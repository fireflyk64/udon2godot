//! Structural summary of a parsed compilation unit, for the differential parser test
//! (`tools/parser_diff.py`): the same counts are taken from tree-sitter-c-sharp's tree and compared,
//! so a construct this parser drops, splits or attaches to the wrong member shows up as a diff.

use crate::ast::*;
use std::collections::BTreeMap;

#[derive(Default)]
struct Counts(BTreeMap<&'static str, usize>);

impl Counts {
    fn add(&mut self, k: &'static str) {
        *self.0.entry(k).or_insert(0) += 1;
    }
    fn json(&self) -> String {
        let parts: Vec<String> = self.0.iter().map(|(k, v)| format!("\"{}\": {}", k, v)).collect();
        format!("{{{}}}", parts.join(", "))
    }
}

fn esc(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn block(b: &Block, c: &mut Counts) {
    for s in &b.stmts {
        stmt(s, c);
    }
}

fn stmt(s: &Stmt, c: &mut Counts) {
    match s {
        Stmt::Block(b) => block(b, c),
        Stmt::Empty(_) => {}
        Stmt::LocalDecl { declarators, .. } => {
            c.add("local");
            for d in declarators {
                c.add("declarator");
                if let Some(e) = &d.init {
                    expr(e, c);
                }
            }
        }
        Stmt::Expr(e, _) => {
            c.add("expr_stmt");
            expr(e, c);
        }
        Stmt::If { cond, then, els, .. } => {
            c.add("if");
            expr(cond, c);
            stmt(then, c);
            if let Some(e) = els {
                stmt(e, c);
            }
        }
        Stmt::While { cond, body, .. } => {
            c.add("while");
            expr(cond, c);
            stmt(body, c);
        }
        Stmt::DoWhile { body, cond, .. } => {
            c.add("do");
            stmt(body, c);
            expr(cond, c);
        }
        Stmt::For { init, cond, update, body, .. } => {
            c.add("for");
            for i in init {
                // tree-sitter keeps the initializer as a declaration / expressions of the `for`
                match i {
                    Stmt::LocalDecl { declarators, .. } => {
                        for d in declarators {
                            c.add("declarator");
                            if let Some(e) = &d.init {
                                expr(e, c);
                            }
                        }
                    }
                    Stmt::Expr(e, _) => expr(e, c),
                    other => stmt(other, c),
                }
            }
            if let Some(e) = cond {
                expr(e, c);
            }
            for u in update {
                expr(u, c);
            }
            stmt(body, c);
        }
        Stmt::Foreach { iter, body, .. } => {
            c.add("foreach");
            expr(iter, c);
            stmt(body, c);
        }
        Stmt::Switch { subject, sections, .. } => {
            c.add("switch");
            expr(subject, c);
            for sec in sections {
                for l in &sec.labels {
                    // tree-sitter opens a section per label, so labels are the comparable unit
                    c.add("switch_label");
                    if let SwitchLabel::Case(e) = l {
                        expr(e, c);
                    }
                }
                for s in &sec.body {
                    stmt(s, c);
                }
            }
        }
        Stmt::Break(_) => c.add("break"),
        Stmt::Continue(_) => c.add("continue"),
        Stmt::Return(e, _) => {
            c.add("return");
            if let Some(e) = e {
                expr(e, c);
            }
        }
        Stmt::Throw(e, _) => {
            c.add("throw");
            if let Some(e) = e {
                expr(e, c);
            }
        }
        Stmt::Try { body, catches, finally, .. } => {
            c.add("try");
            block(body, c);
            for b in catches {
                block(b, c);
            }
            if let Some(f) = finally {
                block(f, c);
            }
        }
        Stmt::Lock { body, .. } => {
            c.add("lock");
            stmt(body, c);
        }
        Stmt::GotoCase(e, _) => {
            c.add("goto");
            if let Some(e) = e {
                expr(e, c);
            }
        }
        Stmt::Label(..) => c.add("label"),
        Stmt::Goto(..) => c.add("goto"),
    }
}

fn args(a: &[Arg], c: &mut Counts) {
    for x in a {
        expr(&x.expr, c);
    }
}

fn expr(e: &Expr, c: &mut Counts) {
    match e {
        Expr::Lit(..) | Expr::Ident(..) | Expr::This(_) | Expr::Base(_) | Expr::TypeExpr(..) | Expr::Typeof(..) | Expr::Default(..) => {}
        Expr::Interp(pieces, _) => {
            c.add("interp");
            for p in pieces {
                if let InterpPiece::Expr { expr: e, .. } = p {
                    expr(e, c);
                }
            }
        }
        Expr::Member { target, .. } => {
            c.add("member");
            expr(target, c);
        }
        Expr::GenericName { name, .. } => expr(name, c),
        Expr::Call { callee, args: a, .. } => {
            c.add("call");
            expr(callee, c);
            args(a, c);
        }
        Expr::Index { target, indices, .. } => {
            c.add("index");
            expr(target, c);
            for i in indices {
                expr(i, c);
            }
        }
        Expr::Unary { expr: x, .. } => {
            c.add("unary");
            expr(x, c);
        }
        Expr::Binary { lhs, rhs, .. } => {
            c.add("binary");
            expr(lhs, c);
            expr(rhs, c);
        }
        Expr::Assign { lhs, rhs, .. } => {
            c.add("assign");
            expr(lhs, c);
            expr(rhs, c);
        }
        Expr::Cond { cond, then, els, .. } => {
            c.add("cond");
            expr(cond, c);
            expr(then, c);
            expr(els, c);
        }
        Expr::Cast { expr: x, .. } => {
            c.add("cast");
            expr(x, c);
        }
        Expr::Is { expr: x, .. } => {
            c.add("is");
            expr(x, c);
        }
        Expr::As { expr: x, .. } => {
            c.add("as");
            expr(x, c);
        }
        Expr::New { args: a, init, .. } => {
            c.add("new");
            args(a, c);
            if let Some(i) = init {
                for x in i {
                    expr(x, c);
                }
            }
        }
        Expr::NewArray { sizes, init, .. } => {
            c.add("new_array");
            for s in sizes.iter().flatten() {
                expr(s, c);
            }
            if let Some(i) = init {
                for x in i {
                    expr(x, c);
                }
            }
        }
        Expr::ArrayInit(items, _) => {
            for x in items {
                expr(x, c);
            }
        }
        Expr::Nameof(x, _) => expr(x, c),
        Expr::Paren(x, _) => expr(x, c),
        Expr::Checked(x, _, _) => expr(x, c),
        Expr::Lambda { body, .. } => {
            c.add("lambda");
            match &**body {
                LambdaBody::Expr(x) => expr(x, c),
                LambdaBody::Block(b) => block(b, c),
            }
        }
    }
}

fn method_json(kind: &str, m: &MethodDecl) -> String {
    let mut c = Counts::default();
    if let Some(b) = &m.body {
        block(b, &mut c);
    }
    format!("{{\"kind\": \"{}\", \"name\": \"{}\", \"params\": {}, \"has_body\": {}, \"counts\": {}}}", kind, esc(&m.name), m.params.len(), m.body.is_some(), c.json())
}

fn type_json(t: &TypeDecl) -> String {
    match t {
        TypeDecl::Enum(e) => format!("{{\"kind\": \"enum\", \"name\": \"{}\", \"members\": {}}}", esc(&e.name), e.members.len()),
        TypeDecl::Class(cl) => {
            let mut fields: Vec<String> = Vec::new();
            let mut props: Vec<String> = Vec::new();
            let mut methods: Vec<String> = Vec::new();
            let mut nested: Vec<String> = Vec::new();
            let mut init = Counts::default();
            for m in &cl.members {
                match m {
                    Member::Field(f) => {
                        for d in &f.declarators {
                            fields.push(format!("\"{}\"", esc(&d.name)));
                            if let Some(e) = &d.init {
                                expr(e, &mut init);
                            }
                        }
                    }
                    Member::Property(p) => {
                        let mut c = Counts::default();
                        for a in [&p.getter, &p.setter].into_iter().flatten() {
                            if let Some(b) = &a.body {
                                block(b, &mut c);
                            }
                        }
                        if let Some(e) = &p.expr_body {
                            expr(e, &mut c);
                        }
                        if let Some(e) = &p.init {
                            expr(e, &mut c);
                        }
                        props.push(format!("{{\"name\": \"{}\", \"counts\": {}}}", esc(&p.name), c.json()));
                    }
                    Member::Method(md) => methods.push(method_json("method", md)),
                    Member::Constructor(md) => methods.push(method_json("ctor", md)),
                    Member::Type(t) => nested.push(type_json(t)),
                }
            }
            format!(
                "{{\"kind\": \"class\", \"name\": \"{}\", \"fields\": [{}], \"field_init\": {}, \"props\": [{}], \"methods\": [{}], \"nested\": [{}]}}",
                esc(&cl.name),
                fields.join(", "),
                init.json(),
                props.join(", "),
                methods.join(", "),
                nested.join(", ")
            )
        }
    }
}

/// JSON summary of one compilation unit.
pub fn summarize(cu: &CompilationUnit) -> String {
    let types: Vec<String> = cu.types.iter().map(type_json).collect();
    format!("{{\"path\": \"{}\", \"types\": [{}]}}", esc(&cu.path), types.join(", "))
}
