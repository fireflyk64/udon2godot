//! Expression lowering.

use super::{Local, Lowerer};
use crate::api::{MemberInfo, PMode, TypeKind};
use crate::ast::*;
use crate::diag::Span;
use crate::gd::*;
use crate::template::{expand, TemplateArgs};
use crate::token::Lit;
use crate::types::{canonical_type_name, Ty};

/// A lowered expression with its C# type.
#[derive(Debug, Clone)]
pub struct Lw {
    pub e: GExpr,
    pub ty: Ty,
}

impl Lw {
    pub fn new(e: GExpr, ty: Ty) -> Self {
        Self { e, ty }
    }
    pub fn unknown(e: GExpr) -> Self {
        Self { e, ty: Ty::Unknown }
    }
}

/// What an identifier or member path resolved to.
enum Resolved {
    Value(Lw),
    Type(String),
    /// A method group on a target (target expr, method name)
    Method(Option<Lw>, String),
    Unresolved,
}

impl<'p> Lowerer<'p> {
    // ----- entry points -----

    pub(crate) fn lower_expr(&mut self, e: &Expr) -> Lw {
        match e {
            Expr::Lit(l, _) => self.lower_lit(l),
            Expr::Interp(pieces, _) => self.lower_interp(pieces),
            Expr::Ident(name, span) => match self.resolve_ident(name, *span) {
                Resolved::Value(v) => v,
                Resolved::Type(t) => Lw::new(GExpr::ident(&t), Ty::TypeName(t)),
                Resolved::Method(_, n) => Lw::new(GExpr::ident(&crate::names::mangle(&n)), Ty::Method(n)),
                Resolved::Unresolved => {
                    self.usage.unresolved.insert(name.clone());
                    self.warn(*span, format!("unresolved identifier `{}`", name));
                    Lw::unknown(GExpr::ident(&crate::names::mangle_local(name)))
                }
            },
            Expr::This(_) => Lw::new(GExpr::ident("self"), Ty::Named(self.class.name.clone())),
            Expr::Base(_) => Lw::new(GExpr::ident("super"), Ty::Named(self.class.base.clone().unwrap_or_default())),
            Expr::TypeExpr(t, _) => {
                let ty = self.prog.resolve_type_ref(t);
                Lw::new(GExpr::ident(&ty.name()), Ty::TypeName(ty.name()))
            }
            Expr::Member { target, name, null_cond, span } => self.lower_member(target, name, *null_cond, *span),
            Expr::GenericName { name, span, .. } => {
                self.error(*span, "generic name used outside of a call");
                let _ = name;
                Lw::unknown(GExpr::Null)
            }
            Expr::Call { callee, args, span } => self.lower_call(callee, args, *span),
            Expr::Index { target, indices, null_cond, span } => self.lower_index(target, indices, *null_cond, *span),
            Expr::Unary { op, expr, span } => self.lower_unary(*op, expr, *span),
            Expr::Binary { op, lhs, rhs, span } => self.lower_binary(*op, lhs, rhs, *span),
            Expr::Assign { op, lhs, rhs, .. } => {
                // assignment as expression: hoist to pre-statements, value is the lhs
                let stmts = self.lower_assign_stmt(*op, lhs, rhs);
                self.pre.extend(stmts);
                self.lower_expr(lhs)
            }
            Expr::Cond { cond, then, els, .. } => {
                let c = self.lower_cond(cond);
                let saved = self.hoist_ok;
                self.hoist_ok = false;
                let t = self.lower_expr(then);
                let f = self.lower_expr(els);
                self.hoist_ok = saved;
                let ty = if t.ty == f.ty || matches!(f.ty, Ty::Null | Ty::Unknown) { t.ty.clone() } else if matches!(t.ty, Ty::Null | Ty::Unknown) { f.ty.clone() } else if t.ty.is_numeric() && f.ty.is_numeric() { Ty::binary_numeric(&t.ty, &f.ty) } else { t.ty.clone() };
                let (te, fe) = (self.coerce(t, &ty).e, self.coerce(f, &ty).e);
                Lw::new(GExpr::Ternary { cond: Box::new(c), then: Box::new(te), els: Box::new(fe) }, ty)
            }
            Expr::Cast { ty, expr, span } => self.lower_cast(ty, expr, *span),
            Expr::Is { expr, ty, .. } => {
                let v = self.lower_expr(expr);
                let t = self.prog.resolve_type_ref(ty);
                let name = self.prog.runtime_type_name(&t);
                if matches!(t, Ty::Null) {
                    return Lw::new(v.e.bin("==", GExpr::Null), Ty::Bool);
                }
                Lw::new(GExpr::ident("U").method("is_type", vec![v.e, GExpr::str(&name)]), Ty::Bool)
            }
            Expr::As { expr, ty, .. } => {
                let v = self.lower_expr(expr);
                let t = self.prog.resolve_type_ref(ty);
                if self.prog.is_unity_object(&t) {
                    let name = self.prog.runtime_type_name(&t);
                    Lw::new(GExpr::ident("U").method("as_type", vec![v.e, GExpr::str(&name)]), t)
                } else {
                    Lw::new(v.e, t)
                }
            }
            Expr::New { ty, args, init, span } => self.lower_new(ty, args, init.as_deref(), *span),
            Expr::NewArray { elem, sizes, rank, init, span } => self.lower_new_array(elem, sizes, *rank, init.as_deref(), *span),
            Expr::ArrayInit(items, _) => {
                let items: Vec<GExpr> = items.iter().map(|i| self.lower_expr(i).e).collect();
                Lw::new(GExpr::Array(items), Ty::Array(Box::new(Ty::Unknown)))
            }
            Expr::Typeof(t, _) => {
                let ty = self.prog.resolve_type_ref(t);
                Lw::new(GExpr::str(&self.prog.runtime_type_name(&ty)), Ty::Named("Type".into()))
            }
            Expr::Nameof(inner, _) => {
                let n = inner.as_dotted_name().map(|d| d.rsplit('.').next().unwrap().to_string()).unwrap_or_default();
                Lw::new(GExpr::str(&n), Ty::String)
            }
            Expr::Default(t, _) => {
                let ty = t.as_ref().map(|t| self.prog.resolve_type_ref(t)).unwrap_or(Ty::Unknown);
                let d = self.prog.default_value(&ty);
                Lw::new(d, ty)
            }
            Expr::Paren(inner, _) => {
                let v = self.lower_expr(inner);
                Lw::new(v.e, v.ty)
            }
            Expr::Checked(inner, _, _) => self.lower_expr(inner),
            Expr::Lambda { span, .. } => {
                self.error(*span, "lambdas are not supported by Udon");
                Lw::unknown(GExpr::Null)
            }
        }
    }

    /// Lower an expression in boolean context (converts Unity objects / players to validity checks).
    pub(crate) fn lower_cond(&mut self, e: &Expr) -> GExpr {
        let lw = self.lower_expr(e);
        self.to_bool(lw)
    }

    pub(crate) fn to_bool(&mut self, lw: Lw) -> GExpr {
        // catalog `op implicit_bool(T)` (RaycastHit2D, ...)
        if let Ty::Named(n) = &lw.ty {
            let ops: Vec<MemberInfo> = self.prog.catalog.operators(n, "implicit_bool").into_iter().cloned().collect();
            if let Some(op) = ops.first() {
                if let Some(t) = &op.get {
                    self.record_mapped(op);
                    return self.expand_template(t, None, &[lw.e.clone()], None, &[], &[], &op.name);
                }
            }
        }
        if self.prog.is_unity_object(&lw.ty) {
            return GExpr::ident("is_instance_valid").call(vec![lw.e]);
        }
        if self.prog.is_player(&lw.ty) {
            return GExpr::ident("Udon").method("is_valid", vec![lw.e]);
        }
        lw.e
    }

    /// Insert implicit conversions when an expression of type `from` is used where `to` is expected.
    pub(crate) fn coerce(&mut self, lw: Lw, to: &Ty) -> Lw {
        match (&lw.ty, to) {
            (Ty::Char, Ty::Int) | (Ty::Char, Ty::UInt) | (Ty::Char, Ty::Long) | (Ty::Char, Ty::Float) | (Ty::Char, Ty::Double) | (Ty::Char, Ty::Short) | (Ty::Char, Ty::Byte) | (Ty::Char, Ty::UShort) => {
                let e = lw.e.method("unicode_at", vec![GExpr::Int(0)]);
                let e = if to.is_real() { GExpr::ident("float").call(vec![e]) } else { e };
                Lw::new(e, to.clone())
            }
            (Ty::Char, Ty::String) => Lw::new(lw.e, Ty::String),
            (Ty::Named(n), Ty::Named(m)) if n != m => {
                // implicit struct conversions from the catalog (Vector2 → Vector3 etc.)
                if let Some(c) = self.prog.catalog.cast(n, to) {
                    if let Some(t) = &c.get {
                        let s = self.expand_template(t, Some(&lw.e), &[], None, &[], &[], &c.name);
                        return Lw::new(s, to.clone());
                    }
                }
                let ops = self.prog.catalog.operators(m, &format!("implicit_{}", m));
                if let Some(op) = ops.first() {
                    if op.params.len() == 1 && op.params[0].ty == lw.ty {
                        if let Some(t) = &op.get {
                            let s = self.expand_template(t, None, &[lw.e.clone()], None, &[], &[], &op.name);
                            return Lw::new(s, to.clone());
                        }
                    }
                }
                Lw::new(lw.e, to.clone())
            }
            (from, Ty::Named(m)) if from.is_numeric() || from.is_string() || from.is_bool() => {
                // implicit conversions into wrapper structs (float → MinMaxCurve, string → DataToken)
                let ops = self.prog.catalog.operators(m, &format!("implicit_{}", m));
                for op in ops {
                    if op.params.len() == 1 && (op.params[0].ty == lw.ty || (op.params[0].ty.is_numeric() && lw.ty.is_numeric())) {
                        if let Some(t) = &op.get {
                            let s = self.expand_template(t, None, &[lw.e.clone()], None, &[], &[], &op.name);
                            return Lw::new(s, to.clone());
                        }
                    }
                }
                Lw::new(lw.e, to.clone())
            }
            (Ty::Named(_), Ty::Bool) => {
                let e = self.to_bool(lw);
                Lw::new(e, Ty::Bool)
            }
            _ => lw,
        }
    }

    // ----- literals -----

    fn lower_lit(&mut self, l: &Lit) -> Lw {
        match l {
            Lit::Int(v) => Lw::new(GExpr::Int(*v), Ty::Int),
            Lit::UInt(v) => Lw::new(GExpr::Int(*v as i64), Ty::UInt),
            Lit::Long(v) => Lw::new(GExpr::Int(*v), Ty::Long),
            Lit::ULong(v) => Lw::new(GExpr::Int(*v as i64), Ty::ULong),
            Lit::Float(v) => Lw::new(GExpr::Float(*v), Ty::Float),
            Lit::Double(v) => Lw::new(GExpr::Float(*v), Ty::Double),
            Lit::Str(s) => Lw::new(GExpr::str(s), Ty::String),
            Lit::Char(c) => Lw::new(GExpr::str(&c.to_string()), Ty::Char),
            Lit::Bool(b) => Lw::new(GExpr::Bool(*b), Ty::Bool),
            Lit::Null => Lw::new(GExpr::Null, Ty::Null),
        }
    }

    fn lower_interp(&mut self, pieces: &[InterpPiece]) -> Lw {
        let mut acc: Option<GExpr> = None;
        for p in pieces {
            let part = match p {
                InterpPiece::Text(t) => GExpr::str(t),
                InterpPiece::Expr { expr, format } => {
                    let lw = self.lower_expr(expr);
                    match format {
                        Some(f) => GExpr::ident("U").method("format_num", vec![lw.e, GExpr::str(f)]),
                        None => self.stringify(lw),
                    }
                }
            };
            acc = Some(match acc {
                Some(a) => a.bin("+", part),
                None => part,
            });
        }
        Lw::new(acc.unwrap_or_else(|| GExpr::str("")), Ty::String)
    }

    /// `str(x)` unless x is already a string; floats use C#-style formatting.
    pub(crate) fn stringify(&mut self, lw: Lw) -> GExpr {
        match &lw.ty {
            Ty::String | Ty::Char => lw.e,
            Ty::Float | Ty::Double => GExpr::ident("U").method("float_str", vec![lw.e]),
            Ty::Bool => GExpr::ident("U").method("bool_str", vec![lw.e]),
            Ty::Named(n) if n == "Vector3" => GExpr::ident("U").method("vec3_str", vec![lw.e]),
            Ty::Named(n) if n == "Vector2" => GExpr::ident("U").method("vec2_str", vec![lw.e]),
            _ => GExpr::ident("str").call(vec![lw.e]),
        }
    }

    // ----- identifiers -----

    fn resolve_ident(&mut self, name: &str, span: Span) -> Resolved {
        if let Some(l) = self.lookup_local(name) {
            return Resolved::Value(Lw::new(GExpr::ident(&l.gd_name), l.ty.clone()));
        }
        // fields / properties of this class chain
        if let Some((_, f)) = self.prog.find_field(&self.class.name, name) {
            return Resolved::Value(Lw::new(GExpr::ident(&f.gd_name), f.ty.clone()));
        }
        if let Some((_, p)) = self.prog.find_prop(&self.class.name, name) {
            if p.decl.is_auto() {
                return Resolved::Value(Lw::new(GExpr::ident(&p.gd_name), p.ty.clone()));
            }
            return Resolved::Value(Lw::new(GExpr::ident(&format!("get_{}", p.gd_name)).call(vec![]), p.ty.clone()));
        }
        if !self.prog.find_methods(&self.class.name, name).is_empty() {
            return Resolved::Method(None, name.to_string());
        }
        // inherited catalog members of the behaviour base (gameObject, transform, enabled, ...)
        if let Some(base) = self.prog.catalog_base_of_class(&self.class.name) {
            let base_name = base.name.clone();
            if let Some(m) = self.prog.catalog.field(&base_name, name, false) {
                let m = m.clone();
                let target = Lw::new(GExpr::ident("self"), Ty::Named(self.class.name.clone()));
                return Resolved::Value(self.apply_getter(&m, Some(&target), span));
            }
            if !self.prog.catalog.members(&base_name, name).is_empty() {
                return Resolved::Method(Some(Lw::new(GExpr::ident("self"), Ty::Named(self.class.name.clone()))), name.to_string());
            }
        }
        // types
        if self.prog.is_user_class(name) {
            return Resolved::Type(name.to_string());
        }
        if let Some(e) = self.prog.user_enum(name) {
            return Resolved::Type(e.name.clone());
        }
        if let Some(t) = self.prog.catalog.resolve_name(name) {
            return Resolved::Type(t.to_string());
        }
        let _ = span;
        Resolved::Unresolved
    }

    /// Resolve a dotted path like `VRC.Udon.Common.Interfaces.NetworkEventTarget` or
    /// `UnityEngine.Vector3` to a type when its head is not a value.
    fn resolve_dotted_type(&self, e: &Expr) -> Option<String> {
        let dotted = e.as_dotted_name()?;
        let head = dotted.split('.').next()?;
        if self.lookup_local(head).is_some() || self.prog.find_field(&self.class.name, head).is_some() || self.prog.find_prop(&self.class.name, head).is_some() {
            return None;
        }
        let canon = canonical_type_name(&dotted);
        if self.prog.is_user_class(&canon) {
            return Some(canon);
        }
        if let Some(e) = self.prog.user_enum(&canon) {
            return Some(e.name.clone());
        }
        if canon.contains('.') || dotted.contains('.') {
            if let Some(t) = self.prog.catalog.resolve_name(&canon) {
                // Only accept when the *whole* path denotes a type (avoid `transform.position` → `Transform`).
                let ok = self.prog.catalog.get(&canon).is_some() || self.prog.catalog.get(&canon.replace('.', ".")).is_some();
                if ok {
                    return Some(t.to_string());
                }
            }
        }
        None
    }

    // ----- member access -----

    fn lower_member(&mut self, target: &Expr, name: &str, null_cond: bool, span: Span) -> Lw {
        // Namespace-qualified type paths.
        let full = Expr::Member { target: Box::new(target.clone()), name: name.to_string(), null_cond: false, span };
        if let Some(t) = self.resolve_dotted_type(&full) {
            return Lw::new(GExpr::ident(&t), Ty::TypeName(t));
        }
        let t = if let Some(tn) = self.resolve_dotted_type(target) { Lw::new(GExpr::ident(&tn), Ty::TypeName(tn)) } else { self.lower_expr(target) };
        if null_cond {
            // `a?.b` → (a.b if a != null else null); evaluate `a` once
            let tmp = self.fresh_tmp();
            self.pre.push(GStmt::VarDecl { name: tmp.clone(), ty: None, init: Some(t.e.clone()) });
            let base = Lw::new(GExpr::ident(&tmp), t.ty.clone());
            let inner = self.member_on(base, name, span);
            let ty = inner.ty.clone();
            return Lw::new(GExpr::Ternary { cond: Box::new(GExpr::ident(&tmp).bin("!=", GExpr::Null)), then: Box::new(inner.e), els: Box::new(GExpr::Null) }, ty);
        }
        self.member_on(t, name, span)
    }

    /// Field/property read on a lowered target.
    fn member_on(&mut self, t: Lw, name: &str, span: Span) -> Lw {
        match t.ty.clone() {
            Ty::TypeName(tn) => self.static_member(&tn, name, span),
            // `Phase.Idle` where `Phase` is a property of enum type `Phase` (C# "Color Color" rule)
            Ty::Named(n) if self.is_enum_type(&n) && self.enum_has_member(&n, name) => self.static_member(&n, name, span),
            Ty::Named(n) => {
                if self.prog.is_user_class(&n) {
                    if let Some((_, f)) = self.prog.find_field(&n, name) {
                        if f.is_const {
                            // cross-class constant: inline literal initializer when possible
                            if n != self.class.name {
                                if let Some(init) = &f.init {
                                    let lw = self.lower_expr(init);
                                    return Lw::new(lw.e, f.ty.clone());
                                }
                            }
                            return Lw::new(GExpr::ident(&f.gd_name), f.ty.clone());
                        }
                        return Lw::new(t.e.member(&f.gd_name), f.ty.clone());
                    }
                    if let Some((_, p)) = self.prog.find_prop(&n, name) {
                        if p.decl.is_auto() {
                            return Lw::new(t.e.member(&p.gd_name), p.ty.clone());
                        }
                        return Lw::new(t.e.method(&format!("get_{}", p.gd_name), vec![]), p.ty.clone());
                    }
                    if let Some(e) = self.prog.user_enum(&format!("{}.{}", n, name)) {
                        return Lw::new(GExpr::ident(&e.name), Ty::TypeName(e.name.clone()));
                    }
                    // catalog base members (gameObject, transform, enabled, name...)
                    if let Some(base) = self.prog.catalog_base_of_class(&n) {
                        let base_name = base.name.clone();
                        if let Some(m) = self.prog.catalog.field(&base_name, name, false) {
                            let m = m.clone();
                            return self.apply_getter(&m, Some(&t), span);
                        }
                    }
                    self.warn(span, format!("unknown member `{}` on `{}`; emitted as dynamic access", name, n));
                    return Lw::unknown(t.e.member(&crate::names::mangle(name)));
                }
                // catalog type
                if let Some(m) = self.prog.catalog.field(&n, name, false) {
                    let m = m.clone();
                    return self.apply_getter(&m, Some(&t), span);
                }
                if let Some(m) = self.prog.catalog.field(&n, name, true) {
                    let m = m.clone();
                    return self.apply_getter(&m, None, span);
                }
                if self.prog.catalog.get(&n).is_some() {
                    self.record_unmapped(&n, name, span);
                    return Lw::unknown(t.e.member(name));
                }
                self.warn(span, format!("member `{}` on unknown type `{}`; emitted as dynamic access", name, n));
                Lw::unknown(t.e.member(name))
            }
            Ty::Array(_) | Ty::MultiArray(..) => match name {
                "Length" | "LongLength" | "Count" => Lw::new(t.e.method("size", vec![]), Ty::Int),
                "Rank" => Lw::new(GExpr::ident("U").method("array_rank", vec![t.e]), Ty::Int),
                _ => {
                    if let Some(m) = self.prog.catalog.field("Array", name, false) {
                        let m = m.clone();
                        return self.apply_getter(&m, Some(&t), span);
                    }
                    self.warn(span, format!("unknown array member `{}`", name));
                    Lw::unknown(t.e.member(name))
                }
            },
            Ty::String => {
                if let Some(m) = self.prog.catalog.field("string", name, false) {
                    let m = m.clone();
                    return self.apply_getter(&m, Some(&t), span);
                }
                self.warn(span, format!("unknown string member `{}`", name));
                Lw::unknown(t.e.member(name))
            }
            ty if ty.is_numeric() || ty.is_bool() => {
                let tn = ty.name();
                if let Some(m) = self.prog.catalog.field(&tn, name, false) {
                    let m = m.clone();
                    return self.apply_getter(&m, Some(&t), span);
                }
                self.warn(span, format!("unknown member `{}` on `{}`", name, tn));
                Lw::unknown(t.e.member(name))
            }
            Ty::Object | Ty::Unknown | Ty::Null => {
                // dynamic; try common Unity-ish guesses so `.Length` on unknown arrays works
                match name {
                    "Length" => Lw::new(t.e.method("size", vec![]), Ty::Int),
                    "gameObject" | "transform" => Lw::unknown(t.e),
                    _ => Lw::unknown(t.e.member(&crate::names::mangle(name))),
                }
            }
            Ty::Method(_) => {
                self.warn(span, format!("member access `{}` on a method group", name));
                Lw::unknown(t.e.member(name))
            }
            _ => Lw::unknown(t.e.member(name)),
        }
    }

    fn static_member(&mut self, tn: &str, name: &str, span: Span) -> Lw {
        // user enum member
        if let Some(e) = self.prog.user_enum(tn) {
            if let Some((_, _v)) = e.members.iter().find(|(m, _)| m == name) {
                let ename = e.name.clone();
                self.note_enum(&ename);
                let gd = self.enum_gd_name(&ename);
                return Lw::new(GExpr::ident(&gd).member(name), Ty::Named(ename));
            }
        }
        // user class static/const
        if self.prog.is_user_class(tn) {
            if let Some((_, f)) = self.prog.find_field(tn, name) {
                if tn == self.class.name {
                    return Lw::new(GExpr::ident(&f.gd_name), f.ty.clone());
                }
                if let Some(init) = &f.init {
                    if f.is_const || (f.is_static && f.is_readonly) {
                        let lw = self.lower_expr(init);
                        return Lw::new(lw.e, f.ty.clone());
                    }
                }
                self.warn(span, format!("cross-class static member `{}.{}` cannot be resolved without class_name; emitted dynamically", tn, name));
                return Lw::new(GExpr::ident("Udon").method("static_get", vec![GExpr::str(tn), GExpr::str(&f.gd_name)]), f.ty.clone());
            }
            if let Some(e) = self.prog.user_enum(&format!("{}.{}", tn, name)) {
                return Lw::new(GExpr::ident(&e.name), Ty::TypeName(e.name.clone()));
            }
            if !self.prog.find_methods(tn, name).is_empty() {
                return Lw::new(GExpr::ident(tn).member(&crate::names::mangle(name)), Ty::Method(name.to_string()));
            }
            self.warn(span, format!("unknown static member `{}.{}`", tn, name));
            return Lw::unknown(GExpr::ident(tn).member(name));
        }
        // catalog
        if let Some(t) = self.prog.catalog.get(tn) {
            let t = t.clone();
            if t.is_enum() {
                if t.enum_value(name).is_some() {
                    self.note_enum(&t.name);
                    let gd_name = self.enum_gd_name(&t.name);
                    return Lw::new(GExpr::ident(&gd_name).member(name), Ty::Named(t.name.clone()));
                }
            }
            if let Some(m) = self.prog.catalog.field(&t.name, name, true) {
                let m = m.clone();
                return self.apply_getter(&m, None, span);
            }
            // nested type: `VRCPlayerApi.TrackingDataType`
            let nested = format!("{}.{}", t.name, name);
            if let Some(nt) = self.prog.catalog.resolve_name(&nested) {
                return Lw::new(GExpr::ident(nt), Ty::TypeName(nt.to_string()));
            }
            if let Some(nt) = self.prog.catalog.get(name) {
                if nt.name != t.name && (nt.is_enum() || nt.kind == TypeKind::Struct) {
                    return Lw::new(GExpr::ident(&nt.name), Ty::TypeName(nt.name.clone()));
                }
            }
            if !self.prog.catalog.members(&t.name, name).is_empty() {
                return Lw::new(GExpr::ident(&t.name).member(name), Ty::Method(name.to_string()));
            }
            self.record_unmapped(&t.name, name, span);
            return Lw::unknown(GExpr::ident(&t.name).member(name));
        }
        self.warn(span, format!("unknown type `{}` in static access `{}.{}`", tn, tn, name));
        Lw::unknown(GExpr::ident(tn).member(name))
    }

    pub(crate) fn is_enum_type(&self, n: &str) -> bool {
        self.prog.user_enum(n).is_some() || self.prog.catalog.get(n).map_or(false, |t| t.is_enum())
    }

    fn enum_has_member(&self, n: &str, member: &str) -> bool {
        if let Some(e) = self.prog.user_enum(n) {
            return e.members.iter().any(|(m, _)| m == member);
        }
        self.prog.catalog.get(n).map_or(false, |t| t.enum_value(member).is_some())
    }

    pub(crate) fn record_unmapped(&mut self, ty: &str, member: &str, span: Span) {
        let key = format!("{}.{}", ty, member);
        *self.usage.unmapped.entry(key.clone()).or_default() += 1;
        let is_extern = self.member_is_extern(ty, member);
        if !is_extern {
            self.usage.not_udon_extern.insert(key.clone());
            self.warn(span, format!("`{}` is not a known Udon extern and is not mapped; emitted as dynamic access", key));
        } else {
            self.warn(span, format!("`{}` is not mapped by the catalog; emitted as dynamic access (TODO)", key));
        }
    }

    fn member_is_extern(&self, ty: &str, member: &str) -> bool {
        let Some(t) = self.prog.catalog.get(ty) else { return true };
        let chain = self.prog.catalog.chain(&t.name);
        for c in chain {
            if let Some(ext) = &c.extern_name {
                if self.prog.externs.has_member(ext, member)
                    || self.prog.externs.has_member(ext, &format!("get_{}", member))
                    || self.prog.externs.has_member(ext, &format!("set_{}", member))
                {
                    return true;
                }
            }
        }
        false
    }

    fn record_mapped(&mut self, m: &MemberInfo) {
        let key = format!("{}.{}", m.owner, m.name);
        *self.usage.mapped.entry(key.clone()).or_default() += 1;
        if m.stored {
            *self.usage.stored.entry(key).or_default() += 1;
        } else if m.stub {
            *self.usage.stubbed.entry(key).or_default() += 1;
        }
    }

    /// Apply a catalog field getter template.
    pub(crate) fn apply_getter(&mut self, m: &MemberInfo, target: Option<&Lw>, span: Span) -> Lw {
        self.record_mapped(m);
        if let Some(msg) = &m.unsupported {
            *self.usage.unsupported.entry(format!("{}.{}", m.owner, m.name)).or_default() += 1;
            self.warn(span, format!("`{}.{}` is unsupported: {}", m.owner, m.name, msg));
            return Lw::new(GExpr::ident("U").method("unsupported", vec![GExpr::str(&format!("{}.{}", m.owner, m.name))]), m.ret.clone());
        }
        let te = target.map(|t| t.e.clone());
        let e = match &m.get {
            Some(t) => self.expand_template(t, te.as_ref(), &[], None, &[], &[], &m.name),
            None => match te {
                Some(t) => t.member(&m.name),
                None => GExpr::ident(&m.owner).member(&m.name),
            },
        };
        Lw::new(e, m.ret.clone())
    }

    /// Expand a template into an expression, hoisting pre-statements.
    pub(crate) fn expand_template(&mut self, template: &str, target: Option<&GExpr>, args: &[GExpr], value: Option<&GExpr>, params: &[GExpr], type_args: &[String], member: &str) -> GExpr {
        // Expressions the template uses more than once are hoisted into temps so side effects run
        // once and nested templates do not duplicate code exponentially. Skipped inside
        // short-circuit / conditional operands, where hoisting would evaluate them unconditionally.
        let mut target_h: Option<GExpr> = target.cloned();
        let mut args_h: Vec<GExpr> = args.to_vec();
        let mut value_h: Option<GExpr> = value.cloned();
        if self.hoist_ok {
            if let Some(t) = target_h.clone() {
                if !t.is_cheap() && crate::template::placeholder_count(template, "0") > 1 {
                    target_h = Some(self.hoist(t));
                }
            }
            for i in 0..args_h.len() {
                if !args_h[i].is_cheap() && crate::template::placeholder_count(template, &(i + 1).to_string()) > 1 {
                    let e = args_h[i].clone();
                    args_h[i] = self.hoist(e);
                }
            }
            if let Some(v) = value_h.clone() {
                if !v.is_cheap() && crate::template::placeholder_count(template, "v") > 1 {
                    value_h = Some(self.hoist(v));
                }
            }
        }
        let tmp = if template.contains("$tmp") { self.fresh_tmp() } else { String::new() };
        let ta = TemplateArgs { target: target_h.as_ref(), args: &args_h, value: value_h.as_ref(), params, type_args, member_name: member, tmp: &tmp };
        let ex = expand(template, &ta);
        for p in ex.pre {
            self.pre.push(GStmt::Raw(p));
        }
        GExpr::Raw(ex.expr)
    }

    /// Evaluate `e` once into a fresh temp and return the temp.
    pub(crate) fn hoist(&mut self, e: GExpr) -> GExpr {
        let tmp = self.fresh_tmp();
        self.pre.push(GStmt::VarDecl { name: tmp.clone(), ty: None, init: Some(e) });
        GExpr::ident(&tmp)
    }

    // ----- calls -----

    fn lower_call(&mut self, callee: &Expr, args: &[Arg], span: Span) -> Lw {
        // Split generic type args.
        let (callee, type_args): (&Expr, Vec<(String, Ty)>) = match callee {
            Expr::GenericName { name, args: targs, .. } => {
                let names: Vec<(String, Ty)> = targs
                    .iter()
                    .map(|t| {
                        let ty = self.prog.resolve_type_ref(t);
                        (self.prog.runtime_type_name(&ty), ty)
                    })
                    .collect();
                (name.as_ref(), names)
            }
            other => (other, vec![]),
        };
        match callee.unparen() {
            Expr::Ident(name, _) => {
                // user method on self
                let methods = self.prog.find_methods(&self.class.name, name);
                if !methods.is_empty() {
                    let m = self.pick_user_method(&methods, args);
                    return self.call_user_method(m, None, args, span);
                }
                // catalog base method (SendCustomEvent etc.)
                if let Some(base) = self.prog.catalog_base_of_class(&self.class.name) {
                    let base_name = base.name.clone();
                    let cands = self.prog.catalog.members(&base_name, name);
                    if !cands.is_empty() {
                        let target = Lw::new(GExpr::ident("self"), Ty::Named(self.class.name.clone()));
                        return self.call_catalog(&base_name, name, Some(target), args, &type_args, span);
                    }
                }
                // local delegate / unknown
                self.warn(span, format!("unresolved method `{}`", name));
                self.usage.unresolved.insert(format!("{}()", name));
                let a = self.lower_args_plain(args);
                Lw::unknown(GExpr::ident(&crate::names::mangle(name)).call(a))
            }
            Expr::Member { target, name, null_cond, .. } => {
                if let Expr::Base(_) = target.unparen() {
                    let a = self.lower_args_plain(args);
                    let ret = self.prog.find_methods(&self.class.name, name).first().map(|m| m.ret.clone()).unwrap_or(Ty::Unknown);
                    return Lw::new(GExpr::ident("super").method(&crate::names::mangle(name), a), ret);
                }
                // static call on a type
                if let Some(tn) = self.resolve_dotted_type(target) {
                    return self.static_call(&tn, name, args, &type_args, span);
                }
                let t = self.lower_expr(target);
                if *null_cond {
                    let tmp = self.fresh_tmp();
                    self.pre.push(GStmt::VarDecl { name: tmp.clone(), ty: None, init: Some(t.e.clone()) });
                    let base = Lw::new(GExpr::ident(&tmp), t.ty.clone());
                    let inner = self.instance_call(base, name, args, &type_args, span);
                    let ty = inner.ty.clone();
                    return Lw::new(GExpr::Ternary { cond: Box::new(GExpr::ident(&tmp).bin("!=", GExpr::Null)), then: Box::new(inner.e), els: Box::new(GExpr::Null) }, ty);
                }
                self.instance_call(t, name, args, &type_args, span)
            }
            other => {
                // calling a delegate value / unsupported
                let c = self.lower_expr(other);
                let a = self.lower_args_plain(args);
                self.warn(span, "call through a non-method expression");
                Lw::unknown(c.e.method("call", a))
            }
        }
    }

    fn static_call(&mut self, tn: &str, name: &str, args: &[Arg], type_args: &[(String, Ty)], span: Span) -> Lw {
        if self.prog.is_user_class(tn) {
            let methods = self.prog.find_methods(tn, name);
            if !methods.is_empty() {
                let m = self.pick_user_method(&methods, args);
                if tn == self.class.name || self.prog.class_chain(&self.class.name).iter().any(|c| c.name == tn) {
                    return self.call_user_method(m, None, args, span);
                }
                // cross-class static call
                let a = self.lower_args_plain(args);
                let ret = m.ret.clone();
                if self.opts.class_name {
                    return Lw::new(GExpr::ident(tn).method(&m.gd_name, a), ret);
                }
                self.warn(span, format!("cross-class static call `{}.{}` routed through Udon.call_static (enable --class-name for a direct call)", tn, name));
                return Lw::new(GExpr::ident("Udon").method("call_static", vec![GExpr::str(tn), GExpr::str(&m.gd_name), GExpr::Array(a)]), ret);
            }
            self.warn(span, format!("unknown static method `{}.{}`", tn, name));
            let a = self.lower_args_plain(args);
            return Lw::unknown(GExpr::ident(tn).method(name, a));
        }
        if self.prog.catalog.get(tn).is_some() {
            let canon = self.prog.catalog.resolve_name(tn).unwrap().to_string();
            return self.call_catalog(&canon, name, None, args, type_args, span);
        }
        self.warn(span, format!("static call on unknown type `{}.{}`", tn, name));
        let a = self.lower_args_plain(args);
        Lw::unknown(GExpr::ident(tn).method(name, a))
    }

    fn instance_call(&mut self, t: Lw, name: &str, args: &[Arg], type_args: &[(String, Ty)], span: Span) -> Lw {
        match t.ty.clone() {
            Ty::TypeName(tn) => self.static_call(&tn, name, args, type_args, span),
            Ty::Named(n) if self.prog.is_user_class(&n) => {
                let methods = self.prog.find_methods(&n, name);
                if !methods.is_empty() {
                    let m = self.pick_user_method(&methods, args);
                    return self.call_user_method(m, Some(t), args, span);
                }
                if let Some(base) = self.prog.catalog_base_of_class(&n) {
                    let base_name = base.name.clone();
                    if !self.prog.catalog.members(&base_name, name).is_empty() {
                        return self.call_catalog(&base_name, name, Some(t), args, type_args, span);
                    }
                }
                self.warn(span, format!("unknown method `{}` on `{}`; emitted as dynamic call", name, n));
                let a = self.lower_args_plain(args);
                Lw::unknown(t.e.method(&crate::names::mangle(name), a))
            }
            Ty::Named(n) => {
                // Enum.HasFlag on user and catalog enums: (x & f) == f
                let is_enum = self.prog.catalog.get(&n).map_or(true, |ti| ti.kind == crate::api::TypeKind::Enum);
                if name == "HasFlag" && args.len() == 1 && is_enum {
                    let f = self.lower_expr(&args[0].expr);
                    let f = self.enum_as_int(f);
                    let fe = if f.e.is_cheap() { f.e } else { self.hoist(f.e) };
                    let te = self.enum_as_int(t).e;
                    return Lw::new(te.bin("&", fe.clone()).bin("==", fe), Ty::Bool);
                }
                if self.prog.catalog.get(&n).is_some() {
                    let canon = self.prog.catalog.resolve_name(&n).unwrap().to_string();
                    return self.call_catalog(&canon, name, Some(t), args, type_args, span);
                }
                self.warn(span, format!("method `{}` on unknown type `{}`; emitted as dynamic call", name, n));
                let a = self.lower_args_plain(args);
                Lw::unknown(t.e.method(name, a))
            }
            Ty::String => self.call_catalog("string", name, Some(t), args, type_args, span),
            Ty::Char => self.call_catalog("char", name, Some(t), args, type_args, span),
            Ty::Array(_) | Ty::MultiArray(..) => self.call_catalog("Array", name, Some(t), args, type_args, span),
            ty if ty.is_numeric() || ty.is_bool() => {
                let tn = ty.name();
                self.call_catalog(&tn, name, Some(t), args, type_args, span)
            }
            Ty::Object | Ty::Unknown | Ty::Null => {
                // dynamic call; well-known Udon behaviour methods keep their names
                let a = self.lower_args_plain(args);
                match name {
                    "ToString" => Lw::new(GExpr::ident("str").call(vec![t.e]), Ty::String),
                    "GetType" => Lw::new(GExpr::ident("U").method("type_of", vec![t.e]), Ty::Named("Type".into())),
                    "Equals" => Lw::new(t.e.bin("==", a.into_iter().next().unwrap_or(GExpr::Null)), Ty::Bool),
                    "GetHashCode" => Lw::new(GExpr::ident("hash").call(vec![t.e]), Ty::Int),
                    _ => {
                        if self.prog.catalog.members("UdonSharpBehaviour", name).iter().any(|m| m.is_method()) {
                            let target = Lw::new(t.e.clone(), Ty::Named("UdonSharpBehaviour".into()));
                            return self.call_catalog("UdonSharpBehaviour", name, Some(target), args, type_args, span);
                        }
                        Lw::unknown(t.e.method(&crate::names::mangle(name), a))
                    }
                }
            }
            _ => {
                let a = self.lower_args_plain(args);
                Lw::unknown(t.e.method(name, a))
            }
        }
    }

    fn lower_args_plain(&mut self, args: &[Arg]) -> Vec<GExpr> {
        args.iter().map(|a| self.lower_expr(&a.expr).e).collect()
    }

    fn pick_user_method<'a>(&mut self, methods: &[&'a crate::program::MethodInfo], args: &[Arg]) -> &'a crate::program::MethodInfo {
        if methods.len() == 1 {
            return methods[0];
        }
        // choose by arity, then by type score
        let arg_tys: Vec<Ty> = args.iter().map(|a| self.peek_type(&a.expr)).collect();
        let mut best: Option<(&crate::program::MethodInfo, u32)> = None;
        for m in methods {
            let params: Vec<crate::api::ParamInfo> = m
                .params
                .iter()
                .map(|p| crate::api::ParamInfo {
                    ty: p.ty.clone(),
                    mode: match p.mode {
                        ParamMode::Out => PMode::Out,
                        ParamMode::Ref => PMode::Ref,
                        ParamMode::Params => PMode::Params,
                        ParamMode::Value => PMode::Value,
                    },
                })
                .collect();
            let min_args = m.params.iter().filter(|p| p.default.is_none() && p.mode != ParamMode::Params).count();
            if args.len() < min_args {
                continue;
            }
            let padded: Vec<Ty> = if args.len() < params.len() && !m.params.iter().any(|p| p.mode == ParamMode::Params) {
                let mut v = arg_tys.clone();
                v.extend(params[args.len()..].iter().map(|p| p.ty.clone()));
                v
            } else {
                arg_tys.clone()
            };
            if let Some(s) = crate::api::score_params(&params, &padded) {
                if best.map_or(true, |(_, bs)| s < bs) {
                    best = Some((m, s));
                }
            }
        }
        best.map(|(m, _)| m).unwrap_or(methods[0])
    }

    /// Type of an expression without emitting code (best effort; may lower into a scratch buffer).
    pub(crate) fn peek_type(&mut self, e: &Expr) -> Ty {
        let saved_pre = std::mem::take(&mut self.pre);
        let saved_diags = self.diags.items.len();
        let saved_tmp = self.tmp_counter;
        let saved_enums = self.used_enums.clone();
        let saved_usage = self.usage.clone();
        let lw = self.lower_expr(e);
        self.pre = saved_pre;
        self.diags.items.truncate(saved_diags);
        self.tmp_counter = saved_tmp;
        self.used_enums = saved_enums;
        self.usage = saved_usage;
        lw.ty
    }

    fn call_user_method(&mut self, m: &crate::program::MethodInfo, target: Option<Lw>, args: &[Arg], span: Span) -> Lw {
        let mut gargs = Vec::new();
        let mut byref_targets: Vec<(Expr, Option<(TypeRef, String)>)> = Vec::new();
        let has_params = m.params.last().map_or(false, |p| p.mode == ParamMode::Params);
        let fixed = if has_params { m.params.len() - 1 } else { m.params.len() };
        let mut params_items = Vec::new();
        for (i, a) in args.iter().enumerate() {
            let pty = m.params.get(i.min(fixed.saturating_sub(0))).map(|p| p.ty.clone());
            if i < fixed {
                let p = &m.params[i];
                if matches!(p.mode, ParamMode::Out | ParamMode::Ref) {
                    // declare `out var x`
                    if let Some((t, n)) = &a.out_decl {
                        let ty = if t.is_var() { p.ty.clone() } else { self.prog.resolve_type_ref(t) };
                        let gd = self.declare_local(n, ty.clone());
                        let hint = self.gd_type(&ty);
                        self.pre.push(GStmt::VarDecl { name: gd, ty: hint, init: Some(self.prog.default_value(&ty)) });
                    }
                    let lw = self.lower_expr(&a.expr);
                    gargs.push(lw.e);
                    byref_targets.push((a.expr.clone(), a.out_decl.clone()));
                    continue;
                }
                let lw = self.lower_expr(&a.expr);
                let lw = match pty {
                    Some(t) => self.coerce(lw, &t),
                    None => lw,
                };
                gargs.push(lw.e);
            } else {
                let lw = self.lower_expr(&a.expr);
                params_items.push(lw.e);
            }
        }
        if has_params {
            // a single array argument passes through
            if params_items.len() == 1 && matches!(self.peek_type(&args[fixed].expr), Ty::Array(_)) {
                gargs.push(params_items.pop().unwrap());
            } else {
                gargs.push(GExpr::Array(params_items));
            }
        }
        let call = match target {
            Some(t) => t.e.method(&m.gd_name, gargs),
            None => GExpr::ident(&m.gd_name).call(gargs),
        };
        if m.has_byref() {
            // var _t = call(); x = _t[1]; ... ; value = _t[0]
            let tmp = self.fresh_tmp();
            self.pre.push(GStmt::VarDecl { name: tmp.clone(), ty: None, init: Some(call) });
            for (i, (target_expr, _)) in byref_targets.iter().enumerate() {
                let lhs = self.lower_expr(target_expr);
                let stmts = self.assign_to(lhs, &target_expr.clone(), GExpr::ident(&tmp).index(GExpr::Int(i as i64 + 1)), span);
                self.pre.extend(stmts);
            }
            if m.ret.is_void() {
                return Lw::new(GExpr::raw("pass"), Ty::Void);
            }
            return Lw::new(GExpr::ident(&tmp).index(GExpr::Int(0)), m.ret.clone());
        }
        Lw::new(call, m.ret.clone())
    }

    /// Call a catalog method (`type_name` canonical), instance when `target` is Some.
    fn call_catalog(&mut self, type_name: &str, name: &str, target: Option<Lw>, args: &[Arg], type_args: &[(String, Ty)], span: Span) -> Lw {
        let mut cands: Vec<MemberInfo> = self.prog.catalog.members(type_name, name).into_iter().filter(|m| m.is_method() && (target.is_some() || m.is_static)).cloned().collect();
        // With a target, instance members win over static ones of the same name
        // (`behaviour.GetUdonTypeName()` vs `UdonSharpBehaviour.GetUdonTypeName<T>()`).
        if target.is_some() && cands.iter().any(|m| !m.is_static) {
            cands.retain(|m| !m.is_static);
        }
        if cands.is_empty() {
            // maybe a field holding a Signal/Callable being invoked, or unmapped
            if self.prog.catalog.get(type_name).is_some() {
                self.record_unmapped(type_name, name, span);
            }
            let a = self.lower_args_plain(args);
            return match target {
                Some(t) => Lw::unknown(t.e.method(name, a)),
                None => Lw::unknown(GExpr::ident(type_name).method(name, a)),
            };
        }
        // Lower args (types needed for overload resolution).
        let mut lowered: Vec<Lw> = Vec::new();
        for a in args {
            if let Some((_, n)) = &a.out_decl {
                // `out var x`: the type comes from the chosen overload; declared after resolution.
                lowered.push(Lw::new(GExpr::ident(&crate::names::mangle_local(n)), Ty::Unknown));
                continue;
            }
            lowered.push(self.lower_expr(&a.expr));
        }
        let arg_tys: Vec<Ty> = lowered.iter().map(|l| l.ty.clone()).collect();
        let cand_refs: Vec<&MemberInfo> = cands.iter().collect();
        let m = match self.prog.catalog.resolve_method(&cand_refs, &arg_tys) {
            Some(m) => m.clone(),
            None => {
                // fall back to arity match, then first
                let by_arity: Vec<&MemberInfo> = cands.iter().filter(|m| m.params.len() == args.len() || m.has_params_array()).collect();
                match by_arity.first() {
                    Some(m) => (*m).clone(),
                    None => {
                        self.warn(span, format!("no overload of `{}.{}` takes {} argument(s); using the first", type_name, name, args.len()));
                        cands[0].clone()
                    }
                }
            }
        };
        // Declare `out var x` locals now that the parameter types are known.
        for (i, a) in args.iter().enumerate() {
            if let Some((t, n)) = &a.out_decl {
                let pty = m.params.get(i).map(|p| p.ty.clone()).unwrap_or(Ty::Unknown);
                let ty = if t.is_var() { pty } else { self.prog.resolve_type_ref(t) };
                let gd = self.declare_local(n, ty.clone());
                let hint = self.gd_type(&ty);
                let dv = self.prog.default_value(&ty);
                self.pre.push(GStmt::VarDecl { name: gd.clone(), ty: hint, init: Some(dv) });
                lowered[i] = Lw::new(GExpr::ident(&gd), ty);
            }
        }
        self.record_mapped(&m);
        if let Some(msg) = &m.unsupported {
            *self.usage.unsupported.entry(format!("{}.{}", m.owner, m.name)).or_default() += 1;
            self.warn(span, format!("`{}.{}` is unsupported: {}", m.owner, m.name, msg));
            return Lw::new(GExpr::ident("U").method("unsupported", vec![GExpr::str(&format!("{}.{}", m.owner, m.name))]), m.ret.clone());
        }
        // Coerce args to parameter types and split params-array.
        let has_params = m.has_params_array();
        let fixed = if has_params { m.params.len() - 1 } else { m.params.len() };
        let mut gargs: Vec<GExpr> = Vec::new();
        let mut params_items: Vec<GExpr> = Vec::new();
        for (i, lw) in lowered.into_iter().enumerate() {
            if i < fixed {
                let pty = m.params[i].ty.clone();
                let lw = if matches!(m.params[i].mode, PMode::Out | PMode::Ref) { lw } else { self.coerce(lw, &pty) };
                gargs.push(lw.e);
            } else if has_params && i == fixed && args.len() == m.params.len() && matches!(arg_tys[i], Ty::Array(_)) {
                // a single array passed to params: use it directly
                let elem = match &m.params[fixed].ty {
                    Ty::Array(e) => (**e).clone(),
                    t => t.clone(),
                };
                let _ = elem;
                params_items.push(GExpr::Raw(format!("__spread__{}", lw.e.render())));
            } else {
                params_items.push(lw.e);
            }
        }
        // `$params` renders as an Array literal; a spread array replaces it wholesale.
        let spread = params_items.iter().find_map(|p| match p {
            GExpr::Raw(s) if s.starts_with("__spread__") => Some(s["__spread__".len()..].to_string()),
            _ => None,
        });
        let te = target.as_ref().map(|t| t.e.clone());
        let template = match &m.get {
            Some(t) => t.clone(),
            None => {
                // default: `$0.Name($args)` / `Type.Name($args)`
                let mut s = String::new();
                if target.is_some() {
                    s.push_str("$0.");
                } else {
                    s.push_str(&m.owner);
                    s.push('.');
                }
                s.push_str(&m.name);
                s.push_str("($args)");
                s
            }
        };
        let template = match &spread {
            Some(arr) => template.replace("$params", arr),
            None => template,
        };
        let type_arg_names: Vec<String> = type_args.iter().map(|(n, _)| n.clone()).collect();
        let e = self.expand_template(&template, te.as_ref(), &gargs, None, &params_items, &type_arg_names, &m.name);
        // Generic return `T` resolves to the (C#) type argument.
        let ret = match &m.ret {
            Ty::Named(n) if n == "T" => type_args.first().map(|(_, t)| t.clone()).unwrap_or(Ty::Unknown),
            Ty::Array(inner) if inner.is_named("T") => Ty::Array(Box::new(type_args.first().map(|(_, t)| t.clone()).unwrap_or(Ty::Unknown))),
            other => other.clone(),
        };
        // `GetComponent(typeof(X))` → return type from the typeof argument
        let ret = if matches!(ret, Ty::Named(ref n) if n == "Component") && !args.is_empty() {
            if let Expr::Typeof(t, _) = args[0].expr.unparen() {
                self.prog.resolve_type_ref(t)
            } else {
                ret
            }
        } else {
            ret
        };
        Lw::new(e, ret)
    }

    // ----- indexing -----

    fn lower_index(&mut self, target: &Expr, indices: &[Expr], null_cond: bool, span: Span) -> Lw {
        let t = self.lower_expr(target);
        let idx: Vec<Lw> = indices.iter().map(|i| self.lower_expr(i)).collect();
        let _ = null_cond;
        match t.ty.clone() {
            Ty::Array(e) => {
                let mut ex = t.e;
                for i in idx {
                    let i = self.coerce(i, &Ty::Int);
                    ex = ex.index(i.e);
                }
                Lw::new(ex, (*e).clone())
            }
            Ty::MultiArray(e, _) => {
                let mut ex = t.e;
                for i in idx {
                    let i = self.coerce(i, &Ty::Int);
                    ex = ex.index(i.e);
                }
                Lw::new(ex, (*e).clone())
            }
            Ty::String => {
                let i = self.coerce(idx.into_iter().next().unwrap_or(Lw::new(GExpr::Int(0), Ty::Int)), &Ty::Int);
                Lw::new(t.e.index(i.e), Ty::Char)
            }
            Ty::Named(n) => {
                // catalog indexer `this[...]` (`this[int, int]` for two-dimensional indexers)
                let key = if idx.len() == 2 { "this[int, int]" } else { "this[int]" };
                let members = self.prog.catalog.members(&n, key);
                let members: Vec<MemberInfo> = members.into_iter().cloned().collect();
                let m = members.first().cloned().or_else(|| self.prog.catalog.members(&n, "this[DataToken]").first().map(|m| (*m).clone()));
                if let Some(m) = m {
                    self.record_mapped(&m);
                    let args: Vec<GExpr> = idx.into_iter().map(|i| i.e).collect();
                    let tmpl = m.get.clone().unwrap_or_else(|| "$0[$1]".into());
                    let e = self.expand_template(&tmpl, Some(&t.e), &args, None, &[], &[], &m.name);
                    return Lw::new(e, m.ret.clone());
                }
                if self.prog.catalog.get(&n).is_none() && !self.prog.is_user_class(&n) {
                    self.warn(span, format!("indexing unknown type `{}`", n));
                }
                let mut ex = t.e;
                for i in idx {
                    ex = ex.index(i.e);
                }
                Lw::unknown(ex)
            }
            _ => {
                let mut ex = t.e;
                for i in idx {
                    ex = ex.index(i.e);
                }
                Lw::unknown(ex)
            }
        }
    }

    // ----- unary / binary -----

    fn lower_unary(&mut self, op: UnOp, expr: &Expr, span: Span) -> Lw {
        match op {
            UnOp::Neg => {
                let v = self.lower_expr(expr);
                let ty = v.ty.promote();
                if let Ty::Named(n) = &v.ty {
                    if let Some(m) = self.prog.catalog.operators(n, "-").into_iter().find(|m| m.params.len() == 1).cloned() {
                        let e = self.expand_template(m.get.as_deref().unwrap_or("-$1"), None, &[v.e], None, &[], &[], "-");
                        return Lw::new(e, m.ret.clone());
                    }
                }
                Lw::new(v.e.neg(), ty)
            }
            UnOp::Plus => self.lower_expr(expr),
            UnOp::Not => {
                let c = self.lower_cond(expr);
                Lw::new(c.not(), Ty::Bool)
            }
            UnOp::BitNot => {
                let v = self.lower_expr(expr);
                let ty = v.ty.promote();
                Lw::new(GExpr::Unary("~", Box::new(v.e)), ty)
            }
            UnOp::PreInc | UnOp::PreDec => {
                let bop = if op == UnOp::PreInc { BinOp::Add } else { BinOp::Sub };
                let stmts = self.lower_assign_stmt(Some(bop), expr, &Expr::Lit(Lit::Int(1), span));
                self.pre.extend(stmts);
                self.lower_expr(expr)
            }
            UnOp::PostInc | UnOp::PostDec => {
                // var _t = x; x += 1; value _t
                let before = self.lower_expr(expr);
                let tmp = self.fresh_tmp();
                self.pre.push(GStmt::VarDecl { name: tmp.clone(), ty: None, init: Some(before.e) });
                let bop = if op == UnOp::PostInc { BinOp::Add } else { BinOp::Sub };
                let stmts = self.lower_assign_stmt(Some(bop), expr, &Expr::Lit(Lit::Int(1), span));
                self.pre.extend(stmts);
                Lw::new(GExpr::ident(&tmp), before.ty)
            }
        }
    }

    fn lower_binary(&mut self, op: BinOp, lhs: &Expr, rhs: &Expr, span: Span) -> Lw {
        match op {
            BinOp::And | BinOp::Or => {
                let a = self.lower_cond(lhs);
                let pre_len = self.pre.len();
                let saved = self.hoist_ok;
                self.hoist_ok = false;
                let b = self.lower_cond(rhs);
                self.hoist_ok = saved;
                if self.pre.len() > pre_len {
                    self.warn(span, "right operand of a short-circuit operator needed hoisted statements; it is now evaluated unconditionally");
                }
                let gop = if op == BinOp::And { "and" } else { "or" };
                return Lw::new(a.bin(gop, b), Ty::Bool);
            }
            BinOp::Coalesce => {
                let a = self.lower_expr(lhs);
                let saved = self.hoist_ok;
                self.hoist_ok = false;
                let b = self.lower_expr(rhs);
                self.hoist_ok = saved;
                let ty = if matches!(a.ty, Ty::Null | Ty::Unknown) { b.ty.clone() } else { a.ty.clone() };
                // strings: "" stands for null in the generated code (see binary_lowered)
                let is_str = a.ty == Ty::String || (ty == Ty::String && a.ty == Ty::Null);
                let cond = |e: GExpr| if is_str { e.clone().bin("!=", GExpr::Null).bin("and", e.bin("!=", GExpr::str(""))) } else { e.bin("!=", GExpr::Null) };
                if a.e.is_atomic() {
                    return Lw::new(GExpr::Ternary { cond: Box::new(cond(a.e.clone())), then: Box::new(a.e), els: Box::new(b.e) }, ty);
                }
                let tmp = self.fresh_tmp();
                self.pre.push(GStmt::VarDecl { name: tmp.clone(), ty: None, init: Some(a.e) });
                return Lw::new(GExpr::Ternary { cond: Box::new(cond(GExpr::ident(&tmp))), then: Box::new(GExpr::ident(&tmp)), els: Box::new(b.e) }, ty);
            }
            _ => {}
        }
        let a = self.lower_expr(lhs);
        let b = self.lower_expr(rhs);
        self.binary_lowered(op, a, b, span)
    }

    pub(crate) fn binary_lowered(&mut self, op: BinOp, a: Lw, b: Lw, span: Span) -> Lw {
        // Null comparisons on Unity objects → validity checks.
        if matches!(op, BinOp::Eq | BinOp::Ne) {
            let a_null = matches!(a.ty, Ty::Null);
            let b_null = matches!(b.ty, Ty::Null);
            if a_null != b_null {
                let (obj, _) = if b_null { (a.clone(), b.clone()) } else { (b.clone(), a.clone()) };
                if self.prog.is_unity_object(&obj.ty) {
                    let valid = GExpr::ident("is_instance_valid").call(vec![obj.e]);
                    return Lw::new(if op == BinOp::Eq { valid.not() } else { valid }, Ty::Bool);
                }
                if obj.ty == Ty::String {
                    // string fields default to "" in the generated code while array elements are
                    // null: treat both as C# null
                    let e = obj.e.clone().bin("==", GExpr::Null).bin("or", obj.e.bin("==", GExpr::str("")));
                    return Lw::new(if op == BinOp::Eq { e } else { e.not() }, Ty::Bool);
                }
                // Only structs backed by a Godot value type are never null; Dictionary-backed ones
                // (Collision, RaycastHit, ...) are null when absent and keep the real comparison.
                let is_value = obj.ty.is_numeric() || obj.ty.is_bool() || obj.ty == Ty::Char || matches!(&obj.ty, Ty::Named(n) if self.prog.catalog.get(n).map_or(false, |t| t.kind == crate::api::TypeKind::Struct && crate::api::is_godot_value_type(&t.gd)));
                if is_value {
                    self.warn(span, format!("comparing value type `{}` with null is always {}", obj.ty.name(), op == BinOp::Ne));
                    return Lw::new(GExpr::Bool(op == BinOp::Ne), Ty::Bool);
                }
            }
        }
        // Catalog operator overloads for struct types.
        let sym = op.as_str();
        for (ty, other) in [(&a.ty, &b.ty), (&b.ty, &a.ty)] {
            if let Ty::Named(n) = ty {
                let ops: Vec<MemberInfo> = self.prog.catalog.operators(n, sym).into_iter().cloned().collect();
                for m in ops {
                    if m.params.len() != 2 {
                        continue;
                    }
                    let (p0, p1) = (&m.params[0].ty, &m.params[1].ty);
                    let cost = crate::api::conversion_cost(&a.ty, p0).and_then(|c0| crate::api::conversion_cost(&b.ty, p1).map(|c1| c0 + c1));
                    if let Some(c) = cost {
                        if c <= 6 {
                            let _ = other;
                            self.record_mapped(&m);
                            let ac = self.coerce(a.clone(), p0).e;
                            let bc = self.coerce(b.clone(), p1).e;
                            let e = self.expand_template(m.get.as_deref().unwrap_or("$1 + $2"), None, &[ac, bc], None, &[], &[], sym);
                            return Lw::new(e, m.ret.clone());
                        }
                    }
                }
            }
        }
        // String concatenation.
        if op == BinOp::Add && (a.ty.is_string() || b.ty.is_string() || a.ty == Ty::Char && b.ty == Ty::Char) {
            let ae = self.stringify(a);
            let be = self.stringify(b);
            return Lw::new(ae.bin("+", be), Ty::String);
        }
        // char arithmetic works on code points (`'z' - 'a'`).
        if a.ty == Ty::Char && b.ty == Ty::Char && matches!(op, BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem | BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr) {
            let a = Lw::new(a.e.method("unicode_at", vec![GExpr::Int(0)]), Ty::Int);
            let b = Lw::new(b.e.method("unicode_at", vec![GExpr::Int(0)]), Ty::Int);
            return self.binary_lowered(op, a, b, span);
        }
        // Enum ↔ int comparisons and arithmetic just work on ints.
        let a = self.enum_as_int(a);
        let b = self.enum_as_int(b);
        let a = self.char_as_int_if_needed(a, &b.ty);
        let b = self.char_as_int_if_needed(b, &a.ty);
        let result_ty = if op.is_comparison() {
            Ty::Bool
        } else if op.is_arith() || op.is_bitwise() {
            if a.ty.is_bool() && b.ty.is_bool() {
                Ty::Bool
            } else if a.ty.is_numeric() && b.ty.is_numeric() {
                if matches!(op, BinOp::Shl | BinOp::Shr) { a.ty.promote() } else { Ty::binary_numeric(&a.ty, &b.ty) }
            } else if a.ty.is_numeric() && b.ty.is_unknown() {
                a.ty.clone()
            } else if b.ty.is_numeric() && a.ty.is_unknown() {
                b.ty.clone()
            } else {
                a.ty.clone()
            }
        } else {
            Ty::Unknown
        };
        let gop: &'static str = match op {
            BinOp::Add => "+",
            BinOp::Sub => "-",
            BinOp::Mul => "*",
            BinOp::Div => "/",
            BinOp::Rem => "%",
            BinOp::BitAnd => {
                if a.ty.is_bool() && b.ty.is_bool() {
                    "and"
                } else {
                    "&"
                }
            }
            BinOp::BitOr => {
                if a.ty.is_bool() && b.ty.is_bool() {
                    "or"
                } else {
                    "|"
                }
            }
            BinOp::BitXor => {
                if a.ty.is_bool() && b.ty.is_bool() {
                    "!="
                } else {
                    "^"
                }
            }
            BinOp::Shl => "<<",
            BinOp::Shr => ">>",
            BinOp::Eq => "==",
            BinOp::Ne => "!=",
            BinOp::Lt => "<",
            BinOp::Le => "<=",
            BinOp::Gt => ">",
            BinOp::Ge => ">=",
            _ => "+",
        };
        // Float remainder needs fmod().
        if op == BinOp::Rem && (a.ty.is_real() || b.ty.is_real()) {
            return Lw::new(GExpr::ident("fmod").call(vec![a.e, b.e]), result_ty);
        }
        // C# integer division truncates; GDScript `/` on two ints also truncates. When one side is
        // a float in C# the result is float in both. Nothing to do.
        // Unsigned right shift on uint: emulate logical shift.
        if op == BinOp::Shr && matches!(a.ty, Ty::UInt) {
            return Lw::new(GExpr::Paren(Box::new(a.e.bin("&", GExpr::Int(0xFFFF_FFFF)))).bin(">>", b.e), Ty::UInt);
        }
        let _ = span;
        Lw::new(a.e.bin(gop, b.e), result_ty)
    }

    fn enum_as_int(&self, lw: Lw) -> Lw {
        if let Ty::Named(n) = &lw.ty {
            let is_enum = self.prog.user_enum(n).is_some() || self.prog.catalog.get(n).map_or(false, |t| t.is_enum());
            if is_enum {
                return Lw::new(lw.e, Ty::Int);
            }
        }
        lw
    }

    fn char_as_int_if_needed(&mut self, lw: Lw, other: &Ty) -> Lw {
        if lw.ty == Ty::Char && other.is_numeric() && *other != Ty::Char {
            return Lw::new(lw.e.method("unicode_at", vec![GExpr::Int(0)]), Ty::Int);
        }
        lw
    }

    // ----- casts -----

    fn lower_cast(&mut self, ty: &TypeRef, expr: &Expr, span: Span) -> Lw {
        let target = self.prog.resolve_type_ref(ty);
        let v = self.lower_expr(expr);
        if v.ty == target {
            return Lw::new(v.e, target);
        }
        // enum → int / int → enum
        let target_is_enum = matches!(&target, Ty::Named(n) if self.prog.user_enum(n).is_some() || self.prog.catalog.get(n).map_or(false, |t| t.is_enum()));
        let src_is_enum = matches!(&v.ty, Ty::Named(n) if self.prog.user_enum(n).is_some() || self.prog.catalog.get(n).map_or(false, |t| t.is_enum()));
        if target_is_enum && (v.ty.is_integral() || v.ty.is_unknown() || v.ty == Ty::Object) {
            return Lw::new(v.e, target);
        }
        if src_is_enum && target.is_integral() {
            return Lw::new(v.e, target);
        }
        if src_is_enum && target.is_real() {
            return Lw::new(GExpr::ident("float").call(vec![v.e]), target);
        }
        // catalog cast entries (numeric conversions, struct conversions)
        let src_name = v.ty.name();
        if let Some(c) = self.prog.catalog.cast(&src_name, &target).cloned() {
            self.record_mapped(&c);
            let e = self.expand_template(c.get.as_deref().unwrap_or("$0"), Some(&v.e), &[], None, &[], &[], &c.name);
            return Lw::new(e, target);
        }
        // numeric conversions from unknown/object
        match &target {
            Ty::Int | Ty::UInt | Ty::Long | Ty::ULong | Ty::Short | Ty::UShort | Ty::Byte | Ty::SByte => {
                if v.ty.is_integral() {
                    return Lw::new(v.e, target);
                }
                if v.ty.is_real() {
                    return Lw::new(GExpr::ident("U").method("f2i", vec![v.e]), target);
                }
                return Lw::new(GExpr::ident("int").call(vec![v.e]), target);
            }
            Ty::Float | Ty::Double | Ty::Decimal => {
                if v.ty.is_real() {
                    return Lw::new(v.e, target);
                }
                return Lw::new(GExpr::ident("float").call(vec![v.e]), target);
            }
            Ty::Bool => return Lw::new(GExpr::ident("bool").call(vec![v.e]), target),
            Ty::String => return Lw::new(if v.ty.is_string() || v.ty == Ty::Char { v.e } else { GExpr::ident("str").call(vec![v.e]) }, target),
            Ty::Char => return Lw::new(GExpr::ident("char").call(vec![v.e]), target),
            _ => {}
        }
        // reference casts: identity (objects are dynamically typed in GDScript)
        let _ = span;
        Lw::new(v.e, target)
    }

    // ----- object creation -----

    fn lower_new(&mut self, ty: &TypeRef, args: &[Arg], init: Option<&[Expr]>, span: Span) -> Lw {
        let t = self.prog.resolve_type_ref(ty);
        let tn = t.name();
        if self.prog.is_user_class(&tn) {
            self.error(span, format!("`new {}()`: Udon behaviours cannot be constructed; use Instantiate", tn));
            return Lw::new(GExpr::Null, t);
        }
        if init.is_some() {
            self.warn(span, "object initializer `{ ... }` is not supported; ignored");
        }
        let ctors: Vec<MemberInfo> = self.prog.catalog.ctors(&tn).into_iter().cloned().collect();
        if ctors.is_empty() {
            if self.prog.catalog.get(&tn).is_some() {
                self.record_unmapped(&tn, "ctor", span);
            } else {
                self.warn(span, format!("constructing unknown type `{}`", tn));
            }
            let a = self.lower_args_plain(args);
            return Lw::new(GExpr::ident(&tn).method("new", a), t);
        }
        let lowered: Vec<Lw> = args.iter().map(|a| self.lower_expr(&a.expr)).collect();
        let arg_tys: Vec<Ty> = lowered.iter().map(|l| l.ty.clone()).collect();
        let refs: Vec<&MemberInfo> = ctors.iter().collect();
        let m = match self.prog.catalog.resolve_method(&refs, &arg_tys) {
            Some(m) => m.clone(),
            None => {
                self.warn(span, format!("no constructor of `{}` takes {} argument(s); using the first", tn, args.len()));
                ctors.iter().find(|c| c.params.len() == args.len()).cloned().unwrap_or_else(|| ctors[0].clone())
            }
        };
        self.record_mapped(&m);
        // Coerce args and split a trailing `params T[]` (see call_catalog).
        let has_params = m.has_params_array();
        let fixed = if has_params { m.params.len() - 1 } else { m.params.len() };
        let mut gargs = Vec::new();
        let mut params_items: Vec<GExpr> = Vec::new();
        let mut spread: Option<String> = None;
        for (i, lw) in lowered.into_iter().enumerate() {
            if i < fixed {
                let lw = match m.params.get(i) {
                    Some(p) => self.coerce(lw, &p.ty),
                    None => lw,
                };
                gargs.push(lw.e);
            } else if has_params && i == fixed && arg_tys.len() == m.params.len() && matches!(arg_tys[i], Ty::Array(_)) {
                spread = Some(lw.e.render());
            } else {
                params_items.push(lw.e);
            }
        }
        let template = m.get.clone().unwrap_or_else(|| "null".to_string());
        let template = match &spread {
            Some(arr) => template.replace("$params", arr),
            None => template,
        };
        let e = self.expand_template(&template, None, &gargs, None, &params_items, &[], "ctor");
        Lw::new(e, t)
    }

    fn lower_new_array(&mut self, elem: &TypeRef, sizes: &[Option<Expr>], rank: u32, init: Option<&[Expr]>, span: Span) -> Lw {
        let elem_ty = if elem.is_var() { Ty::Unknown } else { self.prog.resolve_type_ref(elem) };
        if let Some(items) = init {
            let lowered: Vec<GExpr> = items
                .iter()
                .map(|i| match i {
                    Expr::ArrayInit(inner, _) => {
                        let v: Vec<GExpr> = inner.iter().map(|x| self.lower_expr(x).e).collect();
                        GExpr::Array(v)
                    }
                    other => {
                        let lw = self.lower_expr(other);
                        self.coerce(lw, &elem_ty).e
                    }
                })
                .collect();
            let ty = if rank > 1 { Ty::MultiArray(Box::new(elem_ty), rank) } else { Ty::Array(Box::new(elem_ty)) };
            return Lw::new(GExpr::Array(lowered), ty);
        }
        let default = self.prog.default_value(&elem_ty);
        let dims: Vec<GExpr> = sizes
            .iter()
            .map(|s| match s {
                Some(e) => {
                    let lw = self.lower_expr(e);
                    self.coerce(lw, &Ty::Int).e
                }
                None => GExpr::Int(0),
            })
            .collect();
        let _ = span;
        if rank > 1 {
            let ty = Ty::MultiArray(Box::new(elem_ty), rank);
            return Lw::new(GExpr::ident("U").method("new_array_nd", vec![GExpr::Array(dims), default]), ty);
        }
        let ty = Ty::Array(Box::new(elem_ty.clone()));
        let n = dims.into_iter().next().unwrap_or(GExpr::Int(0));
        // jagged inner arrays default to null
        let default = if elem_ty.is_array() { GExpr::Null } else { default };
        Lw::new(GExpr::ident("U").method("new_array", vec![n, default]), ty)
    }

    // ----- assignment -----

    /// Lower `lhs op= rhs` as statements.
    pub(crate) fn lower_assign_stmt(&mut self, op: Option<BinOp>, lhs: &Expr, rhs: &Expr) -> Vec<GStmt> {
        let mut out = Vec::new();
        let span = lhs.span();
        // `a[f(x)] op= v` evaluates the index once: hoist it into a temporary.
        if op.is_some() {
            if let Expr::Index { target: it, indices, null_cond: false, span: ispan } = lhs.unparen() {
                if indices.len() == 1 && !matches!(indices[0].unparen(), Expr::Ident(..) | Expr::Lit(..)) {
                    let idx = self.lower_expr(&indices[0]);
                    let tmp = self.fresh_tmp();
                    out.extend(self.take_pre());
                    out.push(GStmt::VarDecl { name: tmp.clone(), ty: None, init: Some(idx.e) });
                    let tmp_ty = idx.ty.clone();
                    self.push_scope();
                    if let Some(sc) = self.scopes.last_mut() {
                        sc.insert(tmp.clone(), Local { gd_name: tmp.clone(), ty: tmp_ty });
                    }
                    let rewritten = Expr::Index { target: it.clone(), indices: vec![Expr::Ident(tmp.clone(), *ispan)], null_cond: false, span: *ispan };
                    out.extend(self.lower_assign_stmt(op, &rewritten, rhs));
                    self.pop_scope();
                    return out;
                }
            }
        }
        let target = self.lower_expr(lhs);
        let value = self.lower_expr(rhs);
        let value = match op {
            None => self.coerce(value, &target.ty),
            Some(bop) => {
                // compound: compute `target op value` with proper typing
                let cur = target.clone();
                let combined = self.binary_lowered(bop, cur, value, span);
                // simple targets can use `+=` etc. when the result is a plain binary on the same target
                let ty = target.ty.clone();
                let combined = self.coerce(combined, &ty);
                if let GExpr::Binary(l, gop, r) = &combined.e {
                    if **l == target.e && matches!(*gop, "+" | "-" | "*" | "/" | "%" | "&" | "|" | "^" | "<<" | ">>") && is_plain_lvalue(&target.e) && is_compound_target(&target.e) {
                        let cop: &'static str = match *gop {
                            "+" => "+=",
                            "-" => "-=",
                            "*" => "*=",
                            "/" => "/=",
                            "%" => "%=",
                            "&" => "&=",
                            "|" => "|=",
                            "^" => "^=",
                            "<<" => "<<=",
                            ">>" => ">>=",
                            _ => "=",
                        };
                        out.extend(self.take_pre());
                        out.push(GStmt::Assign { target: target.e.clone(), op: cop, value: (**r).clone() });
                        return out;
                    }
                }
                combined
            }
        };
        out.extend(self.take_pre());
        out.extend(self.assign_to(target, lhs, value.e, span));
        out
    }

    /// Emit statements assigning `value` to the lowered lvalue `target` (from source `lhs`).
    pub(crate) fn assign_to(&mut self, target: Lw, lhs: &Expr, value: GExpr, span: Span) -> Vec<GStmt> {
        // User properties with accessor bodies: `X = v` → `set_X(v)`, `o.X = v` → `o.set_X(v)`.
        if let Some((obj, p)) = self.find_user_prop(lhs) {
            let mut out = self.take_pre();
            let call = match obj {
                Some(o) => o.method(&format!("set_{}", p), vec![value]),
                None => GExpr::ident(&format!("set_{}", p)).call(vec![value]),
            };
            out.push(GStmt::Expr(call));
            return out;
        }
        // Property setter templates: re-resolve the member to find a `set` template.
        if let Expr::Member { target: obj, name, .. } = lhs.unparen() {
            if let Some(setter) = self.find_setter(obj, name) {
                let (tmpl, obj_e) = setter;
                let e = self.expand_template(&tmpl, obj_e.as_ref(), &[], Some(&value), &[], &[], name);
                let mut out = self.take_pre();
                match e {
                    GExpr::Raw(s) => out.push(GStmt::Raw(s)),
                    other => out.push(GStmt::Expr(other)),
                }
                return out;
            }
        }
        // Struct member of a property (e.g. `transform.position.x = 1`) is a C# error; but
        // `localPos.x = 1` on a local is fine.
        match &target.e {
            GExpr::Raw(s) if !is_plain_lvalue(&target.e) => {
                self.warn(span, format!("assignment to a read-only or computed expression `{}` dropped (no setter mapping)", s));
                vec![GStmt::Comment(format!("TODO(udon2godot): dropped assignment to read-only `{}`", s))]
            }
            _ => vec![GStmt::Assign { target: target.e, op: "=", value }],
        }
    }

    /// Is `lhs` a user property with accessor bodies? Returns (lowered target object, gd name).
    fn find_user_prop(&mut self, lhs: &Expr) -> Option<(Option<GExpr>, String)> {
        match lhs.unparen() {
            Expr::Ident(name, _) => {
                if self.lookup_local(name).is_some() {
                    return None;
                }
                let (_, p) = self.prog.find_prop(&self.class.name, name)?;
                if p.decl.is_auto() {
                    return None;
                }
                Some((None, p.gd_name.clone()))
            }
            Expr::Member { target, name, .. } => {
                if let Expr::This(_) = target.unparen() {
                    let (_, p) = self.prog.find_prop(&self.class.name, name)?;
                    if p.decl.is_auto() {
                        return None;
                    }
                    return Some((None, p.gd_name.clone()));
                }
                if self.resolve_dotted_type(target).is_some() {
                    return None;
                }
                let t = self.peek_type(target);
                let Ty::Named(n) = t else { return None };
                if !self.prog.is_user_class(&n) {
                    return None;
                }
                let (_, p) = self.prog.find_prop(&n, name)?;
                if p.decl.is_auto() {
                    return None;
                }
                let gd = p.gd_name.clone();
                let o = self.lower_expr(target);
                Some((Some(o.e), gd))
            }
            _ => None,
        }
    }

    /// Find a catalog setter template for `obj.name`; returns (template, lowered object).
    fn find_setter(&mut self, obj: &Expr, name: &str) -> Option<(String, Option<GExpr>)> {
        if let Some(tn) = self.resolve_dotted_type(obj) {
            if let Some(m) = self.prog.catalog.field_for_write(&tn, name, true) {
                let m = m.clone();
                if let Some(s) = &m.set {
                    self.record_mapped(&m);
                    return Some((s.clone(), None));
                }
                if m.get.is_some() {
                    self.warn(obj.span(), format!("`{}.{}` is read-only in the catalog; assignment emitted verbatim", tn, name));
                }
            }
            return None;
        }
        let t = self.peek_type(obj);
        // `Physics.gravity = v`: a bare catalog type name denotes its statics
        if let Ty::TypeName(tn) = &t {
            let tn = tn.clone();
            if let Some(m) = self.prog.catalog.field_for_write(&tn, name, true) {
                let m = m.clone();
                if let Some(s) = &m.set {
                    self.record_mapped(&m);
                    return Some((s.clone(), None));
                }
                if m.get.is_some() {
                    self.warn(obj.span(), format!("`{}.{}` is read-only in the catalog; assignment emitted verbatim", tn, name));
                }
            }
            return None;
        }
        let tn = match &t {
            Ty::Named(n) => n.clone(),
            Ty::String => "string".into(),
            _ => return None,
        };
        let catalog_type = if self.prog.is_user_class(&tn) {
            // user fields are plain members; only catalog base members (enabled, name...) have setters
            if self.prog.find_field(&tn, name).is_some() || self.prog.find_prop(&tn, name).is_some() {
                return None;
            }
            self.prog.catalog_base_of_class(&tn).map(|b| b.name.clone())?
        } else {
            tn
        };
        let m = self.prog.catalog.field_for_write(&catalog_type, name, false)?.clone();
        if let Some(s) = &m.set {
            self.record_mapped(&m);
            let o = self.lower_expr(obj);
            return Some((s.clone(), Some(o.e)));
        }
        // getter template that is a plain member path can be assigned directly
        if let Some(g) = &m.get {
            if is_assignable_template(g) {
                let o = self.lower_expr(obj);
                return Some((format!("{} = $v", g), Some(o.e)));
            }
            self.warn(obj.span(), format!("`{}.{}` has no setter mapping; assignment emitted verbatim", catalog_type, name));
        }
        None
    }
}

/// SafeGDScript accepts `a[i] += v` only for simple subscripts (identifier or literal index).
fn is_compound_target(e: &GExpr) -> bool {
    match e {
        GExpr::Ident(_) => true,
        GExpr::Member(t, _) => is_compound_target(t),
        GExpr::Index(t, i) => is_compound_target(t) && matches!(**i, GExpr::Ident(_) | GExpr::Int(_) | GExpr::Str(_)),
        GExpr::Raw(s) => !s.contains('(') && !s.contains('['),
        _ => false,
    }
}

fn is_plain_lvalue(e: &GExpr) -> bool {
    match e {
        GExpr::Ident(_) => true,
        GExpr::Member(t, _) => is_plain_lvalue(t) || matches!(**t, GExpr::Call(..) | GExpr::MethodCall(..)),
        GExpr::Index(t, _) => is_plain_lvalue(t) || matches!(**t, GExpr::Call(..) | GExpr::MethodCall(..)),
        GExpr::Raw(s) => {
            let b = s.as_bytes();
            !s.contains(' ') && !s.contains('(') && b.first().map_or(false, |c| c.is_ascii_alphabetic() || *c == b'_')
        }
        _ => false,
    }
}

/// A getter template like `$0.global_position` or `$0.x` can be assigned to.
fn is_assignable_template(t: &str) -> bool {
    let t = t.trim();
    if !t.starts_with("$0.") {
        return false;
    }
    t[3..].chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
}

#[allow(dead_code)]
fn local_of(l: &Local) -> GExpr {
    GExpr::ident(&l.gd_name)
}
