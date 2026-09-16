## Pointer for imported worlds: turns a ray (the camera through the mouse, the view centre when
## the mouse is captured, or a ray a VR controller supplies with `set_ray`) into
##   * mouse events for the world canvas under it (raycast against the `udon_ui_shape` areas of
##     udon_integration, hit from the readable side only, then `SubViewport.push_input` at the
##     pixel `U.ui_world_to_viewport` maps the hit to), including hover enter/exit;
##   * `Interact()` on the behaviour whose collider is hit (within its `proximity`, unless
##     `DisableInteractive`), and pick up / use / drop of `VRC_Pickup` nodes.
## Signals mirror V-Sekai's canvas_plane `function_pointer_receiver` so another picker (Lasso
## snapping for VR) can drive the same sinks through `set_ray`, `press` and `release`.
## Created by `Udon.pointer()`; `world_runner.gd` adds one when a display is present.
extends Node

signal pointer_moved(canvas: Node, world_point: Vector3)
signal pointer_pressed(canvas: Node, world_point: Vector3, button: int)
signal pointer_released(canvas: Node, world_point: Vector3, button: int)
signal hover_changed(target: Node, text: String)

## Furthest hit considered, in metres.
@export var max_distance: float = 10.0
## Physics layers the ray tests (bodies block the pointer; UI areas are found on any layer).
@export var collision_mask: int = 0x7FFFFFFF
## Distance in front of the ray origin at which a held pickup is carried.
@export var hold_distance: float = 0.8
## Ray source: "mouse" (camera through the mouse position, view centre while captured) or
## "custom" (`set_ray`).
var source: String = "mouse"
var enabled: bool = true
## Bodies the ray ignores (the player's own body), as RIDs.
var exclude: Array = []

var ray_origin: Vector3 = Vector3.ZERO
var ray_dir: Vector3 = Vector3.FORWARD
## Last hit: {} or {canvas, px, point, normal, collider, target, kind} (kind: "canvas", "pickup",
## "interact", "solid").
var hit: Dictionary = {}
## Node under the pointer that reacts (behaviour or pickup node), and its prompt text.
var hover_target: Node = null
var hover_text: String = ""
## Pickup adapter of the object currently held, or null.
var held = null
var _held_node: Node3D = null
var _held_offset: Transform3D = Transform3D()
## Window position of the mouse, tracked from the events (the root viewport's
## get_mouse_position() reports the OS cursor and ignores injected events).
var mouse_pos: Vector2 = Vector2.ZERO
var _hover_canvas: Node = null
var _hover_px: Vector2 = Vector2.ZERO
var _mask: int = 0
var _frozen: Variant = null


func _ready() -> void:
	process_priority = -100  # before the behaviours' Update, like Unity's event system
	set_process_input(true)
	set_process_unhandled_input(true)
	if get_viewport() != null:
		mouse_pos = get_viewport().get_mouse_position()


## Track the mouse without consuming anything (GUI may still handle the event).
func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		mouse_pos = event.position


## Drive the pointer from a controller or a scripted test: origin and direction in Godot space.
func set_ray(origin: Vector3, dir: Vector3) -> void:
	source = "custom"
	ray_origin = origin
	ray_dir = dir.normalized()


func _process(_delta: float) -> void:
	if not enabled:
		return
	if source == "mouse" and not _ray_from_mouse():
		return
	_update_hit()
	_carry_held()


## Camera ray through the mouse (or the centre of the view while the mouse is captured).
func _ray_from_mouse() -> bool:
	var vp: Viewport = get_viewport()
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null:
		return false
	var p: Vector2 = mouse_pos
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		p = vp.get_visible_rect().size * 0.5
	ray_origin = cam.project_ray_origin(p)
	ray_dir = cam.project_ray_normal(p)
	return true


## Raycast for the nearest solid body and the nearest readable canvas; the closer one wins.
func _update_hit() -> void:
	var space: PhysicsDirectSpaceState3D = get_viewport().world_3d.direct_space_state if get_viewport() != null else null
	if space == null:
		return
	var to: Vector3 = ray_origin + ray_dir * max_distance
	var q := PhysicsRayQueryParameters3D.create(ray_origin, to, collision_mask)
	q.exclude = Array(exclude, TYPE_RID, "", null)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var body: Dictionary = space.intersect_ray(q)
	var body_d: float = ray_origin.distance_to(body["position"]) if not body.is_empty() else INF
	# areas: only UI shapes count; others are skipped (a few tries)
	var ui: Dictionary = {}
	var aq := PhysicsRayQueryParameters3D.create(ray_origin, to, 0x7FFFFFFF)
	aq.collide_with_areas = true
	aq.collide_with_bodies = false
	var skipped: Array[RID] = []
	for i in range(6):
		aq.exclude = skipped
		var a: Dictionary = space.intersect_ray(aq)
		if a.is_empty():
			break
		var area: Node = a["collider"]
		if area.is_in_group("udon_ui_shape") and area.get_parent() != null and area.get_parent().has_meta("udon_canvas"):
			var cv: Node3D = area.get_parent()
			# readable from the -Z side of the canvas node: the ray must run against that normal
			if ray_dir.dot(cv.global_transform.basis.z) > 0.0 and ray_origin.distance_to(a["position"]) <= body_d:
				ui = a
			break
		skipped.append(a["rid"])
	var new_hit: Dictionary = {}
	if not ui.is_empty():
		var cv: Node = ui["collider"].get_parent()
		var u: Node = get_node("/root/U")
		new_hit = {"kind": "canvas", "canvas": cv, "point": ui["position"], "normal": ui["normal"], "collider": ui["collider"], "px": u.ui_world_to_viewport(cv, u.from_gd_v(ui["position"])), "target": null}
	elif not body.is_empty():
		new_hit = {"kind": "solid", "canvas": null, "point": body["position"], "normal": body["normal"], "collider": body["collider"], "target": null}
		var t: Node = _reactive_ancestor(body["collider"], body_d)
		if t != null:
			new_hit["target"] = t
			new_hit["kind"] = "pickup" if _is_pickup(t) else "interact"
	_apply_hit(new_hit)


## The pickup node or interactable behaviour that owns a collider (unidot puts colliders in helper
## children), or null.
func _reactive_ancestor(collider: Node, dist: float) -> Node:
	var udon: Node = get_node("/root/Udon")
	var n: Node = collider
	var depth: int = 0
	while n != null and depth < 6:
		if udon.has_component(n, "pickup"):
			var pk = udon.pickup(n)
			if pk != null and pk.pickupable and dist <= maxf(pk.proximity, 0.1):
				return n
		if n.has_method("Interact") and n.has_meta("udon_class") and n.get("DisableInteractive") != true and dist <= float(n.get("proximity") if n.get("proximity") != null else 2.0):
			if not n.has_method("udon_has_interact") or n.udon_has_interact():
				return n
		n = n.get_parent()
		depth += 1
	return null


func _is_pickup(n: Node) -> bool:
	return get_node("/root/Udon").has_component(n, "pickup")


func _apply_hit(new_hit: Dictionary) -> void:
	var cv: Node = new_hit.get("canvas")
	if cv != _hover_canvas:
		if _hover_canvas != null:
			_push_motion(_hover_canvas, Vector2(-1e5, -1e5))  # leave: clears hover states
		_hover_canvas = cv
	if cv != null:
		var px: Vector2 = new_hit["px"]
		if px != _hover_px or hit.get("canvas") != cv:
			_push_motion(cv, px)
		_hover_px = px
		pointer_moved.emit(cv, new_hit["point"])
	var target: Node = new_hit.get("target")
	if target != hover_target:
		hover_target = target
		hover_text = ""
		if target != null:
			if new_hit["kind"] == "pickup":
				var pk = get_node("/root/Udon").pickup(target)
				hover_text = str(pk.interaction_text) if pk.interaction_text != "" else "Grab"
			else:
				hover_text = str(target.get("InteractionText"))
		hover_changed.emit(hover_target, hover_text)
	hit = new_hit


func _viewport_of(cv: Node) -> SubViewport:
	if cv == null or not cv.has_meta("udon_canvas"):
		return null
	return cv.get_node_or_null(cv.get_meta("udon_canvas").get("viewport", NodePath())) as SubViewport


func _push_motion(cv: Node, px: Vector2) -> void:
	var vp: SubViewport = _viewport_of(cv)
	if vp == null:
		return
	var e := InputEventMouseMotion.new()
	e.position = px
	e.global_position = px
	e.relative = px - _hover_px
	e.button_mask = _mask
	vp.push_input(e, true)


func _push_button(cv: Node, px: Vector2, button: int, pressed: bool, double_click: bool = false) -> void:
	var vp: SubViewport = _viewport_of(cv)
	if vp == null:
		return
	var e := InputEventMouseButton.new()
	e.position = px
	e.global_position = px
	e.button_index = button
	e.pressed = pressed
	e.double_click = double_click
	e.button_mask = _mask
	vp.push_input(e, true)


## Button press/release from the mouse (`_unhandled_input`), a controller or a test.
func press(button: int = MOUSE_BUTTON_LEFT, double_click: bool = false) -> void:
	_mask |= _mask_of(button)
	if hit.get("kind") == "canvas":
		_push_button(hit["canvas"], hit["px"], button, true, double_click)
		pointer_pressed.emit(hit["canvas"], hit["point"], button)
		return
	pointer_pressed.emit(null, hit.get("point", ray_origin), button)
	var udon: Node = get_node("/root/Udon")
	if button == MOUSE_BUTTON_LEFT:
		if held != null:
			held.use_down()
			udon.input_event("InputUse", true)
		elif hit.get("kind") == "pickup":
			_grab(hit["target"])
		elif hit.get("kind") == "interact":
			udon.input_event("InputUse", true)
			hit["target"].Interact()
		else:
			udon.input_event("InputUse", true)
	elif button == MOUSE_BUTTON_RIGHT and held != null:
		drop()


func release(button: int = MOUSE_BUTTON_LEFT) -> void:
	_mask &= ~_mask_of(button)
	if hit.get("kind") == "canvas":
		_push_button(hit["canvas"], hit["px"], button, false)
		pointer_released.emit(hit["canvas"], hit["point"], button)
		return
	pointer_released.emit(null, hit.get("point", ray_origin), button)
	if button == MOUSE_BUTTON_LEFT:
		if held != null:
			held.use_up()
		get_node("/root/Udon").input_event("InputUse", false)


func _mask_of(button: int) -> int:
	match button:
		MOUSE_BUTTON_LEFT:
			return MOUSE_BUTTON_MASK_LEFT
		MOUSE_BUTTON_RIGHT:
			return MOUSE_BUTTON_MASK_RIGHT
		MOUSE_BUTTON_MIDDLE:
			return MOUSE_BUTTON_MASK_MIDDLE
	return 0


func _unhandled_input(event: InputEvent) -> void:
	if not enabled or source != "mouse":
		return
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		if _ray_from_mouse():
			_update_hit()
		if event.pressed:
			press(event.button_index, event.double_click)
		else:
			release(event.button_index)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G and held != null:
			drop()


# --- pickups ------------------------------------------------------------------------------------

func _grab(node: Node) -> void:
	var udon: Node = get_node("/root/Udon")
	var pk = udon.pickup(node)
	if pk == null or not (node is Node3D):
		return
	held = pk
	_held_node = node
	var carry: Transform3D = _carry_transform()
	_held_offset = carry.affine_inverse() * node.global_transform
	if node is RigidBody3D:
		_frozen = node.freeze
		node.freeze = true
	pk.pick_up(udon.local_player(), 2)
	udon.input_event("InputGrab", true)


func drop() -> void:
	if held == null:
		return
	var udon: Node = get_node("/root/Udon")
	if _held_node is RigidBody3D and _frozen != null:
		_held_node.freeze = _frozen
	held.drop(udon.local_player())
	udon.input_event("InputDrop", true)
	held = null
	_held_node = null
	_frozen = null


func _carry_transform() -> Transform3D:
	var up: Vector3 = Vector3.UP if absf(ray_dir.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	return Transform3D(Basis.looking_at(ray_dir, up), ray_origin + ray_dir * hold_distance)


func _carry_held() -> void:
	if held == null or not is_instance_valid(_held_node):
		held = null
		return
	if not held.is_held:  # dropped by a script
		if _held_node is RigidBody3D and _frozen != null:
			_held_node.freeze = _frozen
		held = null
		return
	_held_node.global_transform = _carry_transform() * _held_offset
