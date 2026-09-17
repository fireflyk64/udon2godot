//! Where does C# code let `null` into a variable?
//!
//! Arrays, `DataDictionary` / `DataList` and `Nullable<T>` are Godot *value* types in the generated
//! code (`Array`, `Dictionary`, `AABB` ...), and a typed SafeGDScript slot rejects null. Most such
//! variables never see a null, so they keep the plain type (it is what lets the sandbox compile
//! indexing and loops to instructions); the ones that are compared with null, set to null or
//! returned as null are declared nullable (`Array?`). The scan is by name and purely syntactic:
//! marking a variable nullable that did not need it costs nothing but speed.

use crate::ast::*;
use crate::token::Lit;
use std::collections::HashSet;

/// Call `f` on every expression under `e`, outermost first.
pub fn walk_expr(e: &Expr, f: &mut dyn FnMut(&Expr)) {
    f(e);
    match e {
        Expr::Lit(..) | Expr::Ident(..) | Expr::This(_) | Expr::Base(_) | Expr::TypeExpr(..) | Expr::Typeof(..) | Expr::Default(..) => {}
        Expr::Interp(pieces, _) => {
            for p in pieces {
                if let InterpPiece::Expr { expr, .. } = p {
                    walk_expr(expr, f);
                }
            }
        }
        Expr::Member { target, .. } => walk_expr(target, f),
        Expr::GenericName { name, .. } => walk_expr(name, f),
        Expr::Call { callee, args, .. } => {
            walk_expr(callee, f);
            for a in args {
                walk_expr(&a.expr, f);
            }
        }
        Expr::Index { target, indices, .. } => {
            walk_expr(target, f);
            for i in indices {
                walk_expr(i, f);
            }
        }
        Expr::Unary { expr, .. } | Expr::Cast { expr, .. } | Expr::Is { expr, .. } | Expr::As { expr, .. } => walk_expr(expr, f),
        Expr::Binary { lhs, rhs, .. } | Expr::Assign { lhs, rhs, .. } => {
            walk_expr(lhs, f);
            walk_expr(rhs, f);
        }
        Expr::Cond { cond, then, els, .. } => {
            walk_expr(cond, f);
            walk_expr(then, f);
            walk_expr(els, f);
        }
        Expr::New { args, init, .. } => {
            for a in args {
                walk_expr(&a.expr, f);
            }
            for i in init.iter().flatten() {
                walk_expr(i, f);
            }
        }
        Expr::NewArray { sizes, init, .. } => {
            for s in sizes.iter().flatten() {
                walk_expr(s, f);
            }
            for i in init.iter().flatten() {
                walk_expr(i, f);
            }
        }
        Expr::ArrayInit(items, _) => {
            for i in items {
                walk_expr(i, f);
            }
        }
        Expr::Nameof(inner, _) | Expr::Paren(inner, _) | Expr::Checked(inner, _, _) => walk_expr(inner, f),
        Expr::Lambda { body, .. } => match &**body {
            LambdaBody::Expr(x) => walk_expr(x, f),
            LambdaBody::Block(b) => walk_stmts(&b.stmts, f, &mut |_| {}),
        },
    }
}

/// Call `f` on every expression and `ret` on every `return` value under the statements.
pub fn walk_stmts(stmts: &[Stmt], f: &mut dyn FnMut(&Expr), ret: &mut dyn FnMut(&Expr)) {
    for s in stmts {
        walk_stmt(s, f, ret);
    }
}

fn walk_stmt(s: &Stmt, f: &mut dyn FnMut(&Expr), ret: &mut dyn FnMut(&Expr)) {
    match s {
        Stmt::Block(b) => walk_stmts(&b.stmts, f, ret),
        Stmt::LocalDecl { declarators, .. } => {
            for d in declarators {
                if let Some(i) = &d.init {
                    walk_expr(i, f);
                }
            }
        }
        Stmt::Expr(x, _) => walk_expr(x, f),
        Stmt::If { cond, then, els, .. } => {
            walk_expr(cond, f);
            walk_stmt(then, f, ret);
            if let Some(e) = els {
                walk_stmt(e, f, ret);
            }
        }
        Stmt::While { cond, body, .. } | Stmt::DoWhile { body, cond, .. } => {
            walk_expr(cond, f);
            walk_stmt(body, f, ret);
        }
        Stmt::For { init, cond, update, body, .. } => {
            walk_stmts(init, f, ret);
            if let Some(c) = cond {
                walk_expr(c, f);
            }
            for u in update {
                walk_expr(u, f);
            }
            walk_stmt(body, f, ret);
        }
        Stmt::Foreach { iter, body, .. } => {
            walk_expr(iter, f);
            walk_stmt(body, f, ret);
        }
        Stmt::Switch { subject, sections, .. } => {
            walk_expr(subject, f);
            for sec in sections {
                walk_stmts(&sec.body, f, ret);
            }
        }
        Stmt::Return(x, _) => {
            if let Some(x) = x {
                ret(x);
                walk_expr(x, f);
            }
        }
        Stmt::Throw(x, _) | Stmt::GotoCase(x, _) => {
            if let Some(x) = x {
                walk_expr(x, f);
            }
        }
        Stmt::Try { body, catches, finally, .. } => {
            walk_stmts(&body.stmts, f, ret);
            for c in catches {
                walk_stmts(&c.stmts, f, ret);
            }
            if let Some(b) = finally {
                walk_stmts(&b.stmts, f, ret);
            }
        }
        Stmt::Lock { body, .. } => walk_stmt(body, f, ret),
        Stmt::Empty(_) | Stmt::Break(_) | Stmt::Continue(_) | Stmt::Label(..) | Stmt::Goto(..) => {}
    }
}

/// `null`, or a conditional / coalesce that can produce it (`ok ? list : null`).
pub fn may_be_null(e: &Expr) -> bool {
    match e.unparen() {
        Expr::Lit(Lit::Null, _) => true,
        Expr::Cond { then, els, .. } => may_be_null(then) || may_be_null(els),
        Expr::Binary { op: BinOp::Coalesce, rhs, .. } => may_be_null(rhs),
        Expr::Cast { expr, .. } => may_be_null(expr),
        _ => false,
    }
}

/// The variable or member an expression names: `x`, `this.x`, `other.x`.
fn named(e: &Expr) -> Option<&str> {
    match e.unparen() {
        Expr::Ident(n, _) => Some(n),
        Expr::Member { name, .. } => Some(name),
        _ => None,
    }
}

/// Add the names the statements compare with null (`x == null`, `x ?? y`, `x?.y`), set to null
/// (`x = null`, `x = ok ? y : null`).
pub fn null_touched(stmts: &[Stmt], out: &mut HashSet<String>) {
    let mut visit = |e: &Expr| match e {
        Expr::Binary { op: BinOp::Eq | BinOp::Ne, lhs, rhs, .. } => {
            let pair = if may_be_null(rhs) { Some(lhs) } else if may_be_null(lhs) { Some(rhs) } else { None };
            if let Some(n) = pair.and_then(|x| named(x)) {
                out.insert(n.to_string());
            }
        }
        Expr::Binary { op: BinOp::Coalesce, lhs, .. } => {
            if let Some(n) = named(lhs) {
                out.insert(n.to_string());
            }
        }
        Expr::Assign { op, lhs, rhs, .. } => {
            if (op.is_none() && may_be_null(rhs)) || *op == Some(BinOp::Coalesce) {
                if let Some(n) = named(lhs) {
                    out.insert(n.to_string());
                }
            }
        }
        Expr::Member { target, null_cond: true, .. } | Expr::Index { target, null_cond: true, .. } => {
            if let Some(n) = named(target) {
                out.insert(n.to_string());
            }
        }
        Expr::Is { expr, ty: TypeRef::Named { name, .. }, .. } if name == "null" => {
            if let Some(n) = named(expr) {
                out.insert(n.to_string());
            }
        }
        _ => {}
    };
    walk_stmts(stmts, &mut visit, &mut |_| {});
}

/// Does any `return` in the statements hand back a null?
pub fn returns_null(stmts: &[Stmt]) -> bool {
    let mut found = false;
    walk_stmts(stmts, &mut |_| {}, &mut |x| found |= may_be_null(x));
    found
}
