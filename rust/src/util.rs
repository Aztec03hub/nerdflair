//! Primitives transcribed from bash semantics.
//!
//! Every function here mirrors one bash construct. Where bash behaviour is
//! locale- or error-dependent the mirroring is documented on the function.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// `_vis_len`: expand %b, strip ESC[ .. m runs, count CHARACTERS.
///
/// Note this counts characters, not display columns: a double-width glyph
/// counts as 1. That is what the bash does (`${#out}` under a UTF-8 locale)
/// and the layout maths depends on it, so it is reproduced verbatim.
pub fn vis_len(s: &str) -> usize {
    let b = s.as_bytes();
    let mut i = 0usize;
    let mut n = 0usize;
    while i < b.len() {
        if b[i] == 0x1b && i + 1 < b.len() && b[i + 1] == b'[' {
            // skip to the first 'm' after the introducer (bash: ${s#*m})
            let mut j = i + 2;
            while j < b.len() && b[j] != b'm' {
                j += 1;
            }
            i = if j < b.len() { j + 1 } else { b.len() };
        } else {
            // advance one UTF-8 character
            let ch_len = utf8_len(b[i]);
            i += ch_len;
            n += 1;
        }
    }
    n
}

fn utf8_len(first: u8) -> usize {
    if first < 0x80 {
        1
    } else if first >> 5 == 0b110 {
        2
    } else if first >> 4 == 0b1110 {
        3
    } else if first >> 3 == 0b11110 {
        4
    } else {
        1
    }
}

/// `_sanitize`: strip every backslash.
pub fn sanitize(s: &str) -> String {
    if s.contains('\\') {
        s.chars().filter(|c| *c != '\\').collect()
    } else {
        s.to_string()
    }
}

/// bash `${var:start:len}` (character indexed).
pub fn char_slice(s: &str, start: usize, len: usize) -> String {
    s.chars().skip(start).take(len).collect()
}

/// bash `${var:start}` (character indexed).
pub fn char_from(s: &str, start: usize) -> String {
    s.chars().skip(start).collect()
}

pub fn char_len(s: &str) -> usize {
    s.chars().count()
}

/// `printf "%'d"`.
///
/// glibc only groups when LC_NUMERIC supplies a `thousands_sep`. The C and
/// C.UTF-8 locales do not, so on this machine `%'d` == `%d`. Grouping is
/// applied only when a non-C numeric locale is in effect.
pub fn fmt_num(n: i64) -> String {
    if !numeric_locale_groups() {
        return n.to_string();
    }
    let neg = n < 0;
    let digits = n.unsigned_abs().to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3 + 1);
    let bytes = digits.as_bytes();
    for (i, c) in bytes.iter().enumerate() {
        if i > 0 && (bytes.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(*c as char);
    }
    if neg {
        format!("-{}", out)
    } else {
        out
    }
}

fn numeric_locale_groups() -> bool {
    let loc = std::env::var("LC_ALL")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("LC_NUMERIC").ok().filter(|s| !s.is_empty()))
        .or_else(|| std::env::var("LANG").ok().filter(|s| !s.is_empty()))
        .unwrap_or_default();
    !(loc.is_empty() || loc == "C" || loc == "POSIX" || loc.starts_with("C."))
}

/// POSIX `cksum` CRC value (the first field of cksum's output).
pub fn cksum(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (i, e) in table.iter_mut().enumerate() {
        let mut c = (i as u32) << 24;
        for _ in 0..8 {
            c = if c & 0x8000_0000 != 0 {
                (c << 1) ^ 0x04C1_1DB7
            } else {
                c << 1
            };
        }
        *e = c;
    }
    let mut crc: u32 = 0;
    for &b in data {
        crc = (crc << 8) ^ table[(((crc >> 24) ^ b as u32) & 0xFF) as usize];
    }
    let mut len = data.len() as u64;
    while len > 0 {
        crc = (crc << 8) ^ table[(((crc >> 24) ^ (len & 0xFF) as u32) & 0xFF) as usize];
        len >>= 8;
    }
    !crc
}

/// Outcome of evaluating a bash arithmetic operand that came from JSON.
///
/// `set -u` is active, so an operand that lexes as an IDENTIFIER (`"Learning"`)
/// is dereferenced, found unset, and **kills the shell** — the statusline
/// stops mid-render and the EXIT trap flushes only what was already buffered.
/// An operand that lexes as a malformed NUMBER (`"45.7"`, `"3abc"`) is a plain
/// syntax error: the assignment does not happen and the test is false, but the
/// shell survives. The two must not be conflated.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Ar {
    Val(i64),
    Syntax,
    Fatal,
}

pub fn arith(s: &str) -> Ar {
    let t = s.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\n');
    if t.is_empty() {
        return Ar::Val(0);
    }
    let b = t.as_bytes();
    let mut i = 0;
    let mut neg = false;
    while i < b.len() && (b[i] == b'-' || b[i] == b'+' || b[i] == b'!' || b[i] == b'~') {
        if b[i] == b'-' {
            neg = !neg;
        }
        i += 1;
    }
    if i >= b.len() {
        return Ar::Syntax;
    }
    let c = b[i];
    if c.is_ascii_alphabetic() || c == b'_' {
        // identifier -> dereference -> unset -> set -u aborts the shell
        return Ar::Fatal;
    }
    if !c.is_ascii_digit() {
        return Ar::Syntax;
    }
    let rest = &t[i..];
    let val: i64 = if let Some(h) = rest
        .strip_prefix("0x")
        .or_else(|| rest.strip_prefix("0X"))
    {
        if h.is_empty() || !h.bytes().all(|x| x.is_ascii_hexdigit()) {
            return Ar::Syntax;
        }
        match i64::from_str_radix(h, 16) {
            Ok(v) => v,
            Err(_) => return Ar::Syntax,
        }
    } else if rest.len() > 1 && rest.starts_with('0') {
        if !rest.bytes().all(|x| (b'0'..=b'7').contains(&x)) {
            return Ar::Syntax;
        }
        match i64::from_str_radix(&rest[1..], 8) {
            Ok(v) => v,
            Err(_) => return Ar::Syntax,
        }
    } else {
        if !rest.bytes().all(|x| x.is_ascii_digit()) {
            return Ar::Syntax;
        }
        match rest.parse::<i64>() {
            Ok(v) => v,
            Err(_) => return Ar::Syntax,
        }
    };
    Ar::Val(if neg { -val } else { val })
}

/// bash arithmetic integer parse, ignoring the fatal/syntax distinction.
/// Use only where the operand is known to be internally generated.
pub fn bash_int(s: &str) -> Option<i64> {
    match arith(s) {
        Ar::Val(v) => Some(v),
        _ => None,
    }
}

pub fn epoch_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Seconds since a file's mtime, mirroring `EPOCHSECONDS - stat -c %Y`.
/// A missing file yields `EPOCHSECONDS - 0`, exactly as the bash fallback
/// (`|| echo 0`) does.
///
/// Never negative. Callers all ask "is this older than N", and a NEGATIVE age
/// is younger than every N, so a clock that steps backwards (WSL does this
/// across suspend) or an mtime in the future would freeze every one of them:
/// no session would append to the ledger, and no cooldown or TTL would ever
/// expire again, for as long as real time took to catch up. Treating a
/// future mtime as "infinitely old" instead fails toward doing the work.
pub fn file_age(path: &Path) -> i64 {
    let mtime = std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let age = epoch_secs() - mtime;
    if age < 0 {
        i64::MAX / 4
    } else {
        age
    }
}

/// A JSON string literal, for `--json`. serde_json could do this, but the
/// whole emitter is a dozen lines and this keeps it readable beside them.
pub fn json_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            // Control characters must be escaped, and the segment strings are
            // FULL of them: every colour is an ESC sequence.
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// The visible text of a coloured segment: CSI sequences removed.
pub fn strip_ansi(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c != '\x1b' {
            o.push(c);
            continue;
        }
        if it.peek() == Some(&'[') {
            it.next();
            // A CSI sequence runs to its first final byte, in @..~
            for d in it.by_ref() {
                if ('\x40'..='\x7e').contains(&d) {
                    break;
                }
            }
        }
    }
    o
}

pub fn uid() -> u32 {
    // Cached: it is asked for several times per render (every stamp path), and
    // each uncached call re-reads /proc/self/status (or spawns `id`).
    static UID: std::sync::OnceLock<u32> = std::sync::OnceLock::new();
    *UID.get_or_init(uid_uncached)
}

fn uid_uncached() -> u32 {
    // getuid() cannot fail: no /proc or `id` fallback that could quietly answer 0.
    unsafe { libc::getuid() }
}

/// bash `${v//[^a-zA-Z0-9]/_}`
pub fn slugify(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

/// `IFS=$'\t' read -r a b c ...`: tab is IFS *whitespace*, so leading/trailing
/// runs are ignored and interior runs collapse — empty fields disappear. This
/// is a real behaviour of lib.sh's state read and is reproduced deliberately.
pub fn read_ifs_whitespace(line: &str, n: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(n);
    let trimmed = line.trim_matches('\t');
    if trimmed.is_empty() {
        return vec![String::new(); n];
    }
    let mut fields: Vec<&str> = trimmed.split('\t').filter(|f| !f.is_empty()).collect();
    if fields.len() > n {
        // the last variable soaks up the remainder, separators preserved
        let tail_start = fields
            .iter()
            .take(n - 1)
            .map(|f| f.len())
            .sum::<usize>();
        let _ = tail_start;
        let head: Vec<String> = fields.drain(..n - 1).map(|s| s.to_string()).collect();
        out.extend(head);
        out.push(fields.join("\t"));
    } else {
        out.extend(fields.iter().map(|s| s.to_string()));
        while out.len() < n {
            out.push(String::new());
        }
    }
    out
}

/// `IFS=$'\x1f' read -r ...`: \x1f is not IFS whitespace, so empty fields are
/// preserved. Missing trailing fields become empty strings.
pub fn read_ifs_unit(line: &str, n: usize) -> Vec<String> {
    let line = line.split('\n').next().unwrap_or("");
    let mut parts: Vec<String> = Vec::with_capacity(n);
    let all: Vec<&str> = line.split('\u{1f}').collect();
    for (i, f) in all.iter().enumerate() {
        if i + 1 == n {
            parts.push(all[i..].join("\u{1f}"));
            break;
        }
        if i >= n {
            break;
        }
        parts.push(f.to_string());
    }
    while parts.len() < n {
        parts.push(String::new());
    }
    parts
}

/// GNU `sort -f` under a C/C.UTF-8 collation: fold case, then fall back to a
/// byte comparison of the original line.
pub fn sort_fold(names: &mut [String]) {
    names.sort_by(|a, b| {
        let fa = a.to_uppercase();
        let fb = b.to_uppercase();
        fa.cmp(&fb).then_with(|| a.cmp(b))
    });
}

/// The private per-user directory every renderer cache lives in (never /tmp: it
/// is shared and the names were predictable, so another local user or a stale
/// symlink could redirect a write or plant a cache we then trust).
/// `$NERDFLAIR_CACHE_DIR`, else `$XDG_CACHE_HOME/nerdflair`, else
/// `$HOME/.cache/nerdflair` (the first two must be absolute). Created 0700 under a
/// temporary umask of 077 (the tmux server's 0117 would otherwise mask it) and
/// verified once per process: a real directory, ours, no group/other bits. An
/// existing directory of ours that is too open is tightened to 0700 and the repair
/// logged. None means "no caches this render": every caller computes without them,
/// and the reason is logged under key `cache-dir` (once an hour), with
/// `recovered` when it clears. Twin of lib.sh `_nf_cache_dir`, same wording.
pub fn cache_dir() -> Option<&'static std::path::PathBuf> {
    static DIR: std::sync::OnceLock<Option<std::path::PathBuf>> = std::sync::OnceLock::new();
    DIR.get_or_init(|| {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt};
        // var_os, not var: a non-UTF-8 path is still a path (var() would drop it and fall back silently)
        let env = |k: &str| std::env::var_os(k).filter(|v| !v.is_empty());
        let fail = |dir: &std::path::Path, why: &str| {
            crate::errlog::note("cache-dir", &format!("{} is unusable ({}); caches skipped", dir.display(), why));
            None
        };
        let dir = if let Some(d) = env("NERDFLAIR_CACHE_DIR") {
            let d = std::path::PathBuf::from(d);
            if !d.is_absolute() {
                crate::errlog::note("cache-dir", &format!("NERDFLAIR_CACHE_DIR={} is not an absolute path; caches skipped", d.display()));
                return None;
            }
            d
        } else {
            let xdg = env("XDG_CACHE_HOME");
            match (xdg, env("HOME")) {
                (Some(x), _) if std::path::Path::new(&x).is_absolute() => std::path::PathBuf::from(x).join("nerdflair"),
                (x, h) => {
                    if let Some(x) = x {
                        crate::errlog::note("cache-dir-xdg", &format!("XDG_CACHE_HOME={} is not an absolute path; ignored", x.to_string_lossy()));
                    }
                    match h {
                        Some(h) => std::path::PathBuf::from(h).join(".cache/nerdflair"),
                        None => {
                            crate::errlog::note("cache-dir", "HOME is empty and NERDFLAIR_CACHE_DIR is not set; caches skipped");
                            return None;
                        }
                    }
                }
            }
        };
        // Create what is missing, top down, all 0700, under umask 077 so nothing is ever
        // briefly more open or (umask 0117) unusable. An existing directory is not touched here.
        let mut missing: Vec<&std::path::Path> = dir.ancestors().take_while(|a| std::fs::symlink_metadata(a).is_err()).collect();
        missing.reverse();
        let mut mkerr: Option<String> = None;
        let old = unsafe { libc::umask(0o077) };
        for m in missing {
            if let Err(e) = std::fs::DirBuilder::new().mode(0o700).create(m) {
                // "Permission denied (os error 13)" -> "Permission denied", as mkdir words it
                mkerr = Some(e.to_string().split(" (os error").next().unwrap_or("").to_string());
                break;
            }
        }
        unsafe { libc::umask(old) };
        let m = match std::fs::symlink_metadata(&dir) {
            Ok(m) => m,
            Err(_) => return fail(&dir, &format!("cannot create it: {}", mkerr.unwrap_or_else(|| "No such file or directory".into()))),
        };
        if !m.is_dir() {
            return fail(&dir, "not a real directory");
        }
        if m.uid() != uid() {
            return fail(&dir, "not owned by this user");
        }
        if m.mode() & 0o077 != 0 {
            if std::env::var_os("NERDFLAIR_CACHE_DIR").map_or(false, |v| !v.is_empty()) {
                // An explicit override may name a directory the owner uses for other things
                // (HOME, a project): never narrow it behind their back, say what to do.
                return fail(&dir, &format!("mode allows group/other access; run: chmod 700 {}", shell_quote(&dir.to_string_lossy())));
            }
            // The default location is ours alone: tighten it (never through a symlink).
            if !tighten_dir(&dir) || std::fs::symlink_metadata(&dir).map_or(true, |fm| fm.mode() & 0o077 != 0) {
                return fail(&dir, "mode allows group/other access and chmod 700 failed");
            }
            crate::errlog::note("cache-dir-repaired", &format!("{} had group/other access; tightened to 0700", dir.display()));
        }
        crate::errlog::ok_if_stamped("cache-dir");
        Some(dir)
    })
    .as_ref()
}

pub fn cache_path(name: &str) -> Option<std::path::PathBuf> {
    cache_dir().map(|d| d.join(name))
}

/// Write a cache file without ever following a symlink at the leaf: a fresh
/// O_EXCL|O_NOFOLLOW temp file, then rename (which replaces a planted link).
pub fn cache_write(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt;
    let mut tmp = path.as_os_str().to_owned(); // not display(): that is lossy for a non-UTF-8 HOME
    tmp.push(format!(".tmp.{}", std::process::id()));
    let tmp = std::path::PathBuf::from(tmp);
    let _ = std::fs::remove_file(&tmp);
    let r = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)
        .and_then(|mut f| f.write_all(data))
        .and_then(|_| std::fs::rename(&tmp, path));
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r
}

/// 'single-quoted' for a shell, as lib.sh writes it in the same message.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// chmod 700 a directory that was just checked to be ours, without following a symlink and
/// without needing the read bit (mode 055 has none): an O_PATH fd, fstat'ed, then fchmodat on
/// its /proc/self/fd entry. Other systems have no O_PATH: lstat-checked path chmod instead.
#[cfg(target_os = "linux")]
fn tighten_dir(dir: &std::path::Path) -> bool {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let Ok(f) = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_NOFOLLOW | libc::O_DIRECTORY)
        .open(dir)
    else {
        return false;
    };
    match f.metadata() {
        Ok(m) if m.is_dir() && m.uid() == uid() => {}
        _ => return false,
    }
    let Ok(p) = std::ffi::CString::new(format!("/proc/self/fd/{}", f.as_raw_fd())) else { return false };
    unsafe { libc::fchmodat(libc::AT_FDCWD, p.as_ptr(), 0o700, 0) == 0 }
}
#[cfg(not(target_os = "linux"))]
fn tighten_dir(dir: &std::path::Path) -> bool {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    match std::fs::symlink_metadata(dir) {
        Ok(m) if m.is_dir() && m.uid() == uid() => {}
        _ => return false,
    }
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).is_ok()
}
