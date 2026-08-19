//! Subprocess helpers. Every git invocation matches the bash flag-for-flag.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// `$(cmd)` — stdout with all trailing newlines stripped, plus success flag.
pub fn out(prog: &str, args: &[&str], dir: Option<&Path>) -> (String, bool) {
    let mut c = Command::new(prog);
    c.args(args).stdin(Stdio::null()).stderr(Stdio::null());
    if let Some(d) = dir {
        c.current_dir(d);
    }
    match c.output() {
        Ok(o) => {
            let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
            while s.ends_with('\n') {
                s.pop();
            }
            (s, o.status.success())
        }
        Err(_) => (String::new(), false),
    }
}

/// Raw stdout, newlines intact (for line counting).
pub fn out_raw(prog: &str, args: &[&str], dir: Option<&Path>) -> (String, bool) {
    let mut c = Command::new(prog);
    c.args(args).stdin(Stdio::null()).stderr(Stdio::null());
    if let Some(d) = dir {
        c.current_dir(d);
    }
    match c.output() {
        Ok(o) => (
            String::from_utf8_lossy(&o.stdout).into_owned(),
            o.status.success(),
        ),
        Err(_) => (String::new(), false),
    }
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

/// Fork a detached background job, exactly as `( ... ) &; disown` does.
/// Never waited on: the render must not block on it.
pub fn spawn_detached(script: &str, stdin_data: Option<&str>) {
    let mut c = Command::new("sh");
    c.arg("-c")
        .arg(script)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    match stdin_data {
        Some(_) => {
            c.stdin(Stdio::piped());
        }
        None => {
            c.stdin(Stdio::null());
        }
    }
    if let Ok(mut child) = c.spawn() {
        if let (Some(data), Some(mut si)) = (stdin_data, child.stdin.take()) {
            use std::io::Write;
            let _ = si.write_all(data.as_bytes());
        }
        // Deliberately not waited on; the child is reparented at exit.
    }
}
