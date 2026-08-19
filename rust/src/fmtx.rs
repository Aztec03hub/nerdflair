//! Number/duration formatting with C-printf semantics.

/// C `strtod`: longest valid prefix, 0 if none. bash's `printf '%.2f'` uses
/// it, so "0x20" is 32, "3abc" is 3 and "abc" is 0 — all of which reach the
/// cost field from a shifted payload.
pub fn strtod(s: &str) -> f64 {
    let t = s.trim_start_matches([' ', '\t', '\n', '\r', '\x0b', '\x0c']);
    let b = t.as_bytes();
    let mut i = 0;
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        i += 1;
    }
    let low = t.to_ascii_lowercase();
    let rest = &low[i..];
    if rest.starts_with("infinity") {
        return finish(&t[..i + 8]);
    }
    if rest.starts_with("inf") {
        return finish(&t[..i + 3]);
    }
    if rest.starts_with("nan") {
        return finish(&t[..i + 3]);
    }
    if rest.starts_with("0x") {
        let mut j = i + 2;
        let start_digits = j;
        while j < b.len() && b[j].is_ascii_hexdigit() {
            j += 1;
        }
        let mut seen = j > start_digits;
        if j < b.len() && b[j] == b'.' {
            j += 1;
            let fs = j;
            while j < b.len() && b[j].is_ascii_hexdigit() {
                j += 1;
            }
            seen = seen || j > fs;
        }
        if !seen {
            return 0.0;
        }
        let mant_end = j;
        if j < b.len() && (b[j] == b'p' || b[j] == b'P') {
            let mut k = j + 1;
            if k < b.len() && (b[k] == b'+' || b[k] == b'-') {
                k += 1;
            }
            let ds = k;
            while k < b.len() && b[k].is_ascii_digit() {
                k += 1;
            }
            if k > ds {
                j = k;
            }
        }
        return parse_hex_float(&t[..if j > mant_end { j } else { mant_end }]);
    }
    let mut j = i;
    let ds = j;
    while j < b.len() && b[j].is_ascii_digit() {
        j += 1;
    }
    let mut seen = j > ds;
    if j < b.len() && b[j] == b'.' {
        j += 1;
        let fs = j;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        seen = seen || j > fs;
    }
    if !seen {
        return 0.0;
    }
    let mant_end = j;
    if j < b.len() && (b[j] == b'e' || b[j] == b'E') {
        let mut k = j + 1;
        if k < b.len() && (b[k] == b'+' || b[k] == b'-') {
            k += 1;
        }
        let es = k;
        while k < b.len() && b[k].is_ascii_digit() {
            k += 1;
        }
        if k > es {
            j = k;
        }
    }
    finish(&t[..if j > mant_end { j } else { mant_end }])
}

fn finish(s: &str) -> f64 {
    s.parse::<f64>().unwrap_or_else(|_| {
        let low = s.to_ascii_lowercase();
        if low.ends_with("nan") {
            if low.starts_with('-') { -f64::NAN } else { f64::NAN }
        } else if low.ends_with("inf") || low.ends_with("infinity") {
            if low.starts_with('-') { f64::NEG_INFINITY } else { f64::INFINITY }
        } else {
            0.0
        }
    })
}

fn parse_hex_float(s: &str) -> f64 {
    let neg = s.starts_with('-');
    let body = s.trim_start_matches(['+', '-']);
    let body = &body[2..]; // strip 0x
    let (mant, exp) = match body.find(['p', 'P']) {
        Some(i) => (&body[..i], body[i + 1..].parse::<i32>().unwrap_or(0)),
        None => (body, 0),
    };
    let (ip, fp) = match mant.find('.') {
        Some(i) => (&mant[..i], &mant[i + 1..]),
        None => (mant, ""),
    };
    let mut v = 0.0f64;
    for c in ip.chars() {
        v = v * 16.0 + c.to_digit(16).unwrap_or(0) as f64;
    }
    let mut scale = 1.0 / 16.0;
    for c in fp.chars() {
        v += c.to_digit(16).unwrap_or(0) as f64 * scale;
        scale /= 16.0;
    }
    v *= 2f64.powi(exp);
    if neg {
        -v
    } else {
        v
    }
}

/// awk's string-to-number coercion for a data field: decimal prefix only.
pub fn awk_num(s: &str) -> f64 {
    let t = s.trim_start_matches([' ', '\t', '\n']);
    let b = t.as_bytes();
    let mut i = 0;
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        i += 1;
    }
    let ds = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    let mut seen = i > ds;
    if i < b.len() && b[i] == b'.' {
        i += 1;
        let fs = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        seen = seen || i > fs;
    }
    if !seen {
        return 0.0;
    }
    let mant_end = i;
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        let mut k = i + 1;
        if k < b.len() && (b[k] == b'+' || b[k] == b'-') {
            k += 1;
        }
        let es = k;
        while k < b.len() && b[k].is_ascii_digit() {
            k += 1;
        }
        if k > es {
            i = k;
        }
    }
    t[..if i > mant_end { i } else { mant_end }]
        .parse::<f64>()
        .unwrap_or(0.0)
}

/// The burn-rate fallback interpolates `$cost` straight into awk SOURCE.
/// A numeric literal evaluates; a bare identifier is an uninitialised awk
/// variable (0); anything else is a syntax error and awk emits nothing.
pub fn awk_expr_num(s: &str) -> Option<f64> {
    let t = s.trim();
    if t.is_empty() {
        return None;
    }
    let b = t.as_bytes();
    let mut i = 0;
    if b[i] == b'+' || b[i] == b'-' {
        i += 1;
    }
    if i < b.len() && (b[i].is_ascii_digit() || b[i] == b'.') {
        let lower = t.to_ascii_lowercase();
        if lower[i..].starts_with("0x") {
            let hex = &t[i + 2..];
            if !hex.is_empty() && hex.bytes().all(|c| c.is_ascii_hexdigit()) {
                let v = i64::from_str_radix(hex, 16).unwrap_or(0) as f64;
                return Some(if b[0] == b'-' { -v } else { v });
            }
            return None;
        }
        return t.parse::<f64>().ok();
    }
    if i < b.len() && (b[i].is_ascii_alphabetic() || b[i] == b'_') {
        if t[i..].bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_') {
            return Some(0.0);
        }
    }
    None
}

/// `printf '%.2f'` — glibc rounds the exact binary value half-to-even, which
/// differs from Rust's built-in float formatting on exact ties (0.125).
pub fn f2(x: f64) -> String {
    if x.is_nan() {
        return if x.is_sign_negative() { "-nan".into() } else { "nan".into() };
    }
    if x.is_infinite() {
        return if x < 0.0 { "-inf".into() } else { "inf".into() };
    }
    let neg = x.is_sign_negative();
    let a = x.abs();
    // 25 places is far beyond any tie point reachable at 2 decimals.
    let exact = format!("{:.25}", a);
    let (int_part, frac_part) = exact.split_once('.').unwrap_or((exact.as_str(), ""));
    let mut digits: Vec<u8> = int_part.bytes().map(|b| b - b'0').collect();
    let int_len = digits.len();
    digits.extend(frac_part.bytes().map(|b| b - b'0'));
    let keep = int_len + 2;
    let round_up = {
        let first = digits.get(keep).copied().unwrap_or(0);
        match first.cmp(&5) {
            std::cmp::Ordering::Greater => true,
            std::cmp::Ordering::Less => false,
            std::cmp::Ordering::Equal => {
                let rest_nonzero = digits[keep + 1..].iter().any(|d| *d != 0);
                if rest_nonzero {
                    true
                } else {
                    // exact tie: round half to even
                    digits[keep - 1] % 2 == 1
                }
            }
        }
    };
    digits.truncate(keep);
    if round_up {
        let mut i = keep;
        loop {
            if i == 0 {
                digits.insert(0, 1);
                break;
            }
            i -= 1;
            if digits[i] == 9 {
                digits[i] = 0;
            } else {
                digits[i] += 1;
                break;
            }
        }
    }
    let int_len = digits.len() - 2;
    let mut out = String::new();
    if neg {
        out.push('-');
    }
    for (i, d) in digits.iter().enumerate() {
        if i == int_len {
            out.push('.');
        }
        out.push((b'0' + d) as char);
    }
    out
}

/// awk/printf `%g` with the default 6 significant digits.
pub fn g(x: f64) -> String {
    if x == 0.0 {
        return "0".into();
    }
    if !x.is_finite() {
        return format!("{}", x);
    }
    let exp = x.abs().log10().floor() as i32;
    if exp < -4 || exp >= 6 {
        let mant = x / 10f64.powi(exp);
        let mut m = format!("{:.5}", mant);
        while m.contains('.') && (m.ends_with('0') || m.ends_with('.')) {
            m.pop();
        }
        return format!("{}e{}{:02}", m, if exp < 0 { "-" } else { "+" }, exp.abs());
    }
    let places = (5 - exp).max(0) as usize;
    let mut s = format!("{:.*}", places, x);
    if s.contains('.') {
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
    }
    s
}

/// `_fmt_duration`
pub fn duration(ms: i64, fmt_num: impl Fn(i64) -> String) -> String {
    let total_secs = ms / 1000;
    let total_mins = total_secs / 60;
    if total_mins >= 60 {
        let hundredths = total_mins * 100 / 60;
        let mut whole = hundredths / 100;
        let frac = hundredths % 100;
        let mut whole_fmt = fmt_num(whole);
        let mut tenths = (frac + 5) / 10;
        if tenths >= 10 {
            whole += 1;
            tenths = 0;
            whole_fmt = fmt_num(whole);
        }
        if tenths == 0 {
            format!("{}h", whole_fmt)
        } else {
            format!("{}.{}h", whole_fmt, tenths)
        }
    } else if total_mins > 0 {
        format!("{}m", total_mins)
    } else {
        format!("{}s", total_secs)
    }
}

/// `_fmt_countdown`
pub fn countdown(target: i64, now: i64) -> String {
    let delta = target - now;
    if delta <= 0 {
        return String::new();
    }
    if delta >= 172800 {
        format!("{}d", delta / 86400)
    } else if delta >= 3600 {
        format!("{}h{:02}m", delta / 3600, (delta % 3600) / 60)
    } else {
        format!("{}m", delta / 60)
    }
}
