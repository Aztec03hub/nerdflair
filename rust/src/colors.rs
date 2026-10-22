//! Palettes and glyphs, transcribed byte-for-byte from scripts/statusline.sh.

// Some palette entries and the TIER_WIND ramp are transcribed but never
// reached: the bash assigns them and no rendered cell reads them back. They
// are kept so the transcription stays auditable against the source.
#[allow(dead_code)]
pub struct Palette {
    pub blue: &'static str,
    pub magenta: &'static str,
    pub cyan: &'static str,
    pub state_color: &'static str,
    pub mauve: &'static str,
    pub mcp_color: &'static str,
    pub dark_green: &'static str,
    pub alert: &'static str,
    pub red: &'static str,
    pub green: &'static str,
    pub orange: &'static str,
    pub mustard: &'static str,
    pub sage: &'static str,
    pub cost_green: &'static str,
    pub diff_plus: &'static str,
    pub diff_minus: &'static str,
    pub dim: &'static str,
}

pub const RESET: &str = "\x1b[0m";

pub const VIBRANT: Palette = Palette {
    blue: "\x1b[38;2;95;179;255m",
    magenta: "\x1b[38;2;198;120;221m",
    cyan: "\x1b[38;2;86;182;194m",
    state_color: "\x1b[38;2;72;200;170m",
    mauve: "\x1b[38;2;145;130;155m",
    mcp_color: "\x1b[38;2;195;130;140m",
    dark_green: "\x1b[38;2;110;155;95m",
    alert: "\x1b[38;2;220;175;100m",
    red: "\x1b[38;2;224;108;117m",
    green: "\x1b[38;2;152;195;121m",
    orange: "\x1b[38;2;235;150;60m",
    mustard: "\x1b[38;2;180;155;95m",
    sage: "\x1b[38;2;190;150;120m",
    cost_green: "\x1b[38;2;90;120;82m",
    diff_plus: "\x1b[38;2;130;190;110m",
    diff_minus: "\x1b[38;2;235;100;90m",
    dim: "\x1b[38;2;85;90;100m",
};

pub const MONO: Palette = Palette {
    blue: "\x1b[38;2;190;190;190m",
    magenta: "\x1b[38;2;170;170;170m",
    cyan: "\x1b[38;2;180;180;180m",
    state_color: "\x1b[38;2;150;150;150m",
    mauve: "\x1b[38;2;140;140;140m",
    mcp_color: "\x1b[38;2;170;170;170m",
    orange: "\x1b[38;2;200;200;200m",
    dark_green: "\x1b[38;2;150;150;150m",
    alert: "\x1b[38;2;200;200;200m",
    red: "\x1b[38;2;210;210;210m",
    green: "\x1b[38;2;170;170;170m",
    mustard: "\x1b[38;2;185;185;185m",
    sage: "\x1b[38;2;145;145;145m",
    cost_green: "\x1b[38;2;150;150;150m",
    diff_plus: "\x1b[38;2;160;160;160m",
    diff_minus: "\x1b[38;2;160;160;160m",
    dim: "\x1b[38;2;90;90;90m",
};

pub const MUTED: Palette = Palette {
    blue: "\x1b[38;2;140;170;210m",
    magenta: "\x1b[38;2;170;145;185m",
    cyan: "\x1b[38;2;130;165;170m",
    state_color: "\x1b[38;2;95;175;150m",
    mauve: "\x1b[38;2;140;135;150m",
    mcp_color: "\x1b[38;2;170;138;142m",
    orange: "\x1b[38;2;200;160;100m",
    dark_green: "\x1b[38;2;125;145;115m",
    alert: "\x1b[38;2;185;165;125m",
    red: "\x1b[38;2;185;140;140m",
    green: "\x1b[38;2;150;170;135m",
    mustard: "\x1b[38;2;185;170;115m",
    sage: "\x1b[38;2;165;145;125m",
    cost_green: "\x1b[38;2;120;135;118m",
    diff_plus: "\x1b[38;2;115;135;110m",
    diff_minus: "\x1b[38;2;175;125;118m",
    dim: "\x1b[38;2;95;95;105m",
};

pub fn palette(mode: &str) -> &'static Palette {
    match mode {
        "mono" => &MONO,
        "muted" => &MUTED,
        _ => &VIBRANT,
    }
}

// ── Progress bar tiers ────────────────────────────────────────────
#[allow(dead_code)]
pub struct BarTheme {
    pub tier_bg: [&'static str; 10],
    pub tier_fg: [&'static str; 10],
    pub empty_bg: &'static str,
    pub empty_fg: &'static str,
    pub light_fg: &'static str,
    pub label_covered_fg: &'static str,
    pub grad_bg_r: [i64; 10],
    pub grad_bg_g: [i64; 10],
    pub grad_bg_b: [i64; 10],
    pub grad_wn_r: [i64; 10],
    pub grad_wn_g: [i64; 10],
    pub grad_wn_b: [i64; 10],
    pub logo_peak: (i64, i64, i64),
}

pub const BAR_VIBRANT: BarTheme = BarTheme {
    tier_bg: [
        "\x1b[48;2;42;48;46m",
        "\x1b[48;2;46;56;48m",
        "\x1b[48;2;50;65;50m",
        "\x1b[48;2;56;76;54m",
        "\x1b[48;2;64;88;56m",
        "\x1b[48;2;76;100;56m",
        "\x1b[48;2;95;105;55m",
        "\x1b[48;2;120;115;58m",
        "\x1b[48;2;148;125;60m",
        "\x1b[48;2;170;130;62m",
    ],
    tier_fg: [
        "\x1b[38;2;42;48;46m",
        "\x1b[38;2;46;56;48m",
        "\x1b[38;2;50;65;50m",
        "\x1b[38;2;56;76;54m",
        "\x1b[38;2;64;88;56m",
        "\x1b[38;2;76;100;56m",
        "\x1b[38;2;95;105;55m",
        "\x1b[38;2;120;115;58m",
        "\x1b[38;2;148;125;60m",
        "\x1b[38;2;170;130;62m",
    ],
    empty_bg: "\x1b[48;2;35;38;45m",
    empty_fg: "\x1b[38;2;35;38;45m",
    light_fg: "\x1b[38;2;85;90;100m",
    label_covered_fg: "\x1b[38;2;18;20;25m",
    grad_bg_r: [48, 50, 55, 65, 88, 115, 140, 160, 180, 200],
    grad_bg_g: [62, 74, 88, 105, 112, 116, 122, 125, 120, 55],
    grad_bg_b: [48, 48, 50, 52, 54, 55, 58, 60, 58, 50],
    grad_wn_r: [27, 29, 32, 38, 50, 66, 86, 109, 131, 153],
    grad_wn_g: [35, 43, 52, 63, 71, 78, 84, 91, 93, 66],
    grad_wn_b: [30, 30, 31, 31, 30, 29, 28, 30, 30, 27],
    logo_peak: (35, 38, 45),
};

pub const BAR_MONO: BarTheme = BarTheme {
    tier_bg: [
        "\x1b[48;2;60;60;60m",
        "\x1b[48;2;72;72;72m",
        "\x1b[48;2;84;84;84m",
        "\x1b[48;2;96;96;96m",
        "\x1b[48;2;108;108;108m",
        "\x1b[48;2;120;120;120m",
        "\x1b[48;2;135;135;135m",
        "\x1b[48;2;150;150;150m",
        "\x1b[48;2;170;170;170m",
        "\x1b[48;2;190;190;190m",
    ],
    tier_fg: [
        "\x1b[38;2;60;60;60m",
        "\x1b[38;2;72;72;72m",
        "\x1b[38;2;84;84;84m",
        "\x1b[38;2;96;96;96m",
        "\x1b[38;2;108;108;108m",
        "\x1b[38;2;120;120;120m",
        "\x1b[38;2;135;135;135m",
        "\x1b[38;2;150;150;150m",
        "\x1b[38;2;170;170;170m",
        "\x1b[38;2;190;190;190m",
    ],
    empty_bg: "\x1b[48;2;38;38;38m",
    empty_fg: "\x1b[38;2;38;38;38m",
    light_fg: "\x1b[38;2;90;90;90m",
    label_covered_fg: "\x1b[38;2;22;22;22m",
    grad_bg_r: [45, 55, 65, 76, 88, 100, 115, 132, 155, 185],
    grad_bg_g: [45, 55, 65, 76, 88, 100, 115, 132, 155, 185],
    grad_bg_b: [45, 55, 65, 76, 88, 100, 115, 132, 155, 185],
    grad_wn_r: [28, 35, 44, 54, 66, 78, 92, 107, 126, 146],
    grad_wn_g: [28, 35, 44, 54, 66, 78, 92, 107, 126, 146],
    grad_wn_b: [28, 35, 44, 54, 66, 78, 92, 107, 126, 146],
    logo_peak: (38, 38, 38),
};

pub const BAR_MUTED: BarTheme = BarTheme {
    tier_bg: [
        "\x1b[48;2;68;82;66m",
        "\x1b[48;2;70;85;68m",
        "\x1b[48;2;73;88;69m",
        "\x1b[48;2;76;90;68m",
        "\x1b[48;2;80;93;67m",
        "\x1b[48;2;85;96;65m",
        "\x1b[48;2;100;103;64m",
        "\x1b[48;2;130;122;68m",
        "\x1b[48;2;158;132;70m",
        "\x1b[48;2;178;132;68m",
    ],
    tier_fg: [
        "\x1b[38;2;68;82;66m",
        "\x1b[38;2;70;85;68m",
        "\x1b[38;2;73;88;69m",
        "\x1b[38;2;76;90;68m",
        "\x1b[38;2;80;93;67m",
        "\x1b[38;2;85;96;65m",
        "\x1b[38;2;100;103;64m",
        "\x1b[38;2;130;122;68m",
        "\x1b[38;2;158;132;70m",
        "\x1b[38;2;178;132;68m",
    ],
    empty_bg: "\x1b[48;2;38;40;45m",
    empty_fg: "\x1b[38;2;38;40;45m",
    light_fg: "\x1b[38;2;88;92;102m",
    label_covered_fg: "\x1b[38;2;20;24;20m",
    grad_bg_r: [48, 52, 55, 62, 76, 92, 110, 132, 150, 168],
    grad_bg_g: [52, 58, 65, 74, 86, 96, 104, 108, 104, 68],
    grad_bg_b: [50, 52, 54, 56, 58, 58, 60, 62, 60, 56],
    grad_wn_r: [33, 35, 37, 40, 44, 48, 62, 92, 120, 140],
    grad_wn_g: [47, 49, 52, 54, 57, 60, 66, 83, 93, 93],
    grad_wn_b: [31, 33, 34, 32, 31, 30, 28, 32, 34, 32],
    logo_peak: (38, 40, 45),
};

pub fn bar_theme(mode: &str) -> &'static BarTheme {
    match mode {
        "mono" => &BAR_MONO,
        "muted" => &BAR_MUTED,
        _ => &BAR_VIBRANT,
    }
}

// ── Glyphs (exact byte sequences from the bash `printf '\xNN'` calls) ──
pub const PL_RIGHT: &str = "\u{e0b4}"; // ee 82 b4
pub const PL_LEFT: &str = "\u{e0b6}"; // ee 82 b6
pub const ELLIPSIS: &str = "\u{2026}";
pub const DIRTY_ICON: &str = "\u{f044}"; // ef 81 84
pub const FOLDER_WORKTREE_ICON: &str = "\u{f1bb}"; // ef 86 bb
pub const FOLDER_ICON: &str = "\u{f024b}"; // f3 b0 89 8b
pub const HOME_ICON: &str = "\u{f015}"; // ef 80 95
pub const BRANCH_ICON: &str = "\u{f062c}"; // f3 b0 98 ac
pub const MODEL_ICON: &str = "\u{f51b}"; // ef 94 9b
pub const TIME_ICON: &str = "\u{f017}"; // fa-clock_o
pub const MCP_ICON: &str = "\u{f1e6}"; // ef 87 a6
pub const STYLE_EXPLANATORY: &str = "\u{f05a}"; // ef 81 9a
pub const STYLE_LEARNING: &str = "\u{f059}"; // ef 81 99
pub const STYLE_PROACTIVE: &str = "\u{f0df8}"; // f3 b0 b7 b8
pub const THINK_ICON: &str = "\u{f0820}"; // f3 b0 a0 a0
pub const FAST_ICON: &str = "\u{f1807}"; // f3 b1 a0 87
pub const REPO_ICON: &str = "\u{f401}"; // ef 90 81
pub const COST_ICON: &str = "\u{f155}"; // ef 85 95
pub const BURN_ICON: &str = "\u{f0238}"; // f3 b1 97 b6  // md-fire (was f15f6 md-fridge_variant_alert_outline)
pub const BLOCK_ICON: &str = "\u{f094}"; // ef 82 94
pub const VOL_ICON: &str = "\u{f028}"; // ef 80 a8
pub const SPEED_ICON: &str = "\u{f04c5}"; // f3 b0 93 85 (literal in source)
// The bash writes `printf '\xf3\xb0\xe5\xa9'` — which is NOT valid UTF-8
// (0xe5 is not a continuation byte). Bash therefore treats it as FOUR
// single-byte characters, and the bar renders four mojibake cells. Faithful
// reproduction needs raw bytes, so each byte is carried as a private-use
// placeholder in plane 16 and swapped back to its byte at write time.
pub const BELL_OFF_ICON: &str = "\u{10FF00}\u{10FF01}\u{10FF02}\u{10FF03}";

/// Replace the raw-byte placeholders with the bytes they stand for.
pub fn emit_bytes(s: &str) -> Vec<u8> {
    if !s.contains('\u{10FF00}') && !s.contains('\u{10FF01}')
        && !s.contains('\u{10FF02}') && !s.contains('\u{10FF03}') {
        return s.as_bytes().to_vec();
    }
    let mut out = Vec::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\u{10FF00}' => out.push(0xf3),
            '\u{10FF01}' => out.push(0xb0),
            '\u{10FF02}' => out.push(0xe5),
            '\u{10FF03}' => out.push(0xa9),
            _ => {
                let mut buf = [0u8; 4];
                out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
            }
        }
    }
    out
}
pub const TMUX_ICON: &str = "\u{ea85}";
pub const ARROW_UP: &str = "\u{2191}";
pub const ARROW_DOWN: &str = "\u{2193}";
pub const CROSS: &str = "\u{2717}";
pub const DOWN_DASHED: &str = "\u{f051f} ";  // md-timer_sand (21e3 is absent from JetBrainsMono NF)

pub const NF_BRAND_COLOR: &str = "\x1b[38;2;145;130;155m";

/// The 17-element logo run: 9 icons interleaved with 8 spaces.
pub const LOGO_ICONS: [&str; 17] = [
    "\u{e838}",
    " ",
    "\u{f0bf7}",
    " ",
    "\u{f0c1e}",
    " ",
    "\u{f0bf4}",
    " ",
    "\u{f335}",
    " ",
    "\u{f0c0c}",
    " ",
    "\u{f0beb}",
    " ",
    "\u{f0c03}",
    " ",
    "\u{f0c1e}",
];

// ── 256-colour clamp guard ─────────────────────────────────────────
// Claude Code forces chalk to 256 colours when $TMUX is set and
// CLAUDE_CODE_TMUX_TRUECOLOR is empty, converting every 24-bit colour with
// ansi-styles rgbToAnsi256. Indices 16 and 17 are the ones colour schemes
// remap (Catppuccin Mocha: peach, rosewater), so the near-black splash and
// empty bar turn orange. In that mode every 38;2 / 48;2 colour that would
// land on 16 or 17 becomes a grey on the 232-255 ramp instead. The bash twin
// is _nf_safe256 / _nf_flush in scripts/statusline.sh; both must agree.

/// True when Claude Code will clamp this render's output to 256 colours.
pub fn clamp256_active() -> bool {
    std::env::var_os("TMUX").map_or(false, |v| !v.is_empty())
        && std::env::var_os("CLAUDE_CODE_TMUX_TRUECOLOR").map_or(true, |v| v.is_empty())
}

/// (r,g,b) unchanged unless rgbToAnsi256 maps it to 16 or 17; then the grey
/// (L,L,L), L = max(8, rounded Rec. 601 luminance), which lands on 232+.
pub fn safe256(r: u32, g: u32, b: u32) -> (u32, u32, u32) {
    // rgbToAnsi256: greys r<8 -> 16; otherwise the cube index is 16 or 17
    // exactly when round(r/255*5) == round(g/255*5) == 0 (r,g <= 25) and
    // round(b/255*5) <= 1 (b <= 76).
    let bad = if r == g && g == b { r < 8 } else { r <= 25 && g <= 25 && b <= 76 };
    if !bad {
        return (r, g, b);
    }
    let l = ((299 * r + 587 * g + 114 * b + 500) / 1000).max(8);
    (l, l, l)
}

/// Rewrites every `[38;2;R;G;B` / `;48;2;R;G;B` (preceded by `[` or `;`)
/// through safe256. Untouched colours keep their original text.
pub fn safe256_sgr(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut last = 0;
    let mut i = 0;
    while i + 1 < b.len() {
        if (b[i] == b'[' || b[i] == b';')
            && (b[i + 1..].starts_with(b"38;2;") || b[i + 1..].starts_with(b"48;2;"))
        {
            let mut j = i + 6;
            let mut v = [0u32; 3];
            let mut ok = true;
            for (k, slot) in v.iter_mut().enumerate() {
                let st = j;
                while j < b.len() && b[j].is_ascii_digit() {
                    *slot = slot.saturating_mul(10).saturating_add((b[j] - b'0') as u32);
                    j += 1;
                }
                if j == st || (k < 2 && (j >= b.len() || b[j] != b';')) {
                    ok = false;
                    break;
                }
                if k < 2 {
                    j += 1;
                }
            }
            if ok {
                let n = safe256(v[0], v[1], v[2]);
                if n != (v[0], v[1], v[2]) {
                    out.push_str(&s[last..i + 6]);
                    out.push_str(&format!("{};{};{}", n.0, n.1, n.2));
                    last = j;
                }
                i = j;
                continue;
            }
        }
        i += 1;
    }
    out.push_str(&s[last..]);
    out
}

#[cfg(test)]
mod safe256_tests {
    use super::*;

    /// ansi-styles rgbToAnsi256, transcribed from the JS.
    fn rgb_to_ansi256(r: u32, g: u32, b: u32) -> u32 {
        let js_round = |x: f64| (x + 0.5).floor() as u32;
        if r == g && g == b {
            if r < 8 { return 16; }
            if r > 248 { return 231; }
            return js_round(((r as f64 - 8.0) / 247.0) * 24.0) + 232;
        }
        16 + 36 * js_round(r as f64 / 255.0 * 5.0)
            + 6 * js_round(g as f64 / 255.0 * 5.0)
            + js_round(b as f64 / 255.0 * 5.0)
    }

    #[test]
    fn safe256_never_lands_on_16_or_17_and_leaves_the_rest_alone() {
        let axis: Vec<u32> = (0..=255).step_by(3).chain([25, 26, 76, 77, 255]).collect();
        for &r in &axis {
            for &g in &axis {
                for &b in &axis {
                    let (nr, ng, nb) = safe256(r, g, b);
                    let q = rgb_to_ansi256(r, g, b);
                    if q == 16 || q == 17 {
                        assert!(nr == ng && ng == nb && nr >= 8, "{r},{g},{b} -> not a ramp grey");
                        assert!(rgb_to_ansi256(nr, ng, nb) >= 232, "{r},{g},{b} -> {nr}");
                    } else {
                        assert_eq!((nr, ng, nb), (r, g, b), "changed a safe colour");
                    }
                }
            }
        }
        for v in 0..=255 { // every exact grey
            let n = safe256(v, v, v);
            let q = rgb_to_ansi256(n.0, n.1, n.2);
            assert!(q != 16 && q != 17, "grey {v}");
        }
    }

    #[test]
    fn safe256_sgr_rewrites_only_bad_colours() {
        let s = "\x1b[48;2;12;14;18m \x1b[1;38;2;72;78;74mX\x1b[38;2;10;10;70mY\x1b[38;2;3;3;3m";
        assert_eq!(
            safe256_sgr(s),
            "\x1b[48;2;14;14;14m \x1b[1;38;2;72;78;74mX\x1b[38;2;17;17;17mY\x1b[38;2;8;8;8m"
        );
    }
}
