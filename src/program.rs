//! Whole-program model: all user classes (partial declarations merged) and enums, with
//! resolved member signatures, plus the API catalog and extern table.

use crate::api::{Catalog, TypeInfo};
use crate::ast::*;
use crate::diag::{Diagnostics, Span};
use crate::externs::ExternTable;
use crate::names::mangle;
use crate::types::{canonical_type_name, ty_from_ref, Ty};
use std::collections::{BTreeMap, HashMap};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncMode {
    Any,
    None,
    Continuous,
    Manual,
    NoVariableSync,
}

impl SyncMode {
    pub fn as_str(self) -> &'static str {
        match self {
            SyncMode::Any => "any",
            SyncMode::None => "none",
            SyncMode::Continuous => "continuous",
            SyncMode::Manual => "manual",
            SyncMode::NoVariableSync => "no_variable_sync",
        }
    }
}

#[derive(Debug, Clone)]
pub struct FieldInfo {
    pub name: String,
    pub gd_name: String,
    pub ty: Ty,
    pub is_public: bool,
    pub is_static: bool,
    pub is_const: bool,
    pub is_readonly: bool,
    pub synced: bool,
    /// `[UdonSynced(UdonSyncMode.Linear)]` etc.
    pub sync_mode: Option<String>,
    pub serialized: bool,
    pub hide_in_inspector: bool,
    /// `[FieldChangeCallback(nameof(Prop))]`
    pub change_callback: Option<String>,
    pub tooltip: Option<String>,
    pub header: Option<String>,
    pub init: Option<Expr>,
    pub doc: Option<String>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct PropInfo {
    pub name: String,
    pub gd_name: String,
    pub ty: Ty,
    pub is_static: bool,
    pub is_public: bool,
    pub decl: PropertyDecl,
}

#[derive(Debug, Clone)]
pub struct ParamSig {
    pub name: String,
    pub gd_name: String,
    pub ty: Ty,
    pub mode: ParamMode,
    pub default: Option<Expr>,
}

#[derive(Debug, Clone)]
pub struct MethodInfo {
    pub name: String,
    pub gd_name: String,
    pub params: Vec<ParamSig>,
    pub ret: Ty,
    pub is_static: bool,
    pub is_override: bool,
    pub is_public: bool,
    pub network_callable: bool,
    pub recursive: bool,
    pub decl: MethodDecl,
    /// Index of the declaration (partial part) this came from.
    pub decl_index: usize,
}

impl MethodInfo {
    /// Methods with `out`/`ref` parameters return `[ret, ref1, ref2, ...]`.
    pub fn has_byref(&self) -> bool {
        self.params.iter().any(|p| matches!(p.mode, ParamMode::Out | ParamMode::Ref))
    }
    pub fn byref_params(&self) -> Vec<&ParamSig> {
        self.params.iter().filter(|p| matches!(p.mode, ParamMode::Out | ParamMode::Ref)).collect()
    }
}

#[derive(Debug, Clone)]
pub struct UserEnum {
    pub name: String,
    pub owner: Option<String>,
    pub members: Vec<(String, i64)>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct ClassInfo {
    pub name: String,
    pub namespace: String,
    pub base: Option<String>,
    pub is_behaviour: bool,
    pub sync_mode: SyncMode,
    pub fields: Vec<FieldInfo>,
    pub props: Vec<PropInfo>,
    pub methods: Vec<MethodInfo>,
    pub decls: Vec<ClassDecl>,
    pub doc: Option<String>,
    pub source_files: Vec<String>,
    pub span: Span,
}

impl ClassInfo {
    pub fn field(&self, name: &str) -> Option<&FieldInfo> {
        self.fields.iter().find(|f| f.name == name)
    }
    pub fn prop(&self, name: &str) -> Option<&PropInfo> {
        self.props.iter().find(|p| p.name == name)
    }
    pub fn methods_named(&self, name: &str) -> Vec<&MethodInfo> {
        self.methods.iter().filter(|m| m.name == name).collect()
    }
}

pub struct Program {
    pub classes: Vec<ClassInfo>,
    pub enums: Vec<UserEnum>,
    pub catalog: Catalog,
    pub externs: ExternTable,
    class_index: HashMap<String, usize>,
    enum_index: HashMap<String, usize>,
}

impl Program {
    pub fn build(units: &[CompilationUnit], catalog: Catalog, externs: ExternTable, diags: &mut Diagnostics) -> Program {
        let mut classes: BTreeMap<String, ClassInfo> = BTreeMap::new();
        let mut enums: Vec<UserEnum> = Vec::new();

        // First pass: collect enums (top-level and nested) so field types resolve.
        for cu in units {
            for td in &cu.types {
                collect_enums(td, None, &mut enums);
            }
        }

        // Second pass: classes (merge partials).
        for cu in units {
            for td in &cu.types {
                let TypeDecl::Class(cd) = td else { continue };
                let entry = classes.entry(cd.name.clone()).or_insert_with(|| ClassInfo {
                    name: cd.name.clone(),
                    namespace: cd.namespace.clone(),
                    base: None,
                    is_behaviour: false,
                    sync_mode: SyncMode::Any,
                    fields: vec![],
                    props: vec![],
                    methods: vec![],
                    decls: vec![],
                    doc: None,
                    source_files: vec![],
                    span: cd.span,
                });
                if !entry.source_files.contains(&cu.path) {
                    entry.source_files.push(cu.path.clone());
                }
                if entry.doc.is_none() {
                    entry.doc = cd.doc.clone();
                }
                if entry.base.is_none() {
                    if let Some(b) = cd.bases.first() {
                        entry.base = Some(canonical_type_name(&b.display()));
                    }
                }
                if let Some(a) = cd.attr("UdonBehaviourSyncMode") {
                    if let Some(arg) = a.args.first() {
                        let t = arg.text.rsplit('.').next().unwrap_or("").trim().to_string();
                        entry.sync_mode = match t.as_str() {
                            "None" => SyncMode::None,
                            "Continuous" => SyncMode::Continuous,
                            "Manual" => SyncMode::Manual,
                            "NoVariableSync" => SyncMode::NoVariableSync,
                            _ => SyncMode::Any,
                        };
                    }
                }
                entry.decls.push(cd.clone());
            }
        }

        // Resolve base chain to decide behaviour-ness.
        let names: Vec<String> = classes.keys().cloned().collect();
        for n in &names {
            let mut cur = classes.get(n).and_then(|c| c.base.clone());
            let mut is_b = false;
            let mut guard = 0;
            while let Some(b) = cur {
                guard += 1;
                if guard > 32 {
                    break;
                }
                if b == "UdonSharpBehaviour" || b == "UdonBehaviour" {
                    is_b = true;
                    break;
                }
                cur = classes.get(&b).and_then(|c| c.base.clone());
            }
            classes.get_mut(n).unwrap().is_behaviour = is_b;
        }

        let mut prog = Program {
            classes: vec![],
            enums,
            catalog,
            externs,
            class_index: HashMap::new(),
            enum_index: HashMap::new(),
        };
        for (i, e) in prog.enums.iter().enumerate() {
            prog.enum_index.insert(e.name.clone(), i);
            if let Some(o) = &e.owner {
                prog.enum_index.insert(format!("{}.{}", o, e.name), i);
            }
        }
        let class_names: Vec<String> = classes.keys().cloned().collect();

        // Third pass: members.
        for (name, mut ci) in classes {
            let mut seen_methods: HashMap<String, usize> = HashMap::new();
            for (di, cd) in ci.decls.iter().enumerate() {
                let mut header: Option<String> = None;
                for m in &cd.members {
                    match m {
                        Member::Field(fd) => {
                            if let Some(h) = fd.attr("Header").and_then(|a| a.args.first()).and_then(|a| a.string_value.clone()) {
                                header = Some(h);
                            }
                            let ty = prog.resolve_type_ref_with(&fd.ty, &class_names);
                            for d in &fd.declarators {
                                let synced_attr = fd.attr("UdonSynced");
                                let serialize_field = fd.has_attr("SerializeField");
                                let non_serialized = fd.has_attr("NonSerialized") || fd.has_attr("System.NonSerialized") || fd.has_attr("NonSerializedAttribute");
                                let is_public = fd.is_public();
                                let sync_mode = synced_attr.and_then(|a| a.args.first()).map(|a| a.text.rsplit('.').next().unwrap_or("").to_string());
                                ci.fields.push(FieldInfo {
                                    name: d.name.clone(),
                                    gd_name: mangle(&d.name),
                                    ty: ty.clone(),
                                    is_public,
                                    is_static: fd.is_static(),
                                    is_const: fd.is_const(),
                                    is_readonly: fd.modifiers.contains(&Modifier::Readonly),
                                    synced: synced_attr.is_some(),
                                    sync_mode,
                                    serialized: !fd.is_static() && !fd.is_const() && !non_serialized && (is_public || serialize_field),
                                    hide_in_inspector: fd.has_attr("HideInInspector"),
                                    change_callback: fd.attr("FieldChangeCallback").and_then(|a| a.args.first()).and_then(|a| a.string_value.clone()),
                                    tooltip: fd.attr("Tooltip").and_then(|a| a.args.first()).and_then(|a| a.string_value.clone()),
                                    header: header.take(),
                                    init: d.init.clone(),
                                    doc: fd.doc.clone(),
                                    span: d.span,
                                });
                            }
                        }
                        Member::Property(pd) => {
                            let ty = prog.resolve_type_ref_with(&pd.ty, &class_names);
                            ci.props.push(PropInfo {
                                name: pd.name.clone(),
                                gd_name: mangle(&pd.name),
                                ty,
                                is_static: pd.is_static(),
                                is_public: pd.modifiers.contains(&Modifier::Public),
                                decl: pd.clone(),
                            });
                        }
                        Member::Method(md) => {
                            let params: Vec<ParamSig> = md
                                .params
                                .iter()
                                .map(|p| ParamSig {
                                    name: p.name.clone(),
                                    gd_name: crate::names::mangle_local(&p.name),
                                    ty: prog.resolve_type_ref_with(&p.ty, &class_names),
                                    mode: p.mode,
                                    default: p.default.clone(),
                                })
                                .collect();
                            let key = format!("{}/{}", md.name, params.len());
                            if let Some(prev) = seen_methods.get(&key) {
                                // Overloads with the same arity are ambiguous in GDScript; keep the first and warn.
                                let prev_m = &ci.methods[*prev];
                                if prev_m.params.iter().map(|p| &p.ty).ne(params.iter().map(|p| &p.ty)) {
                                    diags.warn(md.span, format!("method `{}.{}` is overloaded with the same arity; GDScript cannot overload, the later definition is renamed `{}_{}`", name, md.name, md.name, params.len()));
                                }
                            }
                            let overload_count = ci.methods.iter().filter(|m| m.name == md.name).count();
                            let gd_name = if overload_count == 0 { mangle(&md.name) } else { format!("{}_{}", mangle(&md.name), overload_count + 1) };
                            seen_methods.insert(key, ci.methods.len());
                            ci.methods.push(MethodInfo {
                                name: md.name.clone(),
                                gd_name,
                                params,
                                ret: prog.resolve_type_ref_with(&md.ret, &class_names),
                                is_static: md.is_static(),
                                is_override: md.is_override(),
                                is_public: md.is_public(),
                                network_callable: md.has_attr("NetworkCallable"),
                                recursive: md.has_attr("RecursiveMethod"),
                                decl: md.clone(),
                                decl_index: di,
                            });
                        }
                        Member::Constructor(cd2) => {
                            diags.warn(cd2.span, format!("constructor in `{}` ignored: Udon behaviours cannot declare constructors", name));
                        }
                        Member::Type(_) => {}
                    }
                }
            }
            prog.class_index.insert(name.clone(), prog.classes.len());
            prog.classes.push(ci);
        }
        prog
    }

    pub fn class(&self, name: &str) -> Option<&ClassInfo> {
        self.class_index.get(name).map(|i| &self.classes[*i])
    }

    pub fn user_enum(&self, name: &str) -> Option<&UserEnum> {
        if let Some(i) = self.enum_index.get(name) {
            return Some(&self.enums[*i]);
        }
        // suffix match `Owner.Name`
        let short = name.rsplit('.').next().unwrap_or(name);
        self.enum_index.get(short).map(|i| &self.enums[*i])
    }

    pub fn is_user_class(&self, name: &str) -> bool {
        self.class_index.contains_key(name)
    }

    /// Walk the user class chain (inclusive).
    pub fn class_chain(&self, name: &str) -> Vec<&ClassInfo> {
        let mut out = Vec::new();
        let mut cur = self.class(name);
        let mut guard = 0;
        while let Some(c) = cur {
            out.push(c);
            guard += 1;
            if guard > 32 {
                break;
            }
            cur = c.base.as_deref().and_then(|b| self.class(b));
        }
        out
    }

    /// The catalog type that a user class ultimately derives from (e.g. `UdonSharpBehaviour`).
    pub fn catalog_base_of_class(&self, name: &str) -> Option<&TypeInfo> {
        let chain = self.class_chain(name);
        let last = chain.last()?;
        let b = last.base.as_deref()?;
        self.catalog.get(b)
    }

    /// Look up a field/property/method in a user class or its user bases.
    pub fn find_field(&self, class: &str, member: &str) -> Option<(&ClassInfo, &FieldInfo)> {
        for c in self.class_chain(class) {
            if let Some(f) = c.field(member) {
                return Some((c, f));
            }
        }
        None
    }

    pub fn find_prop(&self, class: &str, member: &str) -> Option<(&ClassInfo, &PropInfo)> {
        for c in self.class_chain(class) {
            if let Some(p) = c.prop(member) {
                return Some((c, p));
            }
        }
        None
    }

    pub fn find_methods(&self, class: &str, member: &str) -> Vec<&MethodInfo> {
        let mut out = Vec::new();
        for c in self.class_chain(class) {
            out.extend(c.methods_named(member));
        }
        out
    }

    /// Resolve a syntactic type reference: user classes and enums, then the catalog.
    pub fn resolve_type_ref(&self, t: &TypeRef) -> Ty {
        let names: Vec<String> = self.class_index.keys().cloned().collect();
        self.resolve_type_ref_with(t, &names)
    }

    fn resolve_type_ref_with(&self, t: &TypeRef, class_names: &[String]) -> Ty {
        let ty = ty_from_ref(t);
        self.canonicalize_ty(&ty, class_names)
    }

    fn canonicalize_ty(&self, ty: &Ty, class_names: &[String]) -> Ty {
        match ty {
            Ty::Named(n) => {
                if class_names.iter().any(|c| c == n) {
                    return Ty::Named(n.clone());
                }
                // nested user type `Outer.Inner`
                let short = n.rsplit('.').next().unwrap_or(n);
                if class_names.iter().any(|c| c == short) {
                    return Ty::Named(short.to_string());
                }
                if let Some(e) = self.user_enum(n) {
                    return Ty::Named(e.name.clone());
                }
                if let Some(c) = self.catalog.resolve_name(n) {
                    return Ty::Named(c.to_string());
                }
                Ty::Named(n.clone())
            }
            Ty::Array(e) => Ty::Array(Box::new(self.canonicalize_ty(e, class_names))),
            Ty::MultiArray(e, r) => Ty::MultiArray(Box::new(self.canonicalize_ty(e, class_names)), *r),
            other => other.clone(),
        }
    }

    /// GDScript type hint for a semantic type.
    pub fn gd_type(&self, ty: &Ty) -> Option<String> {
        Some(match ty {
            Ty::Void => return None,
            Ty::Bool => "bool".into(),
            Ty::Int | Ty::UInt | Ty::Long | Ty::ULong | Ty::Short | Ty::UShort | Ty::Byte | Ty::SByte => "int".into(),
            Ty::Float | Ty::Double | Ty::Decimal => "float".into(),
            Ty::Char | Ty::String => "String".into(),
            Ty::Object => "Variant".into(),
            Ty::Array(_) | Ty::MultiArray(..) => "Array".into(),
            Ty::Named(n) => {
                if self.is_user_class(n) {
                    "Node".into()
                } else if self.user_enum(n).is_some() {
                    "int".into()
                } else if let Some(t) = self.catalog.get(n) {
                    t.gd.clone()
                } else {
                    return None;
                }
            }
            Ty::Null | Ty::Unknown | Ty::TypeName(_) | Ty::Method(_) => return None,
        })
    }

    /// The Godot class-name string used at run time for `typeof(T)` / `GetComponent<T>()`.
    pub fn runtime_type_name(&self, ty: &Ty) -> String {
        match ty {
            Ty::Named(n) => {
                if self.is_user_class(n) {
                    n.clone()
                } else if let Some(t) = self.catalog.get(n) {
                    // generic Godot classes (Node, Control, CanvasLayer ...) say nothing about the Unity
                    // component; the runtime resolves the Unity name through its alias table instead
                    if t.gd == "Variant" || (matches!(t.gd.as_str(), "Node" | "Control" | "CanvasLayer" | "CanvasItem" | "Container") && t.name != t.gd) {
                        t.name.clone()
                    } else {
                        t.gd.clone()
                    }
                } else {
                    n.clone()
                }
            }
            other => other.name(),
        }
    }

    /// Is this type a UnityEngine.Object-derived reference (component/game object/asset)?
    pub fn is_unity_object(&self, ty: &Ty) -> bool {
        match ty {
            Ty::Named(n) => {
                if self.is_user_class(n) {
                    return true;
                }
                self.catalog.is_a(n, "Object")
            }
            _ => false,
        }
    }

    /// Is this a VRCPlayerApi?
    pub fn is_player(&self, ty: &Ty) -> bool {
        ty.is_named("VRCPlayerApi")
    }

    /// Default value expression source for a declared type (used for uninitialized fields/arrays).
    pub fn default_value(&self, ty: &Ty) -> crate::gd::GExpr {
        use crate::gd::GExpr;
        match ty {
            Ty::Bool => GExpr::Bool(false),
            Ty::Int | Ty::UInt | Ty::Long | Ty::ULong | Ty::Short | Ty::UShort | Ty::Byte | Ty::SByte => GExpr::Int(0),
            Ty::Float | Ty::Double | Ty::Decimal => GExpr::Float(0.0),
            Ty::Char => GExpr::str("\0"),
            Ty::String => GExpr::Null,
            Ty::Named(n) => {
                if self.user_enum(n).is_some() {
                    return GExpr::Int(0);
                }
                if let Some(t) = self.catalog.get(n) {
                    if t.is_enum() {
                        return GExpr::Int(0);
                    }
                    return match t.gd.as_str() {
                        "Vector3" => GExpr::raw("Vector3.ZERO"),
                        "Vector2" => GExpr::raw("Vector2.ZERO"),
                        "Vector4" => GExpr::raw("Vector4.ZERO"),
                        "Vector3i" => GExpr::raw("Vector3i.ZERO"),
                        "Vector2i" => GExpr::raw("Vector2i.ZERO"),
                        "Quaternion" => GExpr::raw("Quaternion()"),
                        "Color" => GExpr::raw("Color(0.0, 0.0, 0.0, 0.0)"),
                        "Transform3D" => GExpr::raw("Transform3D()"),
                        "AABB" => GExpr::raw("AABB()"),
                        "Rect2" => GExpr::raw("Rect2()"),
                        "Plane" => GExpr::raw("Plane()"),
                        "Dictionary" => GExpr::raw("{}"),
                        "int" => GExpr::Int(0),
                        "float" => GExpr::Float(0.0),
                        "bool" => GExpr::Bool(false),
                        "String" => GExpr::Null,
                        _ => GExpr::Null,
                    };
                }
                GExpr::Null
            }
            _ => GExpr::Null,
        }
    }
}

fn collect_enums(td: &TypeDecl, owner: Option<&str>, out: &mut Vec<UserEnum>) {
    match td {
        TypeDecl::Enum(ed) => {
            let mut members = Vec::new();
            let mut next = 0i64;
            for m in &ed.members {
                let v = match &m.value {
                    Some(e) => const_int(e, &members).unwrap_or(next),
                    None => next,
                };
                members.push((m.name.clone(), v));
                next = v + 1;
            }
            out.push(UserEnum { name: ed.name.clone(), owner: owner.map(|s| s.to_string()), members, span: ed.span });
        }
        TypeDecl::Class(cd) => {
            for m in &cd.members {
                if let Member::Type(inner) = m {
                    collect_enums(inner, Some(&cd.name), out);
                }
            }
        }
    }
}

/// Evaluate a constant integer expression used in enum member initializers.
pub fn const_int(e: &Expr, prior: &[(String, i64)]) -> Option<i64> {
    use crate::token::Lit;
    match e.unparen() {
        Expr::Lit(Lit::Int(v), _) | Expr::Lit(Lit::Long(v), _) => Some(*v),
        Expr::Lit(Lit::UInt(v), _) | Expr::Lit(Lit::ULong(v), _) => Some(*v as i64),
        Expr::Unary { op: UnOp::Neg, expr, .. } => const_int(expr, prior).map(|v| -v),
        Expr::Unary { op: UnOp::BitNot, expr, .. } => const_int(expr, prior).map(|v| !v),
        Expr::Binary { op, lhs, rhs, .. } => {
            let a = const_int(lhs, prior)?;
            let b = const_int(rhs, prior)?;
            Some(match op {
                BinOp::Add => a + b,
                BinOp::Sub => a - b,
                BinOp::Mul => a * b,
                BinOp::Div => a.checked_div(b)?,
                BinOp::Rem => a.checked_rem(b)?,
                BinOp::Shl => a << b,
                BinOp::Shr => a >> b,
                BinOp::BitAnd => a & b,
                BinOp::BitOr => a | b,
                BinOp::BitXor => a ^ b,
                _ => return None,
            })
        }
        Expr::Ident(n, _) => prior.iter().find(|(m, _)| m == n).map(|(_, v)| *v),
        Expr::Cast { expr, .. } => const_int(expr, prior),
        Expr::Member { name, .. } => prior.iter().find(|(m, _)| m == name).map(|(_, v)| *v),
        _ => None,
    }
}
