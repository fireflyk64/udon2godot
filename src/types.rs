//! Semantic type model shared by the API catalog, type inference and lowering.

use crate::ast::TypeRef;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Ty {
    Void,
    Bool,
    Int,
    UInt,
    Long,
    ULong,
    Short,
    UShort,
    Byte,
    SByte,
    Float,
    Double,
    Decimal,
    Char,
    String,
    Object,
    /// A catalog or user class/struct/enum by canonical name (`Vector3`, `VRCPlayerApi`, `MyBehaviour`).
    Named(String),
    /// One-dimensional array.
    Array(Box<Ty>),
    /// Multi-dimensional rectangular array `T[,]`.
    MultiArray(Box<Ty>, u32),
    /// The `null` literal.
    Null,
    /// An expression naming a type (target of static member access).
    TypeName(String),
    /// A method group / callable name (only used transiently).
    Method(String),
    /// Type inference failed.
    Unknown,
}

impl Ty {
    pub fn is_void(&self) -> bool {
        matches!(self, Ty::Void)
    }
    pub fn is_numeric(&self) -> bool {
        matches!(
            self,
            Ty::Int | Ty::UInt | Ty::Long | Ty::ULong | Ty::Short | Ty::UShort | Ty::Byte | Ty::SByte | Ty::Float | Ty::Double | Ty::Decimal | Ty::Char
        )
    }
    pub fn is_integral(&self) -> bool {
        matches!(self, Ty::Int | Ty::UInt | Ty::Long | Ty::ULong | Ty::Short | Ty::UShort | Ty::Byte | Ty::SByte | Ty::Char)
    }
    pub fn is_real(&self) -> bool {
        matches!(self, Ty::Float | Ty::Double | Ty::Decimal)
    }
    pub fn is_string(&self) -> bool {
        matches!(self, Ty::String)
    }
    pub fn is_bool(&self) -> bool {
        matches!(self, Ty::Bool)
    }
    pub fn is_array(&self) -> bool {
        matches!(self, Ty::Array(_) | Ty::MultiArray(..))
    }
    pub fn is_unknown(&self) -> bool {
        matches!(self, Ty::Unknown)
    }
    pub fn elem(&self) -> Option<&Ty> {
        match self {
            Ty::Array(e) | Ty::MultiArray(e, _) => Some(e),
            _ => None,
        }
    }
    pub fn named(&self) -> Option<&str> {
        match self {
            Ty::Named(n) => Some(n),
            _ => None,
        }
    }
    pub fn is_named(&self, n: &str) -> bool {
        matches!(self, Ty::Named(x) if x == n)
    }
    /// Godot vector-like value types that have `x`/`y`/`z` components and math methods.
    pub fn is_vector(&self) -> bool {
        matches!(self, Ty::Named(n) if n == "Vector3" || n == "Vector2" || n == "Vector4" || n == "Vector3Int" || n == "Vector2Int")
    }

    /// Canonical C# name for display and catalog lookup.
    pub fn name(&self) -> String {
        match self {
            Ty::Void => "void".into(),
            Ty::Bool => "bool".into(),
            Ty::Int => "int".into(),
            Ty::UInt => "uint".into(),
            Ty::Long => "long".into(),
            Ty::ULong => "ulong".into(),
            Ty::Short => "short".into(),
            Ty::UShort => "ushort".into(),
            Ty::Byte => "byte".into(),
            Ty::SByte => "sbyte".into(),
            Ty::Float => "float".into(),
            Ty::Double => "double".into(),
            Ty::Decimal => "decimal".into(),
            Ty::Char => "char".into(),
            Ty::String => "string".into(),
            Ty::Object => "object".into(),
            Ty::Named(n) => n.clone(),
            Ty::Array(e) => format!("{}[]", e.name()),
            Ty::MultiArray(e, r) => format!("{}[{}]", e.name(), ",".repeat((*r - 1) as usize)),
            Ty::Null => "null".into(),
            Ty::TypeName(n) => format!("typeof({})", n),
            Ty::Method(n) => format!("method {}", n),
            Ty::Unknown => "?".into(),
        }
    }

    /// Parse a canonical C# type name (as written in the catalog): `float`, `Vector3[]`, `int[,]`.
    pub fn parse(s: &str) -> Ty {
        let s = s.trim();
        if let Some(inner) = s.strip_suffix("[]") {
            return Ty::Array(Box::new(Ty::parse(inner)));
        }
        if let Some(inner) = s.strip_suffix("[,]") {
            return Ty::MultiArray(Box::new(Ty::parse(inner)), 2);
        }
        if let Some(inner) = s.strip_suffix("[,,]") {
            return Ty::MultiArray(Box::new(Ty::parse(inner)), 3);
        }
        match s {
            "void" | "Void" => Ty::Void,
            "bool" | "Boolean" => Ty::Bool,
            "int" | "Int32" => Ty::Int,
            "uint" | "UInt32" => Ty::UInt,
            "long" | "Int64" => Ty::Long,
            "ulong" | "UInt64" => Ty::ULong,
            "short" | "Int16" => Ty::Short,
            "ushort" | "UInt16" => Ty::UShort,
            "byte" | "Byte" => Ty::Byte,
            "sbyte" | "SByte" => Ty::SByte,
            "float" | "Single" => Ty::Float,
            "double" | "Double" => Ty::Double,
            "decimal" | "Decimal" => Ty::Decimal,
            "char" | "Char" => Ty::Char,
            "string" | "String" => Ty::String,
            "object" | "Object" => Ty::Object,
            "?" => Ty::Unknown,
            other => Ty::Named(other.to_string()),
        }
    }

    /// Mangled name used by Udon extern signatures for this type, given the catalog's
    /// extern name for named types (e.g. `Vector3` → `UnityEngineVector3`).
    pub fn extern_name(&self, resolve_named: &dyn Fn(&str) -> Option<String>) -> Option<String> {
        Some(match self {
            Ty::Void => "SystemVoid".into(),
            Ty::Bool => "SystemBoolean".into(),
            Ty::Int => "SystemInt32".into(),
            Ty::UInt => "SystemUInt32".into(),
            Ty::Long => "SystemInt64".into(),
            Ty::ULong => "SystemUInt64".into(),
            Ty::Short => "SystemInt16".into(),
            Ty::UShort => "SystemUInt16".into(),
            Ty::Byte => "SystemByte".into(),
            Ty::SByte => "SystemSByte".into(),
            Ty::Float => "SystemSingle".into(),
            Ty::Double => "SystemDouble".into(),
            Ty::Decimal => "SystemDecimal".into(),
            Ty::Char => "SystemChar".into(),
            Ty::String => "SystemString".into(),
            Ty::Object => "SystemObject".into(),
            Ty::Named(n) => resolve_named(n)?,
            Ty::Array(e) => format!("{}Array", e.extern_name(resolve_named)?),
            Ty::MultiArray(e, _) => format!("{}Array", e.extern_name(resolve_named)?),
            _ => return None,
        })
    }

    /// The numeric promotion of two operand types under C# binary operator rules.
    pub fn binary_numeric(a: &Ty, b: &Ty) -> Ty {
        use Ty::*;
        if matches!(a, Decimal) || matches!(b, Decimal) {
            return Decimal;
        }
        if matches!(a, Double) || matches!(b, Double) {
            return Double;
        }
        if matches!(a, Float) || matches!(b, Float) {
            return Float;
        }
        if matches!(a, ULong) || matches!(b, ULong) {
            return ULong;
        }
        if matches!(a, Long) || matches!(b, Long) {
            return Long;
        }
        if matches!(a, UInt) || matches!(b, UInt) {
            // uint op int → long in C# when int may be negative; approximate as UInt
            if matches!(a, UInt) && matches!(b, UInt) {
                return UInt;
            }
            return Long;
        }
        Int
    }

    /// Result type of unary minus / promotion of small integers.
    pub fn promote(&self) -> Ty {
        match self {
            Ty::Short | Ty::UShort | Ty::Byte | Ty::SByte | Ty::Char => Ty::Int,
            other => other.clone(),
        }
    }

    /// Default value expression in GDScript for a declared type.
    pub fn is_value_struct(&self) -> bool {
        matches!(self, Ty::Named(n) if matches!(n.as_str(), "Vector3" | "Vector2" | "Vector4" | "Quaternion" | "Color" | "Color32" | "Vector3Int" | "Vector2Int" | "Bounds" | "Rect" | "Ray" | "RaycastHit" | "Matrix4x4" | "Plane" | "Color" | "LayerMask" | "Keyframe" | "ContactPoint" | "VRCPlayerApi.TrackingData" | "TrackingData"))
    }
}

impl fmt::Display for Ty {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.name())
    }
}

/// Resolve a syntactic type reference to a semantic type. Namespace qualifiers are dropped;
/// the caller resolves user/catalog names.
pub fn ty_from_ref(t: &TypeRef) -> Ty {
    match t {
        TypeRef::Void => Ty::Void,
        TypeRef::Var => Ty::Unknown,
        TypeRef::Nullable(inner) => ty_from_ref(inner),
        TypeRef::Array { elem, rank } => {
            let e = ty_from_ref(elem);
            if *rank == 1 {
                Ty::Array(Box::new(e))
            } else {
                Ty::MultiArray(Box::new(e), *rank)
            }
        }
        TypeRef::Named { name, args } => {
            let base = canonical_type_name(name);
            if !args.is_empty() {
                // Generic types are not supported by Udon (List<T> etc.). Keep the name for diagnostics.
                return Ty::Named(format!("{}<{}>", base, args.iter().map(|a| ty_from_ref(a).name()).collect::<Vec<_>>().join(",")));
            }
            Ty::parse(&base)
        }
    }
}

/// Canonicalize a (possibly namespace-qualified) C# type name to the catalog's short form.
/// `UnityEngine.Vector3` → `Vector3`; `VRC.SDKBase.VRCPlayerApi.TrackingDataType` → `VRCPlayerApi.TrackingDataType`;
/// `VRC.Udon.Common.Interfaces.NetworkEventTarget` → `NetworkEventTarget`; `System.String` → `string`.
pub fn canonical_type_name(name: &str) -> String {
    let parts: Vec<&str> = name.split('.').collect();
    // Known namespace prefixes to strip.
    let ns_prefixes: &[&[&str]] = &[
        &["UnityEngine", "UI"],
        &["UnityEngine", "Animations"],
        &["UnityEngine", "Rendering"],
        &["UnityEngine", "Audio"],
        &["UnityEngine", "Video"],
        &["UnityEngine", "AI"],
        &["UnityEngine"],
        &["VRC", "SDKBase"],
        &["VRC", "SDK3", "Components", "Video"],
        &["VRC", "SDK3", "Components"],
        &["VRC", "SDK3", "Video", "Components", "Base"],
        &["VRC", "SDK3", "Video", "Components"],
        &["VRC", "SDK3", "Video", "Components", "AVPro"],
        &["VRC", "SDK3", "Data"],
        &["VRC", "SDK3", "UdonNetworkCalling"],
        &["VRC", "SDK3", "Persistence"],
        &["VRC", "SDK3", "StringLoading"],
        &["VRC", "SDK3", "Image"],
        &["VRC", "SDK3", "Rendering"],
        &["VRC", "SDK3", "Platform"],
        &["VRC", "SDK3", "Dynamics", "PhysBone", "Components"],
        &["VRC", "SDK3", "Dynamics", "Contact", "Components"],
        &["VRC", "SDK3", "Dynamics", "Constraint", "Components"],
        &["VRC", "SDK3"],
        &["VRC", "Udon", "Common", "Interfaces"],
        &["VRC", "Udon", "Common", "Enums"],
        &["VRC", "Udon", "Common"],
        &["VRC", "Udon"],
        &["VRC"],
        &["System", "Collections", "Generic"],
        &["System"],
        &["TMPro"],
        &["UdonSharp"],
        &["Cinemachine"],
    ];
    let mut rest: &[&str] = &parts;
    let mut longest = 0;
    for pre in ns_prefixes {
        if parts.len() > pre.len() && parts[..pre.len()] == **pre && pre.len() > longest {
            longest = pre.len();
        }
    }
    if longest > 0 {
        rest = &parts[longest..];
    }
    let joined = rest.join(".");
    match joined.as_str() {
        "String" => "string".into(),
        "Int32" => "int".into(),
        "Single" => "float".into(),
        "Boolean" => "bool".into(),
        "Double" => "double".into(),
        "Int64" => "long".into(),
        "UInt32" => "uint".into(),
        "UInt64" => "ulong".into(),
        "Int16" => "short".into(),
        "UInt16" => "ushort".into(),
        "Byte" => "byte".into(),
        "SByte" => "sbyte".into(),
        "Char" => "char".into(),
        "Decimal" => "decimal".into(),
        "Object" if longest > 0 && parts[0] == "System" => "object".into(),
        _ => joined,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_names() {
        assert_eq!(canonical_type_name("UnityEngine.Vector3"), "Vector3");
        assert_eq!(canonical_type_name("VRC.SDKBase.VRCPlayerApi.TrackingDataType"), "VRCPlayerApi.TrackingDataType");
        assert_eq!(canonical_type_name("VRC.Udon.Common.Interfaces.NetworkEventTarget"), "NetworkEventTarget");
        assert_eq!(canonical_type_name("VRC.SDK3.Components.VRCObjectSync"), "VRCObjectSync");
        assert_eq!(canonical_type_name("System.String"), "string");
        assert_eq!(canonical_type_name("Foo"), "Foo");
        assert_eq!(canonical_type_name("UnityEngine.UI.Text"), "Text");
    }

    #[test]
    fn parse_ty() {
        assert_eq!(Ty::parse("float[]"), Ty::Array(Box::new(Ty::Float)));
        assert_eq!(Ty::parse("Vector3"), Ty::Named("Vector3".into()));
        assert_eq!(Ty::parse("int[,]"), Ty::MultiArray(Box::new(Ty::Int), 2));
    }
}
