## VR player for imported worlds (OpenXR): an XROrigin3D with the headset camera and two
## controllers. Each controller owns a pointer (`Udon.pointer("left" / "right")`) fed with its aim
## ray: the trigger presses world canvases, calls Interact and seats the player in stations, the
## grip grabs and carries VRC pickups (trigger = use while held), the left stick moves, the right
## stick snap-turns, A/X jumps out of a station. It stands in for the VRChat player:
## `IsUserInVR()` is true, tracking data comes from the headset and the controllers, and the VRChat
## input events carry the hand (`UdonInputEventArgs.handType`).
## `simulate = true` skips OpenXR and uses plain nodes as controllers, so scenarios can place the
## hands and call `simulate_button` / `simulate_stick`, which run the same handlers as the device
## signals (scenarios/vr.gd). Real hardware has not been exercised yet.
extends XROrigin3D

@export var simulate: bool = false
@export var move_speed: float = 2.0
@export var snap_turn_degrees: float = 30.0
@export var eye_height: float = 1.6

var camera: Node3D = null
var hands: Dictionary = {}          # "left" / "right" → controller node
var pointers: Dictionary = {}       # "left" / "right" → udon_pointer.gd
var station = null
var spawn_transform: Transform3D = Transform3D()
var respawn_height: float = -100.0
var _sticks: Dictionary = {"left": Vector2.ZERO, "right": Vector2.ZERO}
var _turn_armed: bool = true
var _move_axis: Vector2 = Vector2.ZERO
var _rays: Dictionary = {}


func _ready() -> void:
	if name == "" or name.begins_with("@"):
		name = "VRPlayer"
	var udon: Node = get_node("/root/Udon")
	if simulate:
		camera = Node3D.new()
		camera.position = Vector3(0, eye_height, 0)
		camera.rotation.y = PI  # like the desktop player: Unity's forward is +Z
	else:
		camera = XRCamera3D.new()
	camera.name = "Head"
	add_child(camera)
	for side in ["left", "right"]:
		var c: Node3D
		if simulate:
			c = Node3D.new()
			c.position = Vector3(0.25 if side == "left" else -0.25, eye_height - 0.4, 0.3)
			c.rotation.y = PI
		else:
			var xc := XRController3D.new()
			xc.tracker = StringName(side + "_hand")
			xc.pose = &"aim"
			xc.button_pressed.connect(_on_button.bind(side, true))
			xc.button_released.connect(_on_button.bind(side, false))
			xc.input_vector2_changed.connect(_on_stick.bind(side))
			c = xc
		c.name = side.capitalize() + "Hand"
		add_child(c)
		hands[side] = c
		pointers[side] = udon.pointer(side)
		_rays[side] = _make_ray(c)
	var p = udon.local_player()
	if p != null:
		p.node = self
		p._in_vr = true
		p._eye_height = eye_height
	if not simulate and not _start_xr():
		push_warning("udon_vr_player: OpenXR did not start; the player stays at the origin without tracking")


func _start_xr() -> bool:
	var xr: XRInterface = XRServer.find_interface("OpenXR")
	if xr == null or not xr.initialize():
		return false
	get_viewport().use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	return true


func _make_ray(parent: Node3D) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = "Ray"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.002
	cyl.bottom_radius = 0.002
	cyl.height = 3.0
	m.mesh = cyl
	m.rotation.x = PI * 0.5
	m.position.z = -1.5
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.4, 0.8, 1.0, 0.6)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.material_override = mat
	parent.add_child(m)
	return m


func _process(_delta: float) -> void:
	for side in hands:
		var c: Node3D = hands[side]
		pointers[side].set_ray(c.global_position, -c.global_transform.basis.z)


func _physics_process(delta: float) -> void:
	var udon: Node = get_node("/root/Udon")
	var p = udon.local_player()
	if station != null:
		if station.occupant == null:
			station = null
		else:
			_follow_station()
			return
	var axis: Vector2 = _sticks["left"]
	if axis.length() < 0.15 or (p != null and p.is_immobilized()):
		axis = Vector2.ZERO
	if axis != Vector2.ZERO:
		# move along the head's yaw (Unity's forward is +Z of the rig, the camera looks along it)
		var fwd: Vector3 = -camera.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right: Vector3 = fwd.cross(Vector3.UP)
		global_position += (fwd * axis.y + right * axis.x) * move_speed * delta
	_snap_to_ground()
	if global_position.y < respawn_height:
		global_transform = spawn_transform
		udon.broadcast_event("OnPlayerRespawn", [p])
	if not axis.is_equal_approx(_move_axis):
		if not is_equal_approx(axis.x, _move_axis.x):
			udon.input_event("InputMoveHorizontal", axis.x, 1)
		if not is_equal_approx(axis.y, _move_axis.y):
			udon.input_event("InputMoveVertical", axis.y, 1)
		_move_axis = axis
	var turn: float = _sticks["right"].x
	if absf(turn) > 0.7 and _turn_armed:
		_turn_armed = false
		rotate_y(-deg_to_rad(snap_turn_degrees) * signf(turn))
		udon.input_event("InputLookHorizontal", signf(turn), 0)
	elif absf(turn) < 0.3:
		_turn_armed = true


func _snap_to_ground() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 1.0, 0), global_position - Vector3(0, 2.0, 0))
	var hit: Dictionary = space.intersect_ray(q)
	if not hit.is_empty():
		global_position.y = hit["position"].y


# --- device handlers (OpenXR action names of Godot's default action map) ------------------------

func _on_button(action: String, side: String, pressed: bool) -> void:
	var ptr: Node = pointers[side]
	var udon: Node = get_node("/root/Udon")
	var hand_type: int = 1 if side == "left" else 0
	match action:
		"trigger_click":
			if pressed:
				if ptr.hit.get("kind") == "station" and station == null:
					_sit(ptr.hit["target"])
				else:
					ptr.press(MOUSE_BUTTON_LEFT)
			else:
				ptr.release(MOUSE_BUTTON_LEFT)
		"grip_click":
			if pressed:
				ptr.grab()
			elif ptr.held != null and ptr.held.auto_hold != 1:
				ptr.drop()
		"ax_button":
			if pressed and station != null:
				leave_station()
			udon.input_event("InputJump", pressed, hand_type)


func _on_stick(action: String, value: Vector2, side: String) -> void:
	if action == "primary":
		_sticks[side] = value


## Scenario entry points: the same handlers the controller signals call.
func simulate_button(side: String, action: String, pressed: bool) -> void:
	_on_button(action, side, pressed)

func simulate_stick(side: String, value: Vector2) -> void:
	_on_stick("primary", value, side)


# --- stations -------------------------------------------------------------------------------------

func _sit(target: Node) -> void:
	var udon: Node = get_node("/root/Udon")
	var st = udon.station(target)
	var pl = udon.local_player()
	if st == null or pl == null or st.occupant != null:
		return
	st.use_station(pl)
	sit_in(st)

func sit_in(st) -> void:
	station = st
	_follow_station()

func leave_station() -> void:
	if station == null or station.disable_station_exit:
		return
	var st = station
	station = null
	st.exit_station(get_node("/root/Udon").local_player())

func _follow_station() -> void:
	if station == null or not (station.node is Node3D):
		return
	var loc: Node3D = station.enter_location if station.enter_location != null else station.node
	global_position = loc.global_position


## VRCPlayerApi.GetTrackingData: head = the headset, hands = the controllers, origin = the rig.
func udon_tracking(kind: int) -> Dictionary:
	var u: Node = get_node("/root/U")
	var n: Node3D = self
	match kind:
		0:
			n = camera
		1:
			n = hands["left"]
		2:
			n = hands["right"]
	if n == camera and not simulate:
		return {"position": u.get_position(n), "rotation": u.get_global_rotation(n)}
	# plain nodes look down -Z like cameras and controllers: report Unity's +Z forward
	var b: Basis = n.global_transform.basis.orthonormalized()
	if n != self:
		b = b * Basis(Vector3.UP, PI)
	return {"position": u.from_gd_v(n.global_position), "rotation": u.from_gd_q(b.get_rotation_quaternion())}
