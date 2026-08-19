/* crash_handler.c - Minimal SIGSEGV handler that prints backtrace.
 * Build: gcc -shared -fPIC -o /tmp/crash_handler.so crash_handler.c -ldl
 * Use: LD_PRELOAD=/tmp/crash_handler.so ./cellapp
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <signal.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <stdlib.h>

static void handler(int sig, siginfo_t *si, void *uc)
{
    void *bt[64];
    int n;
    (void)uc;

    fprintf(stderr, "\n=== CRASH (signal %d) ===\n", sig);
    fprintf(stderr, "si_addr=%p\n", si->si_addr);

    n = backtrace(bt, 64);
    fprintf(stderr, "Backtrace (%d frames):\n", n);
    backtrace_symbols_fd(bt, n, 2);

    /* Also try to resolve symbols with dladdr */
    for (int i = 0; i < n; i++) {
        Dl_info info;
        if (dladdr(bt[i], &info)) {
            fprintf(stderr, "  [%d] %s + %p (%s)\n",
                i,
                info.dli_sname ? info.dli_sname : "?",
                (void*)((char*)bt[i] - (char*)info.dli_saddr),
                info.dli_fname ? info.dli_fname : "?");
        }
    }

    fprintf(stderr, "=== END CRASH ===\n");
    _exit(1);
}

__attribute__((constructor))
static void init_crash_handler(void)
{
    struct sigaction sa;
    sa.sa_sigaction = handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    fprintf(stderr, "[crash_handler] Installed SIGSEGV/SIGABRT handler\n");
}
