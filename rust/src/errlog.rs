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
/// The default stamp directory, as a path only (nothing created or checked).
fn stamp_dir_path() -> Option<PathBuf> {
    Some(log_path().parent()?.join(".nerdflair-stamps"))
}

/// File name of a key's stamp (shared by stamp_path and ok_if_stamped).
fn stamp_name(key: &str) -> String {
    let mut slug = slugify(key);
    slug.truncate(100); // slugify output is ASCII
    format!("nerdflair-err-{}-{}", uid(), slug)
}

fn stamp_dir() -> Option<&'static PathBuf> {
    static DIR: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();
    DIR.get_or_init(|| {
        if let Some(d) = std::env::var_os("NERDFLAIR_ERR_STAMP_DIR").filter(|d| !d.is_empty()) {
            return Some(PathBuf::from(d));
        }
        let dir = stamp_dir_path()?;
        use std::os::unix::fs::{DirBuilderExt, MetadataExt};
        let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir);
        let m = match std::fs::symlink_metadata(&dir) {
            Ok(m) => m,
            Err(e) => {
                stamp_dir_bad(&dir, &e.to_string());
                return None;
            }
        };
        if !(m.is_dir() && m.uid() == uid()) {
            // a symlink, a file, or someone else's directory: not ours to trust
            stamp_dir_bad(&dir, "not a real directory owned by this user");
            return None;
        }
        if m.mode() & 0o077 != 0 {
            // Ours but lax (an old umask): tighten it rather than reject it, or stamps
            // would never work and every render would log every key again.
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        }
        Some(dir)
    })
    .as_ref()
}

/// The stamp directory cannot be trusted, so every back-off and rate limit is
/// per-process only. Say so, once an hour. Written DIRECTLY (emit + a marker
/// file in ~/.claude, O_NOFOLLOW): note() would call stamp_dir() from inside its
/// own OnceLock initialiser and deadlock. Twin of lib.sh `_nf_stamp_dir`.
fn stamp_dir_bad(dir: &std::path::Path, why: &str) {
    let marker = dir.with_file_name(".nerdflair-stamp-dir-bad");
    // A symlink marker can never be written (O_NOFOLLOW), so it cannot rate limit: it counts as
    // "not recent" and the line is logged once per render, the honest outcome. exists() would
    // call a dangling link absent.
    match std::fs::symlink_metadata(&marker) {
        Ok(m) if !m.file_type().is_symlink() && file_age(&marker) < RATE_SECS => return,
        _ => {}
    }
    emit("stamp-dir", &format!("{} is unusable ({}); rate limits and back-offs work per render only", dir.display(), why));
    let _ = write_stamp(&marker); // failing only loses the hourly limit
}

pub fn stamp_path(key: &str) -> Option<PathBuf> {
    Some(stamp_dir()?.join(stamp_name(key)))
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
        Err(e) => {
            // A log that does not exist yet is normal.
            static WARNED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
            if e.kind() != std::io::ErrorKind::NotFound && !WARNED.swap(true, std::sync::atomic::Ordering::Relaxed) {
                let _ = writeln!(std::io::stderr(), "nerdflair: cannot stat {} to trim it: {}", path.display(), e);
            }
            return;
        }
    };
    if len <= CAP_BYTES {
        return;
    }
    let mut tail = Vec::new();
    let read = std::fs::File::open(path).and_then(|mut f| {
        f.seek(SeekFrom::Start(len - KEEP_BYTES))?;
        f.read_to_end(&mut tail)
    });
    if let Err(e) = read {
        let _ = writeln!(std::io::stderr(), "nerdflair: cannot read {} to trim it: {}", path.display(), e);
        return;
    }
    // Start at the next whole line.
    let from = tail.iter().position(|&b| b == b'\n').map(|i| i + 1).unwrap_or(0);
    let tmp = path.with_extension(format!("log.tmp.{}", std::process::id()));
    match std::fs::write(&tmp, &tail[from..]) {
        Ok(()) => {
            if let Err(e) = std::fs::rename(&tmp, path) {
                let _ = writeln!(std::io::stderr(), "nerdflair: cannot replace {} with its trimmed copy: {}", path.display(), e);
                let _ = std::fs::remove_file(&tmp);
            }
        }
        Err(e) => {
            let _ = writeln!(std::io::stderr(), "nerdflair: cannot write {} to trim the log: {}", tmp.display(), e);
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

fn emit(key: &str, reason: &str) -> bool {
    emit_bytes(key, reason.as_bytes())
}

/// Bytes that are safe to put in the log: C0, DEL and C1 controls (U+0080..U+009F, which a
/// terminal may act on as CSI, OSC, DCS) become a space. In text that is not valid UTF-8, a
/// raw 0x80..0x9f byte outside a valid character does too (valid characters are kept whole).
/// Twin of lib.sh `_nf_sanitize`.
fn clean(reason: &[u8]) -> Vec<u8> {
    let mut v: Vec<u8> = Vec::with_capacity(reason.len());
    for ch in reason.utf8_chunks() {
        for c in ch.valid().chars() {
            if c.is_control() {
                v.push(b' ');
            } else {
                let mut buf = [0u8; 4];
                v.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
            }
        }
        v.extend(ch.invalid().iter().map(|&b| if (0x80..=0x9f).contains(&b) { b' ' } else { b }));
    }
    v
}

/// `clean`, then cut to MAX_REASON bytes at a character boundary (never a partial sequence
/// before the "..."). What a log line's reason is, byte for byte; lib.sh `_nf_log_line` is its twin.
pub(crate) fn sanitize_reason(reason: &[u8]) -> Vec<u8> {
    let mut v = clean(reason);
    if v.len() > MAX_REASON {
        let mut cut = MAX_REASON;
        while cut > 0 && (0x80..=0xbf).contains(&v[cut]) {
            cut -= 1;
        }
        v.truncate(cut);
        v.extend_from_slice(b"...");
    }
    v
}

/// `emit` for a reason that may hold a non-UTF-8 path: the bytes reach the log untouched
/// (as the bash twin writes them), only control characters become spaces. The key is filtered
/// the same way, so a future key built from user text cannot bypass it.
fn emit_bytes(key: &str, reason: &[u8]) -> bool {
    let clean_reason = sanitize_reason(reason);
    // One pre-built buffer, one write on an O_APPEND fd, so concurrent
    // renderers cannot interleave inside a line.
    let mut line = format!("{} {} ", iso_now(), std::process::id()).into_bytes();
    line.extend_from_slice(&clean(key.as_bytes()));
    line.extend_from_slice(b": ");
    line.extend_from_slice(&clean_reason);
    line.push(b'\n');
    let path = log_path();
    trim(&path);
    let wrote = path
        .parent()
        .map(|d| std::fs::create_dir_all(d))
        .unwrap_or(Ok(()))
        .and_then(|_| std::fs::OpenOptions::new().create(true).append(true).open(&path))
        .and_then(|mut f| f.write_all(&line));
    if let Err(e) = wrote {
        // Last resort. Hidden by the host, but better than nothing.
        let _ = writeln!(std::io::stderr(), "nerdflair: cannot write {}: {} | {}", path.display(), e, String::from_utf8_lossy(&line).trim_end());
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
    note_bytes(key, reason.as_bytes())
}

/// `note` with a reason that may contain a non-UTF-8 path.
pub fn note_bytes(key: &str, reason: &[u8]) {
    if mem_seen(key) {
        return;
    }
    let stamp = stamp_path(key);
    if let Some(st) = &stamp {
        if st.exists() && file_age(st) < RATE_SECS {
            return;
        }
    }
    // Log, then stamp whether or not the append worked: an unwritable log would
    // otherwise make EVERY render retry and write to stderr. (The reason still
    // reached stderr once, which is the last resort.)
    // ponytail: two renderers racing at the hour boundary may both log.
    emit_bytes(key, reason);
    if let Some(st) = &stamp {
        let _ = write_stamp(st); // false only loses the rate limit
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
    if age >= 7 * 86_400 {
        let _ = std::fs::remove_file(&fail); // a week old: long forgotten, say nothing
        let _ = std::fs::remove_file(&rec);
        return;
    }
    // Report only if no recovery line is newer than the failure line.
    if rec.exists() && file_age(&rec) <= age {
        return;
    }
    emit("recovered", key);
    let _ = write_stamp(&rec);
}

/// `ok(key)` for a hot path: does nothing (and creates nothing) unless the key's failure
/// stamp already exists, so a healthy render never touches the stamp directory.
pub fn ok_if_stamped(key: &str) {
    let dir = match std::env::var_os("NERDFLAIR_ERR_STAMP_DIR").filter(|d| !d.is_empty()) {
        Some(d) => PathBuf::from(d),
        None => match stamp_dir_path() {
            Some(p) => p,
            None => return,
        },
    };
    let mtime = |p: &PathBuf| std::fs::metadata(p).and_then(|m| m.modified());
    // Healthy and never failed: ONE stat (the failure stamp is absent) and out.
    let Ok(f) = mtime(&dir.join(stamp_name(key))) else { return };
    match mtime(&dir.join(stamp_name(&format!("recovered-{}", key)))) {
        Ok(r) if r >= f => {} // already reported as recovered: nothing to do
        _ => ok(key),
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

#[cfg(test)]
mod tests {
    /// Feeds tests/log-sanitizers.sh: with NF_SAN_IN (lines of hex) and NF_SAN_OUT set it writes
    /// the sanitized reason, as hex, per line; without them it does nothing.
    #[test]
    fn sanitizer_table() {
        let (Some(i), Some(o)) = (std::env::var_os("NF_SAN_IN"), std::env::var_os("NF_SAN_OUT")) else { return };
        let unhex = |s: &str| (0..s.len() / 2).map(|k| u8::from_str_radix(&s[2 * k..2 * k + 2], 16).unwrap()).collect::<Vec<u8>>();
        let out: String = std::fs::read_to_string(i)
            .unwrap()
            .lines()
            .map(|l| super::sanitize_reason(&unhex(l)).iter().map(|b| format!("{:02x}", b)).collect::<String>() + "\n")
            .collect();
        std::fs::write(o, out).unwrap();
    }
}
