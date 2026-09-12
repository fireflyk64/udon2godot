#!/usr/bin/env python3
"""Generate `data/api/generated.udon`: a `!stub` catalog entry for every Udon extern that the
hand-written catalog does not map.

Stubs compile and run (getters return the C# default, setters and void methods are no-ops,
value-returning methods return the default) and are reported as "stubbed" by the converter, so a
world author can see exactly which Unity behaviour is approximated. Hand-written entries in the
other `data/api/*.udon` files always take precedence; re-run this script after adding them.

Usage: tools/gen_catalog.py   (needs a release build of the converter)
"""
import os, re, subprocess, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, 'data', 'api')
OUT = os.path.join(API, 'generated.udon')
EXTERNS = os.path.join(ROOT, 'data', 'known_externs.txt')

# Namespace prefixes of mangled extern type names, longest first. The remainder is the C# type
# name (nested types keep their owner: UnityEngineParticleSystemShapeModule → ParticleSystem.ShapeModule).
PREFIXES = [
    ('VRCSDK3DynamicsConstraintComponents', 'VRC'), ('VRCSDK3DynamicsContactComponents', 'VRC'),
    ('VRCSDK3DynamicsPhysBoneComponents', 'VRC'), ('VRCSDK3VideoComponentsAVPro', 'VRC'),
    ('VRCSDK3VideoComponentsBase', 'VRC'), ('VRCSDK3VideoComponents', 'VRC'), ('VRCSDK3ComponentsVideo', 'VRC'),
    ('VRCSDK3UdonNetworkCalling', 'VRC'), ('VRCSDK3StringLoading', 'VRC'), ('VRCSDK3Persistence', 'VRC'),
    ('VRCSDK3Components', 'VRC'), ('VRCSDK3Rendering', 'VRC'), ('VRCSDK3Platform', 'VRC'), ('VRCSDK3Image', 'VRC'),
    ('VRCSDK3Data', 'VRC'), ('VRCSDK3Midi', 'VRC'), ('VRCSDK3', 'VRC'), ('VRCUdonCommonInterfaces', 'VRC'),
    ('VRCUdonCommonEnums', 'VRC'), ('VRCUdonCommon', 'VRC'), ('VRCUdon', 'VRC'), ('VRCSDKBase', 'VRC'),
    ('VRCDynamics', 'VRC'), ('VRCEconomy', 'VRC'), ('VRCCore', 'VRC'), ('VRC', 'VRC'),
    ('UnityEngineAnimations', 'Unity'), ('UnityEngineRendering', 'Unity'), ('UnityEngineSceneManagement', 'Unity'),
    ('UnityEngineEventSystems', 'Unity'), ('UnityEnginePlayables', 'Unity'), ('UnityEngineAudio', 'Unity'),
    ('UnityEngineVideo', 'Unity'), ('UnityEngineEvents', 'Unity'), ('UnityEngineAI', 'Unity'), ('UnityEngineUI', 'Unity'),
    ('UnityEngineXR', 'Unity'), ('UnityEngine', 'Unity'), ('UnityAINavigation', 'Unity'),
    ('SystemTextRegularExpressions', 'System'), ('SystemCollectionsGeneric', 'System'), ('SystemCollections', 'System'),
    ('SystemGlobalization', 'System'), ('SystemText', 'System'), ('SystemThreading', 'System'), ('System', 'System'),
    ('TMPro', 'TMPro'), ('Cinemachine', 'Cinemachine'), ('UnityAINavigation', 'Unity'),
]

# Nested-type owners (mangled names lose the dot): only these owners produce `Owner.Rest`.
NESTED_OWNERS = ['VRCPlayerApi', 'VRC_Pickup', 'VRCStation', 'VRC_SceneDescriptor', 'TMP_Dropdown', 'Dropdown', 'MidiData']
PARTICLE_NESTED = {'MinMaxCurve', 'MinMaxGradient', 'EmitParams', 'Burst', 'Particle', 'Trigger'}

PRIMS = {
    'SystemVoid': 'void', 'SystemBoolean': 'bool', 'SystemInt32': 'int', 'SystemUInt32': 'uint', 'SystemInt64': 'long',
    'SystemUInt64': 'ulong', 'SystemInt16': 'short', 'SystemUInt16': 'ushort', 'SystemByte': 'byte', 'SystemSByte': 'sbyte',
    'SystemSingle': 'float', 'SystemDouble': 'double', 'SystemDecimal': 'decimal', 'SystemChar': 'char',
    'SystemString': 'string', 'SystemObject': 'object', 'T': 'T', 'TArray': 'T[]', 'ListT': 'object',
}

GD_DEFAULT = {
    'void': None, 'bool': 'false', 'int': '0', 'uint': '0', 'long': '0', 'ulong': '0', 'short': '0', 'ushort': '0',
    'byte': '0', 'sbyte': '0', 'float': '0.0', 'double': '0.0', 'decimal': '0.0', 'char': '" "', 'string': '""',
    'object': 'null', 'Vector3': 'Vector3.ZERO', 'Vector2': 'Vector2.ZERO', 'Vector4': 'Vector4.ZERO',
    'Vector3Int': 'Vector3i.ZERO', 'Vector2Int': 'Vector2i.ZERO', 'Quaternion': 'Quaternion()', 'Color': 'Color.WHITE',
    'Color32': 'Color.WHITE', 'Matrix4x4': 'Transform3D()', 'Bounds': 'AABB()', 'Rect': 'Rect2()', 'Plane': 'Plane()',
}

# Godot counterparts for extern types not in the hand-written catalog (gd type hint, kind).
GD_TYPES = {
    'Rigidbody2D': ('RigidBody2D', 'component'), 'Collider2D': ('CollisionObject2D', 'component'),
    'BoxCollider2D': ('CollisionObject2D', 'component'), 'CircleCollider2D': ('CollisionObject2D', 'component'),
    'CapsuleCollider2D': ('CollisionObject2D', 'component'), 'PolygonCollider2D': ('CollisionObject2D', 'component'),
    'EdgeCollider2D': ('CollisionObject2D', 'component'), 'CompositeCollider2D': ('CollisionObject2D', 'component'),
    'SpriteRenderer': ('Sprite3D', 'component'), 'CharacterController': ('CharacterBody3D', 'component'),
    'NavMeshAgent': ('NavigationAgent3D', 'component'), 'NavMeshObstacle': ('NavigationObstacle3D', 'component'),
    'NavMeshSurface': ('NavigationRegion3D', 'component'), 'NavMeshLink': ('NavigationLink3D', 'component'),
    'OffMeshLink': ('NavigationLink3D', 'component'), 'SpringJoint': ('Generic6DOFJoint3D', 'component'),
    'FixedJoint': ('PinJoint3D', 'component'), 'CharacterJoint': ('ConeTwistJoint3D', 'component'),
    'Joint2D': ('Joint2D', 'component'), 'HingeJoint2D': ('PinJoint2D', 'component'), 'SliderJoint2D': ('GrooveJoint2D', 'component'),
    'SpringJoint2D': ('DampedSpringJoint2D', 'component'), 'DistanceJoint2D': ('DampedSpringJoint2D', 'component'),
    'FixedJoint2D': ('PinJoint2D', 'component'), 'RelativeJoint2D': ('PinJoint2D', 'component'), 'TargetJoint2D': ('PinJoint2D', 'component'),
    'WheelJoint2D': ('PinJoint2D', 'component'), 'FrictionJoint2D': ('PinJoint2D', 'component'),
    'Cubemap': ('Cubemap', 'class'), 'Texture3D': ('Texture3D', 'class'), 'CustomRenderTexture': ('Texture2D', 'class'),
    'BillboardRenderer': ('Sprite3D', 'component'), 'AudioReverbZone': ('Area3D', 'component'),
    'AudioReverbFilter': ('AudioEffectReverb', 'class'), 'AudioLowPassFilter': ('AudioEffectLowPassFilter', 'class'),
    'AudioHighPassFilter': ('AudioEffectHighPassFilter', 'class'), 'AudioEchoFilter': ('AudioEffectDelay', 'class'),
    'AudioDistortionFilter': ('AudioEffectDistortion', 'class'), 'AudioChorusFilter': ('AudioEffectChorus', 'class'),
    'VideoPlayer': ('VideoStreamPlayer', 'component'), 'TextMesh': ('Label3D', 'component'),
    'Terrain': ('Node3D', 'component'), 'Cloth': ('Node3D', 'component'), 'LODGroup': ('Node3D', 'component'),
    'Projector': ('Node3D', 'component'), 'WindZone': ('Node3D', 'component'), 'OcclusionArea': ('Node3D', 'component'),
    'LightProbeGroup': ('Node3D', 'component'), 'Skybox': ('Node3D', 'component'), 'AudioListener': ('AudioListener3D', 'component'),
    'PlayableDirector': ('AnimationPlayer', 'component'), 'CanvasRenderer': ('CanvasItem', 'component'),
    'MaskableGraphic': ('Control', 'component'), 'Mask': ('Control', 'component'), 'RectMask2D': ('Control', 'component'),
    'HorizontalLayoutGroup': ('HBoxContainer', 'component'), 'VerticalLayoutGroup': ('VBoxContainer', 'component'),
    'HorizontalOrVerticalLayoutGroup': ('BoxContainer', 'component'), 'GridLayoutGroup': ('GridContainer', 'component'),
    'LayoutGroup': ('Container', 'component'), 'ContentSizeFitter': ('Control', 'component'),
    'AspectRatioFitter': ('AspectRatioContainer', 'component'), 'CanvasScaler': ('CanvasLayer', 'component'),
    'Outline': ('Control', 'component'), 'Shadow': ('Control', 'component'), 'GraphicRaycaster': ('Control', 'component'),
    'StringBuilder': ('Object', 'class'), 'Regex': ('RegEx', 'class'), 'Match': ('RegExMatch', 'class'),
    'Group': ('RegExMatch', 'class'), 'Capture': ('RegExMatch', 'class'), 'MatchCollection': ('Array', 'class'),
    'GroupCollection': ('Array', 'class'), 'CaptureCollection': ('Array', 'class'), 'Encoding': ('Object', 'class'),
    'DateTimeOffset': ('Dictionary', 'struct'), 'TimeZoneInfo': ('Dictionary', 'class'),
    'CinemachineVirtualCamera': ('Camera3D', 'component'), 'CinemachineBrain': ('Node', 'component'),
    'CinemachineVirtualCameraBase': ('Camera3D', 'component'), 'CinemachineDollyCart': ('PathFollow3D', 'component'),
    'CinemachinePath': ('Path3D', 'component'), 'CinemachineSmoothPath': ('Path3D', 'component'), 'CinemachinePathBase': ('Path3D', 'component'),
}

def load_externs():
    by = collections.defaultdict(list)
    for line in open(EXTERNS):
        s = line.strip()
        if not s or '.__' not in s:
            continue
        t, rest = s.split('.__', 1)
        by[t].append(rest)
    return by

def catalog_extern_map():
    """extern name → catalog canonical name, from the hand-written files."""
    m = {}
    names = set()
    for f in sorted(os.listdir(API)):
        if not f.endswith('.udon') or f == 'generated.udon':
            continue
        for line in open(os.path.join(API, f)):
            if line.startswith('type '):
                parts = line.split()
                name = parts[1]
                names.add(name)
                for p in parts:
                    if p.startswith('extern='):
                        m[p[7:]] = name
    return m, names

def demangle_type(mangled, ext_map, all_types):
    """Mangled extern type name → C# canonical name."""
    if mangled in PRIMS:
        return PRIMS[mangled]
    if mangled in ext_map:
        return ext_map[mangled]
    if mangled.endswith('Array') and mangled != 'Array':
        inner = mangled[:-5]
        if inner in PRIMS or inner in ext_map or inner in all_types:
            return demangle_type(inner, ext_map, all_types) + '[]'
    for pre, _fam in PREFIXES:
        if mangled.startswith(pre) and len(mangled) > len(pre):
            rest = mangled[len(pre):]
            if rest.startswith('ParticleSystem') and len(rest) > 14:
                sub = rest[14:]
                if sub.endswith('Module') or sub in PARTICLE_NESTED:
                    return 'ParticleSystem.' + sub
            for owner in NESTED_OWNERS:
                if rest.startswith(owner) and len(rest) > len(owner) and rest[len(owner)].isupper():
                    return owner + '.' + rest[len(owner):]
            return rest
    return mangled

def parse_member(rest):
    segs = rest.split('__')
    name = segs[0]
    if name.startswith('set_') and len(segs) == 2:
        return name, [segs[1]], 'SystemVoid'  # `__set_x__T`: setter without a return segment
    ret = segs[-1]
    args = []
    for ag in segs[1:-1]:
        args.extend([a for a in ag.split('_') if a])
    return name, args, ret

def default_for(ty):
    if ty in GD_DEFAULT:
        return GD_DEFAULT[ty]
    if ty.endswith('[]'):
        return '[]'
    return 'null'

def main():
    if not os.path.exists(os.path.join(ROOT, 'target', 'release', 'udon2godot')):
        subprocess.check_call(['cargo', 'build', '--release'], cwd=ROOT)
    missing_path = '/tmp/udon2godot_missing.tsv'
    env = dict(os.environ, UDON2GODOT_NO_GENERATED='1')
    subprocess.check_call([os.path.join(ROOT, 'target', 'release', 'udon2godot'), '--coverage-missing', missing_path], cwd=ROOT, env=env, stdout=subprocess.DEVNULL)
    by = load_externs()
    ext_map, cat_names = catalog_extern_map()
    all_types = set(by.keys())
    missing = collections.defaultdict(list)
    missing_names = collections.defaultdict(set)
    for line in open(missing_path):
        t, m = line.rstrip('\n').split('\t')
        missing_names[t].add(m)
    for t, names in missing_names.items():
        for rest in by.get(t, []):
            if rest.split('__')[0] in names:
                missing[t].append(rest)
    out = ['# GENERATED by tools/gen_catalog.py — do not edit. `!stub` entries for every Udon extern the',
           '# hand-written catalog does not map: getters return C# defaults, setters and void methods are',
           '# no-ops. Add a real mapping in another data/api/*.udon file and re-run the generator.', '']
    n_types = n_members = 0
    for t in sorted(missing):
        if t.endswith('Array') and t not in ext_map:
            continue  # arrays are covered generically
        if t in ('T', 'TArray', 'ListT'):
            continue
        name = ext_map.get(t) or demangle_type(t, ext_map, all_types)
        if name in PRIMS.values():
            continue
        members = missing[t]
        seen = set()
        lines = []
        for rest in sorted(members):
            mname, args, ret = parse_member(rest)
            if mname in ('Equals', 'GetHashCode', 'GetType', 'ToString', 'Finalize', 'MemberwiseClone') or mname.startswith('op_'):
                continue
            targs = [demangle_type(a, ext_map, all_types) for a in args]
            tret = demangle_type(ret, ext_map, all_types)
            if any(a in ('T', 'T[]', 'object') and 'List' in a for a in targs):
                continue
            is_static = False  # unknown from the signature; instance form works for both via `$0`
            if mname.startswith('get_') and not args:
                prop = mname[4:]
                key = ('get', prop)
                if key in seen:
                    continue
                seen.add(key)
                d = default_for(tret)
                if prop == 'Item':
                    continue
                lines.append(f"  {prop}: {tret} => !stub {d}")
                lines.append(f"  static {prop}: {tret} => !stub {d}")
            elif mname.startswith('set_') and len(args) == 1:
                prop = mname[4:]
                key = ('set', prop)
                if key in seen:
                    continue
                seen.add(key)
                if prop == 'Item':
                    continue
                lines.append(f"  set {prop}: {targs[0]} => !stub pass")
                lines.append(f"  static set {prop}: {targs[0]} => !stub pass")
            elif mname.startswith('ctor'):
                key = ('ctor', tuple(targs))
                if key in seen:
                    continue
                seen.add(key)
                gd = GD_TYPES.get(name, (None, None))[0]
                d = '{}' if gd == 'Dictionary' else 'null'
                if gd == 'Object':
                    d = 'null'
                lines.append(f"  ctor({', '.join(targs)}) => !stub {d}")
            else:
                key = ('m', mname, tuple(targs))
                if key in seen:
                    continue
                seen.add(key)
                d = default_for(tret)
                tmpl = 'pass' if tret == 'void' else d
                lines.append(f"  {mname}({', '.join(targs)}): {tret} => !stub {tmpl}")
                lines.append(f"  static {mname}({', '.join(targs)}): {tret} => !stub {tmpl}")
        if not lines:
            continue
        if name in cat_names or t in ext_map:
            out.append(f"type {name}")
        else:
            gd, kind = GD_TYPES.get(name, ('Variant', 'class'))
            if name.startswith('VRC') and gd == 'Variant':
                gd, kind = 'Node', 'component'
            base = ' : Behaviour' if kind == 'component' else ''
            out.append(f"type {name}{base} kind={kind} gd={gd} extern={t}")
            n_types += 1
        out.extend(lines)
        out.append('')
        n_members += len(lines)
    open(OUT, 'w').write('\n'.join(out))
    print(f"wrote {OUT}: {n_types} new types, {n_members} stub members")

if __name__ == '__main__':
    main()
