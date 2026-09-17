## Desktop player for imported worlds: a CharacterBody3D with a first-person camera standing in
## for the VRChat player. WASD / arrows move, Shift runs, Space jumps, the mouse looks while it is
## captured; Esc or Tab frees it so canvases can be clicked with the cursor (while captured the
## pointer follows the view centre). Provides VRCPlayerApi data through Udon.local_player().node
## (position, velocity, grounded) and `udon_tracking` (head = camera, hands beside it), raises the
## VRChat input events (InputJump, InputMoveHorizontal/Vertical, InputLookHorizontal/Vertical)
## and shows the pointer's prompt. Spawned by world_runner.gd --play / scripts/play_world.sh; a
## game can add its own instance. Unity's forward is +Z here (unidot mirrors X only), so the
## camera looks along the body's +Z and screen-right is the body's -X.
extends CharacterBody3D

@export var eye_height: float = 1.6
## Degrees of turn per pixel of mouse motion.
@export var mouse_sensitivity: float = 0.15
@export var capture_mouse: bool = true
@export var show_hud: bool = true

var head: Node3D = null
var camera: Camera3D = null
var _hud: CanvasLayer = null
var _prompt: Label = null
var _pitch: float = 0.0
var _move_axis: Vector2 = Vector2.ZERO
## Seconds a jump request stays pending: floor contact can flicker for a frame (Jolt reports it a
## step later than Godot Physics when the body stops), and a one-frame request would be lost.
const JUMP_BUFFER: float = 0.15
var _jump_queued: float = 0.0
## Station adapter (udon_station.gd) the player sits in, or null.
var station = null
## Where the player respawns and below which height (VRC_SceneDescriptor.RespawnHeightY).
var spawn_transform: Transform3D = Transform3D(Basis(), Vector3(0, 1, 0))
var respawn_height: float = -100.0


func _ready() -> void:
	if name == "" or name.begins_with("@"):
		name = "DesktopPlayer"
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.3
	cs.shape = cap
	cs.position.y = 0.9
	add_child(cs)
	head = Node3D.new()
	head.name = "Head"
	head.position.y = eye_height
	add_child(head)
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.cull_mask = 0xFFFFFFFF  # unidot maps Unity layers onto visual layers beyond the default mask
	camera.near = 0.05
	camera.rotation.y = PI  # Godot cameras look down -Z; Unity's player looks along +Z
	head.add_child(camera)
	camera.make_current()
	floor_snap_length = 0.1
	var udon: Node = get_node("/root/Udon")
	var p = udon.local_player()
	if p != null:
		p.node = self
		p._eye_height = eye_height
	var ptr: Node = udon.pointer()
	ptr.exclude = [get_rid()]
	ptr.hover_changed.connect(_on_hover)
	if show_hud:
		_build_hud()
	if capture_mouse:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "HUD"
	_hud.layer = 100
	add_child(_hud)
	var cross := Label.new()
	cross.name = "Crosshair"
	cross.text = "+"
	cross.set_anchors_preset(Control.PRESET_CENTER)
	cross.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cross.grow_vertical = Control.GROW_DIRECTION_BOTH
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(cross)
	_prompt = Label.new()
	_prompt.name = "Prompt"
	_prompt.set_anchors_preset(Control.PRESET_CENTER)
	_prompt.position.y += 24
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_prompt)
	var help := Label.new()
	help.name = "Help"
	help.text = "WASD move  Shift run  Space jump  click use/grab  right click / G drop  Esc/Tab mouse"
	help.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	help.position = Vector2(8, -28)
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	help.modulate.a = 0.6
	_hud.add_child(help)


func _on_hover(_target: Node, text: String) -> void:
	if _prompt != null:
		_prompt.text = text


func set_mouse_captured(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
	if _hud != null:
		_hud.get_node("Crosshair").visible = captured


func _unhandled_input(event: InputEvent) -> void:
	var udon: Node = get_node("/root/Udon")
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-deg_to_rad(event.relative.x * mouse_sensitivity))
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -89.0, 89.0)
		head.rotation.x = deg_to_rad(-_pitch)
		udon.input_event("InputLookHorizontal", clampf(event.relative.x * 0.02, -1.0, 1.0))
		udon.input_event("InputLookVertical", clampf(-event.relative.y * 0.02, -1.0, 1.0))
	elif event is InputEventKey and not event.echo:
		if event.pressed and (event.keycode == KEY_ESCAPE or event.keycode == KEY_TAB):
			set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
		elif event.keycode == KEY_SPACE:
			if event.pressed:
				if station != null:
					leave_station()
				else:
					_jump_queued = JUMP_BUFFER
			udon.input_event("InputJump", event.pressed)


## Sit in a station (called by the pointer after use_station): the body follows the station's
## enter location (vehicles move) and locomotion stops until Space exits it.
func sit_in(st) -> void:
	station = st
	velocity = Vector3.ZERO
	_follow_station()

func leave_station() -> void:
	if station == null:
		return
	if station.disable_station_exit:
		return
	var st = station
	station = null
	st.exit_station(get_node("/root/Udon").local_player())

func _follow_station() -> void:
	if station == null or not (station.node is Node3D):
		return
	var loc: Node3D = station.enter_location if station.enter_location != null else station.node
	global_position = loc.global_position
	if station.seated:
		rotation.y = loc.global_transform.basis.get_euler().y

func _physics_process(delta: float) -> void:
	var udon: Node = get_node("/root/Udon")
	var p = udon.local_player()
	if station != null:
		if station.occupant == null:  # left by a script (ExitStation)
			station = null
		else:
			_follow_station()
			_jump_queued = 0.0
			return
	var loco: Dictionary = p._locomotion if p != null else {"walk_speed": 2.0, "run_speed": 4.0, "strafe_speed": 2.0, "jump_impulse": 3.0, "gravity_strength": 1.0}
	var axis := Vector2.ZERO
	if p == null or not p.is_immobilized():
		axis.x = (1.0 if Input.is_physical_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT) else 0.0) - (1.0 if Input.is_physical_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT) else 0.0)
		axis.y = (1.0 if Input.is_physical_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) else 0.0) - (1.0 if Input.is_physical_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) else 0.0)
	var run: bool = Input.is_key_pressed(KEY_SHIFT)
	var fwd_speed: float = float(loco.get("run_speed", 4.0)) if run else float(loco.get("walk_speed", 2.0))
	var side_speed: float = float(loco.get("strafe_speed", 2.0))
	var dir: Vector3 = global_transform.basis * Vector3(-axis.x * side_speed, 0.0, axis.y * fwd_speed)
	velocity.x = dir.x
	velocity.z = dir.z
	var gravity: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * float(loco.get("gravity_strength", 1.0))
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif _jump_queued > 0.0 and (p == null or not p.is_immobilized()):
		velocity.y = float(loco.get("jump_impulse", 3.0))
		_jump_queued = 0.0
	_jump_queued = maxf(_jump_queued - delta, 0.0)
	move_and_slide()
	_respawn_if_fallen()
	if not axis.is_equal_approx(_move_axis):
		if not is_equal_approx(axis.x, _move_axis.x):
			udon.input_event("InputMoveHorizontal", axis.x)
		if not is_equal_approx(axis.y, _move_axis.y):
			udon.input_event("InputMoveVertical", axis.y)
		_move_axis = axis


## Turn the body and head so the camera looks at a world point (Godot space).
func look_at_point(p: Vector3) -> void:
	var d: Vector3 = p - camera.global_position
	if d.length() < 1e-4:
		return
	rotation = Vector3(0.0, atan2(d.x, d.z), 0.0)
	_pitch = rad_to_deg(atan2(d.y, Vector2(d.x, d.z).length()))
	head.rotation.x = deg_to_rad(-_pitch)


## Respawn when fallen out of the world (VRChat's respawn height).
func _respawn_if_fallen() -> void:
	if global_position.y < respawn_height:
		global_transform = spawn_transform
		velocity = Vector3.ZERO
		var udon: Node = get_node("/root/Udon")
		udon.broadcast_event("OnPlayerRespawn", [udon.local_player()])


## VRCPlayerApi.GetTrackingData: head = the camera, hands beside it, origin/avatar root = the body.
func udon_tracking(kind: int) -> Dictionary:
	var u: Node = get_node("/root/U")
	match kind:
		0:
			return {"position": u.get_position(camera), "rotation": u.get_global_rotation(camera)}
		1, 2:
			var side: float = 0.25 if kind == 1 else -0.25  # screen-left is the body's +X
			var pos: Vector3 = head.global_transform * Vector3(side, -0.3, 0.4)
			return {"position": u.from_gd_v(pos), "rotation": u.get_global_rotation(camera)}
		_:
			return {"position": u.get_position(self), "rotation": u.get_global_rotation(self)}
