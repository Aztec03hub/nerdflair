// probe.c — does LD_PRELOAD interposition take on the Claude Code binary?
//
// The binary is Bun 1.4.3 compiled standalone, but `file` reports it
// dynamically linked, so the loader should honour LD_PRELOAD. This proves it
// before anything is built on top: it interposes one trivially-called libc
// function and drops a marker. Nothing else.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void mark(const char *what) {
    static int done = 0;
    if (done) return;
    done = 1;
    const char *p = getenv("NF_PROBE_OUT");
    if (!p) return;
    FILE *f = fopen(p, "a");
    if (!f) return;
    fprintf(f, "interposed: %s pid=%d\n", what, (int)getpid());
    fclose(f);
}

ssize_t read(int fd, void *buf, size_t n) {
    static ssize_t (*real)(int, void *, size_t);
    if (!real) real = dlsym(RTLD_NEXT, "read");
    mark("read");
    return real(fd, buf, n);
}
