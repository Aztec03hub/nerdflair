"""Leak-proof cleanup for the tmux e2e scripts. A script registers every private temp dir and tmux server it
creates (by exact name or path, never a glob); `install()` makes them go away on EVERY exit path: normal end,
assertion failure, exception, Ctrl-C, SIGTERM (both become SystemExit/KeyboardInterrupt, so finally blocks and
atexit run). Cleanup is idempotent. At exit it asserts none of ITS OWN names remain and exits 97 if one does.

    import leakcheck; leakcheck.install()
    d = leakcheck.mkdtemp("nf-x-"); leakcheck.tmux_L(sock); leakcheck.tmux_S(path)
"""
import atexit
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile

_dirs, _L, _S, _files = [], [], [], []
_installed = False


def _sockpath(name):
    return os.path.join(os.environ.get("TMUX_TMPDIR") or "/tmp", f"tmux-{os.getuid()}", name)


def mkdtemp(prefix):
    d = tempfile.mkdtemp(prefix=prefix)
    _dirs.append(d)
    return d


_e2e_tmp = None


def e2e_tmp():
    """Scratch dir for an e2e script's flags, error logs and fake scripts: $NF_E2E_TMP (the caller owns it), else a
    private mkdtemp that cleanup removes. Never the shared /tmp, never the real ~/.claude."""
    global _e2e_tmp
    if _e2e_tmp is None:
        _e2e_tmp = os.environ.get("NF_E2E_TMP") or mkdtemp("nf-e2e-")
    return _e2e_tmp


def file(path):
    _files.append(path)
    return path


def tmux_L(name):
    _L.append(name)
    return name


def tmux_S(path):
    _S.append(path)
    return path


def _kill(*sel):
    env = {k: v for k, v in os.environ.items() if k != "TMUX"}
    try:
        subprocess.run(["tmux", *sel, "kill-server"], capture_output=True, timeout=5, env=env)
    except (OSError, subprocess.TimeoutExpired):
        pass    # tmux gone or wedged: the socket file is removed below either way


def _own_sockets():
    """Sockets (-S style) under our own temp dirs: the nfpty shadow server lives at <dir>/nf-shadow-*/s."""
    out = list(_S)
    for d in _dirs:
        try:
            for sub in os.listdir(d):
                if sub.startswith("nf-shadow-"):
                    out.append(os.path.join(d, sub, "s"))
        except OSError:
            pass
    return out


def server_pids(sock):
    """PIDs listening on the unix socket path `sock`, even when its file was deleted (the kernel keeps the name)."""
    try:
        out = subprocess.run(["ss", "-xlnpH"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    pids = []
    for line in out.splitlines():
        if f" {sock} " in line:
            pids += [int(x) for x in re.findall(r"pid=(\d+)", line)]
    return pids


def _own_tmux_socket(sock):
    """True only when `sock` sits inside a dir this script made or was given as its scratch dir (_dirs, $NF_E2E_TMP):
    never Phil's ambient /tmp/tmux-UID server."""
    own = [os.path.realpath(d) for d in _dirs + ([_e2e_tmp] if _e2e_tmp else [])]
    return any(os.path.realpath(sock).startswith(d + os.sep) for d in own)


def _is_tmux(pid):
    try:
        with open(f"/proc/{pid}/comm") as f:
            return f.read().strip().startswith("tmux")
    except OSError:
        return False


def _kill_orphans(sock):
    """A server whose socket file is gone cannot be reached by `tmux kill-server`: kill the PID that still holds the name,
    but only a tmux process and only for a socket inside our own temp dirs (`ss` also lists children that inherited the fd)."""
    if not _own_tmux_socket(sock):
        return
    for pid in server_pids(sock):
        if not _is_tmux(pid):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass


def cleanup():
    """Kill our servers, remove their sockets and our dirs. Returns the own names still present."""
    for s in _own_sockets():
        if os.path.exists(s):
            _kill("-S", s)
    for n in _L:
        if not os.path.exists(_sockpath(n)):
            _kill_orphans(_sockpath(n))    # the socket file was deleted but the server may still run
        else:
            _kill("-L", n)
            try:
                os.unlink(_sockpath(n))    # a SIGKILLed server leaves the file behind
            except FileNotFoundError:
                pass
    for f in _files:
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass
    for d in _dirs:
        shutil.rmtree(d, ignore_errors=True)
    return left()


def left():
    return [p for p in _dirs + _files + [_sockpath(n) for n in _L] if os.path.lexists(p)]


def _atexit():
    bad = cleanup()
    if bad:
        print(f"leakcheck: LEAKED {bad}", file=sys.stderr)
        os._exit(97)


def _term(signum, _frame):
    raise SystemExit(128 + signum)


def install():
    global _installed
    if _installed:
        return
    _installed = True
    atexit.register(_atexit)
    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, signal.default_int_handler)
