//! nerdflair-statusline — a byte-identical Rust port of scripts/statusline.sh.
//!
//! The bash is the specification. Where the bash has a quirk (a collapsing
//! IFS read, an arithmetic error that silently zeroes a value, an invalid
//! UTF-8 glyph) the quirk is reproduced, with a comment, rather than fixed:
//! the two renderers must agree byte for byte.

mod bar;
mod colors;
mod fmtx;
mod jqx;
mod proc;
mod state;
mod util;

use colors::*;
use serde_json::Value;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use util::*;
use util::Ar;

const GIT_CACHE_TTL: i64 = 3;
const MIN_BRANCH_FIT: i64 = 15;
const MULTI_SIDE_MIN: i64 = 5;
const MULTI_SEP: &str = " \u{b7} ";
const MULTI_SEP_W: i64 = 3;

fn main() {
    let mut buf = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut buf);
    let input = String::from_utf8_lossy(&buf).into_owned();
    let out = render(&input);
    let mut so = std::io::stdout().lock();
    let _ = so.write_all(&colors::emit_bytes(&out));
    let _ = so.flush();
}

// ── jq field extraction ──────────────────────────────────────────
struct Fields {
    cwd: String,
    project_dir: String,
    raw_model: String,
    worktree_branch: String,
    cost: String,
    total_duration_ms: String,
    total_api_ms: String,
    output_style: String,
    effort_level: String,
    thinking_enabled: String,
    fast_mode: String,
    session_id: String,
    used_pct: String,
    #[allow(dead_code)]
    input_tokens: String,
    output_tokens: String,
    ctx_size: String,
    rl_5h_pct: String,
    rl_5h_reset: String,
    rl_7d_pct: String,
    rl_7d_reset: String,
}

fn extract(root: &Value) -> Fields {
    let mut parts: Vec<String> = Vec::with_capacity(20);
    let mut failed = false;
    {
        let mut push = |p: &[&str]| {
            if failed {
                return;
            }
            match jqx::path(root, p) {
                Ok(v) => parts.push(jqx::tostring(v)),
                Err(_) => failed = true,
            }
        };
        push(&["workspace", "current_dir"]);
        push(&["workspace", "project_dir"]);
    }
    // The model element uses `// empty`, so it VANISHES from the array when
    // absent — shifting every later field left by one. Reproduced.
    if !failed {
        match jqx::path(root, &["model"]) {
            Err(_) => failed = true,
            Ok(Value::Object(m)) => {
                let pick = |k: &str| -> Option<String> {
                    match m.get(k) {
                        None | Some(Value::Null) | Some(Value::Bool(false)) => None,
                        Some(v) => Some(jqx::tostring(v)),
                    }
                };
                // Must ALWAYS push, even when absent. The bash side used jq's
                // `empty` here, which yields no output and silently dropped the
                // element -- shifting all 17 later fields and blanking the
                // statusline. Fixed on both sides; push "" so the field count
                // stays 20.
                parts.push(pick("display_name").or_else(|| pick("id")).unwrap_or_default());
            }
            Ok(Value::Null) | Ok(Value::Bool(false)) => parts.push(String::new()),
            Ok(v) => parts.push(jqx::tostring(v)),
        }
    }
    {
        let mut push = |p: &[&str]| {
            if failed {
                return;
            }
            match jqx::path(root, p) {
                Ok(v) => parts.push(jqx::tostring(v)),
                Err(_) => failed = true,
            }
        };
        push(&["worktree", "branch"]);
        push(&["cost", "total_cost_usd"]);
        push(&["cost", "total_duration_ms"]);
        push(&["cost", "total_api_duration_ms"]);
        push(&["output_style", "name"]);
        push(&["effort", "level"]);
        push(&["thinking", "enabled"]);
        push(&["fast_mode"]);
        push(&["session_id"]);
        push(&["context_window", "used_percentage"]);
        push(&["context_window", "total_input_tokens"]);
        push(&["context_window", "total_output_tokens"]);
        push(&["context_window", "context_window_size"]);
        push(&["rate_limits", "five_hour", "used_percentage"]);
        push(&["rate_limits", "five_hour", "resets_at"]);
        push(&["rate_limits", "seven_day", "used_percentage"]);
        push(&["rate_limits", "seven_day", "resets_at"]);
    }
    if failed {
        parts.clear();
    }
    let f = |i: usize| parts.get(i).cloned().unwrap_or_default();
    Fields {
        cwd: f(0),
        project_dir: f(1),
        raw_model: f(2),
        worktree_branch: f(3),
        cost: f(4),
        total_duration_ms: f(5),
        total_api_ms: f(6),
        output_style: f(7),
        effort_level: f(8),
        thinking_enabled: f(9),
        fast_mode: f(10),
        session_id: f(11),
        used_pct: f(12),
        input_tokens: f(13),
        output_tokens: f(14),
        ctx_size: f(15),
        rl_5h_pct: f(16),
        rl_5h_reset: f(17),
        rl_7d_pct: f(18),
        rl_7d_reset: f(19),
    }
}

/// ~/.claude.json is dominated by per-project history that this renderer never
/// looks at. Two shallow RawValue passes keep only `.mcpServers` and the one
/// `.projects[<project_dir>]` entry, which is ~4x cheaper than materialising
/// the whole document as a Value tree. The result is shaped like the original
/// document so downstream lookups are unchanged.
fn load_claude_json(path: &Path, project_dir: &str) -> Option<Value> {
    use serde_json::value::RawValue;
    let text = std::fs::read_to_string(path).ok()?;
    let top: std::collections::HashMap<String, &RawValue> = serde_json::from_str(&text).ok()?;
    let mut obj = serde_json::Map::new();
    if let Some(raw) = top.get("mcpServers") {
        if let Ok(v) = serde_json::from_str::<Value>(raw.get()) {
            obj.insert("mcpServers".into(), v);
        } else {
            obj.insert("mcpServers".into(), Value::Null);
        }
    }
    if !project_dir.is_empty() {
        if let Some(raw) = top.get("projects") {
            if let Ok(projs) = serde_json::from_str::<std::collections::HashMap<String, &RawValue>>(raw.get()) {
                let mut pobj = serde_json::Map::new();
                if let Some(entry) = projs.get(project_dir) {
                    if let Ok(v) = serde_json::from_str::<Value>(entry.get()) {
                        pobj.insert(project_dir.to_string(), v);
                    }
                }
                obj.insert("projects".into(), Value::Object(pobj));
            } else {
                // `.projects` is not an object: jq would error on the index.
                obj.insert("projects".into(), Value::String(String::new()));
            }
        }
    }
    Some(Value::Object(obj))
}

fn parse_model(raw: &str) -> String {
    const FAMILIES: [&str; 4] = ["opus", "sonnet", "haiku", "fable"];
    let bytes = raw.as_bytes();
    let mut found: Option<(usize, usize)> = None;
    'outer: for i in 0..bytes.len() {
        for fam in FAMILIES {
            let fb = fam.as_bytes();
            if i + fb.len() <= bytes.len()
                && bytes[i..i + fb.len()].eq_ignore_ascii_case(fb)
            {
                found = Some((i, fb.len()));
                break 'outer;
            }
        }
    }
    let (i, len) = match found {
        Some(v) => v,
        None => return sanitize(raw),
    };
    let name = &raw[i..i + len];
    let mut model = String::new();
    let mut cs = name.chars();
    if let Some(c) = cs.next() {
        model.extend(c.to_uppercase());
    }
    model.push_str(cs.as_str());
    if let Some(v) = find_dotted_version(raw) {
        model.push(' ');
        model.push_str(&v.replace('-', "."));
    } else if let Some(v) = find_digits(raw) {
        model.push(' ');
        model.push_str(&v);
    }
    model
}

/// leftmost-longest `[0-9]+[.-][0-9]+`
fn find_dotted_version(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i].is_ascii_digit() {
            let mut j = i;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            if j < b.len() && (b[j] == b'.' || b[j] == b'-') {
                let mut k = j + 1;
                while k < b.len() && b[k].is_ascii_digit() {
                    k += 1;
                }
                if k > j + 1 {
                    return Some(s[i..k].to_string());
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
    None
}

fn find_digits(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i].is_ascii_digit() {
            let mut j = i;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            return Some(s[i..j].to_string());
        }
        i += 1;
    }
    None
}

fn basename(p: &str) -> String {
    let t = p.trim_end_matches('/');
    if t.is_empty() {
        return if p.is_empty() { String::new() } else { "/".into() };
    }
    match t.rfind('/') {
        Some(i) => t[i + 1..].to_string(),
        None => t.to_string(),
    }
}

// ── row helpers ──────────────────────────────────────────────────
fn justified_row(max_w: i64, left: &str, right: &str) -> String {
    let left_len = vis_len(left) as i64;
    let right_len = vis_len(right) as i64;
    let mut pad_len = max_w - left_len - right_len;
    if pad_len < 2 {
        pad_len = 2;
    }
    let mut s = String::with_capacity(left.len() + right.len() + pad_len as usize + 8);
    s.push_str(left);
    for _ in 0..pad_len {
        s.push(' ');
    }
    s.push_str(right);
    s.push_str(RESET);
    s
}

fn render(input: &str) -> String {
    // A fatal bash arithmetic error terminates the script; the EXIT trap then
    // flushes whatever was already buffered. `Err(partial)` models exactly that.
    match render_inner(input) {
        Ok(s) => s,
        Err(partial) => partial,
    }
}

// A few assignments mirror bash statements whose value the bash itself never
// reads back (`_branch_is_multi=0`, `style_suffix_len=0`). They are kept so the
// transcription lines up with the source.
#[allow(unused_assignments)]
fn render_inner(input: &str) -> Result<String, String> {
    let mut out = String::new();
    let home = std::env::var("HOME").unwrap_or_default();
    let uid = uid();
    let now = epoch_secs();

    // ── State ────────────────────────────────────────────────────
    let state_path = state::state_file();
    let st = state::read_state(&state_path);
    let sl_mode = st.mode.clone();
    let sl_width = st.width.clone();
    let color_mode = st.color.clone();
    let chime_volume = st.chime_volume.clone();
    let chime_style = st.chime_style.clone();
    let last_session = st.last_session.clone();

    let pal = palette(&color_mode);
    let theme = bar_theme(&color_mode);
    let sep_bullet = format!("{} \u{b7} {}", pal.dim, RESET);
    let opt_bullet = format!("{} \u{b7}{}", pal.dim, RESET);

    // ── Payload ──────────────────────────────────────────────────
    let root: Value = serde_json::from_str(input).unwrap_or(Value::Null);
    let f = extract(&root);
    let cwd = f.cwd.clone();
    let mut project_dir = f.project_dir.clone();
    if !project_dir.is_empty() && Path::new(&project_dir).is_dir() {
        if let Ok(p) = std::fs::canonicalize(&project_dir) {
            project_dir = p.to_string_lossy().into_owned();
        }
    }
    let model = parse_model(&f.raw_model);

    // ── MCP servers ──────────────────────────────────────────────
    let claude_json = PathBuf::from(&home).join(".claude.json");
    let claude_root: Option<Value> = load_claude_json(&claude_json, &project_dir);
    let mut proj_disabled: Vec<String> = Vec::new();
    if !project_dir.is_empty() {
        if let Some(cr) = &claude_root {
            if let Ok(v) = jqx::path(cr, &["projects", &project_dir, "disabledMcpServers"]) {
                if let Value::Array(a) = v {
                    for e in a {
                        if let Value::String(s) = e {
                            if !s.is_empty() {
                                proj_disabled.push(s.clone());
                            }
                        }
                    }
                }
            }
        }
    }
    let mut mcp_names: Vec<String> = Vec::new();
    let mcp_files: Vec<(PathBuf, bool)> = vec![
        (claude_json.clone(), true),
        (PathBuf::from(format!("{}/.mcp.json", project_dir)), false),
        (PathBuf::from(format!("{}/.mcp.json", cwd)), false),
    ];
    for (path, is_claude_json) in &mcp_files {
        if !path.is_file() {
            continue;
        }
        // ~/.claude.json is already parsed; re-parsing a 74 KB file cost
        // ~350 us of the render budget.
        let owned: Option<Value> = if *is_claude_json {
            None
        } else {
            std::fs::read_to_string(path)
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok())
        };
        let v: &Value = match (*is_claude_json, &owned) {
            (true, _) => match &claude_root {
                Some(v) => v,
                None => continue,
            },
            (false, Some(v)) => v,
            (false, None) => continue,
        };
        for name in jqx::mcp_server_names(v, &["mcpServers"]) {
            if *is_claude_json && proj_disabled.iter().any(|d| *d == name) {
                continue;
            }
            mcp_names.push(sanitize(&name));
        }
    }
    if !project_dir.is_empty() {
        if let Some(cr) = &claude_root {
            for name in jqx::mcp_server_names(cr, &["projects", &project_dir, "mcpServers"]) {
                if proj_disabled.iter().any(|d| *d == name) {
                    continue;
                }
                mcp_names.push(sanitize(&name));
            }
        }
    }
    let mcp_enabled = mcp_names.len() as i64;
    let mut mcp_sorted = mcp_names.clone();
    sort_fold(&mut mcp_sorted);

    // ── Git repo detection ───────────────────────────────────────
    let mut git_dir = String::new();
    let mut multi_git_subs: Vec<String> = Vec::new();
    let mut adopted_repo_name = String::new();
    // The bash `cd`s and, when the cd FAILS, keeps running git in whatever
    // directory the shell was already in. Model that shell cwd explicitly.
    let mut shell_cwd: PathBuf =
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    if !cwd.is_empty() {
        if Path::new(&cwd).is_dir() {
            shell_cwd = PathBuf::from(&cwd);
        }
        let run_dir = shell_cwd.clone();
        let (_, ok) = proc::out("git", &["rev-parse", "--is-inside-work-tree"], Some(&run_dir));
        if ok {
            git_dir = cwd.clone();
        } else {
            let mut subs: Vec<String> = Vec::new();
            if let Ok(rd) = std::fs::read_dir(&cwd) {
                let mut entries: Vec<String> = rd
                    .filter_map(|e| e.ok())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| !n.starts_with('.'))
                    .collect();
                entries.sort(); // glob order under a C collation
                for name in entries {
                    let p = format!("{}/{}", cwd.trim_end_matches('/'), name);
                    if Path::new(&p).is_dir() && Path::new(&format!("{}/.git", p)).is_dir() {
                        subs.push(p);
                    }
                }
            }
            if subs.len() == 1 {
                git_dir = subs[0].clone();
                adopted_repo_name = basename(&git_dir);
            } else if subs.len() > 1 {
                multi_git_subs = subs;
            }
        }
    }

    // ── Git cache ────────────────────────────────────────────────
    let mut gc = GitCache::default();
    if !git_dir.is_empty() {
        gc = git_cache(&git_dir, &mut shell_cwd);
    }

    // ── Uncommitted files segment ────────────────────────────────
    let mut dirty_segment = String::new();
    if !git_dir.is_empty() {
        let dirty_count = bash_int(&gc.dirty).unwrap_or(0);
        if dirty_count > 0 {
            dirty_segment = format!(
                "{}{} {}{}",
                pal.mustard,
                DIRTY_ICON,
                fmt_num(dirty_count),
                RESET
            );
            let added = bash_int(&gc.added).unwrap_or(0);
            let removed = bash_int(&gc.removed).unwrap_or(0);
            let mut diff_parts = String::new();
            if added > 0 {
                diff_parts.push_str(&format!("{}+{}{}", pal.diff_plus, fmt_num(added), RESET));
            }
            if removed > 0 {
                if !diff_parts.is_empty() {
                    diff_parts.push(' ');
                }
                diff_parts.push_str(&format!("{}-{}{}", pal.diff_minus, fmt_num(removed), RESET));
            }
            if !diff_parts.is_empty() {
                dirty_segment.push_str(&format!(
                    " \x1b[1;38;2;72;78;74m[{}{}\x1b[1;38;2;72;78;74m]{}",
                    RESET, diff_parts, RESET
                ));
            }
        }
    }

    // ── Multi-repo branch summary ────────────────────────────────
    let mut multi_branch_list = String::new();
    let mut multi_off_count: i64 = 0;
    let multi_total_count = multi_git_subs.len() as i64;
    if multi_total_count > 0 {
        let cache_file = PathBuf::from(format!(
            "/tmp/nerdflair-multibranch-{}",
            cksum(cwd.as_bytes())
        ));
        let fresh = cache_file.is_file() && file_age(&cache_file) < GIT_CACHE_TTL;
        if !fresh {
            let mut list = String::new();
            let mut off = 0i64;
            for sub in &multi_git_subs {
                let (mut b, ok) = proc::out(
                    "git",
                    &["-C", sub, "symbolic-ref", "--quiet", "--short", "HEAD"],
                    None,
                );
                if !ok {
                    let (b2, _) = proc::out("git", &["-C", sub, "rev-parse", "--short", "HEAD"], None);
                    b = b2;
                }
                if b.is_empty() || b == "main" || b == "master" {
                    continue;
                }
                off += 1;
                if !list.is_empty() {
                    list.push_str(", ");
                }
                list.push_str(&format!("{}:{}", basename(sub), b));
            }
            let _ = std::fs::write(&cache_file, format!("{}\n{}", off, list));
        }
        let content = std::fs::read_to_string(&cache_file).unwrap_or_default();
        let mut lines = content.splitn(2, '\n');
        let first = lines.next().unwrap_or("").to_string();
        let rest = lines.next().unwrap_or("");
        multi_off_count = bash_int(&first).unwrap_or(0);
        let mut rest = rest.to_string();
        while rest.ends_with('\n') {
            rest.pop();
        }
        multi_branch_list = sanitize(&rest);
    }

    // ── Folder + branch ──────────────────────────────────────────
    let mut folder_name = String::new();
    let mut branch = String::new();
    let mut branch_is_multi = 0i64;
    let mut is_home = false;
    let display_dir = if project_dir.is_empty() {
        cwd.clone()
    } else {
        project_dir.clone()
    };
    if !display_dir.is_empty() {
        if display_dir == home {
            is_home = true;
        } else {
            folder_name = sanitize(&basename(&display_dir));
        }
        if !f.worktree_branch.is_empty() {
            branch = sanitize(&f.worktree_branch);
        } else if !gc.branch.is_empty() {
            branch = sanitize(&gc.branch);
            if !adopted_repo_name.is_empty() && gc.branch != "main" && gc.branch != "master" {
                branch = format!("{}:{}", sanitize(&adopted_repo_name), branch);
            }
        } else if multi_total_count > 0 {
            if multi_off_count > 0 {
                branch = multi_branch_list.replace(", ", MULTI_SEP);
                branch_is_multi = 1;
            } else {
                branch = format!("{} repos", multi_total_count);
            }
        }
    }
    let folder_icon = if gc.worktree != "1" && f.worktree_branch.is_empty() {
        FOLDER_ICON
    } else {
        FOLDER_WORKTREE_ICON
    };

    // ── MCP segments ─────────────────────────────────────────────
    let mut mcp_segment = String::new();
    let mut mcp_segment_expanded = String::new();
    let mut mcp_segments_truncated: Vec<String> = Vec::new();
    if mcp_enabled > 0 {
        mcp_segment = format!("{}{} {} MCP{}", pal.mcp_color, MCP_ICON, mcp_enabled, RESET);
        if !mcp_sorted.is_empty() {
            let list = mcp_sorted.join(", ");
            mcp_segment_expanded = format!("{}{} {}{}", pal.mcp_color, MCP_ICON, list, RESET);
            let n = mcp_sorted.len();
            if n > 1 {
                for i in (1..n).rev() {
                    let partial = mcp_sorted[..i].join(", ");
                    mcp_segments_truncated.push(format!(
                        "{}{} {}, {} more{}",
                        pal.mcp_color,
                        MCP_ICON,
                        partial,
                        n - i,
                        RESET
                    ));
                }
            }
        }
    }

    // ── Context usage ────────────────────────────────────────────
    let mut ctx_total_s = String::from("200000");
    let mut total_used: i64 = 0;
    let mut pct: i64 = 0;
    let mut pct_is_int = true;
    if !f.used_pct.is_empty() && !f.ctx_size.is_empty() {
        ctx_total_s = f.ctx_size.clone();
        // A fractional `used_percentage` is legal in the payload (the docs' own
        // example is 23.5). bash cannot do float arithmetic, so the original
        // `$(( ctx_total * pct / 100 ))` raised a syntax error, left total_used
        // at 0 and printed to stderr. Both sides now truncate toward zero
        // instead, which is what the integer maths downstream expects.
        // ${x%%.*} on both, mirroring the bash fix.
        let ctx_trunc: String = ctx_total_s.split('.').next().unwrap_or("").to_string();
        let pct_trunc: String = f.used_pct.split('.').next().unwrap_or("").to_string();
        match arith(&ctx_trunc) {
            Ar::Fatal => return Err(out),
            Ar::Syntax => pct_is_int = false,
            Ar::Val(t) => match arith(&pct_trunc) {
                Ar::Fatal => return Err(out),
                Ar::Syntax => pct_is_int = false,
                Ar::Val(p) => {
                    total_used = t.wrapping_mul(p) / 100;
                    pct = p;
                }
            },
        }
    } else {
        let transcript = jqx::path(&root, &["transcript_path"])
            .map(jqx::tostring)
            .unwrap_or_default();
        if !transcript.is_empty() && Path::new(&transcript).is_file() {
            if let Ok(text) = std::fs::read_to_string(&transcript) {
                if let Some(line) = text.lines().filter(|l| l.contains("\"usage\"")).next_back() {
                    if let Ok(v) = serde_json::from_str::<Value>(line) {
                        if let Ok(u) = jqx::path(&v, &["message", "usage"]) {
                            if !u.is_null() {
                                let g = |k: &str| -> i64 {
                                    u.get(k).and_then(|x| x.as_i64()).unwrap_or(0)
                                };
                                total_used = g("input_tokens")
                                    + g("cache_creation_input_tokens")
                                    + g("cache_read_input_tokens")
                                    + g("output_tokens");
                                let ct = bash_int(&ctx_total_s).unwrap_or(200000);
                                pct = total_used * 100 / ct;
                                if pct > 100 {
                                    pct = 99;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    let _ = pct_is_int;
    if total_used <= 0 {
        total_used = 0;
        pct = 0;
    }

    // ── Session chime + last_session persistence ─────────────────
    let mut session_chime = String::new();
    if !f.session_id.is_empty() {
        let sf = PathBuf::from(&home)
            .join(".claude/nerdflair/sessions")
            .join(&f.session_id);
        if sf.is_file() {
            if let Ok(t) = std::fs::read_to_string(&sf) {
                if let Ok(v) = serde_json::from_str::<Value>(&t) {
                    session_chime = match v.get("chime") {
                        Some(Value::Null) | None => String::new(),
                        Some(x) => jqx::tostring(x),
                    };
                }
            }
        }
    }
    if !f.session_id.is_empty() && f.session_id != last_session {
        state::update_field(&state_path, &st, "last_session", &f.session_id);
    }

    let used_fmt = if total_used >= 1_000_000 {
        format!("{}M", total_used / 1_000_000)
    } else if total_used >= 1000 {
        format!("{}k", total_used / 1000)
    } else {
        format!("{}", total_used)
    };
    let size_fmt = match bash_int(&ctx_total_s) {
        Some(t) if t >= 1_000_000 => format!("{}M", t / 1_000_000),
        Some(t) if t >= 1000 => format!("{}k", t / 1000),
        Some(t) => format!("{}", t),
        None => ctx_total_s.clone(),
    };
    let ctx_label = format!("{}/{} {}%", used_fmt, size_fmt, pct);

    // ── Width ────────────────────────────────────────────────────
    let mut max_bar: i64 = if sl_width != "auto" && !sl_width.is_empty()
        && sl_width.bytes().all(|b| b.is_ascii_digit())
    {
        sl_width.parse::<i64>().unwrap_or(80)
    } else {
        match std::env::var("COLUMNS").ok().filter(|s| !s.is_empty()) {
            Some(c) => bash_int(&c).unwrap_or(80),
            None => {
                let (o, ok) = proc::out("tput", &["cols"], None);
                if ok {
                    bash_int(&o).unwrap_or(80)
                } else {
                    80
                }
            }
        }
    };
    if max_bar < 50 {
        max_bar = 50;
    }
    if max_bar > 150 {
        max_bar = 150;
    }
    let row_width = max_bar + 2;

    // ── Git divergence ───────────────────────────────────────────
    let gc_ahead = bash_int(&gc.ahead).unwrap_or(0);
    let gc_behind = bash_int(&gc.behind).unwrap_or(0);
    let mut ahead_segment = String::new();
    if (!gc.ahead.is_empty() || !gc.behind.is_empty()) && gc_ahead + gc_behind > 0 {
        if gc_ahead > 0 {
            ahead_segment.push_str(&format!("{}{}{}{}", pal.dark_green, ARROW_UP, gc_ahead, RESET));
        }
        if gc_behind > 0 {
            if !ahead_segment.is_empty() {
                ahead_segment.push(' ');
            }
            ahead_segment.push_str(&format!("{}{}{}{}", pal.alert, ARROW_DOWN, gc_behind, RESET));
        }
    }

    let mut row1_right = String::from(RESET);
    if sl_mode != "minimal" {
        if !dirty_segment.is_empty() {
            row1_right.push_str(&dirty_segment);
        }
        if !ahead_segment.is_empty() {
            if row1_right != RESET {
                row1_right.push(' ');
            }
            row1_right.push_str(&ahead_segment);
        }
    }
    let right_width = vis_len(&row1_right) as i64;

    let mut extra_reserve = 0i64;
    if sl_mode == "minimal" {
        extra_reserve = char_len(&pct.to_string()) as i64 + 8;
        if !dirty_segment.is_empty() {
            extra_reserve += 3 + vis_len(&dirty_segment) as i64;
        }
    }
    let mut left_budget = row_width - right_width - 3 - extra_reserve;
    if left_budget < 20 {
        left_budget = 20;
    }

    // ── Model text + state suffixes ──────────────────────────────
    let mut model_text = model.clone();
    let mut style_suffix = String::new();
    if !f.output_style.is_empty() && f.output_style != "default" {
        let first = f.output_style.chars().next().unwrap_or(' ');
        let lower: String = first.to_lowercase().collect();
        style_suffix = match lower.as_str() {
            "e" => format!(" {}", STYLE_EXPLANATORY),
            "l" => format!(" {}", STYLE_LEARNING),
            "p" => format!(" {}", STYLE_PROACTIVE),
            other => format!(" {}", other.to_uppercase()),
        };
    }
    let mut effort_suffix = String::new();
    let mut effort_colored = String::new();
    if !f.effort_level.is_empty() {
        effort_suffix = format!(" {}", f.effort_level);
        effort_colored = format!(" {}{}{}", pal.state_color, f.effort_level, RESET);
    }
    let mut state_suffix = String::new();
    let mut state_colored = String::new();
    if f.thinking_enabled == "true" {
        state_suffix = format!(" {}", THINK_ICON);
        state_colored = format!(" {}{}{}", pal.state_color, THINK_ICON, RESET);
    }
    let mut fast_suffix = String::new();
    let mut fast_colored = String::new();
    if f.fast_mode == "true" {
        fast_suffix = format!(" {}", FAST_ICON);
        fast_colored = format!(" {}{}{}", pal.state_color, FAST_ICON, RESET);
    }

    let chrome: i64 = if branch.is_empty() { 7 } else { 12 };
    let mut text_budget = left_budget - chrome;
    if text_budget < 10 {
        text_budget = 10;
    }

    let mut style_len = char_len(&style_suffix) as i64;
    let mut effort_len = char_len(&effort_suffix) as i64;
    let mut state_len = char_len(&state_suffix) as i64;
    let mut fast_len = char_len(&fast_suffix) as i64;
    let ob = |s: i64, e: i64, st: i64, fa: i64| -> i64 {
        if s + e + st + fa > 0 {
            2
        } else {
            0
        }
    };
    let mut model_text_len = char_len(&model_text) as i64
        + style_len
        + effort_len
        + state_len
        + fast_len
        + ob(style_len, effort_len, state_len, fast_len);
    let mut path_len = char_len(&folder_name) as i64;
    let mut branch_len = vis_len(&branch) as i64;
    let mut path_branch_len = path_len + branch_len;

    let min_model = 10i64;
    let mut effort_floor = min_model;
    if !branch.is_empty() && branch_is_multi == 0 && effort_len > 0 {
        let effort_cost = effort_len + 2;
        let mut branch_slack = branch_len - MIN_BRANCH_FIT;
        if branch_slack < 0 {
            branch_slack = 0;
        }
        if branch_slack >= effort_cost {
            effort_floor = min_model + effort_cost;
        }
    }
    let mut model_budget = text_budget - path_branch_len;
    if model_budget < effort_floor {
        model_budget = effort_floor;
    }
    let mut pb_budget = text_budget - model_budget;
    if model_text_len <= model_budget {
        model_budget = model_text_len;
        pb_budget = text_budget - model_budget;
    }

    if branch_is_multi == 1 && path_len + branch_len > pb_budget {
        let multi_min = MULTI_SIDE_MIN + 1 + MULTI_SIDE_MIN;
        let mut model_reserve = min_model;
        if effort_len > 0 {
            let reserve_with_effort = min_model + effort_len + 2;
            let mut target = text_budget - path_len - reserve_with_effort;
            if target < multi_min {
                target = multi_min;
            }
            if !fit_multi_branches(&multi_branch_list, target).is_empty() {
                model_reserve = reserve_with_effort;
            }
        }
        let mut branch_target = text_budget - path_len - model_reserve;
        if branch_target < multi_min {
            branch_target = multi_min;
        }
        let fitted = fit_multi_branches(&multi_branch_list, branch_target);
        branch = if !fitted.is_empty() {
            fitted
        } else {
            format!("{} branches", multi_off_count)
        };
        branch_is_multi = 0;
        branch_len = vis_len(&branch) as i64;
        path_branch_len = path_len + branch_len;
        model_budget = text_budget - path_branch_len;
        if model_budget < min_model {
            model_budget = min_model;
        }
        pb_budget = text_budget - model_budget;
        if model_text_len <= model_budget {
            model_budget = model_text_len;
            pb_budget = text_budget - model_budget;
        }
    }

    if path_branch_len > pb_budget {
        if !branch.is_empty() {
            let half = pb_budget / 2;
            let (mut max_path, mut max_branch);
            if path_len <= half {
                max_path = path_len;
                max_branch = pb_budget - max_path;
            } else if branch_len <= half {
                max_branch = branch_len;
                max_path = pb_budget - max_branch;
            } else {
                max_path = half;
                max_branch = pb_budget - max_path;
            }
            if max_path < 4 {
                max_path = 4;
            }
            if max_branch < 4 {
                max_branch = 4;
            }
            if branch_len > max_branch {
                branch = format!(
                    "{}{}",
                    char_slice(&branch, 0, (max_branch - 1) as usize),
                    ELLIPSIS
                );
            }
            if (char_len(&folder_name) as i64) > max_path {
                let off = char_len(&folder_name) as i64 - max_path + 1;
                folder_name = format!("{}{}", ELLIPSIS, char_from(&folder_name, off as usize));
            }
        } else if path_len > pb_budget {
            let off = path_len - pb_budget + 1;
            folder_name = format!("{}{}", ELLIPSIS, char_from(&folder_name, off as usize));
        }
    }
    path_len = char_len(&folder_name) as i64;
    let _ = path_len;

    if model_text_len > model_budget {
        effort_suffix.clear();
        effort_colored.clear();
        effort_len = 0;
        model_text_len = char_len(&model_text) as i64
            + style_len
            + state_len
            + fast_len
            + ob(style_len, effort_len, state_len, fast_len);
        if model_text_len > model_budget {
            state_suffix.clear();
            state_colored.clear();
            state_len = 0;
            fast_suffix.clear();
            fast_colored.clear();
            fast_len = 0;
            model_text_len = char_len(&model_text) as i64
                + style_len
                + ob(style_len, effort_len, state_len, fast_len);
        }
        if model_text_len > model_budget {
            style_suffix.clear();
            style_len = 0;
            model_text_len = char_len(&model_text) as i64;
        }
        if model_text_len > model_budget {
            model_text = format!(
                "{}{}",
                char_slice(&model_text, 0, (model_budget - 1) as usize),
                ELLIPSIS
            );
        }
    }
    let _ = state_suffix;
    let _ = fast_suffix;

    // ── Assemble row 1 ───────────────────────────────────────────
    let mut folder_segment = String::new();
    if is_home {
        if !branch.is_empty() {
            folder_segment = format!(
                "{}{} {}{}{} {}{}",
                pal.blue, HOME_ICON, sep_bullet, pal.magenta, BRANCH_ICON, branch, RESET
            );
        } else {
            folder_segment = format!("{}{} {}", pal.blue, HOME_ICON, RESET);
        }
    } else if !folder_name.is_empty() {
        if !branch.is_empty() {
            folder_segment = format!(
                "{}{} {}{}{}{} {}{}",
                pal.blue, folder_icon, folder_name, sep_bullet, pal.magenta, BRANCH_ICON, branch, RESET
            );
        } else {
            folder_segment = format!("{}{} {}{}", pal.blue, folder_icon, folder_name, RESET);
        }
    }

    let mut model_segment = String::new();
    if !model_text.is_empty() {
        model_segment = format!("{}{} {}{}", pal.cyan, MODEL_ICON, model_text, RESET);
        if !(effort_colored.is_empty()
            && state_colored.is_empty()
            && style_suffix.is_empty()
            && fast_colored.is_empty())
        {
            model_segment.push_str(&opt_bullet);
        }
        model_segment.push_str(&effort_colored);
        model_segment.push_str(&state_colored);
        model_segment.push_str(pal.state_color);
        model_segment.push_str(&style_suffix);
        model_segment.push_str(RESET);
        model_segment.push_str(&fast_colored);
    }

    let mut row1_left = String::from(RESET);
    if !folder_segment.is_empty() {
        row1_left.push_str(&folder_segment);
    }
    if !model_segment.is_empty() {
        if !folder_segment.is_empty() {
            row1_left.push_str(&sep_bullet);
        }
        row1_left.push_str(&model_segment);
    }

    if sl_mode != "minimal" {
        out.push_str(&justified_row(row_width, &row1_left, &row1_right));
    }

    // ── ccusage bridge ───────────────────────────────────────────
    let ccusage_ttl: i64 = env_int("NERDFLAIR_CCUSAGE_TTL", 60);
    let mut ccusage_line = String::new();
    let ccusage_bin = resolve_ccusage_bin();
    if std::env::var("NERDFLAIR_CCUSAGE").unwrap_or_else(|_| "1".into()) != "0" {
        if let Some(binp) = &ccusage_bin {
            let cache = PathBuf::from(format!("/tmp/nerdflair-ccusage-{}", uid));
            let lock = PathBuf::from(format!("{}.lock", cache.display()));
            let mut fresh = false;
            if cache.is_file() {
                if file_age(&cache) < ccusage_ttl {
                    fresh = true;
                }
                ccusage_line = std::fs::read_to_string(&cache).unwrap_or_default();
            }
            if lock.is_dir() && file_age(&lock) > 120 {
                let _ = std::fs::remove_dir(&lock);
            }
            if !fresh && std::fs::create_dir(&lock).is_ok() {
                let script = format!(
                    "trap 'rmdir {lock} 2>/dev/null' EXIT; \
                     {bin} statusline --refresh-interval {ttl} > {cache}.tmp 2>/dev/null \
                     && mv -f {cache}.tmp {cache}",
                    lock = shq(&lock.to_string_lossy()),
                    bin = shq(&binp.to_string_lossy()),
                    ttl = ccusage_ttl,
                    cache = shq_bare(&cache.to_string_lossy()),
                );
                proc::spawn_detached(&script, Some(input));
            }
        }
    }

    // ── Cost per repo ────────────────────────────────────────────
    let repocost_segment = repo_cost_segment(&f, &git_dir, &project_dir, uid, now, pal);

    // ── MCP health ───────────────────────────────────────────────
    let (mcp_ok, mcp_bad, mcp_warn) = mcp_health(uid, now);

    // ── Time, cost, speed ────────────────────────────────────────
    let mut api_fmt = String::new();
    let mut time_segment = String::new();
    if !f.total_api_ms.is_empty() {
        match arith(&f.total_api_ms) {
            Ar::Fatal => return Err(out),
            Ar::Val(v) if v > 999 => {
                api_fmt = fmtx::duration(v, fmt_num);
                time_segment = format!("{}{}{}", pal.mauve, api_fmt, RESET);
            }
            _ => {}
        }
    }

    let mut speed_segment = String::new();
    if !f.output_tokens.is_empty() && !f.total_api_ms.is_empty() {
        let ot = match arith(&f.output_tokens) {
            Ar::Fatal => return Err(out),
            Ar::Val(v) => v,
            Ar::Syntax => 0,
        };
        let am = if ot > 0 {
            match arith(&f.total_api_ms) {
                Ar::Fatal => return Err(out),
                Ar::Val(v) => v,
                Ar::Syntax => 0,
            }
        } else {
            0
        };
        if ot > 0 && am > 0 {
            let tps = ot.wrapping_mul(1000) / am;
            let sf = if tps >= 1000 {
                format!("{}.{}k", tps / 1000, tps % 1000 / 100)
            } else {
                format!("{}", tps)
            };
            speed_segment = format!("{}{} {}{}", pal.mauve, SPEED_ICON, sf, RESET);
        }
    }

    // `printf '%.2f' "${cost:-0}"` -> C strtod semantics, not Rust's parser.
    let cost_val: f64 = if f.cost.is_empty() {
        0.0
    } else {
        fmtx::strtod(&f.cost)
    };
    let formatted_cost = fmtx::f2(cost_val);
    let mut cost_segment = String::new();
    if formatted_cost != "0.00" {
        cost_segment = format!("{}{}{}{}", pal.cost_green, COST_ICON, formatted_cost, RESET);
    }

    // ── Burn rate ────────────────────────────────────────────────
    let mut burn_val = String::new();
    if !ccusage_line.is_empty() {
        if let Some(v) = scan_burn(&ccusage_line) {
            burn_val = v;
        }
    }
    if burn_val.is_empty() && !f.cost.is_empty() && !f.total_duration_ms.is_empty() {
        match arith(&f.total_duration_ms) {
            Ar::Fatal => return Err(out),
            Ar::Val(d) if d > 120000 => {
                if let Some(c) = fmtx::awk_expr_num(&f.cost) {
                    burn_val = fmtx::f2(c / (d as f64 / 3600000.0));
                }
            }
            _ => {}
        }
    }
    let mut burn_segment = String::new();
    if !burn_val.is_empty() && burn_val != "0" && burn_val != "0.00" {
        let int_part = burn_val.split('.').next().unwrap_or("");
        let mut color = pal.cost_green;
        if let Some(iv) = bash_int(int_part) {
            if iv >= 20 {
                color = pal.mustard;
            }
            if iv >= 50 {
                color = pal.alert;
            }
        }
        burn_segment = format!("{}{} ${}/h{}", color, BURN_ICON, burn_val, RESET);
    }

    // ── ccusage billing block ────────────────────────────────────
    let mut block_segment = String::new();
    if !ccusage_line.is_empty() {
        if let Some(blk_cost) = scan_block_cost(&ccusage_line) {
            block_segment = format!("{}{} {}{}", pal.mauve, BLOCK_ICON, blk_cost, RESET);
            if let Some(left) = scan_block_left(&ccusage_line) {
                block_segment.push_str(&format!("{} {}{}", pal.dim, left, RESET));
            }
        }
    }

    // ── MCP health segment ───────────────────────────────────────
    let mut mcphealth_segment = String::new();
    if !mcp_ok.is_empty() {
        let o = bash_int(&mcp_ok).unwrap_or(0);
        let b = bash_int(&mcp_bad).unwrap_or(0);
        let w = bash_int(&mcp_warn).unwrap_or(0);
        let tot = o + b + w;
        if tot > 0 {
            let mut color = pal.dark_green;
            if w > 0 {
                color = pal.mustard;
            }
            if b > 0 {
                color = pal.alert;
            }
            // `${mcp_icon:-}` — the icon only exists when MCP servers are
            // configured, so an unconfigured session gets a bare ratio.
            let icon = if mcp_enabled > 0 { MCP_ICON } else { "" };
            mcphealth_segment = format!("{}{}{}/{}{}", color, icon, mcp_ok, tot, RESET);
            if b > 0 {
                mcphealth_segment.push_str(&format!("{}{}{}{}", pal.alert, CROSS, b, RESET));
            }
            if w > 0 {
                mcphealth_segment.push_str(&format!("{}!{}{}", pal.mustard, w, RESET));
            }
        }
    }

    // ── Time to auto-compaction ──────────────────────────────────
    let mut compact_segment = String::new();
    if !f.used_pct.is_empty() && !f.total_duration_ms.is_empty() {
        let dur = match arith(&f.total_duration_ms) {
            Ar::Fatal => return Err(out),
            Ar::Val(v) => v,
            Ar::Syntax => 0,
        };
        {
            if dur > 120000 {
                let head = f.used_pct.split('.').next().unwrap_or("");
                let cp_used = if head.is_empty() {
                    0
                } else {
                    match arith(head) {
                        Ar::Fatal => return Err(out),
                        Ar::Val(v) => v,
                        Ar::Syntax => 0,
                    }
                };
                if (5..80).contains(&cp_used) && cp_used > 0 {
                    let secs = (80 - cp_used) * dur / (cp_used * 1000);
                    if secs > 0 && secs < 86400 {
                        let mut color = pal.dim;
                        if secs < 900 {
                            color = pal.mustard;
                        }
                        if secs < 300 {
                            color = pal.alert;
                        }
                        let fmt = if secs >= 3600 {
                            format!("{}h{:02}m", secs / 3600, (secs % 3600) / 60)
                        } else {
                            format!("{}m", secs / 60)
                        };
                        compact_segment = format!("{}{}{}{}", color, DOWN_DASHED, fmt, RESET);
                    }
                }
            }
        }
    }

    // ── tmux ─────────────────────────────────────────────────────
    let mut tmux_segment = String::new();
    if let Ok(pane) = std::env::var("TMUX_PANE") {
        if !pane.is_empty() && proc::which("tmux").is_some() {
            let cache = PathBuf::from(format!("/tmp/nerdflair-tmux-{}-{}", uid, slugify(&pane)));
            let mut name = String::new();
            if cache.is_file() && file_age(&cache) < 60 {
                name = std::fs::read_to_string(&cache).unwrap_or_default();
                while name.ends_with('\n') {
                    name.pop();
                }
            }
            if name.is_empty() {
                let (n, _) = proc::out("tmux", &["display-message", "-p", "#S"], None);
                name = n;
                if !name.is_empty() {
                    let _ = std::fs::write(&cache, &name);
                }
            }
            if !name.is_empty() {
                tmux_segment = format!("{}{} {}{}", pal.dim, TMUX_ICON, name, RESET);
            }
        }
    }

    // ── Rate limits ──────────────────────────────────────────────
    let rl_part = |pct_s: &str, reset: &str, label: &str| -> String {
        if pct_s.is_empty() {
            return String::new();
        }
        let head = match pct_s.rfind('.') {
            Some(i) => &pct_s[..i],
            None => pct_s,
        };
        if head.is_empty() {
            return String::new();
        }
        // `_rl5=$(_rl_part ...)` runs in a subshell, so a fatal arithmetic
        // error there truncates only this part's output, not the render.
        let p = match arith(head) {
            Ar::Fatal => return String::new(),
            Ar::Val(v) => v,
            Ar::Syntax => 0,
        };
        let mut color = pal.dark_green;
        if p >= 60 {
            color = pal.mustard;
        }
        if p >= 85 {
            color = pal.alert;
        }
        let mut s = format!("{}{}{}%{}", color, label, head, RESET);
        if !reset.is_empty() {
            if let Some(t) = bash_int(reset) {
                let cd = fmtx::countdown(t, now);
                if !cd.is_empty() {
                    s.push_str(&format!("{}/{}{}", pal.dim, cd, RESET));
                }
            }
        }
        s
    };
    let rl5 = rl_part(&f.rl_5h_pct, &f.rl_5h_reset, "5h ");
    let rl7 = rl_part(&f.rl_7d_pct, &f.rl_7d_reset, "7d ");
    let mut limits_segment = String::new();
    if !rl5.is_empty() || !rl7.is_empty() {
        limits_segment.push_str(&rl5);
        if !rl5.is_empty() && !rl7.is_empty() {
            limits_segment.push_str(&format!("{} {}", pal.dim, RESET));
        }
        limits_segment.push_str(&rl7);
    }

    // ── Chime label ──────────────────────────────────────────────
    let vol_num: f64 = chime_volume.parse::<f64>().unwrap_or(f64::NAN);
    let vol_nonzero = !chime_volume.is_empty() && chime_volume != "0" && chime_volume != "0.0";
    let mut chime_label = String::new();
    if vol_nonzero {
        if !session_chime.is_empty() && session_chime != "random" {
            chime_label = session_chime.clone();
        } else if chime_style == "random" && state_path.is_file() {
            let last = std::fs::read_to_string(&state_path)
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                .and_then(|v| match v.get("chime_recent_styles") {
                    Some(Value::Array(a)) => a.last().map(jqx::tostring),
                    _ => None,
                })
                .unwrap_or_default();
            chime_label = if last.is_empty() { "random".into() } else { last };
        } else if !chime_style.is_empty() {
            chime_label = chime_style.clone();
        }
    }
    let mut chime_segment = String::new();
    if !chime_label.is_empty() && chime_style == "random" && formatted_cost == "0.00" {
        let vol_pct = fmtx::g(if vol_num.is_nan() { 100.0 } else { vol_num * 100.0 });
        chime_segment = if vol_pct != "100" {
            format!("{}{}  {} {}%{}", pal.mauve, VOL_ICON, chime_label, vol_pct, RESET)
        } else {
            format!("{}{}  {}{}", pal.mauve, VOL_ICON, chime_label, RESET)
        };
    }

    // ── Row 3 ────────────────────────────────────────────────────
    let mut row3_right = String::from(RESET);
    if !cost_segment.is_empty() {
        for seg in [
            &chime_segment,
            &tmux_segment,
            &mcphealth_segment,
            &limits_segment,
            &compact_segment,
            &speed_segment,
            &time_segment,
            &burn_segment,
            &block_segment,
            &repocost_segment,
        ] {
            if !seg.is_empty() {
                row3_right.push_str(seg);
                row3_right.push_str(&sep_bullet);
            }
        }
        row3_right.push_str(&cost_segment);
    } else {
        let mut pre = String::new();
        if !chime_segment.is_empty() {
            pre = chime_segment.clone();
        }
        for extra in [&mcphealth_segment, &limits_segment, &compact_segment] {
            if extra.is_empty() {
                continue;
            }
            if !pre.is_empty() {
                pre.push_str(&sep_bullet);
            }
            pre.push_str(extra);
        }
        row3_right.push_str(&pre);
    }
    let mut row3_right_len = vis_len(&row3_right) as i64;

    let mut mcp_to_use = String::new();
    if !mcp_segment.is_empty() {
        mcp_to_use = mcp_segment.clone();
        let fits = |candidate: &str, rlen: i64| -> bool {
            (vis_len(candidate) as i64) + rlen + 2 <= row_width
        };
        if !mcp_segment_expanded.is_empty() {
            if fits(
                &format!("{}{}", RESET, mcp_segment_expanded),
                row3_right_len,
            ) {
                mcp_to_use = mcp_segment_expanded.clone();
            } else {
                for t in &mcp_segments_truncated {
                    if fits(&format!("{}{}", RESET, t), row3_right_len) {
                        mcp_to_use = t.clone();
                        break;
                    }
                }
            }
        }
    }

    let mut row3_left = String::from(RESET);
    if !mcp_to_use.is_empty() {
        row3_left.push_str(&mcp_to_use);
    } else if !time_segment.is_empty()
        || !cost_segment.is_empty()
        || !chime_segment.is_empty()
        || !speed_segment.is_empty()
        || !burn_segment.is_empty()
        || !block_segment.is_empty()
        || !limits_segment.is_empty()
        || !mcphealth_segment.is_empty()
        || !compact_segment.is_empty()
        || !repocost_segment.is_empty()
    {
        if !cost_segment.is_empty() {
            row3_left.push_str(&cost_segment);
            if !time_segment.is_empty() {
                row3_left.push_str(&sep_bullet);
                row3_left.push_str(&time_segment);
            }
            if !speed_segment.is_empty() {
                row3_left.push_str(&sep_bullet);
                row3_left.push_str(&speed_segment);
            }
        } else if !time_segment.is_empty() {
            row3_left.push_str(&time_segment);
            if !speed_segment.is_empty() {
                row3_left.push_str(&sep_bullet);
                row3_left.push_str(&speed_segment);
            }
        }
        for extra in [
            &tmux_segment,
            &burn_segment,
            &block_segment,
            &repocost_segment,
            &limits_segment,
            &mcphealth_segment,
            &compact_segment,
        ] {
            if extra.is_empty() {
                continue;
            }
            if row3_left != RESET {
                row3_left.push_str(&sep_bullet);
            }
            row3_left.push_str(extra);
        }
        if !chime_segment.is_empty() {
            if row3_left != RESET {
                row3_left.push_str(&sep_bullet);
            }
            row3_left.push_str(&chime_segment);
        }
        row3_right = String::from(RESET);
        row3_right_len = vis_len(&row3_right) as i64;
    }
    let _ = row3_right_len;

    // ── Minimal-mode pill ────────────────────────────────────────
    if sl_mode == "minimal" {
        let mut pill_pct = pct * 100 / 80;
        if pill_pct > 100 {
            pill_pct = 100;
        }
        let mut tier = pill_pct / 10;
        if tier > 9 {
            tier = 9;
        }
        if tier < 0 {
            tier = 0;
        }
        let pill = format!(
            "{}{}{}{} {}% {}{}{}{}",
            theme.tier_fg[tier as usize],
            PL_LEFT,
            theme.tier_bg[tier as usize],
            "\x1b[38;2;18;20;25m",
            pct,
            RESET,
            theme.tier_fg[tier as usize],
            PL_RIGHT,
            RESET
        );
        row1_left.push_str(&sep_bullet);
        row1_left.push_str(&pill);
        if !dirty_segment.is_empty() {
            row1_left.push_str(&sep_bullet);
            row1_left.push_str(&dirty_segment);
        }
        out.push_str(&justified_row(row_width, &row1_left, RESET));
    }

    // ── Progress bar ─────────────────────────────────────────────
    if sl_mode != "minimal" {
        let mut bell_icon = "";
        if !vol_num.is_nan() && vol_num <= 0.0 {
            bell_icon = BELL_OFF_ICON;
        } else if vol_num.is_nan() {
            // awk treats a non-numeric volume as 0, so the icon shows.
            bell_icon = BELL_OFF_ICON;
        }
        let mut bar_area_est = row_width - 2;
        if bar_area_est > 78 {
            bar_area_est = 78;
        }
        if bar_area_est < 20 {
            bar_area_est = 20;
        }
        let dark_zone = bar_area_est - bar_area_est * 80 / 100;

        let compact_time = if api_fmt.is_empty() {
            String::new()
        } else {
            format!("{} ", api_fmt)
        };
        let compact_cost = if formatted_cost == "0.00" {
            String::new()
        } else {
            format!("${} ", formatted_cost)
        };
        let mut bar_right_label = String::new();
        if sl_mode == "compact" {
            let mut t = format!("{}{}{}", compact_time, compact_cost, bell_icon);
            if (char_len(&t) as i64) > dark_zone {
                t = format!("{}{}", compact_cost, bell_icon);
            }
            if (char_len(&t) as i64) > dark_zone {
                t = bell_icon.to_string();
            }
            bar_right_label = t;
        }
        out.push_str(&bar::render_bar(
            theme,
            row_width,
            max_bar,
            pct,
            &ctx_label,
            "",
            Some(80),
            &bar_right_label,
        ));
    }

    if sl_mode == "full" {
        out.push('\n');
        out.push_str(&justified_row(row_width, &row3_left, &row3_right));
    }
    Ok(out)
}

// ── Git cache ────────────────────────────────────────────────────
#[derive(Default)]
struct GitCache {
    dirty: String,
    added: String,
    removed: String,
    branch: String,
    #[allow(dead_code)]
    remote: String,
    worktree: String,
    ahead: String,
    behind: String,
}

fn git_cache(git_dir: &str, shell_cwd: &mut PathBuf) -> GitCache {
    let cache_file = PathBuf::from(format!("/tmp/nerdflair-git-{}", cksum(git_dir.as_bytes())));
    let fresh = cache_file.is_file() && file_age(&cache_file) < GIT_CACHE_TTL;
    let mut computed: Option<String> = None;
    if !fresh {
        if Path::new(git_dir).is_dir() {
            *shell_cwd = PathBuf::from(git_dir);
        }
        let d: &Path = shell_cwd.as_path();
        let (status, _) = proc::out_raw(
            "git",
            &[
                "-c",
                "core.useBuiltinFSMonitor=false",
                "status",
                "--porcelain",
                "--ignore-submodules=dirty",
            ],
            Some(d),
        );
        let dirty = status.bytes().filter(|b| *b == b'\n').count() as i64;
        let mut added = 0i64;
        let mut removed = 0i64;
        if dirty > 0 {
            let (numstat, ok) = proc::out_raw("git", &["diff", "--numstat", "HEAD"], Some(d));
            let numstat = if ok {
                numstat
            } else {
                proc::out_raw("git", &["diff", "--numstat"], Some(d)).0
            };
            for line in numstat.lines() {
                let mut it = line.split('\t');
                let a = it.next().unwrap_or("");
                let r = it.next().unwrap_or("");
                if a == "-" {
                    continue;
                }
                if let Some(v) = bash_int(a) {
                    added += v;
                }
                if let Some(v) = bash_int(r) {
                    removed += v;
                }
            }
            let (others, _) = proc::out_raw(
                "git",
                &["ls-files", "--others", "--exclude-standard"],
                Some(d),
            );
            let mut ucount = 0i64;
            for file in others.lines() {
                ucount += 1;
                if ucount > 100 {
                    break;
                }
                if let Ok(bytes) = std::fs::read(d.join(file)) {
                    added += bytes.iter().filter(|b| **b == b'\n').count() as i64;
                }
            }
        }
        let (mut branch, ok) =
            proc::out("git", &["symbolic-ref", "--quiet", "--short", "HEAD"], Some(d));
        if !ok {
            branch = proc::out("git", &["rev-parse", "--short", "HEAD"], Some(d)).0;
        }
        let (common, _) = proc::out("git", &["rev-parse", "--git-common-dir"], Some(d));
        let (gdir, _) = proc::out("git", &["rev-parse", "--git-dir"], Some(d));
        let worktree = if common != gdir { "1" } else { "0" };
        let (remote_raw, _) = proc::out("git", &["remote", "get-url", "origin"], Some(d));
        let remote = rewrite_remote(&remote_raw);
        let mut ahead = "0".to_string();
        let mut behind = "0".to_string();
        let (ud, ok) = proc::out(
            "git",
            &["rev-list", "--count", "--left-right", "@{upstream}...HEAD"],
            Some(d),
        );
        if ok {
            let b: String = ud.chars().take_while(|c| c.is_ascii_digit()).collect();
            let a: String = {
                let mut s: Vec<char> = Vec::new();
                for c in ud.chars().rev() {
                    if c.is_ascii_digit() {
                        s.push(c);
                    } else {
                        break;
                    }
                }
                s.reverse();
                s.into_iter().collect()
            };
            behind = if b.is_empty() { "0".into() } else { b };
            ahead = if a.is_empty() { "0".into() } else { a };
        }
        let payload = format!(
            "{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
            dirty, added, removed, branch, remote, worktree, ahead, behind
        );
        let _ = std::fs::write(&cache_file, &payload);
        computed = Some(payload);
    }
    let content = std::fs::read_to_string(&cache_file)
        .ok()
        .or(computed)
        .unwrap_or_default();
    let p = read_ifs_unit(&content, 8);
    GitCache {
        dirty: p[0].clone(),
        added: p[1].clone(),
        removed: p[2].clone(),
        branch: p[3].clone(),
        remote: p[4].clone(),
        worktree: p[5].clone(),
        ahead: p[6].clone(),
        behind: p[7].clone(),
    }
}

fn rewrite_remote(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    let mut r = s.to_string();
    if let Some(rest) = r.strip_prefix("git@github.com:") {
        r = format!("https://github.com/{}", rest);
    } else if let Some(rest) = r.strip_prefix("git@") {
        if let Some(i) = rest.find(':') {
            r = format!("https://{}/{}", &rest[..i], &rest[i + 1..]);
        }
    }
    if let Some(stripped) = r.strip_suffix(".git") {
        r = stripped.to_string();
    }
    r
}

// ── multi-repo fitting ───────────────────────────────────────────
fn render_multi_entry(e: &str, width: i64) -> String {
    let (repo, br) = match e.find(':') {
        Some(i) => (&e[..i], &e[i + 1..]),
        None => (e, ""),
    };
    let rlen = char_len(repo) as i64;
    let blen = char_len(br) as i64;
    if (char_len(e) as i64) <= width {
        return e.to_string();
    }
    let mut avail = width - 1;
    if avail < 2 {
        avail = 2;
    }
    let half = avail / 2;
    let (mut max_repo, mut max_br);
    if rlen <= half {
        max_repo = rlen;
        max_br = avail - max_repo;
    } else if blen <= avail - half {
        max_br = blen;
        max_repo = avail - max_br;
    } else {
        max_repo = half;
        max_br = avail - max_repo;
    }
    if max_repo < MULTI_SIDE_MIN {
        max_repo = MULTI_SIDE_MIN;
    }
    if max_br < MULTI_SIDE_MIN {
        max_br = MULTI_SIDE_MIN;
    }
    let repo_out = if rlen > max_repo {
        format!("{}{}", char_slice(repo, 0, (max_repo - 1) as usize), ELLIPSIS)
    } else {
        repo.to_string()
    };
    let br_out = if blen > max_br {
        format!("{}{}", char_slice(br, 0, (max_br - 1) as usize), ELLIPSIS)
    } else {
        br.to_string()
    };
    format!("{}:{}", repo_out, br_out)
}

fn fit_multi_branches(list: &str, target: i64) -> String {
    let entries: Vec<String> = {
        let mut v = Vec::new();
        let mut rest = list.to_string();
        while let Some(i) = rest.find(", ") {
            v.push(rest[..i].to_string());
            rest = rest[i + 2..].to_string();
        }
        v.push(rest);
        v
    };
    let n = entries.len() as i64;
    let sep_cost = (n - 1) * MULTI_SEP_W;
    let content_budget = target - sep_cost;

    let full: i64 = entries.iter().map(|e| char_len(e) as i64).sum();
    if full <= content_budget {
        return entries.join(MULTI_SEP);
    }

    let mut floor = Vec::with_capacity(entries.len());
    let mut alloc = Vec::with_capacity(entries.len());
    for e in &entries {
        let elen = char_len(e) as i64;
        let (rp, bp) = match e.find(':') {
            Some(i) => (&e[..i], &e[i + 1..]),
            None => (e.as_str(), ""),
        };
        let mut rmin = char_len(rp) as i64;
        let mut bmin = char_len(bp) as i64;
        if rmin > MULTI_SIDE_MIN {
            rmin = MULTI_SIDE_MIN + 1;
        }
        if bmin > MULTI_SIDE_MIN {
            bmin = MULTI_SIDE_MIN + 1;
        }
        let mut fl = rmin + 1 + bmin;
        if fl > elen {
            fl = elen;
        }
        floor.push(fl);
        alloc.push(elen);
    }
    let floor_sum: i64 = floor.iter().sum();
    if floor_sum > content_budget {
        return String::new();
    }
    let mut total: i64 = alloc.iter().sum();
    while total > content_budget {
        let mut longest: i64 = -1;
        let mut longest_len: i64 = -1;
        for i in 0..entries.len() {
            if alloc[i] > floor[i] && alloc[i] > longest_len {
                longest_len = alloc[i];
                longest = i as i64;
            }
        }
        if longest < 0 {
            break;
        }
        alloc[longest as usize] -= 1;
        total -= 1;
    }
    entries
        .iter()
        .enumerate()
        .map(|(i, e)| render_multi_entry(e, alloc[i]))
        .collect::<Vec<_>>()
        .join(MULTI_SEP)
}

// ── ccusage / mcp health / repo cost ─────────────────────────────
fn env_int(k: &str, default: i64) -> i64 {
    std::env::var(k)
        .ok()
        .filter(|s| !s.is_empty())
        .and_then(|s| bash_int(&s))
        .unwrap_or(default)
}

fn shq(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
// The bash builds `"${_cu_cache}.tmp"` by concatenation, so quoting must not
// swallow the suffix; keep the bare form for those interpolations.
fn shq_bare(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn resolve_ccusage_bin() -> Option<PathBuf> {
    if let Ok(b) = std::env::var("NERDFLAIR_CCUSAGE_BIN") {
        if !b.is_empty() && proc::is_exec(Path::new(&b)) {
            return Some(PathBuf::from(b));
        }
    }
    let cc = proc::which("ccusage")?;
    let real = std::fs::canonicalize(&cc).unwrap_or(cc.clone());
    let root = real.parent()?.parent()?.to_path_buf();
    for plat in ["linux-x64", "linux-arm64", "darwin-arm64", "darwin-x64"] {
        let cand = root.join(format!("node_modules/@ccusage/ccusage-{}/bin/ccusage", plat));
        if proc::is_exec(&cand) {
            return Some(cand);
        }
    }
    Some(cc)
}

fn mcp_health(uid: u32, _now: i64) -> (String, String, String) {
    let ttl = env_int("NERDFLAIR_MCP_HEALTH_TTL", 300);
    let mut ok = String::new();
    let mut bad = String::new();
    let mut warn = String::new();
    if std::env::var("NERDFLAIR_MCP_HEALTH").unwrap_or_else(|_| "1".into()) == "0" {
        return (ok, bad, warn);
    }
    if proc::which("claude").is_none() {
        return (ok, bad, warn);
    }
    let cache = PathBuf::from(format!("/tmp/nerdflair-mcphealth-{}", uid));
    let lock = PathBuf::from(format!("{}.lock", cache.display()));
    let mut fresh = false;
    if cache.is_file() {
        if file_age(&cache) < ttl {
            fresh = true;
        }
        if let Ok(t) = std::fs::read_to_string(&cache) {
            let p = read_ifs_unit(&t, 3);
            ok = p[0].clone();
            bad = p[1].clone();
            warn = p[2].clone();
        }
    }
    if lock.is_dir() && file_age(&lock) > 300 {
        let _ = std::fs::remove_dir(&lock);
    }
    if !fresh && std::fs::create_dir(&lock).is_ok() {
        let script = format!(
            "trap 'rmdir {lock} 2>/dev/null' EXIT; \
             _out=$(timeout 30 claude mcp list 2>/dev/null || true); _o=0; _b=0; _w=0; \
             while IFS= read -r _ln; do case \"$_ln\" in \
             *Connected*) _o=$((_o+1)) ;; \
             *\"Failed to connect\"*) _b=$((_b+1)) ;; \
             *\"Needs authentication\"*) _w=$((_w+1)) ;; \
             esac; done <<< \"$_out\"; \
             [ $((_o+_b+_w)) -gt 0 ] && printf '%s\\037%s\\037%s' \"$_o\" \"$_b\" \"$_w\" > {cache}.tmp \
             && mv -f {cache}.tmp {cache}",
            lock = shq(&lock.to_string_lossy()),
            cache = shq_bare(&cache.to_string_lossy()),
        );
        // `<<<` is a bashism; run the refresher under bash explicitly.
        let mut c = std::process::Command::new("bash");
        c.arg("-c")
            .arg(&script)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        let _ = c.spawn();
    }
    (ok, bad, warn)
}

/// A well-formed usage row: exactly 4 columns, a plausible epoch, and a cost in
/// a sane range. Spliced rows from the old non-atomic append can carry an epoch
/// concatenated onto a cost; unbounded, one such row wins the per-session max
/// and dominates the sum. Mirrors the awk predicate in statusline.sh.
fn usage_row_ok(cols: &[&str], maxcost: f64) -> bool {
    if cols.len() != 4 {
        return false;
    }
    let ts = fmtx::awk_num(cols[0]);
    let v = fmtx::awk_num(cols[3]);
    (1_600_000_000.0..=4_000_000_000.0).contains(&ts) && v > 0.0 && v < maxcost
}

fn repo_cost_segment(
    f: &Fields,
    git_dir: &str,
    project_dir: &str,
    uid: u32,
    now: i64,
    pal: &Palette,
) -> String {
    if std::env::var("NERDFLAIR_REPO_COST").unwrap_or_else(|_| "1".into()) == "0" {
        return String::new();
    }
    if f.session_id.is_empty() {
        return String::new();
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let cost_file = PathBuf::from(
        std::env::var("NERDFLAIR_REPO_COST_FILE")
            .unwrap_or_else(|_| format!("{}/.claude/nerdflair-usage.tsv", home)),
    );
    let ttl = env_int("NERDFLAIR_REPO_COST_TTL", 60);
    let days = env_int("NERDFLAIR_REPO_COST_DAYS", 30);

    let mut slug = String::new();
    if !git_dir.is_empty() {
        let mut top = git_dir.strip_suffix("/.git").unwrap_or(git_dir).to_string();
        if let Some(i) = top.find("/.git/") {
            top = top[..i].to_string();
        }
        slug = match top.rfind('/') {
            Some(i) => top[i + 1..].to_string(),
            None => top,
        };
    }
    if slug.is_empty() && !project_dir.is_empty() {
        slug = match project_dir.rfind('/') {
            Some(i) => project_dir[i + 1..].to_string(),
            None => project_dir.to_string(),
        };
    }
    if slug.is_empty() {
        return String::new();
    }

    let stamp = PathBuf::from(format!(
        "/tmp/nerdflair-repocost-{}-{}",
        uid,
        slugify(&f.session_id)
    ));
    let maxcost = env_int("NERDFLAIR_REPO_COST_MAX", 100_000) as f64;
    let mut due = true;
    if stamp.is_file() && file_age(&stamp) < ttl {
        due = false;
    }
    if due && !f.cost.is_empty() && f.cost != "0" {
        use std::io::Write as _;
        if let Ok(mut fh) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&cost_file)
        {
            // ONE write_all of a pre-built line. `write!` on a std::fs::File
            // is unbuffered and emits a separate write() per format fragment;
            // O_APPEND makes each fragment atomic but lets another process
            // interleave BETWEEN them. That spliced an epoch onto a cost and
            // produced a $1,787,994,297.21 repo total.
            let line = format!("{}\t{}\t{}\t{}\n", now, f.session_id, slug, f.cost);
            if fh.write_all(line.as_bytes()).is_ok() {
                let _ = std::fs::write(&stamp, "");
            }
        }
        let bytes = std::fs::metadata(&cost_file).map(|m| m.len()).unwrap_or(0);
        let maxb = env_int("NERDFLAIR_REPO_COST_MAXBYTES", 2_000_000) as u64;
        if bytes > maxb {
            let lock = PathBuf::from(format!("{}.lock", cost_file.display()));
            // Clear a lock left by a process that died before removing it;
            // without this, compaction stops forever (observed: 12 days).
            if lock.is_dir() && file_age(&lock) > 300 {
                let _ = std::fs::remove_dir(&lock);
            }
            if std::fs::create_dir(&lock).is_ok() {
                let cutoff = now - days * 86400;
                if let Ok(text) = std::fs::read_to_string(&cost_file) {
                    let kept: String = text
                        .lines()
                        .filter(|l| {
                            let cols: Vec<&str> = l.split('\t').collect();
                            usage_row_ok(&cols, maxcost)
                                && fmtx::awk_num(cols[0]) >= cutoff as f64
                        })
                        .map(|l| format!("{}\n", l))
                        .collect();
                    let tmp = PathBuf::from(format!("{}.tmp", cost_file.display()));
                    if std::fs::write(&tmp, kept).is_ok() {
                        let _ = std::fs::rename(&tmp, &cost_file);
                    }
                }
                let _ = std::fs::remove_dir(&lock);
            }
        }
    }

    let memo = PathBuf::from(format!(
        "/tmp/nerdflair-repocost-total-{}-{}",
        uid,
        slugify(&slug)
    ));
    let mut total = String::new();
    if !due && memo.is_file() {
        total = std::fs::read_to_string(&memo).unwrap_or_default();
        while total.ends_with('\n') {
            total.pop();
        }
    } else if let Ok(text) = std::fs::read_to_string(&cost_file) {
        let cutoff = (now - days * 86400) as f64;
        let mut m: std::collections::HashMap<String, f64> = std::collections::HashMap::new();
        for line in text.lines() {
            let cols: Vec<&str> = line.split('\t').collect();
            if !usage_row_ok(&cols, maxcost) {
                continue;
            }
            if fmtx::awk_num(cols[0]) < cutoff {
                continue;
            }
            if cols[2] != slug {
                continue;
            }
            let v = fmtx::awk_num(cols[3]);
            let e = m.entry(cols[1].to_string()).or_insert(0.0);
            if v > *e {
                *e = v;
            }
        }
        let t: f64 = m.values().sum();
        if t > 0.0 {
            total = fmtx::f2(t);
        }
        let _ = std::fs::write(&memo, &total);
    }
    if !total.is_empty() && total != "0.00" {
        return format!("{}{} ${}{}", pal.dark_green, REPO_ICON, total, RESET);
    }
    String::new()
}

// ── ccusage line scanners (bash =~ equivalents) ──────────────────
fn scan_burn(s: &str) -> Option<String> {
    let b = s.as_bytes();
    for i in 0..b.len() {
        if b[i] != b'$' {
            continue;
        }
        let mut j = i + 1;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        if j == i + 1 || j >= b.len() || b[j] != b'.' {
            continue;
        }
        let mut k = j + 1;
        while k < b.len() && b[k].is_ascii_digit() {
            k += 1;
        }
        if k == j + 1 {
            continue;
        }
        if s[k..].starts_with("/hr") {
            return Some(s[i + 1..k].to_string());
        }
    }
    None
}

fn scan_block_cost(s: &str) -> Option<String> {
    let b = s.as_bytes();
    for i in 0..b.len() {
        if b[i] != b'$' {
            continue;
        }
        let mut j = i + 1;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        if j == i + 1 || j >= b.len() || b[j] != b'.' {
            continue;
        }
        let mut k = j + 1;
        while k < b.len() && b[k].is_ascii_digit() {
            k += 1;
        }
        if k == j + 1 {
            continue;
        }
        if s[k..].starts_with(" block") {
            return Some(s[i..k].to_string());
        }
    }
    None
}

/// `\(([0-9]+h )?([0-9]+m) left\)`
fn scan_block_left(s: &str) -> Option<String> {
    let b = s.as_bytes();
    for i in 0..b.len() {
        if b[i] != b'(' {
            continue;
        }
        let mut p = i + 1;
        let mut hours = String::new();
        // optional "<digits>h "
        let mut q = p;
        while q < b.len() && b[q].is_ascii_digit() {
            q += 1;
        }
        if q > p && q + 1 < b.len() && b[q] == b'h' && b[q + 1] == b' ' {
            hours = s[p..q + 1].to_string();
            p = q + 2;
        }
        let mut r = p;
        while r < b.len() && b[r].is_ascii_digit() {
            r += 1;
        }
        if r == p || r >= b.len() || b[r] != b'm' {
            continue;
        }
        let mins = s[p..r + 1].to_string();
        if s[r + 1..].starts_with(" left)") {
            return Some(format!("{}{}", hours, mins));
        }
    }
    None
}
