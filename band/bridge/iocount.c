// iocount.c — which libc I/O calls does the host actually make on fd 1?
//
// Needed because "LD_PRELOAD interposition takes" and "the host's output goes
// through libc" are different claims, and only the first was measured. Bun is
// Zig and can issue syscalls directly, in which case no amount of interposing
// write/writev will ever see a frame. This counts, and writes the tally at
// exit. No painting, no behaviour change.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

static long n_write, n_writev, n_send, n_fwrite, n_puts;
static long b_write, b_writev;
static int is_tty;

__attribute__((constructor)) static void start(void) { is_tty = isatty(1); }

__attribute__((destructor)) static void report(void) {
    const char *p = getenv("NF_IO_OUT");
    if (!p) return;
    FILE *f = fopen(p, "a");
    if (!f) return;
    fprintf(f,
            "pid=%d tty=%d write=%ld(%ld bytes) writev=%ld(%ld bytes) "
            "send=%ld fwrite=%ld puts=%ld\n",
            (int)getpid(), is_tty, n_write, b_write, n_writev, b_writev,
            n_send, n_fwrite, n_puts);
    fclose(f);
}

ssize_t write(int fd, const void *b, size_t n) {
    static ssize_t (*r)(int, const void *, size_t);
    if (!r) r = dlsym(RTLD_NEXT, "write");
    if (fd == 1) { n_write++; b_write += (long)n; }
    return r(fd, b, n);
}

ssize_t writev(int fd, const struct iovec *v, int c) {
    static ssize_t (*r)(int, const struct iovec *, int);
    if (!r) r = dlsym(RTLD_NEXT, "writev");
    if (fd == 1) {
        n_writev++;
        for (int i = 0; i < c; i++) b_writev += (long)v[i].iov_len;
    }
    return r(fd, v, c);
}

ssize_t send(int fd, const void *b, size_t n, int fl) {
    static ssize_t (*r)(int, const void *, size_t, int);
    if (!r) r = dlsym(RTLD_NEXT, "send");
    if (fd == 1) n_send++;
    return r(fd, b, n, fl);
}

size_t fwrite(const void *p, size_t s, size_t m, FILE *f) {
    static size_t (*r)(const void *, size_t, size_t, FILE *);
    if (!r) r = dlsym(RTLD_NEXT, "fwrite");
    if (f == stdout) n_fwrite++;
    return r(p, s, m, f);
}

int puts(const char *s) {
    static int (*r)(const char *);
    if (!r) r = dlsym(RTLD_NEXT, "puts");
    n_puts++;
    return r(s);
}
