#!/usr/bin/env python3
"""Generate `data/api/unity_particles.udon`: the ParticleSystem catalog (system, renderer, every
module struct, MinMaxCurve/MinMaxGradient, EmitParams, Particle, Burst) from the Udon extern list.

Module properties go through `U.ps_get/ps_set` on PsModule objects (runtime u.gd). The ones the
runtime maps onto GPUParticles3D / ParticleProcessMaterial (ENGINE below) are plain mappings; the
rest are `!stored` (they round-trip, no engine effect). Re-run after editing this file, then
`tools/gen_catalog.py` so the generated stubs shrink.
"""
import os, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_catalog as G

ROOT = G.ROOT
OUT = os.path.join(ROOT, 'data', 'api', 'unity_particles.udon')

MODULES = [  # (catalog type, mangled extern suffix, module kind for the runtime)
    ('MainModule', 'MainModule', 'main'), ('EmissionModule', 'EmissionModule', 'emission'),
    ('ShapeModule', 'ShapeModule', 'shape'), ('VelocityOverLifetimeModule', 'VelocityOverLifetimeModule', 'velocityOverLifetime'),
    ('LimitVelocityOverLifetimeModule', 'LimitVelocityOverLifetimeModule', 'limitVelocityOverLifetime'),
    ('InheritVelocityModule', 'InheritVelocityModule', 'inheritVelocity'),
    ('LifetimeByEmitterSpeedModule', 'LifetimeByEmitterSpeedModule', 'lifetimeByEmitterSpeed'),
    ('ForceOverLifetimeModule', 'ForceOverLifetimeModule', 'forceOverLifetime'),
    ('ColorOverLifetimeModule', 'ColorOverLifetimeModule', 'colorOverLifetime'),
    ('ColorBySpeedModule', 'ColorBySpeedModule', 'colorBySpeed'), ('SizeOverLifetimeModule', 'SizeOverLifetimeModule', 'sizeOverLifetime'),
    ('SizeBySpeedModule', 'SizeBySpeedModule', 'sizeBySpeed'), ('RotationOverLifetimeModule', 'RotationOverLifetimeModule', 'rotationOverLifetime'),
    ('RotationBySpeedModule', 'RotationBySpeedModule', 'rotationBySpeed'), ('ExternalForcesModule', 'ExternalForcesModule', 'externalForces'),
    ('NoiseModule', 'NoiseModule', 'noise'), ('CollisionModule', 'CollisionModule', 'collision'),
    ('TriggerModule', 'TriggerModule', 'trigger'), ('SubEmittersModule', 'SubEmittersModule', 'subEmitters'),
    ('TextureSheetAnimationModule', 'TextureSheetAnimationModule', 'textureSheetAnimation'),
    ('LightsModule', 'LightsModule', 'lights'), ('TrailModule', 'TrailModule', 'trails'),
    ('CustomDataModule', 'CustomDataModule', 'customData'),
]

# properties the runtime maps onto the engine (see u.gd `_ps_apply` / `_ps_read`)
ENGINE = {
    'main': {'loop', 'startLifetime', 'startLifetimeMultiplier', 'startSpeed', 'startSpeedMultiplier', 'startSize', 'startSizeMultiplier', 'startSizeX',
             'startRotation', 'startRotationMultiplier', 'startColor', 'gravityModifier', 'gravityModifierMultiplier', 'simulationSpace', 'simulationSpeed',
             'maxParticles', 'playOnAwake', 'prewarm'},
    'emission': {'enabled', 'rateOverTime', 'rateOverTimeMultiplier', 'burstCount'},
    'shape': {'enabled', 'shapeType', 'radius', 'radiusThickness', 'angle', 'scale', 'position', 'randomDirectionAmount'},
    'velocityOverLifetime': {'speedModifier', 'speedModifierMultiplier', 'radial', 'radialMultiplier'},
    'limitVelocityOverLifetime': {'dampen', 'drag', 'dragMultiplier'},
    'forceOverLifetime': {'enabled', 'x', 'y', 'z', 'xMultiplier', 'yMultiplier', 'zMultiplier'},
    'colorOverLifetime': {'enabled', 'color'},
    'sizeOverLifetime': {'enabled', 'size', 'sizeMultiplier'},
    'rotationOverLifetime': {'enabled', 'z', 'zMultiplier'},
    'noise': {'enabled', 'strength', 'strengthMultiplier', 'frequency', 'scrollSpeed', 'scrollSpeedMultiplier'},
    'collision': {'enabled', 'bounce', 'bounceMultiplier', 'dampen', 'dampenMultiplier', 'radiusScale'},
    'textureSheetAnimation': {'enabled', 'numTilesX', 'numTilesY'},
    'trails': {'enabled', 'lifetime', 'lifetimeMultiplier'},
}

# Unity defaults for the properties scripts read before writing
DEFAULTS = {
    ('main', 'duration'): '5.0', ('main', 'loop'): 'true', ('main', 'startLifetime'): '5.0', ('main', 'startSpeed'): '5.0',
    ('main', 'startSize'): '1.0', ('main', 'startSizeX'): '1.0', ('main', 'startSizeY'): '1.0', ('main', 'startSizeZ'): '1.0',
    ('main', 'maxParticles'): '1000', ('main', 'simulationSpeed'): '1.0', ('main', 'simulationSpace'): '0', ('main', 'playOnAwake'): 'true',
    ('main', 'startLifetimeMultiplier'): '5.0', ('main', 'startSpeedMultiplier'): '5.0', ('main', 'startSizeMultiplier'): '1.0',
    ('main', 'gravityModifierMultiplier'): '1.0', ('main', 'startRotationMultiplier'): '1.0', ('main', 'scalingMode'): '0',
    ('emission', 'rateOverTime'): '10.0', ('emission', 'rateOverTimeMultiplier'): '10.0', ('emission', 'enabled'): 'true',
    ('shape', 'radius'): '1.0', ('shape', 'angle'): '25.0', ('shape', 'scale'): 'Vector3.ONE', ('shape', 'radiusThickness'): '1.0',
    ('shape', 'arc'): '360.0', ('shape', 'shapeType'): '4', ('shape', 'enabled'): 'true', ('shape', 'length'): '5.0',
    ('velocityOverLifetime', 'speedModifier'): '1.0', ('velocityOverLifetime', 'speedModifierMultiplier'): '1.0',
    ('limitVelocityOverLifetime', 'limit'): '1.0', ('limitVelocityOverLifetime', 'limitMultiplier'): '1.0',
    ('sizeOverLifetime', 'size'): '1.0', ('sizeOverLifetime', 'sizeMultiplier'): '1.0',
    ('noise', 'strength'): '1.0', ('noise', 'strengthMultiplier'): '1.0', ('noise', 'frequency'): '0.5', ('noise', 'octaveCount'): '1',
    ('noise', 'quality'): '2', ('collision', 'bounce'): '1.0', ('collision', 'bounceMultiplier'): '1.0', ('collision', 'radiusScale'): '1.0',
    ('collision', 'maxCollisionShapes'): '256', ('textureSheetAnimation', 'numTilesX'): '1', ('textureSheetAnimation', 'numTilesY'): '1',
    ('textureSheetAnimation', 'cycleCount'): '1', ('textureSheetAnimation', 'fps'): '30.0', ('trails', 'lifetime'): '1.0',
    ('trails', 'lifetimeMultiplier'): '1.0', ('trails', 'ratio'): '1.0', ('trails', 'minVertexDistance'): '0.2',
    ('trails', 'inheritParticleColor'): 'true', ('trails', 'dieWithParticles'): 'true', ('trails', 'sizeAffectsWidth'): 'true',
    ('trails', 'widthOverTrailMultiplier'): '1.0', ('trails', 'widthOverTrail'): '1.0', ('trails', 'ribbonCount'): '1',
    ('lights', 'ratio'): '0.0', ('lights', 'intensityMultiplier'): '1.0', ('lights', 'rangeMultiplier'): '1.0', ('lights', 'intensity'): '1.0',
    ('lights', 'range'): '1.0', ('lights', 'maxLights'): '20', ('lights', 'useParticleColor'): 'true', ('lights', 'sizeAffectsRange'): 'true',
    ('lights', 'alphaAffectsIntensity'): 'true', ('subEmitters', 'subEmittersCount'): '0',
    ('externalForces', 'multiplier'): '1.0', ('externalForces', 'multiplierCurve'): '1.0', ('inheritVelocity', 'curve'): '0.0',
    ('rotationOverLifetime', 'x'): '0.0', ('renderer', 'renderMode'): '0', ('renderer', 'sortMode'): '0',
    ('renderer', 'minParticleSize'): '0.0', ('renderer', 'maxParticleSize'): '0.5', ('renderer', 'lengthScale'): '2.0',
    ('renderer', 'velocityScale'): '0.0', ('renderer', 'cameraVelocityScale'): '0.0', ('renderer', 'normalDirection'): '1.0',
    ('renderer', 'alignment'): '0', ('renderer', 'pivot'): 'Vector3.ZERO', ('renderer', 'flip'): 'Vector3.ZERO', ('renderer', 'allowRoll'): 'true',
    ('renderer', 'enableGPUInstancing'): 'true', ('renderer', 'meshCount'): '1', ('renderer', 'supportsMeshInstancing'): 'true',
}

GD_DEFAULT = dict(G.GD_DEFAULT)
GD_DEFAULT.update({'MinMaxCurve': '0.0', 'MinMaxGradient': 'Color.WHITE', 'AnimationCurve': 'null', 'Gradient': 'null', 'Vector3': 'Vector3.ZERO'})


def default_for(kind, prop, ty):
    if (kind, prop) in DEFAULTS:
        return DEFAULTS[(kind, prop)]
    if prop == 'enabled':
        return 'false'
    if ty in GD_DEFAULT:
        return GD_DEFAULT[ty]
    if ty.endswith('[]'):
        return '[]'
    return '0' if ty.startswith('ParticleSystem') else 'null'  # enums


def base_members():
    """Member names the hand-written Object/Component/Behaviour/Renderer blocks already map."""
    names = set()
    for f in sorted(os.listdir(G.API)):
        if not f.endswith('.udon') or f in ('generated.udon', 'unity_particles.udon'):
            continue
        cur = None
        for line in open(os.path.join(G.API, f)):
            if line.startswith('type '):
                cur = line.split()[1]
            elif cur in ('Object', 'Component', 'Behaviour', 'Renderer') and line.startswith('  '):
                head = line.strip().split('=>')[0].strip()
                for pre in ('static ', 'set '):
                    if head.startswith(pre):
                        head = head[len(pre):]
                names.add(head.split('(')[0].split(':')[0].strip())
    return names


BASE = None


def members_of(by, mangled, skip_base=False):
    global BASE
    if BASE is None:
        BASE = base_members()
    props = collections.OrderedDict()
    methods = []
    for rest in sorted(by.get(mangled, [])):
        name, args, ret = G.parse_member(rest)
        if name in ('Equals', 'GetHashCode', 'GetType', 'ToString') or name.startswith('op_'):
            continue
        if skip_base:
            base_name = name[4:] if name.startswith(('get_', 'set_')) else name
            if base_name in BASE:
                continue
        if name.startswith('get_') and not args:
            props.setdefault(name[4:], {})['get'] = ret
        elif name.startswith('set_') and len(args) == 1:
            props.setdefault(name[4:], {})['set'] = args[0]
        elif name.startswith('ctor'):
            methods.append(('ctor', args, ret))
        else:
            methods.append((name, args, ret))
    return props, methods


def main():
    by = G.load_externs()
    ext_map, names = G.catalog_extern_map()
    all_types = set(by.keys())
    d = lambda m: G.demangle_type(m, ext_map, all_types)
    out = ['# GENERATED by tools/gen_particles.py from data/known_externs.txt — edit the generator, not this file.',
           '# ParticleSystem and its modules on GPUParticles3D (runtime u.gd, `ps_*` helpers).', '']
    # --- modules
    for tname, suffix, kind in MODULES:
        mangled = 'UnityEngineParticleSystem' + suffix
        props, methods = members_of(by, mangled)
        out.append(f'type {tname} kind=struct gd=Object extern={mangled}')
        for prop, acc in props.items():
            ty = d(acc.get('get') or acc.get('set'))
            eng = prop in ENGINE.get(kind, set())
            mark = '' if eng else '!stored '
            if 'get' in acc:
                out.append(f'  {prop}: {ty} => {mark}U.ps_get($0, "{prop}", {default_for(kind, prop, ty)})')
            if 'set' in acc:
                out.append(f'  set {prop}: {d(acc["set"])} => {mark}U.ps_set($0, "{prop}", $v)')
        for name, args, ret in methods:
            targs = [d(a) for a in args]
            tret = d(ret)
            sig = f'{name}({", ".join(targs)}): {tret}'
            t = None
            if kind == 'emission':
                if name == 'SetBursts' and len(args) == 1: t = 'U.ps_set_bursts($0, $1)'
                elif name == 'SetBursts' and len(args) == 2: t = 'U.ps_set_bursts($0, $1, $2)'
                elif name == 'GetBursts': t = 'U.ps_get_bursts($0, $1)'
                elif name == 'GetBurst': t = 'U.ps_burst($0, $1)'
                elif name == 'SetBurst': t = 'U.ps_set_burst($0, $1, $2)'
            elif kind == 'subEmitters':
                if name == 'GetSubEmitterSystem': t = 'U.ps_sub_emitter($0.node, $1)'
                elif name == 'GetSubEmitterType': t = 'int(U.ps_get($0, "type" + str($1), 0))'
                elif name == 'GetSubEmitterProperties': t = 'int(U.ps_get($0, "properties" + str($1), 0))'
                elif name == 'GetSubEmitterEmitProbability': t = 'float(U.ps_get($0, "probability" + str($1), 1.0))'
            elif kind == 'textureSheetAnimation':
                if name == 'GetSprite': t = 'U.ps_get($0, "sprite" + str($1), null)'
                elif name == 'SetSprite': t = 'U.ps_set($0, "sprite" + str($1), $2)'
            elif kind == 'collision':
                if name == 'GetPlane': t = 'U.ps_get($0, "plane" + str($1), null)'
                elif name == 'SetPlane': t = 'U.ps_set($0, "plane" + str($1), $2)'
            elif kind == 'trigger':
                if name == 'GetCollider': t = 'null'
                elif name == 'SetCollider': t = 'pass'
                elif name == 'AddCollider': t = 'pass'
                elif name == 'RemoveCollider': t = 'pass'
            if t is None:
                if tret == 'void':
                    t = '!stored pass'
                else:
                    t = f'!stored {default_for(kind, name, tret)}'
            out.append(f'  {sig} => {t}')
        out.append('')

    # --- ParticleSystem (component)
    props, methods = members_of(by, 'UnityEngineParticleSystem', True)
    module_props = {m[2]: m[0] for m in MODULES}
    out.append('type ParticleSystem : Component kind=component gd=GPUParticles3D extern=UnityEngineParticleSystem')
    out.append('  gameObject: GameObject => U.game_object($0)')
    out.append('  transform: Transform => U.game_object($0)')
    special = {
        'isPlaying': 'U.ps_is_playing($0)', 'isEmitting': 'U.ps_is_emitting($0)', 'isStopped': 'U.ps_is_stopped($0)', 'isPaused': 'U.ps_is_paused($0)',
        'particleCount': 'U.ps_particle_count($0)', 'time': 'U.ps_time($0)', 'totalTime': 'U.ps_time($0)',
        'proceduralSimulationSupported': 'false', 'has3DParticleRotations': 'false', 'hasNonUniformParticleSizes': 'false',
    }
    for prop, acc in props.items():
        ty = d(acc.get('get') or acc.get('set'))
        if prop in module_props:
            out.append(f'  {prop}: {module_props[prop]} => U.ps_module($0, "{prop}")')
            continue
        if 'get' in acc:
            if prop in special:
                out.append(f'  {prop}: {ty} => {special[prop]}')
            else:
                out.append(f'  {prop}: {ty} => !stored U.prop_get($0, "{prop}", {default_for("system", prop, ty)})')
        if 'set' in acc:
            if prop == 'time':
                out.append(f'  set time: float => U.ps_set_time($0, $v)')
            else:
                out.append(f'  set {prop}: {d(acc["set"])} => !stored U.prop_set($0, "{prop}", $v)')
    for name, args, ret in methods:
        targs = [d(a) for a in args]
        tret = d(ret)
        sig = f'{name}({", ".join(targs)}): {tret}'
        n = len(args)
        t = None
        if name == 'Play': t = 'U.ps_play($0, true)' if n == 0 else 'U.ps_play($0, $1)'
        elif name == 'Stop': t = {0: 'U.ps_stop($0, true, 0)', 1: 'U.ps_stop($0, $1, 0)', 2: 'U.ps_stop($0, $1, $2)'}.get(n)
        elif name == 'Pause': t = 'U.ps_pause($0, true)' if n == 0 else 'U.ps_pause($0, $1)'
        elif name == 'Clear': t = 'U.ps_clear($0, true)' if n == 0 else 'U.ps_clear($0, $1)'
        elif name == 'Emit' and targs == ['int']: t = 'U.ps_emit($0, $1)'
        elif name == 'Emit' and targs[:1] == ['EmitParams']: t = 'U.ps_emit_params($0, $1, $2)'
        elif name == 'Simulate': t = {1: 'U.ps_simulate($0, $1, true)', 2: 'U.ps_simulate($0, $1, true)', 3: 'U.ps_simulate($0, $1, $3)', 4: 'U.ps_simulate($0, $1, $3)'}.get(n)
        elif name == 'IsAlive': t = 'U.ps_is_playing($0)'
        elif name == 'TriggerSubEmitter' and n == 1: t = 'U.ps_trigger_sub_emitter($0, $1)'
        elif name == 'GetParticles': t = '0'
        elif name == 'SetParticles': t = 'pass'
        elif name == 'GetCustomParticleData': t = '0'
        elif name == 'SetCustomParticleData': t = 'pass'
        elif name == 'GetPlaybackState': t = '{"time": U.ps_time($0)}'
        elif name == 'SetPlaybackState': t = 'U.ps_set_time($0, float($1.get("time", 0.0)))'
        elif name == 'GetTrails' and n == 0: t = '{}'
        elif name == 'GetTrails': t = '0'
        elif name == 'SetTrails': t = 'pass'
        elif name.startswith('Allocate') or name == 'SetMaximumPreMappedBufferCounts': t = 'pass'
        if t is None:
            t = '!stored pass' if tret == 'void' else f'!stored {default_for("system", name, tret)}'
        elif name in ('GetParticles', 'SetParticles', 'GetCustomParticleData', 'SetCustomParticleData', 'GetTrails', 'SetTrails', 'TriggerSubEmitter') and n != 1:
            t = '!stub ' + t
        out.append(f'  {sig} => {t}')
    out.append('')

    # --- ParticleSystemRenderer
    props, methods = members_of(by, 'UnityEngineParticleSystemRenderer', True)
    out.append('type ParticleSystemRenderer : Renderer kind=component gd=GPUParticles3D extern=UnityEngineParticleSystemRenderer')
    out.append('  gameObject: GameObject => U.game_object($0)')
    out.append('  transform: Transform => U.game_object($0)')
    reng = {'material', 'sharedMaterial', 'mesh', 'renderMode', 'enabled'}
    for prop, acc in props.items():
        ty = d(acc.get('get') or acc.get('set'))
        mark = '' if prop in reng else '!stored '
        if 'get' in acc:
            out.append(f'  {prop}: {ty} => {mark}U.ps_get(U.ps_module($0, "renderer"), "{prop}", {default_for("renderer", prop, ty)})')
        if 'set' in acc:
            out.append(f'  set {prop}: {d(acc["set"])} => {mark}U.ps_set(U.ps_module($0, "renderer"), "{prop}", $v)')
    for name, args, ret in methods:
        targs = [d(a) for a in args]
        tret = d(ret)
        sig = f'{name}({", ".join(targs)}): {tret}'
        t = None
        if name == 'GetMeshes': t = 'U.ps_get_bursts(U.ps_module($0, "meshes"), $1)'
        elif name == 'SetMeshes': t = 'U.ps_set_bursts(U.ps_module($0, "meshes"), $1)' if len(args) == 1 else 'U.ps_set_bursts(U.ps_module($0, "meshes"), $1, $2)'
        elif name in ('BakeMesh', 'BakeTrailsMesh'): t = 'pass'
        if t is None:
            t = '!stored pass' if tret == 'void' else f'!stored {default_for("renderer", name, tret)}'
        out.append(f'  {sig} => {t}')
    out.append('')

    # --- structs backed by dictionaries: EmitParams, Particle, Burst
    for tname, mangled, ctor in [('EmitParams', 'UnityEngineParticleSystemEmitParams', '{}'), ('Particle', 'UnityEngineParticleSystemParticle', '{}'), ('Burst', 'UnityEngineParticleSystemBurst', None)]:
        props, methods = members_of(by, mangled)
        out.append(f'type {tname} kind=struct gd=Dictionary extern={mangled}')
        if ctor:
            out.append(f'  ctor() => {ctor}')
        if tname == 'Burst':
            out.append('  ctor(float, short) => {"time": $1, "count": $2, "cycleCount": 1, "repeatInterval": 0.01, "probability": 1.0}')
            out.append('  ctor(float, short, short) => {"time": $1, "count": U.mmc_two_constants($2, $3), "cycleCount": 1, "repeatInterval": 0.01, "probability": 1.0}')
            out.append('  ctor(float, short, short, int, float) => {"time": $1, "count": U.mmc_two_constants($2, $3), "cycleCount": $4, "repeatInterval": $5, "probability": 1.0}')
            out.append('  ctor(float, MinMaxCurve) => {"time": $1, "count": $2, "cycleCount": 1, "repeatInterval": 0.01, "probability": 1.0}')
            out.append('  ctor(float, MinMaxCurve, int, float) => {"time": $1, "count": $2, "cycleCount": $3, "repeatInterval": $4, "probability": 1.0}')
        dflt = {'startSize': '1.0', 'startLifetime': '5.0', 'remainingLifetime': '5.0', 'startColor': 'Color.WHITE', 'startSize3D': 'Vector3.ONE',
                'axisOfRotation': 'Vector3.UP', 'randomSeed': '0', 'cycleCount': '1', 'repeatInterval': '0.01', 'probability': '1.0', 'time': '0.0', 'count': '30'}
        for prop, acc in props.items():
            ty = d(acc.get('get') or acc.get('set'))
            dv = dflt.get(prop, default_for('struct', prop, ty))
            if tname == 'Burst' and prop in ('minCount', 'maxCount'):
                fn = 'U.mmc_min' if prop == 'minCount' else 'U.mmc_max'
                out.append(f'  {prop}: short => int({fn}($0.get("count", 30)))')
                out.append(f'  set {prop}: short => $0.count = U.mmc_with($0.get("count", 30), "constant{"Min" if prop == "minCount" else "Max"}", $v)')
                continue
            if 'get' in acc:
                out.append(f'  {prop}: {ty} => $0.get("{prop}", {dv})')
            if 'set' in acc:
                out.append(f'  set {prop}: {d(acc["set"])} => $0.{prop} = $v')
        for name, args, ret in methods:
            targs = [d(a) for a in args]
            tret = d(ret)
            sig = f'{name}({", ".join(targs)}): {tret}'
            if name == 'ctor':
                continue
            if name.startswith('Reset'):
                key = name[5:]
                key = key[0].lower() + key[1:]
                t = f'$0.erase("{key}")'
            elif name == 'GetCurrentColor': t = '$0.get("startColor", Color.WHITE)'
            elif name == 'GetCurrentSize': t = '$0.get("startSize", 1.0)'
            elif name == 'GetCurrentSize3D': t = '$0.get("startSize3D", Vector3.ONE)'
            elif name == 'GetMeshIndex': t = 'int($0.get("meshIndex", 0))'
            elif name == 'SetMeshIndex': t = '$0.meshIndex = $1'
            else:
                t = '!stored pass' if tret == 'void' else f'!stored {default_for("struct", name, tret)}'
            out.append(f'  {sig} => {t}')
        out.append('')

    out.append('''type MinMaxCurve kind=struct gd=Variant extern=UnityEngineParticleSystemMinMaxCurve
  ctor(float) => $1
  ctor(float, float) => U.mmc_two_constants($1, $2)
  ctor(float, AnimationCurve) => U.mmc_curve($1, $2)
  ctor(float, AnimationCurve, AnimationCurve) => U.mmc_two_curves($1, $2, $3)
  constant: float => U.mmc_constant($0)
  set constant: float => $0 = U.mmc_with($0, "constant", $v)
  constantMin: float => U.mmc_min($0)
  set constantMin: float => $0 = U.mmc_with($0, "constantMin", $v)
  constantMax: float => U.mmc_max($0)
  set constantMax: float => $0 = U.mmc_with($0, "constantMax", $v)
  curve: AnimationCurve => U.mmc_get($0, "curve")
  set curve: AnimationCurve => $0 = U.mmc_with($0, "curve", $v)
  curveMin: AnimationCurve => U.mmc_get($0, "curveMin")
  set curveMin: AnimationCurve => $0 = U.mmc_with($0, "curveMin", $v)
  curveMax: AnimationCurve => U.mmc_get($0, "curveMax")
  set curveMax: AnimationCurve => $0 = U.mmc_with($0, "curveMax", $v)
  curveMultiplier: float => U.mmc_multiplier($0)
  set curveMultiplier: float => $0 = U.mmc_with($0, "curveMultiplier", $v)
  mode: ParticleSystemCurveMode => U.mmc_mode($0)
  set mode: ParticleSystemCurveMode => $0 = U.mmc_with($0, "mode", $v)
  Evaluate(float): float => U.mmc_eval($0, $1, 0.5)
  Evaluate(float, float): float => U.mmc_eval($0, $1, $2)
  cast float => U.mmc_constant($0)
  op implicit_float(float): MinMaxCurve => $1

type MinMaxGradient kind=struct gd=Variant extern=UnityEngineParticleSystemMinMaxGradient
  ctor(Color) => $1
  ctor(Color, Color) => U.mmg_two_colors($1, $2)
  ctor(Gradient) => U.mmg_gradient_value($1)
  ctor(Gradient, Gradient) => U.mmg_two_gradients($1, $2)
  color: Color => U.mmg_color($0)
  set color: Color => $0 = U.mmg_with($0, "color", $v)
  colorMin: Color => U.mmg_eval($0, 0.0, 0.0)
  set colorMin: Color => $0 = U.mmg_with($0, "colorMin", $v)
  colorMax: Color => U.mmg_eval($0, 0.0, 1.0)
  set colorMax: Color => $0 = U.mmg_with($0, "colorMax", $v)
  gradient: Gradient => U.mmg_get($0, "gradient")
  set gradient: Gradient => $0 = U.mmg_with($0, "gradient", $v)
  gradientMin: Gradient => U.mmg_get($0, "gradientMin")
  set gradientMin: Gradient => $0 = U.mmg_with($0, "gradientMin", $v)
  gradientMax: Gradient => U.mmg_get($0, "gradientMax")
  set gradientMax: Gradient => $0 = U.mmg_with($0, "gradientMax", $v)
  mode: ParticleSystemGradientMode => U.mmg_mode($0)
  set mode: ParticleSystemGradientMode => $0 = U.mmg_with($0, "mode", $v)
  Evaluate(float): Color => U.mmg_eval($0, $1, 0.5)
  Evaluate(float, float): Color => U.mmg_eval($0, $1, $2)
  op implicit_Color(Color): MinMaxGradient => $1

type ParticleSystemStopBehavior kind=enum extern=UnityEngineParticleSystemStopBehavior
  enum StopEmittingAndClear = 0
  enum StopEmitting = 1

type ParticleSystemSimulationSpace kind=enum extern=UnityEngineParticleSystemSimulationSpace
  enum Local = 0
  enum World = 1
  enum Custom = 2
''')
    ENUMS = {
        'ParticleSystemCurveMode': ['Constant', 'Curve', 'TwoCurves', 'TwoConstants'],
        'ParticleSystemGradientMode': ['Color', 'Gradient', 'TwoColors', 'TwoGradients', 'RandomColor'],
        'ParticleSystemShapeType': ['Sphere', 'SphereShell', 'Hemisphere', 'HemisphereShell', 'Cone', 'Box', 'Mesh', 'ConeShell', 'ConeVolume', 'ConeVolumeShell', 'Circle', 'CircleEdge', 'SingleSidedEdge', 'MeshRenderer', 'SkinnedMeshRenderer', 'BoxShell', 'BoxEdge', 'Donut', 'Rectangle', 'Sprite', 'SpriteRenderer'],
        'ParticleSystemShapeMultiModeValue': ['Random', 'Loop', 'PingPong', 'BurstSpread'],
        'ParticleSystemMeshShapeType': ['Vertex', 'Edge', 'Triangle'],
        'ParticleSystemShapeTextureChannel': ['Red', 'Green', 'Blue', 'Alpha'],
        'ParticleSystemRenderMode': ['Billboard', 'Stretch', 'HorizontalBillboard', 'VerticalBillboard', 'Mesh', 'None'],
        'ParticleSystemRenderSpace': ['View', 'World', 'Local', 'Facing', 'Velocity'],
        'ParticleSystemSortMode': ['None', 'Distance', 'OldestInFront', 'YoungestInFront', 'Depth'],
        'ParticleSystemCollisionType': ['Planes', 'World'],
        'ParticleSystemCollisionMode': ['Collision3D', 'Collision2D'],
        'ParticleSystemCollisionQuality': ['High', 'Medium', 'Low'],
        'ParticleSystemColliderQueryMode': ['Disabled', 'One', 'All'],
        'ParticleSystemAnimationMode': ['Grid', 'Sprites'],
        'ParticleSystemAnimationType': ['WholeSheet', 'SingleRow'],
        'ParticleSystemAnimationRowMode': ['Custom', 'Random', 'MeshIndex'],
        'ParticleSystemAnimationTimeMode': ['Lifetime', 'Speed', 'FPS'],
        'ParticleSystemTrailMode': ['PerParticle', 'Ribbon'],
        'ParticleSystemTrailTextureMode': ['Stretch', 'Tile', 'DistributePerSegment', 'RepeatPerSegment', 'Static'],
        'ParticleSystemSubEmitterType': ['Birth', 'Collision', 'Death', 'Trigger', 'Manual'],
        'ParticleSystemEmitterVelocityMode': ['Transform', 'Rigidbody', 'Custom'],
        'ParticleSystemScalingMode': ['Hierarchy', 'Local', 'Shape'],
        'ParticleSystemStopAction': ['None', 'Disable', 'Destroy', 'Callback'],
        'ParticleSystemCullingMode': ['Automatic', 'PauseAndCatchup', 'Pause', 'AlwaysSimulate'],
        'ParticleSystemRingBufferMode': ['Disabled', 'PauseUntilReplaced', 'LoopUntilReplaced'],
        'ParticleSystemNoiseQuality': ['Low', 'Medium', 'High'],
        'ParticleSystemInheritVelocityMode': ['Initial', 'Current'],
        'ParticleSystemGameObjectFilter': ['LayerMask', 'List', 'LayerMaskAndList'],
        'ParticleSystemOverlapAction': ['Ignore', 'Kill', 'Callback'],
        'ParticleSystemTriggerEventType': ['Inside', 'Outside', 'Enter', 'Exit'],
        'ParticleSystemCustomData': ['Custom1', 'Custom2'],
        'ParticleSystemCustomDataMode': ['Disabled', 'Vector', 'Color'],
        'ParticleSystemGravitySource': ['Physics3D', 'Physics2D'],
        'ParticleSystemMeshDistribution': ['UniformRandom', 'NonUniformRandom'],
    }
    for name, vals in ENUMS.items():
        mangled = 'UnityEngine' + name
        out.append(f'type {name} kind=enum extern={mangled}')
        for i, v in enumerate(vals):
            out.append(f'  enum {v} = {i}')
        out.append('')
    out.append('''type ParticleSystemSubEmitterProperties kind=enum extern=UnityEngineParticleSystemSubEmitterProperties
  enum InheritNothing = 0
  enum InheritEverything = 31
  enum InheritColor = 1
  enum InheritSize = 2
  enum InheritRotation = 4
  enum InheritLifetime = 8
  enum InheritDuration = 16
''')
    # C# spells these as nested types of ParticleSystem
    for tname, _suffix, _kind in MODULES:
        out.append(f'alias ParticleSystem.{tname} = {tname}')
    for tname in ('MinMaxCurve', 'MinMaxGradient', 'EmitParams', 'Burst', 'Particle'):
        out.append(f'alias ParticleSystem.{tname} = {tname}')
    out.append('')
    open(OUT, 'w').write('\n'.join(out) + '\n')
    print('wrote', OUT, len(out), 'lines')


if __name__ == '__main__':
    main()
