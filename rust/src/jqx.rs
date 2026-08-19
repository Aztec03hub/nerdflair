//! The slices of jq behaviour the bash relies on.

use serde_json::Value;

/// jq's `tostring` for a scalar; objects/arrays render as compact JSON.
pub fn tostring(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => num_str(n),
        _ => serde_json::to_string(v).unwrap_or_default(),
    }
}

/// jq 1.7 preserves the *literal* a number was written with (93.0 stays
/// "93.0", 2.50 stays "2.50") and re-renders it through libdecnumber's
/// to-scientific-string. Canonicalising to a shortest round-trip float, as a
/// naive port does, silently changes `used_percentage: 93.0` from a string
/// bash cannot do arithmetic on into one it can — which flips the whole bar.
pub fn num_str(n: &serde_json::Number) -> String {
    dec_canonical(&n.to_string())
}

/// libdecnumber `to-scientific-string` for a JSON number literal.
pub fn dec_canonical(lit: &str) -> String {
    let b = lit.as_bytes();
    let mut i = 0;
    let mut sign = "";
    if i < b.len() && (b[i] == b'-' || b[i] == b'+') {
        if b[i] == b'-' {
            sign = "-";
        }
        i += 1;
    }
    let int_start = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    let int_part = &lit[int_start..i];
    let mut frac_part = "";
    if i < b.len() && b[i] == b'.' {
        i += 1;
        let fs = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        frac_part = &lit[fs..i];
    }
    let mut exp: i64 = 0;
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        let mut neg = false;
        if i < b.len() && (b[i] == b'-' || b[i] == b'+') {
            neg = b[i] == b'-';
            i += 1;
        }
        let es = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        exp = lit[es..i].parse::<i64>().unwrap_or(0);
        if neg {
            exp = -exp;
        }
    }
    if i != lit.len() || int_part.is_empty() && frac_part.is_empty() {
        return lit.to_string();
    }
    // coefficient digits, exponent as a power of ten applied to them
    let mut digits: String = format!("{}{}", int_part, frac_part);
    let e = exp - frac_part.len() as i64;
    // decNumber strips leading zeros from the coefficient (keeping one for 0)
    let trimmed = digits.trim_start_matches('0');
    digits = if trimmed.is_empty() {
        "0".to_string()
    } else {
        trimmed.to_string()
    };
    let nd = digits.len() as i64;
    let adjusted = e + nd - 1;
    if e <= 0 && adjusted >= -6 {
        if e == 0 {
            return format!("{}{}", sign, digits);
        }
        if adjusted >= 0 {
            let split = (adjusted + 1) as usize;
            return format!("{}{}.{}", sign, &digits[..split], &digits[split..]);
        }
        let zeros = "0".repeat((-adjusted - 1) as usize);
        return format!("{}0.{}{}", sign, zeros, digits);
    }
    let mut out = format!("{}{}", sign, &digits[..1]);
    if nd > 1 {
        out.push('.');
        out.push_str(&digits[1..]);
    }
    out.push('E');
    if adjusted >= 0 {
        out.push('+');
    } else {
        out.push('-');
    }
    out.push_str(&adjusted.abs().to_string());
    out
}

/// `.a.b.c`. `Err(())` models a jq runtime error (indexing a non-object),
/// which aborts the whole filter and leaves every extracted field empty.
pub fn path<'a>(root: &'a Value, keys: &[&str]) -> Result<&'a Value, ()> {
    let mut cur = root;
    for k in keys {
        match cur {
            Value::Object(m) => {
                cur = m.get(*k).unwrap_or(&Value::Null);
            }
            Value::Null => return Ok(&Value::Null),
            _ => return Err(()),
        }
    }
    Ok(cur)
}

/// jq's `@tsv` escaping for one field.
pub fn tsv_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            _ => out.push(c),
        }
    }
    out
}

/// `.x // ""` — null and false both fall through to the alternative.
pub fn alt_str(v: &Value) -> String {
    match v {
        Value::Null | Value::Bool(false) => String::new(),
        other => tostring(other),
    }
}

/// jq's pretty printer: 2-space indent, `": "` between key and value,
/// `[]`/`{}` for empties, one trailing newline. Needed because state.json is
/// rewritten in place and the bash renderer reads it back.
pub fn pretty(v: &Value) -> String {
    let mut s = String::new();
    write_pretty(v, 0, &mut s);
    s.push('\n');
    s
}

fn write_pretty(v: &Value, indent: usize, out: &mut String) {
    match v {
        Value::Array(a) if !a.is_empty() => {
            out.push_str("[\n");
            for (i, item) in a.iter().enumerate() {
                if i > 0 {
                    out.push_str(",\n");
                }
                out.push_str(&" ".repeat(indent + 2));
                write_pretty(item, indent + 2, out);
            }
            out.push('\n');
            out.push_str(&" ".repeat(indent));
            out.push(']');
        }
        Value::Object(m) if !m.is_empty() => {
            out.push_str("{\n");
            for (i, (k, val)) in m.iter().enumerate() {
                if i > 0 {
                    out.push_str(",\n");
                }
                out.push_str(&" ".repeat(indent + 2));
                out.push_str(&serde_json::to_string(k).unwrap_or_default());
                out.push_str(": ");
                write_pretty(val, indent + 2, out);
            }
            out.push('\n');
            out.push_str(&" ".repeat(indent));
            out.push('}');
        }
        Value::Array(_) => out.push_str("[]"),
        Value::Object(_) => out.push_str("{}"),
        Value::Number(n) => out.push_str(&num_str(n)),
        other => out.push_str(&serde_json::to_string(other).unwrap_or_default()),
    }
}

/// `[.mcpServers // {} | to_entries[] | select(.value.disabled != true) | .key] | sort[]`
pub fn mcp_server_names(root: &Value, container: &[&str]) -> Vec<String> {
    let node = match path(root, container) {
        Ok(n) => n,
        Err(_) => return Vec::new(),
    };
    let obj = match node {
        Value::Object(m) => m,
        Value::Null | Value::Bool(false) => return Vec::new(),
        _ => return Vec::new(), // to_entries on a non-object aborts the filter
    };
    let mut names = Vec::new();
    for (k, v) in obj.iter() {
        match v {
            Value::Object(inner) => {
                if inner.get("disabled") == Some(&Value::Bool(true)) {
                    continue;
                }
            }
            Value::Null => {}
            // `.value.disabled` on a scalar is a jq error: the whole filter dies
            _ => return Vec::new(),
        }
        names.push(k.clone());
    }
    names.sort(); // jq sorts strings by codepoint
    names
}
