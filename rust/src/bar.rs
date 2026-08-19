//! `_render_bar`, `_compute_gradient_cache`, `_compute_logo_gradient`.

use crate::colors::*;

fn sgr_bg(r: i64, g: i64, b: i64) -> String {
    format!("\x1b[48;2;{};{};{}m", r, g, b)
}
fn sgr_fg(r: i64, g: i64, b: i64) -> String {
    format!("\x1b[38;2;{};{};{}m", r, g, b)
}

struct GradCache {
    bg: Vec<String>,
    fg: Vec<String>,
}

fn compute_gradient_cache(
    theme: &BarTheme,
    filled: i64,
    body_area: i64,
    compact_mark_pct: Option<i64>,
) -> GradCache {
    let mut bg = Vec::new();
    let mut fg = Vec::new();
    for ci in 0..filled {
        // body_area is always >= 19 here, so the division is safe.
        let mut cpct = (ci + 1) * 100 / body_area;
        if let Some(m) = compact_mark_pct {
            if m > 0 && m < 100 {
                cpct = cpct * 100 / m;
                if cpct > 100 {
                    cpct = 100;
                }
            }
        }
        let mut ft = cpct * 9;
        if ft > 900 {
            ft = 900;
        }
        let mut lo = ft / 100;
        if lo > 8 {
            lo = 8;
        }
        let hi = lo + 1;
        let frac = ft - lo * 100;
        let (lo, hi) = (lo as usize, hi as usize);
        let r = theme.grad_bg_r[lo] + (theme.grad_bg_r[hi] - theme.grad_bg_r[lo]) * frac / 100;
        let g = theme.grad_bg_g[lo] + (theme.grad_bg_g[hi] - theme.grad_bg_g[lo]) * frac / 100;
        let b = theme.grad_bg_b[lo] + (theme.grad_bg_b[hi] - theme.grad_bg_b[lo]) * frac / 100;
        bg.push(sgr_bg(r, g, b));
        fg.push(sgr_fg(r, g, b));
        // wind cache is computed by the bash but never read by any rendered
        // cell (fill cells emit a space), so it is not materialised here.
    }
    GradCache { bg, fg }
}

fn compute_logo_gradient(theme: &BarTheme, bar_area: i64) -> (Vec<String>, Vec<String>) {
    let (dr, dg, db) = (8i64, 8i64, 12i64);
    let (pr, pg, pb) = theme.logo_peak;
    let dark_start = bar_area * 325 / 1000;
    let dark_end = bar_area * 675 / 1000;
    let mut bgs = Vec::with_capacity(bar_area as usize);
    let mut fgs = Vec::with_capacity(bar_area as usize);
    for gi in 0..bar_area {
        let mut t = 0i64;
        if gi < dark_start {
            t = 100 - gi * 100 / dark_start;
        } else if gi >= dark_end {
            let wing = bar_area - dark_end;
            if wing > 0 {
                t = (gi - dark_end) * 100 / wing;
            }
        }
        let r = dr + (pr - dr) * t / 100;
        let g = dg + (pg - dg) * t / 100;
        let b = db + (pb - db) * t / 100;
        bgs.push(sgr_bg(r, g, b));
        fgs.push(sgr_fg(r, g, b));
    }
    (bgs, fgs)
}

#[allow(clippy::too_many_arguments)]
pub fn render_bar(
    theme: &BarTheme,
    bar_width: i64,
    max_bar: i64,
    pct: i64,
    label: &str,
    suffix: &str,
    compact_mark_pct: Option<i64>,
    right_label: &str,
) -> String {
    let mark = compact_mark_pct.filter(|m| *m > 0 && *m < 100);

    // Top tier (outer caps and fallback fill colours)
    let mut tier_pct = pct;
    if let Some(m) = mark {
        tier_pct = pct * 100 / m;
        if tier_pct > 100 {
            tier_pct = 100;
        }
    }
    let mut top = tier_pct / 10;
    if top > 9 {
        top = 9;
    }
    if top < 0 {
        top = 0;
    }
    let fill_bg = theme.tier_bg[top as usize];
    let fill_fg = theme.tier_fg[top as usize];

    let mut bar_area = bar_width - 2;
    if bar_area > max_bar {
        bar_area = max_bar;
    }
    if bar_area < 20 {
        bar_area = 20;
    }

    // Logo shows only on a completely empty bar.
    let logo_on = pct == 0;
    let logo_len = LOGO_ICONS.len() as i64;
    let mut logo_start = 0i64;
    let mut logo_end = 0i64;
    if logo_on {
        logo_start = (bar_area - logo_len) / 2;
        if logo_start < 0 {
            logo_start = 0;
        }
        logo_end = logo_start + logo_len;
    }

    let logo_grad = if logo_on {
        Some(compute_logo_gradient(theme, bar_area))
    } else {
        None
    };

    let compact_empty_bg = "\x1b[48;2;18;20;25m";
    let compact_empty_fg = "\x1b[38;2;18;20;25m";
    let compact_mark_pos: i64 = match mark {
        Some(m) => bar_area * m / 100,
        None => -1,
    };

    let mut has_inner_cap = pct > 0 && pct < 100;
    let body_area = bar_area - if has_inner_cap { 1 } else { 0 };
    let mut filled = body_area * pct / 100;
    if filled > body_area {
        filled = body_area;
    }

    let label_padded: Vec<char> = format!(" {} ", label).chars().collect();
    let label_len = label_padded.len() as i64;
    let (label_start, label_end) = if logo_on {
        (-1i64, -1i64)
    } else {
        let mut s = (bar_area - label_len) / 2;
        if s < 0 {
            s = 0;
        }
        (s, s + label_len)
    };

    let rlabel: Vec<char> = right_label.chars().collect();
    let (rlabel_start, rlabel_end) = if right_label.is_empty() {
        (-1i64, -1i64)
    } else {
        let mut s = bar_area - rlabel.len() as i64;
        if s < 0 {
            s = 0;
        }
        (s, s + rlabel.len() as i64)
    };

    let cache = compute_gradient_cache(theme, filled, body_area, compact_mark_pct);

    // Outer caps
    let mut left_cap_fg: String;
    if pct > 0 {
        left_cap_fg = theme.tier_fg[0].to_string();
    } else if let Some((_, ref lfg)) = logo_grad {
        left_cap_fg = lfg[0].clone();
    } else if logo_on {
        left_cap_fg = compact_empty_fg.to_string();
    } else {
        left_cap_fg = theme.empty_fg.to_string();
    }

    let mut right_cap_fg: String;
    if pct >= 100 {
        right_cap_fg = fill_fg.to_string();
    } else if let Some((_, ref lfg)) = logo_grad {
        right_cap_fg = lfg[(bar_area - 1) as usize].clone();
    } else if logo_on {
        right_cap_fg = compact_empty_fg.to_string();
    } else if compact_mark_pos >= 0 {
        right_cap_fg = compact_empty_fg.to_string();
    } else {
        right_cap_fg = theme.empty_fg.to_string();
    }

    if filled > 0 {
        left_cap_fg = cache.fg[0].clone();
        if pct >= 100 {
            right_cap_fg = cache.fg[(filled - 1) as usize].clone();
        }
    }

    let mut bar = String::with_capacity((bar_area as usize) * 24);
    let mut vis = 0i64;
    let mut body_i = 0i64;

    while vis < bar_area {
        if has_inner_cap && body_i == filled {
            let cap_empty_bg = if logo_on {
                compact_empty_bg
            } else if compact_mark_pos >= 0 && vis >= compact_mark_pos {
                compact_empty_bg
            } else {
                theme.empty_bg
            };
            let (last_fill_fg, last_fill_bg) = if filled > 0 {
                (
                    cache.fg[(filled - 1) as usize].as_str(),
                    cache.bg[(filled - 1) as usize].as_str(),
                )
            } else {
                (fill_fg, fill_bg)
            };
            if vis >= label_start && vis < label_end {
                let ch = label_padded[(vis - label_start) as usize];
                bar.push_str(last_fill_bg);
                bar.push_str(theme.label_covered_fg);
                bar.push(ch);
            } else {
                bar.push_str(cap_empty_bg);
                bar.push_str(last_fill_fg);
                bar.push_str(PL_RIGHT);
            }
            has_inner_cap = false;
            vis += 1;
            continue;
        }

        let cur_empty_bg: &str = if let Some((ref lbg, _)) = logo_grad {
            lbg[vis as usize].as_str()
        } else if compact_mark_pos >= 0 && vis >= compact_mark_pos {
            compact_empty_bg
        } else {
            theme.empty_bg
        };
        let cur_light_fg = theme.light_fg;

        if !logo_on && compact_mark_pos >= 0 && vis == compact_mark_pos && body_i >= filled {
            if vis >= label_start && vis < label_end {
                let ch = label_padded[(vis - label_start) as usize];
                bar.push_str(cur_empty_bg);
                bar.push_str(cur_light_fg);
                bar.push(ch);
            } else {
                bar.push_str(compact_empty_bg);
                bar.push_str(theme.empty_fg);
                bar.push_str(PL_RIGHT);
            }
            body_i += 1;
            vis += 1;
            continue;
        }

        let (cell_bg, _cell_fg) = if body_i < filled {
            (
                cache.bg[body_i as usize].as_str(),
                cache.fg[body_i as usize].as_str(),
            )
        } else {
            (fill_bg, fill_fg)
        };

        if vis >= label_start && vis < label_end {
            let ch = label_padded[(vis - label_start) as usize];
            if body_i < filled {
                bar.push_str(cell_bg);
                bar.push_str(theme.label_covered_fg);
                bar.push(ch);
            } else {
                bar.push_str(cur_empty_bg);
                bar.push_str(cur_light_fg);
                bar.push(ch);
            }
        } else if rlabel_start >= 0 && vis >= rlabel_start && vis < rlabel_end && body_i >= filled {
            let ch = rlabel[(vis - rlabel_start) as usize];
            bar.push_str(cur_empty_bg);
            bar.push_str(cur_light_fg);
            bar.push(ch);
        } else if body_i < filled {
            bar.push_str(cell_bg);
            bar.push(' ');
        } else if logo_on && vis >= logo_start && vis < logo_end {
            let li = (vis - logo_start) as usize;
            bar.push_str(cur_empty_bg);
            bar.push_str(NF_BRAND_COLOR);
            bar.push_str(LOGO_ICONS[li]);
        } else {
            bar.push_str(cur_empty_bg);
            bar.push(' ');
        }
        body_i += 1;
        vis += 1;
    }

    let mut out = String::with_capacity(bar.len() + 64);
    out.push('\n');
    out.push_str(RESET);
    out.push_str(&left_cap_fg);
    out.push_str(PL_LEFT);
    out.push_str(&bar);
    out.push_str(RESET);
    out.push_str(&right_cap_fg);
    out.push_str(PL_RIGHT);
    out.push_str(suffix);
    out.push_str(RESET);
    out
}
