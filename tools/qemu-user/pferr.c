#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <ucontext.h>
#include <unistd.h>

static const char *volatile cur;
static void h(int sig, siginfo_t *si, void *ucv)
{
    ucontext_t *uc = ucv;
    char b[256];
    int n = snprintf(b, sizeof b,
        "%-34s si_code=%d si_addr=%p err=0x%llx trapno=%lld cr2=0x%llx\n",
        cur, si->si_code, si->si_addr,
        (unsigned long long)uc->uc_mcontext.gregs[REG_ERR],
        (long long)uc->uc_mcontext.gregs[REG_TRAPNO],
        (unsigned long long)uc->uc_mcontext.gregs[REG_CR2]);
    write(1, b, n);
    /* make the page usable so the access restarts and succeeds */
    void *pg = (void *)((unsigned long)si->si_addr & ~4095UL);
    if (mmap(pg, 4096, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == MAP_FAILED)
        _exit(3);
}

int main(void)
{
    static char alt[65536];
    stack_t ss = { .ss_sp = alt, .ss_size = sizeof alt };
    sigaltstack(&ss, 0);
    struct sigaction sa = { 0 };
    sa.sa_sigaction = h;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, 0);

    volatile char *p, c;
    p = mmap(0, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    cur = "write PROT_NONE (never touched)"; p[0] = 1;
    p = mmap(0, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    cur = "read  PROT_NONE (never touched)"; c = p[0];
    p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    p[0] = 1; mprotect((void *)p, 4096, PROT_NONE);
    cur = "write PROT_NONE (was populated)"; p[0] = 1;
    p = mmap(0, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    cur = "write PROT_READ (never touched)"; p[0] = 1;
    p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    p[0] = 1; mprotect((void *)p, 4096, PROT_READ);
    cur = "write PROT_READ (populated)"; p[0] = 1;
    p = mmap(0, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    munmap((void *)p, 8192);
    cur = "write unmapped"; p[0] = 1;
    (void)c;
    return 0;
}
