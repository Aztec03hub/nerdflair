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
//! Stamps live in a private directory under ~/.claude (see stamp_dir);
//! $NERDFLAIR_ERR_STAMP_DIR overrides it so tests never share rate-limit state
//! with a real session.

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

/// Where rate-limit stamps live. NOT /tmp: it is shared, the names are
/// predictable, and another user could plant a file or symlink there to silence
/// a key or make us truncate something of theirs. A private 0700 directory
/// under the user's own ~/.claude, verified (a real directory, ours, mode 0700)
/// on first use. None when it cannot be made safe: the caller then rate limits
/// in memory only (once per process) instead of trusting a hostile directory.
/// NERDFLAIR_ERR_STAMP_DIR overrides it (tests; trusted).
fn stamp_dir() -> Option<&'static PathBuf> {
    static DIR: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();
    DIR.get_or_init(|| {
        if let Some(d) = std::env::var("NERDFLAIR_ERR_STAMP_DIR").ok().filter(|d| !d.is_empty()) {
            return Some(PathBuf::from(d));
        }
        let dir = log_path().parent()?.join(".nerdflair-stamps");
        use std::os::unix::fs::{DirBuilderExt, MetadataExt};
        let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir);
        let m = std::fs::symlink_metadata(&dir).ok()?;
        if m.is_dir() && m.uid() == uid() && m.mode() & 0o077 == 0 {
            Some(dir)
        } else {
            None
        }
    })
    .as_ref()
}

pub fn stamp_path(key: &str) -> Option<PathBuf> {
    let mut slug = slugify(key);
    slug.truncate(100); // slugify output is ASCII
    Some(stamp_dir()?.join(format!("nerdflair-err-{}-{}", uid(), slug)))
}

/// Key for a failed write to a /tmp cache or stamp file: the file name is part
/// of the key, so two different files failing in the same hour both log.
pub fn tmp_key(p: &std::path::Path) -> String {
    format!("tmp-write:{}", p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default())
}

fn mem_seen(key: &str) -> bool {
    use std::sync::{Mutex, OnceLock};
    static SEEN: OnceLock<Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    match SEEN.get_or_init(Default::default).lock() {
        Ok(mut g) => !g.insert(key.to_string()),
        Err(_) => false,
    }
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

fn emit(key: &str, reason: &str) -> bool {
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
        return false;
    }
    true
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

/// Record an absorbed failure, once per key per hour (and once per process
/// whatever the stamp says, so an unwritable stamp directory cannot make a
/// render log the same thing twice).
pub fn note(key: &str, reason: &str) {
    if mem_seen(key) {
        return;
    }
    let stamp = stamp_path(key);
    if let Some(st) = &stamp {
        if st.exists() && file_age(st) < RATE_SECS {
            return;
        }
    }
    // Log first, stamp after: a failed append must not silence the key for an
    // hour. ponytail: two renderers racing at the hour boundary may both log.
    if emit(key, reason) {
        if let Some(st) = &stamp {
            let _ = write_stamp(st); // false only loses the rate limit
        }
    }
}

/// A keyed condition that had logged has cleared: say so, once per failure
/// line. The failure stamp is KEPT (so a condition that flaps is still limited
/// to one failure line an hour); a second stamp records that the recovery was
/// already reported for it.
pub fn ok(key: &str) {
    let (Some(fail), Some(rec)) = (stamp_path(key), stamp_path(&format!("recovered-{}", key))) else {
        return;
    };
    if !fail.exists() {
        return;
    }
    let age = file_age(&fail);
    if age >= RATE_SECS {
        let _ = std::fs::remove_file(&fail); // stale: nothing recent to recover from
        let _ = std::fs::remove_file(&rec);
        return;
    }
    // Report only if no recovery line is newer than the failure line.
    if rec.exists() && file_age(&rec) <= age {
        return;
    }
    if emit("recovered", key) {
        let _ = write_stamp(&rec);
    }
}

/// True when `key` was touched less than `secs` ago. For retry back-off.
pub fn recent(key: &str, secs: i64) -> bool {
    match stamp_path(key) {
        Some(st) => st.exists() && file_age(&st) < secs,
        None => false,
    }
}

/// Mark `key` now (back-off marker; logs nothing).
pub fn touch(key: &str) {
    if let Some(st) = stamp_path(key) {
        let _ = write_stamp(&st); // failing only loses the back-off
    }
}

/// Drop a back-off marker.
pub fn clear(key: &str) {
    if let Some(st) = stamp_path(key) {
        let _ = std::fs::remove_file(&st); // absent is the normal case
    }
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
