#!/usr/bin/env python3
"""Apply OMS-41's qemu-user changes to a qemu 11.1.x tree (run from its top directory).

1. x86-64 guests on a host with a larger address space get mappings inside
   their own 47 bits (linux-user/mmap.c).
2. Linux AIO (io_setup, io_destroy, io_submit, io_cancel, io_getevents) passes
   through to the host when the structures match and guest_base is 0
   (linux-user/syscall.c).
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
""")

edit(MMAP, """        if (h2g_valid(ptr + size - 1)) {
            addr = h2g(ptr);
""", """        if (h2g_valid(ptr + size - 1) &&
            h2g(ptr + size - 1) <= guest_mmap_max()) {
            addr = h2g(ptr);
""")

edit(MMAP, """            start += offset - host_offset;
            flags |= MAP_FIXED;
        }
    }

    host_prot = target_to_host_prot(target_prot);
""", """            start += offset - host_offset;
            flags |= MAP_FIXED;
        }
    } else if (!(flags & (MAP_FIXED | MAP_FIXED_NOREPLACE)) &&
               guest_mmap_max() < guest_addr_max) {
        /*
         * As for reserved_va, place the mapping inside the guest's address
         * space ourselves: the host would put it top-down, past the end.
         */
        abi_ulong real_start = start & -host_page_size;
        off_t host_offset = offset & -host_page_size;
        size_t real_len = len + offset - host_offset;
        abi_ulong align = MAX(host_page_size, TARGET_PAGE_SIZE);

        start = mmap_find_vma(real_start, real_len, align);
        if (start == (abi_ulong)-1) {
            errno = ENOMEM;
            return -1;
        }
        start += offset - host_offset;
        flags |= MAP_FIXED;
    }

    host_prot = target_to_host_prot(target_prot);
""")

SYSCALL = "linux-user/syscall.c"

edit(SYSCALL, """safe_syscall3(ssize_t, read, int, fd, void *, buff, size_t, count)
""", """safe_syscall3(ssize_t, read, int, fd, void *, buff, size_t, count)

/*
 * Linux AIO passthrough. Every 64-bit guest and host of the same endianness
 * (x86-64 on arm64 among them) share aio_context_t, struct iocb, struct
 * io_event and struct timespec byte for byte, and with guest_base 0 a guest
 * pointer inside them is the host pointer, so the host kernel can take them
 * as they are. Anything else keeps the old -ENOSYS.
 */
#if defined(TARGET_NR_io_setup) && defined(__NR_io_setup) && \\
    TARGET_ABI_BITS == 64 && HOST_LONG_BITS == 64 && \\
    HOST_BIG_ENDIAN == TARGET_BIG_ENDIAN
#define QEMU_LINUX_AIO_PASSTHROUGH 1
safe_syscall5(int, io_getevents, unsigned long, ctx_id, long, min_nr,
              long, nr, void *, events, struct timespec *, timeout)
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
        if (!access_ok(cpu, VERIFY_WRITE, arg2, sizeof(abi_ulong))) {
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
        if (guest_base) {
            return -TARGET_ENOSYS;
        }
        return get_errno(syscall(__NR_io_submit, (unsigned long)arg1,
                                 (long)arg2, g2h_untagged(arg3)));
    case TARGET_NR_io_cancel:
        if (guest_base) {
            return -TARGET_ENOSYS;
        }
        return get_errno(syscall(__NR_io_cancel, (unsigned long)arg1,
                                 g2h_untagged(arg2), g2h_untagged(arg3)));
    case TARGET_NR_io_getevents:
    {
        struct timespec ts, *pts = NULL;

        if (guest_base) {
            return -TARGET_ENOSYS;
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
        return get_errno(safe_io_getevents(arg1, arg2, arg3,
                                           g2h_untagged(arg4), pts));
    }
#endif

#if defined(TARGET_NR_epoll_wait)
    case TARGET_NR_epoll_wait:
#endif
    case TARGET_NR_epoll_pwait:
""")
MAIN = "linux-user/main.c"

edit(MAIN, """    mmap_next_start = task_unmapped_base;
""", """    mmap_next_start = task_unmapped_base;

#if TARGET_ABI_BITS == 64 && HOST_LONG_BITS == 64 && \\
    TARGET_VIRT_ADDR_SPACE_BITS <= 47
    /*
     * With no reserved_va, mmap.c keeps such a guest's mappings inside its
     * own address space (guest_mmap_max). Search from high in that space,
     * as the guest kernel's default top-down layout would place them:
     * SQL Server's PAL refuses mappings below 2^46, which it takes for the
     * legacy layout. 3/4 of the space leaves 32 TiB on x86-64.
     */
    if (!reserved_va) {
        mmap_next_start = TARGET_PAGE_ALIGN(
            ((abi_ulong)1 << TARGET_VIRT_ADDR_SPACE_BITS) / 4 * 3);
    }
#endif
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
