//! The Udon extern surface (`VRC.Udon.Wrapper.dll` reflected signatures).
//!
//! Signatures have the form `TypeName.__methodName__ArgType1_ArgType2__RetType`, mirroring
//! `Udon.ExternSig` in udonweft. The embedded list is generated from
//! `lean/Udon/KnownExterns/*.lean` (see `data/known_externs.txt`).

use std::collections::{HashMap, HashSet};

/// The embedded list of known extern signatures, one per line.
pub const KNOWN_EXTERNS_TEXT: &str = include_str!("../data/known_externs.txt");

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExternSig {
    pub type_name: String,
    pub method_name: String,
    pub arg_types: Vec<String>,
    pub ret_type: String,
}

impl ExternSig {
    /// Parse `TypeName.__method__Args__Ret`. Mirrors udonweft's `ExternSig.parse`.
    pub fn parse(s: &str) -> Option<ExternSig> {
        if s.is_empty() {
            return None;
        }
        let (type_name, rest) = s.split_once(".__")?;
        if type_name.is_empty() {
            return None;
        }
        let segs: Vec<&str> = rest.split("__").collect();
        if segs.len() < 2 {
            return None;
        }
        let method_name = segs[0];
        if method_name.is_empty() {
            return None;
        }
        let ret_type = *segs.last()?;
        let arg_part = &segs[1..segs.len() - 1];
        let arg_types: Vec<String> = if arg_part.is_empty() {
            vec![]
        } else {
            arg_part
                .iter()
                .flat_map(|ag| {
                    if ag.is_empty() {
                        vec![]
                    } else {
                        // `_` separates arguments, but also sits inside `VRC_Pickup` / `TMP_Dropdown`
                        // (`VRCSDKBaseVRC_PickupPickupHand`): a piece after `...VRC` / `...TMP` that
                        // is not itself a namespace-rooted name continues the previous one.
                        let mut out: Vec<String> = Vec::new();
                        for piece in ag.split('_').filter(|s| !s.is_empty()) {
                            let rooted = ["System", "UnityEngine", "Unity", "VRC", "TMPro", "Cinemachine", "UdonSharp"].iter().any(|r| piece.starts_with(r));
                            match out.last_mut() {
                                Some(prev) if !rooted && (prev.ends_with("VRC") || prev.ends_with("TMP")) => {
                                    prev.push('_');
                                    prev.push_str(piece);
                                }
                                _ => out.push(piece.to_string()),
                            }
                        }
                        out
                    }
                })
                .collect()
        };
        Some(ExternSig { type_name: type_name.to_string(), method_name: method_name.to_string(), arg_types, ret_type: ret_type.to_string() })
    }

    pub fn to_sig_string(&self) -> String {
        format!("{}.__{}__{}__{}", self.type_name, self.method_name, self.arg_types.join("_"), self.ret_type)
    }

    pub fn kind(&self) -> ExternKind {
        if self.method_name.starts_with("get_") {
            ExternKind::PropGet
        } else if self.method_name.starts_with("set_") {
            ExternKind::PropSet
        } else if self.method_name.starts_with("ctor") {
            ExternKind::Ctor
        } else if self.method_name.starts_with("op_") {
            ExternKind::Op
        } else {
            ExternKind::Method
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternKind {
    PropGet,
    PropSet,
    Ctor,
    Op,
    Method,
}

/// Index over the known externs.
pub struct ExternTable {
    all: HashSet<String>,
    /// type → set of method names (without arg/ret)
    by_type: HashMap<String, HashMap<String, Vec<ExternSig>>>,
}

impl ExternTable {
    pub fn load_embedded() -> ExternTable {
        Self::from_text(KNOWN_EXTERNS_TEXT)
    }

    pub fn from_text(text: &str) -> ExternTable {
        let mut all = HashSet::new();
        let mut by_type: HashMap<String, HashMap<String, Vec<ExternSig>>> = HashMap::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if let Some(sig) = ExternSig::parse(line) {
                by_type.entry(sig.type_name.clone()).or_default().entry(sig.method_name.clone()).or_default().push(sig);
            }
            all.insert(line.to_string());
        }
        ExternTable { all, by_type }
    }

    pub fn len(&self) -> usize {
        self.all.len()
    }

    pub fn is_empty(&self) -> bool {
        self.all.is_empty()
    }

    pub fn contains(&self, sig: &str) -> bool {
        self.all.contains(sig)
    }

    pub fn has_type(&self, type_name: &str) -> bool {
        self.by_type.contains_key(type_name)
    }

    /// All method names for a type (e.g. `get_position`, `Translate`).
    pub fn methods_of(&self, type_name: &str) -> Vec<&str> {
        self.by_type.get(type_name).map(|m| m.keys().map(|s| s.as_str()).collect()).unwrap_or_default()
    }

    pub fn has_member(&self, type_name: &str, method_name: &str) -> bool {
        self.by_type.get(type_name).map_or(false, |m| m.contains_key(method_name))
    }

    pub fn overloads(&self, type_name: &str, method_name: &str) -> &[ExternSig] {
        self.by_type.get(type_name).and_then(|m| m.get(method_name)).map(|v| v.as_slice()).unwrap_or(&[])
    }

    pub fn type_names(&self) -> Vec<&str> {
        let mut v: Vec<&str> = self.by_type.keys().map(|s| s.as_str()).collect();
        v.sort();
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_sig() {
        let s = ExternSig::parse("SystemSingle.__op_Addition__SystemSingle_SystemSingle__SystemSingle").unwrap();
        assert_eq!(s.type_name, "SystemSingle");
        assert_eq!(s.method_name, "op_Addition");
        assert_eq!(s.arg_types, vec!["SystemSingle", "SystemSingle"]);
        assert_eq!(s.ret_type, "SystemSingle");
        assert_eq!(s.to_sig_string(), "SystemSingle.__op_Addition__SystemSingle_SystemSingle__SystemSingle");
        let p = ExternSig::parse("VRCSDKBaseVRCPlayerApi.__GetPickupInHand__VRCSDKBaseVRC_PickupPickupHand__VRCSDKBaseVRC_Pickup").unwrap();
        assert_eq!(p.arg_types, vec!["VRCSDKBaseVRC_PickupPickupHand"]);
        let d = ExternSig::parse("TMProTMP_DropdownOptionDataArray.__Set__SystemInt32_TMProTMP_DropdownOptionData__SystemVoid").unwrap();
        assert_eq!(d.arg_types, vec!["SystemInt32", "TMProTMP_DropdownOptionData"]);
        let g = ExternSig::parse("UnityEngineTransform.__get_position__UnityEngineVector3").unwrap();
        assert!(g.arg_types.is_empty());
        assert_eq!(g.kind(), ExternKind::PropGet);
        let c = ExternSig::parse("UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3").unwrap();
        assert_eq!(c.arg_types.len(), 3);
        assert_eq!(c.kind(), ExternKind::Ctor);
    }

    #[test]
    fn embedded_table_loads() {
        let t = ExternTable::load_embedded();
        assert!(t.len() > 30000);
        assert!(t.has_member("VRCSDKBaseVRCPlayerApi", "get_displayName"));
        assert!(t.has_member("UnityEngineTransform", "get_position"));
        assert!(t.contains("VRCSDKBaseNetworking.__get_LocalPlayer__VRCSDKBaseVRCPlayerApi"));
    }
}
