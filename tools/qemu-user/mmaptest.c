/*
 * x86-64 guest checks for qemu-user's mmap placement (OMS-41, patch 1000).
 * Each case reproduces one of the problems in the review of
 * omacom/omarchy-pkgs#3505. Build static on x86-64: cc -O2 -static.
 * Prints one PASS/FAIL line per case; exit status is the failure count.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define KiB (1UL << 10)
#define MiB (1UL << 20)
#define GiB (1UL << 30)
#define TOP (1UL << 47)
#define LOW (1UL << 46)

static int failures;

static void result(const char *name, int ok, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
static void result(const char *name, int ok, const char *fmt, ...)
{
    va_list ap;
    printf("%s %-28s ", ok ? "PASS" : "FAIL", name);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    failures += !ok;
}

static void *anon(void *hint, size_t len, int prot, int extra)
{
    return mmap(hint, len, prot, MAP_PRIVATE | MAP_ANONYMOUS | extra, -1, 0);
}

static int in_window(void *p, size_t len)
{
    uintptr_t a = (uintptr_t)p;
    return p != MAP_FAILED && a + len <= TOP;
}

/* V8's code range: a hint that is already taken. */
static void hint_taken(void)
{
    void *a = anon(NULL, MiB, PROT_READ | PROT_WRITE, 0);
    void *b = anon(a, 512 * MiB, PROT_NONE, MAP_NORESERVE);
    result("hint-taken", a != MAP_FAILED && in_window(b, 512 * MiB),
           "a=%p b=%p errno=%d", a, b, b == MAP_FAILED ? errno : 0);
    munmap(b, 512 * MiB);
    munmap(a, MiB);
}

/* A mapping just above the search start must not block larger ones. */
static void blocker(int noreplace)
{
    void *a = anon(NULL, MiB, PROT_READ, 0);
    void *b = anon((char *)a + 2 * MiB, MiB, PROT_READ,
                   noreplace ? MAP_FIXED_NOREPLACE : 0);
    void *c[6];
    int i, ok = a != MAP_FAILED && b != MAP_FAILED;

    for (i = 0; i < 6; i++) {
        c[i] = anon(NULL, 8 * MiB, PROT_READ, 0);
        ok &= in_window(c[i], 8 * MiB) && (uintptr_t)c[i] >= LOW;
    }
    result(noreplace ? "blocker-noreplace" : "blocker-hint", ok,
           "a=%p b=%p c0=%p c5=%p", a, b, c[0], c[5]);
    for (i = 0; i < 6; i++) {
        if (c[i] != MAP_FAILED) {
            munmap(c[i], 8 * MiB);
        }
    }
    munmap(b, MiB);
    munmap(a, MiB);
}

/* Freed space in the window must be reused. */
static void reuse(void)
{
    int i;
    void *p = NULL;

    for (i = 0; i < 2000; i++) {
        p = anon(NULL, 64 * GiB, PROT_NONE, MAP_NORESERVE);
        if (!in_window(p, 64 * GiB)) {
            break;
        }
        munmap(p, 64 * GiB);
    }
    result("reuse-64g-x2000", i == 2000, "rounds=%d last=%p", i, p);
}

/* realloc-style growth through mremap(MREMAP_MAYMOVE). */
static void grow(void)
{
    size_t size = 4 * KiB;
    char *p = anon(NULL, size, PROT_READ | PROT_WRITE, 0);
    int ok = p != MAP_FAILED;

    if (ok) {
        p[0] = 42;
    }
    while (ok && size < GiB) {
        char *q = mremap(p, size, size + 4 * KiB, MREMAP_MAYMOVE);
        if (q == MAP_FAILED || !in_window(q, size + 4 * KiB) || q[0] != 42) {
            ok = 0;
            break;
        }
        p = q;
        size += 4 * KiB;
    }
    result("mremap-grow-1g", ok, "reached=%zu MiB errno=%d", size / MiB,
           ok ? 0 : errno);
    if (p != MAP_FAILED) {
        munmap(p, size);
    }
}

/* A writable shared file mapping whose length is not a host page multiple. */
static void shared_file(void)
{
    char path[] = "/tmp/mmaptest-XXXXXX";
    int fd = mkstemp(path);
    size_t len = 5000;
    char buf[16] = { 0 };
    char *p;
    int ok;

    unlink(path);
    ok = fd >= 0 && ftruncate(fd, len) == 0;
    p = ok ? mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
           : MAP_FAILED;
    ok = in_window(p, len);
    if (ok) {
        memcpy(p + 4990, "written", 7);
        msync(p, len, MS_SYNC);
        ok = pread(fd, buf, 7, 4990) == 7 && memcmp(buf, "written", 7) == 0;
        munmap(p, len);
    }
    result("shared-file-5000", ok, "p=%p errno=%d", p,
           p == MAP_FAILED ? errno : 0);
    if (fd >= 0) {
        close(fd);
    }
}

/* MAP_HUGETLB must not fail for alignment (ENOMEM: no huge pages set up). */
static void hugetlb(void)
{
    void *p = anon(NULL, 2 * MiB, PROT_READ | PROT_WRITE, MAP_HUGETLB);
    int err = p == MAP_FAILED ? errno : 0;

    result("hugetlb", err != EINVAL && (p == MAP_FAILED || in_window(p, 2 * MiB)),
           "p=%p errno=%d", p, err);
    if (p != MAP_FAILED) {
        munmap(p, 2 * MiB);
    }
}

/* In-place growth must not cross the top of the window. */
static void grow_past_top(void)
{
    /* x86-64 user space ends one page below 2^47. */
    char *want = (char *)(TOP - 4 * KiB - 64 * KiB);
    char *p = anon(want, 64 * KiB, PROT_READ, MAP_FIXED_NOREPLACE);
    char *q = MAP_FAILED;

    if (p == want) {
        q = mremap(p, 64 * KiB, 128 * KiB, 0);
    }
    result("mremap-past-top", p == want && q == MAP_FAILED,
           "p=%p q=%p", p, q);
    munmap(p, q == MAP_FAILED ? 64 * KiB : 128 * KiB);
}

/* A failed mmap must not leave its reservation behind. */
static void no_leak(void)
{
    int i, bad = 0;
    void *p;

    for (i = 0; i < 1000; i++) {
        p = mmap(NULL, 64 * GiB, PROT_READ, MAP_PRIVATE | MAP_NORESERVE,
                 999, 0);
        bad += p != MAP_FAILED || errno != EBADF;
    }
    p = anon(NULL, 64 * GiB, PROT_NONE, MAP_NORESERVE);
    result("bad-fd-no-leak", !bad && in_window(p, 64 * GiB),
           "unexpected=%d after=%p", bad, p);
    if (p != MAP_FAILED) {
        munmap(p, 64 * GiB);
    }
}

/* Default placement: inside 2^46..2^47, as SQL Server's PAL needs. */
static void layout(void)
{
    void *p = anon(NULL, MiB, PROT_READ, 0);
    void *h = malloc(64 * MiB);

    result("layout", in_window(p, MiB) && (uintptr_t)p >= LOW &&
           (uintptr_t)h < TOP, "mmap=%p malloc64M=%p", p, h);
    free(h);
    munmap(p, MiB);
}

int main(int argc, char **argv)
{
    layout();
    hint_taken();
    blocker(0);
    blocker(1);
    reuse();
    grow();
    shared_file();
    hugetlb();
    grow_past_top();
    no_leak();
    return failures;
}
