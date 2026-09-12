## `U` autoload — Unity engine shims that do not depend on the world (math, transforms,
## components, physics queries, audio, animation, particles, materials, UI, strings, time).
##
## Coordinate conventions: scripts always compute in Unity numbers (left-handed, +Z forward).
## `coord_mode` says how the Godot scene was derived from the Unity one, and every value that
## crosses between a script and a node (positions, directions, rotations, velocities, ray hits)
## is mapped by `to_gd_*` / `from_gd_*`:
##   UNITY  – the scene keeps Unity axes verbatim (test scenes built by hand); identity.
##   UNIDOT – the scene was imported by unidot_importer, which mirrors X (positions x → -x,
##            quaternions (x,y,z,w) → (x,-y,-z,w)); the default for imported worlds.
##   GODOT  – the scene was rotated a half-turn about Y so Unity's +Z forward became Godot's -Z.
## Godot cameras and lights look down -Z, so their nodes carry an extra half-turn (see
## `unity_basis`). The mode comes from the project setting `udon/coord_mode` when present.
extends Node

enum CoordMode { UNITY, GODOT, UNIDOT }
var coord_mode: CoordMode = CoordMode.UNITY

func _init() -> void:
	# Godot's physics layer names (written by the scene importer from Unity's TagManager) override
	# the VRChat default table.
	for i in range(1, 33):
		var nm = ProjectSettings.get_setting("layer_names/3d_physics/layer_%d" % i, "")
		if str(nm) != "":
			_layer_names[str(nm)] = i - 1
	var m = ProjectSettings.get_setting("udon/coord_mode", "")
	match str(m).to_lower():
		"unidot", "mirror_x":
			coord_mode = CoordMode.UNIDOT
		"godot":
			coord_mode = CoordMode.GODOT
		"unity":
			coord_mode = CoordMode.UNITY

var _noise: FastNoiseLite = null
var _debug_lines: Array = []
var _line_data: Dictionary = {}     # node id → Dictionary for LineRenderer emulation
var _anim_params: Dictionary = {}   # node id → Dictionary of animator parameters
var _ps_modules: Dictionary = {}    # node id → Dictionary of particle module adapters
var _ps_states: Dictionary = {}     # GPUParticles3D id → {start, playing, paused, offset}
var _tags: Dictionary = {}          # node id → tag
var _layers: Dictionary = {}        # node id → Unity layer number
var _layer_names: Dictionary = {"Default": 0, "TransparentFX": 1, "Ignore Raycast": 2, "Water": 4, "UI": 5, "Player": 9, "PlayerLocal": 10, "Environment": 11, "UiMenu": 12, "Pickup": 13, "PickupNoEnvironment": 14, "StereoLeft": 15, "StereoRight": 16, "Walkthrough": 17, "MirrorReflection": 18, "reserved2": 19, "reserved3": 20, "reserved4": 21}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

func unsupported(what: String):
	push_warning("udon2godot: unsupported API used: " + what)
	return null

func throw(msg: String) -> void:
	push_error("Udon exception: " + msg)
	assert(false, msg)

# ---------------------------------------------------------------------------
# UdonBehaviour API entry points.
# Converted scripts call these instead of the base-class methods: a call from guest code into a
# base-class GDScript method re-enters the sandbox, and the sandbox allows only a few nested
# VM entries per script. Host-side helpers keep the nesting flat.
# ---------------------------------------------------------------------------

func send_custom_event(b, event_name: String) -> void:
	if b == null or not is_instance_valid(b):
		return
	if b.has_method(event_name):
		b.call(event_name)
	elif b.has_method("SendCustomEvent"):
		b.SendCustomEvent(event_name)
	else:
		push_warning("SendCustomEvent: %s has no event '%s'" % [b.name, event_name])

func send_custom_event_delayed_seconds(b, event_name: String, delay: float, timing: int) -> void:
	if b != null and is_instance_valid(b) and b.has_method("SendCustomEventDelayedSeconds"):
		b.SendCustomEventDelayedSeconds(event_name, delay, timing)

func send_custom_event_delayed_frames(b, event_name: String, frames: int, timing: int) -> void:
	if b != null and is_instance_valid(b) and b.has_method("SendCustomEventDelayedFrames"):
		b.SendCustomEventDelayedFrames(event_name, frames, timing)

func send_custom_network_event(b, target: int, event_name: String, args: Array) -> void:
	if b != null and is_instance_valid(b):
		Udon.send_network_event(b, target, event_name, args)

func request_serialization(b) -> void:
	if b != null and is_instance_valid(b) and b.has_method("RequestSerialization"):
		b.RequestSerialization()

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

func delta_time() -> float:
	return Udon._physics_delta if Udon._in_physics else Udon._delta

func unscaled_delta_time() -> float:
	var ts: float = Engine.time_scale
	return delta_time() / ts if ts > 0.0 else delta_time()

func fixed_delta_time() -> float:
	return 1.0 / float(Engine.physics_ticks_per_second)

func time() -> float:
	return Udon._time

func fixed_time() -> float:
	return Udon._fixed_time

func realtime() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0

# ---------------------------------------------------------------------------
# Math
# ---------------------------------------------------------------------------

func sign(x: float) -> float:
	return 1.0 if x >= 0.0 else -1.0

func round_even(x: float) -> float:
	var r: float = roundf(x)
	if absf(x - floorf(x) - 0.5) < 1e-9:
		var f: float = floorf(x)
		return f if fmod(f, 2.0) == 0.0 else f + 1.0
	return r

func trunc(x: float) -> float:
	return float(int(x))

func f2i(x: float) -> int:
	if is_nan(x):
		return -2147483648
	if x >= 2147483647.0:
		return 2147483647
	if x <= -2147483648.0:
		return -2147483648
	return int(x)

func wrap_i32(v: int) -> int:
	v = v & 0xFFFFFFFF
	return v - 0x100000000 if v >= 0x80000000 else v

func wrap_i16(v: int) -> int:
	v = v & 0xFFFF
	return v - 0x10000 if v >= 0x8000 else v

func wrap_i8(v: int) -> int:
	v = v & 0xFF
	return v - 0x100 if v >= 0x80 else v

func compare(a, b) -> int:
	if a < b:
		return -1
	if a > b:
		return 1
	return 0

func inverse_lerp(a: float, b: float, v: float) -> float:
	if a == b:
		return 0.0
	return clampf((v - a) / (b - a), 0.0, 1.0)

func lerp_angle_deg(a: float, b: float, t: float) -> float:
	return a + delta_angle(a, b) * t

func delta_angle(a: float, b: float) -> float:
	var d: float = fposmod(b - a, 360.0)
	if d > 180.0:
		d -= 360.0
	return d

func move_towards_angle(cur: float, target: float, max_delta: float) -> float:
	var d: float = delta_angle(cur, target)
	if -max_delta < d and d < max_delta:
		return target
	return move_toward(cur, cur + d, max_delta)

func smooth_step(from: float, to: float, t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	t = -2.0 * t * t * t + 3.0 * t * t
	return to * t + from * (1.0 - t)

## Unity's Mathf.SmoothDamp. Returns [value, velocity].
func smooth_damp(current: float, target: float, vel: float, smooth_time: float, max_speed: float, dt: float) -> Array:
	smooth_time = maxf(0.0001, smooth_time)
	var omega: float = 2.0 / smooth_time
	var x: float = omega * dt
	var exp_: float = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change: float = current - target
	var original_to: float = target
	var max_change: float = max_speed * smooth_time
	change = clampf(change, -max_change, max_change)
	target = current - change
	var temp: float = (vel + omega * change) * dt
	vel = (vel - omega * temp) * exp_
	var output: float = target + (change + temp) * exp_
	if (original_to - current > 0.0) == (output > original_to):
		output = original_to
		vel = (output - original_to) / dt
	return [output, vel]

func smooth_damp_angle(current: float, target: float, vel: float, smooth_time: float, max_speed: float, dt: float) -> Array:
	target = current + delta_angle(current, target)
	return smooth_damp(current, target, vel, smooth_time, max_speed, dt)

func vec3_smooth_damp(current: Vector3, target: Vector3, vel: Vector3, smooth_time: float, max_speed: float, dt: float) -> Array:
	var x: Array = smooth_damp(current.x, target.x, vel.x, smooth_time, max_speed, dt)
	var y: Array = smooth_damp(current.y, target.y, vel.y, smooth_time, max_speed, dt)
	var z: Array = smooth_damp(current.z, target.z, vel.z, smooth_time, max_speed, dt)
	return [Vector3(x[0], y[0], z[0]), Vector3(x[1], y[1], z[1])]

func vec2_smooth_damp(current: Vector2, target: Vector2, vel: Vector2, smooth_time: float, max_speed: float, dt: float) -> Array:
	var x: Array = smooth_damp(current.x, target.x, vel.x, smooth_time, max_speed, dt)
	var y: Array = smooth_damp(current.y, target.y, vel.y, smooth_time, max_speed, dt)
	return [Vector2(x[0], y[0]), Vector2(x[1], y[1])]

func perlin_noise(x: float, y: float) -> float:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_noise.frequency = 1.0
	return (_noise.get_noise_2d(x, y) + 1.0) * 0.5

func closest_po2(v: int) -> int:
	var up: int = nearest_po2(v)
	var down: int = up >> 1
	return up if (up - v) <= (v - down) else down

func gamma(value: float, abs_max: float, g: float) -> float:
	var neg: bool = value < 0.0
	var a: float = absf(value)
	if a > abs_max:
		return -a if neg else a
	var r: float = pow(a / abs_max, g) * abs_max
	return -r if neg else r

func min_all(arr: Array):
	var m = arr[0]
	for v in arr:
		if v < m:
			m = v
	return m

func max_all(arr: Array):
	var m = arr[0]
	for v in arr:
		if v > m:
			m = v
	return m

func new_random(seed_: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	if seed_ >= 0:
		r.seed = seed_
	else:
		r.randomize()
	return r

func inside_unit_sphere() -> Vector3:
	while true:
		var v := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		if v.length_squared() <= 1.0:
			return v
	return Vector3.ZERO

func on_unit_sphere() -> Vector3:
	var v := inside_unit_sphere()
	return v.normalized() if v.length_squared() > 0.0 else Vector3.UP

func inside_unit_circle() -> Vector2:
	while true:
		var v := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		if v.length_squared() <= 1.0:
			return v
	return Vector2.ZERO

func random_rotation() -> Quaternion:
	return Quaternion(on_unit_sphere(), randf_range(0.0, TAU)).normalized()

# ---------------------------------------------------------------------------
# Vectors, quaternions, coordinate conventions
# ---------------------------------------------------------------------------

# --- script space ⇄ Godot space -----------------------------------------------------------

## Linear map from script (Unity) space to Godot space; an involution in every mode.
func _mode_basis() -> Basis:
	match coord_mode:
		CoordMode.UNIDOT:
			return Basis(Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0))
		CoordMode.GODOT:
			return Basis(Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, -1.0))
		_:
			return Basis()

## Positions and directions.
func to_gd_v(v: Vector3) -> Vector3:
	match coord_mode:
		CoordMode.UNIDOT:
			return Vector3(-v.x, v.y, v.z)
		CoordMode.GODOT:
			return Vector3(-v.x, v.y, -v.z)
		_:
			return v

func from_gd_v(v: Vector3) -> Vector3:
	return to_gd_v(v)

## Rotations (conjugation by the mode basis).
func to_gd_q(q: Quaternion) -> Quaternion:
	match coord_mode:
		CoordMode.UNIDOT:
			return Quaternion(q.x, -q.y, -q.z, q.w)
		CoordMode.GODOT:
			return Quaternion(-q.x, q.y, -q.z, q.w)
		_:
			return q

func from_gd_q(q: Quaternion) -> Quaternion:
	return to_gd_q(q)

## Axial vectors (angular velocity, torque): a reflection flips them on top of the mirror.
func to_gd_axial(w: Vector3) -> Vector3:
	match coord_mode:
		CoordMode.UNIDOT:
			return Vector3(w.x, -w.y, -w.z)
		CoordMode.GODOT:
			return Vector3(-w.x, w.y, -w.z)
		_:
			return w

func from_gd_axial(w: Vector3) -> Vector3:
	return to_gd_axial(w)

func to_gd_t(t: Transform3D) -> Transform3D:
	if coord_mode == CoordMode.UNITY:
		return t
	var m: Basis = _mode_basis()
	return Transform3D(m * t.basis * m, m * t.origin)

func from_gd_t(t: Transform3D) -> Transform3D:
	return to_gd_t(t)

func from_gd_aabb(b: AABB) -> AABB:
	if coord_mode == CoordMode.UNITY:
		return b
	var p0: Vector3 = from_gd_v(b.position)
	var p1: Vector3 = from_gd_v(b.end)
	return AABB(Vector3(minf(p0.x, p1.x), minf(p0.y, p1.y), minf(p0.z, p1.z)), (p1 - p0).abs())

func to_gd_aabb(b: AABB) -> AABB:
	return from_gd_aabb(b)

## Godot cameras and lights look down -Z while Unity's look along +Z: their node carries an
## extra half-turn about Y relative to the Unity transform they stand for.
const _LOOK_FIX: Basis = Basis(Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, -1.0))

func _looks_down_z(n: Node) -> bool:
	return n is Camera3D or n is Light3D

## Orientation of the Unity transform a node stands for, in Godot space (scale removed).
func unity_basis(n_: Node) -> Basis:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Basis()
	var b: Basis = n.global_transform.basis.orthonormalized()
	return b * _LOOK_FIX if _looks_down_z(n) else b

## The Unity transform a node stands for, in Godot space (scale kept).
func unity_transform(n_: Node) -> Transform3D:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Transform3D()
	var t: Transform3D = n.global_transform
	return Transform3D(t.basis * _LOOK_FIX, t.origin) if _looks_down_z(n) else t

func vec_forward() -> Vector3:
	return Vector3(0.0, 0.0, 1.0)

func vec_back() -> Vector3:
	return Vector3(0.0, 0.0, -1.0)

func forward(n_: Node) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(unity_basis(n) * to_gd_v(Vector3(0.0, 0.0, 1.0))).normalized()

func right(n_: Node) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(unity_basis(n) * to_gd_v(Vector3(1.0, 0.0, 0.0))).normalized()

func up(n_: Node) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(unity_basis(n) * to_gd_v(Vector3(0.0, 1.0, 0.0))).normalized()

## Godot cannot invert a parent transform with a zero scale (Unity tolerates it); positions under
## such parents are left where they are.
func _parent_invertible(n: Node3D) -> bool:
	var p := n.get_parent() as Node3D
	return p == null or not is_zero_approx(p.global_transform.basis.determinant())

func get_position(n_: Node) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		if n_ is Control:
			# UI elements: canvas pixels, Y up like Unity's RectTransform
			var gp: Vector2 = n_.global_position
			return Vector3(gp.x, -gp.y, 0.0)
		return Vector3.ZERO
	return from_gd_v(n.global_position)

func set_position(n_: Node, p: Vector3) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		if n_ is Control:
			n_.global_position = Vector2(p.x, -p.y)
		return
	if not _parent_invertible(n):
		return
	n.global_position = to_gd_v(p)

func get_local_position(n_: Node) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(n.position)

func set_local_position(n_: Node, p: Vector3) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	n.position = to_gd_v(p)

func get_global_rotation(n_: Node) -> Quaternion:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Quaternion()
	return from_gd_q(unity_basis(n).get_rotation_quaternion())

func set_global_rotation(n_: Node, q: Quaternion) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	if not _parent_invertible(n):
		return
	var s: Vector3 = n.global_transform.basis.get_scale()
	var t: Transform3D = n.global_transform
	var b: Basis = Basis(to_gd_q(q).normalized())
	if _looks_down_z(n):
		b = b * _LOOK_FIX
	t.basis = b.scaled(s)
	n.global_transform = t

func get_local_rotation(n_: Node) -> Quaternion:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Quaternion()
	var b: Basis = Basis(n.quaternion)
	if _looks_down_z(n):
		b = b * _LOOK_FIX
	return from_gd_q(b.get_rotation_quaternion())

func set_local_rotation(n_: Node, q: Quaternion) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	var b: Basis = Basis(to_gd_q(q).normalized())
	if _looks_down_z(n):
		b = b * _LOOK_FIX
	n.quaternion = b.get_rotation_quaternion()

## Unity worlds hide physics objects by scaling them to zero; Godot bodies cannot be scaled (and
## a zero scale makes their transforms singular), so such nodes are hidden instead and report the
## requested scale back.
func get_local_scale(n_: Node) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		if n_ is Control:
			return Vector3(n_.scale.x, n_.scale.y, 1.0)
		return Vector3.ONE
	if n.has_meta("udon_zero_scale"):
		return n.get_meta("udon_zero_scale")
	return n.scale

func set_local_scale(n_: Node, s: Vector3) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		if n_ is Control:
			n_.scale = Vector2(s.x, s.y)
		return
	var degenerate: bool = absf(s.x) < 1e-5 or absf(s.y) < 1e-5 or absf(s.z) < 1e-5
	if n is CollisionObject3D:
		if degenerate:
			n.set_meta("udon_zero_scale", s)
			n.visible = false
			return
		if n.has_meta("udon_zero_scale"):
			n.remove_meta("udon_zero_scale")
			n.visible = true
		n.scale = Vector3(absf(s.x), absf(s.y), absf(s.z)).max(Vector3(1e-5, 1e-5, 1e-5)) if not s.is_equal_approx(Vector3.ONE) else Vector3.ONE
		return
	if degenerate:
		n.set_meta("udon_zero_scale", s)
		n.scale = Vector3(1e-5, 1e-5, 1e-5).max(s.abs())
		return
	if n.has_meta("udon_zero_scale"):
		n.remove_meta("udon_zero_scale")
	n.scale = s

func lossy_scale(n_: Node) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return n.global_transform.basis.get_scale()

## Unity localToWorldMatrix / worldToLocalMatrix in script space.
func local_to_world_matrix(n_: Node) -> Transform3D:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Transform3D()
	return from_gd_t(unity_transform(n))

func world_to_local_matrix(n_: Node) -> Transform3D:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Transform3D()
	return from_gd_t(unity_transform(n).affine_inverse())

func set_right(n_: Node, r: Vector3) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	set_global_rotation(n, from_to_rotation(right(n), r) * get_global_rotation(n))

func set_up(n_: Node, u_: Vector3) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	set_global_rotation(n, from_to_rotation(up(n), u_) * get_global_rotation(n))

## Unity Quaternion.Euler (degrees, applied Z then X then Y). Script-space maths never depends
## on the coordinate mode; only values crossing to nodes are converted.
func euler(x: float, y: float, z: float) -> Quaternion:
	var qx := Quaternion(Vector3.RIGHT, deg_to_rad(x))
	var qy := Quaternion(Vector3.UP, deg_to_rad(y))
	var qz := Quaternion(Vector3(0.0, 0.0, 1.0), deg_to_rad(z))
	return (qy * qx * qz).normalized()

func euler_v(v: Vector3) -> Quaternion:
	return euler(v.x, v.y, v.z)

## Inverse of `euler`: Unity-style Euler angles in degrees (Y-X-Z order, 0..360).
func quat_to_euler(q: Quaternion) -> Vector3:
	var e: Vector3 = Basis(q.normalized()).get_euler(EULER_ORDER_YXZ)
	var deg := Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))
	return Vector3(fposmod(deg.x, 360.0), fposmod(deg.y, 360.0), fposmod(deg.z, 360.0))

func angle_axis(angle_deg: float, axis: Vector3) -> Quaternion:
	if axis.length_squared() < 1e-12:
		return Quaternion()
	return Quaternion(axis.normalized(), deg_to_rad(angle_deg))

func quat_axis(q: Quaternion) -> Vector3:
	var a: Vector3 = q.get_axis()
	return a if a.length_squared() > 0.0 else Vector3.RIGHT

## Unity Quaternion.LookRotation: rotation whose forward points along `fwd`.
func look_rotation(fwd: Vector3, up_: Vector3) -> Quaternion:
	if fwd.length_squared() < 1e-12:
		return Quaternion()
	var f: Vector3 = fwd.normalized()
	if up_.length_squared() < 1e-12 or absf(f.dot(up_.normalized())) > 0.9999:
		up_ = Vector3.UP if absf(f.dot(Vector3.UP)) < 0.9999 else Vector3(0.0, 0.0, 1.0)
	var z: Vector3 = f
	var x: Vector3 = up_.cross(z).normalized()
	var y: Vector3 = z.cross(x)
	return Basis(x, y, z).get_rotation_quaternion()

func from_to_rotation(a: Vector3, b: Vector3) -> Quaternion:
	if a.length_squared() < 1e-12 or b.length_squared() < 1e-12:
		return Quaternion()
	var an: Vector3 = a.normalized()
	var bn: Vector3 = b.normalized()
	var d: float = an.dot(bn)
	if d > 0.999999:
		return Quaternion()
	if d < -0.999999:
		var axis: Vector3 = Vector3.RIGHT.cross(an)
		if axis.length_squared() < 1e-6:
			axis = Vector3.UP.cross(an)
		return Quaternion(axis.normalized(), PI)
	var c: Vector3 = an.cross(bn)
	var q := Quaternion(c.x, c.y, c.z, 1.0 + d)
	return q.normalized()

func quat_lerp(a: Quaternion, b: Quaternion, t: float) -> Quaternion:
	if a.dot(b) < 0.0:
		b = -b
	return Quaternion(lerpf(a.x, b.x, t), lerpf(a.y, b.y, t), lerpf(a.z, b.z, t), lerpf(a.w, b.w, t)).normalized()

func quat_rotate_towards(a: Quaternion, b: Quaternion, max_deg: float) -> Quaternion:
	var ang: float = rad_to_deg(a.angle_to(b))
	if ang <= 0.0001:
		return b
	return a.slerp(b, minf(1.0, max_deg / ang))

func vec3_slerp(a: Vector3, b: Vector3, t: float) -> Vector3:
	if a.length_squared() < 1e-12 or b.length_squared() < 1e-12:
		return a.lerp(b, t)
	return a.slerp(b, t)

func vec3_rotate_towards(cur: Vector3, target: Vector3, max_rad: float, max_mag: float) -> Vector3:
	var ang: float = cur.angle_to(target)
	var mag: float = move_toward(cur.length(), target.length(), max_mag)
	if ang <= 1e-6 or cur.length_squared() < 1e-12:
		return target.normalized() * mag if target.length_squared() > 0.0 else cur
	var axis: Vector3 = cur.cross(target)
	if axis.length_squared() < 1e-12:
		axis = Vector3.UP if absf(cur.normalized().dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var r: Vector3 = cur.rotated(axis.normalized(), minf(ang, max_rad))
	return r.normalized() * mag

func project_on_plane(v: Vector3, normal: Vector3) -> Vector3:
	var n2: float = normal.length_squared()
	if n2 < 1e-12:
		return v
	return v - normal * (v.dot(normal) / n2)

func reflect(v: Vector3, normal: Vector3) -> Vector3:
	return v - 2.0 * v.dot(normal) * normal

func ortho_normalize(a: Vector3, b: Vector3) -> Array:
	var an: Vector3 = a.normalized()
	var bn: Vector3 = (b - an * b.dot(an)).normalized()
	return [an, bn]

func matrix_column(t: Transform3D, i: int) -> Vector4:
	match i:
		0:
			return Vector4(t.basis.x.x, t.basis.x.y, t.basis.x.z, 0.0)
		1:
			return Vector4(t.basis.y.x, t.basis.y.y, t.basis.y.z, 0.0)
		2:
			return Vector4(t.basis.z.x, t.basis.z.y, t.basis.z.z, 0.0)
		_:
			return Vector4(t.origin.x, t.origin.y, t.origin.z, 1.0)

func matrix_row(t: Transform3D, i: int) -> Vector4:
	return Vector4(t.basis.x[i], t.basis.y[i], t.basis.z[i], t.origin[i])

func aabb_closest_point(b: AABB, p: Vector3) -> Vector3:
	return Vector3(clampf(p.x, b.position.x, b.end.x), clampf(p.y, b.position.y, b.end.y), clampf(p.z, b.position.z, b.end.z))

# ---------------------------------------------------------------------------
# Transform
# ---------------------------------------------------------------------------

func transform_direction(n_: Node, v: Vector3) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(unity_basis(n) * to_gd_v(v))

func inverse_transform_direction(n_: Node, v: Vector3) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(unity_basis(n).inverse() * to_gd_v(v))

func transform_vector(n_: Node, v: Vector3) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(unity_transform(n).basis * to_gd_v(v))

func inverse_transform_vector(n_: Node, v: Vector3) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(unity_transform(n).basis.inverse() * to_gd_v(v))

func transform_point(n_: Node, p: Vector3) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(unity_transform(n) * to_gd_v(p))

func inverse_transform_point(n_: Node, p: Vector3) -> Vector3:
	var n: Node3D = n_ as Node3D
	if n == null:
		return Vector3.ZERO
	return from_gd_v(unity_transform(n).affine_inverse() * to_gd_v(p))

func look_at(n_: Node, target: Vector3, up_: Vector3) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	var d: Vector3 = target - get_position(n)
	if d.length_squared() < 1e-12:
		return
	set_global_rotation(n, look_rotation(d, up_))

## space: 0 = Self (Unity default), 1 = World
func rotate_euler(n_: Node, euler_deg: Vector3, space: int) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	var q: Quaternion = euler_v(euler_deg)
	if space == 0:
		set_local_rotation(n, (get_local_rotation(n) * q).normalized())
	else:
		set_global_rotation(n, (q * get_global_rotation(n)).normalized())

func rotate_axis(n_: Node, axis: Vector3, angle_deg: float, space: int) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	var q: Quaternion = angle_axis(angle_deg, axis)
	if space == 0:
		set_local_rotation(n, (get_local_rotation(n) * q).normalized())
	else:
		set_global_rotation(n, (q * get_global_rotation(n)).normalized())

func rotate_around(n_: Node, point: Vector3, axis: Vector3, angle_deg: float) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	var q: Quaternion = angle_axis(angle_deg, axis)
	var dir: Vector3 = get_position(n) - point
	set_position(n, point + q * dir)
	set_global_rotation(n, (q * get_global_rotation(n)).normalized())

func translate(n_: Node, v: Vector3, space: int) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	if space == 0:
		set_position(n, get_position(n) + transform_direction(n, v))
	else:
		set_position(n, get_position(n) + v)

func translate_relative(n_: Node, v: Vector3, relative_to: Node) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	if relative_to == null:
		set_position(n, get_position(n) + v)
	else:
		set_position(n, get_position(n) + transform_direction(relative_to, v))

func set_position_and_rotation(n_: Node, p: Vector3, q: Quaternion) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	set_position(n, p)
	set_global_rotation(n, q)

func set_local_position_and_rotation(n_: Node, p: Vector3, q: Quaternion) -> void:
	var n: Node3D = n_ as Node3D
	if n == null:
		return
	set_local_position(n, p)
	set_local_rotation(n, q)

func set_parent(n: Node, parent: Node, world_stays: bool) -> void:
	if n == null:
		return
	if parent == null:
		parent = n.get_tree().current_scene if n.is_inside_tree() else null
	if n.get_parent() == parent:
		return
	if n.is_inside_tree() and parent != null:
		n.reparent(parent, world_stays)
	elif parent != null:
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		parent.add_child(n)

func root_of(n: Node) -> Node:
	var cur: Node = n
	while cur.get_parent() != null and cur.get_parent() != cur.get_tree().root:
		cur = cur.get_parent()
	return cur

func is_child_of(n: Node, parent: Node) -> bool:
	return parent != null and (parent == n or parent.is_ancestor_of(n))

func detach_children(n: Node) -> void:
	for c in n.get_children():
		c.reparent(n.get_parent(), true)

func set_sibling_index(n: Node, i: int) -> void:
	var p: Node = n.get_parent()
	if p != null:
		p.move_child(n, i if i >= 0 else p.get_child_count() - 1)

# ---------------------------------------------------------------------------
# GameObject / components
# ---------------------------------------------------------------------------

func set_active(n: Node, active: bool) -> void:
	if n == null:
		return
	var was: bool = is_active(n)
	if n is CanvasItem or n is Node3D:
		n.visible = active
	n.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	if n is CollisionObject3D:
		n.set_deferred("disable_mode", CollisionObject3D.DISABLE_MODE_REMOVE)
	if was != active:
		var ev: String = "OnEnable" if active else "OnDisable"
		if n.has_method(ev) and n.get("enabled") != false:
			n.call(ev)

func is_active(n: Node) -> bool:
	if n == null:
		return false
	return n.process_mode != Node.PROCESS_MODE_DISABLED

func is_active_in_hierarchy(n: Node) -> bool:
	if n == null:
		return false
	return n.can_process() and is_active(n)

func get_enabled(n: Node) -> bool:
	if n == null:
		return false
	var e = n.get("enabled")
	if e != null:
		return e
	if n is CanvasItem or n is Node3D:
		return n.visible
	return true

func set_enabled(n: Node, v: bool) -> void:
	if n == null:
		return
	if n.get("enabled") != null:
		n.set("enabled", v)
	elif n is CanvasItem or n is Node3D:
		n.visible = v

func new_game_object(name_: String) -> Node3D:
	var n := Node3D.new()
	n.name = name_
	var scene: Node = get_tree().current_scene
	if scene != null:
		scene.add_child(n)
	return n

func get_tag(n: Node) -> String:
	if n == null:
		return "Untagged"
	var t = _tags.get(n.get_instance_id())
	if t != null:
		return t
	for g in n.get_groups():
		if String(g).begins_with("tag:"):
			return String(g).substr(4)
	return "Untagged"

func set_tag(n: Node, tag: String) -> void:
	if n != null:
		_tags[n.get_instance_id()] = tag

func compare_tag(n: Node, tag: String) -> bool:
	return get_tag(n) == tag

func get_layer(n: Node) -> int:
	if n == null:
		return 0
	var l = _layers.get(n.get_instance_id())
	if l != null:
		return l
	if n is CollisionObject3D:
		var mask: int = n.collision_layer
		for i in range(32):
			if mask & (1 << i):
				return i
	return 0

func set_layer(n: Node, layer: int) -> void:
	if n == null:
		return
	_layers[n.get_instance_id()] = layer
	if n is CollisionObject3D:
		n.collision_layer = 1 << layer
	if n is VisualInstance3D:
		n.layers = 1 << (layer % 20)

func layer_mask(names: Array) -> int:
	var m: int = 0
	for nm in names:
		var l: int = name_to_layer(nm)
		if l >= 0:
			m |= 1 << l
	return m

func name_to_layer(name_: String) -> int:
	return _layer_names.get(name_, -1)

func layer_to_name(layer: int) -> String:
	for k in _layer_names.keys():
		if _layer_names[k] == layer:
			return k
	return ""

## Does `n` match a runtime type name (Godot class or UdonSharp class name)?
## Unity component types that have no single Godot class: name → Godot classes ("@udon" = any
## converted behaviour).
const _TYPE_ALIASES: Dictionary = {
	"Component": ["Node"], "Behaviour": ["Node"], "MonoBehaviour": ["@udon"],
	"Collider": ["CollisionObject3D", "CollisionShape3D"],
	"BoxCollider": ["CollisionObject3D", "CollisionShape3D"], "SphereCollider": ["CollisionObject3D", "CollisionShape3D"],
	"CapsuleCollider": ["CollisionObject3D", "CollisionShape3D"], "MeshCollider": ["CollisionObject3D", "CollisionShape3D"],
	"Animator": ["AnimationPlayer", "AnimationTree"],
	"LineRenderer": ["MeshInstance3D"], "TrailRenderer": ["MeshInstance3D", "GPUParticles3D"],
	"ParticleSystem": ["GPUParticles3D"], "ParticleSystemRenderer": ["GPUParticles3D"],
	"TextMeshPro": ["Label3D"], "EventSystem": ["Node"],
	# bake-time / editor components whose settings only round-trip: they "live" on the nodes that
	# carry the geometry they would have affected
	"NavMeshModifier": ["NavigationRegion3D", "MeshInstance3D", "@meta:udon_navmesh_modifier"],
	# constraints are solved by the runtime for any Node3D a script configures them on
	"IConstraint": ["Node3D"], "PositionConstraint": ["Node3D"], "RotationConstraint": ["Node3D"], "ScaleConstraint": ["Node3D"],
	"ParentConstraint": ["Node3D"], "AimConstraint": ["Node3D"], "LookAtConstraint": ["Node3D"],
	"VRCConstraintBase": ["Node3D"], "VRCPositionConstraint": ["Node3D"], "VRCRotationConstraint": ["Node3D"], "VRCScaleConstraint": ["Node3D"],
	"VRCParentConstraint": ["Node3D"], "VRCAimConstraint": ["Node3D"], "VRCLookAtConstraint": ["Node3D"],
	"NavMeshModifierVolume": ["NavigationRegion3D", "@meta:udon_navmesh_volume"],
	"OcclusionPortal": ["OccluderInstance3D", "@meta:udon_occlusion_portal"],
	"PostProcessingPostProcessVolume": ["WorldEnvironment", "@meta:udon_post_process"], "PostProcessVolume": ["WorldEnvironment", "@meta:udon_post_process"],
	# uGUI / TextMeshPro: the converter passes the Unity names for Control-based components.
	# "@clip" = a clipping Control, "@meta:x" = a node carrying metadata x (set by the importer).
	"Graphic": ["Control"], "MaskableGraphic": ["Control"], "RectTransform": ["Control"], "CanvasRenderer": ["Control"],
	"LayoutElement": ["Control"], "ContentSizeFitter": ["Control"], "AspectRatioFitter": ["Control"],
	"Text": ["Label", "RichTextLabel"], "TMP_Text": ["Label", "RichTextLabel"], "TextMeshProUGUI": ["Label", "RichTextLabel"],
	"Image": ["TextureRect", "Panel", "ColorRect", "BaseButton", "@meta:udon_image"], "RawImage": ["TextureRect"],
	"Selectable": ["BaseButton", "Range", "LineEdit", "OptionButton", "TextEdit"], "Button": ["BaseButton"], "Toggle": ["BaseButton"],
	"Slider": ["Range"], "Scrollbar": ["ScrollBar"], "Dropdown": ["OptionButton"], "TMP_Dropdown": ["OptionButton"],
	"InputField": ["LineEdit", "TextEdit"], "TMP_InputField": ["LineEdit", "TextEdit"], "VRCUrlInputField": ["LineEdit", "TextEdit"],
	"ScrollRect": ["ScrollContainer"], "Mask": ["@clip", "Control"], "RectMask2D": ["@clip", "Control"],
	"CanvasGroup": ["@meta:udon_canvas_group", "Control"], "Outline": ["@meta:udon_effect_outline", "Label", "RichTextLabel", "Button"],
	"Shadow": ["@meta:udon_effect_shadow", "Label", "RichTextLabel", "Button"], "BaseMeshEffect": ["Label", "RichTextLabel", "Button"],
	"Canvas": ["@meta:udon_canvas", "CanvasLayer"], "CanvasScaler": ["@meta:udon_canvas", "CanvasLayer"], "GraphicRaycaster": ["@meta:udon_canvas", "CanvasLayer"],
	"HorizontalLayoutGroup": ["HBoxContainer", "BoxContainer"], "VerticalLayoutGroup": ["VBoxContainer", "BoxContainer"],
	"HorizontalOrVerticalLayoutGroup": ["BoxContainer"], "GridLayoutGroup": ["GridContainer"], "LayoutGroup": ["Container"],
}

## VRC components are provider adapters: a node "has" one when the world registered it
## (`Udon.pickup(node)` etc.), put it in the `udon_<kind>` group, or implements the surface itself.
const _VRC_COMPONENTS: Dictionary = {
	"VRC_Pickup": "pickup", "VRCPickup": "pickup", "VRCStation": "station", "VRC_Station": "station",
	"VRCObjectSync": "object_sync", "VRC_ObjectSync": "object_sync", "VRCObjectPool": "object_pool",
	"VRCAvatarPedestal": "avatar_pedestal", "VRC_AvatarPedestal": "avatar_pedestal", "VRCPortalMarker": "portal",
	"VRC_PortalMarker": "portal", "VRCMirrorReflection": "mirror", "VRC_MirrorReflection": "mirror",
	"BaseVRCVideoPlayer": "video", "VRCUnityVideoPlayer": "video", "VRCAVProVideoPlayer": "video",
}

func node_is_type(n, type_name: String) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	if type_name == "" or type_name == "Node" or type_name == "Object":
		return true
	if n is Object and n.is_class(type_name):
		return true
	if _VRC_COMPONENTS.has(type_name):
		return n is Node and Udon.has_component(n, _VRC_COMPONENTS[type_name])
	if (type_name == "Canvas" or type_name == "CanvasLayer") and n is Node and n.has_meta("udon_canvas"):
		return true  # world-space canvas container (udon_integration); GetComponent passes Godot class names
	if _TYPE_ALIASES.has(type_name):
		for a in _TYPE_ALIASES[type_name]:
			if a == "@udon":
				if n is Node and n.has_method("udon_class"):
					return true
			elif a == "@clip":
				if n is Control and n.clip_contents:
					return true
			elif a.begins_with("@meta:"):
				if n is Node and n.has_meta(a.substr(6)):
					return true
			elif n.is_class(a):
				return true
	if n is Node and n.has_method("udon_is") and n.udon_is(type_name):
		return true
	var s = n.get_script() if n is Object else null
	while s != null:
		if s.get_global_name() == type_name:
			return true
		s = s.get_base_script()
	return false

## Unity GetComponent: the node itself, then direct children that are "component-like".
## The root Control of a world-space canvas container, null for other nodes.
func canvas_root(n: Node) -> Control:
	if n == null or not n.has_meta("udon_canvas"):
		return null
	var cfg: Dictionary = n.get_meta("udon_canvas")
	return n.get_node_or_null(cfg.get("root", NodePath())) as Control

func get_component(n: Node, type_name: String):
	if n == null or not is_instance_valid(n):
		return null
	if node_is_type(n, type_name):
		return n
	# UI components of a world-space canvas live on its root Control
	var croot := canvas_root(n)
	if croot != null and node_is_type(croot, type_name):
		return croot
	for c in n.get_children():
		if _is_component_child(c) and node_is_type(c, type_name):
			return c
	return null

## A child that stands for a separate GameObject (physics body/area, plain spatial, scripted
## behaviour) is not a component of its parent; helper nodes (shapes, meshes, audio, lights...) are.
const _UNIDOT_COLLIDER_NAMES: Array = ["BoxCollider", "SphereCollider", "CapsuleCollider", "MeshCollider", "WheelCollider", "TerrainCollider", "CharacterController"]
# helper children unidot_importer creates for non-collider components of a GameObject
const _UNIDOT_HELPER_NAMES: Array = ["MeshRenderer", "SkinnedMeshRenderer", "Camera", "Light", "AudioSource", "ParticleSystem", "LineRenderer", "TrailRenderer", "ReflectionProbe", "VideoPlayer", "CanvasPlane", "Viewport"]

## True for a node that unidot_importer (or udon_integration) created to hold one component of
## its parent GameObject.
func _is_helper_child(c: Node) -> bool:
	if c == null or c.get_parent() == null:
		return false
	if c is CollisionShape3D or c is CollisionShape2D or c.has_meta("udon_component_child"):
		return true
	var nm := String(c.name)
	return nm.trim_suffix("2") in _UNIDOT_COLLIDER_NAMES or nm in _UNIDOT_HELPER_NAMES or nm.begins_with("UiShape")

## Component.gameObject / Component.transform: the GameObject node owning a component node.
## Hand-built scenes put components on the object node itself, so those map to themselves.
func game_object(n: Node) -> Node:
	var cur: Node = n
	for _i in range(4):
		if cur == null or not _is_helper_child(cur):
			break
		cur = cur.get_parent()
	return cur

## Transform.childCount / GetChild: only child GameObjects count, not the helper nodes the scene
## importer adds for components (MeshRenderer, colliders, audio ...).
func go_children(n: Node) -> Array:
	var out: Array = []
	if n == null:
		return out
	for c in n.get_children():
		if not _is_component_child(c):
			out.append(c)
	return out

func go_child_count(n: Node) -> int:
	return go_children(n).size()

func go_child(n: Node, i: int) -> Node:
	var kids: Array = go_children(n)
	return kids[i] if i >= 0 and i < kids.size() else null

func _is_component_child(c: Node) -> bool:
	if c.has_meta("udon_component_child"):
		return true  # a second UdonSharp behaviour of the same GameObject
	if c is CollisionObject3D or c is CollisionObject2D:
		# unidot_importer turns a Collider without a Rigidbody into a StaticBody3D/Area3D child
		# named after the collider type; those are components, other bodies are objects
		return String(c.name).trim_suffix("2") in _UNIDOT_COLLIDER_NAMES or String(c.name).begins_with("UiShape")
	var cls: String = c.get_class()
	if cls == "Node3D" or cls == "Node2D" or cls == "Node":
		return false
	if c.has_method("udon_class"):
		return false
	return true

func get_components(n: Node, type_name: String) -> Array:
	var out: Array = []
	if n == null:
		return out
	if node_is_type(n, type_name):
		out.append(n)
	for c in n.get_children():
		if _is_component_child(c) and node_is_type(c, type_name):
			out.append(c)
	return out

## Unity GetComponentInChildren: the object itself is always considered; inactive descendants
## are skipped unless include_inactive.
func get_component_in_children(n: Node, type_name: String, include_inactive: bool):
	if n == null:
		return null
	if node_is_type(n, type_name):
		return n
	for c in n.get_children():
		var r = _find_in_children(c, type_name, include_inactive)
		if r != null:
			return r
	return null

func _find_in_children(n: Node, type_name: String, include_inactive: bool):
	if not include_inactive and not is_active(n):
		return null
	if node_is_type(n, type_name):
		return n
	for c in n.get_children():
		var r = _find_in_children(c, type_name, include_inactive)
		if r != null:
			return r
	return null

func get_components_in_children(n: Node, type_name: String, include_inactive: bool) -> Array:
	var out: Array = []
	if n == null:
		return out
	if node_is_type(n, type_name):
		out.append(n)
	for c in n.get_children():
		_collect_children(c, type_name, include_inactive, out)
	return out

func _collect_children(n: Node, type_name: String, include_inactive: bool, out: Array) -> void:
	if n == null:
		return
	if not include_inactive and not is_active(n):
		return
	if node_is_type(n, type_name):
		out.append(n)
	for c in n.get_children():
		_collect_children(c, type_name, include_inactive, out)

func get_component_in_parent(n: Node, type_name: String, _include_inactive: bool):
	var cur: Node = n
	while cur != null:
		if node_is_type(cur, type_name):
			return cur
		cur = cur.get_parent()
	return null

func get_components_in_parent(n: Node, type_name: String, _include_inactive: bool) -> Array:
	var out: Array = []
	var cur: Node = n
	while cur != null:
		if node_is_type(cur, type_name):
			out.append(cur)
		cur = cur.get_parent()
	return out

func add_component(n: Node, type_name: String):
	if ClassDB.class_exists(type_name):
		var c = ClassDB.instantiate(type_name)
		if c is Node:
			n.add_child(c)
			return c
	push_warning("AddComponent: cannot create " + type_name)
	return null

## Unity names may contain characters Godot node names cannot (`.`, `:`, `@`, `%`); Godot
## replaced them with `_` when the scene was built, so paths from scripts are mapped the same way.
func node_path_from_unity(path: String) -> String:
	var parts: PackedStringArray = path.split("/")
	for i in range(parts.size()):
		if parts[i] != "" and parts[i] != "." and parts[i] != "..":
			parts[i] = parts[i].validate_node_name()
	return "/".join(parts)

## Transform.Find: a child (or child path) by Unity name. Children of a converted Canvas live in
## its viewport (`udon_canvas` metadata), so each step also looks there.
func find_transform(n: Node, path: String) -> Node:
	if n == null or path == "":
		return null
	var np: String = node_path_from_unity(path)
	var r: Node = n.get_node_or_null(np)
	if r != null:
		return r
	var cur: Node = n
	for seg in np.split("/"):
		if seg == "" or seg == ".":
			continue
		if seg == "..":
			cur = cur.get_parent()
			if cur == null:
				return null
			continue
		var next: Node = cur.get_node_or_null(seg)
		if next == null and cur.has_meta("udon_canvas"):
			var croot: Node = cur.get_node_or_null(cur.get_meta("udon_canvas").get("root", NodePath()))
			if croot != null:
				next = croot.get_node_or_null(seg)
		if next == null:
			return null
		cur = next
	return cur

func find_object(name_: String) -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	var np: String = node_path_from_unity(name_)
	if name_.begins_with("/"):
		return scene.get_node_or_null(np.substr(1))
	if np.contains("/"):
		var first: Node = scene.find_child(np.get_slice("/", 0), true, false)
		return first.get_node_or_null(np.substr(np.find("/") + 1)) if first != null else null
	return scene.find_child(np, true, false)

func find_with_tag(tag: String) -> Node:
	var all: Array = find_all_with_tag(tag)
	return all[0] if not all.is_empty() else null

func find_all_with_tag(tag: String) -> Array:
	var out: Array = get_tree().get_nodes_in_group("tag:" + tag)
	for id in _tags.keys():
		if _tags[id] == tag:
			var o = instance_from_id(id)
			if o != null and not out.has(o):
				out.append(o)
	return out

func find_object_of_type(type_name: String):
	var all: Array = get_components_in_children(get_tree().current_scene, type_name, true)
	return all[0] if not all.is_empty() else null

func find_objects_of_type(type_name: String) -> Array:
	return get_components_in_children(get_tree().current_scene, type_name, true)

func send_message(n: Node, method: String, arg) -> void:
	if n != null and n.has_method(method):
		if arg == null:
			n.call(method)
		else:
			n.call(method, arg)

func broadcast_message(n: Node, method: String, arg) -> void:
	send_message(n, method, arg)
	for c in n.get_children():
		broadcast_message(c, method, arg)

func obj_eq(a, b) -> bool:
	var av: bool = a != null and is_instance_valid(a)
	var bv: bool = b != null and is_instance_valid(b)
	if not av and not bv:
		return true
	return a == b

func is_type(v, type_name: String) -> bool:
	if v == null:
		return false
	if v is Object:
		return node_is_type(v, type_name)
	return type_name == builtin_type_name(v)

func as_type(v, type_name: String):
	return v if is_type(v, type_name) else null

func type_of(v) -> String:
	if v == null:
		return "null"
	if v is Object:
		if v.has_method("udon_class"):
			return v.udon_class()
		var s = v.get_script()
		if s != null and s.get_global_name() != "":
			return s.get_global_name()
		return v.get_class()
	return builtin_type_name(v)

func builtin_type_name(v) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "bool"
		TYPE_INT:
			return "int"
		TYPE_FLOAT:
			return "float"
		TYPE_STRING, TYPE_STRING_NAME:
			return "string"
		TYPE_VECTOR3:
			return "Vector3"
		TYPE_VECTOR2:
			return "Vector2"
		TYPE_QUATERNION:
			return "Quaternion"
		TYPE_COLOR:
			return "Color"
		TYPE_ARRAY:
			return "Array"
		TYPE_DICTIONARY:
			return "Dictionary"
		_:
			return type_string(typeof(v))

func type_is_subclass(a: String, b: String) -> bool:
	return ClassDB.is_parent_class(a, b)

func string_to_hash(s: String) -> int:
	return shader_prop_id(s)

func set_global_shader_param(id, value) -> void:
	RenderingServer.global_shader_parameter_set(_shader_param_name(id), value)

func find_shader(_name: String) -> Shader:
	return null

# ---------------------------------------------------------------------------
# Rigidbody
# ---------------------------------------------------------------------------

func rb_set_kinematic(rb: RigidBody3D, kinematic: bool) -> void:
	rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	rb.freeze = kinematic

func rb_get_freeze_rotation(rb: RigidBody3D) -> bool:
	return rb.axis_lock_angular_x and rb.axis_lock_angular_y and rb.axis_lock_angular_z

func rb_set_freeze_rotation(rb: RigidBody3D, v: bool) -> void:
	rb.axis_lock_angular_x = v
	rb.axis_lock_angular_y = v
	rb.axis_lock_angular_z = v

func rb_get_constraints(rb: RigidBody3D) -> int:
	var c: int = 0
	if rb.axis_lock_linear_x:
		c |= 2
	if rb.axis_lock_linear_y:
		c |= 4
	if rb.axis_lock_linear_z:
		c |= 8
	if rb.axis_lock_angular_x:
		c |= 16
	if rb.axis_lock_angular_y:
		c |= 32
	if rb.axis_lock_angular_z:
		c |= 64
	return c

func rb_set_constraints(rb: RigidBody3D, c: int) -> void:
	rb.axis_lock_linear_x = (c & 2) != 0
	rb.axis_lock_linear_y = (c & 4) != 0
	rb.axis_lock_linear_z = (c & 8) != 0
	rb.axis_lock_angular_x = (c & 16) != 0
	rb.axis_lock_angular_y = (c & 32) != 0
	rb.axis_lock_angular_z = (c & 64) != 0

func rb_set_center_of_mass(rb: RigidBody3D, v: Vector3) -> void:
	rb.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	rb.center_of_mass = to_gd_v(v)

func rb_get_center_of_mass(rb: RigidBody3D) -> Vector3:
	return from_gd_v(rb.center_of_mass)

func rb_world_center_of_mass(rb: RigidBody3D) -> Vector3:
	return from_gd_v(rb.to_global(rb.center_of_mass))

func rb_get_velocity(rb: RigidBody3D) -> Vector3:
	return from_gd_v(rb.linear_velocity)

func rb_set_velocity(rb: RigidBody3D, v: Vector3) -> void:
	rb.linear_velocity = to_gd_v(v)

func rb_get_angular_velocity(rb: RigidBody3D) -> Vector3:
	return from_gd_axial(rb.angular_velocity)

func rb_set_angular_velocity(rb: RigidBody3D, w: Vector3) -> void:
	rb.angular_velocity = to_gd_axial(w)

func rb_get_max_angular_velocity(_rb: RigidBody3D) -> float:
	return 7.0

func rb_set_max_angular_velocity(_rb: RigidBody3D, _v: float) -> void:
	pass

func rb_set_detect_collisions(rb: RigidBody3D, v: bool) -> void:
	for c in rb.get_children():
		if c is CollisionShape3D:
			c.disabled = not v

## ForceMode: Force=0 Impulse=1 VelocityChange=2 Acceleration=5
func rb_add_force(rb: RigidBody3D, f_u: Vector3, mode: int) -> void:
	var f: Vector3 = to_gd_v(f_u)
	_rb_track(rb, _rb_force_equiv(rb, f, mode), Vector3.ZERO)
	match mode:
		1:
			rb.apply_central_impulse(f)
		2:
			rb.apply_central_impulse(f * rb.mass)
		5:
			rb.apply_central_force(f * rb.mass)
		_:
			rb.apply_central_force(f)

func rb_add_torque(rb: RigidBody3D, t_u: Vector3, mode: int) -> void:
	var t: Vector3 = to_gd_axial(t_u)
	_rb_track(rb, Vector3.ZERO, _rb_force_equiv(rb, t, mode))
	match mode:
		1:
			rb.apply_torque_impulse(t)
		2:
			rb.apply_torque_impulse(t * rb.mass)
		5:
			rb.apply_torque(t * rb.mass)
		_:
			rb.apply_torque(t)

func rb_add_force_at_position(rb: RigidBody3D, f_u: Vector3, pos: Vector3, mode: int) -> void:
	var f: Vector3 = to_gd_v(f_u)
	var offset: Vector3 = to_gd_v(pos) - rb.global_position
	var fe: Vector3 = _rb_force_equiv(rb, f, mode)
	_rb_track(rb, fe, offset.cross(fe))
	match mode:
		1:
			rb.apply_impulse(f, offset)
		2:
			rb.apply_impulse(f * rb.mass, offset)
		5:
			rb.apply_force(f * rb.mass, offset)
		_:
			rb.apply_force(f, offset)

func rb_add_explosion_force(rb: RigidBody3D, force: float, origin: Vector3, radius: float, upwards: float, mode: int) -> void:
	var p: Vector3 = get_position(rb)
	var d: Vector3 = p - origin
	var dist: float = d.length()
	if radius > 0.0 and dist > radius:
		return
	var falloff: float = 1.0 - (dist / radius if radius > 0.0 else 0.0)
	var dir: Vector3 = (d + Vector3(0.0, upwards, 0.0)).normalized() if dist > 1e-6 else Vector3.UP
	rb_add_force(rb, dir * force * falloff, mode)

func rb_move_position(rb: RigidBody3D, p: Vector3) -> void:
	if rb.freeze:
		set_position(rb, p)
	else:
		var dt: float = fixed_delta_time()
		rb.linear_velocity = (to_gd_v(p) - rb.global_position) / dt

func rb_move_rotation(rb: RigidBody3D, q: Quaternion) -> void:
	if rb.freeze:
		set_global_rotation(rb, q)
	else:
		var dt: float = fixed_delta_time()
		var delta: Quaternion = (q * get_global_rotation(rb).inverse()).normalized()
		var axis: Vector3 = delta.get_axis()
		var ang: float = delta.get_angle()
		if ang > PI:
			ang -= TAU
		rb.angular_velocity = to_gd_axial(axis * ang / dt) if axis.length_squared() > 0.0 else Vector3.ZERO

func rb_point_velocity(rb: RigidBody3D, p: Vector3) -> Vector3:
	return from_gd_v(rb.linear_velocity + rb.angular_velocity.cross(to_gd_v(p) - rb.to_global(rb.center_of_mass)))

func rb_relative_point_velocity(rb: RigidBody3D, local_p: Vector3) -> Vector3:
	return from_gd_v(rb.linear_velocity + rb.angular_velocity.cross(rb.to_global(to_gd_v(local_p)) - rb.to_global(rb.center_of_mass)))

func rb_sweep_test_all(rb: RigidBody3D, dir_u: Vector3, dist: float) -> Array:
	var h: Dictionary = rb_sweep_test(rb, dir_u, dist)
	return [h] if not h.is_empty() else []

func rb_sweep_test(rb: RigidBody3D, dir_u: Vector3, dist: float) -> Dictionary:
	var dir: Vector3 = to_gd_v(dir_u)
	var space := rb.get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	for c in rb.get_children():
		if c is CollisionShape3D and c.shape != null:
			params.shape = c.shape
			params.transform = c.global_transform
			break
	if params.shape == null:
		return {}
	params.exclude = [rb.get_rid()]
	var res: Array = _cast_refined3d(space, params, dir.normalized(), dist if is_finite(dist) else 100000.0)
	if res.is_empty():
		return {}
	var hit: Dictionary = {"position": from_gd_v(rb.global_position + dir.normalized() * res[0]), "normal": -dir_u.normalized(), "distance": res[0], "collider": null}
	params.transform = Transform3D(params.transform.basis, res[1])
	params.motion = Vector3.ZERO
	var rest: Dictionary = space.get_rest_info(params)
	if rest.has("collider_id"):
		hit["collider"] = instance_from_id(rest["collider_id"])
		hit["position"] = from_gd_v(rest.get("point", hit["position"]))
		hit["normal"] = from_gd_v(rest.get("normal", -dir.normalized()))
	return hit

# ---------------------------------------------------------------------------
# Colliders / physics queries
# ---------------------------------------------------------------------------

func _collision_object(n: Node) -> CollisionObject3D:
	if n is CollisionObject3D:
		return n
	if n is CollisionShape3D and n.get_parent() is CollisionObject3D:
		return n.get_parent()
	if n != null:
		for c in n.get_children():
			if c is CollisionObject3D:
				return c
	return null

func collider_get_enabled(n: Node) -> bool:
	if n is CollisionShape3D:
		return not n.disabled
	var co := _collision_object(n)
	if co == null:
		return false
	var shapes: int = 0
	for c in co.get_children():
		if c is CollisionShape3D:
			shapes += 1
			if not c.disabled:
				return true
	return shapes == 0 and co.collision_layer != 0

func collider_set_enabled(n: Node, v: bool) -> void:
	if n is CollisionShape3D:
		n.disabled = not v
		return
	var co := _collision_object(n)
	if co != null:
		for c in co.get_children():
			if c is CollisionShape3D:
				c.disabled = not v

func collider_is_trigger(n: Node) -> bool:
	return _collision_object(n) is Area3D

func collider_set_trigger(_n: Node, _v: bool) -> void:
	push_warning("Collider.isTrigger cannot be changed at run time in Godot (use an Area3D)")

func collider_bounds(n: Node) -> AABB:
	return from_gd_aabb(_collider_bounds_gd(n))

func _collider_bounds_gd(n: Node) -> AABB:
	var co := _collision_object(n)
	var aabb := AABB()
	var first: bool = true
	if co != null:
		for c in co.get_children():
			if c is CollisionShape3D and c.shape != null:
				var local: AABB = c.shape.get_debug_mesh().get_aabb() if c.shape.get_debug_mesh() != null else AABB(Vector3.ZERO, Vector3.ONE)
				var world: AABB = c.global_transform * local
				aabb = world if first else aabb.merge(world)
				first = false
	if first and n is VisualInstance3D:
		return n.global_transform * n.get_aabb()
	if first and n is Node3D:
		return AABB(n.global_position, Vector3.ZERO)
	return aabb

func collider_attached_rigidbody(n: Node) -> RigidBody3D:
	var cur: Node = n
	while cur != null:
		if cur is RigidBody3D:
			return cur
		cur = cur.get_parent()
	return null

func collider_material(_n: Node) -> PhysicsMaterial:
	var co := _collision_object(_n)
	if co is PhysicsBody3D:
		return co.physics_material_override
	return null

func collider_set_material(n: Node, m: PhysicsMaterial) -> void:
	var co := _collision_object(n)
	if co is PhysicsBody3D:
		co.physics_material_override = m

func collider_closest_point(n: Node, p: Vector3) -> Vector3:
	return aabb_closest_point(collider_bounds(n), p)

func collider_raycast(n: Node, ray: Dictionary, dist: float) -> Dictionary:
	var hit: Dictionary = raycast(ray.origin, ray.direction, dist, -1, 2)
	if hit.is_empty():
		return {}
	var co := _collision_object(n)
	if co != null and hit.get("collider") != co:
		return {}
	return hit

func shape_of(n: Node) -> CollisionShape3D:
	if n is CollisionShape3D:
		return n
	var co := _collision_object(n)
	if co != null:
		for c in co.get_children():
			if c is CollisionShape3D:
				return c
	return null

func shape_get_center(n: Node) -> Vector3:
	var s := shape_of(n)
	return s.position if s != null else Vector3.ZERO

func shape_set_center(n: Node, v: Vector3) -> void:
	var s := shape_of(n)
	if s != null:
		s.position = v

func shape_get_size(n: Node) -> Vector3:
	var s := shape_of(n)
	if s != null and s.shape is BoxShape3D:
		return s.shape.size
	return Vector3.ONE

func shape_set_size(n: Node, v: Vector3) -> void:
	var s := shape_of(n)
	if s != null and s.shape is BoxShape3D:
		s.shape.size = v

func shape_get_radius(n: Node) -> float:
	var s := shape_of(n)
	if s != null and (s.shape is SphereShape3D or s.shape is CapsuleShape3D or s.shape is CylinderShape3D):
		return s.shape.radius
	return 0.5

func shape_set_radius(n: Node, v: float) -> void:
	var s := shape_of(n)
	if s != null and (s.shape is SphereShape3D or s.shape is CapsuleShape3D or s.shape is CylinderShape3D):
		s.shape.radius = v

func shape_get_height(n: Node) -> float:
	var s := shape_of(n)
	if s != null and (s.shape is CapsuleShape3D or s.shape is CylinderShape3D):
		return s.shape.height
	return 2.0

func shape_set_height(n: Node, v: float) -> void:
	var s := shape_of(n)
	if s != null and (s.shape is CapsuleShape3D or s.shape is CylinderShape3D):
		s.shape.height = v

func mesh_of(n: Node) -> Mesh:
	if n is MeshInstance3D:
		return n.mesh
	if n != null:
		for c in n.get_children():
			if c is MeshInstance3D:
				return c.mesh
	return null

func gravity() -> Vector3:
	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var v: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	return from_gd_v(v * g)

func set_gravity(g_u: Vector3) -> void:
	var g: Vector3 = to_gd_v(g_u)
	PhysicsServer3D.area_set_param(get_viewport().world_3d.space, PhysicsServer3D.AREA_PARAM_GRAVITY, g.length())
	PhysicsServer3D.area_set_param(get_viewport().world_3d.space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, g.normalized())

func _space() -> PhysicsDirectSpaceState3D:
	var w := get_viewport().world_3d if get_viewport() != null else null
	return w.direct_space_state if w != null else null

## Unity layer mask (bit per layer) → Godot collision mask. -1 = everything.
func _godot_mask(unity_mask: int) -> int:
	if unity_mask == -1 or unity_mask == -5:
		return 0xFFFFFFFF
	return unity_mask & 0xFFFFFFFF

## trigger: QueryTriggerInteraction (0 global, 1 ignore, 2 collide)
func raycast(origin: Vector3, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Dictionary:
	var space := _space()
	if space == null or dir.length_squared() < 1e-12:
		return {}
	var d: float = max_dist if is_finite(max_dist) else 100000.0
	var o: Vector3 = to_gd_v(origin)
	var q := PhysicsRayQueryParameters3D.create(o, o + to_gd_v(dir).normalized() * d, _godot_mask(mask))
	q.collide_with_areas = trigger != 1
	q.collide_with_bodies = true
	var r: Dictionary = space.intersect_ray(q)
	if r.is_empty():
		return {}
	_hit_from_gd(r)
	r["distance"] = origin.distance_to(r["position"])
	r["origin"] = origin
	return r

## Godot hit dictionaries carry Godot-space vectors; scripts read them in script space.
func _hit_from_gd(r: Dictionary) -> Dictionary:
	if coord_mode != CoordMode.UNITY:
		if r.has("position"):
			r["position"] = from_gd_v(r["position"])
		if r.has("normal"):
			r["normal"] = from_gd_v(r["normal"])
	return r

func raycast_all(origin: Vector3, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Array:
	var out: Array = []
	var exclude: Array = []
	var space := _space()
	if space == null:
		return out
	var d: float = max_dist if is_finite(max_dist) else 100000.0
	var o: Vector3 = to_gd_v(origin)
	for _i in range(32):
		var q := PhysicsRayQueryParameters3D.create(o, o + to_gd_v(dir).normalized() * d, _godot_mask(mask))
		q.collide_with_areas = trigger != 1
		q.exclude = exclude
		var r: Dictionary = space.intersect_ray(q)
		if r.is_empty():
			break
		_hit_from_gd(r)
		r["distance"] = origin.distance_to(r["position"])
		out.append(r)
		exclude.append(r["rid"])
	return out

func raycast_non_alloc(origin: Vector3, dir: Vector3, results: Array, max_dist: float, mask: int, trigger: int) -> int:
	var hits: Array = raycast_all(origin, dir, max_dist, mask, trigger)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

## Bounding radius of a shape around its origin (any orientation).
func _shape_radius(shape: Shape3D) -> float:
	if shape is SphereShape3D:
		return shape.radius
	if shape is BoxShape3D:
		return shape.size.length() * 0.5
	if shape is CapsuleShape3D:
		return shape.height * 0.5
	if shape is CylinderShape3D:
		return Vector2(shape.height * 0.5, shape.radius).length()
	var mesh: Mesh = shape.get_debug_mesh()
	return mesh.get_aabb().size.length() * 0.5 if mesh != null else 1.0

## cast_motion bisects to ~1/256 of the motion, so a long sweep is imprecise and can skip thin
## obstacles. A ray along the sweep bounds the length, then the sweep is repeated from the safe
## point over the safe→unsafe gap until the gap is negligible. Returns [distance, unsafe origin]
## in Godot space, or [] when nothing is hit within `max_len`.
func _cast_refined3d(space: PhysicsDirectSpaceState3D, params: PhysicsShapeQueryParameters3D, dir: Vector3, max_len: float) -> Array:
	var basis: Basis = params.transform.basis
	var origin: Vector3 = params.transform.origin
	var remaining: float = max_len
	var reach: float = _shape_radius(params.shape)
	var ray := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_len, params.collision_mask)
	ray.collide_with_areas = params.collide_with_areas
	ray.exclude = params.exclude
	var r: Dictionary = space.intersect_ray(ray)
	if not r.is_empty():
		remaining = minf(remaining, origin.distance_to(r["position"]) + reach * 2.0 + 0.01)
	var total: float = 0.0
	var gap: float = 0.0
	for pass_ in range(5):
		params.transform = Transform3D(basis, origin)
		params.motion = dir * remaining
		var m: PackedFloat32Array = space.cast_motion(params)
		if m.size() < 2 or m[0] >= 1.0:
			if pass_ == 0:
				return []
			break
		total += remaining * m[0]
		origin += dir * remaining * m[0]
		gap = remaining * (m[1] - m[0])
		if gap <= 0.0002:
			break
		remaining = gap * 1.5 + 0.0002
	return [total, origin + dir * gap]

## Sweep a shape (Godot transform) along a Unity direction; a Unity RaycastHit dictionary or {}.
func _shape_cast(shape: Shape3D, xform: Transform3D, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Dictionary:
	var space := _space()
	if space == null:
		return {}
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = xform
	var d: float = max_dist if is_finite(max_dist) else 100000.0
	var dir_gd: Vector3 = to_gd_v(dir).normalized()
	params.collision_mask = _godot_mask(mask)
	params.collide_with_areas = trigger != 1
	var res: Array = _cast_refined3d(space, params, dir_gd, d)
	if res.is_empty():
		return {}
	var distance: float = res[0]
	# rest info at the unsafe position: the safe one leaves a gap and reports nothing
	params.transform = Transform3D(xform.basis, res[1])
	params.motion = Vector3.ZERO
	var rest: Dictionary = space.get_rest_info(params)
	var hit: Dictionary = {"position": from_gd_v(rest.get("point", xform.origin + dir_gd * distance)), "normal": from_gd_v(rest.get("normal", -dir_gd)), "distance": distance, "collider": null}
	if rest.has("collider_id"):
		hit["collider"] = instance_from_id(rest["collider_id"])
	else:
		for r in space.intersect_shape(params, 1):
			hit["collider"] = r.get("collider")
	return hit

func _fill_hits(hits: Array, results: Array) -> int:
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func sphere_cast(origin: Vector3, radius: float, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Dictionary:
	var shape := SphereShape3D.new()
	shape.radius = radius
	return _shape_cast(shape, Transform3D(Basis(), to_gd_v(origin)), dir, max_dist, mask, trigger)

func sphere_cast_all(origin: Vector3, radius: float, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Array:
	var h: Dictionary = sphere_cast(origin, radius, dir, max_dist, mask, trigger)
	return [h] if not h.is_empty() else []

func sphere_cast_non_alloc(origin: Vector3, radius: float, dir: Vector3, results: Array, max_dist: float, mask: int, trigger: int) -> int:
	return _fill_hits(sphere_cast_all(origin, radius, dir, max_dist, mask, trigger), results)

func _capsule(p1: Vector3, p2: Vector3, radius: float) -> Array:
	var s := CapsuleShape3D.new()
	s.radius = radius
	s.height = p1.distance_to(p2) + radius * 2.0
	var b := Basis()
	if p1.distance_squared_to(p2) > 1e-9:
		b = Basis(from_to_rotation(Vector3.UP, to_gd_v(p2 - p1).normalized()))
	return [s, Transform3D(b, to_gd_v((p1 + p2) * 0.5))]

func capsule_cast(p1: Vector3, p2: Vector3, radius: float, dir: Vector3, max_dist: float, mask: int, trigger: int = 0) -> Dictionary:
	var c: Array = _capsule(p1, p2, radius)
	return _shape_cast(c[0], c[1], dir, max_dist, mask, trigger)

func capsule_cast_all(p1: Vector3, p2: Vector3, radius: float, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Array:
	var h: Dictionary = capsule_cast(p1, p2, radius, dir, max_dist, mask, trigger)
	return [h] if not h.is_empty() else []

func capsule_cast_non_alloc(p1: Vector3, p2: Vector3, radius: float, dir: Vector3, results: Array, max_dist: float, mask: int, trigger: int) -> int:
	return _fill_hits(capsule_cast_all(p1, p2, radius, dir, max_dist, mask, trigger), results)

func box_cast(center: Vector3, half: Vector3, dir: Vector3, rot: Quaternion, max_dist: float, mask: int, trigger: int = 0) -> Dictionary:
	var shape := BoxShape3D.new()
	shape.size = half * 2.0
	return _shape_cast(shape, Transform3D(Basis(to_gd_q(rot)), to_gd_v(center)), dir, max_dist, mask, trigger)

func box_cast_all(center: Vector3, half: Vector3, dir: Vector3, rot: Quaternion, max_dist: float, mask: int, trigger: int) -> Array:
	var h: Dictionary = box_cast(center, half, dir, rot, max_dist, mask, trigger)
	return [h] if not h.is_empty() else []

func box_cast_non_alloc(center: Vector3, half: Vector3, dir: Vector3, results: Array, rot: Quaternion, max_dist: float, mask: int, trigger: int) -> int:
	return _fill_hits(box_cast_all(center, half, dir, rot, max_dist, mask, trigger), results)

func _overlap(shape: Shape3D, xform: Transform3D, mask: int, trigger: int) -> Array:
	var space := _space()
	if space == null:
		return []
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = xform
	params.collision_mask = _godot_mask(mask)
	params.collide_with_areas = trigger != 1
	var out: Array = []
	for r in space.intersect_shape(params, 64):
		out.append(r["collider"])
	return out

func overlap_sphere(pos: Vector3, radius: float, mask: int, trigger: int) -> Array:
	var s := SphereShape3D.new()
	s.radius = radius
	return _overlap(s, Transform3D(Basis(), to_gd_v(pos)), mask, trigger)

func overlap_sphere_non_alloc(pos: Vector3, radius: float, results: Array, mask: int, trigger: int) -> int:
	var hits: Array = overlap_sphere(pos, radius, mask, trigger)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func overlap_box(center: Vector3, half: Vector3, rot: Quaternion, mask: int, trigger: int) -> Array:
	var s := BoxShape3D.new()
	s.size = half * 2.0
	return _overlap(s, Transform3D(Basis(to_gd_q(rot)), to_gd_v(center)), mask, trigger)

func overlap_box_non_alloc(center: Vector3, half: Vector3, results: Array, rot: Quaternion, mask: int, trigger: int) -> int:
	var hits: Array = overlap_box(center, half, rot, mask, trigger)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func overlap_capsule(p1: Vector3, p2: Vector3, radius: float, mask: int, trigger: int) -> Array:
	var c: Array = _capsule(p1, p2, radius)
	return _overlap(c[0], c[1], mask, trigger)

func overlap_capsule_non_alloc(p1: Vector3, p2: Vector3, radius: float, results: Array, mask: int, trigger: int) -> int:
	return _fill_hits(overlap_capsule(p1, p2, radius, mask, trigger), results)

func get_ignore_collision(a: Node, b: Node) -> bool:
	var ca := _collision_object(a)
	var cb := _collision_object(b)
	if ca == null or cb == null:
		return false
	return ca.get_collision_exceptions().has(cb)

func ignore_collision(a: Node, b: Node, ignore: bool) -> void:
	var ca := _collision_object(a)
	var cb := _collision_object(b)
	if ca == null or cb == null:
		return
	if ignore:
		ca.add_collision_exception_with(cb)
	else:
		ca.remove_collision_exception_with(cb)

func joint_get_connected_body(j: Joint3D) -> Node:
	return j.get_node_or_null(j.node_b)

func joint_set_connected_body(j: Joint3D, body: Node) -> void:
	j.node_b = j.get_path_to(body) if body != null else NodePath()

func hinge_motor(j: HingeJoint3D) -> Dictionary:
	return {"targetVelocity": rad_to_deg(j.get_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY)), "force": j.get_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE)}

func hinge_set_motor(j: HingeJoint3D, m: Dictionary) -> void:
	j.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, deg_to_rad(float(m.get("targetVelocity", 0.0))))
	j.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, float(m.get("force", 0.0)))

func wheel_ground_hit(w: VehicleWheel3D) -> Dictionary:
	var b: Basis = w.global_transform.basis
	return {"point": from_gd_v(w.get_contact_point()), "normal": from_gd_v(w.get_contact_normal()), "collider": w.get_contact_body(), "force": 0.0, "forwardSlip": 0.0, "sidewaysSlip": w.get_skidinfo(), "forwardDir": from_gd_v(-b.z), "sidewaysDir": from_gd_v(b.x)}

# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------

func _vol_prop(a: Node) -> String:
	return "volume_db" if (a is AudioStreamPlayer3D or a is AudioStreamPlayer or a is AudioStreamPlayer2D) else ""

func audio_get_volume(a: Node) -> float:
	var p := _vol_prop(a)
	return db_to_linear(a.get(p)) if p != "" else 1.0

func audio_set_volume(a: Node, v: float) -> void:
	var p := _vol_prop(a)
	if p != "":
		a.set(p, linear_to_db(maxf(v, 0.0001)))

func audio_get_loop(a: Node) -> bool:
	var s = a.get("stream")
	if s is AudioStreamWAV:
		return s.loop_mode != AudioStreamWAV.LOOP_DISABLED
	if s != null and s.get("loop") != null:
		return s.loop
	return false

func audio_set_loop(a: Node, v: bool) -> void:
	var s = a.get("stream")
	if s == null:
		return
	if s is AudioStreamWAV:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD if v else AudioStreamWAV.LOOP_DISABLED
	elif s.get("loop") != null:
		s.loop = v

func audio_get_mute(a: Node) -> bool:
	return a.get_meta("udon_muted", false)

func audio_set_mute(a: Node, v: bool) -> void:
	if v and not audio_get_mute(a):
		a.set_meta("udon_prev_volume", a.get(_vol_prop(a)))
		a.set(_vol_prop(a), -80.0)
	elif not v and audio_get_mute(a):
		a.set(_vol_prop(a), a.get_meta("udon_prev_volume", 0.0))
	a.set_meta("udon_muted", v)

func audio_get_enabled(a: Node) -> bool:
	return a.process_mode != Node.PROCESS_MODE_DISABLED

func audio_set_enabled(a: Node, v: bool) -> void:
	a.process_mode = Node.PROCESS_MODE_INHERIT if v else Node.PROCESS_MODE_DISABLED
	if not v and a.has_method("stop"):
		a.stop()

func audio_set_bus(a: Node, bus) -> void:
	if bus != null:
		a.set("bus", str(bus))

func audio_play_delayed(a: Node, delay: float) -> void:
	if delay <= 0.0:
		a.play()
		return
	var t := get_tree().create_timer(delay)
	var w: WeakRef = weakref(a)
	t.timeout.connect(func():
		var o = w.get_ref()
		if o != null:
			o.play())

func audio_play_one_shot(a: Node, clip: AudioStream, volume: float) -> void:
	if clip == null:
		return
	var p: Node
	if a is AudioStreamPlayer3D:
		p = AudioStreamPlayer3D.new()
		p.max_distance = a.max_distance
		p.unit_size = a.unit_size
		p.attenuation_model = a.attenuation_model
	elif a is AudioStreamPlayer2D:
		p = AudioStreamPlayer2D.new()
	else:
		p = AudioStreamPlayer.new()
	p.stream = clip
	p.set("bus", a.get("bus"))
	p.set("pitch_scale", a.get("pitch_scale"))
	p.set("volume_db", a.get(_vol_prop(a)) + linear_to_db(maxf(volume, 0.0001)))
	a.add_child(p)
	p.finished.connect(p.queue_free)
	p.play()

func audio_play_at_point(clip: AudioStream, pos: Vector3, volume: float) -> void:
	var p := AudioStreamPlayer3D.new()
	p.stream = clip
	p.volume_db = linear_to_db(maxf(volume, 0.0001))
	get_tree().current_scene.add_child(p)
	p.global_position = to_gd_v(pos)
	p.finished.connect(p.queue_free)
	p.play()

# ---------------------------------------------------------------------------
# Animator (parameters stored per node; forwarded to an AnimationTree if present)
# ---------------------------------------------------------------------------

func _anim_tree(n: Node) -> AnimationTree:
	if n is AnimationTree:
		return n
	if n != null:
		for c in n.get_children():
			if c is AnimationTree:
				return c
	return null

func _anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	if n != null:
		for c in n.get_children():
			if c is AnimationPlayer:
				return c
	return null

func _params(n: Node) -> Dictionary:
	var id: int = n.get_instance_id()
	if not _anim_params.has(id):
		_anim_params[id] = {}
	return _anim_params[id]

func anim_set(n: Node, key, value) -> void:
	if n == null:
		return
	var k: String = str(key)
	_params(n)[k] = value
	var t := _anim_tree(n)
	if t != null:
		if t.has_method("_setup_blend_to_meta"):
			# unidot_importer's runtime/anim_tree.gd keeps Unity animator parameters as metadata
			# and fans them out to the blend/condition parameters of the converted controller.
			t.set(StringName("metadata/" + k), value)
		var path: String = "parameters/" + k
		if t.get(path) != null:
			t.set(path, value)
		elif t.get(path + "/blend_amount") != null:
			t.set(path + "/blend_amount", value)
		elif t.get(path + "/blend_position") != null:
			t.set(path + "/blend_position", value)
		elif t.get(path + "/condition") != null:
			t.set(path + "/condition", bool(value))
	if n.has_method("udon_anim_set"):
		n.udon_anim_set(k, value)

func anim_set_damped(n: Node, key, value: float, damp_time: float, dt: float) -> void:
	var cur: float = float(anim_get(n, key, 0.0))
	var r: Array = smooth_damp(cur, value, 0.0, damp_time, INF, dt) if damp_time > 0.0 else [value, 0.0]
	anim_set(n, key, r[0])

func anim_get(n: Node, key, default):
	if n == null:
		return default
	var t := _anim_tree(n)
	if t != null and t.has_meta(str(key)):
		return t.get_meta(str(key))
	return _params(n).get(str(key), default)

func anim_trigger(n: Node, key) -> void:
	var k: String = str(key)
	var t := _anim_tree(n)
	if t != null:
		var path: String = "parameters/" + k + "/request"
		if t.get(path) != null:
			t.set(path, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			return
	anim_set(n, k, true)
	var p := _anim_player(n)
	if p != null and p.has_animation(k):
		p.play(k)

func anim_reset_trigger(n: Node, key) -> void:
	anim_set(n, str(key), false)

func anim_play(n: Node, state, _layer: int, normalized_time: float) -> void:
	var p := _anim_player(n)
	var s: String = str(state)
	if p != null and p.has_animation(s):
		p.play(s)
		if normalized_time > -INF:
			p.seek(normalized_time * p.get_animation(s).length, true)
		return
	var t := _anim_tree(n)
	if t != null:
		var sm = t.get("parameters/playback")
		if sm is AnimationNodeStateMachinePlayback:
			sm.travel(s)

func anim_cross_fade(n: Node, state, duration: float, _layer: int) -> void:
	var p := _anim_player(n)
	var s: String = str(state)
	if p != null and p.has_animation(s):
		p.play(s, duration)
		return
	anim_play(n, s, _layer, -INF)

func anim_get_speed(n: Node) -> float:
	var p := _anim_player(n)
	return p.speed_scale if p != null else 1.0

func anim_set_speed(n: Node, v: float) -> void:
	var p := _anim_player(n)
	if p != null:
		p.speed_scale = v

func anim_get_enabled(n: Node) -> bool:
	var t := _anim_tree(n)
	if t != null:
		return t.active
	return n.process_mode != Node.PROCESS_MODE_DISABLED

func anim_set_enabled(n: Node, v: bool) -> void:
	var t := _anim_tree(n)
	if t != null:
		t.active = v
	else:
		n.process_mode = Node.PROCESS_MODE_INHERIT if v else Node.PROCESS_MODE_DISABLED

func anim_controller(n: Node):
	var t := _anim_tree(n)
	return t.tree_root if t != null else null

func anim_set_controller(n: Node, c) -> void:
	var t := _anim_tree(n)
	if t != null and c is AnimationRootNode:
		t.tree_root = c

func anim_layer_count(_n: Node) -> int:
	return 1

func anim_parameter_count(n: Node) -> int:
	return _params(n).size()

func anim_layer_name(_n: Node, _i: int) -> String:
	return "Base Layer"

func anim_layer_index(_n: Node, name_: String) -> int:
	return 0 if name_ == "Base Layer" else -1

func anim_set_layer_weight(n: Node, _i: int, w: float) -> void:
	anim_set(n, "__layer_weight", w)

func anim_get_layer_weight(n: Node, _i: int) -> float:
	return float(anim_get(n, "__layer_weight", 1.0))

func anim_state_info(n: Node, _layer: int, next: bool) -> Dictionary:
	var p := _anim_player(n)
	if p != null and p.current_animation != "":
		var a := p.get_animation(p.current_animation)
		var len_: float = a.length if a != null else 0.0
		var t: float = p.current_animation_position
		return {"name": p.current_animation if not next else "", "normalizedTime": (t / len_) if len_ > 0.0 else 0.0, "length": len_, "speed": p.speed_scale, "loop": a != null and a.loop_mode != Animation.LOOP_NONE}
	var tree := _anim_tree(n)
	if tree != null:
		var sm = tree.get("parameters/playback")
		if sm is AnimationNodeStateMachinePlayback:
			return {"name": String(sm.get_current_node()), "normalizedTime": (sm.get_current_play_position() / sm.get_current_length()) if sm.get_current_length() > 0.0 else 0.0, "length": sm.get_current_length(), "speed": 1.0, "loop": false}
	return {"name": "", "normalizedTime": 0.0, "length": 0.0, "speed": 1.0, "loop": false}

func anim_in_transition(n: Node, _layer: int) -> bool:
	var tree := _anim_tree(n)
	if tree != null:
		var sm = tree.get("parameters/playback")
		if sm is AnimationNodeStateMachinePlayback:
			return sm.get_fading_from_node() != &""
	return false

func anim_bone_transform(n: Node, _bone: int) -> Node3D:
	return n if n is Node3D else null

func animation_current_clip(p: AnimationPlayer) -> Animation:
	return p.get_animation(p.current_animation) if p.current_animation != "" else null

func animation_play(p: AnimationPlayer, name_: String) -> bool:
	if name_ == "":
		if p.current_animation == "" and p.get_animation_list().size() > 0:
			p.play(p.get_animation_list()[0])
		else:
			p.play()
		return true
	if p.has_animation(name_):
		p.play(name_)
		return true
	return false

func blend_shape_get(m: MeshInstance3D, i: int) -> float:
	return m.get_blend_shape_value(i) * 100.0

func blend_shape_set(m: MeshInstance3D, i: int, v: float) -> void:
	m.set_blend_shape_value(i, v / 100.0)

# ---------------------------------------------------------------------------
# Particles
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ParticleSystem → GPUParticles3D (+ ParticleProcessMaterial)
#
# Unity module structs (`ps.main`, `ps.shape`, ...) are PsModule objects. Values set by scripts live
# in `data`; `_ps_apply` pushes the ones Godot can express onto the GPUParticles3D / process
# material, `_ps_read` reads those back so scripts see the imported state; everything else only
# round-trips (`!stored` in the catalog). The importer seeds `data` through the `udon_particles`
# metadata ({module: {prop: value}}).
#
# MinMaxCurve is a float (constant) or {mode, constant, constantMin, constantMax, curve, curveMin,
# curveMax, multiplier}; MinMaxGradient a Color or {mode, color, colorMin, colorMax, gradient,
# gradientMin, gradientMax}. Modes follow ParticleSystemCurveMode / ParticleSystemGradientMode.
# ---------------------------------------------------------------------------

class PsModule:
	var node: Node
	var kind: String
	var data: Dictionary = {}
	func _init(n: Node, k: String) -> void:
		node = n
		kind = k

func _gpu(n: Node) -> GPUParticles3D:
	if n is GPUParticles3D:
		return n
	if n != null:
		for c in n.get_children():
			if c is GPUParticles3D:
				return c
	return null

func _ps_pm(p: GPUParticles3D) -> ParticleProcessMaterial:
	if p == null:
		return null
	if p.process_material is ParticleProcessMaterial:
		return p.process_material
	if p.process_material == null:
		var pm := ParticleProcessMaterial.new()
		p.process_material = pm
		return pm
	return null

func _ps_draw_material(p: GPUParticles3D) -> Material:
	if p == null:
		return null
	if p.material_override != null:
		return p.material_override
	if p.draw_pass_1 != null and p.draw_pass_1.get_surface_count() > 0:
		return p.draw_pass_1.surface_get_material(0)
	return null

func _ps_state(p: GPUParticles3D) -> Dictionary:
	var id: int = p.get_instance_id()
	if not _ps_states.has(id):
		_ps_states[id] = {"start": Time.get_ticks_msec(), "playing": p.emitting, "paused": false, "offset": 0.0}
	return _ps_states[id]

func ps_module(n: Node, kind: String) -> PsModule:
	var p := _gpu(n)
	var target: Node = p if p != null else n
	if target == null:
		return null
	var id: int = target.get_instance_id()
	if not _ps_modules.has(id):
		_ps_modules[id] = {}
	var mods: Dictionary = _ps_modules[id]
	if not mods.has(kind):
		var m := PsModule.new(target, kind)
		if target.has_meta("udon_particles"):
			var all: Dictionary = target.get_meta("udon_particles")
			if all.has(kind) and all[kind] is Dictionary:
				m.data = (all[kind] as Dictionary).duplicate()
		mods[kind] = m
	return mods[kind]

func ps_main(n: Node) -> PsModule:
	return ps_module(n, "main")

func ps_emission(n: Node) -> PsModule:
	return ps_module(n, "emission")

## Module property: script-set values first, then the live engine value, then the default.
func ps_get(m, prop: String, default = null):
	if m == null:
		return default
	if m.data.has(prop):
		return m.data[prop]
	var v = _ps_read(m, prop)
	if v != null:
		return v
	return default

func ps_set(m, prop: String, value) -> void:
	if m == null:
		return
	m.data[prop] = value
	_ps_apply(m, prop, value)

func _ps_read(m: PsModule, prop: String):
	var p := _gpu(m.node)
	if p == null:
		return null
	var pm: ParticleProcessMaterial = p.process_material as ParticleProcessMaterial
	match m.kind:
		"main":
			match prop:
				"loop":
					return not p.one_shot
				"startLifetime", "startLifetimeMultiplier":
					return p.lifetime
				"startSpeed", "startSpeedMultiplier":
					return pm.initial_velocity_max if pm != null else 0.0
				"startSize", "startSizeMultiplier", "startSizeX":
					return pm.scale_max if pm != null else 1.0
				"startColor":
					return pm.color if pm != null else Color.WHITE
				"startRotation", "startRotationMultiplier":
					return deg_to_rad(pm.angle_max) if pm != null else 0.0
				"gravityModifier", "gravityModifierMultiplier":
					return (-pm.gravity.y / 9.81) if pm != null else 0.0
				"simulationSpace":
					return 0 if p.local_coords else 1
				"simulationSpeed":
					return p.speed_scale
				"maxParticles":
					return p.amount
				"playOnAwake":
					return p.get_meta("udon_play_on_awake") if p.has_meta("udon_play_on_awake") else p.emitting
				"prewarm":
					return p.preprocess > 0.0
		"emission":
			match prop:
				"enabled":
					return p.emitting
				"rateOverTime", "rateOverTimeMultiplier":
					return float(p.amount) / maxf(p.lifetime, 0.001)
				"burstCount":
					return (m.data.get("bursts", []) as Array).size()
		"shape":
			if pm == null:
				return null
			match prop:
				"enabled":
					return pm.emission_shape != ParticleProcessMaterial.EMISSION_SHAPE_POINT
				"shapeType":
					match pm.emission_shape:
						ParticleProcessMaterial.EMISSION_SHAPE_SPHERE:
							return 0
						ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE:
							return 1
						ParticleProcessMaterial.EMISSION_SHAPE_BOX:
							return 5
						ParticleProcessMaterial.EMISSION_SHAPE_RING:
							return 4
					return 0
				"radius":
					return pm.emission_ring_radius if pm.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_RING else pm.emission_sphere_radius
				"angle":
					return pm.spread
				"scale":
					return pm.emission_box_extents * 2.0
				"position":
					return from_gd_v(pm.emission_shape_offset)
		"trails":
			match prop:
				"enabled":
					return p.trail_enabled
				"lifetime", "lifetimeMultiplier":
					return p.trail_lifetime
		"noise":
			if pm == null:
				return null
			match prop:
				"enabled":
					return pm.turbulence_enabled
				"strength", "strengthMultiplier":
					return pm.turbulence_noise_strength
				"frequency":
					return pm.turbulence_noise_scale
				"scrollSpeed", "scrollSpeedMultiplier":
					return pm.turbulence_noise_speed
		"collision":
			if pm == null:
				return null
			match prop:
				"enabled":
					return pm.collision_mode != ParticleProcessMaterial.COLLISION_DISABLED
				"bounce", "bounceMultiplier":
					return pm.collision_bounce
				"dampen", "dampenMultiplier":
					return pm.collision_friction
		"rotationOverLifetime":
			if pm == null:
				return null
			match prop:
				"z", "zMultiplier":
					return deg_to_rad(pm.angular_velocity_max)
				"enabled":
					return pm.angular_velocity_max != 0.0
		"limitVelocityOverLifetime":
			if pm == null:
				return null
			match prop:
				"dampen":
					return pm.damping_max / 10.0
				"drag", "dragMultiplier":
					return pm.damping_max
		"colorOverLifetime":
			if pm != null and prop == "color" and pm.color_ramp is GradientTexture1D and pm.color_ramp.gradient != null:
				return {"mode": 1, "gradient": pm.color_ramp.gradient}
			if pm != null and prop == "enabled":
				return pm.color_ramp != null
		"sizeOverLifetime":
			if pm != null and prop == "size" and pm.scale_curve is CurveTexture and pm.scale_curve.curve != null:
				return {"mode": 1, "curve": pm.scale_curve.curve, "multiplier": 1.0}
			if pm != null and prop == "enabled":
				return pm.scale_curve != null
		"textureSheetAnimation":
			var dm := _ps_draw_material(p)
			if dm is BaseMaterial3D:
				match prop:
					"enabled":
						return dm.particles_anim_h_frames * dm.particles_anim_v_frames > 1
					"numTilesX":
						return dm.particles_anim_h_frames
					"numTilesY":
						return dm.particles_anim_v_frames
		"renderer":
			match prop:
				"material", "sharedMaterial":
					return _ps_draw_material(p)
				"mesh":
					return p.draw_pass_1
				"enabled":
					return p.visible
	return null

## Push a module property onto the node (the properties Godot can express).
func _ps_apply(m: PsModule, prop: String, value) -> void:
	var p := _gpu(m.node)
	if p == null:
		return
	var pm := _ps_pm(p)
	match m.kind:
		"main":
			match prop:
				"loop":
					p.one_shot = not bool(value)
				"startLifetime", "startLifetimeMultiplier":
					var mx: float = mmc_max(value)
					p.lifetime = maxf(mx, 0.01)
					if pm != null:
						pm.lifetime_randomness = clampf(1.0 - mmc_min(value) / maxf(mx, 0.0001), 0.0, 1.0)
				"startSpeed", "startSpeedMultiplier":
					if pm != null:
						pm.initial_velocity_min = mmc_min(value)
						pm.initial_velocity_max = mmc_max(value)
				"startSize", "startSizeMultiplier", "startSizeX":
					if pm != null:
						pm.scale_min = maxf(mmc_min(value), 0.0)
						pm.scale_max = maxf(mmc_max(value), 0.0)
				"startRotation", "startRotationMultiplier":
					if pm != null:
						pm.angle_min = rad_to_deg(mmc_min(value))
						pm.angle_max = rad_to_deg(mmc_max(value))
				"startColor":
					if pm != null:
						if mmg_mode(value) == 0:
							pm.color = mmg_color(value)
							pm.color_initial_ramp = null
						else:
							pm.color = Color.WHITE
							var gt := GradientTexture1D.new()
							gt.gradient = mmg_gradient(value)
							pm.color_initial_ramp = gt
				"gravityModifier", "gravityModifierMultiplier":
					if pm != null:
						_ps_update_gravity(m.node, pm)
				"simulationSpace":
					p.local_coords = int(value) == 0
				"simulationSpeed":
					p.speed_scale = float(value)
				"maxParticles":
					p.amount = maxi(int(value), 1)
				"playOnAwake":
					p.set_meta("udon_play_on_awake", bool(value))
				"prewarm":
					p.preprocess = p.lifetime if bool(value) else 0.0
		"emission":
			match prop:
				"enabled":
					if _ps_state(p)["playing"]:
						p.emitting = bool(value)
				"rateOverTime", "rateOverTimeMultiplier":
					var rate: float = mmc_max(value)
					if rate > 0.0:
						p.amount = maxi(int(ceil(rate * p.lifetime)), 1)
						p.explosiveness = 0.0
				"bursts":
					var total: int = 0
					for b in value:
						if b is Dictionary:
							total += int(mmc_max(b.get("count", 0)))
					if total > 0 and mmc_max(m.data.get("rateOverTime", 0.0)) <= 0.0:
						p.amount = total
						p.explosiveness = 1.0
		"shape":
			if pm == null:
				return
			match prop:
				"enabled":
					if not bool(value):
						pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
				"shapeType":
					_ps_apply_shape(m, pm)
				"radius", "radiusThickness":
					_ps_apply_shape(m, pm)
				"angle":
					pm.spread = clampf(float(value), 0.0, 180.0)
				"scale":
					pm.emission_box_extents = (value as Vector3).abs() * 0.5
				"position":
					pm.emission_shape_offset = to_gd_v(value)
				"randomDirectionAmount":
					pm.spread = lerpf(pm.spread, 180.0, clampf(float(value), 0.0, 1.0))
		"velocityOverLifetime":
			if pm == null:
				return
			match prop:
				"speedModifier", "speedModifierMultiplier":
					var k: float = mmc_max(value)
					var base: float = float(m.data.get("_base_speed", pm.initial_velocity_max))
					m.data["_base_speed"] = base
					pm.initial_velocity_min = mmc_min(value) * base
					pm.initial_velocity_max = k * base
				"radial", "radialMultiplier":
					pm.radial_velocity_min = mmc_min(value)
					pm.radial_velocity_max = mmc_max(value)
		"limitVelocityOverLifetime":
			if pm == null:
				return
			match prop:
				"dampen":
					pm.damping_min = float(value) * 10.0
					pm.damping_max = float(value) * 10.0
				"drag", "dragMultiplier":
					pm.damping_min = mmc_min(value)
					pm.damping_max = mmc_max(value)
		"forceOverLifetime":
			if pm != null and prop in ["x", "y", "z", "xMultiplier", "yMultiplier", "zMultiplier", "enabled"]:
				_ps_update_gravity(m.node, pm)
		"colorOverLifetime":
			if pm == null:
				return
			match prop:
				"color":
					var gt := GradientTexture1D.new()
					gt.gradient = mmg_gradient(value)
					pm.color_ramp = gt
				"enabled":
					if not bool(value):
						pm.color_ramp = null
		"sizeOverLifetime":
			if pm == null:
				return
			match prop:
				"size", "sizeMultiplier":
					var c: Curve = mmc_curve_of(value)
					if c != null:
						var ct := CurveTexture.new()
						ct.curve = c
						pm.scale_curve = ct
					else:
						pm.scale_curve = null
				"enabled":
					if not bool(value):
						pm.scale_curve = null
		"rotationOverLifetime":
			if pm == null:
				return
			match prop:
				"z", "zMultiplier":
					pm.angular_velocity_min = rad_to_deg(mmc_min(value))
					pm.angular_velocity_max = rad_to_deg(mmc_max(value))
				"enabled":
					if not bool(value):
						pm.angular_velocity_min = 0.0
						pm.angular_velocity_max = 0.0
		"noise":
			if pm == null:
				return
			match prop:
				"enabled":
					pm.turbulence_enabled = bool(value)
				"strength", "strengthMultiplier":
					pm.turbulence_noise_strength = mmc_max(value)
				"frequency":
					pm.turbulence_noise_scale = float(value)
				"scrollSpeed", "scrollSpeedMultiplier":
					pm.turbulence_noise_speed = Vector3.ONE * mmc_max(value)
		"collision":
			if pm == null:
				return
			match prop:
				"enabled":
					pm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID if bool(value) else ParticleProcessMaterial.COLLISION_DISABLED
				"bounce", "bounceMultiplier":
					pm.collision_bounce = mmc_max(value)
				"dampen", "dampenMultiplier":
					pm.collision_friction = mmc_max(value)
				"radiusScale":
					pm.collision_use_scale = true
		"textureSheetAnimation":
			var dm := _ps_draw_material(p)
			if dm is BaseMaterial3D:
				match prop:
					"numTilesX":
						dm.particles_anim_h_frames = maxi(int(value), 1)
						dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
					"numTilesY":
						dm.particles_anim_v_frames = maxi(int(value), 1)
						dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
					"enabled":
						if not bool(value):
							dm.particles_anim_h_frames = 1
							dm.particles_anim_v_frames = 1
		"trails":
			match prop:
				"enabled":
					p.trail_enabled = bool(value)
				"lifetime", "lifetimeMultiplier":
					p.trail_lifetime = maxf(mmc_max(value), 0.01)
		"renderer":
			match prop:
				"material", "sharedMaterial":
					p.material_override = value
				"mesh":
					if value is Mesh:
						p.draw_pass_1 = value
				"renderMode":
					var dm := _ps_draw_material(p)
					if dm is BaseMaterial3D:
						match int(value):
							0, 1, 2:
								dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
							3:
								dm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
							_:
								dm.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
				"enabled":
					p.visible = bool(value)

func _ps_apply_shape(m: PsModule, pm: ParticleProcessMaterial) -> void:
	var shape: int = int(m.data.get("shapeType", 0))
	var radius: float = float(m.data.get("radius", pm.emission_sphere_radius))
	var thickness: float = float(m.data.get("radiusThickness", 1.0))
	match shape:
		0, 2:  # Sphere, Hemisphere
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE if thickness > 0.0 else ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
			pm.emission_sphere_radius = maxf(radius, 0.001)
		1, 3:  # SphereShell, HemisphereShell
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
			pm.emission_sphere_radius = maxf(radius, 0.001)
		4, 7, 8, 9, 10, 11, 17:  # Cone family, Circle, Donut: a ring around the local +Z axis
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
			pm.emission_ring_axis = Vector3(0, 0, 1)
			pm.emission_ring_radius = maxf(radius, 0.001)
			pm.emission_ring_inner_radius = maxf(radius, 0.001) * (1.0 - clampf(thickness, 0.0, 1.0))
			pm.emission_ring_height = 0.0
			pm.direction = Vector3(0, 0, 1)
		5, 15, 16, 18:  # Box family, Rectangle
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			var sc: Vector3 = m.data.get("scale", pm.emission_box_extents * 2.0)
			pm.emission_box_extents = sc.abs() * 0.5
		_:
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
			pm.emission_sphere_radius = maxf(radius, 0.001)

func _ps_update_gravity(n: Node, pm: ParticleProcessMaterial) -> void:
	var main := ps_module(n, "main")
	var force := ps_module(n, "forceOverLifetime")
	var g: float = mmc_max(main.data.get("gravityModifier", 0.0)) * mmc_max(main.data.get("gravityModifierMultiplier", 1.0)) if main.data.has("gravityModifier") else -pm.gravity.y / 9.81
	var v := Vector3(0.0, -9.81 * g, 0.0)
	if force.data.get("enabled", not force.data.is_empty()):
		v += to_gd_v(Vector3(mmc_max(force.data.get("x", 0.0)), mmc_max(force.data.get("y", 0.0)), mmc_max(force.data.get("z", 0.0))))
	pm.gravity = v

# --- playback ---------------------------------------------------------------------------------

func ps_play(n: Node, with_children: bool) -> void:
	var p := _gpu(n)
	if p != null:
		var st := _ps_state(p)
		if not st["playing"] or st["paused"]:
			st["start"] = Time.get_ticks_msec()
		st["playing"] = true
		st["paused"] = false
		p.speed_scale = float(ps_get(ps_module(p, "main"), "simulationSpeed", 1.0))
		var em = ps_module(p, "emission").data.get("enabled", true)
		p.emitting = bool(em)
	if with_children:
		for c in n.get_children():
			if c is GPUParticles3D and c != p:
				ps_play(c, true)

func ps_stop(n: Node, with_children: bool, behavior: int) -> void:
	var p := _gpu(n)
	if p != null:
		var st := _ps_state(p)
		st["playing"] = false
		p.emitting = false
		if behavior == 0:
			p.restart()
			p.emitting = false
	if with_children:
		for c in n.get_children():
			if c is GPUParticles3D and c != p:
				ps_stop(c, true, behavior)

func ps_pause(n: Node, with_children: bool) -> void:
	var p := _gpu(n)
	if p != null:
		var st := _ps_state(p)
		st["offset"] = ps_time(p)
		st["paused"] = true
		p.speed_scale = 0.0
	if with_children:
		for c in n.get_children():
			if c is GPUParticles3D and c != p:
				ps_pause(c, true)

func ps_clear(n: Node, with_children: bool) -> void:
	var p := _gpu(n)
	if p != null:
		var was: bool = p.emitting
		p.restart()
		p.emitting = was
	if with_children:
		for c in n.get_children():
			if c is GPUParticles3D and c != p:
				ps_clear(c, true)

func ps_is_playing(n: Node) -> bool:
	var p := _gpu(n)
	if p == null:
		return false
	var st := _ps_state(p)
	if p.emitting:
		return true
	return st["playing"] and p.one_shot and ps_time(p) < p.lifetime

func ps_is_emitting(n: Node) -> bool:
	var p := _gpu(n)
	return p != null and p.emitting

func ps_is_paused(n: Node) -> bool:
	var p := _gpu(n)
	return p != null and _ps_state(p)["paused"]

func ps_is_stopped(n: Node) -> bool:
	return not ps_is_playing(n)

## Seconds since Play (Unity `time`; wraps for looping systems).
func ps_time(n: Node) -> float:
	var p := _gpu(n)
	if p == null:
		return 0.0
	var st := _ps_state(p)
	if st["paused"]:
		return float(st["offset"])
	if not st["playing"]:
		return 0.0
	var t: float = float(Time.get_ticks_msec() - int(st["start"])) / 1000.0 * maxf(p.speed_scale, 0.0)
	var dur: float = float(ps_get(ps_module(p, "main"), "duration", p.lifetime))
	if not p.one_shot and dur > 0.0:
		t = fmod(t, dur)
	return t

func ps_set_time(n: Node, t: float) -> void:
	var p := _gpu(n)
	if p != null:
		var st := _ps_state(p)
		st["start"] = Time.get_ticks_msec() - int(t * 1000.0)

func ps_particle_count(n: Node) -> int:
	var p := _gpu(n)
	if p == null or not ps_is_playing(p):
		return 0
	return p.amount

func ps_simulate(n: Node, t: float, restart: bool) -> void:
	var p := _gpu(n)
	if p == null:
		return
	if restart:
		p.restart()
	p.preprocess = maxf(t, 0.0)
	ps_set_time(p, t)

func ps_emit(n: Node, count: int) -> void:
	var p := _gpu(n)
	if p == null:
		return
	for _i in range(count):
		p.emit_particle(p.global_transform, Vector3.ZERO, Color.WHITE, Color.WHITE, GPUParticles3D.EMIT_FLAG_POSITION)

func ps_emit_params(n: Node, params: Dictionary, count: int) -> void:
	var p := _gpu(n)
	if p == null:
		return
	var xf := Transform3D(Basis(), to_gd_v(params["position"]) if params.has("position") else p.global_position)
	var flags: int = GPUParticles3D.EMIT_FLAG_POSITION
	var vel := Vector3.ZERO
	if params.has("velocity"):
		flags |= GPUParticles3D.EMIT_FLAG_VELOCITY
		vel = to_gd_v(params["velocity"])
	var col: Color = Color.WHITE
	if params.has("startColor"):
		flags |= GPUParticles3D.EMIT_FLAG_COLOR
		col = params["startColor"]
	for _i in range(count):
		p.emit_particle(xf, vel, col, Color.WHITE, flags)

func ps_trigger_sub_emitter(n: Node, index: int) -> void:
	var subs: Array = ps_module(n, "subEmitters").data.get("systems", [])
	if index >= 0 and index < subs.size() and subs[index] is Node:
		ps_play(subs[index], true)

func ps_sub_emitter_count(n: Node) -> int:
	var subs: Array = ps_module(n, "subEmitters").data.get("systems", [])
	return subs.size()

func ps_sub_emitter(n: Node, index: int) -> Node:
	var subs: Array = ps_module(n, "subEmitters").data.get("systems", [])
	return subs[index] if index >= 0 and index < subs.size() else null

func ps_material(n: Node) -> Material:
	return _ps_draw_material(_gpu(n))

func ps_set_material(n: Node, m: Material) -> void:
	var p := _gpu(n)
	if p != null:
		p.material_override = m

# --- bursts -----------------------------------------------------------------------------------

func ps_bursts(m) -> Array:
	if m == null:
		return []
	if not m.data.has("bursts"):
		m.data["bursts"] = []
	return m.data["bursts"]

func ps_set_bursts(m, bursts: Array, count: int = -1) -> void:
	if m == null:
		return
	var arr: Array = []
	var n: int = bursts.size() if count < 0 else mini(count, bursts.size())
	for i in range(n):
		arr.append(bursts[i])
	ps_set(m, "bursts", arr)

func ps_get_bursts(m, out: Array) -> int:
	var b: Array = ps_bursts(m)
	var n: int = mini(b.size(), out.size())
	for i in range(n):
		out[i] = b[i]
	return b.size()

func ps_burst(m, index: int) -> Dictionary:
	var b: Array = ps_bursts(m)
	return b[index] if index >= 0 and index < b.size() else {}

func ps_set_burst(m, index: int, burst: Dictionary) -> void:
	var b: Array = ps_bursts(m)
	if index >= 0 and index < b.size():
		b[index] = burst
		ps_set(m, "bursts", b)

# --- MinMaxCurve ------------------------------------------------------------------------------

func mmc_two_constants(a: float, b: float) -> Dictionary:
	return {"mode": 3, "constantMin": a, "constantMax": b, "multiplier": 1.0}

func mmc_curve(mult: float, c: Curve) -> Dictionary:
	return {"mode": 1, "multiplier": mult, "curve": c}

func mmc_two_curves(mult: float, cmin: Curve, cmax: Curve) -> Dictionary:
	return {"mode": 2, "multiplier": mult, "curveMin": cmin, "curveMax": cmax}

func mmc_mode(v) -> int:
	if v is Dictionary:
		return int(v.get("mode", 0))
	return 0

func mmc_multiplier(v) -> float:
	if v is Dictionary:
		return float(v.get("multiplier", v.get("constant", v.get("constantMax", 1.0))))
	return float(v) if v != null else 0.0

func _curve_range(c: Curve) -> Vector2:
	if c == null:
		return Vector2.ZERO
	var lo: float = INF
	var hi: float = -INF
	for i in range(9):
		var y: float = c.sample(float(i) / 8.0)
		lo = minf(lo, y)
		hi = maxf(hi, y)
	return Vector2(lo, hi)

func mmc_constant(v) -> float:
	if v is Dictionary:
		match int(v.get("mode", 0)):
			3:
				return float(v.get("constantMax", v.get("constant", 0.0)))
			1, 2:
				return float(v.get("multiplier", 1.0))
		return float(v.get("constant", v.get("constantMax", 0.0)))
	return float(v) if v != null else 0.0

func mmc_min(v) -> float:
	if v is Dictionary:
		match int(v.get("mode", 0)):
			3:
				return float(v.get("constantMin", 0.0))
			1:
				return _curve_range(v.get("curve")).x * float(v.get("multiplier", 1.0))
			2:
				return _curve_range(v.get("curveMin")).x * float(v.get("multiplier", 1.0))
		return float(v.get("constant", v.get("constantMin", 0.0)))
	return float(v) if v != null else 0.0

func mmc_max(v) -> float:
	if v is Dictionary:
		match int(v.get("mode", 0)):
			3:
				return float(v.get("constantMax", 0.0))
			1:
				return _curve_range(v.get("curve")).y * float(v.get("multiplier", 1.0))
			2:
				return _curve_range(v.get("curveMax")).y * float(v.get("multiplier", 1.0))
		return float(v.get("constant", v.get("constantMax", 0.0)))
	return float(v) if v != null else 0.0

func mmc_eval(v, t: float, lerp_factor: float) -> float:
	if v is Dictionary:
		var mult: float = float(v.get("multiplier", 1.0))
		match int(v.get("mode", 0)):
			1:
				var c: Curve = v.get("curve")
				return (c.sample(t) if c != null else 1.0) * mult
			2:
				var a: Curve = v.get("curveMin")
				var b: Curve = v.get("curveMax")
				return lerpf(a.sample(t) if a != null else 1.0, b.sample(t) if b != null else 1.0, lerp_factor) * mult
			3:
				return lerpf(float(v.get("constantMin", 0.0)), float(v.get("constantMax", 0.0)), lerp_factor)
		return float(v.get("constant", 0.0))
	return float(v) if v != null else 0.0

func mmc_get(v, key: String):
	if v is Dictionary:
		return v.get(key)
	return null

## Struct setter: returns the updated value (the catalog assigns it back).
func mmc_with(v, key: String, value):
	var d: Dictionary = (v as Dictionary).duplicate() if v is Dictionary else {"mode": 0, "constant": float(v) if v != null else 0.0}
	d[key] = value
	if key == "constant":
		d["mode"] = 0
	elif key == "curve":
		d["mode"] = 1
	elif key == "constantMin" or key == "constantMax":
		if d.get("mode", 0) != 3:
			d["mode"] = 3
	elif key == "curveMin" or key == "curveMax":
		d["mode"] = 2
	elif key == "curveMultiplier":
		d["multiplier"] = value
	if d.get("mode", 0) == 0 and d.has("constant") and not d.has("curve"):
		return float(d["constant"])
	return d

## The Curve of a curve-mode value (null for constants).
func mmc_curve_of(v) -> Curve:
	if v is Dictionary:
		if v.has("curve"):
			return v["curve"]
		if v.has("curveMax"):
			return v["curveMax"]
	return null

# --- MinMaxGradient ---------------------------------------------------------------------------

func mmg_two_colors(a: Color, b: Color) -> Dictionary:
	return {"mode": 2, "colorMin": a, "colorMax": b}

func mmg_gradient_value(g: Gradient) -> Dictionary:
	return {"mode": 1, "gradient": g}

func mmg_two_gradients(a: Gradient, b: Gradient) -> Dictionary:
	return {"mode": 3, "gradientMin": a, "gradientMax": b}

func mmg_mode(v) -> int:
	if v is Dictionary:
		return int(v.get("mode", 0))
	return 0

func mmg_color(v) -> Color:
	if v is Dictionary:
		match int(v.get("mode", 0)):
			1, 3:
				var g: Gradient = v.get("gradient", v.get("gradientMax"))
				return g.sample(0.0) if g != null else Color.WHITE
			2:
				return v.get("colorMax", Color.WHITE)
		return v.get("color", Color.WHITE)
	return v if v is Color else Color.WHITE

func mmg_get(v, key: String):
	if v is Dictionary:
		return v.get(key)
	if key == "color":
		return v
	return null

func mmg_with(v, key: String, value):
	var d: Dictionary = (v as Dictionary).duplicate() if v is Dictionary else {"mode": 0, "color": v if v is Color else Color.WHITE}
	d[key] = value
	if key == "color":
		d["mode"] = 0
	elif key == "gradient":
		d["mode"] = 1
	elif key == "colorMin" or key == "colorMax":
		if d.get("mode", 0) != 2:
			d["mode"] = 2
	elif key == "gradientMin" or key == "gradientMax":
		d["mode"] = 3
	if d.get("mode", 0) == 0 and d.has("color"):
		return d["color"]
	return d

func mmg_eval(v, t: float, lerp_factor: float) -> Color:
	if v is Dictionary:
		match int(v.get("mode", 0)):
			1:
				var g: Gradient = v.get("gradient")
				return g.sample(t) if g != null else Color.WHITE
			2:
				return (v.get("colorMin", Color.WHITE) as Color).lerp(v.get("colorMax", Color.WHITE), lerp_factor)
			3:
				var a: Gradient = v.get("gradientMin")
				var b: Gradient = v.get("gradientMax")
				return (a.sample(t) if a != null else Color.WHITE).lerp(b.sample(t) if b != null else Color.WHITE, lerp_factor)
		return v.get("color", Color.WHITE)
	return v if v is Color else Color.WHITE

## A Godot Gradient for any MinMaxGradient value (constants become flat gradients).
func mmg_gradient(v) -> Gradient:
	if v is Dictionary:
		match int(v.get("mode", 0)):
			1:
				return v.get("gradient") if v.get("gradient") != null else Gradient.new()
			3:
				return v.get("gradientMax") if v.get("gradientMax") != null else Gradient.new()
			2:
				var g := Gradient.new()
				g.set_color(0, v.get("colorMin", Color.WHITE))
				g.set_color(1, v.get("colorMax", Color.WHITE))
				return g
	var flat := Gradient.new()
	var c: Color = mmg_color(v)
	flat.set_color(0, c)
	flat.set_color(1, c)
	return flat

# ---------------------------------------------------------------------------
# Renderer / Material
# ---------------------------------------------------------------------------

func _geom(n: Node) -> GeometryInstance3D:
	if n is GeometryInstance3D:
		return n
	if n != null:
		for c in n.get_children():
			if c is GeometryInstance3D:
				return c
	return null

func renderer_shared_material(n: Node) -> Material:
	var g := _geom(n)
	if g == null:
		return null
	if g.material_override != null:
		return g.material_override
	if g is MeshInstance3D:
		var m: Material = g.get_surface_override_material(0)
		if m == null and g.mesh != null and g.mesh.get_surface_count() > 0:
			m = g.mesh.surface_get_material(0)
		return m
	return null

## Unity `renderer.material` returns a per-instance copy; emulate by duplicating once.
func renderer_material(n: Node) -> Material:
	var g := _geom(n)
	if g == null:
		return null
	if g.has_meta("udon_instanced_material"):
		return g.get_meta("udon_instanced_material")
	var m := renderer_shared_material(n)
	if m == null:
		m = StandardMaterial3D.new()
	else:
		m = m.duplicate()
	g.material_override = m
	g.set_meta("udon_instanced_material", m)
	return m

func renderer_set_material(n: Node, m: Material) -> void:
	var g := _geom(n)
	if g != null:
		g.material_override = m
		g.set_meta("udon_instanced_material", m)

func renderer_materials(n: Node) -> Array:
	var g := _geom(n)
	var out: Array = []
	if g is MeshInstance3D and g.mesh != null:
		for i in range(g.mesh.get_surface_count()):
			var m: Material = g.get_surface_override_material(i)
			out.append(m if m != null else g.mesh.surface_get_material(i))
	elif g != null:
		out.append(renderer_shared_material(n))
	return out

func renderer_set_materials(n: Node, mats: Array) -> void:
	var g := _geom(n)
	if g is MeshInstance3D:
		for i in range(mini(mats.size(), g.get_surface_override_material_count())):
			g.set_surface_override_material(i, mats[i])

func renderer_bounds(n: Node) -> AABB:
	var g := _geom(n)
	return from_gd_aabb(g.global_transform * g.get_aabb()) if g != null else AABB()

func renderer_set_property_block(n: Node, block: Dictionary) -> void:
	var g := _geom(n)
	if g == null:
		return
	for k in block.keys():
		g.set_instance_shader_parameter(_shader_param_name(k), block[k])
	var m := renderer_material(n)
	for k in block.keys():
		mat_set(m, k, block[k])

func renderer_get_property_block(n: Node, block: Dictionary) -> void:
	var g := _geom(n)
	if g == null:
		return
	for k in block.keys():
		var v = g.get_instance_shader_parameter(_shader_param_name(k))
		if v != null:
			block[k] = v

func _shader_param_name(k) -> String:
	if k is int and _prop_names.has(k):
		k = _prop_names[k]
	var s: String = str(k)
	return s.trim_prefix("_")

func new_material(_shader) -> Material:
	if _shader is Shader:
		var sm := ShaderMaterial.new()
		sm.shader = _shader
		return sm
	return StandardMaterial3D.new()

## Map common Unity material properties onto StandardMaterial3D / ShaderMaterial.
func mat_set(m: Material, key, value) -> void:
	if m == null:
		return
	if is_render_texture(value):
		value = rt_texture(value)
	var k: String = _prop_names[key] if (key is int and _prop_names.has(key)) else str(key)
	if m is ShaderMaterial:
		m.set_shader_parameter(_shader_param_name(k), value)
		return
	if m is BaseMaterial3D:
		match k:
			"_Color", "_BaseColor", "color":
				m.albedo_color = value
			"_MainTex", "_BaseMap":
				m.albedo_texture = value
			"_EmissionColor":
				m.emission_enabled = true
				m.emission = value
			"_Metallic":
				m.metallic = float(value)
			"_Glossiness", "_Smoothness":
				m.roughness = 1.0 - float(value)
			"_BumpMap", "_NormalMap":
				m.normal_enabled = value != null
				m.normal_texture = value
			"_MainTex_Offset":
				m.uv1_offset = Vector3(value.x, value.y, 0.0)
			"_MainTex_Scale":
				m.uv1_scale = Vector3(value.x, value.y, 1.0)
			_:
				m.set_meta("udon_" + _shader_param_name(k), value)

func mat_get(m: Material, key, default):
	if m == null:
		return default
	var k: String = _prop_names[key] if (key is int and _prop_names.has(key)) else str(key)
	if m is ShaderMaterial:
		var v = m.get_shader_parameter(_shader_param_name(k))
		return v if v != null else default
	if m is BaseMaterial3D:
		match k:
			"_Color", "_BaseColor", "color":
				return m.albedo_color
			"_MainTex", "_BaseMap":
				return m.albedo_texture
			"_EmissionColor":
				return m.emission
			"_Metallic":
				return m.metallic
			"_Glossiness", "_Smoothness":
				return 1.0 - m.roughness
			"_MainTex_Offset":
				return Vector2(m.uv1_offset.x, m.uv1_offset.y)
			"_MainTex_Scale":
				return Vector2(m.uv1_scale.x, m.uv1_scale.y)
			_:
				return m.get_meta("udon_" + _shader_param_name(k), default)
	return default

func mat_has(m: Material, key) -> bool:
	var k: String = _prop_names[key] if (key is int and _prop_names.has(key)) else str(key)
	if m is ShaderMaterial:
		return m.get_shader_parameter(_shader_param_name(k)) != null
	return k in ["_Color", "_BaseColor", "_MainTex", "_EmissionColor", "_Metallic", "_Glossiness", "_Smoothness"] or m.has_meta("udon_" + _shader_param_name(k))

func mat_copy(dst: Material, src: Material) -> void:
	if dst is BaseMaterial3D and src is BaseMaterial3D:
		dst.albedo_color = src.albedo_color
		dst.albedo_texture = src.albedo_texture
		dst.emission = src.emission
		dst.emission_enabled = src.emission_enabled

func new_texture(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	return ImageTexture.create_from_image(img)

func texture_get_pixel(t: Texture2D, x: int, y: int) -> Color:
	var img := t.get_image()
	if img == null:
		return Color.BLACK
	return img.get_pixel(clampi(x, 0, img.get_width() - 1), clampi(img.get_height() - 1 - y, 0, img.get_height() - 1))

func texture_set_pixel(t: Texture2D, x: int, y: int, c: Color) -> void:
	var img := t.get_image()
	if img != null:
		img.set_pixel(x, img.get_height() - 1 - y, c)
		t.set_meta("udon_img", img)

func texture_set_pixels(t: Texture2D, colors: Array) -> void:
	var img := t.get_image()
	if img == null:
		return
	var w: int = img.get_width()
	for i in range(mini(colors.size(), w * img.get_height())):
		img.set_pixel(i % w, img.get_height() - 1 - (i / w), colors[i])
	t.set_meta("udon_img", img)

func texture_get_pixels(t: Texture2D) -> Array:
	var out: Array = []
	var img := t.get_image()
	if img == null:
		return out
	for y in range(img.get_height() - 1, -1, -1):
		for x in range(img.get_width()):
			out.append(img.get_pixel(x, y))
	return out

func texture_apply(t: Texture2D) -> void:
	if t is ImageTexture and t.has_meta("udon_img"):
		t.update(t.get_meta("udon_img"))

func white_texture() -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)

func black_texture() -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	return ImageTexture.create_from_image(img)

## RenderTextures are SubViewports created on demand (Unity: a contract between a Camera and a
## texture; Godot: the viewport must be in the tree). The UdonRenderTexture resource describes
## one; `rt_viewport` creates and caches its SubViewport under the U autoload.
var _rt_viewports: Dictionary = {}   # resource instance id → SubViewport
const _RT_SCRIPT = preload("res://addons/udon_runtime/udon_render_texture.gd")

func is_render_texture(rt) -> bool:
	return rt is Resource and rt.get_script() == _RT_SCRIPT

func new_render_texture(w: int, h: int, depth: int = 24):
	var rt: Resource = _RT_SCRIPT.new()
	rt.width = maxi(w, 1)
	rt.height = maxi(h, 1)
	rt.depth = depth
	return rt

func rt_viewport(rt) -> SubViewport:
	if not is_render_texture(rt):
		return null
	var id: int = rt.get_instance_id()
	if _rt_viewports.has(id) and is_instance_valid(_rt_viewports[id]):
		return _rt_viewports[id]
	var vp := SubViewport.new()
	vp.name = "RenderTexture_%d" % id
	vp.size = Vector2i(rt.width, rt.height)
	vp.transparent_bg = rt.transparent
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	_rt_viewports[id] = vp
	return vp

## The Texture2D to use where a script hands the RenderTexture to a material or UI element.
func rt_texture(rt) -> Texture2D:
	if rt is Texture2D:
		return rt
	var vp := rt_viewport(rt)
	return vp.get_texture() if vp != null else null

## Unity Camera.targetTexture: a proxy camera inside the texture's viewport follows this camera
## (RemoteTransform3D) and renders the shared world; the original stops rendering to the screen.
func camera_set_target_texture(c: Camera3D, rt) -> void:
	if c == null:
		return
	var old: Node = c.get_node_or_null("UdonRenderTarget")
	if old != null:
		var proxy_old = old.get_meta("proxy") if old.has_meta("proxy") else null
		if proxy_old is Node and is_instance_valid(proxy_old):
			proxy_old.queue_free()
		old.queue_free()
		c.set_meta("udon_target_texture", null)
	if rt == null:
		c.current = c.has_meta("udon_was_current") and c.get_meta("udon_was_current")
		return
	var vp := rt_viewport(rt)
	if vp == null:
		return
	var proxy := Camera3D.new()
	proxy.name = "Camera_" + str(c.get_instance_id())
	proxy.fov = c.fov
	proxy.near = c.near
	proxy.far = c.far
	proxy.projection = c.projection
	proxy.size = c.size
	proxy.cull_mask = c.cull_mask
	proxy.environment = c.environment
	vp.add_child(proxy)
	proxy.current = true
	proxy.global_transform = c.global_transform
	var rtf := RemoteTransform3D.new()
	rtf.name = "UdonRenderTarget"
	rtf.set_meta("proxy", proxy)
	c.add_child(rtf)
	rtf.remote_path = rtf.get_path_to(proxy)
	c.set_meta("udon_was_current", c.current)
	c.set_meta("udon_target_texture", rt)
	c.current = false

func camera_get_target_texture(c: Camera3D):
	if c == null or not c.has_meta("udon_target_texture"):
		return null
	return c.get_meta("udon_target_texture")

func mesh_vertex_count(m: Mesh) -> int:
	return mesh_vertices(m).size()

func mesh_vertices(m: Mesh) -> Array:
	if m == null or m.get_surface_count() == 0:
		return []
	return Array(m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX])

func mesh_normals(m: Mesh) -> Array:
	if m == null or m.get_surface_count() == 0:
		return []
	var n = m.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	return Array(n) if n != null else []

func mesh_triangles(m: Mesh) -> Array:
	if m == null or m.get_surface_count() == 0:
		return []
	var idx = m.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	return Array(idx) if idx != null else []

# ---------------------------------------------------------------------------
# Light / camera
# ---------------------------------------------------------------------------

func light_get_range(l: Light3D) -> float:
	if l is OmniLight3D:
		return l.omni_range
	if l is SpotLight3D:
		return l.spot_range
	return INF

func light_set_range(l: Light3D, r: float) -> void:
	if l is OmniLight3D:
		l.omni_range = r
	elif l is SpotLight3D:
		l.spot_range = r

func light_get_spot_angle(l: Light3D) -> float:
	return l.spot_angle * 2.0 if l is SpotLight3D else 30.0

func light_set_spot_angle(l: Light3D, a: float) -> void:
	if l is SpotLight3D:
		l.spot_angle = a / 2.0

func light_type(l: Light3D) -> int:
	if l is SpotLight3D:
		return 0
	if l is DirectionalLight3D:
		return 1
	return 2

func main_camera() -> Camera3D:
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

func camera_aspect(c: Camera3D) -> float:
	var s: Vector2 = c.get_viewport().get_visible_rect().size
	return s.x / maxf(s.y, 1.0)

func camera_set_enabled(c: Camera3D, v: bool) -> void:
	if v:
		c.make_current()
	elif c.current:
		c.clear_current()

func camera_get_bg(c: Camera3D) -> Color:
	if c.environment != null:
		return c.environment.background_color
	return Color.BLACK

func camera_set_bg(c: Camera3D, col: Color) -> void:
	if c.environment == null:
		c.environment = Environment.new()
		c.environment.background_mode = Environment.BG_COLOR
	c.environment.background_color = col

func camera_pixel_size(c: Camera3D) -> Vector2i:
	return Vector2i(c.get_viewport().get_visible_rect().size)

func screen_size() -> Vector2i:
	var vp := get_viewport()
	return Vector2i(vp.get_visible_rect().size) if vp != null else Vector2i(1920, 1080)

## Unity's camera space is right-handed with -Z forward (OpenGL convention); the view matrix in
## script space is the Unity worldToLocal followed by a Z flip.
func world_to_camera_matrix(c: Node3D) -> Transform3D:
	return Transform3D(Basis.from_scale(Vector3(1.0, 1.0, -1.0)), Vector3.ZERO) * world_to_local_matrix(c)

func world_to_screen(c: Camera3D, p_u: Vector3) -> Vector3:
	var p: Vector3 = to_gd_v(p_u)
	var s: Vector2 = c.unproject_position(p)
	var h: float = c.get_viewport().get_visible_rect().size.y
	var depth: float = (c.global_transform.affine_inverse() * p).z * -1.0
	return Vector3(s.x, h - s.y, depth)

func world_to_viewport(c: Camera3D, p: Vector3) -> Vector3:
	var s: Vector3 = world_to_screen(c, p)
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return Vector3(s.x / size.x, s.y / size.y, s.z)

func screen_to_world(c: Camera3D, p: Vector3) -> Vector3:
	var h: float = c.get_viewport().get_visible_rect().size.y
	return from_gd_v(c.project_position(Vector2(p.x, h - p.y), p.z))

func viewport_to_world(c: Camera3D, p: Vector3) -> Vector3:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return screen_to_world(c, Vector3(p.x * size.x, p.y * size.y, p.z))

func screen_point_to_ray(c: Camera3D, p: Vector3) -> Dictionary:
	var h: float = c.get_viewport().get_visible_rect().size.y
	var sp := Vector2(p.x, h - p.y)
	return {"origin": from_gd_v(c.project_ray_origin(sp)), "direction": from_gd_v(c.project_ray_normal(sp))}

func viewport_point_to_ray(c: Camera3D, p: Vector3) -> Dictionary:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return screen_point_to_ray(c, Vector3(p.x * size.x, p.y * size.y, 0.0))

func debug_draw_line(_a: Vector3, _b: Vector3, _c: Color, _dur: float) -> void:
	pass

# ---------------------------------------------------------------------------
# LineRenderer / TrailRenderer emulation (positions stored; drawn with an ImmediateMesh)
# ---------------------------------------------------------------------------

func _line(n: Node) -> Dictionary:
	var id: int = n.get_instance_id()
	if not _line_data.has(id):
		_line_data[id] = {"positions": [], "props": {}}
	return _line_data[id]

func line_get_count(n: Node) -> int:
	return _line(n)["positions"].size()

func line_set_count(n: Node, c: int) -> void:
	_line(n)["positions"].resize(maxi(c, 0))
	_line_redraw(n)

func line_set_position(n: Node, i: int, p: Vector3) -> void:
	var d := _line(n)
	if i >= d["positions"].size():
		d["positions"].resize(i + 1)
	d["positions"][i] = p
	_line_redraw(n)

func line_get_position(n: Node, i: int) -> Vector3:
	var d := _line(n)
	return d["positions"][i] if i < d["positions"].size() and d["positions"][i] != null else Vector3.ZERO

func line_set_positions(n: Node, arr: Array) -> void:
	_line(n)["positions"] = arr.duplicate()
	_line_redraw(n)

func line_get_positions(n: Node, into: Array) -> int:
	var d := _line(n)
	var c: int = mini(into.size(), d["positions"].size())
	for i in range(c):
		into[i] = d["positions"][i]
	return c

func line_get_prop(n: Node, key: String, default):
	return _line(n)["props"].get(key, default)

func line_set_prop(n: Node, key: String, value) -> void:
	_line(n)["props"][key] = value
	_line_redraw(n)

func line_clear(n: Node) -> void:
	_line(n)["positions"].clear()
	_line_redraw(n)

func _line_redraw(n: Node) -> void:
	if not (n is Node3D):
		return
	var d := _line(n)
	var mi: MeshInstance3D = n.get_node_or_null("_udon_line")
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "_udon_line"
		mi.mesh = ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mi.material_override = mat
		n.add_child(mi)
		mi.top_level = true
		mi.global_transform = Transform3D()
	var im: ImmediateMesh = mi.mesh
	im.clear_surfaces()
	var pts: Array = d["positions"]
	var set_pts: int = 0
	for p0 in pts:
		if p0 != null:
			set_pts += 1
	if set_pts < 2:
		return
	var world: bool = d["props"].get("useWorldSpace", true)
	var c0: Color = d["props"].get("startColor", Color.WHITE)
	var c1: Color = d["props"].get("endColor", c0)
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(pts.size()):
		var p = pts[i]
		if p == null:
			continue
		p = to_gd_v(p) if world else unity_transform(n) * to_gd_v(p)
		im.surface_set_color(c0.lerp(c1, float(i) / maxf(pts.size() - 1, 1.0)))
		im.surface_add_vertex(p)
	im.surface_end()

# ---------------------------------------------------------------------------
# UI helpers (Control-based)
# ---------------------------------------------------------------------------

func ui_get_text(n: Node) -> String:
	if n == null:
		return ""
	var t = n.get("text")
	return str(t) if t != null else ""

func ui_set_text(n: Node, s: String) -> void:
	if n != null and n.get("text") != null:
		n.set("text", s)

func ui_get_color(n: Node) -> Color:
	if n is Label3D:
		return n.modulate
	if n is Control:
		var c = n.get_theme_color("font_color") if n.has_theme_color("font_color") else null
		return c if c != null else n.modulate
	return Color.WHITE

func ui_set_color(n: Node, c: Color) -> void:
	if n is Label or n is RichTextLabel:
		n.add_theme_color_override("font_color", c)
	elif n is Label3D or n is CanvasItem:
		n.modulate = c

func ui_get_font_size(n: Node) -> int:
	if n is Label3D:
		return n.font_size
	if n is Control and n.has_theme_font_size("font_size"):
		return n.get_theme_font_size("font_size")
	return 16

func ui_set_font_size(n: Node, s: int) -> void:
	if n is Label3D:
		n.font_size = s
	elif n is Control:
		n.add_theme_font_size_override("font_size", s)

func ui_set_visible_characters(n: Node, c: int) -> void:
	if n.get("visible_characters") != null:
		n.set("visible_characters", c)

func ui_text_info(n: Node) -> Dictionary:
	var t: String = ui_get_text(n)
	return {"characterCount": t.length(), "lineCount": t.split("\n").size()}

func ui_fade_alpha(n: CanvasItem, alpha: float, duration: float) -> void:
	var tw := n.create_tween()
	tw.tween_property(n, "modulate:a", alpha, duration)

func ui_get_texture(n: Node):
	return n.get("texture")

func ui_set_texture(n: Node, t) -> void:
	if n.get("texture") != null or n is TextureRect:
		n.set("texture", t)

func ui_get_fill(n: Node) -> float:
	if n is TextureProgressBar:
		return n.ratio
	if n is Range:
		return n.ratio
	return n.get_meta("udon_fill", 1.0)

func ui_set_fill(n: Node, v: float) -> void:
	if n is TextureProgressBar or n is Range:
		n.ratio = v
	else:
		n.set_meta("udon_fill", v)
		if n is Control:
			n.scale.x = v

func ui_get_interactable(n: Node) -> bool:
	if n.get("disabled") != null:
		return not n.disabled
	if n.get("editable") != null:
		return n.editable
	return true

func ui_set_interactable(n: Node, v: bool) -> void:
	if n.get("disabled") != null:
		n.disabled = not v
	elif n.get("editable") != null:
		n.editable = v

func scroll_get_v(s: ScrollContainer) -> float:
	var bar := s.get_v_scroll_bar()
	var range_: float = bar.max_value - bar.page
	return 1.0 - (bar.value / range_ if range_ > 0.0 else 0.0)

func scroll_set_v(s: ScrollContainer, v: float) -> void:
	var bar := s.get_v_scroll_bar()
	bar.value = (1.0 - v) * (bar.max_value - bar.page)

func scroll_get_h(s: ScrollContainer) -> float:
	var bar := s.get_h_scroll_bar()
	var range_: float = bar.max_value - bar.page
	return bar.value / range_ if range_ > 0.0 else 0.0

func scroll_set_h(s: ScrollContainer, v: float) -> void:
	var bar := s.get_h_scroll_bar()
	bar.value = v * (bar.max_value - bar.page)

func scroll_content(s: ScrollContainer) -> Control:
	return s.get_child(0) if s.get_child_count() > 0 else null

func rect_get_pivot(c: Control) -> Vector2:
	return c.pivot_offset / c.size if c.size.x > 0.0 and c.size.y > 0.0 else Vector2(0.5, 0.5)

func rect_set_pivot(c: Control, p: Vector2) -> void:
	c.pivot_offset = p * c.size

func rect_set_anchor_min(c: Control, v: Vector2) -> void:
	c.anchor_left = v.x
	c.anchor_top = 1.0 - v.y

func rect_set_anchor_max(c: Control, v: Vector2) -> void:
	c.anchor_right = v.x
	c.anchor_bottom = 1.0 - v.y

func rect_set_offset_min(c: Control, v: Vector2) -> void:
	c.offset_left = v.x
	c.offset_bottom = -v.y

func rect_set_offset_max(c: Control, v: Vector2) -> void:
	c.offset_right = v.x
	c.offset_top = -v.y

func rect_set_size_axis(c: Control, axis: int, size: float) -> void:
	if axis == 0:
		c.size.x = size
	else:
		c.size.y = size

func rect_world_corners(c: Control, into: Array) -> void:
	var r: Rect2 = c.get_global_rect()
	var corners: Array = [Vector3(r.position.x, r.end.y, 0.0), Vector3(r.position.x, r.position.y, 0.0), Vector3(r.end.x, r.position.y, 0.0), Vector3(r.end.x, r.end.y, 0.0)]
	for i in range(mini(4, into.size())):
		into[i] = corners[i]

func app_is_focused() -> bool:
	return DisplayServer.window_is_focused()

func app_platform() -> int:
	match OS.get_name():
		"Windows":
			return 2
		"macOS":
			return 1
		"Linux":
			return 13
		"Android":
			return 11
		"iOS":
			return 8
		"Web":
			return 17
		_:
			return 2

func app_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "1.0"))

# ---------------------------------------------------------------------------
# UI interaction helpers (tests, bots, pointer/laser input on world-space canvases)
# ---------------------------------------------------------------------------

## Press a converted UI control the way a user would: buttons emit `pressed` (toggles flip),
## sliders/inputs/dropdowns take a value and emit their change signals.
func ui_press(n: Node, value = null) -> void:
	if n == null or not is_instance_valid(n):
		return
	if n is BaseButton:
		if n.disabled:
			return
		if n.toggle_mode:
			n.button_pressed = (not n.button_pressed) if value == null else bool(value)
		n.button_down.emit()
		n.pressed.emit()
		n.button_up.emit()
		if n.has_method("udon_ui_pressed"):
			n.udon_ui_pressed()
	elif n is Range:
		if value != null:
			n.value = float(value)
	elif n is LineEdit:
		if value != null:
			n.text = str(value)
			n.text_changed.emit(n.text)
		n.text_submitted.emit(n.text)
	elif n is TextEdit:
		if value != null:
			n.text = str(value)
			n.text_changed.emit()
	elif n is OptionButton:
		if value != null:
			n.select(int(value))
			n.item_selected.emit(int(value))
	elif n.has_method("Interact"):
		n.Interact()

## Find a control on a converted canvas by (Unity) name; `root` may be any node of the scene.
func ui_find(root: Node, name_: String) -> Node:
	if root == null:
		return null
	return root.find_child(name_, true, false)

## Click a world-space canvas (converted by unidot's udon_integration) at a world point: the hit
## is mapped to viewport pixels and delivered as mouse press/release events.
func ui_click_world(canvas_node: Node, world_point: Vector3) -> bool:
	if canvas_node == null or not canvas_node.has_meta("udon_canvas"):
		return false
	var cfg: Dictionary = canvas_node.get_meta("udon_canvas")
	if str(cfg.get("mode", "")) != "world":
		return false
	var vp: SubViewport = canvas_node.get_node_or_null(cfg["viewport"])
	var plane: Node3D = canvas_node.get_node_or_null(cfg["plane"])
	if vp == null or plane == null:
		return false
	var local: Vector3 = plane.global_transform.affine_inverse() * to_gd_v(world_point)
	var units: Vector2 = cfg.get("plane_size", cfg.get("size", Vector2(vp.size)))
	var k: float = float(cfg.get("k", 1.0))
	# the plane is a half-turned QuadMesh: texture U runs along -X, V down from the top
	var px: Vector2 = Vector2((units.x * 0.5 - local.x) * k, (units.y * 0.5 - local.y) * k)
	return ui_click_viewport(vp, px)

func ui_click_viewport(vp: SubViewport, px: Vector2) -> bool:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = px
	down.global_position = px
	var move := InputEventMouseMotion.new()
	move.position = px
	move.global_position = px
	vp.push_input(move, true)
	vp.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = px
	up.global_position = px
	vp.push_input(up, true)
	return true

# ---------------------------------------------------------------------------
# Strings & formatting
# ---------------------------------------------------------------------------

func bool_str(b: bool) -> String:
	return "True" if b else "False"

## Unity Object.name over nodes (name) and resources (resource_name).
## Generic property storage for Unity members Godot has no counterpart for (`!stored` catalog
## entries): values round-trip so scripts that set then read them behave, but nothing is rendered.
## Nodes keep them in the `udon_props` metadata, dictionaries as keys, module objects in `data`.
func prop_get(o, key: String, default = null):
	if o is Dictionary:
		return o.get(key, default)
	if o is Object:
		if o.get("data") is Dictionary:
			return o.data.get(key, default)
		if o.has_meta("udon_props"):
			var d: Dictionary = o.get_meta("udon_props")
			return d.get(key, default)
	return default

## Nodes and resources keep stored values in `udon_props` metadata; dictionaries hold them directly.
func prop_set(o, key: String, value) -> void:
	if o is Dictionary:
		o[key] = value
	elif o is Object:
		if o.get("data") is Dictionary:
			o.data[key] = value
			return
		var d: Dictionary = o.get_meta("udon_props") if o.has_meta("udon_props") else {}
		d[key] = value
		o.set_meta("udon_props", d)

func obj_get_name(o) -> String:
	if o is Node:
		return String(game_object(o).name)
	if o is Resource:
		return o.resource_name if o.resource_name != "" else o.resource_path.get_file().get_basename()
	return str(o) if o != null else ""

func obj_set_name(o, v: String) -> void:
	if o is Node:
		game_object(o).name = v
	elif o is Resource:
		o.resource_name = v

## Color.h/s/v are computed properties the sandbox cannot read on a Color value; do it host-side.
func color_hsv(c: Color) -> Array:
	return [c.h, c.s, c.v]

## Unity sliders are continuous unless wholeNumbers is set; Godot's default step of 1 would snap.
func slider_set_value(s, v: float) -> void:
	if s is Range:
		if s is Slider and s.step == 1.0 and not s.rounded:
			s.step = 0.0
		s.value = v

## C# float.ToString(): shortest round-trip, no trailing ".0".
func float_str(f: float) -> String:
	if is_nan(f):
		return "NaN"
	if is_inf(f):
		return "∞" if f > 0.0 else "-∞"
	if f == floorf(f) and absf(f) < 1e15:
		return str(int(f))
	# shortest decimal that round-trips through float32 (Godot's "%g" is unsupported)
	var f32: float = _f32(f)
	var e: int = int(floor(log(absf(f)) / log(10.0)))
	for sig in range(1, 10):
		var s: String = String.num(f, maxi(0, sig - 1 - e))
		if _f32(float(s)) == f32:
			return _trim_float(s)
	return _trim_float(String.num(f, 9))

func _f32(f: float) -> float:
	var p: PackedFloat32Array = PackedFloat32Array([f])
	return p[0]

func _trim_float(s: String) -> String:
	if s.contains(".") and not s.contains("e"):
		s = s.rstrip("0").rstrip(".")
	if s == "" or s == "-":
		s = "0"
	return s

## Fixed-point with .NET rounding (half away from zero; printf rounds half to even).
func _fixed(f: float, d: int) -> String:
	var scale: float = pow(10.0, d)
	var r: float = floor(absf(f) * scale + 0.5) / scale
	return ("-" if f < 0.0 and r != 0.0 else "") + ("%.*f" % [d, r])

## .NET "E" format: d.dddE+xxx
func _sci(f: float, d: int, upper: bool) -> String:
	var ex: String = "E" if upper else "e"
	if f == 0.0:
		return ("0." + "0".repeat(d) if d > 0 else "0") + ex + "+000"
	var e: int = int(floor(log(absf(f)) / log(10.0)))
	var ms: String = _fixed(f / pow(10.0, e), d)
	if absf(float(ms)) >= 10.0:
		e += 1
		ms = _fixed(f / pow(10.0, e), d)
	return ms + ex + ("+" if e >= 0 else "-") + str(absi(e)).pad_zeros(3)

func vec3_str(v: Vector3, fmt: String = "F2") -> String:
	return "(%s, %s, %s)" % [format_num(v.x, fmt), format_num(v.y, fmt), format_num(v.z, fmt)]

func vec2_str(v: Vector2, fmt: String = "F2") -> String:
	return "(%s, %s)" % [format_num(v.x, fmt), format_num(v.y, fmt)]

## .NET numeric format strings: F0..F9, N0..N9, D2, X, X4, 0.00, 0.#, P0, E2, C
func format_num(v, fmt: String) -> String:
	if fmt == null or fmt == "":
		return float_str(v) if typeof(v) == TYPE_FLOAT else str(v)
	if typeof(v) == TYPE_BOOL:
		return bool_str(v)
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return str(v)
	var f: float = float(v)
	var spec: String = fmt.substr(0, 1).to_upper()
	var digits_s: String = fmt.substr(1)
	var digits: int = int(digits_s) if digits_s.is_valid_int() else -1
	match spec:
		"F":
			return _fixed(f, digits if digits >= 0 else 2)
		"N":
			var d: int = digits if digits >= 0 else 2
			var s: String = _fixed(absf(f), d)
			var parts: PackedStringArray = s.split(".")
			var ip: String = parts[0]
			var out: String = ""
			var cnt: int = 0
			for i in range(ip.length() - 1, -1, -1):
				out = ip[i] + out
				cnt += 1
				if cnt % 3 == 0 and i > 0:
					out = "," + out
			if parts.size() > 1:
				out += "." + parts[1]
			return ("-" if f < 0.0 else "") + out
		"D":
			var iv: int = int(v)
			var s2: String = str(absi(iv))
			if digits > 0:
				s2 = s2.pad_zeros(digits)
			return ("-" if iv < 0 else "") + s2
		"X":
			var hex: String = ("%x" % int(v)).to_upper() if fmt.substr(0, 1) == "X" else ("%x" % int(v))
			while hex.length() < digits:
				hex = "0" + hex
			return hex
		"P":
			return _fixed(f * 100.0, digits if digits >= 0 else 2) + " %"
		"E":
			return _sci(f, digits if digits >= 0 else 6, fmt.substr(0, 1) == "E")
		"C":
			return "$" + format_num(f, "N" + (str(digits) if digits >= 0 else "2"))
		"G", "R":
			return float_str(f)
		_:
			pass
	# custom patterns: 0.00, #.##, 0.#
	if fmt.contains("0") or fmt.contains("#"):
		var dot: int = fmt.find(".")
		var int_part: String = fmt if dot < 0 else fmt.substr(0, dot)
		var frac_part: String = "" if dot < 0 else fmt.substr(dot + 1)
		var min_frac: int = frac_part.count("0")
		var max_frac: int = frac_part.length()
		var s3: String = _fixed(f, max_frac)
		if max_frac > min_frac and s3.contains("."):
			s3 = s3.rstrip("0")
			if s3.ends_with("."):
				s3 = s3.substr(0, s3.length() - 1)
		var min_int: int = int_part.count("0")
		var parts2: PackedStringArray = s3.split(".")
		var neg: bool = parts2[0].begins_with("-")
		var ip2: String = parts2[0].trim_prefix("-")
		if ip2.length() < min_int:
			ip2 = ip2.pad_zeros(min_int)
		if int_part.contains(","):
			var out2: String = ""
			var cnt2: int = 0
			for i in range(ip2.length() - 1, -1, -1):
				out2 = ip2[i] + out2
				cnt2 += 1
				if cnt2 % 3 == 0 and i > 0:
					out2 = "," + out2
			ip2 = out2
		var res: String = ("-" if neg else "") + ip2
		if parts2.size() > 1 and parts2[1] != "":
			res += "." + parts2[1]
		return res
	return str(v)

## string.Format / interpolation holes: {0}, {1:F2}, {0,5}
func format(fmt: String, args: Array) -> String:
	var out: String = ""
	var i: int = 0
	while i < fmt.length():
		var c: String = fmt[i]
		if c == "{":
			if i + 1 < fmt.length() and fmt[i + 1] == "{":
				out += "{"
				i += 2
				continue
			var close: int = fmt.find("}", i)
			if close < 0:
				out += fmt.substr(i)
				break
			var spec: String = fmt.substr(i + 1, close - i - 1)
			var idx_s: String = spec
			var f: String = ""
			var align: int = 0
			var colon: int = spec.find(":")
			if colon >= 0:
				idx_s = spec.substr(0, colon)
				f = spec.substr(colon + 1)
			var comma: int = idx_s.find(",")
			if comma >= 0:
				align = int(idx_s.substr(comma + 1))
				idx_s = idx_s.substr(0, comma)
			var idx: int = int(idx_s)
			var val = args[idx] if idx < args.size() else ""
			var s: String = format_num(val, f) if f != "" else _to_str(val)
			if align > 0:
				s = s.lpad(align)
			elif align < 0:
				s = s.rpad(-align)
			out += s
			i = close + 1
		elif c == "}" and i + 1 < fmt.length() and fmt[i + 1] == "}":
			out += "}"
			i += 2
		else:
			out += c
			i += 1
	return out

func _to_str(v) -> String:
	match typeof(v):
		TYPE_FLOAT:
			return float_str(v)
		TYPE_BOOL:
			return bool_str(v)
		TYPE_VECTOR3:
			return vec3_str(v)
		TYPE_VECTOR2:
			return vec2_str(v)
		_:
			return str(v)

func concat(parts: Array) -> String:
	var out: String = ""
	for p in parts:
		out += _to_str(p)
	return out

func join(sep: String, parts: Array) -> String:
	var strs: PackedStringArray = []
	for p in parts:
		strs.append(_to_str(p))
	return sep.join(strs)

func is_null_or_empty(s) -> bool:
	return s == null or str(s) == ""

func is_null_or_whitespace(s) -> bool:
	return s == null or str(s).strip_edges() == ""

func str_compare(a: String, b: String, ignore_case: bool = false) -> int:
	if ignore_case:
		return a.nocasecmp_to(b)
	return a.casecmp_to(b)

func str_equals(a: String, b: String, comparison: int) -> bool:
	if comparison == 1 or comparison == 3 or comparison == 5:
		return a.nocasecmp_to(b) == 0
	return a == b

func str_split(s: String, sep: String, options: int) -> Array:
	var out: Array = Array(s.split(sep, options & 1 == 0))
	if options & 2:
		for i in range(out.size()):
			out[i] = out[i].strip_edges()
	return out

func str_split_any(s: String, seps: Array, options: int = 0) -> Array:
	var out: Array = []
	var cur: String = ""
	for ch in s:
		if seps.has(ch):
			out.append(cur)
			cur = ""
		else:
			cur += ch
	out.append(cur)
	if options & 1:
		out = out.filter(func(x): return x != "")
	return out

func str_trim_chars(s: String, chars: Array, start: bool = true, end: bool = true) -> String:
	var cs: String = "".join(chars)
	if start and end:
		return s.strip_edges() if cs == "" else s.lstrip(cs).rstrip(cs)
	if start:
		return s.lstrip(cs)
	return s.rstrip(cs)

func pad_left(s: String, width: int, pad: String) -> String:
	while s.length() < width:
		s = pad + s
	return s

func pad_right(s: String, width: int, pad: String) -> String:
	while s.length() < width:
		s = s + pad
	return s

func to_char_array(s: String) -> Array:
	var out: Array = []
	for ch in s:
		out.append(ch)
	return out

func char_is_digit(c: String) -> bool:
	return c.length() > 0 and c.unicode_at(0) >= 48 and c.unicode_at(0) <= 57

func char_is_letter(c: String) -> bool:
	if c.length() == 0:
		return false
	var u: int = c.unicode_at(0)
	return (u >= 65 and u <= 90) or (u >= 97 and u <= 122) or u > 127 and c.to_upper() != c.to_lower()

func char_is_letter_or_digit(c: String) -> bool:
	return char_is_digit(c) or char_is_letter(c)

func char_is_whitespace(c: String) -> bool:
	return c.length() > 0 and c.strip_edges() == ""

func char_is_punctuation(c: String) -> bool:
	return c.length() > 0 and "!\"#%&'()*,-./:;?@[\\]_{}".contains(c)

func parse_base(s: String, base: int) -> int:
	if base == 16:
		return s.hex_to_int()
	if base == 2:
		return s.bin_to_int()
	return s.to_int()

func to_base(v: int, base: int) -> String:
	match base:
		16:
			return "%x" % v
		2:
			var out: String = ""
			var n: int = v
			if n == 0:
				return "0"
			while n > 0:
				out = str(n & 1) + out
				n >>= 1
			return out
		8:
			return "%o" % v
		_:
			return str(v)

## A random version-4 GUID in .NET's canonical "8-4-4-4-12" form.
func new_guid() -> String:
	var b := PackedByteArray()
	for _i in range(16):
		b.append(randi() & 255)
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	return guid_parse(b.hex_encode())

func bytes_to_int32(bytes: Array, offset: int) -> int:
	return PackedByteArray(bytes).decode_s32(offset)

func bytes_to_float(bytes: Array, offset: int) -> float:
	return PackedByteArray(bytes).decode_float(offset)

func int32_to_bytes(v: int) -> Array:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, v)
	return Array(b)

func float_to_bytes(v: float) -> Array:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return Array(b)

func float_to_bits(v: float) -> int:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b.decode_s32(0)

func bits_to_float(v: int) -> float:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, v)
	return b.decode_float(0)

# ---------------------------------------------------------------------------
# Arrays
# ---------------------------------------------------------------------------

func new_array(n: int, default) -> Array:
	var a: Array = []
	a.resize(maxi(n, 0))
	if default != null:
		a.fill(default)
	return a

func new_array_nd(dims: Array, default) -> Array:
	if dims.is_empty():
		return []
	var n: int = int(dims[0])
	if dims.size() == 1:
		return new_array(n, default)
	var a: Array = []
	a.resize(maxi(n, 0))
	for i in range(a.size()):
		a[i] = new_array_nd(dims.slice(1), default)
	return a

func array_rank(a: Array) -> int:
	var r: int = 1
	var cur = a
	while cur is Array and cur.size() > 0 and cur[0] is Array:
		r += 1
		cur = cur[0]
	return r

func array_get_length(a: Array, dim: int) -> int:
	var cur = a
	for _i in range(dim):
		if cur is Array and cur.size() > 0:
			cur = cur[0]
		else:
			return 0
	return cur.size() if cur is Array else 0

func array_copy(src: Array, si: int, dst: Array, di: int, n: int) -> void:
	for i in range(n):
		if si + i < src.size() and di + i < dst.size():
			dst[di + i] = src[si + i]

func array_clear(a: Array, i: int, n: int) -> void:
	for k in range(i, mini(i + n, a.size())):
		a[k] = null if not (a[k] is int or a[k] is float or a[k] is bool) else (0 if a[k] is int else (0.0 if a[k] is float else false))

func array_resized(a, n: int) -> Array:
	var out: Array = a.duplicate() if a != null else []
	out.resize(n)
	return out

func array_reverse_range(a: Array, i: int, n: int) -> void:
	var s: Array = a.slice(i, i + n)
	s.reverse()
	for k in range(s.size()):
		a[i + k] = s[k]

func array_sort_range(a: Array, i: int, n: int) -> void:
	var s: Array = a.slice(i, i + n)
	s.sort()
	for k in range(s.size()):
		a[i + k] = s[k]

func array_remove(a: Array, v) -> bool:
	var i: int = a.find(v)
	if i < 0:
		return false
	a.remove_at(i)
	return true

func array_remove_all(a: Array, v) -> int:
	var c: int = 0
	while a.has(v):
		a.erase(v)
		c += 1
	return c

func array_remove_range(a: Array, i: int, n: int) -> void:
	for _k in range(n):
		if i < a.size():
			a.remove_at(i)

func array_insert_range(a: Array, i: int, items: Array) -> void:
	for k in range(items.size()):
		a.insert(i + k, items[k])

# ---------------------------------------------------------------------------
# Data containers (VRC DataToken)
# ---------------------------------------------------------------------------

func token_type(v) -> int:
	match typeof(v):
		TYPE_NIL:
			return 0
		TYPE_BOOL:
			return 1
		TYPE_INT:
			return 6
		TYPE_FLOAT:
			return 11
		TYPE_STRING, TYPE_STRING_NAME:
			return 12
		TYPE_ARRAY:
			return 13
		TYPE_DICTIONARY:
			return 16 if v.has("error") and v.size() == 1 else 14
		_:
			return 15

func token_error(v) -> int:
	if v is Dictionary and v.has("error"):
		return int(v["error"])
	return 0

func json_parse(s: String):
	var j := JSON.new()
	if j.parse(s) != OK:
		return null
	return j.data

# ---------------------------------------------------------------------------
# Date / time
# ---------------------------------------------------------------------------

func datetime_now(utc: bool) -> Dictionary:
	var d: Dictionary = Time.get_datetime_dict_from_system(utc)
	var unix: float = Time.get_unix_time_from_system()
	d["unix"] = unix
	d["millisecond"] = int(fmod(unix, 1.0) * 1000.0)
	d["ticks"] = int(unix * 10000000.0) + 621355968000000000
	d["dayofyear"] = 1
	return d

func datetime_today() -> Dictionary:
	var d := datetime_now(false)
	d["hour"] = 0
	d["minute"] = 0
	d["second"] = 0
	d["millisecond"] = 0
	return d

func datetime_from_unix(unix: float) -> Dictionary:
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(int(unix))
	d["unix"] = unix
	d["millisecond"] = int(fmod(unix, 1.0) * 1000.0)
	d["ticks"] = int(unix * 10000000.0) + 621355968000000000
	d["dayofyear"] = 1
	return d

func datetime_date(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	out["hour"] = 0
	out["minute"] = 0
	out["second"] = 0
	return out

func datetime_add_seconds(d: Dictionary, s: float) -> Dictionary:
	return datetime_from_unix(float(d.get("unix", 0.0)) + s)

func datetime_diff(a: Dictionary, b: Dictionary) -> Dictionary:
	return timespan_from_seconds(float(a.get("unix", 0.0)) - float(b.get("unix", 0.0)))

func datetime_format(d: Dictionary, fmt: String) -> String:
	if fmt == "":
		return "%04d-%02d-%02d %02d:%02d:%02d" % [d.get("year", 0), d.get("month", 0), d.get("day", 0), d.get("hour", 0), d.get("minute", 0), d.get("second", 0)]
	var out: String = fmt
	out = out.replace("yyyy", "%04d" % d.get("year", 0)).replace("MM", "%02d" % d.get("month", 0)).replace("dd", "%02d" % d.get("day", 0))
	out = out.replace("HH", "%02d" % d.get("hour", 0)).replace("mm", "%02d" % d.get("minute", 0)).replace("ss", "%02d" % d.get("second", 0))
	out = out.replace("fff", "%03d" % d.get("millisecond", 0))
	return out

func timespan_from_seconds(s: float) -> Dictionary:
	return {"total_seconds": s}

func timespan_format(t: Dictionary, _fmt: String) -> String:
	var s: float = float(t.get("total_seconds", 0.0))
	var neg: bool = s < 0.0
	s = absf(s)
	var h: int = int(s / 3600.0)
	var m: int = int(fmod(s, 3600.0) / 60.0)
	var sec: float = fmod(s, 60.0)
	return ("-" if neg else "") + "%02d:%02d:%02d" % [h, m, int(sec)]

# ---------------------------------------------------------------------------
# Input key mapping
# ---------------------------------------------------------------------------

func keycode_to_godot_key(keycode: int) -> Key:
	if keycode >= 97 and keycode <= 122:
		return (KEY_A + (keycode - 97)) as Key
	if keycode >= 48 and keycode <= 57:
		return (KEY_0 + (keycode - 48)) as Key
	if keycode >= 282 and keycode <= 296:
		return (KEY_F1 + (keycode - 282)) as Key
	if keycode >= 256 and keycode <= 265:
		return (KEY_KP_0 + (keycode - 256)) as Key
	match keycode:
		8: return KEY_BACKSPACE
		9: return KEY_TAB
		13: return KEY_ENTER
		19: return KEY_PAUSE
		27: return KEY_ESCAPE
		32: return KEY_SPACE
		39: return KEY_APOSTROPHE
		44: return KEY_COMMA
		45: return KEY_MINUS
		46: return KEY_PERIOD
		47: return KEY_SLASH
		59: return KEY_SEMICOLON
		61: return KEY_EQUAL
		91: return KEY_BRACKETLEFT
		92: return KEY_BACKSLASH
		93: return KEY_BRACKETRIGHT
		96: return KEY_QUOTELEFT
		127: return KEY_DELETE
		266: return KEY_KP_PERIOD
		267: return KEY_KP_DIVIDE
		268: return KEY_KP_MULTIPLY
		269: return KEY_KP_SUBTRACT
		270: return KEY_KP_ADD
		271: return KEY_KP_ENTER
		273: return KEY_UP
		274: return KEY_DOWN
		275: return KEY_RIGHT
		276: return KEY_LEFT
		277: return KEY_INSERT
		278: return KEY_HOME
		279: return KEY_END
		280: return KEY_PAGEUP
		281: return KEY_PAGEDOWN
		300: return KEY_NUMLOCK
		301: return KEY_CAPSLOCK
		302: return KEY_SCROLLLOCK
		303, 304: return KEY_SHIFT
		305, 306: return KEY_CTRL
		307, 308: return KEY_ALT
		309, 310: return KEY_META
		311, 312: return KEY_META
		319: return KEY_MENU
		_: return KEY_NONE

func keycode_from_name(name_: String) -> int:
	var n: String = name_.to_lower()
	if n.length() == 1:
		return n.unicode_at(0)
	match n:
		"space": return 32
		"escape": return 27
		"return", "enter": return 13
		"tab": return 9
		"backspace": return 8
		"up": return 273
		"down": return 274
		"left": return 276
		"right": return 275
		"left shift": return 304
		"right shift": return 303
		"left ctrl": return 306
		"right ctrl": return 305
		"left alt": return 308
		"right alt": return 307
		_: return 0

# ---------------------------------------------------------------------------
# AnimationCurve (Curve), constraints, wheels
# ---------------------------------------------------------------------------

func curve_from_keys(keys: Array) -> Curve:
	var c := Curve.new()
	for k in keys:
		curve_add_key(c, float(k.get("time", 0.0)), float(k.get("value", 0.0)), float(k.get("inTangent", 0.0)), float(k.get("outTangent", 0.0)))
	return c

## Godot curves clamp to their domain/value range (0..1 by default); grow both to fit the keys.
func curve_add_key(c: Curve, t: float, v: float, tin: float = 0.0, tout: float = 0.0) -> int:
	if c.point_count == 0:
		c.min_domain = t
		c.max_domain = t
		c.min_value = v
		c.max_value = v
	c.min_domain = minf(c.min_domain, t)
	c.max_domain = maxf(c.max_domain, t)
	c.min_value = minf(c.min_value, v)
	c.max_value = maxf(c.max_value, v)
	return c.add_point(Vector2(t, v), tin, tout)

func curve_keys(c: Curve) -> Array:
	var out: Array = []
	for i in range(c.point_count):
		var p: Vector2 = c.get_point_position(i)
		out.append({"time": p.x, "value": p.y, "inTangent": c.get_point_left_tangent(i), "outTangent": c.get_point_right_tangent(i)})
	return out

func curve_move_key(c: Curve, i: int, k: Dictionary) -> int:
	c.set_point_offset(i, float(k.get("time", 0.0)))
	c.set_point_value(i, float(k.get("value", 0.0)))
	return i

func curve_linear(t0: float, v0: float, t1: float, v1: float) -> Curve:
	return curve_from_keys([{"time": t0, "value": v0}, {"time": t1, "value": v1}])

func curve_ease_in_out(t0: float, v0: float, t1: float, v1: float) -> Curve:
	var c := curve_linear(t0, v0, t1, v1)
	c.set_point_right_tangent(0, 0.0)
	c.set_point_left_tangent(1, 0.0)
	return c

var _constraints: Dictionary = {}

func _constraint(n: Node) -> Dictionary:
	var id: int = n.get_instance_id()
	if not _constraints.has(id):
		_constraints[id] = {"active": false, "weight": 1.0, "locked": false, "sources": []}
	return _constraints[id]

func constraint_get(n: Node, key: String, default):
	if n == null:
		return default
	return _constraint(n).get(key, default)

func constraint_set(n: Node, key: String, value) -> void:
	if n == null:
		return
	_constraint(n)[key] = value
	if n.has_method("udon_constraint_set"):
		n.udon_constraint_set(key, value)

func constraint_sources(n: Node) -> Array:
	return _constraint(n)["sources"] if n != null else []

func constraint_set_source(n: Node, i: int, src: Dictionary) -> void:
	var s: Array = constraint_sources(n)
	if i >= 0 and i < s.size():
		s[i] = src

func constraint_add_source(n: Node, src: Dictionary) -> int:
	var s: Array = constraint_sources(n)
	s.append(src)
	return s.size() - 1

func constraint_remove_source(n: Node, i: int) -> void:
	var s: Array = constraint_sources(n)
	if i >= 0 and i < s.size():
		s.remove_at(i)

func wheel_set_spring(w: VehicleWheel3D, spring: Dictionary) -> void:
	w.suspension_stiffness = float(spring.get("spring", w.suspension_stiffness))
	w.damping_compression = float(spring.get("damper", w.damping_compression))
	w.damping_relaxation = float(spring.get("damper", w.damping_relaxation))

# ---------------------------------------------------------------------------
# .NET extras: StringBuilder, Regex, Encoding, DateTime parsing, Stopwatch, Type
# ---------------------------------------------------------------------------

const _UdonStringBuilder := preload("res://addons/udon_runtime/udon_string_builder.gd")
var _regex_cache: Dictionary = {}

func new_string_builder(initial: String):
	return _UdonStringBuilder.new(initial)

func new_regex(pattern: String, options: int) -> RegEx:
	var p: String = pattern
	if options & 1:
		p = "(?i)" + p
	if options & 2:
		p = "(?m)" + p
	if options & 16:
		p = "(?s)" + p
	if options & 32:
		p = "(?x)" + p
	var r := RegEx.new()
	if r.compile(p) != OK:
		push_error("Regex: invalid pattern " + pattern)
	r.set_meta("udon_options", options)
	return r

func regex_static(pattern: String, options: int) -> RegEx:
	var key := "%d:%s" % [options, pattern]
	if not _regex_cache.has(key):
		_regex_cache[key] = new_regex(pattern, options)
	return _regex_cache[key]

func _match_dict(r: RegEx, m: RegExMatch, subject: String) -> Dictionary:
	if m == null:
		return {"success": false, "value": "", "index": 0, "length": 0, "groups": [], "name": "0"}
	var groups: Array = []
	var by_num: Dictionary = {}
	for n in m.names.keys():
		by_num[m.names[n]] = n
	for i in range(m.get_group_count() + 1):
		var s: int = m.get_start(i)
		groups.append({"success": s >= 0, "value": m.get_string(i), "index": maxi(s, 0), "length": m.get_string(i).length(), "name": str(by_num.get(i, str(i))), "groups": []})
	return {"success": true, "value": m.get_string(), "index": m.get_start(), "length": m.get_string().length(), "groups": groups, "name": "0", "_regex": r, "_subject": subject, "_end": m.get_end()}

func regex_match(r: RegEx, subject: String, start: int = 0, end: int = -1) -> Dictionary:
	return _match_dict(r, r.search(subject, start, end), subject)

func regex_next_match(m: Dictionary) -> Dictionary:
	var r = m.get("_regex")
	if r == null or not m.get("success", false):
		return _match_dict(null, null, "")
	var subject: String = m.get("_subject", "")
	var next: int = int(m.get("_end", 0))
	if next == int(m.get("index", 0)):
		next += 1
	return _match_dict(r, r.search(subject, next), subject)

func regex_matches(r: RegEx, subject: String, start: int = 0) -> Array:
	var out: Array = []
	for m in r.search_all(subject, start):
		out.append(_match_dict(r, m, subject))
	return out

## .NET replacement syntax ($1, ${name}) → Godot ($1, ${name} works too)
func regex_replacement(rep: String) -> String:
	return rep.replace("$$", "\\$")

func regex_replace_n(r: RegEx, subject: String, rep: String, count: int, start: int = 0) -> String:
	var out: String = subject
	var n: int = 0
	var pos: int = start
	while n < count:
		var m := r.search(out, pos)
		if m == null:
			break
		var repl: String = regex_expand(_match_dict(r, m, out), rep)
		out = out.substr(0, m.get_start()) + repl + out.substr(m.get_end())
		pos = m.get_start() + repl.length()
		n += 1
	return out

func regex_expand(m: Dictionary, rep: String) -> String:
	var out: String = rep
	var groups: Array = m.get("groups", [])
	for i in range(groups.size() - 1, -1, -1):
		out = out.replace("$" + str(i), str(groups[i].get("value", "")))
		out = out.replace("${" + str(groups[i].get("name", "")) + "}", str(groups[i].get("value", "")))
	return out.replace("$&", str(m.get("value", "")))

func regex_split(r: RegEx, subject: String, count: int = 0) -> Array:
	var out: Array = []
	var last: int = 0
	for m in r.search_all(subject):
		if count > 0 and out.size() >= count - 1:
			break
		out.append(subject.substr(last, m.get_start() - last))
		last = m.get_end()
	out.append(subject.substr(last))
	return out

func regex_group_name(r: RegEx, i: int) -> String:
	# Named groups are numbered in order of appearance; approximate with the names list.
	var names: PackedStringArray = r.get_names()
	if i >= 1 and i <= names.size():
		return names[i - 1]
	return str(i)

func regex_group_number(r: RegEx, name_: String) -> int:
	var names: PackedStringArray = r.get_names()
	var i: int = names.find(name_)
	return i + 1 if i >= 0 else -1

func regex_group_by_name(groups: Array, name_: String) -> Dictionary:
	for g in groups:
		if str(g.get("name", "")) == name_:
			return g
	return {"success": false, "value": "", "index": 0, "length": 0, "name": ""}

func regex_group_names(groups: Array) -> Array:
	var out: Array = []
	for g in groups:
		out.append(str(g.get("name", "")))
	return out

func regex_escape(s: String) -> String:
	var out: String = ""
	for c in s:
		if "\\*+?|{}[]()^$.#".contains(c) or c == " ":
			out += "\\"
		out += c
	return out

func regex_unescape(s: String) -> String:
	return s.replace("\\\\", "\\").replace("\\.", ".").replace("\\*", "*").replace("\\+", "+").replace("\\?", "?").replace("\\(", "(").replace("\\)", ")").replace("\\[", "[").replace("\\]", "]").replace("\\{", "{").replace("\\}", "}").replace("\\^", "^").replace("\\$", "$").replace("\\|", "|").replace("\\#", "#").replace("\\ ", " ")

func encoding_get_bytes(enc: String, s: String) -> Array:
	match enc:
		"ascii", "latin1":
			return Array(s.to_ascii_buffer())
		"utf16":
			return Array(s.to_utf16_buffer())
		"utf32":
			return Array(s.to_utf32_buffer())
		_:
			return Array(s.to_utf8_buffer())

func encoding_get_string(enc: String, bytes: Array) -> String:
	var b := PackedByteArray(bytes)
	match enc:
		"ascii", "latin1":
			return b.get_string_from_ascii()
		"utf16":
			return b.get_string_from_utf16()
		"utf32":
			return b.get_string_from_utf32()
		_:
			return b.get_string_from_utf8()

func datetime_parse(s: String) -> Dictionary:
	var unix: float = float(Time.get_unix_time_from_datetime_string(s.strip_edges().replace(" ", "T")))
	if unix <= 0.0 and not s.begins_with("1970"):
		return {"unix": -1.0}
	return datetime_from_unix(unix)

func datetime_from_parts(y: int, mo: int, d: int, h: int, mi: int, s: int) -> Dictionary:
	return datetime_from_unix(float(Time.get_unix_time_from_datetime_dict({"year": y, "month": mo, "day": d, "hour": h, "minute": mi, "second": s})))

func days_in_month(y: int, m: int) -> int:
	var days: Array = [31, 29 if ((y % 4 == 0 and y % 100 != 0) or y % 400 == 0) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	return days[clampi(m - 1, 0, 11)]

func stopwatch_start(sw: Dictionary) -> void:
	if not sw.get("running", false):
		sw["start"] = Time.get_ticks_usec()
		sw["running"] = true

func stopwatch_stop(sw: Dictionary) -> void:
	if sw.get("running", false):
		sw["acc"] = int(sw.get("acc", 0)) + (Time.get_ticks_usec() - int(sw.get("start", 0)))
		sw["running"] = false

func stopwatch_usec(sw: Dictionary) -> int:
	var acc: int = int(sw.get("acc", 0))
	if sw.get("running", false):
		acc += Time.get_ticks_usec() - int(sw.get("start", 0))
	return acc

func type_is_value(t: String) -> bool:
	return t in ["bool", "int", "float", "double", "long", "short", "byte", "char", "Vector3", "Vector2", "Vector4", "Quaternion", "Color", "Color32", "Rect", "Bounds", "Plane", "Ray", "Matrix4x4"]

func type_base(t: String) -> String:
	if ClassDB.class_exists(t):
		return ClassDB.get_parent_class(t)
	return "Object"

func type_code(t: String) -> int:
	match t:
		"bool": return 3
		"char": return 4
		"sbyte": return 5
		"byte": return 6
		"short": return 7
		"ushort": return 8
		"int": return 9
		"uint": return 10
		"long": return 11
		"ulong": return 12
		"float": return 13
		"double": return 14
		"decimal": return 15
		"DateTime": return 16
		"string": return 18
		_: return 1

func change_type(v, t: String):
	match t:
		"int", "long", "short", "byte", "uint", "ulong", "ushort", "sbyte": return int(v)
		"float", "double", "decimal": return float(v)
		"string": return str(v)
		"bool": return bool(v)
		_: return v

func array_index_of_range(a: Array, v, start: int, count: int) -> int:
	var i: int = a.find(v, start)
	return i if i >= 0 and i < start + count else -1

func array_last_index_of(a: Array, v, start: int) -> int:
	var i: int = start
	while i >= 0:
		if i < a.size() and a[i] == v:
			return i
		i -= 1
	return -1

func array_sort_keys_items(keys: Array, items: Array) -> void:
	var idx: Array = range(keys.size())
	idx.sort_custom(func(x, y): return keys[x] < keys[y])
	var k2: Array = keys.duplicate()
	var i2: Array = items.duplicate()
	for n in range(idx.size()):
		keys[n] = k2[idx[n]]
		if n < items.size():
			items[n] = i2[idx[n]]

func scene_root() -> Node:
	return get_tree().current_scene if get_tree().current_scene != null else get_tree().root

# ---------------------------------------------------------------------------
# 2D physics (Unity Y-up ↔ Godot Y-down)
# ---------------------------------------------------------------------------

func v2_to_gd(v: Vector2) -> Vector2:
	return Vector2(v.x, -v.y)

func v2_from_gd(v: Vector2) -> Vector2:
	return Vector2(v.x, -v.y)

func gravity2d() -> Vector2:
	var g: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
	var v: Vector2 = ProjectSettings.get_setting("physics/2d/default_gravity_vector", Vector2.DOWN)
	return v2_from_gd(v * g)

func set_gravity2d(g: Vector2) -> void:
	var space := get_viewport().world_2d.space
	PhysicsServer2D.area_set_param(space, PhysicsServer2D.AREA_PARAM_GRAVITY, g.length())
	PhysicsServer2D.area_set_param(space, PhysicsServer2D.AREA_PARAM_GRAVITY_VECTOR, v2_to_gd(g).normalized())

func rb2d_set_kinematic(rb: RigidBody2D, k: bool) -> void:
	rb.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
	rb.freeze = k

func rb2d_get_body_type(rb: RigidBody2D) -> int:
	if rb.freeze:
		return 2 if rb.freeze_mode == RigidBody2D.FREEZE_MODE_STATIC else 1
	return 0

func rb2d_set_body_type(rb: RigidBody2D, t: int) -> void:
	match t:
		1:
			rb.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
			rb.freeze = true
		2:
			rb.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
			rb.freeze = true
		_:
			rb.freeze = false

func rb2d_get_constraints(rb: RigidBody2D) -> int:
	return (4 if rb.lock_rotation else 0)

func rb2d_set_constraints(rb: RigidBody2D, c: int) -> void:
	rb.lock_rotation = (c & 4) != 0
	if c & 3 == 3:
		rb.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
		rb.freeze = true

func rb2d_add_force(rb: RigidBody2D, f: Vector2, mode: int) -> void:
	if mode == 1:
		rb.apply_central_impulse(v2_to_gd(f))
	else:
		rb.apply_central_force(v2_to_gd(f))

func rb2d_add_force_at(rb: RigidBody2D, f: Vector2, pos: Vector2, mode: int) -> void:
	var off: Vector2 = v2_to_gd(pos) - rb.global_position
	if mode == 1:
		rb.apply_impulse(v2_to_gd(f), off)
	else:
		rb.apply_force(v2_to_gd(f), off)

func rb2d_add_torque(rb: RigidBody2D, t: float, mode: int) -> void:
	if mode == 1:
		rb.apply_torque_impulse(-t)
	else:
		rb.apply_torque(-t)

func rb2d_move_position(rb: RigidBody2D, p: Vector2) -> void:
	var target: Vector2 = v2_to_gd(p)
	if rb.freeze:
		rb.global_position = target
	else:
		rb.linear_velocity = (target - rb.global_position) / fixed_delta_time()

func rb2d_move_rotation(rb: RigidBody2D, deg: float) -> void:
	var target: float = -deg_to_rad(deg)
	if rb.freeze:
		rb.global_rotation = target
	else:
		rb.angular_velocity = angle_difference(rb.global_rotation, target) / fixed_delta_time()

func rb2d_point_velocity(rb: RigidBody2D, p: Vector2) -> Vector2:
	var r: Vector2 = v2_to_gd(p) - rb.to_global(rb.center_of_mass)
	return v2_from_gd(rb.linear_velocity + Vector2(-r.y, r.x) * rb.angular_velocity)

func _space2d() -> PhysicsDirectSpaceState2D:
	var w := get_viewport().world_2d if get_viewport() != null else null
	return w.direct_space_state if w != null else null

func _mask2d(m: int) -> int:
	return 0xFFFFFFFF if m < 0 else m

func raycast2d(origin: Vector2, dir: Vector2, dist: float, mask: int) -> Dictionary:
	var space := _space2d()
	if space == null or dir.length_squared() < 1e-12:
		return {}
	var d: float = dist if is_finite(dist) else 100000.0
	var o: Vector2 = v2_to_gd(origin)
	var q := PhysicsRayQueryParameters2D.create(o, o + v2_to_gd(dir).normalized() * d, _mask2d(mask))
	q.collide_with_areas = true
	var r: Dictionary = space.intersect_ray(q)
	if r.is_empty():
		return {}
	var p: Vector2 = r["position"]
	return {"point": v2_from_gd(p), "normal": v2_from_gd(r["normal"]), "distance": o.distance_to(p), "fraction": o.distance_to(p) / d, "collider": r["collider"], "centroid": v2_from_gd(p)}

func raycast2d_all(origin: Vector2, dir: Vector2, dist: float, mask: int) -> Array:
	var out: Array = []
	var exclude: Array = []
	var space := _space2d()
	if space == null:
		return out
	var d: float = dist if is_finite(dist) else 100000.0
	var o: Vector2 = v2_to_gd(origin)
	for _i in range(32):
		var q := PhysicsRayQueryParameters2D.create(o, o + v2_to_gd(dir).normalized() * d, _mask2d(mask))
		q.collide_with_areas = true
		q.exclude = exclude
		var r: Dictionary = space.intersect_ray(q)
		if r.is_empty():
			break
		var p: Vector2 = r["position"]
		out.append({"point": v2_from_gd(p), "normal": v2_from_gd(r["normal"]), "distance": o.distance_to(p), "fraction": o.distance_to(p) / d, "collider": r["collider"], "centroid": v2_from_gd(p)})
		exclude.append(r["rid"])
	return out

func raycast2d_all_into(origin: Vector2, dir: Vector2, dist: float, mask: int, results: Array) -> int:
	var hits: Array = raycast2d_all(origin, dir, dist, mask)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func _shape2d(kind: String, radius: float, size: Vector2) -> Shape2D:
	match kind:
		"circle":
			var c := CircleShape2D.new()
			c.radius = radius
			return c
		"box":
			var b := RectangleShape2D.new()
			b.size = size
			return b
		"capsule":
			var cp := CapsuleShape2D.new()
			cp.radius = size.x / 2.0
			cp.height = size.y
			return cp
		_:
			var pt := CircleShape2D.new()
			pt.radius = 0.01
			return pt

## 2D twin of _cast_refined3d: [distance, unsafe origin] in Godot space, or [].
func _cast_refined2d(space: PhysicsDirectSpaceState2D, params: PhysicsShapeQueryParameters2D, dir: Vector2, max_len: float) -> Array:
	var rot: float = params.transform.get_rotation()
	var origin: Vector2 = params.transform.origin
	var remaining: float = max_len
	var reach: float = params.shape.get_rect().size.length() * 0.5 if params.shape != null else 1.0
	var ray := PhysicsRayQueryParameters2D.create(origin, origin + dir * max_len, params.collision_mask)
	ray.collide_with_areas = params.collide_with_areas
	ray.exclude = params.exclude
	var r: Dictionary = space.intersect_ray(ray)
	if not r.is_empty():
		remaining = minf(remaining, origin.distance_to(r["position"]) + reach * 2.0 + 0.01)
	else:
		remaining = minf(remaining, 10000.0)
	var total: float = 0.0
	var gap: float = 0.0
	for pass_ in range(5):
		params.transform = Transform2D(rot, origin)
		params.motion = dir * remaining
		var m: PackedFloat32Array = space.cast_motion(params)
		if m.size() < 2 or m[0] >= 1.0:
			if pass_ == 0:
				return []
			break
		total += remaining * m[0]
		origin += dir * remaining * m[0]
		gap = remaining * (m[1] - m[0])
		if gap <= 0.0002:
			break
		remaining = gap * 1.5 + 0.0002
	return [total, origin + dir * gap]

func shapecast2d(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, dir: Vector2, dist: float, mask: int) -> Dictionary:
	var space := _space2d()
	if space == null:
		return {}
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = _shape2d(kind, radius, size)
	params.transform = Transform2D(-deg_to_rad(angle), v2_to_gd(origin))
	var d: float = dist if is_finite(dist) else 100000.0
	var dir_gd: Vector2 = v2_to_gd(dir).normalized()
	params.collision_mask = _mask2d(mask)
	params.collide_with_areas = true
	var res: Array = _cast_refined2d(space, params, dir_gd, d)
	if res.is_empty():
		return {}
	var distance: float = res[0]
	var centroid: Vector2 = v2_to_gd(origin) + dir_gd * distance
	params.transform = Transform2D(-deg_to_rad(angle), res[1])
	params.motion = Vector2.ZERO
	var rest: Dictionary = space.get_rest_info(params)
	var col = instance_from_id(rest["collider_id"]) if rest.has("collider_id") else null
	if col == null:
		for r in space.intersect_shape(params, 1):
			col = r.get("collider")
	return {"point": v2_from_gd(rest.get("point", centroid)), "normal": v2_from_gd(rest.get("normal", -dir_gd)), "distance": distance, "fraction": distance / d, "collider": col, "centroid": v2_from_gd(centroid)}

func shapecast2d_all(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, dir: Vector2, dist: float, mask: int) -> Array:
	var h := shapecast2d(kind, origin, radius, size, angle, dir, dist, mask)
	return [h] if not h.is_empty() else []

func shapecast2d_into(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, dir: Vector2, dist: float, mask: int, results: Array) -> int:
	var hits: Array = shapecast2d_all(kind, origin, radius, size, angle, dir, dist, mask)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func overlap2d(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, mask: int) -> Array:
	var space := _space2d()
	if space == null:
		return []
	var out: Array = []
	if kind == "point":
		var pq := PhysicsPointQueryParameters2D.new()
		pq.position = v2_to_gd(origin)
		pq.collision_mask = _mask2d(mask)
		pq.collide_with_areas = true
		for r in space.intersect_point(pq, 64):
			out.append(r["collider"])
		return out
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = _shape2d(kind, radius, size)
	params.transform = Transform2D(-deg_to_rad(angle), v2_to_gd(origin))
	params.collision_mask = _mask2d(mask)
	params.collide_with_areas = true
	for r in space.intersect_shape(params, 64):
		out.append(r["collider"])
	return out

func overlap2d_first(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, mask: int):
	var all: Array = overlap2d(kind, origin, radius, size, angle, mask)
	return all[0] if not all.is_empty() else null

func overlap2d_into(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, mask: int, results: Array) -> int:
	var all: Array = overlap2d(kind, origin, radius, size, angle, mask)
	var n: int = mini(all.size(), results.size())
	for i in range(n):
		results[i] = all[i]
	return n

func _co2d(n: Node) -> CollisionObject2D:
	if n is CollisionObject2D:
		return n
	if n is CollisionShape2D and n.get_parent() is CollisionObject2D:
		return n.get_parent()
	if n != null:
		for c in n.get_children():
			if c is CollisionObject2D:
				return c
	return null

func shape2d_of(n: Node) -> CollisionShape2D:
	if n is CollisionShape2D:
		return n
	var co := _co2d(n)
	if co != null:
		for c in co.get_children():
			if c is CollisionShape2D:
				return c
	return null

func collider2d_get_enabled(n: Node) -> bool:
	var s := shape2d_of(n)
	return s != null and not s.disabled

func collider2d_set_enabled(n: Node, v: bool) -> void:
	var s := shape2d_of(n)
	if s != null:
		s.disabled = not v

func collider2d_attached_rigidbody(n: Node) -> RigidBody2D:
	var cur: Node = n
	while cur != null:
		if cur is RigidBody2D:
			return cur
		cur = cur.get_parent()
	return null

func collider2d_bounds(n: Node) -> AABB:
	var s := shape2d_of(n)
	if s == null or s.shape == null:
		return AABB()
	var r: Rect2 = s.shape.get_rect()
	var gr: Rect2 = s.global_transform * r
	var pos: Vector2 = v2_from_gd(gr.end)
	return AABB(Vector3(gr.position.x, pos.y, 0.0), Vector3(gr.size.x, gr.size.y, 0.0))

func collider2d_material(n: Node) -> PhysicsMaterial:
	var co := _co2d(n)
	return co.physics_material_override if co is PhysicsBody2D else null

func collider2d_set_material(n: Node, m: PhysicsMaterial) -> void:
	var co := _co2d(n)
	if co is PhysicsBody2D:
		co.physics_material_override = m

func collider2d_material_prop(n: Node, prop: String, default: float) -> float:
	var m := collider2d_material(n)
	return m.get(prop) if m != null else default

func shape2d_set_offset(n: Node, v: Vector2) -> void:
	var s := shape2d_of(n)
	if s != null:
		s.position = v2_to_gd(v)

func shape2d_get_size(n: Node) -> Vector2:
	var s := shape2d_of(n)
	if s != null and s.shape is RectangleShape2D:
		return s.shape.size
	if s != null and s.shape is CapsuleShape2D:
		return Vector2(s.shape.radius * 2.0, s.shape.height)
	return Vector2.ONE

func shape2d_set_size(n: Node, v: Vector2) -> void:
	var s := shape2d_of(n)
	if s != null and s.shape is RectangleShape2D:
		s.shape.size = v
	elif s != null and s.shape is CapsuleShape2D:
		s.shape.radius = v.x / 2.0
		s.shape.height = v.y

func shape2d_get_radius(n: Node) -> float:
	var s := shape2d_of(n)
	if s != null and (s.shape is CircleShape2D or s.shape is CapsuleShape2D):
		return s.shape.radius
	return 0.5

func shape2d_set_radius(n: Node, v: float) -> void:
	var s := shape2d_of(n)
	if s != null and (s.shape is CircleShape2D or s.shape is CapsuleShape2D):
		s.shape.radius = v

func shape2d_get_points(n: Node) -> Array:
	var s := shape2d_of(n)
	var out: Array = []
	if s != null and s.shape is ConvexPolygonShape2D:
		for p in s.shape.points:
			out.append(v2_from_gd(p))
	elif s != null and s.shape is ConcavePolygonShape2D:
		for p in s.shape.segments:
			out.append(v2_from_gd(p))
	return out

func shape2d_get_points_into(n: Node, into: Array) -> int:
	var pts: Array = shape2d_get_points(n)
	into.assign(pts)
	return pts.size()

func shape2d_set_points(n: Node, pts: Array) -> void:
	var s := shape2d_of(n)
	if s == null:
		return
	var conv := PackedVector2Array()
	for p in pts:
		conv.append(v2_to_gd(p))
	if s.shape is ConvexPolygonShape2D or s.shape == null:
		var sh := ConvexPolygonShape2D.new()
		sh.points = conv
		s.shape = sh
	elif s.shape is ConcavePolygonShape2D:
		var seg := PackedVector2Array()
		for i in range(conv.size() - 1):
			seg.append(conv[i])
			seg.append(conv[i + 1])
		s.shape.segments = seg

func collider2d_touching(a: Node, b: Node) -> bool:
	var ca := _co2d(a)
	var cb := _co2d(b)
	if ca == null or cb == null:
		return false
	if ca is RigidBody2D:
		return ca.get_colliding_bodies().has(cb)
	if ca is Area2D:
		return ca.get_overlapping_bodies().has(cb) or ca.get_overlapping_areas().has(cb)
	return false

func collider2d_touching_any(a: Node) -> bool:
	var ca := _co2d(a)
	if ca is RigidBody2D:
		return not ca.get_colliding_bodies().is_empty()
	if ca is Area2D:
		return not ca.get_overlapping_bodies().is_empty()
	return false

func collider2d_overlap_point(n: Node, p: Vector2) -> bool:
	var co := _co2d(n)
	return co != null and overlap2d("point", p, 0.0, Vector2.ZERO, 0.0, -1).has(co)

func collider2d_closest_point(n: Node, p: Vector2) -> Vector2:
	var b := collider2d_bounds(n)
	var c := aabb_closest_point(b, Vector3(p.x, p.y, 0.0))
	return Vector2(c.x, c.y)

func collider2d_distance(a: Node, b: Node) -> Dictionary:
	var pa: Vector2 = collider2d_closest_point(a, collider2d_closest_point(b, Vector2.ZERO))
	var pb: Vector2 = collider2d_closest_point(b, pa)
	return {"pointA": pa, "pointB": pb, "normal": (pb - pa).normalized(), "distance": pa.distance_to(pb)}

func collider2d_raycast(n: Node, dir: Vector2, results: Array, dist: float) -> int:
	var co := _co2d(n)
	if not (co is Node2D):
		return 0
	var hit := raycast2d(v2_from_gd(co.global_position), dir, dist, -1)
	if hit.is_empty() or results.is_empty():
		return 0
	results[0] = hit
	return 1

func rb2d_cast(n: Node, dir: Vector2, results: Array, dist: float) -> int:
	var co := _co2d(n)
	var s := shape2d_of(n)
	if co == null or s == null or s.shape == null:
		return 0
	var space := _space2d()
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = s.shape
	params.transform = s.global_transform
	params.exclude = [co.get_rid()]
	var d: float = dist if is_finite(dist) else 100000.0
	var dir_gd: Vector2 = v2_to_gd(dir).normalized()
	var res: Array = _cast_refined2d(space, params, dir_gd, d)
	if res.is_empty() or results.is_empty():
		return 0
	var centroid: Vector2 = s.global_position + dir_gd * res[0]
	params.transform = Transform2D(s.global_transform.get_rotation(), res[1])
	params.motion = Vector2.ZERO
	var rest: Dictionary = space.get_rest_info(params)
	var col = instance_from_id(rest["collider_id"]) if rest.has("collider_id") else null
	results[0] = {"point": v2_from_gd(rest.get("point", centroid)), "normal": v2_from_gd(rest.get("normal", -dir_gd)), "distance": res[0], "fraction": res[0] / d, "collider": col, "centroid": v2_from_gd(centroid)}
	return 1

func rb2d_attached_colliders(rb: RigidBody2D, into: Array) -> int:
	var n: int = 0
	for c in rb.get_children():
		if c is CollisionShape2D and n < into.size():
			into[n] = c
			n += 1
	return n

func rb2d_contacts(n: Node, into: Array) -> int:
	var co := _co2d(n)
	var bodies: Array = []
	if co is RigidBody2D:
		bodies = co.get_colliding_bodies()
	elif co is Area2D:
		bodies = co.get_overlapping_bodies()
	var k: int = mini(bodies.size(), into.size())
	for i in range(k):
		into[i] = bodies[i]
	return k

func rb2d_overlap_point(rb: RigidBody2D, p: Vector2) -> bool:
	return overlap2d("point", p, 0.0, Vector2.ZERO, 0.0, -1).has(rb)

func collider2d_contact_points(n: Node, into: Array) -> int:
	var co := _co2d(n)
	if not (co is RigidBody2D) or into.is_empty():
		return 0
	var bodies: Array = co.get_colliding_bodies()
	var k: int = mini(bodies.size(), into.size())
	for i in range(k):
		into[i] = {"point": v2_from_gd(bodies[i].global_position), "normal": Vector2.UP, "collider": bodies[i], "otherCollider": co}
	return k

func collider2d_overlap(n: Node, into: Array) -> int:
	return rb2d_contacts(n, into)

func ignore_collision2d(a: Node, b: Node, ignore: bool) -> void:
	var ca := _co2d(a)
	var cb := _co2d(b)
	if ca is PhysicsBody2D and cb is PhysicsBody2D:
		if ignore:
			ca.add_collision_exception_with(cb)
		else:
			ca.remove_collision_exception_with(cb)

var _effectors: Dictionary = {}

func effector_get(n: Node, key: String, default):
	return _effectors.get(n.get_instance_id(), {}).get(key, default) if n != null else default

func effector_set(n: Node, key: String, value) -> void:
	if n == null:
		return
	var id: int = n.get_instance_id()
	if not _effectors.has(id):
		_effectors[id] = {}
	_effectors[id][key] = value
	if n is Area2D and key in ["forceAngle", "forceMagnitude"]:
		var ang: float = float(_effectors[id].get("forceAngle", 0.0))
		var mag: float = float(_effectors[id].get("forceMagnitude", 0.0))
		n.gravity_direction = v2_to_gd(Vector2(cos(deg_to_rad(ang)), sin(deg_to_rad(ang))))
		n.gravity = mag
		n.gravity_space_override = Area2D.SPACE_OVERRIDE_COMBINE if mag != 0.0 else Area2D.SPACE_OVERRIDE_DISABLED

# ---------------------------------------------------------------------------
# Navigation & character controller
# ---------------------------------------------------------------------------

var _nav: Dictionary = {}

func nav_get(a: Node, key: String, default):
	return _nav.get(a.get_instance_id(), {}).get(key, default) if a != null else default

func nav_set(a: Node, key: String, value) -> void:
	if a == null:
		return
	var id: int = a.get_instance_id()
	if not _nav.has(id):
		_nav[id] = {}
	_nav[id][key] = value

func nav_origin(a: NavigationAgent3D) -> Vector3:
	var p := a.get_parent()
	return get_position(p) if p is Node3D else Vector3.ZERO

func nav_set_stopped(a: NavigationAgent3D, stopped: bool) -> void:
	nav_set(a, "stopped", stopped)
	if stopped:
		a.velocity = Vector3.ZERO

func nav_warp(a: NavigationAgent3D, p: Vector3) -> bool:
	var body := a.get_parent()
	if body is Node3D:
		set_position(body, p)
	return true

func nav_move(a: NavigationAgent3D, offset: Vector3) -> void:
	var body := a.get_parent()
	if body is Node3D:
		body.global_position += to_gd_v(offset)

func nav_sample(p: Vector3, max_dist: float) -> Dictionary:
	var map: RID = _nav_map()
	if not map.is_valid():
		return {"position": p, "hit": false}
	var c: Vector3 = from_gd_v(NavigationServer3D.map_get_closest_point(map, to_gd_v(p)))
	return {"position": c, "normal": Vector3.UP, "distance": p.distance_to(c), "hit": p.distance_to(c) <= max_dist, "mask": -1}

func nav_path(from: Vector3, to: Vector3) -> Array:
	var map: RID = _nav_map()
	if not map.is_valid():
		return []
	var out: Array = []
	for p in NavigationServer3D.map_get_path(map, to_gd_v(from), to_gd_v(to), true):
		out.append(from_gd_v(p))
	return out

func cc_collision_flags(cc: CharacterBody3D) -> int:
	var f: int = 0
	if cc.is_on_wall():
		f |= 1
	if cc.is_on_ceiling():
		f |= 2
	if cc.is_on_floor():
		f |= 4
	return f

## CharacterController.Move: displacement this frame (no gravity applied by Unity either).
func cc_move(cc: CharacterBody3D, motion: Vector3) -> int:
	# move_and_slide integrates velocity over the current frame's delta (physics or process)
	var dt: float = get_physics_process_delta_time() if Engine.is_in_physics_frame() else get_process_delta_time()
	dt = maxf(dt, 0.0001)
	cc.velocity = motion / dt
	cc.move_and_slide()
	if OS.has_environment("UDON_PHYS_DEBUG"):
		print("[phys] cc_move dt=", dt, " vel=", cc.velocity, " pos=", cc.global_position, " floor=", cc.is_on_floor(), " slides=", cc.get_slide_collision_count(), " shape=", shape_of(cc).shape if shape_of(cc) != null else null, " mask=", cc.collision_mask)
	_cc_report_hits(cc, motion)
	return cc_collision_flags(cc)

## OnControllerColliderHit for every surface the move slid along (ControllerColliderHit dicts).
func _cc_report_hits(cc: CharacterBody3D, motion: Vector3) -> void:
	var n: int = cc.get_slide_collision_count()
	if n == 0 or not (Udon.physics_has_handler(cc, "OnControllerColliderHit") or Udon.physics_has_handler(cc, "OnControllerColliderHitPlayer")):
		return
	var dir_u: Vector3 = motion.normalized() if motion.length_squared() > 1e-12 else Vector3.ZERO
	var seen: Array = []
	for i in range(n):
		var kc: KinematicCollision3D = cc.get_slide_collision(i)
		var other = kc.get_collider()
		if other == null or seen.has(other):
			continue
		seen.append(other)
		var hit: Dictionary = {"collider": other, "controller": cc, "moveDirection": dir_u, "moveLength": motion.length(), "normal": from_gd_v(kc.get_normal()), "point": from_gd_v(kc.get_position())}
		Udon.dispatch_physics(cc, "OnControllerColliderHit", [hit])
		var player = Udon._phys_player_of(other)
		if player != null:
			hit["player"] = player
			Udon.dispatch_physics(cc, "OnControllerColliderHitPlayer", [hit])

## CharacterController.SimpleMove: velocity in m/s with gravity.
func cc_simple_move(cc: CharacterBody3D, speed: Vector3) -> bool:
	var v: Vector3 = speed
	v.y = cc.velocity.y + gravity().y * delta_time()
	if cc.is_on_floor() and v.y < 0.0:
		v.y = -0.1
	cc.velocity = v
	cc.move_and_slide()
	return cc.is_on_floor()

# ---------------------------------------------------------------------------
# RenderSettings (WorldEnvironment), camera, mesh, texture, matrix, joint, misc adapters
# ---------------------------------------------------------------------------

func _env() -> Environment:
	var we: WorldEnvironment = find_object_of_type("WorldEnvironment")
	if we != null:
		if we.environment == null:
			we.environment = Environment.new()
		return we.environment
	var cam := main_camera()
	if cam != null:
		if cam.environment == null:
			cam.environment = Environment.new()
		return cam.environment
	return null

func env_get(prop: String, default):
	var e := _env()
	if e == null:
		return default
	if prop == "sky":
		return e.sky
	var v = e.get(prop)
	return v if v != null else default

func env_set(prop: String, value) -> void:
	var e := _env()
	if e == null:
		return
	if prop == "fog_enabled":
		e.fog_enabled = bool(value)
	elif prop == "ambient_light_source":
		e.ambient_light_source = (Environment.AMBIENT_SOURCE_COLOR if int(value) != 0 else Environment.AMBIENT_SOURCE_BG)
	else:
		e.set(prop, value)

func env_set_skybox(mat) -> void:
	var e := _env()
	if e == null:
		return
	if mat is Sky:
		e.sky = mat
		e.background_mode = Environment.BG_SKY
	elif mat is Material:
		var sky := Sky.new()
		sky.sky_material = mat
		e.sky = sky
		e.background_mode = Environment.BG_SKY

func env_sun() -> DirectionalLight3D:
	return find_object_of_type("DirectionalLight3D")

func env_set_sun(_l) -> void:
	pass

func camera_projection(c: Camera3D) -> Transform3D:
	return c.global_transform.affine_inverse()

func camera_frustum_corners(c: Camera3D, z: float, into: Array) -> void:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	var corners: Array = [Vector2(0, size.y), Vector2(0, 0), Vector2(size.x, 0), Vector2(size.x, size.y)]
	for i in range(mini(4, into.size())):
		into[i] = c.to_local(c.project_position(corners[i], z))

func camera_copy_from(dst: Camera3D, src: Camera3D) -> void:
	dst.fov = src.fov
	dst.near = src.near
	dst.far = src.far
	dst.projection = src.projection
	dst.size = src.size
	dst.cull_mask = src.cull_mask
	dst.global_transform = src.global_transform

func screen_to_viewport(c: Camera3D, p: Vector3) -> Vector3:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return Vector3(p.x / size.x, p.y / size.y, p.z)

func viewport_to_screen(c: Camera3D, p: Vector3) -> Vector3:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return Vector3(p.x * size.x, p.y * size.y, p.z)

func all_cameras() -> Array:
	return get_components_in_children(scene_root(), "Camera3D", true)

func mesh_array(m: Mesh, idx: int) -> Array:
	if m == null or m.get_surface_count() == 0:
		return []
	var a = m.surface_get_arrays(0)[idx]
	return Array(a) if a != null else []

func mesh_tangents(m: Mesh) -> Array:
	var raw: Array = mesh_array(m, Mesh.ARRAY_TANGENT)
	var out: Array = []
	for i in range(0, raw.size() - 3, 4):
		out.append(Vector4(raw[i], raw[i + 1], raw[i + 2], raw[i + 3]))
	return out

func mesh_set_arrays(m: Mesh, which: String, data: Array) -> void:
	if not (m is ArrayMesh):
		return
	var arrays: Array = m.surface_get_arrays(0) if m.get_surface_count() > 0 else []
	if arrays.is_empty():
		arrays.resize(Mesh.ARRAY_MAX)
	match which:
		"vertices":
			arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(data)
		"normals":
			arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(data)
		"triangles":
			arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(data)
		"uv":
			arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(data)
		"uv2":
			arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array(data)
		"colors":
			arrays[Mesh.ARRAY_COLOR] = PackedColorArray(data)
		"tangents":
			var t := PackedFloat32Array()
			for v in data:
				t.append_array([v.x, v.y, v.z, v.w])
			arrays[Mesh.ARRAY_TANGENT] = t
	if arrays[Mesh.ARRAY_VERTEX] == null:
		return
	if m.get_surface_count() > 0:
		m.clear_surfaces()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func mesh_clear(m: Mesh) -> void:
	if m is ArrayMesh:
		m.clear_surfaces()

func mesh_blend_shape_index(m: Mesh, name_: String) -> int:
	if m is ArrayMesh:
		for i in range(m.get_blend_shape_count()):
			if String(m.get_blend_shape_name(i)) == name_:
				return i
	return -1

func texture_get_pixels_rect(t: Texture2D, x: int, y: int, w: int, h: int) -> Array:
	var out: Array = []
	var img := t.get_image()
	if img == null:
		return out
	for yy in range(y + h - 1, y - 1, -1):
		for xx in range(x, x + w):
			out.append(img.get_pixel(clampi(xx, 0, img.get_width() - 1), clampi(img.get_height() - 1 - yy, 0, img.get_height() - 1)))
	return out

func texture_set_pixels_rect(t: Texture2D, x: int, y: int, w: int, h: int, colors: Array) -> void:
	var img := t.get_image()
	if img == null:
		return
	var i: int = 0
	for yy in range(y, y + h):
		for xx in range(x, x + w):
			if i < colors.size():
				img.set_pixel(clampi(xx, 0, img.get_width() - 1), clampi(img.get_height() - 1 - yy, 0, img.get_height() - 1), colors[i])
			i += 1
	t.set_meta("udon_img", img)

func texture_load_raw(t: Texture2D, bytes: Array) -> void:
	var img := t.get_image()
	if img == null:
		return
	var b := PackedByteArray(bytes)
	if b.size() == img.get_data().size():
		img.set_data(img.get_width(), img.get_height(), img.has_mipmaps(), img.get_format(), b)
		t.set_meta("udon_img", img)

func texture_resize(t: Texture2D, w: int, h: int) -> bool:
	var img := t.get_image()
	if img == null:
		return false
	img.resize(w, h)
	if t is ImageTexture:
		t.set_image(img)
	return true

var _rt: Dictionary = {}

func rt_get(t, key: String, default):
	if t == null:
		return default
	if is_render_texture(t):
		match key:
			"width":
				return t.width
			"height":
				return t.height
			"depth":
				return t.depth
	if key == "width" and t is Texture2D:
		return t.get_width()
	if key == "height" and t is Texture2D:
		return t.get_height()
	return _rt.get(t.get_instance_id(), {}).get(key, default) if t is Object else default

func rt_set(t, key: String, value) -> void:
	if not (t is Object):
		return
	var id: int = t.get_instance_id()
	if not _rt.has(id):
		_rt[id] = {}
	_rt[id][key] = value

func matrix_get(t: Transform3D, row: int, col: int) -> float:
	var c: Vector4 = matrix_column(t, col)
	return c[row]

func matrix_from_columns(c0: Vector4, c1: Vector4, c2: Vector4, c3: Vector4) -> Transform3D:
	return Transform3D(Vector3(c0.x, c0.y, c0.z), Vector3(c1.x, c1.y, c1.z), Vector3(c2.x, c2.y, c2.z), Vector3(c3.x, c3.y, c3.z))

func matrix_set_column(t: Transform3D, i: int, v: Vector4) -> Transform3D:
	var v3 := Vector3(v.x, v.y, v.z)
	match i:
		0: t.basis.x = v3
		1: t.basis.y = v3
		2: t.basis.z = v3
		_: t.origin = v3
	return t

func matrix_set_row(t: Transform3D, i: int, v: Vector4) -> Transform3D:
	if i < 3:
		t.basis.x[i] = v.x
		t.basis.y[i] = v.y
		t.basis.z[i] = v.z
		t.origin[i] = v.w
	return t

func matrix_mul_vec4(t: Transform3D, v: Vector4) -> Vector4:
	var p: Vector3 = t.basis * Vector3(v.x, v.y, v.z) + t.origin * v.w
	return Vector4(p.x, p.y, p.z, v.w)

var _joints: Dictionary = {}

func joint_get(j: Node, key: String, default):
	return _joints.get(j.get_instance_id(), {}).get(key, default) if j != null else default

func joint_set(j: Node, key: String, value) -> void:
	if j == null:
		return
	var id: int = j.get_instance_id()
	if not _joints.has(id):
		_joints[id] = {}
	_joints[id][key] = value

## ConfigurableJointMotion: Locked=0 Limited=1 Free=2 → Generic6DOFJoint3D linear limits
func joint6_motion(j: Node, axis: int, motion: int) -> void:
	if not (j is Generic6DOFJoint3D):
		return
	var flag := Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT
	j.set_flag_x(flag, motion != 2) if axis == 0 else (j.set_flag_y(flag, motion != 2) if axis == 1 else j.set_flag_z(flag, motion != 2))
	var lim: float = 0.0 if motion == 0 else float(joint_get(j, "linearLimit", 0.0))
	joint6_linear_limit_axis(j, axis, lim)

func joint6_angular(j: Node, axis: int, motion: int) -> void:
	if not (j is Generic6DOFJoint3D):
		return
	var flag := Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT
	match axis:
		0: j.set_flag_x(flag, motion != 2)
		1: j.set_flag_y(flag, motion != 2)
		_: j.set_flag_z(flag, motion != 2)
	if motion == 0:
		var lo := Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT
		var hi := Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT
		match axis:
			0:
				j.set_param_x(lo, 0.0)
				j.set_param_x(hi, 0.0)
			1:
				j.set_param_y(lo, 0.0)
				j.set_param_y(hi, 0.0)
			_:
				j.set_param_z(lo, 0.0)
				j.set_param_z(hi, 0.0)

func joint6_linear_limit(j: Node, lim: float) -> void:
	for a in range(3):
		if int(joint_get(j, ["xMotion", "yMotion", "zMotion"][a], 2)) == 1:
			joint6_linear_limit_axis(j, a, lim)

func joint6_linear_limit_axis(j: Generic6DOFJoint3D, axis: int, lim: float) -> void:
	var lo := Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT
	var hi := Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT
	match axis:
		0:
			j.set_param_x(lo, -lim)
			j.set_param_x(hi, lim)
		1:
			j.set_param_y(lo, -lim)
			j.set_param_y(hi, lim)
		_:
			j.set_param_z(lo, -lim)
			j.set_param_z(hi, lim)

var _generic_props: Dictionary = {}

func _gp_get(n, key: String, default):
	if not (n is Object):
		return default
	return _generic_props.get(n.get_instance_id(), {}).get(key, default)

func _gp_set(n, key: String, value) -> void:
	if not (n is Object):
		return
	var id: int = n.get_instance_id()
	if not _generic_props.has(id):
		_generic_props[id] = {}
	_generic_props[id][key] = value

func reverb_get(n, key: String, default):
	return _gp_get(n, key, default)

func reverb_set(n, key: String, value) -> void:
	_gp_set(n, key, value)

func dolly_get(n, key: String, default):
	return _gp_get(n, key, default)

func dolly_set(n, key: String, value) -> void:
	_gp_set(n, key, value)
	if n is PathFollow3D and key == "time":
		n.progress = float(value)

func physbone_get(n, key: String, default):
	return _gp_get(n, key, default)

func physbone_set(n, key: String, value) -> void:
	_gp_set(n, key, value)

func cine_get(n, key: String, default):
	return _gp_get(n, key, default)

func cine_set(n, key: String, value) -> void:
	_gp_set(n, key, value)
	if n is Camera3D and key == "priority" and int(value) > 100:
		n.make_current()

func layout_get(n, key: String, default):
	return _gp_get(n, key, default)

func layout_set(n, key: String, value) -> void:
	_gp_set(n, key, value)

func video_get(n, key: String, default):
	return _gp_get(n, key, default)

func video_set_url(n, url: String) -> void:
	_gp_set(n, "url", url)
	if n is VideoStreamPlayer and url.begins_with("res://"):
		n.stream = load(url)

func path_position(p: Path3D, offset: float) -> Vector3:
	if p.curve == null:
		return get_position(p)
	return from_gd_v(p.to_global(p.curve.sample_baked(offset, true)))

func path_tangent(p: Path3D, offset: float) -> Vector3:
	if p.curve == null:
		return forward(p)
	var a: Vector3 = p.curve.sample_baked(offset, true)
	var b: Vector3 = p.curve.sample_baked(offset + 0.01, true)
	return from_gd_v(p.global_transform.basis * (b - a).normalized())

func path_orientation(p: Path3D, offset: float) -> Quaternion:
	return look_rotation(path_tangent(p, offset), Vector3.UP)

func dropdown_options(o: OptionButton) -> Array:
	var out: Array = []
	for i in range(o.item_count):
		out.append({"text": o.get_item_text(i), "image": o.get_item_icon(i)})
	return out

func dropdown_set_options(o: OptionButton, opts: Array) -> void:
	o.clear()
	dropdown_add_options(o, opts)

func dropdown_add_options(o: OptionButton, opts: Array) -> void:
	for it in opts:
		if it is Dictionary:
			o.add_item(str(it.get("text", "")))
		else:
			o.add_item(str(it))

func anim_parameters(n: Node) -> Array:
	var out: Array = []
	for k in _params(n).keys():
		var v = _params(n)[k]
		var t: int = 1 if typeof(v) == TYPE_FLOAT else (3 if typeof(v) == TYPE_INT else (4 if typeof(v) == TYPE_BOOL else 9))
		out.append({"name": k, "type": t, "value": v})
	return out

func animation_state(p: AnimationPlayer, name_: String) -> Dictionary:
	var a := p.get_animation(name_) if p.has_animation(name_) else null
	return {"name": name_, "enabled": p.current_animation == name_, "weight": 1.0, "time": p.current_animation_position if p.current_animation == name_ else 0.0, "normalizedTime": 0.0, "speed": p.speed_scale, "length": a.length if a != null else 0.0, "clip": a}

func animation_add_clip(p: AnimationPlayer, clip: Animation, name_: String) -> void:
	var lib: AnimationLibrary = p.get_animation_library("") if p.has_animation_library("") else null
	if lib == null:
		lib = AnimationLibrary.new()
		p.add_animation_library("", lib)
	lib.add_animation(name_, clip)

func animation_remove_clip(p: AnimationPlayer, name_: String) -> void:
	if p.has_animation_library("") and p.get_animation_library("").has_animation(name_):
		p.get_animation_library("").remove_animation(name_)

func terrain_sample_height(n: Node, p: Vector3) -> float:
	var hit := raycast(Vector3(p.x, 10000.0, p.z), Vector3.DOWN, 20000.0, -1, 1)
	return hit.get("position", Vector3.ZERO).y if not hit.is_empty() else 0.0

func line_add_position(n: Node, p: Vector3) -> void:
	_line(n)["positions"].append(p)
	_line_redraw(n)

func line_add_positions(n: Node, pts: Array) -> void:
	_line(n)["positions"].append_array(pts)
	_line_redraw(n)

func line_gradient(n: Node) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, line_get_prop(n, "startColor", Color.WHITE))
	g.set_color(1, line_get_prop(n, "endColor", Color.WHITE))
	return g

func gpu_readback(tex, _mip: int, receiver) -> Dictionary:
	var img: Image = tex.get_image() if tex is Texture2D else null
	var d := {"done": true, "hasError": img == null, "width": img.get_width() if img != null else 0, "height": img.get_height() if img != null else 0, "data": img.get_data() if img != null else PackedByteArray(), "image": img}
	if receiver != null and receiver.has_method("OnAsyncGpuReadbackComplete"):
		receiver.call_deferred("OnAsyncGpuReadbackComplete", d)
	return d

func gpu_readback_copy(req: Dictionary, into: Array) -> bool:
	var data: PackedByteArray = req.get("data", PackedByteArray())
	var n: int = mini(data.size(), into.size())
	for i in range(n):
		into[i] = data[i]
	return not req.get("hasError", true)

func gpu_readback_copy_colors(req: Dictionary, into: Array) -> bool:
	var img: Image = req.get("image")
	if img == null:
		return false
	var i: int = 0
	for y in range(img.get_height() - 1, -1, -1):
		for x in range(img.get_width()):
			if i >= into.size():
				return true
			into[i] = img.get_pixel(x, y)
			i += 1
	return true

func gpu_readback_copy_floats(req: Dictionary, into: Array) -> bool:
	var img: Image = req.get("image")
	if img == null:
		return false
	var i: int = 0
	for y in range(img.get_height() - 1, -1, -1):
		for x in range(img.get_width()):
			if i >= into.size():
				return true
			into[i] = img.get_pixel(x, y).r
			i += 1
	return true

# ---------------------------------------------------------------------------
# Unity UI extras: Selectable state, navigation, colour blocks, layout sizes, masks, text effects,
# TMP alignment/overflow, dropdown options, sprites, canvases. Values Godot cannot express are
# kept in node metadata (see prop_get/prop_set) so scripts round-trip them.
# ---------------------------------------------------------------------------

const _UI_NAV_DIRS: Dictionary = {"up": "focus_neighbor_top", "down": "focus_neighbor_bottom", "left": "focus_neighbor_left", "right": "focus_neighbor_right"}

## Selectable.FindSelectableOnUp/Down/Left/Right: the explicit focus neighbour, else null.
func ui_neighbor(n: Node, dir: String) -> Node:
	if not (n is Control):
		return null
	var path: NodePath = n.get(_UI_NAV_DIRS[dir])
	if path.is_empty():
		return null
	return n.get_node_or_null(path)

## Navigation struct {mode, selectOnUp, selectOnDown, selectOnLeft, selectOnRight, wrapAround}.
func ui_nav_get(n: Node) -> Dictionary:
	var d: Dictionary = {"mode": 3, "selectOnUp": null, "selectOnDown": null, "selectOnLeft": null, "selectOnRight": null, "wrapAround": false}
	if n is Control:
		d["mode"] = 0 if n.focus_mode == Control.FOCUS_NONE else 3
		var explicit := false
		for k in _UI_NAV_DIRS:
			var nb := ui_neighbor(n, k)
			d["selectOn" + k.capitalize()] = nb
			if nb != null:
				explicit = true
		if explicit:
			d["mode"] = 4
	if n != null and n.has_meta("udon_navigation"):
		var stored: Dictionary = n.get_meta("udon_navigation")
		for k in stored:
			d[k] = stored[k]
	return d

func ui_nav_set(n: Node, d: Dictionary) -> void:
	if n == null:
		return
	n.set_meta("udon_navigation", {"mode": int(d.get("mode", 3)), "wrapAround": bool(d.get("wrapAround", false))})
	if not (n is Control):
		return
	n.focus_mode = Control.FOCUS_NONE if int(d.get("mode", 3)) == 0 else Control.FOCUS_ALL
	for k in _UI_NAV_DIRS:
		var target = d.get("selectOn" + k.capitalize())
		if target is Node:
			n.set(_UI_NAV_DIRS[k], n.get_path_to(target))
		elif target == null and int(d.get("mode", 3)) == 4:
			n.set(_UI_NAV_DIRS[k], NodePath())

const _UI_DEFAULT_COLORS: Dictionary = {"normalColor": Color(1, 1, 1, 1), "highlightedColor": Color(0.9607843, 0.9607843, 0.9607843, 1), "pressedColor": Color(0.78431374, 0.78431374, 0.78431374, 1), "selectedColor": Color(0.9607843, 0.9607843, 0.9607843, 1), "disabledColor": Color(0.78431374, 0.78431374, 0.78431374, 0.5019608), "colorMultiplier": 1.0, "fadeDuration": 0.1}

func ui_default_colors() -> Dictionary:
	return _UI_DEFAULT_COLORS.duplicate()

## ColorBlock: stored per node; the normal colour tints the Control (modulate).
func ui_colors_get(n: Node) -> Dictionary:
	if n != null and n.has_meta("udon_colors"):
		return (n.get_meta("udon_colors") as Dictionary).duplicate()
	return ui_default_colors()

func ui_colors_set(n: Node, d: Dictionary) -> void:
	if n == null:
		return
	var merged: Dictionary = ui_colors_get(n)
	for k in d:
		merged[k] = d[k]
	n.set_meta("udon_colors", merged)
	if n is CanvasItem:
		var c: Color = merged.get("normalColor", Color.WHITE)
		n.self_modulate = Color(c.r, c.g, c.b, c.a) * float(merged.get("colorMultiplier", 1.0))
		n.self_modulate.a = c.a

## SpriteState {highlightedSprite, pressedSprite, selectedSprite, disabledSprite}: applied to
## TextureButtons, stored for everything else.
func ui_sprite_state_get(n: Node) -> Dictionary:
	var d: Dictionary = {"highlightedSprite": null, "pressedSprite": null, "selectedSprite": null, "disabledSprite": null}
	if n is TextureButton:
		d["highlightedSprite"] = n.texture_hover
		d["pressedSprite"] = n.texture_pressed
		d["disabledSprite"] = n.texture_disabled
		d["selectedSprite"] = n.texture_focused
	if n != null and n.has_meta("udon_sprite_state"):
		for k in n.get_meta("udon_sprite_state"):
			d[k] = n.get_meta("udon_sprite_state")[k]
	return d

func ui_sprite_state_set(n: Node, d: Dictionary) -> void:
	if n == null:
		return
	n.set_meta("udon_sprite_state", d.duplicate())
	if n is TextureButton:
		n.texture_hover = d.get("highlightedSprite")
		n.texture_pressed = d.get("pressedSprite")
		n.texture_disabled = d.get("disabledSprite")
		n.texture_focused = d.get("selectedSprite")

## LayoutElement.flexibleWidth/Height: size flags expand + stretch ratio.
func ui_flexible_get(n: Node, axis: String) -> float:
	if not (n is Control):
		return 0.0
	var flags: int = n.size_flags_horizontal if axis == "x" else n.size_flags_vertical
	return n.size_flags_stretch_ratio if flags & Control.SIZE_EXPAND else 0.0

func ui_flexible_set(n: Node, axis: String, v: float) -> void:
	if not (n is Control):
		return
	var flags: int = Control.SIZE_EXPAND_FILL if v > 0.0 else Control.SIZE_FILL
	if axis == "x":
		n.size_flags_horizontal = flags
	else:
		n.size_flags_vertical = flags
	if v > 0.0:
		n.size_flags_stretch_ratio = v

func ui_min_size(n: Node, axis: String) -> float:
	if not (n is Control):
		return 0.0
	var s: Vector2 = n.get_combined_minimum_size()
	return s.x if axis == "x" else s.y

func ui_preferred_size(n: Node, axis: String) -> float:
	if not (n is Control):
		return 0.0
	var s: Vector2 = n.get_combined_minimum_size()
	if n.custom_minimum_size == Vector2.ZERO:
		s = s.max(n.size)
	return s.x if axis == "x" else s.y

## The Canvas a UI node belongs to: the world-canvas container (`udon_canvas` metadata) or the
## nearest CanvasLayer / SubViewport ancestor.
func ui_canvas(n: Node) -> Node:
	var cur: Node = n
	while cur != null:
		if cur.has_meta("udon_canvas") or cur is CanvasLayer:
			return cur
		if cur is SubViewport and cur.get_parent() != null and cur.get_parent().has_meta("udon_canvas"):
			return cur.get_parent()
		cur = cur.get_parent()
	return null

func ui_canvas_get(n: Node, key: String, default = null):
	var c := ui_canvas(n)
	if c == null:
		return default
	var cfg: Dictionary = c.get_meta("udon_canvas") if c.has_meta("udon_canvas") else {}
	match key:
		"pixelRect", "renderingDisplaySize":
			var size: Vector2 = cfg.get("size", Vector2.ZERO)
			if size == Vector2.ZERO and c is CanvasLayer:
				size = c.get_viewport().get_visible_rect().size
			return Rect2(Vector2.ZERO, size) if key == "pixelRect" else size
		"isRootCanvas":
			return ui_canvas(c.get_parent()) == null
		"rootCanvas":
			var root: Node = c
			while ui_canvas(root.get_parent()) != null:
				root = ui_canvas(root.get_parent())
			return root
		"referencePixelsPerUnit":
			return float(cfg.get("k", 100.0))
		"renderMode":
			return {"overlay": 0, "camera": 1, "world": 2}.get(str(cfg.get("mode", "world")), 2)
		"scaleFactor":
			return c.scale.x if c is CanvasLayer else 1.0
	return prop_get(c, key, default)

func ui_canvas_set(n: Node, key: String, value) -> void:
	var c := ui_canvas(n)
	if c == null:
		return
	if key == "scaleFactor" and c is CanvasLayer:
		c.scale = Vector2(float(value), float(value))
	prop_set(c, key, value)

## Image.SetNativeSize: the Control takes its texture's size.
func ui_set_native_size(n: Node) -> void:
	if n is TextureRect and n.texture != null:
		n.custom_minimum_size = n.texture.get_size()
		n.size = n.texture.get_size()

func ui_texture_size(n: Node, axis: String) -> float:
	var t: Texture2D = null
	if n is TextureRect:
		t = n.texture
	elif n is Control:
		t = ui_get_texture(n)
	if t == null:
		return ui_min_size(n, axis)
	return t.get_width() if axis == "x" else t.get_height()

## Outline/Shadow effects: theme overrides on text controls.
func ui_effect_get(n: Node, kind: String, key: String, default = null):
	if n == null:
		return default
	var d: Dictionary = n.get_meta("udon_effect_" + kind) if n.has_meta("udon_effect_" + kind) else {}
	if d.has(key):
		return d[key]
	if n is Control:
		match [kind, key]:
			["outline", "effectColor"]:
				return n.get_theme_color("font_outline_color")
			["outline", "effectDistance"]:
				return Vector2.ONE * float(n.get_theme_constant("outline_size"))
			["shadow", "effectColor"]:
				return n.get_theme_color("font_shadow_color")
			["shadow", "effectDistance"]:
				return Vector2(n.get_theme_constant("shadow_offset_x"), -n.get_theme_constant("shadow_offset_y"))
	return default

func ui_effect_set(n: Node, kind: String, key: String, value) -> void:
	if n == null:
		return
	var d: Dictionary = n.get_meta("udon_effect_" + kind) if n.has_meta("udon_effect_" + kind) else {}
	d[key] = value
	n.set_meta("udon_effect_" + kind, d)
	if not (n is Control):
		return
	var enabled: bool = bool(d.get("enabled", true))
	match kind:
		"outline":
			if d.has("effectColor"):
				n.add_theme_color_override("font_outline_color", d["effectColor"])
			var dist: Vector2 = d.get("effectDistance", Vector2.ONE)
			n.add_theme_constant_override("outline_size", int(round(maxf(absf(dist.x), absf(dist.y)))) if enabled else 0)
		"shadow":
			if d.has("effectColor"):
				n.add_theme_color_override("font_shadow_color", d["effectColor"] if enabled else Color(0, 0, 0, 0))
			var dist2: Vector2 = d.get("effectDistance", Vector2(1, -1))
			n.add_theme_constant_override("shadow_offset_x", int(round(dist2.x)))
			n.add_theme_constant_override("shadow_offset_y", int(round(-dist2.y)))

## AspectRatioFitter: {aspectMode, aspectRatio}; modes 1/2 resize the Control, 3/4 fit the parent.
func ui_aspect_set(n: Node, key: String, value) -> void:
	prop_set(n, key, value)
	if not (n is Control):
		return
	var mode: int = int(prop_get(n, "aspectMode", 0))
	var ratio: float = maxf(float(prop_get(n, "aspectRatio", 1.0)), 0.001)
	match mode:
		1:
			n.size = Vector2(n.size.x, n.size.x / ratio)
		2:
			n.size = Vector2(n.size.y * ratio, n.size.y)
		3, 4:
			var parent := n.get_parent() as Control
			if parent != null:
				var ps: Vector2 = parent.size
				var w: float = ps.x
				var h: float = w / ratio
				if (h > ps.y) == (mode == 3):
					h = ps.y
					w = h * ratio
				n.size = Vector2(w, h)
				n.position = (ps - n.size) * 0.5

## Dropdown options as OptionData dictionaries {text, image}.
func dd_options(n: Node) -> Array:
	var out: Array = []
	if n is OptionButton:
		for i in range(n.item_count):
			out.append({"text": n.get_item_text(i), "image": n.get_item_icon(i)})
	return out

func dd_set_options(n: Node, options: Array) -> void:
	if not (n is OptionButton):
		return
	n.clear()
	dd_add_options(n, options)

func dd_add_options(n: Node, options: Array) -> void:
	if not (n is OptionButton):
		return
	for o in options:
		if o is Dictionary:
			n.add_item(str(o.get("text", "")))
			if o.get("image") is Texture2D:
				n.set_item_icon(n.item_count - 1, o["image"])
		elif o is Texture2D:
			n.add_icon_item(o, "")
		else:
			n.add_item(str(o))

func dd_option_text(n: Node, i: int) -> String:
	if n is OptionButton and i >= 0 and i < n.item_count:
		return n.get_item_text(i)
	return ""

func toggle_get_group(n: Node) -> ButtonGroup:
	return n.button_group if n is BaseButton else null

func toggle_set_group(n: Node, g) -> void:
	if n is BaseButton:
		n.button_group = g if g is ButtonGroup else null

func toggle_group_active(g) -> Array:
	var out: Array = []
	if g is ButtonGroup:
		for b in g.get_buttons():
			if b.button_pressed:
				out.append(b)
	return out

func toggle_group_first(g) -> Node:
	return g.get_pressed_button() if g is ButtonGroup else null

# TMP alignment ↔ Godot (HorizontalAlignmentOptions: Left 1, Center 2, Right 4, Justified 8; VerticalAlignmentOptions: Top 256, Middle 512, Bottom 1024)
func ui_halign_get(n: Node) -> int:
	if n is Label:
		return {HORIZONTAL_ALIGNMENT_LEFT: 1, HORIZONTAL_ALIGNMENT_CENTER: 2, HORIZONTAL_ALIGNMENT_RIGHT: 4, HORIZONTAL_ALIGNMENT_FILL: 8}.get(n.horizontal_alignment, 1)
	if n is LineEdit:
		return {HORIZONTAL_ALIGNMENT_LEFT: 1, HORIZONTAL_ALIGNMENT_CENTER: 2, HORIZONTAL_ALIGNMENT_RIGHT: 4, HORIZONTAL_ALIGNMENT_FILL: 8}.get(n.alignment, 1)
	return int(prop_get(n, "horizontalAlignment", 1))

func ui_halign_set(n: Node, v: int) -> void:
	prop_set(n, "horizontalAlignment", v)
	var ga: int = {1: HORIZONTAL_ALIGNMENT_LEFT, 2: HORIZONTAL_ALIGNMENT_CENTER, 4: HORIZONTAL_ALIGNMENT_RIGHT, 8: HORIZONTAL_ALIGNMENT_FILL, 16: HORIZONTAL_ALIGNMENT_FILL, 32: HORIZONTAL_ALIGNMENT_CENTER}.get(v, HORIZONTAL_ALIGNMENT_LEFT)
	if n is Label:
		n.horizontal_alignment = ga
	elif n is LineEdit:
		n.alignment = ga
	elif n is Button:
		n.alignment = ga

func ui_valign_get(n: Node) -> int:
	if n is Label:
		return {VERTICAL_ALIGNMENT_TOP: 256, VERTICAL_ALIGNMENT_CENTER: 512, VERTICAL_ALIGNMENT_BOTTOM: 1024}.get(n.vertical_alignment, 256)
	return int(prop_get(n, "verticalAlignment", 256))

func ui_valign_set(n: Node, v: int) -> void:
	prop_set(n, "verticalAlignment", v)
	if n is Label:
		n.vertical_alignment = {256: VERTICAL_ALIGNMENT_TOP, 512: VERTICAL_ALIGNMENT_CENTER, 1024: VERTICAL_ALIGNMENT_BOTTOM, 2048: VERTICAL_ALIGNMENT_BOTTOM, 4096: VERTICAL_ALIGNMENT_CENTER, 8192: VERTICAL_ALIGNMENT_TOP}.get(v, VERTICAL_ALIGNMENT_TOP)

## TextAlignmentOptions = horizontal | vertical
func ui_alignment_get(n: Node) -> int:
	return ui_halign_get(n) | ui_valign_get(n)

func ui_alignment_set(n: Node, v: int) -> void:
	ui_halign_set(n, v & 0xFF)
	ui_valign_set(n, v & 0xFF00)

## TextOverflowModes: Overflow 0, Ellipsis 1, Masking 2, Truncate 3, ScrollRect 4, Page 5, Linked 6
func ui_overflow_get(n: Node) -> int:
	if n is Label:
		match n.text_overrun_behavior:
			TextServer.OVERRUN_TRIM_ELLIPSIS, TextServer.OVERRUN_TRIM_WORD_ELLIPSIS:
				return 1
			TextServer.OVERRUN_TRIM_CHAR, TextServer.OVERRUN_TRIM_WORD:
				return 3
		return 2 if n.clip_text else 0
	return int(prop_get(n, "overflowMode", 0))

func ui_overflow_set(n: Node, v: int) -> void:
	prop_set(n, "overflowMode", v)
	if n is Label:
		match v:
			1:
				n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				n.clip_text = true
			3:
				n.text_overrun_behavior = TextServer.OVERRUN_TRIM_CHAR
				n.clip_text = true
			2, 4, 5:
				n.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
				n.clip_text = true
			_:
				n.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
				n.clip_text = false
	elif n is Control:
		n.clip_contents = v != 0

func ui_max_lines_get(n: Node) -> int:
	if n is Label:
		return n.max_lines_visible
	return int(prop_get(n, "maxVisibleLines", 99999))

func ui_max_lines_set(n: Node, v: int) -> void:
	prop_set(n, "maxVisibleLines", v)
	if n is Label:
		n.max_lines_visible = v if v < 99999 else -1

func ui_rtl_get(n: Node) -> bool:
	if n is Control:
		return n.get("text_direction") == Control.TEXT_DIRECTION_RTL
	return false

func ui_rtl_set(n: Node, v: bool) -> void:
	if n is Label or n is RichTextLabel or n is LineEdit:
		n.text_direction = Control.TEXT_DIRECTION_RTL if v else Control.TEXT_DIRECTION_AUTO

func ui_wrap_get(n: Node) -> bool:
	if n is Label:
		return n.autowrap_mode != TextServer.AUTOWRAP_OFF
	if n is RichTextLabel:
		return n.autowrap_mode != TextServer.AUTOWRAP_OFF
	return bool(prop_get(n, "enableWordWrapping", true))

func ui_wrap_set(n: Node, v: bool) -> void:
	prop_set(n, "enableWordWrapping", v)
	if n is Label or n is RichTextLabel:
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if v else TextServer.AUTOWRAP_OFF

func ui_line_spacing_get(n: Node) -> float:
	if n is Control:
		return float(n.get_theme_constant("line_spacing"))
	return 0.0

func ui_line_spacing_set(n: Node, v: float) -> void:
	if n is Control:
		n.add_theme_constant_override("line_spacing", int(round(v)))

func ui_alpha_get(n: Node) -> float:
	return n.modulate.a if n is CanvasItem else 1.0

func ui_alpha_set(n: Node, v: float) -> void:
	if n is CanvasItem:
		n.modulate.a = clampf(v, 0.0, 1.0)

## Graphic.Raycast: is the point (viewport pixels) over the control
func ui_raycast(n: Node, p: Vector2) -> bool:
	return n is Control and n.is_visible_in_tree() and n.get_global_rect().has_point(p)

func ui_depth(n: Node) -> int:
	return n.get_index() if n != null and n.get_parent() != null else -1

func ui_rect(n: Node) -> Rect2:
	return n.get_rect() if n is Control else Rect2()

# --- sprites: a Sprite is a Texture2D; sub-rectangles are AtlasTextures ---------------------------

func sprite_rect(t: Texture2D) -> Rect2:
	if t is AtlasTexture:
		return t.region
	if t != null:
		return Rect2(Vector2.ZERO, t.get_size())
	return Rect2()

func sprite_pivot(t: Texture2D) -> Vector2:
	if t != null and t.has_meta("udon_pivot"):
		return t.get_meta("udon_pivot")
	return sprite_rect(t).size * 0.5

func sprite_ppu(t: Texture2D) -> float:
	if t != null and t.has_meta("udon_ppu"):
		return float(t.get_meta("udon_ppu"))
	return 100.0

func sprite_bounds(t: Texture2D) -> AABB:
	var r := sprite_rect(t)
	var ppu := sprite_ppu(t)
	var size := Vector3(r.size.x / ppu, r.size.y / ppu, 0.0)
	return AABB(-size * 0.5, size)

func sprite_create(tex: Texture2D, rect: Rect2, pivot: Vector2, ppu: float = 100.0) -> Texture2D:
	if tex == null:
		return null
	var at := AtlasTexture.new()
	at.atlas = tex
	# Unity rects are bottom-left based
	at.region = Rect2(rect.position.x, tex.get_height() - rect.position.y - rect.size.y, rect.size.x, rect.size.y)
	at.set_meta("udon_pivot", pivot * rect.size)
	at.set_meta("udon_ppu", ppu)
	return at

## Copy as many elements as fit (NonAlloc pattern); returns the number of source elements.
func fill_array(dst: Array, src: Array) -> int:
	var n: int = mini(dst.size(), src.size())
	for i in range(n):
		dst[i] = src[i]
	return src.size()

## Text.GetTextAnchorPivot: TextAnchor (0 UpperLeft … 8 LowerRight) → pivot
func text_anchor_pivot(anchor: int) -> Vector2:
	var x: float = [0.0, 0.5, 1.0][clampi(anchor % 3, 0, 2)]
	var y: float = [1.0, 0.5, 0.0][clampi(anchor / 3, 0, 2)]
	return Vector2(x, y)

func toggle_group_clear(g) -> void:
	if g is ButtonGroup:
		for b in g.get_buttons():
			b.set_pressed_no_signal(false)

## RectTransform.GetLocalCorners: bottom-left, top-left, top-right, bottom-right (Unity order)
func rect_local_corners(c: Control, out: Array) -> void:
	if not (c is Control) or out.size() < 4:
		return
	var s: Vector2 = c.size
	var p: Vector2 = rect_get_pivot(c) * s
	out[0] = Vector3(-p.x, -(s.y - p.y), 0.0)
	out[1] = Vector3(-p.x, p.y, 0.0)
	out[2] = Vector3(s.x - p.x, p.y, 0.0)
	out[3] = Vector3(s.x - p.x, -(s.y - p.y), 0.0)

func rect_set_anchored_position(c: Control, v: Vector2) -> void:
	if c is Control:
		c.position = v

# ---------------------------------------------------------------------------
# System extras: TimeSpan parsing, Guid, BitConverter widths, dates, vectors, rects, matrices
# ---------------------------------------------------------------------------

## TimeSpan.Parse: "[-][d.]hh:mm[:ss[.fff]]"; {"total_seconds", "ok"} — ok=false when malformed.
func timespan_parse(text: String) -> Dictionary:
	var t := text.strip_edges()
	var neg := t.begins_with("-")
	if neg:
		t = t.substr(1)
	var days: float = 0.0
	if t.contains(".") and t.find(".") < t.find(":"):
		days = float(t.get_slice(".", 0))
		t = t.substr(t.find(".") + 1)
	var parts := t.split(":")
	if parts.size() < 2 or parts.size() > 3:
		return {"total_seconds": 0.0, "ok": false}
	for p in parts:
		if p == "" or not p.replace(".", "").is_valid_int():
			return {"total_seconds": 0.0, "ok": false}
	var s: float = days * 86400.0 + float(parts[0]) * 3600.0 + float(parts[1]) * 60.0
	if parts.size() == 3:
		s += float(parts[2])
	return {"total_seconds": -s if neg else s, "ok": true}

# --- Guid: canonical lowercase "8-4-4-4-12" strings -----------------------------------------------

func guid_parse(text: String) -> String:
	var t := text.strip_edges().to_lower().trim_prefix("{").trim_suffix("}").trim_prefix("(").trim_suffix(")")
	var hex := t.replace("-", "")
	if hex.length() != 32 or not hex.is_valid_hex_number(false):
		return ""
	return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-" + hex.substr(12, 4) + "-" + hex.substr(16, 4) + "-" + hex.substr(20, 12)

func guid_format(g: String, fmt: String) -> String:
	match fmt.to_upper():
		"N":
			return g.replace("-", "")
		"B":
			return "{" + g + "}"
		"P":
			return "(" + g + ")"
	return g

## Guid.ToByteArray: .NET's mixed-endian layout (first three groups little-endian).
func guid_to_bytes(g: String) -> Array:
	var hex := g.replace("-", "")
	var raw: PackedByteArray = hex.hex_decode()
	if raw.size() != 16:
		return []
	var out: Array = []
	for i in [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]:
		out.append(raw[i])
	return out

func guid_from_bytes(bytes: Array) -> String:
	if bytes.size() < 16:
		return ""
	var raw := PackedByteArray()
	for i in [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]:
		raw.append(int(bytes[i]) & 255)
	return guid_parse(raw.hex_encode())

func guid_from_parts(a: int, b: int, c: int, d: Array) -> String:
	var raw := PackedByteArray()
	raw.resize(16)
	raw.encode_u32(0, a & 0xFFFFFFFF)
	raw.encode_u16(4, b & 0xFFFF)
	raw.encode_u16(6, c & 0xFFFF)
	for i in range(8):
		raw[8 + i] = int(d[i]) & 255 if i < d.size() else 0
	# the encoders wrote little-endian; the canonical string shows the groups big-endian
	var swapped := PackedByteArray([raw[3], raw[2], raw[1], raw[0], raw[5], raw[4], raw[7], raw[6]])
	swapped.append_array(raw.slice(8))
	return guid_parse(swapped.hex_encode())

# --- BitConverter widths ---------------------------------------------------------------------------

func int16_to_bytes(v: int) -> Array:
	var p := PackedByteArray()
	p.resize(2)
	p.encode_s16(0, v)
	return Array(p)

func int64_to_bytes(v: int) -> Array:
	var p := PackedByteArray()
	p.resize(8)
	p.encode_s64(0, v)
	return Array(p)

func double_to_bytes(v: float) -> Array:
	var p := PackedByteArray()
	p.resize(8)
	p.encode_double(0, v)
	return Array(p)

func _bytes_packed(bytes: Array, offset: int, n: int) -> PackedByteArray:
	var p := PackedByteArray()
	for i in range(n):
		p.append(int(bytes[offset + i]) & 255 if offset + i < bytes.size() else 0)
	return p

func bytes_to_int16(bytes: Array, offset: int) -> int:
	return _bytes_packed(bytes, offset, 2).decode_s16(0)

func bytes_to_int64(bytes: Array, offset: int) -> int:
	return _bytes_packed(bytes, offset, 8).decode_s64(0)

func bytes_to_double(bytes: Array, offset: int) -> float:
	return _bytes_packed(bytes, offset, 8).decode_double(0)

func double_to_bits(v: float) -> int:
	var p := PackedByteArray()
	p.resize(8)
	p.encode_double(0, v)
	return p.decode_s64(0)

func bits_to_double(v: int) -> float:
	var p := PackedByteArray()
	p.resize(8)
	p.encode_s64(0, v)
	return p.decode_double(0)

## Convert.ToBase64CharArray: writes the base64 text into `out` at `out_index`, returns its length.
func base64_chars(bytes: Array, offset: int, length: int, out: Array, out_index: int) -> int:
	var p := _bytes_packed(bytes, offset, length)
	var text := Marshalls.raw_to_base64(p)
	for i in range(text.length()):
		if out_index + i < out.size():
			out[out_index + i] = text[i]
	return text.length()

func chars_to_string(chars: Array) -> String:
	var s := ""
	for c in chars:
		s += str(c)
	return s

## Convert.ToDateTime(object): strings are parsed, DateTime dictionaries pass through.
func to_datetime(v) -> Dictionary:
	if v is Dictionary:
		return v
	if v is String:
		return datetime_parse(v)
	return datetime_from_unix(0.0)

## DateTime.AddMonths / AddYears with day clamping (.NET semantics).
func datetime_add_months(d: Dictionary, months: int) -> Dictionary:
	var y: int = int(d.get("year", 1970))
	var m: int = int(d.get("month", 1)) - 1 + months
	y += int(floor(float(m) / 12.0))
	m = posmod(m, 12) + 1
	var day: int = mini(int(d.get("day", 1)), days_in_month(y, m))
	var out := datetime_from_parts(y, m, day, int(d.get("hour", 0)), int(d.get("minute", 0)), int(d.get("second", 0)))
	return out

func random_bytes(out: Array) -> void:
	for i in range(out.size()):
		out[i] = randi_range(0, 255)

func sb_char_at(sb, i: int) -> String:
	var s: String = str(sb)
	return s[i] if i >= 0 and i < s.length() else ""

# --- math structs ---------------------------------------------------------------------------------

func v4_move_towards(a: Vector4, b: Vector4, max_delta: float) -> Vector4:
	var d := b - a
	var len := d.length()
	if len <= max_delta or len < 0.000001:
		return b
	return a + d / len * max_delta

func v4_project(a: Vector4, on: Vector4) -> Vector4:
	var sq := on.length_squared()
	if sq < 0.000001:
		return Vector4.ZERO
	return on * (a.dot(on) / sq)

## Bounds.IntersectRay(ray, out distance): distance along the ray to the box, or -1.
func aabb_ray_distance(b: AABB, origin: Vector3, dir: Vector3) -> float:
	var hit = b.intersects_ray(origin, dir)
	if hit == null:
		return -1.0
	return origin.distance_to(hit)

## Mathf.CorrelatedColorTemperatureToRGB (Kelvin → linear RGB, Tanner Helland's fit).
func color_temperature(kelvin: float) -> Color:
	var t: float = clampf(kelvin, 1000.0, 40000.0) / 100.0
	var r: float
	var g: float
	var b: float
	if t <= 66.0:
		r = 255.0
		g = 99.4708025861 * log(t) - 161.1195681661
		b = 0.0 if t <= 19.0 else 138.5177312231 * log(t - 10.0) - 305.0447927307
	else:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
		b = 255.0
	return Color(clampf(r / 255.0, 0.0, 1.0), clampf(g / 255.0, 0.0, 1.0), clampf(b / 255.0, 0.0, 1.0), 1.0).srgb_to_linear()

func float_to_half(v: float) -> int:
	var p := PackedByteArray()
	p.resize(2)
	p.encode_half(0, v)
	return p.decode_u16(0)

func half_to_float(bits: int) -> float:
	var p := PackedByteArray()
	p.resize(2)
	p.encode_u16(0, bits & 0xFFFF)
	return p.decode_half(0)

## Matrix4x4 element write (row, column) on the affine 3x4 part.
func matrix_set(t: Transform3D, row: int, col: int, v: float) -> Transform3D:
	if row > 2:
		return t
	if col == 3:
		t.origin[row] = v
		return t
	var b: Basis = t.basis
	match col:
		0:
			var c := b.x
			c[row] = v
			b.x = c
		1:
			var c := b.y
			c[row] = v
			b.y = c
		2:
			var c := b.z
			c[row] = v
			b.z = c
	t.basis = b
	return t

func rect_with_min(r: Rect2, v: Vector2) -> Rect2:
	return Rect2(v, r.end - v)

func rect_with_xmin(r: Rect2, x: float) -> Rect2:
	return Rect2(x, r.position.y, r.end.x - x, r.size.y)

func rect_with_ymin(r: Rect2, y: float) -> Rect2:
	return Rect2(r.position.x, y, r.size.x, r.end.y - y)


# ---------------------------------------------------------------------------
# Physics extras: layer overrides, accumulated forces, capsule direction, contacts, physic
# material combine modes, scene settings, 2D filters / capsules / ray intersections, ConstantForce2D
# ---------------------------------------------------------------------------

## The collision object a Collider/Rigidbody expression denotes, 3D or 2D.
func _phys_co(n: Node):
	var co = _collision_object(n)
	if co == null:
		co = _co2d(n)
	return co

## Unity 2022 layer overrides (includeLayers / excludeLayers on colliders and rigidbodies): kept
## in metadata and folded into the Godot collision mask (include sets bits, exclude clears them).
func layers_get(n: Node, key: String) -> int:
	var co = _phys_co(n)
	if co == null:
		return 0
	return int(co.get_meta("udon_" + key, 0))

func layers_set(n: Node, key: String, v: int) -> void:
	var co = _phys_co(n)
	if co == null:
		return
	if not co.has_meta("udon_base_mask"):
		co.set_meta("udon_base_mask", co.collision_mask)
	co.set_meta("udon_" + key, v)
	var base: int = int(co.get_meta("udon_base_mask"))
	var inc: int = int(co.get_meta("udon_includeLayers", 0)) & 0xFFFFFFFF
	var exc: int = int(co.get_meta("udon_excludeLayers", 0)) & 0xFFFFFFFF
	co.collision_mask = (base | inc) & ~exc & 0xFFFFFFFF

# --- Rigidbody.GetAccumulatedForce / GetAccumulatedTorque: forces applied this physics step -----

var _rb_accum: Dictionary = {}  # instance id → [physics frame, force (Godot), torque (Godot)]

func _rb_track(rb: RigidBody3D, force: Vector3, torque: Vector3) -> void:
	var frame: int = Engine.get_physics_frames()
	var id: int = rb.get_instance_id()
	var rec: Array = _rb_accum.get(id, [frame, Vector3.ZERO, Vector3.ZERO])
	if rec[0] != frame:
		rec = [frame, Vector3.ZERO, Vector3.ZERO]
	rec[1] += force
	rec[2] += torque
	_rb_accum[id] = rec

## ForceMode → force-equivalent for the accumulator (impulses count as impulse / fixed step).
func _rb_force_equiv(rb: RigidBody3D, f: Vector3, mode: int) -> Vector3:
	match mode:
		1:
			return f / fixed_delta_time()
		2:
			return f * rb.mass / fixed_delta_time()
		5:
			return f * rb.mass
	return f

func rb_accumulated_force(rb: RigidBody3D) -> Vector3:
	var rec: Array = _rb_accum.get(rb.get_instance_id(), [])
	var f: Vector3 = rb.constant_force
	if not rec.is_empty() and rec[0] == Engine.get_physics_frames():
		f += rec[1]
	return from_gd_v(f)

func rb_accumulated_torque(rb: RigidBody3D) -> Vector3:
	var rec: Array = _rb_accum.get(rb.get_instance_id(), [])
	var t: Vector3 = rb.constant_torque
	if not rec.is_empty() and rec[0] == Engine.get_physics_frames():
		t += rec[2]
	return from_gd_axial(t)

## Rigidbody.automaticInertiaTensor: Godot computes the tensor whenever `inertia` is zero.
func rb_set_auto_inertia(rb: RigidBody3D, v: bool) -> void:
	if v:
		rb.inertia = Vector3.ZERO

# --- CapsuleCollider.direction (0 = X, 1 = Y, 2 = Z): the CollisionShape3D's orientation ------

func shape_get_direction(n: Node) -> int:
	var cs := shape_of(n)
	if cs == null:
		return 1
	var y: Vector3 = cs.transform.basis.y.abs()
	if y.x > 0.9:
		return 0
	if y.z > 0.9:
		return 2
	return 1

func shape_set_direction(n: Node, d: int) -> void:
	var cs := shape_of(n)
	if cs == null:
		return
	var b := Basis()
	match d:
		0:
			b = Basis(Vector3(0, 0, 1), -PI / 2.0)
		2:
			b = Basis(Vector3(1, 0, 0), PI / 2.0)
	cs.transform = Transform3D(b, cs.transform.origin)

## Collider.providesContacts ↔ RigidBody3D.contact_monitor (contacts for OnCollision* callbacks).
func collider_provides_contacts(n: Node) -> bool:
	var co = _collision_object(n)
	return co is RigidBody3D and co.contact_monitor

func collider_set_provides_contacts(n: Node, v: bool) -> void:
	var co = _collision_object(n)
	if co is RigidBody3D:
		co.contact_monitor = v
		if v:
			co.max_contacts_reported = maxi(co.max_contacts_reported, 8)

# --- PhysicMaterial combine modes: Average 0, Multiply 1, Minimum 2, Maximum 3 -----------------
# Godot expresses "rough" (max friction) and "absorbent" (min bounce); other modes are remembered.

func pm_combine_get(m: PhysicsMaterial, kind: String) -> int:
	if m == null:
		return 0
	if m.has_meta("udon_" + kind + "Combine"):
		return int(m.get_meta("udon_" + kind + "Combine"))
	if kind == "friction":
		return 3 if m.rough else 0
	return 2 if m.absorbent else 0

func pm_combine_set(m: PhysicsMaterial, kind: String, v: int) -> void:
	if m == null:
		return
	m.set_meta("udon_" + kind + "Combine", v)
	if kind == "friction":
		m.rough = v == 3
	else:
		m.absorbent = v == 2

# --- Physics / Physics2D settings ----------------------------------------------------------------

var _phys_settings: Dictionary = {}

## Settings Godot has no equivalent for: remembered so they round-trip.
func phys_get(key: String, default):
	return _phys_settings.get(key, default)

func phys_set(key: String, v) -> void:
	_phys_settings[key] = v

func _space2d_rid() -> RID:
	var w := get_viewport().world_2d if get_viewport() != null else null
	return w.space if w != null else RID()

## Live 2D space parameters (sleep thresholds, time to sleep, solver iterations).
const _SPACE2D_PARAMS: Dictionary = {"linear_sleep": PhysicsServer2D.SPACE_PARAM_BODY_LINEAR_VELOCITY_SLEEP_THRESHOLD, "angular_sleep": PhysicsServer2D.SPACE_PARAM_BODY_ANGULAR_VELOCITY_SLEEP_THRESHOLD, "time_to_sleep": PhysicsServer2D.SPACE_PARAM_BODY_TIME_TO_SLEEP, "solver_iterations": PhysicsServer2D.SPACE_PARAM_SOLVER_ITERATIONS, "contact_bias": PhysicsServer2D.SPACE_PARAM_CONTACT_DEFAULT_BIAS, "max_penetration": PhysicsServer2D.SPACE_PARAM_CONTACT_MAX_ALLOWED_PENETRATION}
const _SPACE3D_PARAMS: Dictionary = {"linear_sleep": PhysicsServer3D.SPACE_PARAM_BODY_LINEAR_VELOCITY_SLEEP_THRESHOLD, "angular_sleep": PhysicsServer3D.SPACE_PARAM_BODY_ANGULAR_VELOCITY_SLEEP_THRESHOLD, "time_to_sleep": PhysicsServer3D.SPACE_PARAM_BODY_TIME_TO_SLEEP, "solver_iterations": PhysicsServer3D.SPACE_PARAM_SOLVER_ITERATIONS, "contact_bias": PhysicsServer3D.SPACE_PARAM_CONTACT_DEFAULT_BIAS, "max_penetration": PhysicsServer3D.SPACE_PARAM_CONTACT_MAX_ALLOWED_PENETRATION}

func space2d_get(key: String, default: float) -> float:
	var rid := _space2d_rid()
	if not rid.is_valid() or not _SPACE2D_PARAMS.has(key):
		return default
	return float(PhysicsServer2D.space_get_param(rid, _SPACE2D_PARAMS[key]))

func space2d_set(key: String, v: float) -> void:
	var rid := _space2d_rid()
	if rid.is_valid() and _SPACE2D_PARAMS.has(key):
		PhysicsServer2D.space_set_param(rid, _SPACE2D_PARAMS[key], v)

func _space3d_rid() -> RID:
	var w := get_viewport().world_3d if get_viewport() != null else null
	return w.space if w != null else RID()

func space3d_get(key: String, default: float) -> float:
	var rid := _space3d_rid()
	if not rid.is_valid() or not _SPACE3D_PARAMS.has(key):
		return default
	return float(PhysicsServer3D.space_get_param(rid, _SPACE3D_PARAMS[key]))

func space3d_set(key: String, v: float) -> void:
	var rid := _space3d_rid()
	if rid.is_valid() and _SPACE3D_PARAMS.has(key):
		PhysicsServer3D.space_set_param(rid, _SPACE3D_PARAMS[key], v)

## ContactFilter2D depth of a GameObject: z-index for 2D nodes, z position for 3D ones.
func depth2d(n: Node) -> float:
	if n is Node2D:
		return float(n.z_index)
	if n is Node3D:
		return n.global_position.z
	return 0.0

# --- 2D queries: ContactFilter2D masks, capsule directions, 3D rays against the 2D plane --------

## The layer mask a ContactFilter2D applies (-1 = everything when the mask is not in use).
func filter2d_mask(f: Dictionary) -> int:
	return int(f.get("layerMask", -1)) if f.get("useLayerMask", false) else -1

## Unity capsules are (width, height) with CapsuleDirection2D; Godot capsules stand upright, so a
## horizontal capsule is the swapped size rotated by 90°.
func cap2d_size(size: Vector2, direction: int) -> Vector2:
	return Vector2(size.y, size.x) if direction == 1 else size

func cap2d_angle(angle: float, direction: int) -> float:
	return angle + 90.0 if direction == 1 else angle

## Physics2D.GetRayIntersection: a 3D ray hits the 2D colliders lying in the z = 0 plane.
func ray_intersection2d_all(ray: Dictionary, dist: float, mask: int) -> Array:
	var o: Vector3 = ray.get("origin", Vector3.ZERO)
	var d: Vector3 = ray.get("direction", Vector3.FORWARD)
	var max_d: float = dist if is_finite(dist) else 100000.0
	if absf(d.z) < 1e-6:
		return raycast2d_all(Vector2(o.x, o.y), Vector2(d.x, d.y), max_d, mask)
	var t: float = -o.z / d.z
	if t < 0.0 or t > max_d:
		return []
	var p: Vector3 = o + d * t
	var p2 := Vector2(p.x, p.y)
	var out: Array = []
	var n2 := Vector2(d.x, d.y)
	var normal: Vector2 = -n2.normalized() if n2.length_squared() > 1e-12 else Vector2.UP
	for c in overlap2d("point", p2, 0.0, Vector2.ZERO, 0.0, mask):
		out.append({"point": p2, "normal": normal, "distance": t, "fraction": t / max_d, "collider": c, "centroid": p2})
	return out

func ray_intersection2d(ray: Dictionary, dist: float, mask: int) -> Dictionary:
	var all: Array = ray_intersection2d_all(ray, dist, mask)
	return all[0] if not all.is_empty() else {}

func ray_intersection2d_into(ray: Dictionary, dist: float, mask: int, results: Array) -> int:
	return _fill_hits(ray_intersection2d_all(ray, dist, mask), results)

## ContactFilter2D depth / normal-angle tests against a candidate.
func filter2d_depth_ok(f: Dictionary, z: float) -> bool:
	if not f.get("useDepth", false):
		return true
	var inside: bool = z >= float(f.get("minDepth", -INF)) and z <= float(f.get("maxDepth", INF))
	return not inside if f.get("useOutsideDepth", false) else inside

func filter2d_angle_ok(f: Dictionary, angle: float) -> bool:
	if not f.get("useNormalAngle", false):
		return true
	var a: float = fposmod(angle, 360.0)
	var inside: bool = a >= float(f.get("minNormalAngle", 0.0)) and a <= float(f.get("maxNormalAngle", 359.9999))
	return not inside if f.get("useOutsideNormalAngle", false) else inside

## Collider2D.GetShapes(PhysicsShapeGroup2D): the collision shapes of the object, into a group.
func collider2d_shapes(n: Node, group: Dictionary) -> int:
	var co := _co2d(n)
	var shapes: Array = []
	if co != null:
		for c in co.get_children():
			if c is CollisionShape2D or c is CollisionPolygon2D:
				shapes.append(c)
	group["shapes"] = shapes
	return shapes.size()

## SliderJoint2D.limits ↔ GrooveJoint2D length / initial offset.
func slider2d_limits_get(j: GrooveJoint2D) -> Dictionary:
	return {"min": -j.initial_offset, "max": j.length - j.initial_offset}

func slider2d_limits_set(j: GrooveJoint2D, lim: Dictionary) -> void:
	var lo: float = float(lim.get("min", 0.0))
	var hi: float = float(lim.get("max", 0.0))
	j.length = maxf(hi - lo, 0.0)
	j.initial_offset = -lo

## ConstantForce2D.enabled: the force stays on the RigidBody2D; disabling parks it in metadata.
func cf2d_get_enabled(rb: RigidBody2D) -> bool:
	return not rb.has_meta("udon_cf_saved")

func cf2d_set_enabled(rb: RigidBody2D, v: bool) -> void:
	if v:
		if rb.has_meta("udon_cf_saved"):
			var saved: Array = rb.get_meta("udon_cf_saved")
			rb.constant_force = saved[0]
			rb.constant_torque = saved[1]
			rb.remove_meta("udon_cf_saved")
	elif not rb.has_meta("udon_cf_saved"):
		rb.set_meta("udon_cf_saved", [rb.constant_force, rb.constant_torque])
		rb.constant_force = Vector2.ZERO
		rb.constant_torque = 0.0

## WheelCollider.rotationSpeed (degrees per second) from the wheel's rpm.
func wheel_rotation_speed(w: VehicleWheel3D) -> float:
	return w.get_rpm() * 6.0

func instance_id_of(o) -> int:
	return o.get_instance_id() if o is Object else 0

# ---------------------------------------------------------------------------
# Rendering and assets: texture sampler state, cubemaps and 3D textures, mesh attributes and
# combining, renderer bounds, physical camera, frustum utilities, spherical harmonics, shadows
# ---------------------------------------------------------------------------

## Shader.PropertyToID ids resolve back to their names for material / property-block writes.
var _prop_names: Dictionary = {}

func shader_prop_id(s: String) -> int:
	var id: int = s.hash()
	_prop_names[id] = s
	return id

# --- textures -----------------------------------------------------------------------------------

## Unity TextureDimension: Tex2D 2, Tex3D 3, Cube 4, Tex2DArray 5, CubeArray 6.
func texture_dimension(t) -> int:
	if t is Texture3D:
		return 3
	if t is Cubemap:
		return 4
	if t is CubemapArray:
		return 6
	if t is Texture2DArray:
		return 5
	return 2 if t is Texture2D else 0

func texture_texel_size(t) -> Vector2:
	if t is Texture2D:
		return Vector2(1.0 / maxf(t.get_width(), 1.0), 1.0 / maxf(t.get_height(), 1.0))
	if t is Texture3D or t is TextureLayered:
		return Vector2(1.0 / maxf(t.get_width(), 1.0), 1.0 / maxf(t.get_height(), 1.0))
	if is_render_texture(t):
		return Vector2(1.0 / maxf(rt_get(t, "width", 256), 1.0), 1.0 / maxf(rt_get(t, "height", 256), 1.0))
	return Vector2.ONE

func texture_mipmap_count(t) -> int:
	if t is Texture2D:
		var img: Image = t.get_image()
		return img.get_mipmap_count() + 1 if img != null else 1
	if t is TextureLayered or t is Texture3D:
		return 1 + (1 if t.has_mipmaps() else 0)
	return 1

func texture_update_count(t) -> int:
	return int(prop_get(t, "updateCount", 0))

func texture_increment_update(t) -> void:
	prop_set(t, "updateCount", texture_update_count(t) + 1)

## Texture2D.SetPixelData: colours or raw bytes at mip level 0.
func texture_set_pixel_data(t: Texture2D, data: Array) -> void:
	if data.is_empty():
		return
	if data[0] is Color:
		texture_set_pixels(t, data)
	else:
		texture_load_raw(t, data)

## Layered / 3D textures cannot be read back from the rendering server headlessly, so the
## images a script writes are kept on the resource and re-uploaded on every change.
func _cube_faces(c: Cubemap) -> Array:
	if c == null:
		return []
	if c.has_meta("udon_faces"):
		return c.get_meta("udon_faces")
	var faces: Array = []
	for i in range(c.get_layers()):
		faces.append(c.get_layer_data(i))
	c.set_meta("udon_faces", faces)
	return faces

func new_cubemap(size: int) -> Cubemap:
	var faces: Array[Image] = []
	for _i in range(6):
		faces.append(Image.create(maxi(size, 1), maxi(size, 1), false, Image.FORMAT_RGBA8))
	var c := Cubemap.new()
	c.create_from_images(faces)
	c.set_meta("udon_faces", Array(faces))
	return c

func cubemap_get_pixel(c: Cubemap, face: int, x: int, y: int) -> Color:
	var faces: Array = _cube_faces(c)
	if face < 0 or face >= faces.size() or faces[face] == null:
		return Color.BLACK
	var img: Image = faces[face]
	return img.get_pixel(clampi(x, 0, img.get_width() - 1), clampi(y, 0, img.get_height() - 1))

func cubemap_set_pixel(c: Cubemap, face: int, x: int, y: int, col: Color) -> void:
	var faces: Array = _cube_faces(c)
	if face < 0 or face >= faces.size() or faces[face] == null:
		return
	var img: Image = faces[face]
	img.set_pixel(clampi(x, 0, img.get_width() - 1), clampi(y, 0, img.get_height() - 1), col)
	c.update_layer(img, face)

func cubemap_get_pixels(c: Cubemap, face: int) -> Array:
	var out: Array = []
	var faces: Array = _cube_faces(c)
	if face < 0 or face >= faces.size() or faces[face] == null:
		return out
	var img: Image = faces[face]
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			out.append(img.get_pixel(x, y))
	return out

func cubemap_set_pixels(c: Cubemap, colors: Array, face: int) -> void:
	var faces: Array = _cube_faces(c)
	if face < 0 or face >= faces.size() or faces[face] == null:
		return
	var img: Image = faces[face]
	var w: int = img.get_width()
	for i in range(mini(colors.size(), w * img.get_height())):
		img.set_pixel(i % w, i / w, colors[i])
	c.update_layer(img, face)

func _tex3d_slices(t: Texture3D) -> Array:
	if t == null:
		return []
	if t.has_meta("udon_slices"):
		return t.get_meta("udon_slices")
	var slices: Array = Array(t.get_data())
	t.set_meta("udon_slices", slices)
	return slices

func _tex3d_upload(t: Texture3D, slices: Array) -> void:
	if not (t is ImageTexture3D):
		return
	var typed: Array[Image] = []
	for img in slices:
		typed.append(img)
	t.update(typed)

func new_texture3d(w: int, h: int, d: int) -> ImageTexture3D:
	var slices: Array[Image] = []
	for _i in range(maxi(d, 1)):
		slices.append(Image.create(maxi(w, 1), maxi(h, 1), false, Image.FORMAT_RGBA8))
	var t := ImageTexture3D.new()
	t.create(Image.FORMAT_RGBA8, maxi(w, 1), maxi(h, 1), maxi(d, 1), false, slices)
	t.set_meta("udon_slices", Array(slices))
	return t

func texture3d_get_pixel(t: Texture3D, x: int, y: int, z: int) -> Color:
	var slices: Array = _tex3d_slices(t)
	if z < 0 or z >= slices.size() or slices[z] == null:
		return Color.BLACK
	var img: Image = slices[z]
	return img.get_pixel(clampi(x, 0, img.get_width() - 1), clampi(y, 0, img.get_height() - 1))

func texture3d_get_pixels(t: Texture3D) -> Array:
	var out: Array = []
	for img in _tex3d_slices(t):
		if img == null:
			continue
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				out.append(img.get_pixel(x, y))
	return out

## Writes colours in x-fastest, then y, then z order (Unity's Texture3D layout).
func texture3d_set_pixels(t: Texture3D, colors: Array) -> void:
	var slices: Array = _tex3d_slices(t)
	var i: int = 0
	for img in slices:
		if img == null:
			continue
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				if i < colors.size():
					img.set_pixel(x, y, colors[i])
				i += 1
	_tex3d_upload(t, slices)

func texture3d_set_pixel(t: Texture3D, x: int, y: int, z: int, col: Color) -> void:
	var slices: Array = _tex3d_slices(t)
	if z < 0 or z >= slices.size() or slices[z] == null:
		return
	var img: Image = slices[z]
	img.set_pixel(clampi(x, 0, img.get_width() - 1), clampi(y, 0, img.get_height() - 1), col)
	_tex3d_upload(t, slices)

# --- meshes ---------------------------------------------------------------------------------------

## Unity VertexAttribute → Godot ARRAY_* index (BlendWeight 12 / BlendIndices 13 → bones).
const _VERTEX_ATTR: Dictionary = {0: Mesh.ARRAY_VERTEX, 1: Mesh.ARRAY_NORMAL, 2: Mesh.ARRAY_TANGENT, 3: Mesh.ARRAY_COLOR, 4: Mesh.ARRAY_TEX_UV, 5: Mesh.ARRAY_TEX_UV2, 6: Mesh.ARRAY_CUSTOM0, 7: Mesh.ARRAY_CUSTOM1, 8: Mesh.ARRAY_CUSTOM2, 9: Mesh.ARRAY_CUSTOM3, 12: Mesh.ARRAY_WEIGHTS, 13: Mesh.ARRAY_BONES}
const _VERTEX_ATTR_DIM: Dictionary = {0: 3, 1: 3, 2: 4, 3: 4, 4: 2, 5: 2, 6: 2, 7: 2, 8: 2, 9: 2, 10: 2, 11: 2, 12: 4, 13: 4}

func mesh_has_attribute(m: Mesh, attr: int) -> bool:
	if m == null or m.get_surface_count() == 0 or not _VERTEX_ATTR.has(attr):
		return false
	var a = m.surface_get_arrays(0)[_VERTEX_ATTR[attr]]
	return a != null and a.size() > 0

func mesh_attribute_dimension(m: Mesh, attr: int) -> int:
	return int(_VERTEX_ATTR_DIM.get(attr, 0)) if mesh_has_attribute(m, attr) else 0

func mesh_set_bounds(m: Mesh, b: AABB) -> void:
	if m is ArrayMesh:
		m.custom_aabb = to_gd_aabb(b)

## Blend shapes can only be declared on an ArrayMesh before it has surfaces.
func mesh_add_blend_shape(m: Mesh, name_: String) -> void:
	if m is ArrayMesh:
		if m.get_surface_count() > 0:
			push_warning("Mesh.AddBlendShapeFrame: blend shapes must be added before the surfaces (Godot)")
			return
		m.add_blend_shape(name_)

func mesh_clear_blend_shapes(m: Mesh) -> void:
	if m is ArrayMesh and m.get_surface_count() == 0:
		m.clear_blend_shapes()

## Mesh.CombineMeshes: CombineInstance dictionaries {mesh, subMeshIndex, transform} become the
## surfaces of `dst` (one merged surface, or one per instance).
func mesh_combine(dst: Mesh, instances: Array, merge: bool, use_matrices: bool) -> void:
	if not (dst is ArrayMesh):
		return
	dst.clear_surfaces()
	var merged_v := PackedVector3Array()
	var merged_n := PackedVector3Array()
	var merged_uv := PackedVector2Array()
	var merged_i := PackedInt32Array()
	var has_uv: bool = true
	var has_n: bool = true
	for inst in instances:
		if not (inst is Dictionary):
			continue
		var src: Mesh = inst.get("mesh")
		if src == null or src.get_surface_count() == 0:
			continue
		var sub: int = clampi(int(inst.get("subMeshIndex", 0)), 0, src.get_surface_count() - 1)
		var arrays: Array = src.surface_get_arrays(sub)
		var xf: Transform3D = to_gd_t(inst.get("transform", Transform3D())) if use_matrices else Transform3D()
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms = arrays[Mesh.ARRAY_NORMAL]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var idx = arrays[Mesh.ARRAY_INDEX]
		var v2 := PackedVector3Array()
		var n2 := PackedVector3Array()
		for k in range(verts.size()):
			v2.append(xf * verts[k])
			if norms != null:
				n2.append((xf.basis * norms[k]).normalized())
		var i2 := PackedInt32Array()
		if idx != null and idx.size() > 0:
			i2 = idx
		else:
			for k in range(verts.size()):
				i2.append(k)
		if merge:
			var base: int = merged_v.size()
			merged_v.append_array(v2)
			if norms != null:
				merged_n.append_array(n2)
			else:
				has_n = false
			if uvs != null:
				merged_uv.append_array(uvs)
			else:
				has_uv = false
			for k in i2:
				merged_i.append(k + base)
		else:
			var out: Array = []
			out.resize(Mesh.ARRAY_MAX)
			out[Mesh.ARRAY_VERTEX] = v2
			if norms != null:
				out[Mesh.ARRAY_NORMAL] = n2
			if uvs != null:
				out[Mesh.ARRAY_TEX_UV] = uvs
			out[Mesh.ARRAY_INDEX] = i2
			dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	if merge and merged_v.size() > 0:
		var out: Array = []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = merged_v
		if has_n and merged_n.size() == merged_v.size():
			out[Mesh.ARRAY_NORMAL] = merged_n
		if has_uv and merged_uv.size() == merged_v.size():
			out[Mesh.ARRAY_TEX_UV] = merged_uv
		out[Mesh.ARRAY_INDEX] = merged_i
		dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)

# --- renderers ------------------------------------------------------------------------------------

func renderer_force_off_get(n: Node) -> bool:
	var g := _geom(n)
	return g != null and bool(g.get_meta("udon_force_off", false))

func renderer_force_off_set(n: Node, v: bool) -> void:
	var g := _geom(n)
	if g == null:
		return
	g.set_meta("udon_force_off", v)
	g.visible = not v

## Renderer.bounds is world space; Godot's custom_aabb is local to the instance.
func renderer_set_bounds(n: Node, b: AABB) -> void:
	var g := _geom(n)
	if g == null:
		return
	var world: AABB = to_gd_aabb(b)
	g.custom_aabb = g.global_transform.affine_inverse() * world

func renderer_set_local_bounds(n: Node, b: AABB) -> void:
	var g := _geom(n)
	if g is GPUParticles3D:
		g.visibility_aabb = to_gd_aabb(b)
	elif g != null:
		g.custom_aabb = to_gd_aabb(b)

func light_set_type(_l: Light3D, _t: int) -> void:
	push_warning("Light.type cannot change at run time: Godot lights are distinct node classes")

# --- physical camera (CameraAttributesPhysical) ---------------------------------------------------

func _cam_phys(c: Camera3D) -> CameraAttributesPhysical:
	if c.attributes is CameraAttributesPhysical:
		return c.attributes
	var a := CameraAttributesPhysical.new()
	if c.attributes != null:
		a.auto_exposure_enabled = c.attributes.auto_exposure_enabled
	c.attributes = a
	return a

func camera_phys_get(c: Camera3D, key: String, default: float) -> float:
	if c == null:
		return default
	if not (c.attributes is CameraAttributesPhysical):
		return default
	var a: CameraAttributesPhysical = c.attributes
	match key:
		"aperture":
			return a.exposure_aperture
		"shutterSpeed":
			return 1.0 / maxf(a.exposure_shutter_speed, 0.0001)
		"iso":
			return a.exposure_sensitivity
		"focusDistance":
			return a.frustum_focus_distance
	return default

func camera_phys_set(c: Camera3D, key: String, v: float) -> void:
	if c == null:
		return
	var a := _cam_phys(c)
	match key:
		"aperture":
			a.exposure_aperture = v
		"shutterSpeed":
			a.exposure_shutter_speed = 1.0 / maxf(v, 0.0001)
		"iso":
			a.exposure_sensitivity = v
		"focusDistance":
			a.frustum_focus_distance = v

# --- GeometryUtility ------------------------------------------------------------------------------

## Camera frustum planes in script space: Unity order left, right, bottom, top, near, far.
func frustum_planes(c: Camera3D) -> Array:
	if c == null:
		return []
	var gd: Array = c.get_frustum()   # near, far, left, top, right, bottom
	if gd.size() < 6:
		return []
	var order: Array = [2, 4, 5, 3, 0, 1]
	var out: Array = []
	for i in order:
		var p: Plane = gd[i]
		# Godot's frustum planes face outward; Unity's face inward (positive side = inside)
		var n: Vector3 = from_gd_v(-p.normal)
		out.append(Plane(n, -p.d))
	return out

func frustum_planes_into(c: Camera3D, into: Array) -> void:
	var planes: Array = frustum_planes(c)
	for i in range(mini(planes.size(), into.size())):
		into[i] = planes[i]

## Frustum planes of a view-projection matrix approximated by the active camera.
func frustum_planes_matrix(_m: Transform3D) -> Array:
	return frustum_planes(main_camera())

## True when the box is (partly) inside every plane's positive half-space.
func test_planes_aabb(planes: Array, b: AABB) -> bool:
	for p in planes:
		if not (p is Plane):
			continue
		var n: Vector3 = p.normal
		var far_corner := Vector3(b.end.x if n.x >= 0.0 else b.position.x, b.end.y if n.y >= 0.0 else b.position.y, b.end.z if n.z >= 0.0 else b.position.z)
		if p.distance_to(far_corner) < 0.0:
			return false
	return true

func calculate_bounds(points: Array, m: Transform3D) -> AABB:
	if points.is_empty():
		return AABB()
	var first: Vector3 = m * points[0]
	var b := AABB(first, Vector3.ZERO)
	for i in range(1, points.size()):
		b = b.expand(m * points[i])
	return b

## Plane through a polygon (Newell's method); {} when degenerate.
func plane_from_polygon(points: Array) -> Dictionary:
	if points.size() < 3:
		return {}
	var n := Vector3.ZERO
	for i in range(points.size()):
		var a: Vector3 = points[i]
		var b: Vector3 = points[(i + 1) % points.size()]
		n += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
	if n.length_squared() < 1e-12:
		return {}
	return {"plane": Plane(n.normalized(), points[0])}

# --- SphericalHarmonicsL2: 3 channels × 9 coefficients (Unity's real SH basis) ------------------

const _SH_C: Array = [0.282095, 0.488603, 0.488603, 0.488603, 1.092548, 1.092548, 0.315392, 1.092548, 0.546274]

func sh_new() -> Dictionary:
	var c: Array = []
	for _i in range(27):
		c.append(0.0)
	return {"c": c}

func sh_get(sh: Dictionary, channel: int, i: int) -> float:
	var c: Array = sh.get("c", [])
	var k: int = channel * 9 + i
	return float(c[k]) if k >= 0 and k < c.size() else 0.0

func sh_set(sh: Dictionary, channel: int, i: int, v: float) -> void:
	if not sh.has("c"):
		sh["c"] = sh_new()["c"]
	var k: int = channel * 9 + i
	if k >= 0 and k < 27:
		sh["c"][k] = v

func _sh_basis(d: Vector3) -> Array:
	return [_SH_C[0], _SH_C[1] * d.y, _SH_C[2] * d.z, _SH_C[3] * d.x, _SH_C[4] * d.x * d.y, _SH_C[5] * d.y * d.z, _SH_C[6] * (3.0 * d.z * d.z - 1.0), _SH_C[7] * d.x * d.z, _SH_C[8] * (d.x * d.x - d.y * d.y)]

func sh_add_ambient(sh: Dictionary, col: Color) -> void:
	# a constant radiance L integrates to L * sqrt(4π) * Y00 ... expressed so that Evaluate returns L
	var scale: float = 1.0 / _SH_C[0]
	sh_set(sh, 0, 0, sh_get(sh, 0, 0) + col.r * scale)
	sh_set(sh, 1, 0, sh_get(sh, 1, 0) + col.g * scale)
	sh_set(sh, 2, 0, sh_get(sh, 2, 0) + col.b * scale)

func sh_add_directional(sh: Dictionary, dir: Vector3, col: Color, intensity: float) -> void:
	var d: Vector3 = dir.normalized()
	var basis: Array = _sh_basis(d)
	# Unity's convention: a directional light adds 2π * intensity * colour * basis(d), cosine-lobe weighted
	var lobe: Array = [PI, 2.0 * PI / 3.0, 2.0 * PI / 3.0, 2.0 * PI / 3.0, PI / 4.0, PI / 4.0, PI / 4.0, PI / 4.0, PI / 4.0]
	var ch: Array = [col.r, col.g, col.b]
	for c in range(3):
		for i in range(9):
			sh_set(sh, c, i, sh_get(sh, c, i) + basis[i] * lobe[i] * ch[c] * intensity * 2.0)

func sh_evaluate(sh: Dictionary, dirs: Array, into: Array) -> void:
	for k in range(mini(dirs.size(), into.size())):
		var basis: Array = _sh_basis((dirs[k] as Vector3).normalized())
		var rgb: Array = [0.0, 0.0, 0.0]
		for c in range(3):
			for i in range(9):
				rgb[c] += sh_get(sh, c, i) * basis[i]
		into[k] = Color(maxf(rgb[0], 0.0), maxf(rgb[1], 0.0), maxf(rgb[2], 0.0), 1.0)

# --- shadow distance (VRCQualitySettings) ----------------------------------------------------------

func _sun_lights() -> Array:
	return get_components_in_children(scene_root(), "DirectionalLight3D", true)

func shadow_distance_get(default: float) -> float:
	for l in _sun_lights():
		return l.directional_shadow_max_distance
	return default

func shadow_distance_set(d: float) -> void:
	for l in _sun_lights():
		l.directional_shadow_max_distance = d

func shadow_splits_set(s1: float, s2: float, s3: float) -> void:
	for l in _sun_lights():
		l.directional_shadow_split_1 = clampf(s1, 0.0, 1.0)
		l.directional_shadow_split_2 = clampf(s2, 0.0, 1.0)
		l.directional_shadow_split_3 = clampf(s3, 0.0, 1.0)

func shadow_splits_get() -> Vector3:
	for l in _sun_lights():
		return Vector3(l.directional_shadow_split_1, l.directional_shadow_split_2, l.directional_shadow_split_3)
	return Vector3(0.067, 0.2, 0.467)

## Unity cascade count 1/2/4 ↔ DirectionalLight3D shadow mode.
func shadow_cascades_get() -> int:
	for l in _sun_lights():
		match l.directional_shadow_mode:
			DirectionalLight3D.SHADOW_ORTHOGONAL:
				return 1
			DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS:
				return 2
		return 4
	return 4

func shadow_cascades_set(n: int) -> void:
	for l in _sun_lights():
		l.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if n <= 1 else (DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if n == 2 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)

## OcclusionPortal.open over an OccluderInstance3D (an open portal occludes nothing).
func portal_get_open(n: Node) -> bool:
	if n is OccluderInstance3D:
		return not n.visible
	return bool(prop_get(n, "open", true))

func portal_set_open(n: Node, v: bool) -> void:
	if n is OccluderInstance3D:
		n.visible = not v
	prop_set(n, "open", v)

func quat_dir(q: Quaternion, axis: Vector3) -> Vector3:
	return q * axis

func renderer_local_bounds(n: Node) -> AABB:
	var g := _geom(n)
	if g == null:
		return AABB()
	if g is GPUParticles3D:
		return from_gd_aabb(g.visibility_aabb)
	return from_gd_aabb(g.custom_aabb if g.custom_aabb.size != Vector3.ZERO else g.get_aabb())

## Mesh.bounds: the custom AABB when a script set one, else the computed one.
func mesh_get_bounds(m: Mesh) -> AABB:
	if m == null:
		return AABB()
	if m is ArrayMesh and m.custom_aabb.size != Vector3.ZERO:
		return from_gd_aabb(m.custom_aabb)
	return from_gd_aabb(m.get_aabb())

# ---------------------------------------------------------------------------
# Navigation extras: links (NavigationLink3D), NavMesh data/link instances, build settings,
# nav raycast, triangulation of the scene's navigation meshes
# ---------------------------------------------------------------------------

var _nav_synced_frame: int = -1

## The world navigation map, synchronised once per frame before the first query so regions and
## links added this frame (or before the first physics tick) are already searchable.
func _nav_map() -> RID:
	var map: RID = get_viewport().world_3d.navigation_map if get_viewport() != null else RID()
	if map.is_valid() and _nav_synced_frame != Engine.get_process_frames():
		_nav_synced_frame = Engine.get_process_frames()
		NavigationServer3D.map_force_update(map)
		if NavigationServer3D.map_get_iteration_id(map) == 0:
			# never synchronised: make sure the map is active and try once more
			NavigationServer3D.map_set_active(map, true)
			NavigationServer3D.map_force_update(map)
			if NavigationServer3D.map_get_iteration_id(map) == 0:
				push_warning("navigation map has no synchronised regions yet (%d regions registered)" % NavigationServer3D.map_get_regions(map).size())
		if OS.has_environment("UDON_NAV_DEBUG"):
			print("[nav] map ", map, " active=", NavigationServer3D.map_is_active(map), " iteration=", NavigationServer3D.map_get_iteration_id(map), " regions=", NavigationServer3D.map_get_regions(map).size(), " frame=", Engine.get_process_frames())
	return map

## Unity area index ↔ Godot navigation layer bit.
func nav_area_get(l: NavigationLink3D) -> int:
	var layers: int = l.navigation_layers
	for i in range(32):
		if layers & (1 << i):
			return i
	return 0

func nav_area_set(l: NavigationLink3D, area: int) -> void:
	l.navigation_layers = 1 << clampi(area, 0, 31)

## Unity cost modifiers: negative = default cost.
func nav_cost_get(l: NavigationLink3D) -> float:
	return l.travel_cost if l.has_meta("udon_cost_override") else -1.0

func nav_cost_set(l: NavigationLink3D, cost: float) -> void:
	if cost < 0.0:
		l.remove_meta("udon_cost_override")
		l.travel_cost = 1.0
	else:
		l.set_meta("udon_cost_override", true)
		l.travel_cost = cost

## OffMeshLink.startTransform / endTransform: the link follows the referenced nodes.
func offmesh_transform_get(l: NavigationLink3D, which: String) -> Node:
	var n = prop_get(l, which + "Transform", null)
	return n if n is Node else l

func offmesh_transform_set(l: NavigationLink3D, which: String, n: Node) -> void:
	prop_set(l, which + "Transform", n)
	offmesh_update_positions(l)

func offmesh_update_positions(l: NavigationLink3D) -> void:
	var s = prop_get(l, "startTransform", null)
	var e = prop_get(l, "endTransform", null)
	if s is Node3D:
		l.set_global_start_position(s.global_position)
	if e is Node3D:
		l.set_global_end_position(e.global_position)

## NavMesh.AddLink: a NavigationLink3D built from NavMeshLinkData at a pose; {"node", "valid"}.
func nav_add_link(data: Dictionary, pos: Vector3, rot: Quaternion) -> Dictionary:
	var link := NavigationLink3D.new()
	link.name = "NavMeshLink"
	link.start_position = to_gd_v(data.get("startPosition", Vector3.ZERO))
	link.end_position = to_gd_v(data.get("endPosition", Vector3.ZERO))
	link.bidirectional = bool(data.get("bidirectional", true))
	nav_area_set(link, int(data.get("area", 0)))
	nav_cost_set(link, float(data.get("costModifier", -1.0)))
	prop_set(link, "width", float(data.get("width", 0.0)))
	scene_root().add_child(link)
	link.global_transform = Transform3D(Basis(to_gd_q(rot)), to_gd_v(pos))
	return {"node": link, "valid": true}

func nav_remove_instance(inst: Dictionary) -> void:
	var n = inst.get("node")
	if n is Node and is_instance_valid(n):
		n.queue_free()
	inst["valid"] = false
	inst["node"] = null

## NavMesh.AddNavMeshData: a NavigationRegion3D when the data carries a NavigationMesh.
func nav_add_data(data: Dictionary, pos: Vector3, rot: Quaternion) -> Dictionary:
	var mesh = data.get("mesh")
	if not (mesh is NavigationMesh):
		return {"node": null, "valid": false}
	var region := NavigationRegion3D.new()
	region.name = "NavMeshData"
	region.navigation_mesh = mesh
	scene_root().add_child(region)
	region.global_transform = Transform3D(Basis(to_gd_q(rot)), to_gd_v(pos))
	data["position"] = pos
	data["rotation"] = rot
	return {"node": region, "valid": true}

## NavMesh build settings: Godot bakes offline, so these are a description with Unity's defaults.
func nav_build_settings(id: int) -> Dictionary:
	return {"agentTypeID": id, "agentRadius": 0.5, "agentHeight": 2.0, "agentSlope": 45.0, "agentClimb": 0.4, "ledgeDropHeight": 0.0, "maxJumpAcrossDistance": 0.0, "minRegionArea": 2.0, "overrideVoxelSize": false, "voxelSize": 0.1666, "overrideTileSize": false, "tileSize": 256, "buildHeightMesh": false, "preserveTilesOutsideBounds": false, "debug": {}}

## NavMesh.Raycast: walks the segment and reports where it leaves the navigation mesh.
func nav_raycast(from: Vector3, to: Vector3, _mask: int) -> Dictionary:
	var map: RID = _nav_map()
	if not map.is_valid():
		return {"position": to, "hit": false, "normal": Vector3.UP, "distance": from.distance_to(to), "mask": _mask}
	var total: float = from.distance_to(to)
	var steps: int = maxi(int(total / 0.25), 1)
	var last: Vector3 = from
	for i in range(steps + 1):
		var p: Vector3 = from.lerp(to, float(i) / float(steps))
		var c: Vector3 = from_gd_v(NavigationServer3D.map_get_closest_point(map, to_gd_v(p)))
		if p.distance_to(c) > 0.5:
			return {"position": last, "hit": true, "normal": (from - to).normalized() if total > 0.0 else Vector3.UP, "distance": from.distance_to(last), "mask": _mask}
		last = p
	return {"position": to, "hit": false, "normal": Vector3.UP, "distance": total, "mask": _mask}

## NavMesh.CalculateTriangulation over the scene's NavigationRegion3D meshes (fan-triangulated).
func nav_triangulation() -> Dictionary:
	var verts: Array = []
	var indices: Array = []
	var areas: Array = []
	for region in get_components_in_children(scene_root(), "NavigationRegion3D", true):
		var nm: NavigationMesh = region.navigation_mesh
		if nm == null:
			continue
		var base: int = verts.size()
		for v in nm.get_vertices():
			verts.append(from_gd_v(region.global_transform * v))
		for pi in range(nm.get_polygon_count()):
			var poly: PackedInt32Array = nm.get_polygon(pi)
			for k in range(1, poly.size() - 1):
				indices.append(base + poly[0])
				indices.append(base + poly[k])
				indices.append(base + poly[k + 1])
				areas.append(0)
	return {"vertices": verts, "indices": indices, "areas": areas}

func nav_region_of(_a: Node) -> Node:
	var regions: Array = get_components_in_children(scene_root(), "NavigationRegion3D", true)
	return regions[0] if not regions.is_empty() else null

## NavMeshQueryFilter area costs live in the filter dictionary.
func nav_filter_cost_get(f: Dictionary, area: int) -> float:
	return float(f.get("costs", {}).get(area, 1.0))

func nav_filter_cost_set(f: Dictionary, area: int, cost: float) -> void:
	if not f.has("costs"):
		f["costs"] = {}
	f["costs"][area] = cost

# ---------------------------------------------------------------------------
# Constraint solver: Unity Animations constraints and VRChat constraints share the store set up
# by constraint_get/constraint_set. Each frame (deferred, after every Update) the active
# constraints move their node toward the weighted result of their sources.
# ---------------------------------------------------------------------------

## Remembers which solver a node's constraint uses ("position", "rotation", "scale", "parent",
## "aim", "lookat"); the catalog calls this from the type-specific members.
func constraint_kind(n: Node, kind: String) -> void:
	if n != null:
		_constraint(n)["kind"] = kind

func _src_node(src) -> Node3D:
	if src is Dictionary:
		var t = src.get("sourceTransform", src.get("SourceTransform"))
		return t if t is Node3D else null
	return null

func _src_weight(src) -> float:
	return float(src.get("weight", src.get("Weight", 1.0))) if src is Dictionary else 0.0

func _src_offset(src, key_unity: String, key_vrc: String) -> Vector3:
	if src is Dictionary:
		return src.get(key_unity, src.get(key_vrc, Vector3.ZERO))
	return Vector3.ZERO

func _cget(c: Dictionary, keys: Array, default):
	for k in keys:
		if c.has(k):
			return c[k]
	return default

func _axis_mask(c: Dictionary, unity_key: String, vrc_prefix: String) -> Vector3:
	if c.has(unity_key):
		var a: int = int(c[unity_key])
		return Vector3(1.0 if a & 1 else 0.0, 1.0 if a & 2 else 0.0, 1.0 if a & 4 else 0.0)
	return Vector3(1.0 if c.get(vrc_prefix + "X", true) else 0.0, 1.0 if c.get(vrc_prefix + "Y", true) else 0.0, 1.0 if c.get(vrc_prefix + "Z", true) else 0.0)

func _masked(current: Vector3, target: Vector3, mask: Vector3) -> Vector3:
	return Vector3(target.x if mask.x > 0.5 else current.x, target.y if mask.y > 0.5 else current.y, target.z if mask.z > 0.5 else current.z)

## Weighted average of source rotations (successive normalised slerps).
func _avg_rotation(rots: Array, weights: Array) -> Quaternion:
	var total: float = 0.0
	var acc := Quaternion()
	for i in range(rots.size()):
		var w: float = weights[i]
		if w <= 0.0:
			continue
		total += w
		acc = rots[i] if total == w else acc.slerp(rots[i], w / total)
	return acc

func solve_constraints() -> void:
	for id in _constraints.keys():
		var c: Dictionary = _constraints[id]
		if not c.get("active", false):
			continue
		var n = instance_from_id(id)
		if not (n is Node3D) or not n.is_inside_tree():
			continue
		var target: Node3D = c.get("target") if c.get("target") is Node3D else n
		_solve_one(target, c)

func _solve_one(n: Node3D, c: Dictionary) -> void:
	var kind: String = str(c.get("kind", ""))
	var weight: float = clampf(float(c.get("weight", 1.0)), 0.0, 1.0)
	var sources: Array = c.get("sources", [])
	var positions: Array = []
	var rotations: Array = []
	var scales: Array = []
	var weights: Array = []
	var wsum: float = 0.0
	for i in range(sources.size()):
		var s = sources[i]
		var sn: Node3D = _src_node(s)
		if sn == null:
			continue
		var w: float = _src_weight(s)
		if w <= 0.0:
			continue
		var p: Vector3 = get_position(sn)
		var r: Quaternion = get_global_rotation(sn)
		if kind == "parent":
			var off_p: Vector3 = _src_offset(s, "translationOffset", "ParentPositionOffset")
			var off_r: Vector3 = _src_offset(s, "rotationOffset", "ParentRotationOffset")
			var offs_p: Array = c.get("translationOffsets", [])
			var offs_r: Array = c.get("rotationOffsets", [])
			if i < offs_p.size():
				off_p = offs_p[i]
			if i < offs_r.size():
				off_r = offs_r[i]
			p = p + r * off_p
			r = r * euler_v(off_r)
		positions.append(p)
		rotations.append(r)
		scales.append(sn.global_transform.basis.get_scale())
		weights.append(w)
		wsum += w
	if wsum <= 0.0:
		return
	var avg_pos := Vector3.ZERO
	var avg_scale := Vector3.ZERO
	for i in range(positions.size()):
		avg_pos += positions[i] * (weights[i] / wsum)
		avg_scale += scales[i] * (weights[i] / wsum)
	var cur_pos: Vector3 = get_position(n)
	var cur_rot: Quaternion = get_global_rotation(n)
	match kind:
		"position":
			var goal: Vector3 = avg_pos + _cget(c, ["translationOffset", "positionOffset"], Vector3.ZERO)
			var mask: Vector3 = _axis_mask(c, "translationAxis", "affectP")
			set_position(n, _masked(cur_pos, cur_pos.lerp(goal, weight), mask))
		"rotation":
			var goal: Quaternion = _avg_rotation(rotations, weights) * euler_v(_cget(c, ["rotationOffset"], Vector3.ZERO))
			var mask: Vector3 = _axis_mask(c, "rotationAxis", "affect")
			var e: Vector3 = _masked(quat_to_euler(cur_rot), quat_to_euler(cur_rot.slerp(goal, weight)), mask)
			set_global_rotation(n, euler_v(e))
		"scale":
			var goal: Vector3 = avg_scale * _cget(c, ["scaleOffset"], Vector3.ONE)
			var mask: Vector3 = _axis_mask(c, "scalingAxis", "affectS")
			var cur: Vector3 = n.scale
			n.scale = _masked(cur, cur.lerp(goal, weight), mask)
		"parent":
			var goal_r: Quaternion = _avg_rotation(rotations, weights)
			var pmask: Vector3 = _axis_mask(c, "translationAxis", "affectP")
			var rmask: Vector3 = _axis_mask(c, "rotationAxis", "affect")
			set_position(n, _masked(cur_pos, cur_pos.lerp(avg_pos, weight), pmask))
			var e: Vector3 = _masked(quat_to_euler(cur_rot), quat_to_euler(cur_rot.slerp(goal_r, weight)), rmask)
			set_global_rotation(n, euler_v(e))
		"aim", "lookat":
			var dir: Vector3 = avg_pos - cur_pos
			if dir.length_squared() < 1e-10:
				return
			var aim_axis: Vector3 = _cget(c, ["aimVector", "aimAxis"], vec_forward()) if kind == "aim" else vec_forward()
			var up_axis: Vector3 = _cget(c, ["upVector", "upAxis"], Vector3.UP)
			var world_up: Vector3 = Vector3.UP
			var up_obj = _cget(c, ["worldUpObject", "worldUpTransform"], null)
			var up_type: int = int(_cget(c, ["worldUpType"], 0))
			if up_obj is Node3D and (up_type == 1 or up_type == 2 or kind == "lookat" and c.get("useUp", c.get("useUpObject", false))):
				world_up = (get_position(up_obj) - cur_pos).normalized() if up_type == 1 else up(up_obj)
			elif up_type == 3:
				world_up = _cget(c, ["worldUpVector", "worldUp"], Vector3.UP)
			var look: Quaternion = look_rotation(dir.normalized(), world_up)
			# rotate so the aim axis (not necessarily +Z) points along the look direction
			var fix: Quaternion = from_to_rotation(aim_axis, vec_forward())
			var goal: Quaternion = look * fix
			if kind == "lookat":
				goal = goal * Quaternion(vec_forward(), deg_to_rad(float(c.get("roll", 0.0))))
			goal = goal * euler_v(_cget(c, ["rotationOffset"], Vector3.ZERO))
			var mask: Vector3 = _axis_mask(c, "rotationAxis", "affect")
			var e: Vector3 = _masked(quat_to_euler(cur_rot), quat_to_euler(cur_rot.slerp(goal, weight)), mask)
			set_global_rotation(n, euler_v(e))
			if up_axis != Vector3.UP:
				pass

## Cinemachine damping: the residual decays to 1 % over the damping time.
func cine_damp(initial: float, damp_time: float, dt: float) -> float:
	if damp_time <= 0.0 or dt <= 0.0:
		return initial
	return initial * (1.0 - exp(-4.605170186 * dt / damp_time))

func cine_damp_v(initial: Vector3, damp_time: float, dt: float) -> Vector3:
	return Vector3(cine_damp(initial.x, damp_time, dt), cine_damp(initial.y, damp_time, dt), cine_damp(initial.z, damp_time, dt))

func cine_damp_v3(initial: Vector3, damp: Vector3, dt: float) -> Vector3:
	return Vector3(cine_damp(initial.x, damp.x, dt), cine_damp(initial.y, damp.y, dt), cine_damp(initial.z, damp.z, dt))

# --- AnimationCurve extras ------------------------------------------------------------------------

func curve_clear(c: Curve) -> void:
	c.clear_points()

func curve_copy(dst: Curve, src: Curve) -> void:
	dst.clear_points()
	# ranges first: Godot clamps points to the curve's domain and value range as they are added
	dst.min_domain = src.min_domain
	dst.max_domain = src.max_domain
	dst.min_value = src.min_value
	dst.max_value = src.max_value
	for i in range(src.point_count):
		dst.add_point(src.get_point_position(i), src.get_point_left_tangent(i), src.get_point_right_tangent(i))

func curve_key(c: Curve, i: int) -> Dictionary:
	if i < 0 or i >= c.point_count:
		return {"time": 0.0, "value": 0.0, "inTangent": 0.0, "outTangent": 0.0}
	var p: Vector2 = c.get_point_position(i)
	return {"time": p.x, "value": p.y, "inTangent": c.get_point_left_tangent(i), "outTangent": c.get_point_right_tangent(i)}

func curve_set_keys(c: Curve, keys: Array) -> void:
	c.clear_points()
	for k in keys:
		curve_add_key(c, float(k.get("time", 0.0)), float(k.get("value", 0.0)), float(k.get("inTangent", 0.0)), float(k.get("outTangent", 0.0)))

# --- Humanoid tables --------------------------------------------------------------------------------

const HUMAN_BONES: Array = ["Hips", "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot", "Spine", "Chest", "Neck", "Head", "LeftShoulder", "RightShoulder", "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm", "LeftHand", "RightHand", "LeftToes", "RightToes", "LeftEye", "RightEye", "Jaw", "Left Thumb Proximal", "Left Thumb Intermediate", "Left Thumb Distal", "Left Index Proximal", "Left Index Intermediate", "Left Index Distal", "Left Middle Proximal", "Left Middle Intermediate", "Left Middle Distal", "Left Ring Proximal", "Left Ring Intermediate", "Left Ring Distal", "Left Little Proximal", "Left Little Intermediate", "Left Little Distal", "Right Thumb Proximal", "Right Thumb Intermediate", "Right Thumb Distal", "Right Index Proximal", "Right Index Intermediate", "Right Index Distal", "Right Middle Proximal", "Right Middle Intermediate", "Right Middle Distal", "Right Ring Proximal", "Right Ring Intermediate", "Right Ring Distal", "Right Little Proximal", "Right Little Intermediate", "Right Little Distal", "UpperChest"]
const HUMAN_REQUIRED: Array = [0, 1, 2, 3, 4, 5, 6, 7, 10, 13, 14, 15, 16, 17, 18]
const HUMAN_PARENT: Dictionary = {0: -1, 1: 0, 2: 0, 3: 1, 4: 2, 5: 3, 6: 4, 7: 0, 8: 7, 54: 8, 9: 54, 10: 9, 11: 54, 12: 54, 13: 11, 14: 12, 15: 13, 16: 14, 17: 15, 18: 16, 19: 5, 20: 6, 21: 10, 22: 10, 23: 10}

func human_parent_bone(i: int) -> int:
	if HUMAN_PARENT.has(i):
		return HUMAN_PARENT[i]
	if i >= 24 and i <= 38:
		return 17 if (i - 24) % 3 == 0 else i - 1
	if i >= 39 and i <= 53:
		return 18 if (i - 39) % 3 == 0 else i - 1
	return -1

func human_muscle_names() -> Array:
	var out: Array = []
	for i in range(95):
		out.append("Muscle %d" % i)
	return out

## AvatarMask: transform paths and humanoid body parts kept in a dictionary.
func mask_paths(m: Dictionary) -> Array:
	if not m.has("paths"):
		m["paths"] = []
	return m["paths"]

func mask_add_path(m: Dictionary, t: Node, recursive: bool) -> void:
	if not (t is Node):
		return
	var paths: Array = mask_paths(m)
	paths.append({"path": str(t.get_path()), "active": true})
	if recursive:
		for c in t.get_children():
			mask_add_path(m, c, true)

func mask_remove_path(m: Dictionary, t: Node, recursive: bool) -> void:
	if not (t is Node):
		return
	var paths: Array = mask_paths(m)
	var p: String = str(t.get_path())
	var i: int = 0
	while i < paths.size():
		var entry: Dictionary = paths[i]
		if entry.get("path", "") == p or (recursive and str(entry.get("path", "")).begins_with(p + "/")):
			paths.remove_at(i)
		else:
			i += 1

func constraint_offset(n: Node, key: String, i: int) -> Vector3:
	var arr: Array = constraint_get(n, key, [])
	return arr[i] if i >= 0 and i < arr.size() else Vector3.ZERO

## RuntimeAnimatorController.animationClips: an AnimationPlayer's animations, or the override map.
func anim_controller_clips(c) -> Array:
	var out: Array = []
	if c is Dictionary:
		return anim_controller_clips(c.get("controller"))
	if c is AnimationPlayer:
		for name_ in c.get_animation_list():
			out.append(c.get_animation(name_))
	elif c is AnimationLibrary:
		for name_ in c.get_animation_list():
			out.append(c.get_animation(name_))
	return out

func anim_clip_name(clip) -> String:
	return clip.resource_name if clip is Resource else str(clip)

func type_array(objs: Array) -> Array:
	var out: Array = []
	for o in objs:
		out.append(type_of(o))
	return out

# ---------------------------------------------------------------------------
# Leftovers: gradient keys, text assets, contacts, player data keys, audio clips, hierarchy
# ---------------------------------------------------------------------------

## Unity GradientColorKey / GradientAlphaKey lists over a Godot Gradient.
func gradient_color_keys(g: Gradient) -> Array:
	var out: Array = []
	if g == null:
		return out
	for i in range(g.get_point_count()):
		out.append({"color": g.get_color(i), "time": g.get_offset(i)})
	return out

func gradient_alpha_keys(g: Gradient) -> Array:
	var out: Array = []
	if g == null:
		return out
	for i in range(g.get_point_count()):
		out.append({"alpha": g.get_color(i).a, "time": g.get_offset(i)})
	return out

## Rebuilds the gradient from colour keys and alpha keys (alpha sampled at each colour key).
func gradient_set_keys(g: Gradient, color_keys: Array, alpha_keys: Array) -> void:
	if g == null:
		return
	var alpha := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	if alpha_keys.is_empty():
		alpha_keys = [{"alpha": 1.0, "time": 0.0}, {"alpha": 1.0, "time": 1.0}]
	var a_offs := PackedFloat32Array()
	var a_cols := PackedColorArray()
	for k in alpha_keys:
		a_offs.append(float(k.get("time", 0.0)))
		var av: float = float(k.get("alpha", 1.0))
		a_cols.append(Color(av, av, av, av))
	alpha.offsets = a_offs
	alpha.colors = a_cols
	if color_keys.is_empty():
		color_keys = [{"color": Color.WHITE, "time": 0.0}, {"color": Color.WHITE, "time": 1.0}]
	for k in color_keys:
		var t: float = float(k.get("time", 0.0))
		var c: Color = k.get("color", Color.WHITE)
		c.a = alpha.sample(t).a
		offs.append(t)
		cols.append(c)
	g.offsets = offs
	g.colors = cols

## TextAsset: a String, a JSON resource, or any Resource with a `text`/`data` property.
func text_asset_text(t) -> String:
	if t is String:
		return t
	if t is JSON:
		return JSON.stringify(t.data)
	if t is Resource:
		var v = t.get("text")
		if v != null:
			return str(v)
		v = t.get("data")
		if v is PackedByteArray:
			return v.get_string_from_utf8()
		if v != null:
			return str(v)
	return str(t) if t != null else ""

func text_asset_bytes(t) -> Array:
	return Array(text_asset_text(t).to_utf8_buffer())

## VRCContactReceiver.CalculateProximity: 1 at the sender's centre, 0 at the receiver's radius.
func contact_proximity(receiver: Node, sender) -> float:
	if receiver == null or sender == null:
		return 0.0
	var rp: Vector3 = get_position(receiver) if receiver is Node3D else Vector3.ZERO
	var sp: Vector3 = Vector3.ZERO
	var sr: float = 0.0
	if sender is Node3D:
		sp = get_position(sender)
		sr = float(prop_get(sender, "radius", 0.0))
	elif sender is Dictionary:
		sp = sender.get("position", Vector3.ZERO)
		sr = float(sender.get("radius", 0.0))
	var rr: float = float(prop_get(receiver, "radius", 0.5))
	var reach: float = maxf(rr + sr, 0.0001)
	return clampf(1.0 - rp.distance_to(sp) / reach, 0.0, 1.0)

## AudioClip.Create: a silent PCM clip of the requested length (fill it with SetData).
func audio_clip_create(name_: String, samples: int, channels: int, frequency: int) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.resource_name = name_
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = maxi(frequency, 1)
	wav.stereo = channels >= 2
	var data := PackedByteArray()
	data.resize(maxi(samples, 0) * 2 * (2 if channels >= 2 else 1))
	wav.data = data
	return wav

func hierarchy_count(n: Node) -> int:
	if n == null:
		return 0
	var c: int = 1
	for ch in n.get_children():
		c += hierarchy_count(ch)
	return c
