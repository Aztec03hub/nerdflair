//! Durable record of every failure the renderer absorbs.
//!
//! Rule (owner): a fallback is fine, but every absorbed failure leaves one
//! log line, with the reason. `note(key, reason)` appends
//! `ISO-time pid key: reason` to `$HOME/.claude/nerdflair-errors.log`, at most
//! once per key per hour (a stamp file whose mtime is the last time the key
//! logged). `ok(key)` logs `recovered: key` once when a keyed condition
//! clears. The bash twin is `_nf_err` in scripts/lib.sh; same file, same line
//! format, same stamp names.
//!
//! The logger never panics, never blocks and takes no lock. Swallowing ITS OWN
//! failure is the one correct `let _ =` in this program: there is nowhere left
//! to report it except stderr, which is tried last.
//!
//! Stamps live in $NERDFLAIR_ERR_STAMP_DIR (default /tmp); the override exists
//! so tests never share rate-limit state with a real session.

use crate::util::{epoch_secs, file_age, slugify, uid};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

const RATE_SECS: i64 = 3600;
const CAP_BYTES: u64 = 256 * 1024;
const KEEP_BYTES: u64 = 64 * 1024;
const MAX_REASON: usize = 400;

pub fn log_path() -> PathBuf {
    // Same rule as state.rs: HOME unset or empty means "/", never a relative path.
    let home = std::env::var("HOME").unwrap_or_default();
    let base = if home.is_empty() { PathBuf::from("/") } else { PathBuf::from(home) };
    base.join(".claude/nerdflair-errors.log")
}

pub fn stamp_path(key: &str) -> PathBuf {
    let dir = std::env::var("NERDFLAIR_ERR_STAMP_DIR")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "/tmp".into());
    let mut slug = slugify(key);
    slug.truncate(100); // slugify output is ASCII
    PathBuf::from(dir).join(format!("nerdflair-err-{}-{}", uid(), slug))
}

/// Days since 1970-01-01 to (y, m, d), proleptic Gregorian (Hinnant).
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + (m <= 2) as i64, m, d)
}

fn iso_now() -> String {
    let t = epoch_secs();
    let (y, m, d) = civil(t.div_euclid(86_400));
    let s = t.rem_euclid(86_400);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, s / 3600, s % 3600 / 60, s % 60)
}

/// Keep the last KEEP_BYTES when the log is over CAP_BYTES. Runs only on the
/// (rate limited) write path, so it costs nothing on a healthy render.
fn trim(path: &PathBuf) {
    let len = match std::fs::metadata(path) {
        Ok(m) => m.len(),
        Err(_) => return,
    };
    if len <= CAP_BYTES {
        return;
    }
    let mut tail = Vec::new();
    let read = std::fs::File::open(path).and_then(|mut f| {
        f.seek(SeekFrom::Start(len - KEEP_BYTES))?;
        f.read_to_end(&mut tail)
    });
    if read.is_err() {
        return;
    }
    // Start at the next whole line.
    let from = tail.iter().position(|&b| b == b'\n').map(|i| i + 1).unwrap_or(0);
    let tmp = path.with_extension(format!("log.tmp.{}", std::process::id()));
    if std::fs::write(&tmp, &tail[from..]).is_ok() {
        if std::fs::rename(&tmp, path).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

fn emit(key: &str, reason: &str) {
    let mut clean: String = reason
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    if clean.len() > MAX_REASON {
        let mut cut = MAX_REASON;
        while !clean.is_char_boundary(cut) {
            cut -= 1;
        }
        clean.truncate(cut);
        clean.push_str("...");
    }
    // One pre-built buffer, one write on an O_APPEND fd, so concurrent
    // renderers cannot interleave inside a line.
    let line = format!("{} {} {}: {}\n", iso_now(), std::process::id(), key, clean);
    let path = log_path();
    trim(&path);
    let wrote = path
        .parent()
        .map(|d| std::fs::create_dir_all(d))
        .unwrap_or(Ok(()))
        .and_then(|_| std::fs::OpenOptions::new().create(true).append(true).open(&path))
        .and_then(|mut f| f.write_all(line.as_bytes()));
    if let Err(e) = wrote {
        // Last resort. Hidden by the host, but better than nothing.
        let _ = writeln!(std::io::stderr(), "nerdflair: cannot write {}: {} | {}", path.display(), e, line.trim_end());
    }
}

/// Create or touch a stamp WITHOUT following a symlink: /tmp is shared and the
/// stamp name is predictable, so a planted symlink must not make us truncate
/// someone else's file. Returns false when it could not be written.
fn write_stamp(path: &PathBuf) -> bool {
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .is_ok()
}

/// Record an absorbed failure, once per key per hour.
pub fn note(key: &str, reason: &str) {
    let stamp = stamp_path(key);
    if stamp.exists() && file_age(&stamp) < RATE_SECS {
        return;
    }
    // Stamp first. If the stamp cannot be written we cannot rate limit, and
    // losing a reason is worse than a repeat, so log regardless.
    // ponytail: two renderers racing at the hour boundary may both log.
    let _ = write_stamp(&stamp); // false only loses the rate limit, never the line
    emit(key, reason);
}

/// A keyed condition that had logged has cleared: say so once.
pub fn ok(key: &str) {
    let stamp = stamp_path(key);
    if stamp.exists() && std::fs::remove_file(&stamp).is_ok() {
        emit("recovered", key);
    }
}

/// True when `key` was touched less than `secs` ago. For retry back-off.
pub fn recent(key: &str, secs: i64) -> bool {
    let stamp = stamp_path(key);
    stamp.exists() && file_age(&stamp) < secs
}

/// Mark `key` now (back-off marker; logs nothing).
pub fn touch(key: &str) {
    let _ = write_stamp(&stamp_path(key)); // failing only loses the back-off
}

/// Drop a back-off marker.
pub fn clear(key: &str) {
    let _ = std::fs::remove_file(stamp_path(key)); // absent is the normal case
}

/// `note` for an io::Error with its kind, so the log shows the class.
pub fn note_io(key: &str, what: &str, e: &std::io::Error) {
    note(key, &format!("{}: {} ({:?})", what, e, e.kind()));
}

/// Install the panic hook: log message and location, leave stdout alone.
pub fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        let msg = if let Some(s) = info.payload().downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "non-string panic payload".to_string()
        };
        let loc = info
            .location()
            .map(|l| format!("{}:{}", l.file(), l.line()))
            .unwrap_or_else(|| "unknown".into());
        note("panic", &format!("{} at {}", msg, loc));
    }));
}
