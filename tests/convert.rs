//! Integration tests: convert fixtures and (when present) the reference corpora.

use std::path::{Path, PathBuf};

use udon2godot::api::Catalog;
use udon2godot::diag::Diagnostics;
use udon2godot::externs::ExternTable;
use udon2godot::lower::{lower_class, ClassOutput, LowerOptions};
use udon2godot::parser::parse_source;
use udon2godot::program::Program;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn collect(p: &Path, out: &mut Vec<PathBuf>) {
    if p.is_dir() {
        let mut entries: Vec<_> = std::fs::read_dir(p).unwrap().filter_map(|e| e.ok()).map(|e| e.path()).collect();
        entries.sort();
        for e in entries {
            if e.is_dir() && e.file_name().map_or(false, |n| n == "Editor") {
                continue;
            }
            collect(&e, out);
        }
    } else if p.extension().map_or(false, |e| e == "cs") {
        out.push(p.to_path_buf());
    }
}

fn convert(paths: &[PathBuf]) -> (Vec<ClassOutput>, Diagnostics) {
    let mut units = Vec::new();
    for f in paths {
        let src = std::fs::read_to_string(f).unwrap();
        units.push(parse_source(&src, &f.to_string_lossy()).unwrap_or_else(|e| panic!("{}: {}", f.display(), e)));
    }
    let mut diags = Diagnostics::new();
    let prog = Program::build(&units, Catalog::load_embedded().unwrap(), ExternTable::load_embedded(), &mut diags);
    let opts = LowerOptions::default();
    let outs = prog.classes.iter().map(|c| lower_class(&prog, c, &opts)).collect();
    (outs, diags)
}

fn convert_source(src: &str) -> ClassOutput {
    let cu = parse_source(src, "test.cs").unwrap();
    let mut diags = Diagnostics::new();
    let prog = Program::build(&[cu], Catalog::load_embedded().unwrap(), ExternTable::load_embedded(), &mut diags);
    let opts = LowerOptions::default();
    lower_class(&prog, &prog.classes[0], &opts)
}

#[test]
fn counter_fixture_converts_without_errors() {
    let (outs, diags) = convert(&[root().join("tests/fixtures/Counter.cs")]);
    assert!(!diags.has_errors());
    assert_eq!(outs.len(), 1);
    let o = &outs[0];
    assert!(!o.diags.has_errors(), "{:?}", o.diags.items);
    let s = &o.source;
    assert!(s.contains("extends \"res://addons/udon_runtime/udon_behaviour.gd\""));
    assert!(s.contains("@export var speed: float = 2.0"));
    assert!(s.contains("func udon_synced_vars() -> Array:\n\treturn [\"count\", \"_phase\"]"));
    assert!(s.contains("return {\"_phase\": \"set_Phase\"}"));
    assert!(s.contains("enum Phase_ { Idle = 0, Running = 5, Done = 6 }"));
    assert!(s.contains("for i in range(0, positions.size()):"));
    assert!(s.contains("(U.get_position(target) - U.get_position(self)).normalized()"));
    assert!(s.contains("hit = U.raycast(U.get_position(self), dir, 10.0, -1, 0)"));
    assert!(s.contains("U.send_custom_network_event(self, NetworkEventTarget.All, \"OnBump\", [count])"));
    assert!(s.contains("var _t3 = TryGet(i, v)"));
    assert!(s.contains("Udon.get_key_down(KeyCode.Space)"));
    assert!(s.contains("fmod(sqrt(j), 2.0)"));
    assert!(o.usage.unmapped.is_empty(), "unmapped: {:?}", o.usage.unmapped);
}

#[test]
fn language_constructs() {
    let src = r#"
using UdonSharp; using UnityEngine; using VRC.SDKBase;
public class T : UdonSharpBehaviour {
    public string name2 = "x"; public int position;
    int[] arr = new int[3]; float f; bool b; string s;
    void Start() {
        s = "a" + 1 + f;
        f = 7 % 2f; int i = 7 / 2; i <<= 1; i >>= 2;
        arr[i] += 1; arr[i + 1] -= 2;
        do { i--; } while (i > 0);
        for (int k = 10; k >= 0; k -= 2) { if (k == 4) continue; }
        switch (i) { case 1: i = 2; break; case 2: if (b) break; i = 3; break; default: i = 4; break; }
        var v = Vector3.zero; v.x++; float m = (v - Vector3.one).magnitude;
        object o = null; string t = o == null ? "n" : o.ToString();
        Transform tr = transform; if (tr && tr.parent != null) tr.SetParent(null);
        float ang = Mathf.Atan2(v.y, v.x) * Mathf.Rad2Deg;
        int c = (int)'a' + (int)(2.7f);
        string fmt = $"{f:F1} {i}";
        int p = position;
    }
}
"#;
    let o = convert_source(src);
    assert!(!o.diags.has_errors(), "{:?}", o.diags.items);
    let s = &o.source;
    assert!(s.contains("var position_: int = 0"), "member colliding with Node3D.position is mangled");
    assert!(s.contains("s = \"a\" + str(1) + U.float_str(f)"));
    assert!(s.contains("f = fmod(7.0, 2.0)") || s.contains("f = fmod(7, 2.0)"));
    assert!(s.contains("var i: int = 7 / 2"));
    assert!(s.contains("i <<= 1") && s.contains("i >>= 2"));
    assert!(s.contains("arr[i] += 1"));
    assert!(s.contains("arr[_t1] = arr[_t1] - 2") || s.contains("arr[_t1] -= 2"), "{}", s);
    assert!(s.contains("while _t2 or i > 0") || s.contains("while _t"), "do/while: {}", s);
    assert!(s.contains("for k in range(10, 0 - 1, -2):"), "{}", s);
    assert!(s.contains("match i:"));
    assert!(s.contains("\t\t\tif b:\n\t\t\t\tpass\n\t\t\telse:\n\t\t\t\ti = 3"), "switch break rewrite: {}", s);
    assert!(s.contains("var m: float = (v - Vector3.ONE).length()"));
    assert!(s.contains("is_instance_valid(tr_) and is_instance_valid(tr_.get_parent())"), "`tr` collides with Object.tr() and is mangled");
    assert!(s.contains("U.set_parent(tr_, null, true)"));
    assert!(s.contains("atan2(v.y, v.x) * (180.0 / PI)"));
    assert!(s.contains("\"a\".unicode_at(0) + U.f2i(2.7)"));
    assert!(s.contains("U.format_num(f, \"F1\") + \" \" + str(i)"));
    assert!(s.contains("var p: int = position_"));
}

#[test]
fn network_and_sync_metadata() {
    let src = r#"
using UdonSharp; using UnityEngine; using VRC.SDKBase; using VRC.Udon.Common.Interfaces; using VRC.SDK3.UdonNetworkCalling;
[UdonBehaviourSyncMode(BehaviourSyncMode.Continuous)]
public class N : UdonSharpBehaviour {
    [UdonSynced(UdonSyncMode.Linear)] public float pos;
    [UdonSynced] public int hits;
    [NetworkCallable] public void Hit(int dmg, Vector3 at) { hits += dmg; }
    public override void OnPlayerJoined(VRCPlayerApi p) { if (p.isLocal) SendCustomNetworkEvent(VRC.Udon.Common.Interfaces.NetworkEventTarget.Owner, nameof(Hit), 1, Vector3.up); }
    public override void OnDeserialization(VRC.Udon.Common.DeserializationResult r) { float l = r.Latency; }
    public void Ping() { NetworkCalling.SendCustomNetworkEvent(this, NetworkEventTarget.All, nameof(Hit), 2, transform.position); }
}
"#;
    let o = convert_source(src);
    assert!(!o.diags.has_errors(), "{:?}", o.diags.items);
    let s = &o.source;
    assert!(s.contains("return \"continuous\""));
    assert!(s.contains("return {\"pos\": \"Linear\"}"));
    assert!(s.contains("return [\"Hit\"]"));
    assert!(s.contains("func OnDeserialization(r: Dictionary) -> void:"));
    assert!(s.contains("r.get(\"receiveTime\", 0.0) - r.get(\"sendTime\", 0.0)"));
    assert!(s.contains("U.send_custom_network_event(self, NetworkEventTarget.Owner, \"Hit\", [1, Vector3.UP])"));
    assert!(s.contains("U.send_custom_network_event(self, NetworkEventTarget.All, \"Hit\", [2, U.get_position(self)])"));
}

fn corpus(rel: &str) -> Option<PathBuf> {
    let p = root().join(rel);
    if p.exists() { Some(p) } else { None }
}

#[test]
fn reference_corpora_convert_without_errors() {
    let mut files = Vec::new();
    let mut found = false;
    for rel in ["refs/vrcbce/Packages/com.vrcbilliards.vrcbce/Runtime", "refs/SaccFlightAndVehicles"] {
        if let Some(p) = corpus(rel) {
            found = true;
            collect(&p, &mut files);
        }
    }
    if !found {
        eprintln!("reference corpora not checked out; skipping");
        return;
    }
    let (outs, diags) = convert(&files);
    assert!(!diags.has_errors());
    let errors: Vec<String> = outs.iter().flat_map(|o| o.diags.items.iter().filter(|d| d.severity == udon2godot::diag::Severity::Error).map(|d| format!("{}: {}", o.name, d))).collect();
    assert!(errors.is_empty(), "{:#?}", errors);
    let mapped: usize = outs.iter().map(|o| o.usage.mapped.values().sum::<usize>()).sum();
    let unmapped: usize = outs.iter().map(|o| o.usage.unmapped.len()).sum();
    assert!(outs.len() >= 100, "classes: {}", outs.len());
    assert!(mapped > 10000, "mapped: {}", mapped);
    assert!(unmapped <= 8, "unmapped members: {}", unmapped);
}
