// ctl.c — positive control for the I/O counter. Calls write(2) and writev(2)
// on fd 1 directly, so a counter that reports zero for THIS is broken, and
// any conclusion drawn from it about another program is worthless.
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

int main(void) {
    write(1, "control-write\n", 14);
    struct iovec v[2] = {{"control-", 8}, {"writev\n", 7}};
    writev(1, v, 2);
    return 0;
}
