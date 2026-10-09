// overlay.c — paint a floating panel into a program's own output stream.
//
// THE IDEA. A tmux popup grabs the keyboard because it is a pane. We do not
// want a pane; we want pixels. This shim rides inside the host process (it is
// LD_PRELOADed, proven to take on the Claude Code binary) and appends our own
// escape sequences to what the host writes. tmux carries them like any other
// output, so there is no popup, no fork of tmux, no extension to maintain and
// nothing that can take the keyboard: an overlay painted this way is not an
// input surface at all.
//
// WHAT IT BORROWS FROM tmux's popup. Only the ideas worth having: a rounded
// border, a drop of padding, a title row, and placement clamped to the screen.
// The drawing is ours, so the look is ours to change.
//
// HOW IT STAYS ON SCREEN. The host repaints its frame whenever it likes and
// knows nothing about our cells, so the panel is re-asserted after every
// flush of host output while it is active. Cheap: it is one string write.
//
// This file is the PAINTER only. What to paint and where comes from the
// bridge; see bridge/README.md.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/uio.h>   // writev: the host batches its frames through it

#define NF_MAX_LINES 8
#define NF_MAX_W 100

static ssize_t (*real_write)(int, const void *, size_t);

/* The panel currently shown; empty title means nothing is shown. */
static struct {
    int x, y, w, lines;
    char title[NF_MAX_W];
    char line[NF_MAX_LINES][NF_MAX_W];
    char accent[16];
    int active;
} panel;

static int in_paint; /* re-entrancy guard: our own writes must not recurse */

static void out(const char *s) {
    size_t n = strlen(s);
    size_t off = 0;
    while (off < n) {
        ssize_t k = real_write(STDOUT_FILENO, s + off, n - off);
        if (k <= 0) break;
        off += (size_t)k;
    }
}

static void outf(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    out(buf);
}

/* Draw the panel. Save cursor, paint absolutely, restore: the host's own
   cursor position must come back exactly, or its next write lands wrong. */
static void nf_paint(void) {
    if (!panel.active || in_paint) return;
    in_paint = 1;

    const char *acc = panel.accent[0] ? panel.accent : "38;5;110";
    int w = panel.w;

    out("\033[s");            /* save cursor */
    out("\033[?25l");         /* hide it while we draw */

    /* top border with the title inlaid, the one flourish worth copying */
    outf("\033[%d;%dH\033[%sm╭", panel.y, panel.x, acc);
    int used = 0;
    if (panel.title[0]) {
        outf("─ \033[1m%s\033[22m ", panel.title);
        used = (int)strlen(panel.title) + 3;
    }
    for (int i = used; i < w - 2; i++) out("─");
    out("╮\033[0m");

    for (int i = 0; i < panel.lines; i++) {
        outf("\033[%d;%dH\033[%sm│\033[0m ", panel.y + 1 + i, panel.x, acc);
        outf("%-*.*s", w - 4, w - 4, panel.line[i]);
        outf(" \033[%sm│\033[0m", acc);
    }

    outf("\033[%d;%dH\033[%sm╰", panel.y + 1 + panel.lines, panel.x, acc);
    for (int i = 0; i < w - 2; i++) out("─");
    out("╯\033[0m");

    out("\033[?25h");
    out("\033[u");            /* restore cursor */
    in_paint = 0;
}

/* Erase by asking the host to repaint. We cannot know what was underneath,
   and guessing would smear the transcript; a full repaint is correct and the
   host does one on any resize-ish nudge. The bridge sends this on hover-out. */
static void nf_clear(void) {
    if (!panel.active) return;
    panel.active = 0;
}

void nf_overlay_set(int x, int y, int w, const char *accent, const char *title,
                    const char **lines, int nlines) {
    if (nlines > NF_MAX_LINES) nlines = NF_MAX_LINES;
    if (w > NF_MAX_W - 1) w = NF_MAX_W - 1;
    panel.x = x; panel.y = y; panel.w = w; panel.lines = nlines;
    snprintf(panel.title, sizeof panel.title, "%s", title ? title : "");
    snprintf(panel.accent, sizeof panel.accent, "%s", accent ? accent : "");
    for (int i = 0; i < nlines; i++)
        snprintf(panel.line[i], sizeof panel.line[i], "%s", lines[i]);
    panel.active = 1;
    nf_paint();
}

void nf_overlay_hide(void) { nf_clear(); }

/* Driven by NF_PANEL until the bridge socket exists, so the painter can be
   SEEN before anything is built on it:
     NF_PANEL="x~y~w~accent~title~line one|line two"
   accent is an SGR colour body, e.g. "38;5;183". */
__attribute__((constructor)) static void nf_init(void) {
    const char *spec = getenv("NF_PANEL");
    if (!spec || !*spec) return;
    /* Same gate as the write path, and it matters more here: the constructor
       runs in every child too, and painting from one corrupts its output
       before the first write() is ever interposed. */
    if (!isatty(STDOUT_FILENO)) return;
    if (!real_write) real_write = dlsym(RTLD_NEXT, "write");

    char buf[1024];
    snprintf(buf, sizeof buf, "%s", spec);
    char *save = NULL;
    char *f[6] = {0};
    int i = 0;
    for (char *t = strtok_r(buf, "~", &save); t && i < 6; t = strtok_r(NULL, "~", &save))
        f[i++] = t;
    if (i < 6) return;

    const char *ls[NF_MAX_LINES];
    int n = 0;
    char *ls_save = NULL;
    for (char *t = strtok_r(f[5], "|", &ls_save); t && n < NF_MAX_LINES;
         t = strtok_r(NULL, "|", &ls_save))
        ls[n++] = t;

    nf_overlay_set(atoi(f[0]), atoi(f[1]), atoi(f[2]), f[3], f[4], ls, n);
}

/* Every host frame is followed by our panel, because the host repaints
   whatever it likes and knows nothing about our cells. */
/* Only the process that OWNS THE TERMINAL may paint.
   LD_PRELOAD is inherited by every child, so without this gate each hook
   Claude Code spawns gets the panel appended to its stdout. Measured: the
   session's SessionStart hooks failed with
     bell.sh: line 24: cd: $'\E[s\E[?25l\E[10;30H...'
   because a hook's output IS data to its caller, and we had written a panel
   into it. A hook's stdout is a pipe and the TUI's is a tty, so isatty
   separates them exactly. Cached, since isatty is a syscall and this is the
   hot path. */
static int nf_may_paint(void) {
    static int cached = -1;
    if (cached < 0) cached = isatty(STDOUT_FILENO) ? 1 : 0;
    return cached;
}

ssize_t write(int fd, const void *buf, size_t n) {
    if (!real_write) real_write = dlsym(RTLD_NEXT, "write");
    ssize_t r = real_write(fd, buf, n);
    if (fd == STDOUT_FILENO && panel.active && !in_paint && nf_may_paint())
        nf_paint();
    return r;
}

/* writev as well, and this is not belt-and-braces: with only write() hooked
   the panel appeared once from the constructor, the host cleared the screen
   at startup, and it never came back. The host batches its frames, so the
   frames arrive here, not in write(). */
ssize_t writev(int fd, const struct iovec *iov, int cnt) {
    static ssize_t (*real_writev)(int, const struct iovec *, int);
    if (!real_writev) real_writev = dlsym(RTLD_NEXT, "writev");
    ssize_t r = real_writev(fd, iov, cnt);
    if (fd == STDOUT_FILENO && panel.active && !in_paint && nf_may_paint())
        nf_paint();
    return r;
}
