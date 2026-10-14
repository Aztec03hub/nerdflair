//! Subprocess helpers. Every git invocation matches the bash flag-for-flag.

use crate::errlog;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Wall-clock limit for one child. A git on a hung network filesystem would
/// otherwise block the renderer until the host kills it, leaving no trace.
/// NERDFLAIR_PROC_TIMEOUT_MS overrides (tests use it).
const DEFAULT_TIMEOUT_MS: u64 = 10_000;

fn timeout() -> Duration {
    let ms = std::env::var("NERDFLAIR_PROC_TIMEOUT_MS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(DEFAULT_TIMEOUT_MS);
    Duration::from_millis(ms)
}

fn drain<R: Read + Send + 'static>(h: Option<R>, what: &'static str) -> thread::JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut v = Vec::new();
        if let Some(mut h) = h {
            if let Err(e) = h.read_to_end(&mut v) {
                errlog::note_io("pipe-read", what, &e);
            }
        }
        v
    })
}

/// Run `prog`, returning stdout and success. Failures that are always
/// unexpected (cannot spawn, timeout) are logged here, once, for every caller.
/// `chk = Some((label, quiet))` also logs a non-zero exit with the first line
/// of stderr, unless stderr contains one of the `quiet` substrings (the
/// documented "this just means no" answers, such as "not a git repository").
static TIMED_OUT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn run(
    prog: &str,
    args: &[&str],
    dir: Option<&Path>,
    chk: Option<(&str, &[&str])>,
) -> (Vec<u8>, bool) {
    // After one timeout this render, do not wait another full timeout for the next
    // call (a hung filesystem makes every git call hang): already logged once.
    if TIMED_OUT.load(std::sync::atomic::Ordering::Relaxed) && prog == "git" {
        return (Vec::new(), false);
    }
    let mut c = Command::new(prog);
    c.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(d) = dir {
        c.current_dir(d);
    }
    let mut child = match c.spawn() {
        Ok(ch) => ch,
        Err(e) => {
            errlog::note_io(&format!("spawn:{}", prog), &format!("cannot run {}", prog), &e);
            return (Vec::new(), false);
        }
    };
    let so = drain(child.stdout.take(), "stdout");
    let se = drain(child.stderr.take(), "stderr");
    let limit = timeout();
    let start = Instant::now();
    let label = chk.map(|c| c.0).unwrap_or(prog);
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) => {
                if start.elapsed() >= limit {
                    // Log FIRST: reaping can itself hang on a process stuck in
                    // uninterruptible I/O, and the line must not wait on that.
                    errlog::note(
                        &format!("timeout:{}", label),
                        &format!("{} {:?} still running after {} ms, killed; no more {} this render", prog, args, limit.as_millis(), prog),
                    );
                    TIMED_OUT.store(true, std::sync::atomic::Ordering::Relaxed);
                    let _ = child.kill();
                    // Bounded reap (about 200 ms): never block the render on a stuck child.
                    for _ in 0..200 {
                        if matches!(child.try_wait(), Ok(Some(_))) {
                            break;
                        }
                        thread::sleep(Duration::from_millis(1));
                    }
                    // Not joined: a grandchild may still hold the pipes open.
                    return (Vec::new(), false);
                }
                thread::sleep(Duration::from_micros(300));
            }
            Err(e) => {
                errlog::note_io(&format!("wait:{}", prog), &format!("waiting for {}", prog), &e);
                return (Vec::new(), false);
            }
        }
    };
    let stdout = so.join().unwrap_or_default();
    let stderr = se.join().unwrap_or_default();
    if !status.success() {
        if let Some((label, quiet)) = chk {
            let text = String::from_utf8_lossy(&stderr);
            if !quiet.iter().any(|q| text.contains(q)) {
                let code = status.code().map(|c| c.to_string()).unwrap_or_else(|| "signal".into());
                errlog::note(
                    &format!("{}:{}", label, code),
                    &format!("{} {:?} failed: {}", prog, args, text.lines().next().unwrap_or("(no stderr)")),
                );
            }
        }
    }
    (stdout, status.success())
}

fn strip_nl(b: Vec<u8>) -> String {
    let mut s = String::from_utf8_lossy(&b).into_owned();
    while s.ends_with('\n') {
        s.pop();
    }
    s
}

/// `$(cmd)` - stdout with all trailing newlines stripped, plus success flag.
/// A non-zero exit is NOT logged: use for probes whose failure means "no".
pub fn out(prog: &str, args: &[&str], dir: Option<&Path>) -> (String, bool) {
    let (o, ok) = run(prog, args, dir, None);
    (strip_nl(o), ok)
}

/// `out` for a command that is expected to succeed: a non-zero exit logs
/// `label:<code>` with stderr's first line, except for `quiet` answers.
pub fn out_chk(
    prog: &str,
    args: &[&str],
    dir: Option<&Path>,
    label: &str,
    quiet: &[&str],
) -> (String, bool) {
    let (o, ok) = run(prog, args, dir, Some((label, quiet)));
    (strip_nl(o), ok)
}

/// Raw stdout, newlines intact (for line counting). Always checked.
pub fn out_raw_chk(
    prog: &str,
    args: &[&str],
    dir: Option<&Path>,
    label: &str,
    quiet: &[&str],
) -> (String, bool) {
    let (o, ok) = run(prog, args, dir, Some((label, quiet)));
    (String::from_utf8_lossy(&o).into_owned(), ok)
}

/// `command -v <name>`
pub fn which(name: &str) -> Option<PathBuf> {
    if name.contains('/') {
        let p = PathBuf::from(name);
        return if is_exec(&p) { Some(p) } else { None };
    }
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let cand = dir.join(name);
        if is_exec(&cand) {
            return Some(cand);
        }
    }
    None
}

pub fn is_exec(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}
