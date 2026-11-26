#!/usr/bin/env python3
"""Apply OMS-41's qemu-user changes to a qemu 11.1.x tree (run from its top directory).

1. x86-64 guests on a host with a larger address space get mappings inside
   their own 47 bits (linux-user/mmap.c, main.c): QEMU searches its own page
   table for the hole, claims it with MAP_FIXED_NOREPLACE, skips past its own
   host mappings and reuses freed space; mremap resizes in place first.
   omacom/omarchy-pkgs's patch 1000.
2. Linux AIO (io_setup, io_destroy, io_submit, io_cancel, io_getevents) passes
   through to the host when the structures match and guest_base is 0, with
   every pointer checked against guest memory, a read into a page protected
   for translated code redone, and result errnos translated
   (linux-user/syscall.c). omacom/omarchy-pkgs's patch 1001.
3. sigcontext.trapno carries the real trap number, not -1: a backport of
   upstream qemu 586284af4c2c, which v11.2.0-rc1 has (linux-user/i386,
   target/i386). SQL Server's PAL grows a thread stack on a guard-page fault
   only when trapno says page fault (14).

Each anchor must match exactly once, or the script stops without writing.
"""
import sys
from pathlib import Path


def edit(path, old, new):
    p = Path(path)
    text = p.read_text()
    if text.count(old) != 1:
        sys.exit(f"{path}: anchor found {text.count(old)} times:\n{old}")
    p.write_text(text.replace(old, new))



MMAP = "linux-user/mmap.c"

edit(MMAP, '#include "qemu/interval-tree.h"\n', '#include "qemu/interval-tree.h"\n#include "user/selfmap.h"\n')

edit(MMAP, """abi_ulong task_unmapped_base;
abi_ulong elf_et_dyn_base;
abi_ulong mmap_next_start;
""", """abi_ulong task_unmapped_base;
abi_ulong elf_et_dyn_base;
abi_ulong mmap_next_start;

/*
 * The highest guest address for a mapping the guest didn't place itself.
 * Without reserved_va, guest_addr_max admits every host address. A 64-bit
 * guest with a smaller address space than the host's must still not be
 * handed addresses past its own: on an arm64 host with 48-bit user
 * addresses, an x86-64 guest would get mappings above 2^47, which x86-64
 * programs take for kernel addresses (SQL Server's PAL sign-extends them
 * from bit 47 and faults).
 */
static abi_ulong guest_mmap_max(void)
{
#if TARGET_ABI_BITS == 64 && HOST_LONG_BITS == 64 && \\
    TARGET_VIRT_ADDR_SPACE_BITS <= 47
    if (!reserved_va) {
        return MIN(guest_addr_max,
                   ((abi_ulong)1 << TARGET_VIRT_ADDR_SPACE_BITS) - 1);
    }
#endif
    return guest_addr_max;
}

/*
 * True when QEMU, not the host kernel, must choose where the guest's
 * unplaced mappings go: the host would put them above guest_mmap_max().
 */
static bool mmap_window_capped(void)
{
    return !reserved_va && guest_mmap_max() < guest_addr_max;
}

/*
 * The end of the host mappings that overlap the guest range [addr, addr +
 * size), as a guest address. These are QEMU's own mappings, which the guest
 * page table doesn't record. If none is found (it has gone again), return
 * the next host page, so a search always moves on.
 */
static abi_ulong host_mappings_end(abi_ulong addr, abi_ulong size)
{
    uintptr_t start = (uintptr_t)g2h_untagged(addr);
    uintptr_t last = start + size - 1;
    uintptr_t end = start + qemu_real_host_page_size();
    IntervalTreeRoot *maps = read_self_maps();
    IntervalTreeNode *n;

    if (maps) {
        for (n = interval_tree_iter_first(maps, start, last); n;
             n = interval_tree_iter_next(n, start, last)) {
            end = MAX(end, n->last + 1);
        }
        free_self_maps(maps);
    }
    return h2g_nocheck(end);
}

/*
 * Subroutine of mmap_find_vma, used when the guest's mappings must stay
 * below guest_mmap_max() and no address space was reserved for it.
 *
 * Search the guest page table for a hole, as mmap_find_vma_reserved does,
 * and claim it on the host with MAP_FIXED_NOREPLACE. A host mapping of
 * QEMU's own in the hole fails the claim; the search then resumes past it.
 * The search runs from @start to the top of the window, then again from
 * task_unmapped_base, reusing space the guest has freed, and last from the
 * bottom of the address space, so every hole in the window is reachable.
 */
static abi_ulong mmap_find_vma_capped(abi_ulong start, abi_ulong size,
                                      abi_ulong align, bool from_next)
{
    abi_ulong max = guest_mmap_max();
    abi_ulong low = ROUND_UP(MAX(mmap_min_addr, TARGET_PAGE_SIZE), align);
    abi_ulong from[3] = { start, ROUND_UP(task_unmapped_base, align), low };
    abi_ulong searched = -1;
    int i;

    if (size - 1 > max) {
        return -1;
    }
    for (i = 0; i < ARRAY_SIZE(from); i++) {
        abi_ulong addr = from[i];

        /* [searched, max] has been searched already. */
        if (addr >= searched) {
            continue;
        }
        searched = addr;

        while (addr <= max - (size - 1)) {
            void *want, *p;
            abi_ulong next;

            addr = page_find_range_empty(addr, max, size, align);
            if (addr == (abi_ulong)-1) {
                break;
            }
            want = g2h_untagged(addr);
            p = mmap(want, size, PROT_NONE,
                     MAP_ANONYMOUS | MAP_PRIVATE | MAP_NORESERVE |
                     MAP_FIXED_NOREPLACE, -1, 0);
            if (p == want) {
                if (from_next && addr >= task_unmapped_base) {
                    mmap_next_start = addr + size;
                }
                return addr;
            }
            if (p != MAP_FAILED) {
                /* The host took MAP_FIXED_NOREPLACE as a hint. */
                munmap(p, size);
            } else if (errno != EEXIST) {
                return -1;
            }
            next = ROUND_UP(host_mappings_end(addr, size), align);
            if (next <= addr) {
                break;
            }
            addr = next;
        }
    }
    return -1;
}

/*
 * The host's default huge page size, which a MAP_HUGETLB mapping without
 * a size gets, or 0 if it is unknown.
 */
static abi_ulong host_hugetlb_size(void)
{
    static abi_ulong size = -1;

    if (size == (abi_ulong)-1) {
        FILE *f = fopen("/proc/meminfo", "r");
        char line[128];
        unsigned long kb;

        size = 0;
        if (f) {
            while (fgets(line, sizeof(line), f)) {
                if (sscanf(line, "Hugepagesize: %lu kB", &kb) == 1) {
                    size = (abi_ulong)kb << 10;
                    break;
                }
            }
            fclose(f);
        }
    }
    return size;
}
""")

edit(MMAP, """abi_ulong mmap_find_vma(abi_ulong start, abi_ulong size, abi_ulong align)
{
    int host_page_size = qemu_real_host_page_size();
    void *ptr, *prev;
    abi_ulong addr;
    int wrapped, repeat;

    align = MAX(align, host_page_size);

    /* If 'start' == 0, then a default start address is used. */
    if (start == 0) {
""", """abi_ulong mmap_find_vma(abi_ulong start, abi_ulong size, abi_ulong align)
{
    int host_page_size = qemu_real_host_page_size();
    void *ptr, *prev;
    abi_ulong addr;
    int wrapped, repeat;
    bool from_next = start == 0;

    align = MAX(align, host_page_size);

    /* If 'start' == 0, then a default start address is used. */
    if (start == 0) {
""")

edit(MMAP, """    if (reserved_va) {
        return mmap_find_vma_reserved(start, size, align);
    }

    addr = start;
""", """    if (reserved_va) {
        return mmap_find_vma_reserved(start, size, align);
    }
    if (mmap_window_capped()) {
        return mmap_find_vma_capped(start, size, align, from_next);
    }

    addr = start;
""")

# mmap_h_gt_g: a placed mapping takes the direct path, as an unplaced one does.
edit(MMAP, """static abi_long mmap_h_gt_g(abi_ulong start, abi_ulong len,
                            int target_prot, int host_prot,
                            int flags, int page_flags, int fd,
                            off_t offset, int host_page_size)
{""", """static abi_long mmap_h_gt_g(abi_ulong start, abi_ulong len,
                            int target_prot, int host_prot,
                            int flags, int page_flags, int fd,
                            off_t offset, int host_page_size, bool placed)
{""")

edit(MMAP, """    if (!(flags & (MAP_FIXED | MAP_FIXED_NOREPLACE))) {
        /*
         * Adjust the offset to something representable on the host.
         */
        host_len = len + offset - host_offset;
        p = mmap(want_p, host_len, host_prot, flags, fd, host_offset);
        if (p == MAP_FAILED) {
            return -1;
        }
""", """    /*
     * @placed: QEMU chose @start, a host-page-aligned hole of whole host
     * pages, and @flags has MAP_FIXED_NOREPLACE. Map it as the host would
     * place it, rather than as a fixed guest range, which would need
     * mmap_frag() for a length that doesn't end on a host page.
     */
    if (placed || !(flags & (MAP_FIXED | MAP_FIXED_NOREPLACE))) {
        /*
         * Adjust the offset to something representable on the host.
         */
        host_len = len + offset - host_offset;
        p = mmap(want_p, host_len, host_prot, flags, fd, host_offset);
        if (p == MAP_FAILED) {
            return -1;
        }
        /* If the host kernel does not support MAP_FIXED_NOREPLACE, emulate. */
        if (placed && p != want_p) {
            do_munmap(p, host_len);
            errno = EEXIST;
            return -1;
        }
""")

edit(MMAP, """    host_prot = target_to_host_prot(target_prot);

    if (host_page_size == TARGET_PAGE_SIZE) {
        return mmap_h_eq_g(start, len, host_prot, flags,
                           page_flags, fd, offset);
    } else if (host_page_size < TARGET_PAGE_SIZE) {
        return mmap_h_lt_g(start, len, host_prot, flags,
                           page_flags, fd, offset, host_page_size);
    } else {
        return mmap_h_gt_g(start, len, target_prot, host_prot, flags,
                           page_flags, fd, offset, host_page_size);
    }
}
""", """    host_prot = target_to_host_prot(target_prot);

    if (mmap_window_capped() && !(flags & (MAP_FIXED | MAP_FIXED_NOREPLACE))) {
        /*
         * As for reserved_va, place the mapping inside the guest's address
         * space ourselves: the host would put it top-down, past the end.
         * Unlike reserved_va, there is no reservation to map over: release
         * the hole mmap_find_vma claimed and map into it with
         * MAP_FIXED_NOREPLACE. A thread that maps host memory of QEMU's own
         * in between takes the hole first; then search again.
         */
        off_t host_offset = offset & -host_page_size;
        abi_ulong real_len = len + offset - host_offset;
        abi_ulong align = MAX(host_page_size, TARGET_PAGE_SIZE);
        abi_ulong hint = start;
        int tries;

        if (flags & MAP_HUGETLB) {
            /* The host aligns and sizes the mapping to its huge page. */
            abi_ulong huge = host_hugetlb_size();

            if (!huge) {
                errno = EINVAL;
                return -1;
            }
            align = MAX(align, huge);
            real_len = ROUND_UP(real_len, huge);
        } else {
            real_len = ROUND_UP(real_len, host_page_size);
        }

        for (tries = 0; tries < 8; tries++) {
            abi_ulong hole = mmap_find_vma(hint, real_len, align);
            abi_long ret;

            if (hole == (abi_ulong)-1) {
                errno = ENOMEM;
                return -1;
            }
            munmap(g2h_untagged(hole), real_len);
            ret = target_mmap_host(hole, len, target_prot, host_prot,
                                   flags | MAP_FIXED_NOREPLACE, page_flags,
                                   fd, offset, host_page_size, true);
            if (ret != -1 || errno != EEXIST) {
                return ret;
            }
            hint = hole;
        }
        errno = ENOMEM;
        return -1;
    }

    return target_mmap_host(start, len, target_prot, host_prot, flags,
                            page_flags, fd, offset, host_page_size, false);
}
""")

edit(MMAP, """static abi_long target_mmap__locked(abi_ulong start, abi_ulong len,
                                    int target_prot, int flags, int page_flags,
                                    int fd, off_t offset)
{""", """static abi_long target_mmap_host(abi_ulong start, abi_ulong len,
                                 int target_prot, int host_prot, int flags,
                                 int page_flags, int fd, off_t offset,
                                 int host_page_size, bool placed)
{
    if (host_page_size == TARGET_PAGE_SIZE) {
        return mmap_h_eq_g(start, len, host_prot, flags,
                           page_flags, fd, offset);
    } else if (host_page_size < TARGET_PAGE_SIZE) {
        return mmap_h_lt_g(start, len, host_prot, flags,
                           page_flags, fd, offset, host_page_size);
    } else {
        return mmap_h_gt_g(start, len, target_prot, host_prot, flags,
                           page_flags, fd, offset, host_page_size, placed);
    }
}

static abi_long target_mmap__locked(abi_ulong start, abi_ulong len,
                                    int target_prot, int flags, int page_flags,
                                    int fd, off_t offset)
{""")

# mremap: try growing in place before moving, and keep in-place growth
# inside the window.
edit(MMAP, """    } else if (flags & MREMAP_MAYMOVE) {
        abi_ulong mmap_start;

        mmap_start = mmap_find_vma(0, new_size, TARGET_PAGE_SIZE);

        if (mmap_start == -1) {
            errno = ENOMEM;
            host_addr = MAP_FAILED;
        } else {
""", """    } else if (flags & MREMAP_MAYMOVE) {
        abi_ulong mmap_start;

        host_addr = MAP_FAILED;
        if (mmap_window_capped() &&
            (new_size <= old_size ||
             (old_addr + new_size - 1 <= guest_mmap_max() &&
              page_check_range_empty(old_addr + old_size,
                                     old_addr + new_size - 1)))) {
            /*
             * Resize in place first, as the host kernel would. Moving
             * every time takes a fresh range of new_size per call, so a
             * buffer grown in small steps would use up the window.
             */
            host_addr = mremap(g2h_untagged(old_addr), old_size, new_size, 0);
        }

        if (host_addr != MAP_FAILED) {
            /* Resized in place. */
        } else if ((mmap_start = mmap_find_vma(0, new_size,
                                               TARGET_PAGE_SIZE)) == -1) {
            errno = ENOMEM;
            host_addr = MAP_FAILED;
        } else {
""")

edit(MMAP, """                /* Check if address fits target address space */
                if (!guest_range_valid_untagged(h2g(host_addr), new_size)) {""",
"""                /* Check if address fits target address space */
                if (!guest_range_valid_untagged(h2g(host_addr), new_size) ||
                    (mmap_window_capped() &&
                     h2g(host_addr) + new_size - 1 > guest_mmap_max())) {""")

MAIN = "linux-user/main.c"
edit(MAIN, """    mmap_next_start = task_unmapped_base;
""", """
#if TARGET_ABI_BITS == 64 && HOST_LONG_BITS == 64 && \\
    TARGET_VIRT_ADDR_SPACE_BITS <= 47
    /*
     * With no reserved_va, mmap.c keeps such a guest's mappings inside its
     * own address space. Place them high in that space, as the guest
     * kernel's default top-down layout would: SQL Server's PAL refuses
     * mappings below 2^46, which it takes for the legacy layout. 3/4 of the
     * space leaves 32 TiB above on x86-64, and the program and its heap,
     * at ELF_ET_DYN_BASE (2/3), sit below.
     */
    if (!reserved_va) {
        task_unmapped_base = TARGET_PAGE_ALIGN(
            ((abi_ulong)1 << TARGET_VIRT_ADDR_SPACE_BITS) / 4 * 3);
    }
#endif
    mmap_next_start = task_unmapped_base;
""")

SYSCALL = "linux-user/syscall.c"

edit(SYSCALL, """safe_syscall3(ssize_t, read, int, fd, void *, buff, size_t, count)
""", """safe_syscall3(ssize_t, read, int, fd, void *, buff, size_t, count)

/*
 * Linux AIO passthrough. Every 64-bit guest and host of the same endianness
 * (x86-64 on arm64 among them) share aio_context_t, struct iocb, struct
 * io_event and struct iovec byte for byte, and with guest_base 0 a guest
 * pointer inside them is the host pointer, so the host kernel can take them
 * as they are, once QEMU has checked them against the guest's memory.
 * Anything else keeps the old -ENOSYS.
 */
#if defined(TARGET_NR_io_setup) && defined(__NR_io_setup) && \\
    TARGET_ABI_BITS == 64 && HOST_LONG_BITS == 64 && \\
    HOST_BIG_ENDIAN == TARGET_BIG_ENDIAN
#define QEMU_LINUX_AIO_PASSTHROUGH 1
#include <linux/aio_abi.h>

safe_syscall5(int, io_getevents, unsigned long, ctx_id, long, min_nr,
              long, nr, void *, events, struct timespec *, timeout)

/*
 * Check the buffers of one iocb against the guest's memory: writable for a
 * read, readable for a write. Checking a buffer writable also unprotects a
 * page that QEMU write-protected because it holds translated code, which
 * the host kernel could not write into. Commands without a buffer pass.
 */
static bool aio_iocb_buffers_ok(CPUState *cpu, const struct iocb *cb)
{
    int type;

    switch (cb->aio_lio_opcode) {
    case IOCB_CMD_PREAD:
    case IOCB_CMD_PREADV:
        type = VERIFY_WRITE;
        break;
    case IOCB_CMD_PWRITE:
    case IOCB_CMD_PWRITEV:
        type = VERIFY_READ;
        break;
    default:
        return true;
    }

    if (cb->aio_lio_opcode == IOCB_CMD_PREADV ||
        cb->aio_lio_opcode == IOCB_CMD_PWRITEV) {
        const struct iovec *iov;
        uint64_t i;

        if (cb->aio_nbytes > IOV_MAX) {
            return true; /* the host kernel refuses it with EINVAL */
        }
        if (!access_ok(cpu, VERIFY_READ, cb->aio_buf,
                       cb->aio_nbytes * sizeof(*iov))) {
            return false;
        }
        iov = g2h_untagged(cb->aio_buf);
        for (i = 0; i < cb->aio_nbytes; i++) {
            if (iov[i].iov_len &&
                !access_ok(cpu, type, (abi_ulong)(uintptr_t)iov[i].iov_base,
                           iov[i].iov_len)) {
                return false;
            }
        }
        return true;
    }
    return !cb->aio_nbytes ||
           access_ok(cpu, type, cb->aio_buf, cb->aio_nbytes);
}

/*
 * Make a completion event right for the guest. A read the host kernel
 * failed with EFAULT may have hit a page that QEMU write-protected again,
 * for code translated on it, after io_submit unprotected it: if the guest
 * buffers are valid, unprotect them and redo the read here. Then give the
 * result's errno the guest's number.
 */
static void aio_fix_event(CPUState *cpu, struct io_event *ev)
{
    int tries;

    for (tries = 0; ev->res == -EFAULT && tries < 3; tries++) {
        const struct iocb *cb;
        struct iovec one, *iov;
        int count;
        ssize_t r;

        if (!access_ok(cpu, VERIFY_READ, ev->obj, sizeof(*cb))) {
            break;
        }
        cb = g2h_untagged(ev->obj);
        if ((cb->aio_lio_opcode != IOCB_CMD_PREAD &&
             cb->aio_lio_opcode != IOCB_CMD_PREADV) ||
            !aio_iocb_buffers_ok(cpu, cb)) {
            break;
        }
        if (cb->aio_lio_opcode == IOCB_CMD_PREAD) {
            one.iov_base = g2h_untagged(cb->aio_buf);
            one.iov_len = cb->aio_nbytes;
            iov = &one;
            count = 1;
        } else {
            iov = g2h_untagged(cb->aio_buf);
            count = cb->aio_nbytes;
        }
        r = preadv2(cb->aio_fildes, iov, count, cb->aio_offset,
                    cb->aio_rw_flags);
        ev->res = r < 0 ? -errno : r;
    }
    if (ev->res < 0 && ev->res >= -4095) {
        ev->res = -host_to_target_errno(-ev->res);
    }
}
#endif
""")

edit(SYSCALL, """#if defined(TARGET_NR_epoll_wait)
    case TARGET_NR_epoll_wait:
#endif
    case TARGET_NR_epoll_pwait:
""", """#ifdef QEMU_LINUX_AIO_PASSTHROUGH
    case TARGET_NR_io_setup:
        if (guest_base) {
            return -TARGET_ENOSYS;
        }
        if (!access_ok(cpu, VERIFY_WRITE, arg2, sizeof(aio_context_t))) {
            return -TARGET_EFAULT;
        }
        return get_errno(syscall(__NR_io_setup, (unsigned int)arg1,
                                 g2h_untagged(arg2)));
    case TARGET_NR_io_destroy:
        if (guest_base) {
            return -TARGET_ENOSYS;
        }
        return get_errno(syscall(__NR_io_destroy, (unsigned long)arg1));
    case TARGET_NR_io_submit:
    {
        abi_long nr = arg2, i;
        const abi_ulong *iocbpp;

        if (guest_base) {
            return -TARGET_ENOSYS;
        }
        if (nr < 0) {
            return -TARGET_EINVAL;
        }
        /*
         * Submit the iocbs up to the first that is not valid guest memory,
         * or whose buffers are not, as the kernel stops at the first it
         * can't read. Check the pointer array one entry at a time, so a
         * huge nr can't overflow the length.
         */
        iocbpp = g2h_untagged(arg3);
        for (i = 0; i < nr; i++) {
            if (!access_ok(cpu, VERIFY_READ, arg3 + i * sizeof(abi_ulong),
                           sizeof(abi_ulong)) ||
                !access_ok(cpu, VERIFY_READ, iocbpp[i], sizeof(struct iocb)) ||
                !aio_iocb_buffers_ok(cpu, g2h_untagged(iocbpp[i]))) {
                break;
            }
        }
        if (nr > 0 && i == 0) {
            return -TARGET_EFAULT;
        }
        return get_errno(syscall(__NR_io_submit, (unsigned long)arg1,
                                 (long)i, iocbpp));
    }
    case TARGET_NR_io_cancel:
    {
        struct io_event *ev;

        if (guest_base) {
            return -TARGET_ENOSYS;
        }
        if (!access_ok(cpu, VERIFY_READ, arg2, sizeof(struct iocb)) ||
            !access_ok(cpu, VERIFY_WRITE, arg3, sizeof(*ev))) {
            return -TARGET_EFAULT;
        }
        ev = g2h_untagged(arg3);
        ret = get_errno(syscall(__NR_io_cancel, (unsigned long)arg1,
                                g2h_untagged(arg2), ev));
        if (ret == 0) {
            aio_fix_event(cpu, ev);
        }
        return ret;
    }
    case TARGET_NR_io_getevents:
    {
        struct timespec ts, *pts = NULL;
        struct io_event *events;
        abi_long i;

        if (guest_base) {
            return -TARGET_ENOSYS;
        }
        if (arg3 > 0 &&
            ((abi_ulong)arg3 > guest_addr_max / sizeof(*events) ||
             !access_ok(cpu, VERIFY_WRITE, arg4, arg3 * sizeof(*events)))) {
            return -TARGET_EFAULT;
        }
        if (arg5) {
            struct target_timespec *tts;

            if (!lock_user_struct(VERIFY_READ, tts, arg5, 1)) {
                return -TARGET_EFAULT;
            }
            __get_user(ts.tv_sec, &tts->tv_sec);
            __get_user(ts.tv_nsec, &tts->tv_nsec);
            unlock_user_struct(tts, arg5, 0);
            pts = &ts;
        }
        events = g2h_untagged(arg4);
        ret = get_errno(safe_io_getevents(arg1, arg2, arg3, events, pts));
        for (i = 0; i < ret; i++) {
            aio_fix_event(cpu, &events[i]);
        }
        return ret;
    }
#endif

#if defined(TARGET_NR_epoll_wait)
    case TARGET_NR_epoll_wait:
#endif
    case TARGET_NR_epoll_pwait:
""")

# Upstream 586284af4c2c "linux-user/i386: report the real trap number in
# sigcontext.trapno", unchanged. v11.2.0-rc1 has it: drop this block on 11.2
# or later.
CPU_LOOP = "linux-user/i386/cpu_loop.c"

edit(CPU_LOOP, """        cpu_exec_end(cs);
        qemu_process_cpu_events(cs);

        switch(trapnr) {
        case 0x80:
""", """        cpu_exec_end(cs);
        qemu_process_cpu_events(cs);

        /*
         * Remember the exception for sigcontext.trapno, as linux does in
         * thread.trap_nr.  Only hardware exception vectors qualify; the
         * EXCP_* values at 0x100 and above are emulation internals.
         */
        if (trapnr >= EXCP00_DIVZ && trapnr <= EXCP12_MCHK) {
            env->trap_nr = trapnr;
        }

        switch(trapnr) {
        case 0x80:
""")

SIGNAL = "linux-user/i386/signal.c"

edit(SIGNAL, """                             abi_ptr fpend_addr)
{
    CPUState *cs = env_cpu(env);

#ifndef TARGET_X86_64
    uint16_t magic;
""", """                             abi_ptr fpend_addr)
{
#ifndef TARGET_X86_64
    uint16_t magic;
""")

edit(SIGNAL, """    __put_user(env->regs[R_EAX], &sc->eax);
    __put_user(cs->exception_index, &sc->trapno);
""", """    __put_user(env->regs[R_EAX], &sc->eax);
    __put_user(env->trap_nr, &sc->trapno);
""")

edit(SIGNAL, """    __put_user(env->regs[15], &sc->r15);

    __put_user(cs->exception_index, &sc->trapno);
""", """    __put_user(env->regs[15], &sc->r15);

    __put_user(env->trap_nr, &sc->trapno);
""")

edit("target/i386/cpu.h", """    /* exception/interrupt handling */
    int error_code;
    int exception_is_int;
""", """    /* exception/interrupt handling */
    int error_code;
#ifdef CONFIG_USER_ONLY
    /*
     * The number of the last cpu exception taken by this thread, mirroring
     * linux's thread.trap_nr, which is what the kernel reports in
     * sigcontext.trapno.  CPUState::exception_index cannot be used for this:
     * cpu_exec() resets it before returning, long before the signal frame is
     * built during delivery.
     */
    int trap_nr;
#endif
    int exception_is_int;
""")

edit("target/i386/tcg/user/excp_helper.c", """     * is copied to linux sigcontext.err.  The exception_index is
     * copied to linux sigcontext.trapno.  Short of inventing a new
     * place to store the trapno, we cannot let our caller raise the
     * signal and set exception_index to EXCP_INTERRUPT.
""", """     * is copied to linux sigcontext.err.  The trapno reported in
     * linux sigcontext.trapno is recorded separately in env->trap_nr
     * by cpu_loop(), since cpu_exec() clears exception_index before
     * the signal frame is built.
""")
print("applied")
