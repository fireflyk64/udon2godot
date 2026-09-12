//! Lowering: C# AST (one merged class) → GDScript AST.

pub mod expr;

use crate::ast::*;
use crate::diag::{Diagnostics, Span};
use crate::gd::*;
use crate::names::mangle_local;
use crate::program::{ClassInfo, FieldInfo, MethodInfo, Program};
use crate::token::Lit;
use crate::types::Ty;
use std::collections::{BTreeMap, BTreeSet, HashMap};

#[derive(Debug, Clone)]
pub struct LowerOptions {
    /// Script the generated behaviours extend.
    pub base_script: String,
    /// Resource path prefix of the output directory (for `extends` between converted scripts).
    pub res_prefix: String,
    /// Emit `class_name` (refused by a restricted sandbox).
    pub class_name: bool,
    /// Emit `# TODO` comments for unmapped members.
    pub todo_comments: bool,
}

impl Default for LowerOptions {
    fn default() -> Self {
        Self { base_script: "res://addons/udon_runtime/udon_behaviour.gd".into(), res_prefix: "res://".into(), class_name: false, todo_comments: true }
    }
}

/// Per-class conversion report.
#[derive(Debug, Default, Clone)]
pub struct Usage {
    /// Catalog members used, keyed `Type.member`.
    pub mapped: BTreeMap<String, usize>,
    /// Members of known types that the catalog does not map.
    pub unmapped: BTreeMap<String, usize>,
    /// Members explicitly marked unsupported.
    pub unsupported: BTreeMap<String, usize>,
    /// Members mapped by `!stub` templates (approximate or no-op behaviour).
    pub stubbed: BTreeMap<String, usize>,
    /// Members mapped by `!stored` templates (round-trip only).
    pub stored: BTreeMap<String, usize>,
    /// Members used that are not Udon externs (would not compile in VRChat either).
    pub not_udon_extern: BTreeSet<String>,
    /// Unresolved identifiers / types.
    pub unresolved: BTreeSet<String>,
}

pub struct ClassOutput {
    pub name: String,
    pub source: String,
    pub diags: Diagnostics,
    pub usage: Usage,
}

#[derive(Debug, Clone)]
pub(crate) struct Local {
    pub gd_name: String,
    pub ty: Ty,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct LoopCtx {
    /// Statements to run before `continue` (for-loop update).
    pub continue_prefix: Vec<GStmt>,
    pub is_switch: bool,
}

pub struct Lowerer<'p> {
    pub(crate) prog: &'p Program,
    pub(crate) class: &'p ClassInfo,
    pub(crate) opts: &'p LowerOptions,
    pub(crate) diags: Diagnostics,
    pub(crate) scopes: Vec<HashMap<String, Local>>,
    /// Every GDScript local name declared so far in the current function: C# block scopes are
    /// flattened, and SafeGDScript rejects a second `var i` in one function scope.
    pub(crate) fn_declared: std::collections::HashSet<String>,
    pub(crate) cur_method: Option<&'p MethodInfo>,
    pub(crate) tmp_counter: u32,
    pub(crate) pre: Vec<GStmt>,
    /// False while lowering operands whose evaluation is conditional (short-circuit rhs, ternary
    /// branches): template arguments must not be hoisted there.
    pub(crate) hoist_ok: bool,
    pub(crate) used_enums: BTreeSet<String>,
    pub(crate) usage: Usage,
    pub(crate) loops: Vec<LoopCtx>,
    pub(crate) in_static: bool,
}

pub fn lower_class(prog: &Program, class: &ClassInfo, opts: &LowerOptions) -> ClassOutput {
    let mut l = Lowerer {
        prog,
        class,
        opts,
        diags: Diagnostics::new(),
        scopes: vec![],
        fn_declared: std::collections::HashSet::new(),
        cur_method: None,
        tmp_counter: 0,
        pre: vec![],
        hoist_ok: true,
        used_enums: BTreeSet::new(),
        usage: Usage::default(),
        loops: vec![],
        in_static: false,
    };
    let script = l.lower();
    let source = Printer::new().script(&script);
    ClassOutput { name: class.name.clone(), source, diags: l.diags, usage: l.usage }
}

impl<'p> Lowerer<'p> {
    // ----- diagnostics & helpers -----

    pub(crate) fn warn(&mut self, span: Span, msg: impl Into<String>) {
        self.diags.warn(span, msg);
    }

    pub(crate) fn error(&mut self, span: Span, msg: impl Into<String>) {
        self.diags.error(span, msg);
    }

    pub(crate) fn fresh_tmp(&mut self) -> String {
        self.tmp_counter += 1;
        format!("_t{}", self.tmp_counter)
    }

    pub(crate) fn push_scope(&mut self) {
        self.scopes.push(HashMap::new());
    }

    pub(crate) fn pop_scope(&mut self) {
        self.scopes.pop();
    }

    pub(crate) fn declare_local(&mut self, name: &str, ty: Ty) -> String {
        let mut gd = mangle_local(name);
        // A gd name is used once per function: no shadowing of outer locals (forbidden in nested
        // GDScript scopes) and no reuse by sibling C# blocks (flattened into one scope).
        let redeclare_here = self.scopes.last().map_or(false, |s| s.contains_key(name));
        if !redeclare_here && self.fn_declared.contains(&gd) {
            let base = gd.clone();
            let mut n = 2;
            while self.fn_declared.contains(&gd) {
                gd = format!("{}{}", base, n);
                n += 1;
            }
        }
        self.fn_declared.insert(gd.clone());
        if let Some(s) = self.scopes.last_mut() {
            s.insert(name.to_string(), Local { gd_name: gd.clone(), ty });
        }
        gd
    }

    pub(crate) fn lookup_local(&self, name: &str) -> Option<&Local> {
        for s in self.scopes.iter().rev() {
            if let Some(l) = s.get(name) {
                return Some(l);
            }
        }
        None
    }

    pub(crate) fn take_pre(&mut self) -> Vec<GStmt> {
        std::mem::take(&mut self.pre)
    }

    pub(crate) fn gd_type(&self, ty: &Ty) -> Option<String> {
        self.prog.gd_type(ty)
    }

    pub(crate) fn note_enum(&mut self, name: &str) {
        self.used_enums.insert(name.to_string());
    }

    /// GDScript name for an enum declared in this script; renamed when a member shares the name
    /// (C# allows a property `Phase` of enum type `Phase`).
    pub(crate) fn enum_gd_name(&self, enum_name: &str) -> String {
        let short = enum_name.rsplit('.').next().unwrap_or(enum_name);
        let collides = self.class.fields.iter().any(|f| f.gd_name == short)
            || self.class.props.iter().any(|p| p.gd_name == short)
            || self.class.methods.iter().any(|m| m.gd_name == short);
        if collides {
            format!("{}_", short)
        } else {
            short.to_string()
        }
    }

    // ----- class -----

    fn lower(&mut self) -> GScript {
        let class = self.class;
        let mut script = GScript::default();
        script.header.push(format!("Generated by udon2godot from {}", class.source_files.join(", ")));
        script.header.push(format!("UdonSharp class `{}` (namespace `{}`)", class.name, class.namespace));
        if let Some(d) = &class.doc {
            for l in d.lines() {
                script.header.push(l.trim().to_string());
            }
        }
        if self.opts.class_name {
            script.class_name = Some(class.name.clone());
        }
        if class.is_behaviour {
            script.extends = Some(format!("\"{}\"", self.opts.base_script));
        } else if let Some(b) = &class.base {
            if self.prog.is_user_class(b) {
                script.extends = Some(format!("\"{}{}.sgd\"", self.opts.res_prefix, b));
            } else {
                self.warn(class.span, format!("class `{}` does not derive from UdonSharpBehaviour; emitted as a plain Node script", class.name));
                script.extends = Some("Node".into());
            }
        } else {
            self.warn(class.span, format!("class `{}` does not derive from UdonSharpBehaviour; emitted as a plain Node script", class.name));
            script.extends = Some("Node".into());
        }
        // Behaviours deriving from another user behaviour extend that script instead.
        if class.is_behaviour {
            if let Some(b) = &class.base {
                if self.prog.is_user_class(b) {
                    script.extends = Some(format!("\"{}{}.sgd\"", self.opts.res_prefix, b));
                }
            }
        }

        // Constants first (they may be referenced by field initializers).
        for f in &class.fields {
            if f.is_const || (f.is_static && f.is_readonly) {
                self.push_scope();
                let (init, is_literal) = match &f.init {
                    Some(e) => {
                        let lw = self.lower_expr(e);
                        let pre = self.take_pre();
                        let lit = pre.is_empty() && is_const_expr(&lw.e);
                        (lw.e, lit)
                    }
                    None => (self.prog.default_value(&f.ty), true),
                };
                self.pop_scope();
                if is_literal {
                    script.consts.push(GConst { name: f.gd_name.clone(), ty: self.gd_type(&f.ty), value: init, comment: f.doc.clone() });
                } else {
                    // Non-foldable constant: emit as a plain member.
                    script.vars.push(GVar { name: f.gd_name.clone(), ty: self.gd_type(&f.ty), init: Some(init), export: false, doc: f.doc.clone(), comment: Some("const (non-foldable initializer)".into()), setter: None, getter: None });
                }
            }
        }

        // Fields.
        for f in &class.fields {
            if f.is_const || (f.is_static && f.is_readonly) {
                continue;
            }
            let var = self.lower_field(f);
            script.vars.push(var);
        }

        // Properties: auto-properties are plain members; accessor properties become
        // get_X()/set_X() functions (a GDScript property setter would cost a host round-trip,
        // and the sandbox allows only a few nested VM entries).
        let mut prop_funcs: Vec<GFunc> = Vec::new();
        for p in &class.props {
            if p.decl.is_auto() {
                let var = self.lower_property(p);
                script.vars.push(var);
            } else {
                prop_funcs.extend(self.lower_property_funcs(p));
            }
        }

        // Metadata functions used by the runtime.
        script.funcs.push(GFunc {
            name: "udon_class".into(),
            params: vec![],
            ret: Some("String".into()),
            body: vec![GStmt::Return(Some(GExpr::str(&class.name)))],
            is_static: false,
            doc: None,
            comment: Some("UdonSharp class name (used for GetComponent<T>() and `is`)".into()),
        });
        let chain: Vec<GExpr> = self.prog.class_chain(&class.name).iter().map(|c| GExpr::str(&c.name)).collect();
        script.funcs.push(GFunc {
            name: "udon_class_chain".into(),
            params: vec![],
            ret: Some("Array".into()),
            body: vec![GStmt::Return(Some(GExpr::Array(chain)))],
            is_static: false,
            doc: None,
            comment: None,
        });
        let synced: Vec<GExpr> = class.fields.iter().filter(|f| f.synced).map(|f| GExpr::str(&f.gd_name)).collect();
        script.funcs.push(GFunc {
            name: "udon_synced_vars".into(),
            params: vec![],
            ret: Some("Array".into()),
            body: vec![GStmt::Return(Some(GExpr::Array(synced)))],
            is_static: false,
            doc: None,
            comment: Some("[UdonSynced] members, in declaration order".into()),
        });
        let sync_modes: Vec<(GExpr, GExpr)> = class
            .fields
            .iter()
            .filter(|f| f.synced && f.sync_mode.is_some())
            .map(|f| (GExpr::str(&f.gd_name), GExpr::str(f.sync_mode.as_deref().unwrap_or("None"))))
            .collect();
        if !sync_modes.is_empty() {
            script.funcs.push(GFunc {
                name: "udon_sync_var_modes".into(),
                params: vec![],
                ret: Some("Dictionary".into()),
                body: vec![GStmt::Return(Some(GExpr::Dict(sync_modes)))],
                is_static: false,
                doc: None,
                comment: Some("[UdonSynced(UdonSyncMode.X)] interpolation modes".into()),
            });
        }
        script.funcs.push(GFunc {
            name: "udon_sync_mode".into(),
            params: vec![],
            ret: Some("String".into()),
            body: vec![GStmt::Return(Some(GExpr::str(class.sync_mode.as_str())))],
            is_static: false,
            doc: None,
            comment: Some("[UdonBehaviourSyncMode]".into()),
        });
        let callbacks: Vec<(GExpr, GExpr)> = class
            .fields
            .iter()
            .filter_map(|f| f.change_callback.as_ref().map(|cb| (GExpr::str(&f.gd_name), GExpr::str(&format!("set_{}", crate::names::mangle(cb))))))
            .collect();
        if !callbacks.is_empty() {
            script.funcs.push(GFunc {
                name: "udon_field_callbacks".into(),
                params: vec![],
                ret: Some("Dictionary".into()),
                body: vec![GStmt::Return(Some(GExpr::Dict(callbacks)))],
                is_static: false,
                doc: None,
                comment: Some("[FieldChangeCallback]: synced field → property setter method invoked on deserialization".into()),
            });
        }
        let network_callable: Vec<GExpr> = class.methods.iter().filter(|m| m.network_callable).map(|m| GExpr::str(&m.gd_name)).collect();
        if !network_callable.is_empty() {
            script.funcs.push(GFunc {
                name: "udon_network_callable".into(),
                params: vec![],
                ret: Some("Array".into()),
                body: vec![GStmt::Return(Some(GExpr::Array(network_callable)))],
                is_static: false,
                doc: None,
                comment: Some("[NetworkCallable] methods".into()),
            });
        }

        // Property accessors, then methods.
        script.funcs.extend(prop_funcs);
        for m in &class.methods {
            let f = self.lower_method(m);
            script.funcs.push(f);
        }

        // Enums referenced anywhere in the class.
        let used: Vec<String> = self.used_enums.iter().cloned().collect();
        for name in used {
            if let Some(ue) = self.prog.user_enum(&name) {
                let gd_name = self.enum_gd_name(&ue.name);
                script.enums.push(GEnum { name: gd_name, members: ue.members.clone() });
            } else if let Some(ct) = self.prog.catalog.get(&name) {
                if ct.is_enum() {
                    let gd_name = self.enum_gd_name(&ct.name);
                    // GDScript enum members must be unique names; duplicate values are fine.
                    let mut seen = BTreeSet::new();
                    let members: Vec<(String, i64)> = ct.enum_members.iter().filter(|(n, _)| seen.insert(n.clone())).cloned().collect();
                    script.enums.push(GEnum { name: gd_name, members });
                }
            }
        }
        script.enums.sort_by(|a, b| a.name.cmp(&b.name));
        script.enums.dedup_by(|a, b| a.name == b.name);
        script
    }

    fn lower_field(&mut self, f: &FieldInfo) -> GVar {
        self.push_scope();
        let init = match &f.init {
            Some(Expr::ArrayInit(items, _)) => {
                let items: Vec<GExpr> = items.iter().map(|e| self.lower_expr(e).e).collect();
                let _ = self.take_pre();
                Some(GExpr::Array(items))
            }
            Some(e) => {
                let lw = self.lower_expr(e);
                let pre = self.take_pre();
                if !pre.is_empty() {
                    self.warn(f.span, format!("field `{}` initializer needs statements; moved to a plain default", f.name));
                    Some(self.prog.default_value(&f.ty))
                } else {
                    Some(self.coerce(lw, &f.ty).e)
                }
            }
            None => {
                let d = self.prog.default_value(&f.ty);
                Some(d)
            }
        };
        self.pop_scope();
        // Strings default to "" rather than null so `String`-typed members stay valid.
        let init = match (&f.ty, init) {
            (Ty::String, Some(GExpr::Null)) => Some(GExpr::str("")),
            (Ty::Array(_), Some(GExpr::Null)) | (Ty::MultiArray(..), Some(GExpr::Null)) => Some(GExpr::Array(vec![])),
            (_, i) => i,
        };
        let mut comment = None;
        if f.synced {
            comment = Some(match &f.sync_mode {
                Some(m) => format!("[UdonSynced({})]", m),
                None => "[UdonSynced]".into(),
            });
        }
        if let Some(cb) = &f.change_callback {
            comment = Some(format!("{}[FieldChangeCallback({})]", comment.map(|c| c + " ").unwrap_or_default(), cb));
        }
        let mut doc = f.doc.clone();
        if let Some(t) = &f.tooltip {
            doc = Some(match doc {
                Some(d) => format!("{}\n{}", d, t),
                None => t.clone(),
            });
        }
        if let Some(h) = &f.header {
            doc = Some(match doc {
                Some(d) => format!("[{}] {}", h, d),
                None => format!("[{}]", h),
            });
        }
        let export = f.serialized && !f.hide_in_inspector;
        let mut ty = self.gd_type(&f.ty);
        if export {
            // Scene importers wire exported object references late (nodes of any class, UI
            // controls included), so exported component/GameObject/behaviour fields are typed `Node`.
            if let Ty::Named(n) = &f.ty {
                let nodeish = self.prog.is_user_class(n)
                    || self.prog.catalog.get(n).map_or(false, |t| matches!(t.kind, crate::api::TypeKind::Component | crate::api::TypeKind::Behaviour) || t.name == "GameObject");
                if nodeish {
                    ty = Some("Node".into());
                }
            }
        }
        GVar { name: f.gd_name.clone(), ty, init, export, doc, comment, setter: None, getter: None }
    }

    fn lower_property(&mut self, p: &crate::program::PropInfo) -> GVar {
        let d = &p.decl;
        let mut var = GVar { name: p.gd_name.clone(), ty: self.gd_type(&p.ty), init: None, export: false, doc: d.doc.clone(), comment: Some("property".into()), setter: None, getter: None };
        if let Some(e) = &d.expr_body {
            self.push_scope();
            let lw = self.lower_expr(e);
            let mut body = self.take_pre();
            body.push(GStmt::Return(Some(self.coerce(lw, &p.ty).e)));
            self.pop_scope();
            var.getter = Some(body);
            return var;
        }
        if let Some(i) = &d.init {
            self.push_scope();
            let lw = self.lower_expr(i);
            let _ = self.take_pre();
            var.init = Some(self.coerce(lw, &p.ty).e);
            self.pop_scope();
        }
        if let Some(g) = &d.getter {
            if let Some(b) = &g.body {
                self.push_scope();
                let body = self.lower_block_stmts(&b.stmts);
                self.pop_scope();
                var.getter = Some(body);
            }
        }
        if let Some(s) = &d.setter {
            if let Some(b) = &s.body {
                self.push_scope();
                self.declare_local("value", p.ty.clone());
                // the setter parameter is always named `value` in GDScript
                if let Some(sc) = self.scopes.last_mut() {
                    sc.insert("value".into(), Local { gd_name: "value".into(), ty: p.ty.clone() });
                }
                let body = self.lower_block_stmts(&b.stmts);
                self.pop_scope();
                var.setter = Some(body);
            }
        }
        if var.getter.is_none() && var.setter.is_none() {
            var.comment = Some("auto-property".into());
            if var.init.is_none() {
                var.init = Some(self.prog.default_value(&p.ty));
            }
        } else if var.getter.is_some() && var.setter.is_none() && d.setter.is_none() {
            // read-only property: keep getter only
        }
        var
    }

    fn lower_property_funcs(&mut self, p: &crate::program::PropInfo) -> Vec<GFunc> {
        self.fn_declared.clear();
        let d = &p.decl;
        let mut out = Vec::new();
        let ret = self.gd_type(&p.ty);
        if let Some(e) = &d.expr_body {
            self.push_scope();
            let lw = self.lower_expr(e);
            let mut body = self.take_pre();
            body.push(GStmt::Return(Some(self.coerce(lw, &p.ty).e)));
            self.pop_scope();
            out.push(GFunc { name: format!("get_{}", p.gd_name), params: vec![], ret, body, is_static: p.is_static, doc: d.doc.clone(), comment: Some(format!("property {} (getter)", p.name)) });
            return out;
        }
        if let Some(g) = &d.getter {
            let body = match &g.body {
                Some(b) => {
                    self.push_scope();
                    let b = self.lower_block_stmts(&b.stmts);
                    self.pop_scope();
                    b
                }
                None => vec![GStmt::Return(Some(GExpr::ident(&format!("_prop_{}", p.gd_name))))],
            };
            out.push(GFunc { name: format!("get_{}", p.gd_name), params: vec![], ret: ret.clone(), body, is_static: p.is_static, doc: d.doc.clone(), comment: Some(format!("property {} (getter)", p.name)) });
        }
        if let Some(st) = &d.setter {
            self.push_scope();
            if let Some(sc) = self.scopes.last_mut() {
                sc.insert("value".into(), Local { gd_name: "value".into(), ty: p.ty.clone() });
            }
            let body = match &st.body {
                Some(b) => self.lower_block_stmts(&b.stmts),
                None => vec![GStmt::Assign { target: GExpr::ident(&format!("_prop_{}", p.gd_name)), op: "=", value: GExpr::ident("value") }],
            };
            self.pop_scope();
            out.push(GFunc { name: format!("set_{}", p.gd_name), params: vec![GParam { name: "value".into(), ty: self.gd_type(&p.ty), default: None }], ret: Some("void".into()), body, is_static: p.is_static, doc: None, comment: Some(format!("property {} (setter)", p.name)) });
        }
        out
    }

    fn lower_method(&mut self, m: &'p MethodInfo) -> GFunc {
        self.cur_method = Some(m);
        self.fn_declared.clear();
        self.in_static = m.is_static;
        self.push_scope();
        let mut params = Vec::new();
        for p in &m.params {
            let gd = self.declare_local(&p.name, p.ty.clone());
            let default = p.default.as_ref().map(|e| {
                let lw = self.lower_expr(e);
                let _ = self.take_pre();
                self.coerce(lw, &p.ty).e
            });
            let ty = if p.mode == ParamMode::Params { Some("Array".into()) } else { self.gd_type(&p.ty) };
            let default = if p.mode == ParamMode::Params { Some(GExpr::Array(vec![])) } else { default };
            params.push(GParam { name: gd, ty, default });
        }
        let mut body = match &m.decl.body {
            Some(b) => self.lower_block_stmts(&b.stmts),
            None => vec![GStmt::Pass],
        };
        // Methods with out/ref params return [ret, byrefs...]; rewrite bare returns.
        let ret = if m.has_byref() {
            let names: Vec<String> = m.byref_params().iter().map(|p| self.lookup_local(&p.name).map(|l| l.gd_name.clone()).unwrap_or(p.gd_name.clone())).collect();
            body = rewrite_returns_byref(body, &names, m.ret.is_void());
            if !ends_with_return(&body) {
                let mut items = vec![GExpr::Null];
                items.extend(names.iter().map(|n| GExpr::ident(n)));
                body.push(GStmt::Return(Some(GExpr::Array(items))));
            }
            Some("Array".into())
        } else {
            if m.ret.is_void() { Some("void".into()) } else { self.gd_type(&m.ret) }
        };
        self.pop_scope();
        self.cur_method = None;
        self.in_static = false;
        let mut comment = None;
        if m.network_callable {
            comment = Some("[NetworkCallable]".into());
        }
        if m.is_override {
            comment = Some(format!("{}override", comment.map(|c| c + " ").unwrap_or_default()));
        }
        GFunc { name: m.gd_name.clone(), params, ret, body, is_static: m.is_static, doc: m.decl.doc.clone(), comment }
    }

    // ----- statements -----

    pub(crate) fn lower_block_stmts(&mut self, stmts: &[Stmt]) -> Vec<GStmt> {
        let mut out = Vec::new();
        for s in stmts {
            out.extend(self.lower_stmt(s));
        }
        out
    }

    fn lower_embedded(&mut self, s: &Stmt) -> Vec<GStmt> {
        self.push_scope();
        let r = match s {
            Stmt::Block(b) => self.lower_block_stmts(&b.stmts),
            other => self.lower_stmt(other),
        };
        self.pop_scope();
        r
    }

    pub(crate) fn lower_stmt(&mut self, s: &Stmt) -> Vec<GStmt> {
        match s {
            Stmt::Block(b) => {
                self.push_scope();
                let r = self.lower_block_stmts(&b.stmts);
                self.pop_scope();
                r
            }
            Stmt::Empty(_) => vec![],
            Stmt::LocalDecl { ty, declarators, .. } => {
                let mut out = Vec::new();
                let declared_ty = if ty.is_var() { None } else { Some(self.prog.resolve_type_ref(ty)) };
                for d in declarators {
                    let (init, ty) = match &d.init {
                        Some(Expr::ArrayInit(items, _)) => {
                            let items: Vec<GExpr> = items.iter().map(|e| self.lower_expr(e).e).collect();
                            out.extend(self.take_pre());
                            let t = declared_ty.clone().unwrap_or(Ty::Array(Box::new(Ty::Unknown)));
                            (Some(GExpr::Array(items)), t)
                        }
                        Some(e) => {
                            let lw = self.lower_expr(e);
                            out.extend(self.take_pre());
                            let t = declared_ty.clone().unwrap_or_else(|| lw.ty.clone());
                            let e = match &declared_ty {
                                Some(dt) => self.coerce(lw, dt).e,
                                None => lw.e,
                            };
                            (Some(e), t)
                        }
                        None => (None, declared_ty.clone().unwrap_or(Ty::Unknown)),
                    };
                    let gd = self.declare_local(&d.name, ty.clone());
                    let hint = match &ty {
                        Ty::Null | Ty::Unknown => None,
                        t => self.gd_type(t),
                    };
                    // Uninitialized locals get their C# default so typed slots never hold the
                    // uninitialized sentinel (objects stay null).
                    let init = match (&ty, init) {
                        (Ty::String, None) => Some(GExpr::str("")),
                        (Ty::Array(_), None) | (Ty::MultiArray(..), None) => Some(GExpr::Array(vec![])),
                        (Ty::String, Some(GExpr::Null)) => Some(GExpr::str("")),
                        (t, None) if !matches!(t, Ty::Unknown | Ty::Null | Ty::Object) && !self.prog.is_unity_object(t) && !self.prog.is_player(t) => {
                            let d = self.prog.default_value(t);
                            if d == GExpr::Null { None } else { Some(d) }
                        }
                        (_, i) => i,
                    };
                    out.push(GStmt::VarDecl { name: gd, ty: hint, init });
                }
                out
            }
            Stmt::Expr(e, span) => self.lower_expr_stmt(e, *span),
            Stmt::If { cond, then, els, .. } => {
                let mut out = Vec::new();
                let c = self.lower_cond(cond);
                out.extend(self.take_pre());
                let mut branches = vec![(c, self.lower_embedded(then))];
                let mut els_out = None;
                let mut cur = els.as_deref();
                while let Some(e) = cur {
                    match e {
                        Stmt::If { cond, then, els, .. } => {
                            let c2 = self.lower_cond(cond);
                            let pre = self.take_pre();
                            if !pre.is_empty() {
                                // cannot hoist into an elif; nest instead
                                let mut nested = pre;
                                nested.extend(self.lower_if_chain(c2, then, els.as_deref()));
                                els_out = Some(nested);
                                cur = None;
                                break;
                            }
                            branches.push((c2, self.lower_embedded(then)));
                            cur = els.as_deref();
                        }
                        other => {
                            els_out = Some(self.lower_embedded(other));
                            cur = None;
                        }
                    }
                }
                out.push(GStmt::If { branches, els: els_out });
                out
            }
            Stmt::While { cond, body, .. } => {
                let mut out = Vec::new();
                let c = self.lower_cond(cond);
                let pre = self.take_pre();
                self.loops.push(LoopCtx::default());
                let b = self.lower_embedded(body);
                self.loops.pop();
                if pre.is_empty() {
                    out.push(GStmt::While { cond: c, body: b });
                } else {
                    let mut wb = pre;
                    wb.push(GStmt::If { branches: vec![(c.not(), vec![GStmt::Break])], els: None });
                    wb.extend(b);
                    out.push(GStmt::While { cond: GExpr::Bool(true), body: wb });
                }
                out
            }
            Stmt::DoWhile { body, cond, .. } => {
                // var _first = true; while _first or cond: _first = false; body
                let flag = self.fresh_tmp();
                let mut out = vec![GStmt::VarDecl { name: flag.clone(), ty: Some("bool".into()), init: Some(GExpr::Bool(true)) }];
                let c = self.lower_cond(cond);
                let pre = self.take_pre();
                self.loops.push(LoopCtx::default());
                let b = self.lower_embedded(body);
                self.loops.pop();
                if pre.is_empty() {
                    let mut wb = vec![GStmt::Assign { target: GExpr::ident(&flag), op: "=", value: GExpr::Bool(false) }];
                    wb.extend(b);
                    out.push(GStmt::While { cond: GExpr::ident(&flag).bin("or", c), body: wb });
                } else {
                    let mut wb = vec![GStmt::If {
                        branches: vec![(GExpr::ident(&flag).not(), {
                            let mut v = pre;
                            v.push(GStmt::If { branches: vec![(c.not(), vec![GStmt::Break])], els: None });
                            v
                        })],
                        els: None,
                    }];
                    wb.push(GStmt::Assign { target: GExpr::ident(&flag), op: "=", value: GExpr::Bool(false) });
                    wb.extend(b);
                    out.push(GStmt::While { cond: GExpr::Bool(true), body: wb });
                }
                out
            }
            Stmt::For { init, cond, update, body, .. } => self.lower_for(init, cond.as_ref(), update, body),
            Stmt::Foreach { ty, name, iter, body, .. } => {
                let mut out = Vec::new();
                let it = self.lower_expr(iter);
                out.extend(self.take_pre());
                let elem_ty = match &it.ty {
                    Ty::Array(e) | Ty::MultiArray(e, _) => (**e).clone(),
                    Ty::String => Ty::Char,
                    Ty::Named(n) if n == "Transform" => Ty::Named("Transform".into()),
                    Ty::Named(n) if n == "DataList" => Ty::Named("DataToken".into()),
                    _ => Ty::Unknown,
                };
                let elem_ty = if ty.is_var() { elem_ty } else { self.prog.resolve_type_ref(ty) };
                let iter_expr = if it.ty.is_named("Transform") { it.e.method("get_children", vec![]) } else { it.e };
                self.push_scope();
                let gd = self.declare_local(name, elem_ty);
                self.loops.push(LoopCtx::default());
                let b = match body.as_ref() {
                    Stmt::Block(bl) => self.lower_block_stmts(&bl.stmts),
                    other => self.lower_stmt(other),
                };
                self.loops.pop();
                self.pop_scope();
                out.push(GStmt::For { var: gd, iter: iter_expr, body: b });
                out
            }
            Stmt::Switch { subject, sections, .. } => self.lower_switch(subject, sections),
            Stmt::Break(span) => {
                if let Some(l) = self.loops.last() {
                    if l.is_switch {
                        // A `break` that escapes a switch arm: handled by the arm rewriter; if one
                        // survives here it is a no-op in a `match`.
                        return vec![];
                    }
                } else {
                    self.warn(*span, "`break` outside of a loop");
                }
                vec![GStmt::Break]
            }
            Stmt::Continue(span) => {
                // find the innermost real loop
                let mut prefix = Vec::new();
                let mut found = false;
                for l in self.loops.iter().rev() {
                    if !l.is_switch {
                        prefix = l.continue_prefix.clone();
                        found = true;
                        break;
                    }
                }
                if !found {
                    self.warn(*span, "`continue` outside of a loop");
                }
                let mut out = prefix;
                out.push(GStmt::Continue);
                out
            }
            Stmt::Return(e, _) => {
                let mut out = Vec::new();
                match e {
                    Some(e) => {
                        let lw = self.lower_expr(e);
                        out.extend(self.take_pre());
                        let ret_ty = self.cur_method.map(|m| m.ret.clone()).unwrap_or(Ty::Unknown);
                        let v = self.coerce(lw, &ret_ty).e;
                        out.push(GStmt::Return(Some(v)));
                    }
                    None => out.push(GStmt::Return(None)),
                }
                out
            }
            Stmt::Throw(e, span) => {
                self.warn(*span, "`throw` is lowered to a runtime error (Udon has no exceptions)");
                let mut out = Vec::new();
                let msg = match e {
                    Some(e) => {
                        let lw = self.lower_expr(e);
                        out.extend(self.take_pre());
                        lw.e
                    }
                    None => GExpr::str("exception"),
                };
                out.push(GStmt::Expr(GExpr::ident("U").method("throw", vec![GExpr::ident("str").call(vec![msg])])));
                out
            }
            Stmt::Try { body, span, .. } => {
                self.warn(*span, "`try`/`catch` is not supported by Udon; only the try block is kept");
                self.push_scope();
                let r = self.lower_block_stmts(&body.stmts);
                self.pop_scope();
                r
            }
            Stmt::Lock { body, .. } => self.lower_embedded(body),
            Stmt::GotoCase(_, span) => {
                self.error(*span, "`goto case` is not supported");
                vec![GStmt::Comment("TODO(udon2godot): goto case".into())]
            }
            Stmt::Label(l, span) | Stmt::Goto(l, span) => {
                self.error(*span, format!("labels/goto are not supported (`{}`)", l));
                vec![GStmt::Comment(format!("TODO(udon2godot): goto {}", l))]
            }
        }
    }

    fn lower_if_chain(&mut self, cond: GExpr, then: &Stmt, els: Option<&Stmt>) -> Vec<GStmt> {
        let t = self.lower_embedded(then);
        let e = els.map(|e| {
            let mut pre_and = Vec::new();
            match e {
                Stmt::If { cond, then, els, .. } => {
                    let c = self.lower_cond(cond);
                    pre_and.extend(self.take_pre());
                    pre_and.extend(self.lower_if_chain(c, then, els.as_deref()));
                }
                other => pre_and.extend(self.lower_embedded(other)),
            }
            pre_and
        });
        vec![GStmt::If { branches: vec![(cond, t)], els: e }]
    }

    fn lower_for(&mut self, init: &[Stmt], cond: Option<&Expr>, update: &[Expr], body: &Stmt) -> Vec<GStmt> {
        // Try the counting-loop pattern: for (int i = a; i < b; i++)
        if let Some(r) = self.try_lower_range_for(init, cond, update, body) {
            return r;
        }
        self.push_scope();
        let mut out = Vec::new();
        for s in init {
            out.extend(self.lower_stmt(s));
        }
        let c = match cond {
            Some(c) => self.lower_cond(c),
            None => GExpr::Bool(true),
        };
        let pre = self.take_pre();
        // update statements
        let mut upd = Vec::new();
        for u in update {
            upd.extend(self.lower_expr_stmt(u, u.span()));
        }
        self.loops.push(LoopCtx { continue_prefix: upd.clone(), is_switch: false });
        let b = self.lower_embedded(body);
        self.loops.pop();
        let has_pre = !pre.is_empty();
        let mut wb = pre;
        if has_pre {
            wb.push(GStmt::If { branches: vec![(c.clone().not(), vec![GStmt::Break])], els: None });
        }
        wb.extend(b);
        wb.extend(upd);
        // If we hoisted pre-statements, the loop is `while true` with an explicit break.
        let loop_cond = if has_pre { GExpr::Bool(true) } else { c };
        out.push(GStmt::While { cond: loop_cond, body: wb });
        self.pop_scope();
        // Wrap in a block scope? GDScript has no block scoping for the init var; it leaks into the
        // enclosing function scope, which is harmless.
        out
    }

    fn try_lower_range_for(&mut self, init: &[Stmt], cond: Option<&Expr>, update: &[Expr], body: &Stmt) -> Option<Vec<GStmt>> {
        if init.len() != 1 || update.len() != 1 {
            return None;
        }
        let (var, start) = match &init[0] {
            Stmt::LocalDecl { ty, declarators, .. } if declarators.len() == 1 && (ty.is_var() || matches!(ty, TypeRef::Named { name, .. } if name == "int")) => {
                let d = &declarators[0];
                (d.name.clone(), d.init.as_ref()?)
            }
            _ => return None,
        };
        // update: i++ / ++i / i += 1 / i-- / --i / i -= 1
        let step: i64 = match update[0].unparen() {
            Expr::Unary { op: UnOp::PostInc | UnOp::PreInc, expr, .. } if is_ident(expr, &var) => 1,
            Expr::Unary { op: UnOp::PostDec | UnOp::PreDec, expr, .. } if is_ident(expr, &var) => -1,
            Expr::Assign { op: Some(BinOp::Add), lhs, rhs, .. } if is_ident(lhs, &var) => match rhs.unparen() {
                Expr::Lit(Lit::Int(v), _) => *v,
                _ => return None,
            },
            Expr::Assign { op: Some(BinOp::Sub), lhs, rhs, .. } if is_ident(lhs, &var) => match rhs.unparen() {
                Expr::Lit(Lit::Int(v), _) => -*v,
                _ => return None,
            },
            _ => return None,
        };
        if step == 0 {
            return None;
        }
        // cond: i < b, i <= b, i > b, i >= b, i != b
        let (op, bound) = match cond?.unparen() {
            Expr::Binary { op, lhs, rhs, .. } if is_ident(lhs, &var) => (*op, rhs.as_ref()),
            _ => return None,
        };
        let ok = match (op, step > 0) {
            (BinOp::Lt, true) | (BinOp::Le, true) | (BinOp::Ne, true) => true,
            (BinOp::Gt, false) | (BinOp::Ge, false) | (BinOp::Ne, false) => true,
            _ => false,
        };
        if !ok {
            return None;
        }
        // body must not assign the loop variable, and the bound must be side-effect free
        if assigns_var(body, &var) || !is_pure_expr(bound) {
            return None;
        }
        if expr_mentions_assign(bound) {
            return None;
        }
        let s = self.lower_expr(start);
        let b = self.lower_expr(bound);
        if !self.pre.is_empty() {
            let _ = self.take_pre();
            return None;
        }
        if !s.ty.is_integral() && !s.ty.is_unknown() {
            return None;
        }
        if !b.ty.is_integral() && !b.ty.is_unknown() {
            return None;
        }
        let end = match op {
            BinOp::Le => b.e.bin("+", GExpr::Int(1)),
            BinOp::Ge => b.e.bin("-", GExpr::Int(1)),
            _ => b.e,
        };
        let mut args = vec![s.e, end];
        if step != 1 {
            args.push(GExpr::Int(step));
        }
        self.push_scope();
        let gd = self.declare_local(&var, Ty::Int);
        self.loops.push(LoopCtx::default());
        let body_stmts = match body {
            Stmt::Block(bl) => self.lower_block_stmts(&bl.stmts),
            other => self.lower_stmt(other),
        };
        self.loops.pop();
        self.pop_scope();
        Some(vec![GStmt::For { var: gd, iter: GExpr::ident("range").call(args), body: body_stmts }])
    }

    fn lower_switch(&mut self, subject: &Expr, sections: &[SwitchSection]) -> Vec<GStmt> {
        let mut out = Vec::new();
        let subj = self.lower_expr(subject);
        out.extend(self.take_pre());
        let subj_ty = subj.ty.clone();
        let mut arms = Vec::new();
        let mut default_arm: Option<GMatchArm> = None;
        for sec in sections {
            let mut patterns = Vec::new();
            let mut is_default = false;
            for l in &sec.labels {
                match l {
                    SwitchLabel::Case(e) => {
                        let lw = self.lower_expr(e);
                        let pre = self.take_pre();
                        if !pre.is_empty() {
                            self.warn(e.span(), "case label needs statements; not supported");
                        }
                        let e = self.coerce(lw, &subj_ty).e;
                        patterns.push(e);
                    }
                    SwitchLabel::Default => is_default = true,
                }
            }
            self.push_scope();
            self.loops.push(LoopCtx { continue_prefix: vec![], is_switch: true });
            let body = self.lower_case_body(&sec.body);
            self.loops.pop();
            self.pop_scope();
            if is_default {
                let mut arm = GMatchArm { patterns: vec![], body };
                if !patterns.is_empty() {
                    // `case X: default:` — wildcard covers X too
                    arm.patterns.clear();
                }
                default_arm = Some(arm);
            } else {
                arms.push(GMatchArm { patterns, body });
            }
        }
        if let Some(d) = default_arm {
            arms.push(d);
        }
        out.push(GStmt::Match { subject: subj.e, arms });
        out
    }

    /// Lower a switch section body: drop the terminating `break`, and rewrite
    /// `if (c) { ...; break; } rest` into `if c: ... else: rest`.
    fn lower_case_body(&mut self, stmts: &[Stmt]) -> Vec<GStmt> {
        let mut stmts: Vec<&Stmt> = stmts.iter().collect();
        // unwrap a single block `case X: { ... }`
        if stmts.len() == 1 {
            if let Stmt::Block(b) = stmts[0] {
                stmts = b.stmts.iter().collect();
            }
        }
        // strip trailing break(s)
        while let Some(Stmt::Break(_)) = stmts.last() {
            stmts.pop();
        }
        self.lower_case_list(&stmts)
    }

    fn lower_case_list(&mut self, stmts: &[&Stmt]) -> Vec<GStmt> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < stmts.len() {
            let s = stmts[i];
            if let Stmt::If { cond, then, els: None, .. } = s {
                if block_ends_with_break(then) {
                    // if cond: then-without-break  else: rest
                    let c = self.lower_cond(cond);
                    out.extend(self.take_pre());
                    let then_stmts: Vec<&Stmt> = match then.as_ref() {
                        Stmt::Block(b) => b.stmts.iter().collect(),
                        other => vec![other],
                    };
                    let mut then_stmts = then_stmts;
                    while let Some(Stmt::Break(_)) = then_stmts.last() {
                        then_stmts.pop();
                    }
                    self.push_scope();
                    let t = self.lower_case_list(&then_stmts);
                    self.pop_scope();
                    let rest: Vec<&Stmt> = stmts[i + 1..].to_vec();
                    self.push_scope();
                    let r = self.lower_case_list(&rest);
                    self.pop_scope();
                    out.push(GStmt::If { branches: vec![(c, t)], els: if r.is_empty() { None } else { Some(r) } });
                    return out;
                }
            }
            if let Stmt::Break(span) = s {
                if i + 1 < stmts.len() {
                    self.warn(*span, "`break` in the middle of a switch section; following statements are unreachable and dropped");
                }
                return out;
            }
            if contains_switch_break(s) {
                self.warn(s.span(), "a `break` nested inside this statement exits the enclosing `switch`; it is dropped in the `match` lowering (verify control flow)");
            }
            out.extend(self.lower_stmt(s));
            i += 1;
        }
        out
    }

    /// Lower an expression used as a statement (assignments, calls, increments).
    pub(crate) fn lower_expr_stmt(&mut self, e: &Expr, span: Span) -> Vec<GStmt> {
        let mut out = Vec::new();
        match e.unparen() {
            Expr::Assign { op, lhs, rhs, .. } => {
                let stmts = self.lower_assign_stmt(*op, lhs, rhs);
                out.extend(stmts);
            }
            Expr::Unary { op: UnOp::PostInc | UnOp::PreInc, expr, .. } => {
                let stmts = self.lower_assign_stmt(Some(BinOp::Add), expr, &Expr::Lit(Lit::Int(1), span));
                out.extend(stmts);
            }
            Expr::Unary { op: UnOp::PostDec | UnOp::PreDec, expr, .. } => {
                let stmts = self.lower_assign_stmt(Some(BinOp::Sub), expr, &Expr::Lit(Lit::Int(1), span));
                out.extend(stmts);
            }
            other => {
                let lw = self.lower_expr(other);
                out.extend(self.take_pre());
                match lw.e {
                    GExpr::Raw(ref s) if crate::template::is_statement_like(s) => out.push(GStmt::Raw(s.clone())),
                    GExpr::Raw(ref s) if s == "pass" => {}
                    // A value-only template result (e.g. `not hit.is_empty()` after an out-param call)
                    // has no effect as a statement; its side effects are already in the pre-statements.
                    GExpr::Raw(ref s) if !crate::gd::raw_is_atomic(s) => {}
                    e => {
                        // A bare value expression as a statement is legal in GDScript but pointless;
                        // keep calls, drop pure values.
                        match &e {
                            GExpr::Call(..) | GExpr::MethodCall(..) | GExpr::Raw(_) => out.push(GStmt::Expr(e)),
                            // `_tN[0]`: the (void) result of a hoisted ref/out call; nothing to keep.
                            GExpr::Index(b, i) if matches!(&**b, GExpr::Ident(n) if n.starts_with("_t")) && matches!(&**i, GExpr::Int(0)) => {}
                            _ => {
                                self.warn(span, "expression statement has no effect and was dropped");
                            }
                        }
                    }
                }
            }
        }
        out
    }
}

pub(crate) fn is_ident(e: &Expr, name: &str) -> bool {
    matches!(e.unparen(), Expr::Ident(n, _) if n == name)
}

fn is_const_expr(e: &GExpr) -> bool {
    match e {
        GExpr::Int(_) | GExpr::Float(_) | GExpr::Str(_) | GExpr::Bool(_) | GExpr::Null => true,
        GExpr::Unary(_, x) => is_const_expr(x),
        GExpr::Binary(a, _, b) => is_const_expr(a) && is_const_expr(b),
        GExpr::Paren(x) => is_const_expr(x),
        GExpr::Raw(s) => s == "PI" || s == "INF" || s == "TAU" || s == "NAN" || s.starts_with("Vector3(") || s.starts_with("Vector2(") || s.starts_with("Color(") || s.starts_with("Vector3.") || s.starts_with("Vector2.") || s.starts_with("Color.") || s == "(PI / 180.0)" || s == "(180.0 / PI)",
        GExpr::Ident(_) => true, // other consts
        GExpr::Call(callee, args) => matches!(&**callee, GExpr::Ident(n) if n == "Vector3" || n == "Vector2" || n == "Color" || n == "Vector4") && args.iter().all(is_const_expr),
        GExpr::Member(t, _) => matches!(&**t, GExpr::Ident(n) if n == "Vector3" || n == "Vector2" || n == "Color"),
        _ => false,
    }
}

fn ends_with_return(body: &[GStmt]) -> bool {
    matches!(body.last(), Some(GStmt::Return(_)))
}

/// Rewrite `return x` → `return [x, refs...]` for by-ref methods.
fn rewrite_returns_byref(body: Vec<GStmt>, names: &[String], is_void: bool) -> Vec<GStmt> {
    body.into_iter()
        .map(|s| match s {
            GStmt::Return(v) => {
                let mut items = vec![if is_void { GExpr::Null } else { v.unwrap_or(GExpr::Null) }];
                items.extend(names.iter().map(|n| GExpr::ident(n)));
                GStmt::Return(Some(GExpr::Array(items)))
            }
            GStmt::If { branches, els } => GStmt::If {
                branches: branches.into_iter().map(|(c, b)| (c, rewrite_returns_byref(b, names, is_void))).collect(),
                els: els.map(|e| rewrite_returns_byref(e, names, is_void)),
            },
            GStmt::While { cond, body } => GStmt::While { cond, body: rewrite_returns_byref(body, names, is_void) },
            GStmt::For { var, iter, body } => GStmt::For { var, iter, body: rewrite_returns_byref(body, names, is_void) },
            GStmt::Match { subject, arms } => GStmt::Match {
                subject,
                arms: arms.into_iter().map(|a| GMatchArm { patterns: a.patterns, body: rewrite_returns_byref(a.body, names, is_void) }).collect(),
            },
            other => other,
        })
        .collect()
}

fn block_ends_with_break(s: &Stmt) -> bool {
    match s {
        Stmt::Break(_) => true,
        Stmt::Block(b) => matches!(b.stmts.last(), Some(Stmt::Break(_))),
        _ => false,
    }
}

/// Does a statement contain a `break` that would target an enclosing switch (not a nested loop/switch)?
fn contains_switch_break(s: &Stmt) -> bool {
    match s {
        Stmt::Break(_) => true,
        Stmt::Block(b) => b.stmts.iter().any(contains_switch_break),
        Stmt::If { then, els, .. } => contains_switch_break(then) || els.as_deref().map_or(false, contains_switch_break),
        Stmt::Try { body, .. } => body.stmts.iter().any(contains_switch_break),
        Stmt::Lock { body, .. } => contains_switch_break(body),
        // loops and switches capture their own breaks
        _ => false,
    }
}

/// Does the statement assign to the named variable (or increment it)?
pub(crate) fn assigns_var(s: &Stmt, var: &str) -> bool {
    fn expr_assigns(e: &Expr, var: &str) -> bool {
        match e {
            Expr::Assign { lhs, rhs, .. } => is_ident(lhs, var) || expr_assigns(lhs, var) || expr_assigns(rhs, var),
            Expr::Unary { op: UnOp::PostInc | UnOp::PreInc | UnOp::PostDec | UnOp::PreDec, expr, .. } => is_ident(expr, var) || expr_assigns(expr, var),
            Expr::Unary { expr, .. } => expr_assigns(expr, var),
            Expr::Binary { lhs, rhs, .. } => expr_assigns(lhs, var) || expr_assigns(rhs, var),
            Expr::Call { callee, args, .. } => {
                expr_assigns(callee, var)
                    || args.iter().any(|a| (matches!(a.mode, ParamMode::Out | ParamMode::Ref) && is_ident(&a.expr, var)) || expr_assigns(&a.expr, var))
            }
            Expr::Member { target, .. } => expr_assigns(target, var),
            Expr::Index { target, indices, .. } => expr_assigns(target, var) || indices.iter().any(|i| expr_assigns(i, var)),
            Expr::Cond { cond, then, els, .. } => expr_assigns(cond, var) || expr_assigns(then, var) || expr_assigns(els, var),
            Expr::Cast { expr, .. } | Expr::Paren(expr, _) | Expr::Checked(expr, _, _) => expr_assigns(expr, var),
            Expr::New { args, .. } => args.iter().any(|a| expr_assigns(&a.expr, var)),
            Expr::NewArray { sizes, init, .. } => sizes.iter().flatten().any(|s| expr_assigns(s, var)) || init.as_ref().map_or(false, |i| i.iter().any(|e| expr_assigns(e, var))),
            Expr::ArrayInit(items, _) => items.iter().any(|e| expr_assigns(e, var)),
            Expr::Interp(pieces, _) => pieces.iter().any(|p| matches!(p, InterpPiece::Expr { expr, .. } if expr_assigns(expr, var))),
            _ => false,
        }
    }
    match s {
        Stmt::Block(b) => b.stmts.iter().any(|x| assigns_var(x, var)),
        Stmt::LocalDecl { declarators, .. } => declarators.iter().any(|d| d.name == var || d.init.as_ref().map_or(false, |i| expr_assigns(i, var))),
        Stmt::Expr(e, _) => expr_assigns(e, var),
        Stmt::If { cond, then, els, .. } => expr_assigns(cond, var) || assigns_var(then, var) || els.as_deref().map_or(false, |e| assigns_var(e, var)),
        Stmt::While { cond, body, .. } | Stmt::DoWhile { body, cond, .. } => expr_assigns(cond, var) || assigns_var(body, var),
        Stmt::For { init, cond, update, body, .. } => {
            init.iter().any(|s| assigns_var(s, var)) || cond.as_ref().map_or(false, |c| expr_assigns(c, var)) || update.iter().any(|u| expr_assigns(u, var)) || assigns_var(body, var)
        }
        Stmt::Foreach { name, iter, body, .. } => name == var || expr_assigns(iter, var) || assigns_var(body, var),
        Stmt::Switch { subject, sections, .. } => expr_assigns(subject, var) || sections.iter().any(|s| s.body.iter().any(|x| assigns_var(x, var))),
        Stmt::Return(Some(e), _) | Stmt::Throw(Some(e), _) => expr_assigns(e, var),
        Stmt::Try { body, catches, finally, .. } => {
            body.stmts.iter().any(|x| assigns_var(x, var)) || catches.iter().any(|c| c.stmts.iter().any(|x| assigns_var(x, var))) || finally.as_ref().map_or(false, |f| f.stmts.iter().any(|x| assigns_var(x, var)))
        }
        Stmt::Lock { body, .. } => assigns_var(body, var),
        _ => false,
    }
}

/// Side-effect-free expression (for `range()` bounds).
fn is_pure_expr(e: &Expr) -> bool {
    match e.unparen() {
        Expr::Lit(..) | Expr::Ident(..) | Expr::This(_) | Expr::TypeExpr(..) => true,
        Expr::Member { target, .. } => is_pure_expr(target),
        Expr::Index { target, indices, .. } => is_pure_expr(target) && indices.iter().all(is_pure_expr),
        Expr::Binary { lhs, rhs, .. } => is_pure_expr(lhs) && is_pure_expr(rhs),
        Expr::Unary { op, expr, .. } => !matches!(op, UnOp::PostInc | UnOp::PreInc | UnOp::PostDec | UnOp::PreDec) && is_pure_expr(expr),
        Expr::Cast { expr, .. } => is_pure_expr(expr),
        Expr::Cond { cond, then, els, .. } => is_pure_expr(cond) && is_pure_expr(then) && is_pure_expr(els),
        _ => false,
    }
}

fn expr_mentions_assign(e: &Expr) -> bool {
    matches!(e.unparen(), Expr::Assign { .. })
}
