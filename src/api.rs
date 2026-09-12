//! The API catalog: how Unity / VRChat / .NET types and members used by UdonSharp scripts map
//! onto Godot and the `udon_runtime` abstraction layer.
//!
//! The catalog is written in a small line-oriented DSL (see `data/api/*.udon`) and parsed at
//! startup. Grammar:
//!
//! ```text
//! # comment
//! type Name [: Base] [kind=struct|class|enum|static|component|behaviour] [gd=GodotType] [extern=MangledExternName]
//!   [static] name: Type [=> get-template]         # field / property getter (default `$0.name`)
//!   [static] set name: Type => set-template        # property setter; `$v` is the assigned value
//!   [static] Name(T1, T2, ...): Ret [=> template]  # method (default `$0.Name($1, $2)`); overload by param list
//!   ctor(T1, ...) => template                      # constructor
//!   op SYM(T1, T2): Ret => template                # operator (binary), `op -(T): Ret` for unary
//!   cast Type => template                          # explicit conversion `(Type)$0`
//!   enum Name = 3                                  # enum member (kind=enum)
//! alias Other = Name
//! ```
//!
//! Template placeholders: `$0` target/this, `$1..$9` arguments, `$v` assigned value, `$args`
//! all arguments comma-separated, `$T1` first generic type argument rendered as a Godot class
//! string, `$N` the member name. A template of the form `!unsupported message` marks the member
//! as unsupported (converted code gets a warning and a runtime error call). Parameter types may
//! be prefixed with `out`, `ref` or `params`.

use crate::types::Ty;
use std::collections::HashMap;

pub const CATALOG_SOURCES: &[(&str, &str)] = &[
    ("system.udon", include_str!("../data/api/system.udon")),
    ("unity_math.udon", include_str!("../data/api/unity_math.udon")),
    ("unity_core.udon", include_str!("../data/api/unity_core.udon")),
    ("unity_physics.udon", include_str!("../data/api/unity_physics.udon")),
    ("unity_misc.udon", include_str!("../data/api/unity_misc.udon")),
    ("vrc.udon", include_str!("../data/api/vrc.udon")),
    ("system_extra.udon", include_str!("../data/api/system_extra.udon")),
    ("vrc_extra.udon", include_str!("../data/api/vrc_extra.udon")),
    ("unity_2d.udon", include_str!("../data/api/unity_2d.udon")),
    ("unity_extra.udon", include_str!("../data/api/unity_extra.udon")),
    ("unity_particles.udon", include_str!("../data/api/unity_particles.udon")),
    ("unity_ui.udon", include_str!("../data/api/unity_ui.udon")),
    ("enums.udon", include_str!("../data/api/enums.udon")),
];

/// Generated `!stub` entries for every extern the hand-written files do not map
/// (`tools/gen_catalog.py`). Loaded last so hand-written mappings win. Skipped when the
/// environment variable `UDON2GODOT_NO_GENERATED` is set (used by the generator itself).
pub const GENERATED_SOURCE: (&str, &str) = ("generated.udon", include_str!("../data/api/generated.udon"));

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypeKind {
    Struct,
    Class,
    Enum,
    Static,
    Component,
    Behaviour,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PMode {
    Value,
    Out,
    Ref,
    Params,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ParamInfo {
    pub ty: Ty,
    pub mode: PMode,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MemberKind {
    Field,
    Method,
    Ctor,
    Op(String),
    Cast,
}

#[derive(Debug, Clone)]
pub struct MemberInfo {
    pub owner: String,
    pub name: String,
    pub is_static: bool,
    pub kind: MemberKind,
    pub params: Vec<ParamInfo>,
    pub ret: Ty,
    pub get: Option<String>,
    pub set: Option<String>,
    pub unsupported: Option<String>,
    /// A `!stub` mapping: compiles and runs, but only approximates (or ignores) the Unity behaviour.
    pub stub: bool,
    /// A `!stored` mapping: the value round-trips through `U.prop_get/prop_set` but has no engine
    /// effect (reported apart from plain stubs).
    pub stored: bool,
    /// Source line for diagnostics.
    pub line: usize,
}

impl MemberInfo {
    pub fn is_field(&self) -> bool {
        self.kind == MemberKind::Field
    }
    pub fn is_method(&self) -> bool {
        self.kind == MemberKind::Method
    }
    pub fn has_params_array(&self) -> bool {
        self.params.last().map_or(false, |p| p.mode == PMode::Params)
    }
}

#[derive(Debug, Clone)]
pub struct TypeInfo {
    pub name: String,
    pub base: Option<String>,
    pub kind: TypeKind,
    pub gd: String,
    pub extern_name: Option<String>,
    /// Further Udon extern type names mapped onto this catalog type (a re-opened `type` with a
    /// different `extern=`), e.g. `Random` covers UnityEngine.Random and System.Random.
    pub extern_aliases: Vec<String>,
    pub members: Vec<MemberInfo>,
    pub enum_members: Vec<(String, i64)>,
    pub file: String,
}

impl TypeInfo {
    pub fn is_component(&self) -> bool {
        matches!(self.kind, TypeKind::Component | TypeKind::Behaviour)
    }
    pub fn is_enum(&self) -> bool {
        self.kind == TypeKind::Enum
    }
    pub fn enum_value(&self, member: &str) -> Option<i64> {
        self.enum_members.iter().find(|(n, _)| n == member).map(|(_, v)| *v)
    }
}

#[derive(Debug, Default)]
pub struct Catalog {
    types: HashMap<String, TypeInfo>,
    aliases: HashMap<String, String>,
    /// short (last segment) → full names, for nested type lookup
    short_index: HashMap<String, Vec<String>>,
}

#[derive(Debug)]
pub struct CatalogError {
    pub file: String,
    pub line: usize,
    pub message: String,
}

impl std::fmt::Display for CatalogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}: {}", self.file, self.line, self.message)
    }
}

fn split_top_level(s: &str, sep: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut cur = String::new();
    for c in s.chars() {
        match c {
            '(' | '[' | '<' => {
                depth += 1;
                cur.push(c);
            }
            ')' | ']' | '>' => {
                depth -= 1;
                cur.push(c);
            }
            c if c == sep && depth == 0 => {
                out.push(cur.trim().to_string());
                cur.clear();
            }
            c => cur.push(c),
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur.trim().to_string());
    }
    out
}

fn parse_param(s: &str) -> ParamInfo {
    let s = s.trim();
    if let Some(r) = s.strip_prefix("out ") {
        return ParamInfo { ty: Ty::parse(r), mode: PMode::Out };
    }
    if let Some(r) = s.strip_prefix("ref ") {
        return ParamInfo { ty: Ty::parse(r), mode: PMode::Ref };
    }
    if let Some(r) = s.strip_prefix("params ") {
        return ParamInfo { ty: Ty::parse(r), mode: PMode::Params };
    }
    ParamInfo { ty: Ty::parse(s), mode: PMode::Value }
}

impl Catalog {
    pub fn load_embedded() -> Result<Catalog, CatalogError> {
        let mut c = Catalog::default();
        for (name, src) in CATALOG_SOURCES {
            c.parse_source(name, src)?;
        }
        if std::env::var_os("UDON2GODOT_NO_GENERATED").is_none() {
            c.parse_source(GENERATED_SOURCE.0, GENERATED_SOURCE.1)?;
        }
        c.rebuild_index();
        Ok(c)
    }

    pub fn from_sources(sources: &[(&str, &str)]) -> Result<Catalog, CatalogError> {
        let mut c = Catalog::default();
        for (name, src) in sources {
            c.parse_source(name, src)?;
        }
        c.rebuild_index();
        Ok(c)
    }

    fn rebuild_index(&mut self) {
        self.short_index.clear();
        for name in self.types.keys() {
            let short = name.rsplit('.').next().unwrap_or(name).to_string();
            self.short_index.entry(short).or_default().push(name.clone());
        }
    }

    pub fn parse_source(&mut self, file: &str, src: &str) -> Result<(), CatalogError> {
        let err = |line: usize, m: String| CatalogError { file: file.to_string(), line, message: m };
        let mut current: Option<String> = None;
        for (i, raw) in src.lines().enumerate() {
            let lineno = i + 1;
            let line = match raw.find('#') {
                Some(p) if !raw[..p].contains('"') => &raw[..p],
                _ => raw,
            };
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let indented = line.starts_with(' ') || line.starts_with('\t');
            if !indented {
                if let Some(rest) = trimmed.strip_prefix("type ") {
                    let ti = Self::parse_type_header(rest, file, lineno)?;
                    current = Some(ti.name.clone());
                    if let Some(existing) = self.types.get_mut(&ti.name) {
                        // Allow re-opening a type to add members.
                        if existing.base.is_none() {
                            existing.base = ti.base;
                        }
                        if existing.extern_name.is_none() {
                            existing.extern_name = ti.extern_name;
                        } else if let Some(e) = ti.extern_name {
                            if existing.extern_name.as_deref() != Some(e.as_str()) && !existing.extern_aliases.contains(&e) {
                                existing.extern_aliases.push(e);
                            }
                        }
                    } else {
                        self.types.insert(ti.name.clone(), ti);
                    }
                    continue;
                }
                if let Some(rest) = trimmed.strip_prefix("alias ") {
                    let (a, b) = rest.split_once('=').ok_or_else(|| err(lineno, "alias needs `A = B`".into()))?;
                    self.aliases.insert(a.trim().to_string(), b.trim().to_string());
                    continue;
                }
                return Err(err(lineno, format!("unexpected top-level line: {}", trimmed)));
            }
            let owner = match &current {
                Some(c) => c.clone(),
                None => return Err(err(lineno, "member line outside of a type".into())),
            };
            let m = Self::parse_member_line(trimmed, &owner, file, lineno)?;
            let ti = self.types.get_mut(&owner).unwrap();
            match m {
                Parsed::Member(mut mi) => {
                    // `set name` merges into an existing field of the same name.
                    if let Some(setter) = mi.set.take() {
                        if let Some(existing) = ti.members.iter_mut().find(|e| e.name == mi.name && e.is_field() && e.is_static == mi.is_static) {
                            existing.set = Some(setter);
                            continue;
                        }
                        mi.set = Some(setter);
                        mi.get = None;
                    }
                    ti.members.push(mi);
                }
                Parsed::Enum(name, v) => ti.enum_members.push((name, v)),
            }
        }
        Ok(())
    }

    fn parse_type_header(rest: &str, file: &str, lineno: usize) -> Result<TypeInfo, CatalogError> {
        // Name [: Base] key=value...
        let mut parts = rest.split_whitespace();
        let name = parts.next().ok_or_else(|| CatalogError { file: file.into(), line: lineno, message: "type needs a name".into() })?.to_string();
        let mut base = None;
        let mut kind = TypeKind::Class;
        let mut gd = None;
        let mut extern_name = None;
        let mut expect_base = false;
        for p in parts {
            if p == ":" {
                expect_base = true;
                continue;
            }
            if expect_base {
                base = Some(p.to_string());
                expect_base = false;
                continue;
            }
            if let Some(v) = p.strip_prefix("kind=") {
                kind = match v {
                    "struct" => TypeKind::Struct,
                    "class" => TypeKind::Class,
                    "enum" => TypeKind::Enum,
                    "static" => TypeKind::Static,
                    "component" => TypeKind::Component,
                    "behaviour" => TypeKind::Behaviour,
                    other => return Err(CatalogError { file: file.into(), line: lineno, message: format!("unknown kind `{}`", other) }),
                };
            } else if let Some(v) = p.strip_prefix("gd=") {
                gd = Some(v.to_string());
            } else if let Some(v) = p.strip_prefix("extern=") {
                extern_name = Some(v.to_string());
            } else if let Some(b) = p.strip_prefix(':') {
                base = Some(b.to_string());
            } else {
                return Err(CatalogError { file: file.into(), line: lineno, message: format!("unexpected `{}` in type header", p) });
            }
        }
        let gd = gd.unwrap_or_else(|| match kind {
            TypeKind::Enum => "int".into(),
            TypeKind::Component | TypeKind::Behaviour => "Node".into(),
            _ => "Variant".into(),
        });
        Ok(TypeInfo { name, base, kind, gd, extern_name, extern_aliases: vec![], members: vec![], enum_members: vec![], file: file.into() })
    }

    fn parse_member_line(line: &str, owner: &str, file: &str, lineno: usize) -> Result<Parsed, CatalogError> {
        let err = |m: String| CatalogError { file: file.to_string(), line: lineno, message: m };
        let (head, template) = match line.find("=>") {
            Some(p) => (line[..p].trim(), Some(line[p + 2..].trim().to_string())),
            None => (line.trim(), None),
        };
        let (unsupported, template) = match &template {
            Some(t) if t.starts_with("!unsupported") => (Some(t.trim_start_matches("!unsupported").trim().to_string()), None),
            _ => (None, template),
        };
        let (stored, template) = match &template {
            Some(t) if t.starts_with("!stored") => (true, Some(t.trim_start_matches("!stored").trim().to_string())),
            _ => (false, template),
        };
        let (stub, template) = match &template {
            Some(t) if t.starts_with("!stub") => (true, Some(t.trim_start_matches("!stub").trim().to_string())),
            _ => (stored, template),
        };
        let mut head = head;
        // enum member
        if let Some(rest) = head.strip_prefix("enum ") {
            let (n, v) = rest.split_once('=').ok_or_else(|| err("enum member needs `= value`".into()))?;
            let v = v.trim();
            let val = if let Some(h) = v.strip_prefix("0x") { i64::from_str_radix(h, 16) } else { v.parse::<i64>() }.map_err(|_| err(format!("bad enum value `{}`", v)))?;
            return Ok(Parsed::Enum(n.trim().to_string(), val));
        }
        let mut is_static = false;
        if let Some(r) = head.strip_prefix("static ") {
            is_static = true;
            head = r.trim();
        }
        let mut is_set = false;
        if let Some(r) = head.strip_prefix("set ") {
            is_set = true;
            head = r.trim();
        }
        // ctor
        if let Some(r) = head.strip_prefix("ctor") {
            let r = r.trim();
            let inner = r.strip_prefix('(').and_then(|x| x.strip_suffix(')')).ok_or_else(|| err("ctor needs (params)".into()))?;
            let params = if inner.trim().is_empty() { vec![] } else { split_top_level(inner, ',').iter().map(|p| parse_param(p)).collect() };
            let tmpl = template.clone().or_else(|| if unsupported.is_some() { None } else { Some(String::new()) });
            return Ok(Parsed::Member(MemberInfo {
                owner: owner.into(),
                name: "ctor".into(),
                is_static: true,
                kind: MemberKind::Ctor,
                params,
                ret: Ty::parse(owner),
                get: tmpl,
                set: None,
                unsupported,
                stub,
                stored,
                line: lineno,
            }));
        }
        // op
        if let Some(r) = head.strip_prefix("op ") {
            let r = r.trim();
            let p = r.find('(').ok_or_else(|| err("op needs (params)".into()))?;
            let sym = r[..p].trim().to_string();
            let close = r.rfind(')').ok_or_else(|| err("op needs )".into()))?;
            let inner = &r[p + 1..close];
            let params: Vec<ParamInfo> = split_top_level(inner, ',').iter().map(|p| parse_param(p)).collect();
            let ret = r[close + 1..].trim().strip_prefix(':').map(|s| Ty::parse(s.trim())).unwrap_or(Ty::Unknown);
            return Ok(Parsed::Member(MemberInfo {
                owner: owner.into(),
                name: format!("op{}", sym),
                is_static: true,
                kind: MemberKind::Op(sym),
                params,
                ret,
                get: template,
                set: None,
                unsupported,
                stub,
                stored,
                line: lineno,
            }));
        }
        // cast
        if let Some(r) = head.strip_prefix("cast ") {
            return Ok(Parsed::Member(MemberInfo {
                owner: owner.into(),
                name: format!("cast {}", r.trim()),
                is_static: false,
                kind: MemberKind::Cast,
                params: vec![],
                ret: Ty::parse(r.trim()),
                get: template,
                set: None,
                unsupported,
                stub,
                stored,
                line: lineno,
            }));
        }
        // method: Name(params): Ret
        if let Some(p) = head.find('(') {
            let name = head[..p].trim().to_string();
            let close = head.rfind(')').ok_or_else(|| err("method needs )".into()))?;
            let inner = &head[p + 1..close];
            let params: Vec<ParamInfo> = if inner.trim().is_empty() { vec![] } else { split_top_level(inner, ',').iter().map(|p| parse_param(p)).collect() };
            let ret = head[close + 1..].trim().strip_prefix(':').map(|s| Ty::parse(s.trim())).unwrap_or(Ty::Void);
            return Ok(Parsed::Member(MemberInfo {
                owner: owner.into(),
                name,
                is_static,
                kind: MemberKind::Method,
                params,
                ret,
                get: template,
                set: None,
                unsupported,
                stub,
                stored,
                line: lineno,
            }));
        }
        // field: name: Type
        let (name, ty) = head.split_once(':').ok_or_else(|| err(format!("cannot parse member line `{}`", line)))?;
        let name = name.trim().to_string();
        let ty = Ty::parse(ty.trim());
        if is_set {
            return Ok(Parsed::Member(MemberInfo {
                owner: owner.into(),
                name,
                is_static,
                kind: MemberKind::Field,
                params: vec![],
                ret: ty,
                get: None,
                set: Some(template.unwrap_or_default()),
                unsupported,
                stub,
                stored,
                line: lineno,
            }));
        }
        Ok(Parsed::Member(MemberInfo { owner: owner.into(), name, is_static, kind: MemberKind::Field, params: vec![], ret: ty, get: template, set: None, unsupported, stub, stored, line: lineno }))
    }

    // ----- lookup -----

    /// Resolve a canonical type name (after namespace stripping) to a catalog type.
    /// Tries exact, alias, and nested-name suffix match (`TrackingDataType` → `VRCPlayerApi.TrackingDataType`).
    pub fn resolve_name(&self, name: &str) -> Option<&str> {
        if let Some(t) = self.types.get(name) {
            return Some(&t.name);
        }
        if let Some(a) = self.aliases.get(name) {
            return self.resolve_name(a);
        }
        let short = name.rsplit('.').next().unwrap_or(name);
        if name.contains('.') {
            // `Owner.Nested` where Owner is an alias
            if let Some((owner, nested)) = name.rsplit_once('.') {
                if let Some(o) = self.aliases.get(owner) {
                    let full = format!("{}.{}", o, nested);
                    if let Some(t) = self.types.get(&full) {
                        return Some(&t.name);
                    }
                }
            }
            // A dotted path must match a full name or a `.`-delimited suffix of one.
            if let Some(v) = self.short_index.get(short) {
                for full in v {
                    if full == name || full.ends_with(&format!(".{}", name)) {
                        return Some(full.as_str());
                    }
                }
            }
            return None;
        }
        if let Some(v) = self.short_index.get(short) {
            if v.len() == 1 {
                return Some(v[0].as_str());
            }
            for full in v {
                if full == name {
                    return Some(full.as_str());
                }
            }
            return Some(v[0].as_str());
        }
        None
    }

    pub fn get(&self, name: &str) -> Option<&TypeInfo> {
        let n = self.resolve_name(name)?;
        self.types.get(n)
    }

    pub fn types(&self) -> impl Iterator<Item = &TypeInfo> {
        self.types.values()
    }

    /// Walk the base chain starting at `name` (inclusive).
    pub fn chain(&self, name: &str) -> Vec<&TypeInfo> {
        let mut out = Vec::new();
        let mut cur = self.get(name);
        let mut guard = 0;
        while let Some(t) = cur {
            out.push(t);
            guard += 1;
            if guard > 32 {
                break;
            }
            cur = t.base.as_deref().and_then(|b| self.get(b));
        }
        out
    }

    /// Is `name` (or a base of it) the type `ancestor`?
    pub fn is_a(&self, name: &str, ancestor: &str) -> bool {
        let anc = match self.resolve_name(ancestor) {
            Some(a) => a.to_string(),
            None => return false,
        };
        self.chain(name).iter().any(|t| t.name == anc)
    }

    /// Find members named `member` on `type_name` or its bases.
    pub fn members(&self, type_name: &str, member: &str) -> Vec<&MemberInfo> {
        let mut out = Vec::new();
        for t in self.chain(type_name) {
            for m in &t.members {
                if m.name == member {
                    out.push(m);
                }
            }
        }
        out
    }

    /// Field/property for reading: prefers a member with a getter (or a plain field) over a
    /// setter-only entry that a derived type may add (e.g. a generated `set bounds` stub).
    pub fn field(&self, type_name: &str, member: &str, is_static: bool) -> Option<&MemberInfo> {
        let cands: Vec<&MemberInfo> = self.members(type_name, member).into_iter().filter(|m| m.is_field() && m.is_static == is_static).collect();
        cands.iter().copied().find(|m| m.get.is_some() || m.set.is_none()).or_else(|| cands.first().copied())
    }

    /// Field/property for writing: prefers a member with a setter template.
    pub fn field_for_write(&self, type_name: &str, member: &str, is_static: bool) -> Option<&MemberInfo> {
        let cands: Vec<&MemberInfo> = self.members(type_name, member).into_iter().filter(|m| m.is_field() && m.is_static == is_static).collect();
        cands.iter().copied().find(|m| m.set.is_some() || m.get.is_none()).or_else(|| cands.first().copied())
    }

    pub fn ctors(&self, type_name: &str) -> Vec<&MemberInfo> {
        self.get(type_name).map(|t| t.members.iter().filter(|m| m.kind == MemberKind::Ctor).collect()).unwrap_or_default()
    }

    pub fn operators(&self, type_name: &str, sym: &str) -> Vec<&MemberInfo> {
        let mut out = Vec::new();
        for t in self.chain(type_name) {
            for m in &t.members {
                if let MemberKind::Op(s) = &m.kind {
                    if s == sym {
                        out.push(m);
                    }
                }
            }
        }
        out
    }

    pub fn cast(&self, from: &str, to: &Ty) -> Option<&MemberInfo> {
        for t in self.chain(from) {
            for m in &t.members {
                if m.kind == MemberKind::Cast && &m.ret == to {
                    return Some(m);
                }
            }
        }
        None
    }

    /// Choose the best overload of a method for the given argument types.
    /// Returns the member and a score (lower is better); `None` if no candidate has the right arity.
    pub fn resolve_method<'a>(&'a self, candidates: &[&'a MemberInfo], arg_types: &[Ty]) -> Option<&'a MemberInfo> {
        let mut best: Option<(&MemberInfo, u32)> = None;
        for m in candidates {
            let score = match score_params(&m.params, arg_types) {
                Some(s) => s,
                None => continue,
            };
            match best {
                Some((_, bs)) if bs <= score => {}
                _ => best = Some((m, score)),
            }
        }
        best.map(|(m, _)| m)
    }
}

enum Parsed {
    Member(MemberInfo),
    Enum(String, i64),
}

/// Score how well `args` match `params`; `None` = not applicable.
pub fn score_params(params: &[ParamInfo], args: &[Ty]) -> Option<u32> {
    let has_params = params.last().map_or(false, |p| p.mode == PMode::Params);
    if !has_params && params.len() != args.len() {
        return None;
    }
    if has_params && args.len() < params.len() - 1 {
        return None;
    }
    let mut score = 0u32;
    for (i, a) in args.iter().enumerate() {
        let p = if has_params && i >= params.len() - 1 {
            let last = params.last().unwrap();
            // params T[]: accept elements of T or a single T[]
            if i == params.len() - 1 && args.len() == params.len() && a == &last.ty {
                continue;
            }
            match &last.ty {
                Ty::Array(e) => ParamInfo { ty: (**e).clone(), mode: PMode::Value },
                _ => last.clone(),
            }
        } else {
            params[i].clone()
        };
        score += match conversion_cost(a, &p.ty) {
            Some(c) => c,
            None => return None,
        };
    }
    if has_params {
        score += 1;
    }
    Some(score)
}

/// Cost of converting an argument of type `from` to a parameter of type `to`.
/// Godot built-in value types (never null in GDScript).
pub fn is_godot_value_type(gd: &str) -> bool {
    matches!(gd, "int" | "float" | "bool" | "Vector2" | "Vector2i" | "Vector3" | "Vector3i" | "Vector4" | "Vector4i" | "Quaternion" | "Color" | "Basis" | "Transform2D" | "Transform3D" | "AABB" | "Rect2" | "Rect2i" | "Plane" | "Projection")
}

pub fn conversion_cost(from: &Ty, to: &Ty) -> Option<u32> {
    use Ty::*;
    if from == to {
        return Some(0);
    }
    match (from, to) {
        (Unknown, _) | (_, Unknown) => Some(3),
        (Null, Named(_)) | (Null, String) | (Null, Object) | (Null, Array(_)) => Some(1),
        (_, Object) => Some(6),
        // integer widening
        (Byte | SByte | Short | UShort | Char, Int) => Some(1),
        (Byte | SByte | Short | UShort | Char | Int | UInt, Long) => Some(2),
        (Byte | UShort | UInt, ULong) => Some(2),
        (Byte, Short) | (Byte, UShort) | (SByte, Short) | (UShort, UInt) => Some(1),
        (Int, UInt) | (UInt, Int) => Some(3),
        // narrowing from int: C# allows it for constants, which is what compiled Udon code passes
        (Int, Byte) | (Int, SByte) | (Int, Short) | (Int, UShort) | (Int, Char) => Some(4),
        (Long, Int) | (Long, UInt) => Some(5),
        // to float/double
        (Byte | SByte | Short | UShort | Char | Int | UInt | Long | ULong, Float) => Some(2),
        (Byte | SByte | Short | UShort | Char | Int | UInt | Long | ULong | Float, Double) => Some(2),
        (Double, Float) => Some(4),
        // enums and ints are interchangeable-ish for overload purposes
        (Named(_), Int) | (Int, Named(_)) => Some(5),
        // component/class up-casts: accept named → named at a cost (the caller may check is_a)
        (Named(_), Named(_)) => Some(4),
        (Array(_), Array(_)) => Some(4),
        (Named(_), Array(_)) | (Array(_), Named(_)) => None,
        (String, Named(_)) | (Named(_), String) => None,
        (Bool, Named(_)) | (Named(_), Bool) => None,
        (Bool, _) | (_, Bool) => None,
        (String, _) | (_, String) => None,
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_small_catalog() {
        let src = r#"
type Vector3 kind=struct gd=Vector3 extern=UnityEngineVector3
  x: float
  magnitude: float => $0.length()
  static zero: Vector3 => Vector3.ZERO
  static Dot(Vector3, Vector3): float => $1.dot($2)
  static Lerp(Vector3, Vector3, float): Vector3 => $1.lerp($2, clampf($3, 0.0, 1.0))
  Normalize(): void => $0 = $0.normalized()
  ctor(float, float, float) => Vector3($1, $2, $3)
  op +(Vector3, Vector3): Vector3 => $1 + $2
  op *(Vector3, float): Vector3 => $1 * $2
  op *(float, Vector3): Vector3 => $1 * $2
type Component kind=component gd=Node extern=UnityEngineComponent
  name: string => $0.name
  set name: string => $0.name = $v
  transform: Transform => $0
type Transform : Component kind=component gd=Node3D extern=UnityEngineTransform
  position: Vector3 => $0.global_position
  set position: Vector3 => $0.global_position = $v
  Translate(Vector3): void => $0.global_translate($1)
  Translate(float, float, float): void => $0.global_translate(Vector3($1, $2, $3))
type TrackingDataType kind=enum extern=VRCSDKBaseVRCPlayerApiTrackingDataType
  enum Head = 0
  enum LeftHand = 1
alias VRCPlayerApi.TrackingDataType = TrackingDataType
"#;
        let c = Catalog::from_sources(&[("t.udon", src)]).unwrap();
        let v = c.get("Vector3").unwrap();
        assert_eq!(v.kind, TypeKind::Struct);
        assert_eq!(c.field("Vector3", "magnitude", false).unwrap().get.as_deref(), Some("$0.length()"));
        assert!(c.field("Vector3", "zero", true).is_some());
        let dots = c.members("Vector3", "Dot");
        assert_eq!(dots.len(), 1);
        let m = c.resolve_method(&dots, &[Ty::Named("Vector3".into()), Ty::Named("Vector3".into())]).unwrap();
        assert_eq!(m.ret, Ty::Float);
        let tr = c.members("Transform", "Translate");
        assert_eq!(tr.len(), 2);
        let chosen = c.resolve_method(&tr, &[Ty::Int, Ty::Float, Ty::Float]).unwrap();
        assert_eq!(chosen.params.len(), 3);
        // inherited member
        assert!(c.field("Transform", "name", false).is_some());
        assert_eq!(c.field("Transform", "position", false).unwrap().set.as_deref(), Some("$0.global_position = $v"));
        assert!(c.is_a("Transform", "Component"));
        assert_eq!(c.get("VRCPlayerApi.TrackingDataType").unwrap().enum_value("LeftHand"), Some(1));
        assert_eq!(c.operators("Vector3", "*").len(), 2);
        assert_eq!(c.ctors("Vector3").len(), 1);
    }
}

#[cfg(test)]
mod embedded_tests {
    use super::*;

    #[test]
    fn embedded_catalog_loads() {
        let c = Catalog::load_embedded().unwrap_or_else(|e| panic!("catalog error: {}", e));
        let ntypes = c.types().count();
        let nmembers: usize = c.types().map(|t| t.members.len() + t.enum_members.len()).sum();
        assert!(ntypes > 100, "types: {}", ntypes);
        assert!(nmembers > 1000, "members: {}", nmembers);
        assert!(c.get("VRCPlayerApi").is_some());
        assert!(c.get("VRC.SDKBase.VRCPlayerApi.TrackingDataType").is_some() || c.get("VRCPlayerApi.TrackingDataType").is_some());
        assert!(c.get("VRCPickup").is_some());
        assert!(c.is_a("UdonSharpBehaviour", "Component"));
        assert!(c.is_a("Rigidbody", "Object"));
        assert!(c.field("Transform", "position", false).unwrap().set.is_some());
        assert!(c.members("Physics", "Raycast").len() > 5);
        eprintln!("catalog: {} types, {} members", ntypes, nmembers);
    }
}
