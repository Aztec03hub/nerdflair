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
pub fn file_age(path: &Path) -> i64 {
    let mtime = std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    epoch_secs() - mtime
}

pub fn uid() -> u32 {
    // Avoids a libc dependency for one getuid().
    if let Ok(s) = std::fs::read_to_string("/proc/self/status") {
        for line in s.lines() {
            if let Some(rest) = line.strip_prefix("Uid:") {
                if let Some(first) = rest.split_whitespace().next() {
                    if let Ok(v) = first.parse::<u32>() {
                        return v;
                    }
                }
            }
        }
    }
    match std::process::Command::new("id").arg("-u").output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout).trim().parse().unwrap_or(0),
        Err(_) => 0,
    }
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
