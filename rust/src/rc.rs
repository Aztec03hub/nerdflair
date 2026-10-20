//! Remote Control readout for the main status line.
//!
//! The band plugin owns the truth (Claude Code maintains
//! CLAUDE_CODE_BRIDGE_SESSION_ID in its own process, and only a child spawned
//! fresh sees the current value), so the plugin runs `--rc-sync` on a timer. That
//! writes one line into the private cache dir, `rc-<slug of session id>`:
//!
//!     v1 on|off|unknown <since-epoch> <label>
//!
//! and the renderer, which has no way to ask Claude Code anything, only reads it.
//! Twin of the rc block in statusline.sh; same grammar, same wording.
//!
//! No file at all = the plugin is not loaded: show nothing, invent nothing.
//! A corrupt file, or an "on" nobody has refreshed for 120 s (the plugin writes
//! at least every 30 s), is shown as UNKNOWN (amber) and logged once.

use crate::colors::RESET;
use crate::errlog;
use crate::util::*;
use std::path::Path;

const STALE_SECS: i64 = 120;
const REFRESH_SECS: i64 = 30;
const GREEN: &str = "\x1b[38;2;74;222;128m"; // #4ade80
const OFF: &str = "\x1b[38;2;75;85;99m"; // #4b5563
const AMBER: &str = "\x1b[38;2;251;191;36m"; // #fbbf24

#[derive(Clone, Copy, PartialEq)]
enum St {
    On,
    Off,
    Unknown,
}

impl St {
    fn word(self) -> &'static str {
        match self {
            St::On => "on",
            St::Off => "off",
            St::Unknown => "unknown",
        }
    }
}

struct Rec {
    state: St,
    since: i64,
    label: String,
}

/// A label is what the plugin calls the surface: letters, digits, space and `+._-`, at most 24.
fn label_ok(s: &str) -> bool {
    s.len() <= 24 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b" +._-".contains(&b))
}

fn parse(line: &str) -> Option<Rec> {
    let rest = line.strip_prefix("v1 ")?;
    let (state, rest) = rest.split_once(' ')?;
    let state = match state {
        "on" => St::On,
        "off" => St::Off,
        "unknown" => St::Unknown,
        _ => return None,
    };
    let (since, label) = rest.split_once(' ').unwrap_or((rest, ""));
    if !(1..=15).contains(&since.len()) || !since.bytes().all(|b| b.is_ascii_digit()) || !label_ok(label) {
        return None;
    }
    Some(Rec { state, since: since.parse().ok()?, label: label.to_string() })
}

fn path_for(session: &str) -> Option<std::path::PathBuf> {
    cache_path(&format!("rc-{}", slugify(session)))
}

fn draw(state: St, label: &str) -> String {
    let (color, glyph, text) = match state {
        St::On => (GREEN, "\u{2b24}", if label.is_empty() { "on" } else { label }),
        St::Off => (OFF, "\u{25ef}", if label.is_empty() { "off" } else { label }),
        St::Unknown => (AMBER, "?", "unknown"),
    };
    format!("{}{} RC {}{}", color, glyph, text, RESET)
}

/// The segment for this session, or "" when there is nothing to say.
pub fn segment(session: &str) -> String {
    if session.is_empty() {
        return String::new();
    }
    let Some(p) = path_for(session) else { return String::new() };
    let text = match std::fs::read(&p) {
        Ok(b) => String::from_utf8_lossy(&b).into_owned(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return String::new(),
        Err(e) => {
            errlog::note_io("rc", &format!("cannot read {}; remote control state unknown", p.display()), &e);
            return draw(St::Unknown, "");
        }
    };
    let Some(rec) = parse(text.split('\n').next().unwrap_or("")) else {
        errlog::note("rc", &format!("{} is corrupt; remote control state unknown", p.display()));
        return draw(St::Unknown, "");
    };
    if rec.state == St::On && file_age(&p) > STALE_SECS {
        errlog::note("rc-stale", &format!("{} is over {} s old while on; the band plugin is not refreshing it, remote control state unknown", p.display(), STALE_SECS));
        return draw(St::Unknown, "");
    }
    draw(rec.state, &rec.label)
}

fn debug_on() -> bool {
    if std::env::var("NERDFLAIR_BAND_DEBUG").map_or(false, |v| !v.is_empty() && v != "0") {
        return true;
    }
    let flag = match std::env::var_os("NERDFLAIR_BAND_DEBUG_FILE").filter(|v| !v.is_empty()) {
        Some(f) => std::path::PathBuf::from(f),
        None => crate::state::state_file().with_file_name("band-debug"),
    };
    flag.exists()
}

/// `--rc-sync <session id> [label]`: what the plugin calls. Reads the bridge from
/// OUR environment (inherited from Claude Code on this very spawn), writes the rc
/// file when the state or label changed or it is over 30 s old, and prints
/// `debug=1` or `debug=0` (whether the band row is to be drawn).
pub fn sync(args: &[String]) -> i32 {
    let sid = args.first().map(String::as_str).unwrap_or("");
    if sid.is_empty() {
        eprintln!("rc-sync: no session id");
        return 2;
    }
    let Some(p) = path_for(sid) else {
        eprintln!("rc-sync: no usable cache directory (see the nerdflair error log)");
        return 3;
    };
    let state = if std::env::var("CLAUDE_CODE_BRIDGE_SESSION_ID").map_or(false, |v| !v.is_empty()) { St::On } else { St::Off };
    let label: String = args
        .get(1)
        .map(String::as_str)
        .unwrap_or("")
        .chars()
        .map(|c| if c.is_ascii() && label_ok(&c.to_string()) { c } else { '_' })
        .take(24)
        .collect::<String>()
        .trim()
        .to_string();
    let old = std::fs::read(&p).ok().and_then(|b| parse(String::from_utf8_lossy(&b).split('\n').next().unwrap_or("")));
    let same = old.as_ref().map_or(false, |o| o.state == state && o.label == label);
    if !(same && file_age(&p) < REFRESH_SECS) {
        let now = epoch_secs();
        let since = old.as_ref().filter(|o| o.state == state).map_or(now, |o| o.since);
        let line = format!("v1 {} {} {}\n", state.word(), since, label);
        if let Err(e) = cache_write(&p, line.as_bytes()) {
            eprintln!("rc-sync: cannot write {}: {}", Path::new(&p).display(), e);
            return 4;
        }
    }
    println!("debug={}", if debug_on() { 1 } else { 0 });
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_grammar_and_nothing_looser() {
        let r = parse("v1 on 1700000000 web+mobile").unwrap();
        assert!(r.state == St::On && r.since == 1700000000 && r.label == "web+mobile");
        assert!(parse("v1 off 5").unwrap().label.is_empty());
        assert!(parse("v1 unknown 5 ").is_some(), "an empty label after the space is fine");
        for bad in ["", "v2 on 5", "v1 maybe 5", "v1 on", "v1 on x", "v1 on 1234567890123456", "v1 on 5 we$b", "v1 on 5 abcdefghijklmnopqrstuvwxyz", "v1  on 5", "v1 on  5"] {
            assert!(parse(bad).is_none(), "{bad:?} must be corrupt");
        }
    }

    #[test]
    fn draws_each_state_in_its_colour() {
        assert_eq!(draw(St::On, "web"), format!("{}\u{2b24} RC web{}", GREEN, RESET));
        assert_eq!(draw(St::On, ""), format!("{}\u{2b24} RC on{}", GREEN, RESET));
        assert_eq!(draw(St::Off, ""), format!("{}\u{25ef} RC off{}", OFF, RESET));
        assert_eq!(draw(St::Unknown, "web"), format!("{}? RC unknown{}", AMBER, RESET));
    }
}
