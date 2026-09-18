//! Expansion of catalog templates into GDScript source.
//!
//! Placeholders: `$0` target, `$1..$9` positional args, `$v` assigned value, `$args` all args
//! comma-joined, `$params` the trailing params-array as an Array literal, `$tmp` a fresh temp
//! name (stable within one expansion), `$T1` first generic type argument, `$N` member name.
//! `A ;; B ;; C` splits into pre-statements A, B and the result expression C.

use crate::gd::GExpr;

pub struct TemplateArgs<'a> {
    pub target: Option<&'a GExpr>,
    pub args: &'a [GExpr],
    pub value: Option<&'a GExpr>,
    /// Arguments that belong to a `params T[]` parameter (already separated from `args`).
    pub params: &'a [GExpr],
    pub type_args: &'a [String],
    pub member_name: &'a str,
    pub tmp: &'a str,
}

pub struct Expanded {
    pub pre: Vec<String>,
    pub expr: String,
    /// True when the result expression is a statement-like template (assignment / `pass`),
    /// i.e. it cannot be used as a value.
    pub is_statement: bool,
}

fn atomic(e: &GExpr) -> String {
    if e.is_atomic() {
        e.render()
    } else {
        format!("({})", e.render())
    }
}

/// Number of times the placeholder `$name` occurs in `t`.
pub fn placeholder_count(t: &str, name: &str) -> usize {
    let chars: Vec<char> = t.chars().collect();
    let mut n = 0;
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '$' {
            let mut j = i + 1;
            while j < chars.len() && (chars[j].is_ascii_alphanumeric() || chars[j] == '_') {
                j += 1;
            }
            let nm: String = chars[i + 1..j].iter().collect();
            if nm == name {
                n += 1;
            }
            i = j.max(i + 1);
        } else {
            i += 1;
        }
    }
    n
}

/// Substitute placeholders in `template`.
pub fn expand(template: &str, a: &TemplateArgs<'_>) -> Expanded {
    let mut parts: Vec<String> = template.split(";;").map(|s| s.trim().to_string()).collect();
    let last = parts.pop().unwrap_or_default();
    let pre: Vec<String> = parts.into_iter().map(|p| subst(&p, a)).collect();
    let expr = subst(&last, a);
    let is_statement = is_statement_like(&expr);
    Expanded { pre, expr, is_statement }
}

pub fn is_statement_like(s: &str) -> bool {
    let t = s.trim();
    if t == "pass" || t.starts_with("var ") || t.starts_with("breakpoint") {
        return true;
    }
    // top-level assignment `x = y` (not `==`, `!=`, `<=`, `>=`) outside brackets/strings
    let b = t.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if in_str {
            if c == b'\\' {
                i += 2;
                continue;
            }
            if c == b'"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        match c {
            b'"' => in_str = true,
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b'=' if depth == 0 => {
                let prev = if i > 0 { b[i - 1] } else { b' ' };
                let next = if i + 1 < b.len() { b[i + 1] } else { b' ' };
                if next == b'=' {
                    i += 2;
                    continue;
                }
                if matches!(prev, b'=' | b'!' | b'<' | b'>' | b'+' | b'-' | b'*' | b'/' | b'%' | b'&' | b'|' | b'^') {
                    // compound assignment or comparison: `+=` counts as a statement, `<=` does not
                    if matches!(prev, b'+' | b'-' | b'*' | b'/' | b'%' | b'&' | b'|' | b'^') {
                        return true;
                    }
                    i += 1;
                    continue;
                }
                return true;
            }
            _ => {}
        }
        i += 1;
    }
    false
}

fn subst(t: &str, a: &TemplateArgs<'_>) -> String {
    let mut out = String::with_capacity(t.len() + 16);
    let chars: Vec<char> = t.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c != '$' {
            out.push(c);
            i += 1;
            continue;
        }
        // read placeholder name
        let mut j = i + 1;
        while j < chars.len() && (chars[j].is_ascii_alphanumeric() || chars[j] == '_') {
            j += 1;
        }
        let name: String = chars[i + 1..j].iter().collect();
        let rep = match name.as_str() {
            "0" => a.target.map(atomic).unwrap_or_else(|| "self".into()),
            "v" => a.value.map(atomic).unwrap_or_else(|| "null".into()),
            "args" => {
                let mut all: Vec<String> = a.args.iter().map(|e| e.render()).collect();
                all.extend(a.params.iter().map(|e| e.render()));
                all.join(", ")
            }
            "params" => format!("[{}]", a.params.iter().map(|e| e.render()).collect::<Vec<_>>().join(", ")),
            "tmp" => a.tmp.to_string(),
            "N" => a.member_name.to_string(),
            "T1" => a.type_args.first().map(|s| type_arg_source(s)).unwrap_or_else(|| "\"\"".into()),
            "T2" => a.type_args.get(1).map(|s| type_arg_source(s)).unwrap_or_else(|| "\"\"".into()),
            n if n.chars().all(|c| c.is_ascii_digit()) && !n.is_empty() => {
                let idx: usize = n.parse().unwrap();
                match a.args.get(idx - 1) {
                    Some(e) => {
                        // A placeholder that is a whole argument or array element needs no parens.
                        let before = chars[..i].iter().rev().find(|c| !c.is_whitespace()).copied();
                        let after = chars[j..].iter().find(|c| !c.is_whitespace()).copied();
                        let whole = matches!(before, Some('(') | Some(',') | Some('[') | Some(':') | None) && matches!(after, Some(')') | Some(',') | Some(']') | Some('}') | None);
                        if whole && !matches!(e, GExpr::Ternary { .. } | GExpr::Lambda { .. }) {
                            e.render()
                        } else {
                            atomic(e)
                        }
                    }
                    None => "null".into(),
                }
            }
            _ => {
                // not a placeholder: keep literally
                out.push('$');
                i += 1;
                continue;
            }
        };
        out.push_str(&rep);
        i = j;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands() {
        let t = GExpr::ident("t");
        let args = vec![GExpr::ident("a").bin("+", GExpr::Int(1)), GExpr::Float(2.0)];
        let ta = TemplateArgs { target: Some(&t), args: &args, value: None, params: &[], type_args: &[], member_name: "M", tmp: "_t0" };
        let e = expand("$0.lerp($1, clampf($2, 0.0, 1.0))", &ta);
        assert_eq!(e.expr, "t.lerp(a + 1, clampf(2.0, 0.0, 1.0))");
        assert!(!e.is_statement);
        let e = expand("$1 = U.raycast($2) ;; not $1.is_empty()", &ta);
        assert_eq!(e.pre, vec!["(a + 1) = U.raycast(2.0)"]);
        assert_eq!(e.expr, "not (a + 1).is_empty()");
        assert!(is_statement_like("$0.x = 3"));
        assert!(is_statement_like("x += 3"));
        assert!(!is_statement_like("x == 3"));
        assert!(!is_statement_like("x <= 3"));
        assert!(!is_statement_like("f(x = 3)"));
        assert!(is_statement_like("pass"));
    }
}

/// Marks a type argument that is only known at run time: the type parameter of the generic method
/// being lowered, which arrives in a hidden String parameter. The rest of the text is that
/// parameter's name and is emitted as an identifier instead of a quoted type name.
pub const RUNTIME_TYPE_ARG: char = '\u{1}';

fn type_arg_source(name: &str) -> String {
    match name.strip_prefix(RUNTIME_TYPE_ARG) {
        Some(ident) => ident.to_string(),
        None => format!("\"{}\"", name),
    }
}
