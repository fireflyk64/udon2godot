//! GDScript / SafeGDScript output AST and pretty-printer.
//!
//! Precedence (loosest → tightest), following the SafeGDScript parser:
//! `as`, ternary, `or`, `and`, `not`, `in`, equality, comparison, `|`, `^`, `&`, shifts,
//! `+`/`-`, `*`/`/`/`%`, `is`, `**`, unary `-`/`~`/`+`, call/subscript/member.

use std::fmt::Write;

#[derive(Debug, Clone, PartialEq)]
pub enum GExpr {
    /// Pre-rendered source treated as atomic (wrapped by the producer when needed).
    Raw(String),
    Ident(String),
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    Null,
    Member(Box<GExpr>, String),
    Call(Box<GExpr>, Vec<GExpr>),
    MethodCall(Box<GExpr>, String, Vec<GExpr>),
    Index(Box<GExpr>, Box<GExpr>),
    /// op is one of "-", "+", "~", "not"
    Unary(&'static str, Box<GExpr>),
    Binary(Box<GExpr>, &'static str, Box<GExpr>),
    /// `then if cond else els`
    Ternary { cond: Box<GExpr>, then: Box<GExpr>, els: Box<GExpr> },
    Array(Vec<GExpr>),
    Dict(Vec<(GExpr, GExpr)>),
    As(Box<GExpr>, String),
    Is(Box<GExpr>, String),
    Lambda { params: Vec<String>, body: Box<GExpr> },
    Paren(Box<GExpr>),
}

/// Binding power of an expression node (higher binds tighter).
fn prec(e: &GExpr) -> u8 {
    match e {
        GExpr::As(..) => 1,
        GExpr::Ternary { .. } => 2,
        GExpr::Binary(_, op, _) => match *op {
            "or" => 3,
            "and" => 4,
            "in" | "not in" => 6,
            "==" | "!=" => 7,
            "<" | ">" | "<=" | ">=" => 8,
            "|" => 9,
            "^" => 10,
            "&" => 11,
            "<<" | ">>" => 12,
            "+" | "-" => 13,
            "*" | "/" | "%" => 14,
            "**" => 16,
            _ => 13,
        },
        GExpr::Unary(op, _) => {
            if *op == "not" {
                5
            } else {
                17
            }
        }
        GExpr::Is(..) => 15,
        GExpr::Lambda { .. } => 2,
        GExpr::Raw(s) => {
            if raw_is_atomic(s) {
                20
            } else {
                0
            }
        }
        _ => 20,
    }
}

/// Pre-rendered source counts as atomic when it has no top-level operator (templates always put
/// spaces around operators; calls, member chains, literals and bracketed expressions have none
/// at depth 0).
pub fn raw_is_atomic(s: &str) -> bool {
    let t = s.trim();
    if t.is_empty() {
        return true;
    }
    if t.starts_with("not ") || t.starts_with("var ") {
        return false;
    }
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev = '\0';
    for c in t.chars() {
        if in_str {
            if c == '"' && prev != '\\' {
                in_str = false;
            }
            prev = c;
            continue;
        }
        match c {
            '"' => in_str = true,
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ' ' if depth == 0 => return false,
            _ => {}
        }
        prev = c;
    }
    // A leading unary minus on a longer expression keeps its meaning under member access.
    true
}

fn is_left_assoc(op: &str) -> bool {
    !matches!(op, "**")
}

pub fn gd_string_literal(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\0' => out.push_str("\\u0000"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn gd_float_literal(v: f64) -> String {
    if v.is_nan() {
        return "NAN".into();
    }
    if v.is_infinite() {
        return if v > 0.0 { "INF".into() } else { "-INF".into() };
    }
    let mut s = format!("{}", v);
    if !s.contains('.') && !s.contains('e') && !s.contains("inf") && !s.contains("NaN") {
        s.push_str(".0");
    }
    s
}

impl GExpr {
    pub fn ident(s: &str) -> GExpr {
        GExpr::Ident(s.to_string())
    }
    pub fn raw(s: impl Into<String>) -> GExpr {
        GExpr::Raw(s.into())
    }
    pub fn member(self, name: &str) -> GExpr {
        GExpr::Member(Box::new(self), name.to_string())
    }
    pub fn call(self, args: Vec<GExpr>) -> GExpr {
        GExpr::Call(Box::new(self), args)
    }
    pub fn method(self, name: &str, args: Vec<GExpr>) -> GExpr {
        GExpr::MethodCall(Box::new(self), name.to_string(), args)
    }
    pub fn index(self, i: GExpr) -> GExpr {
        GExpr::Index(Box::new(self), Box::new(i))
    }
    pub fn bin(self, op: &'static str, rhs: GExpr) -> GExpr {
        GExpr::Binary(Box::new(self), op, Box::new(rhs))
    }
    pub fn not(self) -> GExpr {
        GExpr::Unary("not", Box::new(self))
    }
    pub fn neg(self) -> GExpr {
        GExpr::Unary("-", Box::new(self))
    }
    pub fn str(s: &str) -> GExpr {
        GExpr::Str(s.to_string())
    }
    pub fn is_atomic(&self) -> bool {
        prec(self) >= 20
    }

    /// Cheap and side-effect free to evaluate more than once (no calls).
    pub fn is_cheap(&self) -> bool {
        match self {
            GExpr::Ident(_) | GExpr::Int(_) | GExpr::Float(_) | GExpr::Str(_) | GExpr::Bool(_) | GExpr::Null => true,
            GExpr::Member(b, _) | GExpr::Paren(b) | GExpr::Unary(_, b) => b.is_cheap(),
            GExpr::Index(a, b) => a.is_cheap() && b.is_cheap(),
            GExpr::Raw(s) => !s.contains('(') && s.len() <= 32,
            _ => false,
        }
    }

    /// Render to source.
    pub fn render(&self) -> String {
        let mut s = String::new();
        self.write(&mut s);
        s
    }

    fn write_child(&self, out: &mut String, child: &GExpr, min_prec: u8) {
        if prec(child) < min_prec {
            out.push('(');
            child.write(out);
            out.push(')');
        } else {
            child.write(out);
        }
    }

    fn write(&self, out: &mut String) {
        match self {
            GExpr::Raw(s) => out.push_str(s),
            GExpr::Ident(s) => out.push_str(s),
            GExpr::Int(v) => {
                let _ = write!(out, "{}", v);
            }
            GExpr::Float(v) => out.push_str(&gd_float_literal(*v)),
            GExpr::Str(s) => out.push_str(&gd_string_literal(s)),
            GExpr::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            GExpr::Null => out.push_str("null"),
            GExpr::Member(t, name) => {
                // Numeric literals need parens: `1.x` is invalid.
                let need = !t.is_atomic() || matches!(**t, GExpr::Int(_) | GExpr::Float(_));
                if need {
                    out.push('(');
                    t.write(out);
                    out.push(')');
                } else {
                    t.write(out);
                }
                out.push('.');
                out.push_str(name);
            }
            GExpr::Call(callee, args) => {
                self.write_child(out, callee, 20);
                out.push('(');
                for (i, a) in args.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    a.write(out);
                }
                out.push(')');
            }
            GExpr::MethodCall(t, name, args) => {
                let need = !t.is_atomic() || matches!(**t, GExpr::Int(_) | GExpr::Float(_));
                if need {
                    out.push('(');
                    t.write(out);
                    out.push(')');
                } else {
                    t.write(out);
                }
                out.push('.');
                out.push_str(name);
                out.push('(');
                for (i, a) in args.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    a.write(out);
                }
                out.push(')');
            }
            GExpr::Index(t, i) => {
                self.write_child(out, t, 20);
                out.push('[');
                i.write(out);
                out.push(']');
            }
            GExpr::Unary(op, e) => {
                let p = prec(self);
                if *op == "not" {
                    // `not` binds looser than comparison; always parenthesize a non-atomic operand for clarity.
                    out.push_str("not ");
                    self.write_child(out, e, 20);
                } else {
                    out.push_str(op);
                    // `- -x` needs a space; `-(-x)` is clearer.
                    if let GExpr::Unary(op2, _) = &**e {
                        if op2 == op {
                            out.push('(');
                            e.write(out);
                            out.push(')');
                            return;
                        }
                    }
                    // Negative literal inside unary: `-(-1)`
                    if let GExpr::Int(v) = &**e {
                        if *v < 0 {
                            out.push('(');
                            e.write(out);
                            out.push(')');
                            return;
                        }
                    }
                    if let GExpr::Float(v) = &**e {
                        if *v < 0.0 {
                            out.push('(');
                            e.write(out);
                            out.push(')');
                            return;
                        }
                    }
                    self.write_child(out, e, p);
                }
            }
            GExpr::Binary(l, op, r) => {
                let p = prec(self);
                let (lp, rp) = if is_left_assoc(op) { (p, p + 1) } else { (p + 1, p) };
                // Comparison chains like `a < b == c` are confusing and engine precedence differs between
                // GDScript and SafeGDScript docs; parenthesize any comparison nested in a comparison.
                let (lp, rp) = if matches!(*op, "==" | "!=" | "<" | ">" | "<=" | ">=") { (9, 9) } else { (lp, rp) };
                self.write_child(out, l, lp);
                out.push(' ');
                out.push_str(op);
                out.push(' ');
                self.write_child(out, r, rp);
            }
            GExpr::Ternary { cond, then, els } => {
                // `then if cond else els`; nested ternaries in `then` need parens.
                self.write_child(out, then, 3);
                out.push_str(" if ");
                self.write_child(out, cond, 3);
                out.push_str(" else ");
                self.write_child(out, els, 2);
            }
            GExpr::Array(items) => {
                out.push('[');
                for (i, a) in items.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    a.write(out);
                }
                out.push(']');
            }
            GExpr::Dict(items) => {
                out.push('{');
                for (i, (k, v)) in items.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    k.write(out);
                    out.push_str(": ");
                    v.write(out);
                }
                out.push('}');
            }
            GExpr::As(e, ty) => {
                self.write_child(out, e, 2);
                out.push_str(" as ");
                out.push_str(ty);
            }
            GExpr::Is(e, ty) => {
                self.write_child(out, e, 16);
                out.push_str(" is ");
                out.push_str(ty);
            }
            GExpr::Lambda { params, body } => {
                out.push_str("func(");
                out.push_str(&params.join(", "));
                out.push_str("): return ");
                body.write(out);
            }
            GExpr::Paren(e) => {
                out.push('(');
                e.write(out);
                out.push(')');
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum GStmt {
    Expr(GExpr),
    VarDecl { name: String, ty: Option<String>, init: Option<GExpr> },
    /// `target op value` where op is `=`, `+=`, ...
    Assign { target: GExpr, op: &'static str, value: GExpr },
    If { branches: Vec<(GExpr, Vec<GStmt>)>, els: Option<Vec<GStmt>> },
    While { cond: GExpr, body: Vec<GStmt> },
    For { var: String, iter: GExpr, body: Vec<GStmt> },
    Match { subject: GExpr, arms: Vec<GMatchArm> },
    Break,
    Continue,
    Pass,
    Return(Option<GExpr>),
    Comment(String),
    /// A raw line (already indented relative to the block).
    Raw(String),
    /// Blank line
    Blank,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GMatchArm {
    /// Empty patterns = wildcard `_`.
    pub patterns: Vec<GExpr>,
    pub body: Vec<GStmt>,
}

#[derive(Debug, Clone, Default)]
pub struct GVar {
    pub name: String,
    pub ty: Option<String>,
    pub init: Option<GExpr>,
    pub export: bool,
    /// `@export_storage`: saved with the scene but not shown in the inspector (a public Unity
    /// field with `[HideInInspector]` is still serialized).
    pub export_storage: bool,
    pub doc: Option<String>,
    pub comment: Option<String>,
    /// Inline setter body statements (`set(value): ...`) — `value` is the parameter name.
    pub setter: Option<Vec<GStmt>>,
    pub getter: Option<Vec<GStmt>>,
}

#[derive(Debug, Clone, Default)]
pub struct GParam {
    pub name: String,
    pub ty: Option<String>,
    pub default: Option<GExpr>,
}

#[derive(Debug, Clone, Default)]
pub struct GFunc {
    pub name: String,
    pub params: Vec<GParam>,
    pub ret: Option<String>,
    pub body: Vec<GStmt>,
    pub is_static: bool,
    pub doc: Option<String>,
    pub comment: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct GEnum {
    pub name: String,
    pub members: Vec<(String, i64)>,
}

#[derive(Debug, Clone, Default)]
pub struct GConst {
    pub name: String,
    pub ty: Option<String>,
    pub value: GExpr,
    pub comment: Option<String>,
}

impl Default for GExpr {
    fn default() -> Self {
        GExpr::Null
    }
}

#[derive(Debug, Clone, Default)]
pub struct GScript {
    pub header: Vec<String>,
    pub class_name: Option<String>,
    pub extends: Option<String>,
    pub enums: Vec<GEnum>,
    pub consts: Vec<GConst>,
    pub signals: Vec<(String, Vec<String>)>,
    pub vars: Vec<GVar>,
    pub funcs: Vec<GFunc>,
}

pub struct Printer {
    out: String,
    indent: usize,
}

impl Printer {
    pub fn new() -> Self {
        Self { out: String::new(), indent: 0 }
    }

    fn line(&mut self, s: &str) {
        for _ in 0..self.indent {
            self.out.push('\t');
        }
        self.out.push_str(s);
        self.out.push('\n');
    }

    fn blank(&mut self) {
        self.out.push('\n');
    }

    pub fn script(mut self, s: &GScript) -> String {
        for h in &s.header {
            self.line(&format!("# {}", h));
        }
        if let Some(cn) = &s.class_name {
            self.line(&format!("class_name {}", cn));
        }
        if let Some(e) = &s.extends {
            self.line(&format!("extends {}", e));
        }
        if !s.header.is_empty() || s.extends.is_some() {
            self.blank();
        }
        for e in &s.enums {
            let items: Vec<String> = e.members.iter().map(|(n, v)| format!("{} = {}", n, v)).collect();
            self.line(&format!("enum {} {{ {} }}", e.name, items.join(", ")));
        }
        if !s.enums.is_empty() {
            self.blank();
        }
        for c in &s.consts {
            if let Some(cm) = &c.comment {
                // a doc comment may span lines: every one needs its own marker
                for l in cm.lines() {
                    self.line(&format!("# {}", l.trim()));
                }
            }
            match &c.ty {
                Some(t) => self.line(&format!("const {}: {} = {}", c.name, t, c.value.render())),
                None => self.line(&format!("const {} = {}", c.name, c.value.render())),
            }
        }
        if !s.consts.is_empty() {
            self.blank();
        }
        for (name, params) in &s.signals {
            self.line(&format!("signal {}({})", name, params.join(", ")));
        }
        if !s.signals.is_empty() {
            self.blank();
        }
        for v in &s.vars {
            self.var(v);
        }
        if !s.vars.is_empty() {
            self.blank();
        }
        for (i, f) in s.funcs.iter().enumerate() {
            if i > 0 {
                self.blank();
            }
            self.func(f);
        }
        self.out
    }

    fn var(&mut self, v: &GVar) {
        if let Some(d) = &v.doc {
            for l in d.lines() {
                self.line(&format!("## {}", l));
            }
        }
        if let Some(c) = &v.comment {
            for l in c.lines() {
                self.line(&format!("# {}", l.trim()));
            }
        }
        let mut s = String::new();
        if v.export_storage {
            s.push_str("@export_storage ");
        } else if v.export {
            s.push_str("@export ");
        }
        s.push_str("var ");
        s.push_str(&v.name);
        if let Some(t) = &v.ty {
            s.push_str(": ");
            s.push_str(t);
        }
        if let Some(i) = &v.init {
            s.push_str(" = ");
            s.push_str(&i.render());
        }
        if v.setter.is_none() && v.getter.is_none() {
            self.line(&s);
            return;
        }
        s.push(':');
        self.line(&s);
        self.indent += 1;
        if let Some(body) = &v.setter {
            self.line("set(value):");
            self.indent += 1;
            self.block(body);
            self.indent -= 1;
        }
        if let Some(body) = &v.getter {
            self.line("get:");
            self.indent += 1;
            self.block(body);
            self.indent -= 1;
        }
        self.indent -= 1;
    }

    fn func(&mut self, f: &GFunc) {
        if let Some(d) = &f.doc {
            for l in d.lines() {
                self.line(&format!("## {}", l));
            }
        }
        if let Some(c) = &f.comment {
            for l in c.lines() {
                self.line(&format!("# {}", l.trim()));
            }
        }
        let params: Vec<String> = f
            .params
            .iter()
            .map(|p| {
                let mut s = p.name.clone();
                if let Some(t) = &p.ty {
                    s.push_str(": ");
                    s.push_str(t);
                }
                if let Some(d) = &p.default {
                    s.push_str(" = ");
                    s.push_str(&d.render());
                }
                s
            })
            .collect();
        let mut head = String::new();
        if f.is_static {
            head.push_str("static ");
        }
        head.push_str("func ");
        head.push_str(&f.name);
        head.push('(');
        head.push_str(&params.join(", "));
        head.push(')');
        if let Some(r) = &f.ret {
            head.push_str(" -> ");
            head.push_str(r);
        }
        head.push(':');
        self.line(&head);
        self.indent += 1;
        self.block(&f.body);
        self.indent -= 1;
    }

    fn block(&mut self, stmts: &[GStmt]) {
        let has_code = stmts.iter().any(|s| !matches!(s, GStmt::Comment(_) | GStmt::Blank));
        if !has_code {
            for s in stmts {
                self.stmt(s);
            }
            self.line("pass");
            return;
        }
        for s in stmts {
            self.stmt(s);
        }
    }

    fn stmt(&mut self, s: &GStmt) {
        match s {
            GStmt::Expr(e) => self.line(&e.render()),
            GStmt::VarDecl { name, ty, init } => {
                let mut l = format!("var {}", name);
                if let Some(t) = ty {
                    l.push_str(": ");
                    l.push_str(t);
                }
                if let Some(i) = init {
                    l.push_str(" = ");
                    l.push_str(&i.render());
                }
                self.line(&l);
            }
            GStmt::Assign { target, op, value } => {
                self.line(&format!("{} {} {}", target.render(), op, value.render()));
            }
            GStmt::If { branches, els } => {
                for (i, (cond, body)) in branches.iter().enumerate() {
                    let kw = if i == 0 { "if" } else { "elif" };
                    self.line(&format!("{} {}:", kw, cond.render()));
                    self.indent += 1;
                    self.block(body);
                    self.indent -= 1;
                }
                if let Some(e) = els {
                    self.line("else:");
                    self.indent += 1;
                    self.block(e);
                    self.indent -= 1;
                }
            }
            GStmt::While { cond, body } => {
                self.line(&format!("while {}:", cond.render()));
                self.indent += 1;
                self.block(body);
                self.indent -= 1;
            }
            GStmt::For { var, iter, body } => {
                self.line(&format!("for {} in {}:", var, iter.render()));
                self.indent += 1;
                self.block(body);
                self.indent -= 1;
            }
            GStmt::Match { subject, arms } => {
                self.line(&format!("match {}:", subject.render()));
                self.indent += 1;
                for arm in arms {
                    let pat = if arm.patterns.is_empty() {
                        "_".to_string()
                    } else {
                        arm.patterns.iter().map(|p| p.render()).collect::<Vec<_>>().join(", ")
                    };
                    self.line(&format!("{}:", pat));
                    self.indent += 1;
                    self.block(&arm.body);
                    self.indent -= 1;
                }
                self.indent -= 1;
            }
            GStmt::Break => self.line("break"),
            GStmt::Continue => self.line("continue"),
            GStmt::Pass => self.line("pass"),
            GStmt::Return(None) => self.line("return"),
            GStmt::Return(Some(e)) => self.line(&format!("return {}", e.render())),
            GStmt::Comment(c) => {
                for l in c.lines() {
                    self.line(&format!("# {}", l));
                }
            }
            GStmt::Raw(r) => self.line(r),
            GStmt::Blank => self.blank(),
        }
    }
}

impl Default for Printer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn precedence() {
        let a = GExpr::ident("a");
        let b = GExpr::ident("b");
        let c = GExpr::ident("c");
        // (a + b) * c
        let e = a.clone().bin("+", b.clone()).bin("*", c.clone());
        assert_eq!(e.render(), "(a + b) * c");
        // a - (b - c)
        let e = a.clone().bin("-", b.clone().bin("-", c.clone()));
        assert_eq!(e.render(), "a - (b - c)");
        // not (a == b)
        let e = a.clone().bin("==", b.clone()).not();
        assert_eq!(e.render(), "not (a == b)");
        // (x as Node) != null
        let e = GExpr::As(Box::new(a.clone()), "Node".into()).bin("!=", GExpr::Null);
        assert_eq!(e.render(), "(a as Node) != null");
        // -(a + b)
        let e = a.clone().bin("+", b.clone()).neg();
        assert_eq!(e.render(), "-(a + b)");
        // ternary in arg
        let t = GExpr::Ternary { cond: Box::new(c.clone()), then: Box::new(a.clone()), els: Box::new(b.clone()) };
        let e = GExpr::ident("f").call(vec![t.clone()]);
        assert_eq!(e.render(), "f(a if c else b)");
        // (a if c else b).x
        assert_eq!(t.clone().member("x").render(), "(a if c else b).x");
        // (a + b).length()
        assert_eq!(a.clone().bin("+", b.clone()).method("length", vec![]).render(), "(a + b).length()");
        // a and (b or c)
        assert_eq!(a.clone().bin("and", b.clone().bin("or", c.clone())).render(), "a and (b or c)");
        // (a < b) == c
        assert_eq!(a.clone().bin("<", b.clone()).bin("==", c.clone()).render(), "(a < b) == c");
        // 1.5.x -> (1.5).x
        assert_eq!(GExpr::Float(1.5).member("x").render(), "(1.5).x");
        assert_eq!(GExpr::Float(2.0).render(), "2.0");
        assert_eq!(GExpr::Float(1e-5).render(), "0.00001");
        assert_eq!(GExpr::str("a\"b\n").render(), "\"a\\\"b\\n\"");
    }

    #[test]
    fn print_script() {
        let s = GScript {
            extends: Some("Node3D".into()),
            vars: vec![GVar { name: "x".into(), ty: Some("int".into()), init: Some(GExpr::Int(1)), export: true, ..Default::default() }],
            funcs: vec![GFunc {
                name: "f".into(),
                params: vec![GParam { name: "a".into(), ty: Some("int".into()), default: None }],
                ret: Some("int".into()),
                body: vec![GStmt::If {
                    branches: vec![(GExpr::ident("a").bin(">", GExpr::Int(0)), vec![GStmt::Return(Some(GExpr::Int(1)))])],
                    els: Some(vec![]),
                }],
                ..Default::default()
            }],
            ..Default::default()
        };
        let out = Printer::new().script(&s);
        assert_eq!(out, "extends Node3D\n\n@export var x: int = 1\n\nfunc f(a: int) -> int:\n\tif a > 0:\n\t\treturn 1\n\telse:\n\t\tpass\n");
    }
}
