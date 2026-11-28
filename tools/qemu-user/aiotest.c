/*
 * x86-64 guest checks for qemu-user's Linux AIO passthrough (OMS-41, patch
 * 1001). Each case comes from the review of omacom/omarchy-pkgs#3505.
 * Build static on x86-64: cc -O2 -static. Raw syscalls, no libaio.
 *
 * Usage: aiotest [HOSTADDR]
 * HOSTADDR (hex) is an address mapped in the qemu process but not in the
 * guest, such as qemu's own data segment, read by the caller from
 * /proc/PID/maps; "-" reads it from stdin once the test has started, so the
 * caller can look the process up first. Without it those cases are skipped.
 * Prints one PASS/FAIL line per case; exit status is the failure count.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/aio_abi.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <unistd.h>

static int failures;
static aio_context_t ctx;

static void result(const char *name, int ok, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
static void result(const char *name, int ok, const char *fmt, ...)
{
    va_list ap;
    printf("%s %-26s ", ok ? "PASS" : "FAIL", name);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    fflush(stdout);
    failures += !ok;
}

static long sys_submit(long nr, struct iocb **list)
{
    long r = syscall(SYS_io_submit, ctx, nr, list);
    return r < 0 ? -errno : r;
}

static long sys_getevents(long nr, struct io_event *ev)
{
    struct timespec ts = { 5, 0 };
    long r = syscall(SYS_io_getevents, ctx, 1, nr, ev, &ts);
    return r < 0 ? -errno : r;
}

static void prep(struct iocb *cb, int op, int fd, void *buf, size_t n, off_t off)
{
    memset(cb, 0, sizeof(*cb));
    cb->aio_lio_opcode = op;
    cb->aio_fildes = fd;
    cb->aio_buf = (uintptr_t)buf;
    cb->aio_nbytes = n;
    cb->aio_offset = off;
}

/* Submit one iocb and wait for it; return its res, or the submit error. */
static long run1(struct iocb *cb)
{
    struct iocb *list[1] = { cb };
    struct io_event ev;
    long r = sys_submit(1, list);

    if (r != 1) {
        return r < 0 ? r : -1000;
    }
    r = sys_getevents(1, &ev);
    if (r != 1) {
        return r < 0 ? r : -1001;
    }
    return ev.res;
}

static int datafile(void)
{
    char path[] = "/tmp/aiotest-XXXXXX";
    char buf[8192];
    int fd = mkstemp(path), i;

    unlink(path);
    for (i = 0; i < (int)sizeof(buf); i++) {
        buf[i] = 'a' + i % 26;
    }
    if (fd < 0 || write(fd, buf, sizeof(buf)) != sizeof(buf)) {
        perror("datafile");
        exit(100);
    }
    return fd;
}

static int matches(const char *p, size_t n, off_t off)
{
    size_t i;
    for (i = 0; i < n; i++) {
        if (p[i] != 'a' + (off + i) % 26) {
            return 0;
        }
    }
    return 1;
}

static void basic(int fd)
{
    static char buf[4096];
    struct iocb cb;
    long r;

    prep(&cb, IOCB_CMD_PREAD, fd, buf, sizeof(buf), 100);
    r = run1(&cb);
    result("pread", r == 4096 && matches(buf, 4096, 100), "res=%ld", r);
}

/*
 * A buffer on a page that holds code QEMU has translated: QEMU write-protects
 * that page to catch changes to the code, and the host kernel then can't
 * write the read's data into it.
 */
static void code_page(int fd, int vector)
{
    unsigned char *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    int (*fn)(void) = (int (*)(void))page;
    struct iovec iov[2];
    struct iocb cb;
    long r;
    int i, before, after;

    /* mov $7, %eax; ret */
    memcpy(page, "\xb8\x07\x00\x00\x00\xc3", 6);
    for (i = 0, before = 0; i < 3; i++) {
        before += fn();
    }
    if (vector) {
        iov[0].iov_base = page + 2048;
        iov[0].iov_len = 512;
        iov[1].iov_base = page + 2560;
        iov[1].iov_len = 512;
        prep(&cb, IOCB_CMD_PREADV, fd, iov, 2, 300);
    } else {
        prep(&cb, IOCB_CMD_PREAD, fd, page + 2048, 1024, 300);
    }
    r = run1(&cb);
    memcpy(page + 1, "\x09", 1); /* now mov $9: the new code must run */
    after = fn();
    result(vector ? "preadv-into-code-page" : "pread-into-code-page",
           r == 1024 && matches((char *)page + 2048, 1024, 300) &&
           before == 21 && after == 9,
           "res=%ld fn=%d,%d", r, before, after);
    munmap(page, 4096);
}

/* An error in the completion event (EINVAL: reading a directory). */
static void event_errno(void)
{
    static char buf[64];
    int dfd = open("/", O_RDONLY | O_DIRECTORY);
    struct iocb cb;
    long r;

    prep(&cb, IOCB_CMD_PREAD, dfd, buf, sizeof(buf), 0);
    r = run1(&cb);
    result("event-errno", r == -EINVAL, "res=%ld", r);
    close(dfd);
}

/*
 * An unmapped iocb or buffer gives EFAULT. A native kernel reports a bad
 * buffer in the completion event and qemu at submit, so either passes.
 */
static void bad_guest_pointers(int fd)
{
    char *gone = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    static char buf[64];
    struct iocb cb, cb2, *list[2];
    long r1, r2, r3;

    munmap(gone, 4096);
    list[0] = (struct iocb *)gone;
    r1 = sys_submit(1, list);

    prep(&cb, IOCB_CMD_PREAD, fd, gone, 64, 0);
    r2 = run1(&cb);

    /* The first iocb is good, the second not: the first still completes. */
    prep(&cb, IOCB_CMD_PREAD, fd, buf, 64, 0);
    prep(&cb2, IOCB_CMD_PREAD, fd, gone, 64, 0);
    list[0] = &cb;
    list[1] = &cb2;
    r3 = sys_submit(2, list);
    if (r3 >= 1) {
        struct io_event ev[2];
        long i, n = sys_getevents(r3, ev);

        for (i = 0; i < n; i++) {
            if (ev[i].obj == (uintptr_t)&cb && ev[i].res != 64) {
                r3 = -3000;
            }
        }
    }
    result("unmapped-guest-pointers",
           r1 == -EFAULT && r2 == -EFAULT && (r3 == 1 || r3 == 2),
           "iocb=%ld buf=%ld partial=%ld", r1, r2, r3);
}

/*
 * Memory that is QEMU's, not the guest's: the host kernel must never be
 * handed it. Natively this address is not mapped, so the answer is EFAULT.
 */
static void host_memory(int fd, uintptr_t host)
{
    struct iocb cb, *list[1] = { &cb };
    struct io_event *events = (struct io_event *)host;
    long r1, r2;
    static char buf[64];

    prep(&cb, IOCB_CMD_PREAD, fd, (void *)host, 64, 0);
    r1 = run1(&cb);

    prep(&cb, IOCB_CMD_PREAD, fd, buf, 64, 0);
    r2 = sys_submit(1, list);
    if (r2 == 1) {
        r2 = sys_getevents(1, events);
    } else {
        r2 = -2000;
    }
    result("qemu-memory-pointers", r1 == -EFAULT && r2 == -EFAULT,
           "buf=%ld events=%ld (at %#lx)", r1, r2, (unsigned long)host);
    if (r2 != -EFAULT) {
        struct io_event ev;
        sys_getevents(1, &ev); /* drain */
    }
}

int main(int argc, char **argv)
{
    int fd = datafile();
    uintptr_t host = 0;

    if (syscall(SYS_io_setup, 16, &ctx) != 0) {
        result("io_setup", 0, "errno=%d", errno);
        return failures;
    }
    basic(fd);
    code_page(fd, 0);
    code_page(fd, 1);
    event_errno();
    bad_guest_pointers(fd);
    if (argc > 1) {
        char line[64] = "";
        const char *arg = argv[1];

        if (strcmp(arg, "-") == 0) {
            printf("waiting for HOSTADDR on stdin\n");
            fflush(stdout);
            if (!fgets(line, sizeof(line), stdin)) {
                line[0] = 0;
            }
            arg = line;
        }
        host = strtoull(arg, NULL, 16);
        if (host) {
            host_memory(fd, host);
        }
    }
    syscall(SYS_io_destroy, ctx);
    return failures;
}
