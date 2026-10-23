//! lib.sh state handling, including its legacy migrations and its
//! field-collapsing read bug (see `read_ifs_whitespace`).

use crate::errlog;
use crate::jqx;
use serde_json::Value;
use std::path::{Path, PathBuf};

pub const DEFAULT_MODE: &str = "full";
pub const DEFAULT_WIDTH: &str = "auto";
pub const DEFAULT_COLOR: &str = "vibrant";
pub const DEFAULT_TERMINAL_BELL: &str = "on";
pub const DEFAULT_CHIME_SOUND: &str = "Glass";
pub const DEFAULT_CHIME_STYLE: &str = "random";
pub const DEFAULT_CHIME_EVENTS: &str =
    "Notification,PermissionRequest,PreCompact,SessionEnd,SessionStart,Stop";
pub const DEFAULT_CHIME_VOLUME: &str = "1";

#[derive(Default, Debug)]
pub struct State {
    pub mode: String,
    pub width: String,
    pub color: String,
    pub terminal_bell: String,
    pub chime_sound: String,
    pub chime_style: String,
    pub chime_events: String,
    pub chime_volume: String,
    pub last_session: String,
    pub spinner_verbs: String,
}

pub fn state_file() -> PathBuf {
    // The bash renderer builds "$HOME/.claude/..." and so, with HOME unset or
    // empty, "/.claude/...". An empty PathBuf would instead join to a path
    // RELATIVE to the working directory and litter whatever repo it ran in.
    let home = std::env::var("HOME").unwrap_or_default();
    let base = if home.is_empty() { PathBuf::from("/") } else { PathBuf::from(home) };
    base.join(".claude/nerdflair/state.json")
}

pub fn read_state(path: &Path) -> State {
    let mut vals = vec![String::new(); 14];
    // Missing file = first run, defaults are correct and silent. A file that
    // EXISTS but cannot be read or parsed also degrades to defaults (the
    // user's settings silently revert), so that case is logged.
    if path.is_file() {
        match std::fs::read_to_string(path) {
            Err(e) => errlog::note_io("state-corrupt", &format!("cannot read {}; using defaults", path.display()), &e),
            Ok(text) => match serde_json::from_str::<Value>(&text) {
                Err(e) => errlog::note(
                    "state-corrupt",
                    &format!("{} is not valid JSON ({}); using defaults", path.display(), e),
                ),
                Ok(v) => {
                let keys = [
                    "mode",
                    "width",
                    "color",
                    "terminal_bell",
                    "chime_sound",
                    "chime_style",
                    "chime_events",
                    "chime_volume",
                    "last_session",
                    "spinner_verbs",
                    "bell",
                    "audio_style",
                    "audio_events",
                    "bell_volume",
                ];
                let mut ok = true;
                let mut fields = Vec::with_capacity(14);
                for k in keys {
                    match jqx::path(&v, &[k]) {
                        Ok(node) => fields.push(jqx::alt_str(node)),
                        Err(_) => {
                            ok = false;
                            break;
                        }
                    }
                }
                if ok {
                    // `IFS=$'\x1f' read -r` (upstream 89c0af3): a non-whitespace
                    // separator keeps empty fields in place; read stops at the
                    // first newline.
                    let joined = fields.join("\u{1f}");
                    let line = joined.split('\n').next().unwrap_or("");
                    let mut it = line.split('\u{1f}').map(String::from);
                    vals = (0..14).map(|_| it.next().unwrap_or_default()).collect();
                    errlog::ok("state-corrupt");
                } else {
                    errlog::note(
                        "state-corrupt",
                        &format!("{} is JSON but not an object; using defaults", path.display()),
                    );
                }
                }
            },
        }
    }

    let mut s = State {
        mode: vals[0].clone(),
        width: vals[1].clone(),
        color: vals[2].clone(),
        terminal_bell: vals[3].clone(),
        chime_sound: vals[4].clone(),
        chime_style: vals[5].clone(),
        chime_events: vals[6].clone(),
        chime_volume: vals[7].clone(),
        last_session: vals[8].clone(),
        spinner_verbs: vals[9].clone(),
    };
    let old_bell = &vals[10];
    let old_audio_style = &vals[11];
    let old_audio_events = &vals[12];
    let old_bell_volume = &vals[13];

    if s.mode.is_empty() {
        s.mode = DEFAULT_MODE.into();
    }
    if s.width.is_empty() {
        s.width = DEFAULT_WIDTH.into();
    }
    if s.color.is_empty() {
        s.color = DEFAULT_COLOR.into();
    }
    if s.chime_sound.is_empty() {
        s.chime_sound = DEFAULT_CHIME_SOUND.into();
    }
    if s.color == "default" {
        s.color = "vibrant".into();
    }
    if s.terminal_bell.is_empty() && !old_bell.is_empty() {
        match old_bell.as_str() {
            "both" => s.terminal_bell = "on".into(),
            "visual" => {
                s.terminal_bell = "on".into();
                s.chime_volume = "0".into();
            }
            "audio" => s.terminal_bell = "off".into(),
            "off" => {
                s.terminal_bell = "off".into();
                s.chime_volume = "0".into();
            }
            _ => {}
        }
    }
    if s.terminal_bell.is_empty() {
        s.terminal_bell = DEFAULT_TERMINAL_BELL.into();
    }
    if s.chime_style.is_empty() && !old_audio_style.is_empty() {
        s.chime_style = old_audio_style.clone();
    }
    if s.chime_style.is_empty() {
        s.chime_style = DEFAULT_CHIME_STYLE.into();
    }
    if s.chime_events.is_empty() && !old_audio_events.is_empty() {
        s.chime_events = old_audio_events.clone();
    }
    if s.chime_events.is_empty() {
        s.chime_events = DEFAULT_CHIME_EVENTS.into();
    }
    if s.chime_volume.is_empty() && !old_bell_volume.is_empty() {
        s.chime_volume = old_bell_volume.clone();
    }
    if s.chime_volume.is_empty() {
        s.chime_volume = DEFAULT_CHIME_VOLUME.into();
    }
    s
}

/// `_nf_write_state`: the 11-key object jq -n builds, in its key order. No
/// `flair` (bash dropped it); an old file that has one still reads fine.
fn write_state(path: &Path, s: &State) {
    let mut recent = Value::Array(vec![]);
    match std::fs::read_to_string(path) {
        // No file yet: nothing to preserve, silent.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => errlog::note_io(
            "state-corrupt",
            &format!("cannot read {} to keep chime_recent_styles; history reset", path.display()),
            &e,
        ),
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Err(e) => errlog::note(
                "state-corrupt",
                &format!("{} unparseable ({}); chime_recent_styles history reset", path.display(), e),
            ),
            Ok(v) => {
                if let Some(r) = v.get("chime_recent_styles") {
                    if !r.is_null() {
                        recent = r.clone();
                    }
                }
            }
        },
    }
    let mut obj = serde_json::Map::new();
    obj.insert("mode".into(), Value::String(s.mode.clone()));
    obj.insert("width".into(), Value::String(s.width.clone()));
    obj.insert(
        "terminal_bell".into(),
        Value::String(s.terminal_bell.clone()),
    );
    obj.insert("chime_sound".into(), Value::String(s.chime_sound.clone()));
    obj.insert("chime_volume".into(), Value::String(s.chime_volume.clone()));
    obj.insert("chime_style".into(), Value::String(s.chime_style.clone()));
    obj.insert("chime_events".into(), Value::String(s.chime_events.clone()));
    obj.insert("color".into(), Value::String(s.color.clone()));
    obj.insert("last_session".into(), Value::String(s.last_session.clone()));
    obj.insert("spinner_verbs".into(), Value::String(s.spinner_verbs.clone()));
    obj.insert("chime_recent_styles".into(), recent);
    atomic_write(path, &jqx::pretty(&Value::Object(obj)));
}

/// Delete `<state file>.tmp.*` regular files older than an hour: a kill between creating the
/// temp and the rename leaves one behind for good. Twin of lib.sh `_nf_state_heal`.
fn sweep_stale_tmp(path: &Path) {
    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else { return };
    let prefix = format!("{}.tmp.", name.to_string_lossy());
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        if !e.file_name().to_string_lossy().starts_with(&prefix) {
            continue;
        }
        let stale = e.metadata().ok().filter(|m| m.is_file()) // symlink_metadata: DirEntry does not follow
            .and_then(|m| m.modified().ok()).and_then(|t| t.elapsed().ok())
            .map_or(false, |a| a.as_secs() > 3600);
        if stale {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

/// Write via temp + rename. Failure is logged (key `state-write`) and the
/// orphan temp removed; the return value tells the caller whether it landed.
fn atomic_write(path: &Path, contents: &str) -> bool {
    sweep_stale_tmp(path);
    let tmp = path.with_extension(format!("json.tmp.{}", std::process::id()));
    let res = std::fs::write(&tmp, contents).and_then(|_| std::fs::rename(&tmp, path));
    match res {
        Ok(()) => {
            errlog::ok("state-write");
            true
        }
        Err(e) => {
            errlog::note_io("state-write", &format!("{} not updated; settings/last_session not persisted", path.display()), &e);
            if let Err(e2) = std::fs::remove_file(&tmp) {
                if e2.kind() != std::io::ErrorKind::NotFound {
                    errlog::note_io("state-write", &format!("orphan {}", tmp.display()), &e2);
                }
            }
            false
        }
    }
}

/// `_nf_update_field <field> <value>` — jq `.field = $v`, atomic via rename.
pub fn update_field(path: &Path, state: &State, field: &str, value: &str) {
    // The caller retries on EVERY render while last_session differs, so after a
    // failed write back off for a minute instead of hammering a broken disk
    // several times a second per session. (The log line is rate limited
    // separately.)
    if errlog::recent("state-write-retry", 60) {
        return;
    }
    if let Some(dir) = path.parent() {
        if let Err(e) = std::fs::create_dir_all(dir) {
            errlog::note_io("state-write", &format!("cannot create {}", dir.display()), &e);
            errlog::touch("state-write-retry");
            return;
        }
    }
    if !path.is_file() {
        write_state(path, state);
    }
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => {
            errlog::note_io("state-write", &format!("cannot read {} for update", path.display()), &e);
            errlog::touch("state-write-retry");
            return;
        }
    };
    // A corrupt file is reported by read_state on this same render; the bash
    // twin copies it to state.json.corrupt and rebuilds, Rust leaves it alone
    // (output parity does not depend on it), so say that it was left.
    let mut v: Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => {
            errlog::note("state-corrupt", &format!("{} unparseable ({}); {} not updated", path.display(), e, field));
            errlog::touch("state-write-retry");
            return; // jq fails, `>` truncates tmp only, mv never runs
        }
    };
    match &mut v {
        Value::Object(m) => {
            m.insert(field.to_string(), Value::String(value.to_string()));
        }
        _ => {
            errlog::note("state-corrupt", &format!("{} is JSON but not an object; {} not updated", path.display(), field));
            errlog::touch("state-write-retry");
            return;
        }
    }
    if atomic_write(path, &jqx::pretty(&v)) {
        errlog::clear("state-write-retry");
    } else {
        errlog::touch("state-write-retry");
    }
}

#[cfg(test)]
mod tests {
    /// bash's `_nf_write_state` keys, in its order: no `flair`, `spinner_verbs` before the history.
    #[test]
    fn write_state_matches_bash_keys() {
        let dir = std::env::temp_dir().join(format!("nf-state-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.json");
        super::write_state(&path, &super::read_state(&path));
        let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        std::fs::remove_file(&path).unwrap();
        std::fs::remove_dir(&dir).unwrap();
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(|k| k.as_str()).collect();
        assert_eq!(
            keys,
            ["mode", "width", "terminal_bell", "chime_sound", "chime_volume", "chime_style", "chime_events", "color", "last_session", "spinner_verbs", "chime_recent_styles"]
        );
    }
}
