## Runs an imported world scene headless or on screen for smoke tests and screenshots:
##   godot --headless --path <project> -s world_runner.gd -- --scene res://X.tscn [--frames 120] [--quit]
##   godot --display-driver x11 --rendering-method gl_compatibility --path <project> -s world_runner.gd \
##         -- --scene res://X.tscn --frames 240 --shot out.png [--shot-every 60] [--camera "x,y,z" --look "x,y,z"]
##         [--shadows]  (real-time shadows on all lights, substitute for baked lightmaps)
##         [--frame NodePath --view "x,y,z" --dist 1.2 --fov 60]  (frame a node; view = direction to the camera)
##         [--face NodePath [--face-back]]  (camera in front of a world canvas so its UI fills the view)
##   optional: --debug-scripts (guest backtraces with function names)
##             --dump-refs (list converted behaviours and unbound references)
##             --press "NodePath"  (ui_press on a converted control after the scene settled)
##             --call "NodePath:Method"  (call an event on a converted behaviour)
##             --spawn (put a simple player body at the scene descriptor spawn / origin)
##             --play (desktop player: WASD, mouse look, click to use; runs until the window closes
##                     unless --frames is given; scripts/play_world.sh wraps this)
##             --scenario res://scenarios/x.gd  (drive the world; see godot_world_template/scenarios)
extends SceneTree

var _args: Dictionary = {}
var _frame: int = 0
var _frames: int = 120
var _shots: int = 0
var _scene: Node = null
var _errors: int = 0
var _player: Node = null


func _init() -> void:
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < raw.size():
		var a: String = raw[i]
		if a.begins_with("--"):
			var key: String = a.substr(2)
			if i + 1 < raw.size() and not raw[i + 1].begins_with("--"):
				_args[key] = raw[i + 1]
				i += 1
			else:
				_args[key] = true
		i += 1
	_frames = int(_args.get("frames", 120))
	ProjectSettings.set_setting("sandbox/binary_translation/auto_bake", false)
	await process_frame
	await process_frame
	var path: String = str(_args.get("scene", ""))
	if path == "":
		push_error("world_runner: --scene is required")
		quit(2)
		return
	if _args.has("debug-scripts"):
		_debug_scripts()
	var ps = load(path)
	if ps == null:
		push_error("world_runner: cannot load " + path)
		quit(2)
		return
	_scene = ps.instantiate()
	root.add_child(_scene)
	current_scene = _scene
	print("[world_runner] loaded %s: %d nodes, %d converted behaviours" % [path, _count(_scene), _count_udon(_scene)])
	if _args.has("dump-refs"):
		_dump_refs(_scene)
	if _args.has("camera"):
		_place_camera(_parse_v3(str(_args["camera"])), _parse_v3(str(_args.get("look", "0,0,0"))))
	elif _args.has("frame"):
		_frame_node(str(_args["frame"]))
	elif _args.has("face"):
		_face_canvas(str(_args["face"]))
	if _args.has("spawn"):
		_spawn_player()
	if _args.has("play"):
		_spawn_desktop_player()
	if DisplayServer.get_name() != "headless" or _args.has("pointer"):
		root.get_node("Udon").pointer()
	if _args.has("play") and not _has_visible_light():
		_add_light()
	if _args.has("light") or (_args.has("shot") and not _has_visible_light()):
		_add_light()
	if _args.has("shadows"):
		_enable_shadows()
	var scenario_ok: bool = true
	if _args.has("scenario"):
		scenario_ok = await _run_scenario(str(_args["scenario"]))
	var limit: int = 0 if _args.has("play") and not _args.has("frames") else _frames
	while limit == 0 or _frame < limit:
		await process_frame
		_frame += 1
		if _frame == 30:
			_interact()
		if _args.has("shot") and _args.has("shot-every") and _frame % int(_args["shot-every"]) == 0:
			await _screenshot(str(_args["shot"]).get_basename() + "_%04d.png" % _frame)
	if _args.has("shot"):
		await _screenshot(str(_args["shot"]))
	print("[world_runner] done after %d frames, %d screenshot(s)" % [_frame, _shots])
	quit(0 if scenario_ok else 1)


# --- scenarios: a GDScript with `func run(runner) -> void` that drives the world ----------------
var _checks: int = 0
var _failures: Array = []

func _run_scenario(path: String) -> bool:
	var scr = load(path)
	if scr == null:
		push_error("world_runner: cannot load scenario " + path)
		return false
	var scen = scr.new()
	print("[scenario] " + path)
	await scen.run(self)
	print("[scenario] %d checks, %d failure(s)" % [_checks, _failures.size()])
	for f in _failures:
		print("   FAIL " + f)
	print("SCENARIO " + ("PASSED" if _failures.is_empty() else "FAILED"))
	return _failures.is_empty()

func check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures.append(what)

func wait(frames: int) -> void:
	for i in range(frames):
		await process_frame
		_frame += 1

func find(name_or_path: String) -> Node:
	if _scene.has_node(name_or_path):
		return _scene.get_node(name_or_path)
	return _scene.find_child(name_or_path, true, false)

## First visible button (BaseButton) of that name; Unity menus often wrap a button in a container of
## the same name, which `find` would return.
func find_button(name: String) -> BaseButton:
	for n in _all(_scene):
		if n is BaseButton and String(n.name) == name and n.is_visible_in_tree():
			return n
	return null

## First converted behaviour of a class.
func behaviour(cls: String) -> Node:
	for n in _all(_scene):
		if n.has_meta("udon_class") and str(n.get_meta("udon_class")) == cls:
			return n
	return null

func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out

func shot(tag: String) -> void:
	if _args.has("shot"):
		await _screenshot(str(_args["shot"]).get_basename() + "_" + tag + ".png")

func u() -> Node:
	return root.get_node("U")

## The current camera: the player's or the game's when one is active, else the runner's
## (created by --camera/--frame/--face or on demand).
func camera() -> Camera3D:
	var cam: Camera3D = root.get_viewport().get_camera_3d()
	if cam == null:
		cam = root.get_node_or_null("RunnerCamera")
	if cam == null:
		_place_camera(Vector3(0, 1.6, -2), Vector3(0, 1.5, 3))
		cam = root.get_node("RunnerCamera")
	return cam

## Window pixel of a world point (Godot space) through the runner's camera.
func project(p: Vector3) -> Vector2:
	return camera().unproject_position(p)

## Grab the rendered frame (null when headless).
func capture() -> Image:
	await process_frame
	await process_frame
	return root.get_viewport().get_texture().get_image()

## Colour of the rendered frame at a window pixel (transparent black when headless).
func pixel(px: Vector2) -> Color:
	var img: Image = await capture()
	if img == null or px.x < 0 or px.y < 0 or px.x >= img.get_width() or px.y >= img.get_height():
		return Color(0, 0, 0, 0)
	return img.get_pixelv(Vector2i(int(px.x), int(px.y)))

## Real input through the window: a mouse move to a window pixel, a click there, a key tap.
var _mouse_px: Vector2 = Vector2.ZERO

func mouse_move(px: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = px
	e.global_position = px
	e.relative = px - _mouse_px
	_mouse_px = px
	Input.parse_input_event(e)
	await process_frame

## Relative mouse motion without moving the cursor (mouse look, Unity's Mouse X / Mouse Y axes).
func mouse_delta(d: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = _mouse_px
	e.global_position = _mouse_px
	e.relative = d
	Input.parse_input_event(e)
	await process_frame

## Marks the last click on screenshots: a small ring drawn on a HUD layer for a while.
var _marks: CanvasLayer = null

func _mark_click(px: Vector2) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if _marks == null:
		_marks = CanvasLayer.new()
		_marks.name = "ClickMarks"
		_marks.layer = 120
		root.add_child(_marks)
	var m := Control.new()
	m.name = "Mark"
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.position = px
	m.draw.connect(func():
		m.draw_arc(Vector2.ZERO, 9.0, 0.0, TAU, 32, Color(1, 0.2, 0.2, 0.95), 3.0)
		m.draw_line(Vector2(-14, 0), Vector2(14, 0), Color(1, 0.2, 0.2, 0.95), 2.0)
		m.draw_line(Vector2(0, -14), Vector2(0, 14), Color(1, 0.2, 0.2, 0.95), 2.0))
	_marks.add_child(m)
	create_timer(2.0).timeout.connect(m.queue_free)

## Press or release a mouse button at the current cursor position.
func mouse_button(pressed: bool, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	if pressed:
		_mark_click(_mouse_px)
	var e := InputEventMouseButton.new()
	e.position = _mouse_px
	e.global_position = _mouse_px
	e.button_index = button
	e.pressed = pressed
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
	Input.parse_input_event(e)
	await process_frame

## World point (Godot space) at the centre of a control on a world canvas.
func control_world(ctl: Control) -> Vector3:
	var uu: Node = u()
	var cv: Node = uu._ui_world_canvas(ctl)
	var px: Vector2 = ctl.get_global_transform() * (ctl.size * 0.5)
	return uu.to_gd_v(uu.ui_viewport_to_world(cv, px))

## Look at a control of a world canvas (desktop player) and click it through the window.
func click_control(ctl: Control) -> void:
	var w: Vector3 = control_world(ctl)
	if _player != null:
		_player.look_at_point(w)
		await process_frame
		await process_frame
	await click(project(w))

## Stand the desktop player `dist` metres in front of a world-canvas control (its readable side)
## and look at it.
func face_control(ctl: Control, dist: float = 1.5) -> void:
	var cv: Node3D = u()._ui_world_canvas(ctl)
	var w: Vector3 = control_world(ctl)
	var normal: Vector3 = -cv.global_transform.basis.z.normalized() if cv != null else Vector3.FORWARD
	normal.y = 0.0
	await place_player(w + normal.normalized() * dist)
	if _player != null:
		_player.look_at_point(w)
		await process_frame

## Put the desktop player at a point (Godot space), on the ground below it.
func place_player(pos: Vector3) -> void:
	if _player == null:
		return
	var space: PhysicsDirectSpaceState3D = root.get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 2.0, 0), pos - Vector3(0, 50.0, 0))
	q.exclude = [_player.get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	if not hit.is_empty():
		pos.y = hit["position"].y + 0.05
	_player.global_position = pos
	_player.velocity = Vector3.ZERO
	await process_frame

func click(px: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	await mouse_move(px)
	for pressed in [true, false]:
		await mouse_button(pressed, button)
	await process_frame

func key(keycode: Key, hold_frames: int = 1, unicode: int = 0) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = keycode
		e.physical_keycode = keycode
		e.pressed = pressed
		e.unicode = unicode
		Input.parse_input_event(e)
		for i in range(hold_frames):
			await process_frame

## Type text: one key event per character (letters, digits, space), then Enter when `submit`.
func type_text(text: String, submit: bool = true) -> void:
	for ch in text:
		var code: int = ch.unicode_at(0)
		var keycode: Key = (OS.find_keycode_from_string(ch.to_upper()) as Key) if ch != " " else KEY_SPACE
		await key(keycode, 1, code)
	if submit:
		await key(KEY_ENTER)

## World point (Godot space) at a fraction of a control's rect on a world canvas (0..1, top-left origin).
func control_world_at(ctl: Control, frac: Vector2) -> Vector3:
	var uu: Node = u()
	var cv: Node = uu._ui_world_canvas(ctl)
	var px: Vector2 = ctl.get_global_transform() * (ctl.size * frac)
	return uu.to_gd_v(uu.ui_viewport_to_world(cv, px))

func udon() -> Node:
	return root.get_node("Udon")


func _interact() -> void:
	if _args.has("press"):
		for p in str(_args["press"]).split(";"):
			var n: Node = _scene.get_node_or_null(p) if _scene.has_node(p) else _scene.find_child(p.get_file(), true, false)
			if n == null:
				print("[world_runner] press: no node " + p)
			else:
				root.get_node("U").ui_press(n)
				print("[world_runner] pressed " + p)
	if _args.has("call"):
		for c in str(_args["call"]).split(";"):
			var parts: PackedStringArray = c.split(":")
			var n: Node = _scene.get_node_or_null(parts[0])
			if n != null and parts.size() > 1 and n.has_method(parts[1]):
				n.call(parts[1])
				print("[world_runner] called " + c)
			else:
				print("[world_runner] call: cannot resolve " + c)


func _spawn_player() -> void:
	var udon: Node = root.get_node("Udon")
	var body := CharacterBody3D.new()
	body.name = "LocalPlayerBody"
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.6
	cap.radius = 0.25
	cs.shape = cap
	body.add_child(cs)
	root.add_child(body)
	var spawn: Node3D = null
	for n in _scene.find_children("*", "Node3D", true, false):
		if n.has_meta("udon_scene_descriptor"):
			var cfg: Dictionary = n.get_meta("udon_scene_descriptor")
			var sp: Array = cfg.get("spawns", [])
			if not sp.is_empty():
				spawn = n.get_node_or_null(sp[0])
			break
	body.global_position = spawn.global_position if spawn != null else Vector3(0, 1, 0)
	var p = udon.local_player()
	if p != null:
		p.node = body
	print("[world_runner] player body at " + str(body.global_position))


## The desktop player spawned by --play (or null).
func player() -> Node:
	return _player

## Spawn point of the world: the scene descriptor's first spawn, else the origin, snapped onto the
## ground below (a spawn marker inside a floor collider would otherwise start the body in a wall).
func _spawn_transform() -> Transform3D:
	var t: Transform3D = Transform3D(Basis(), Vector3(0, 0.1, 0))
	for n in _scene.find_children("*", "Node3D", true, false):
		if n.has_meta("udon_scene_descriptor"):
			var cfg: Dictionary = n.get_meta("udon_scene_descriptor")
			var sp: Array = cfg.get("spawns", [])
			if not sp.is_empty():
				var spawn: Node3D = n.get_node_or_null(sp[0])
				if spawn != null:
					var st: Transform3D = spawn.global_transform
					t = Transform3D(Basis(Vector3.UP, st.basis.get_euler().y), st.origin)
			break
	var space: PhysicsDirectSpaceState3D = root.get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(t.origin + Vector3(0, 2.0, 0), t.origin - Vector3(0, 50.0, 0))
	var hit: Dictionary = space.intersect_ray(q)
	if not hit.is_empty():
		t.origin.y = hit["position"].y + 0.05
	return t

func _spawn_desktop_player() -> void:
	var body: CharacterBody3D = load("res://addons/udon_runtime/udon_desktop_player.gd").new()
	body.name = "DesktopPlayer"
	body.capture_mouse = DisplayServer.get_name() != "headless" and not _args.has("scenario")
	root.add_child(body)
	body.global_transform = _spawn_transform()
	_player = body
	print("[world_runner] desktop player at " + str(body.global_position))
func _frame_node(path: String) -> void:
	var n: Node = _scene if path == "." else (_scene.get_node_or_null(path) if _scene.has_node(path) else _scene.find_child(path, true, false))
	if n == null:
		print("[world_runner] frame: no node " + path)
		return
	var aabb := AABB()
	var first := true
	for vi in n.find_children("*", "VisualInstance3D", true, false):
		if not vi.is_visible_in_tree() or String(vi.name).begins_with("CanvasPlane"):
			continue
		var b: AABB = vi.get_global_transform() * vi.get_aabb()
		aabb = b if first else aabb.merge(b)
		first = false
	if first:
		print("[world_runner] frame: no visible geometry under " + path)
		return
	var center: Vector3 = aabb.get_center()
	var radius: float = maxf(aabb.size.length() * 0.5, 0.5)
	var dir: Vector3 = Vector3(-0.55, 0.65, -0.55).normalized()
	if _args.has("view"):
		dir = _parse_v3(str(_args["view"])).normalized()
	# --dist scales the distance (1.9 radii by default), --fov the camera's field of view
	var dist: float = float(_args.get("dist", 1.9))
	_place_camera(center + dir * radius * dist, center)
	if _args.has("fov"):
		root.get_node("RunnerCamera").fov = float(_args["fov"])
	print("[world_runner] framed %s: center=%s size=%s" % [path, str(center), str(aabb.size)])


## Put the camera in front of a world canvas (its readable side, or the back with --face-back) so
## the fitted plane fills the view.
func _face_canvas(path: String) -> void:
	var n: Node = _scene.get_node_or_null(path) if _scene.has_node(path) else _scene.find_child(path, true, false)
	if n == null or not n.has_meta("udon_canvas"):
		print("[world_runner] face: no world canvas at " + path)
		return
	var cfg: Dictionary = n.get_meta("udon_canvas")
	var plane: MeshInstance3D = n.get_node_or_null(cfg.get("plane", NodePath()))
	if plane == null:
		print("[world_runner] face: canvas without plane " + path)
		return
	var aabb: AABB = plane.get_global_transform() * plane.get_aabb()
	var center: Vector3 = aabb.get_center()
	var normal: Vector3 = -n.global_transform.basis.z.normalized()
	if _args.has("face-back"):
		normal = -normal
	var gs: Vector3 = n.global_transform.basis.get_scale()
	var units: Vector2 = cfg.get("plane_size", cfg.get("size", Vector2.ONE))
	var size: Vector2 = Vector2(units.x * gs.x, units.y * gs.y)
	var fov: float = float(_args.get("fov", 60))
	var dist: float = maxf(size.x, size.y * 16.0 / 9.0) * 0.5 / tan(deg_to_rad(fov) * 0.5) * float(_args.get("dist", 1.1))
	_place_camera(center + normal * dist, center)
	root.get_node("RunnerCamera").fov = fov
	print("[world_runner] facing %s: center=%s size=%.2fx%.2f m normal=%s" % [path, str(center), size.x, size.y, str(normal)])


func _has_visible_light() -> bool:
	for l in _scene.find_children("*", "Light3D", true, false):
		if l.is_visible_in_tree():
			return true
	return false


## `--shadows`: real-time shadows on every light. Unity worlds bake their shadows into lightmaps,
## which cannot be imported; this is the closest substitute for screenshots.
func _enable_shadows() -> void:
	var n: int = 0
	for l in _scene.find_children("*", "Light3D", true, false):
		if not l.shadow_enabled:
			l.shadow_enabled = true
			n += 1
	print("[world_runner] shadows enabled on %d light(s)" % n)


## Fallback lighting for screenshots of worlds whose lighting was baked in Unity.
func _add_light() -> void:
	var l := DirectionalLight3D.new()
	l.name = "RunnerLight"
	l.rotation_degrees = Vector3(-50, 30, 0)
	l.light_energy = 1.2
	l.shadow_enabled = true
	root.add_child(l)
	var env: Environment = null
	var we: WorldEnvironment = null
	for w in _scene.find_children("*", "WorldEnvironment", true, false):
		we = w
		break
	if we != null and we.environment != null:
		env = we.environment
	else:
		env = Environment.new()
		var wn := WorldEnvironment.new()
		wn.name = "RunnerEnvironment"
		wn.environment = env
		root.add_child(wn)
	if env.background_mode == Environment.BG_CLEAR_COLOR or env.background_mode == Environment.BG_COLOR:
		env.background_mode = Environment.BG_COLOR
		if env.background_color.get_luminance() < 0.05:
			env.background_color = Color(0.35, 0.4, 0.5)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	print("[world_runner] added fallback light and ambient")


func _place_camera(pos: Vector3, look: Vector3) -> void:
	var cam: Camera3D = root.get_node_or_null("RunnerCamera")
	if cam == null:
		cam = Camera3D.new()
		cam.name = "RunnerCamera"
		# unidot maps Unity layers onto Godot visual layers beyond the default cull mask
		cam.cull_mask = 0xFFFFFFFF
		root.add_child(cam)
	cam.global_position = pos
	if not look.is_equal_approx(pos):
		cam.look_at(look, Vector3.UP)
	cam.make_current()


func _parse_v3(s: String) -> Vector3:
	var p: PackedStringArray = s.split(",")
	if p.size() < 3:
		return Vector3.ZERO
	return Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float())


func _screenshot(path: String) -> void:
	if _args.has("frame"):
		_frame_node(str(_args["frame"]))
	elif _args.has("face"):
		_face_canvas(str(_args["face"]))
	var cam: Camera3D = root.get_node_or_null("RunnerCamera")
	if cam != null:
		# world scripts may activate their own cameras (desktop views); screenshots use ours
		for c in root.find_children("*", "Camera3D", true, false):
			if c != cam and c.current:
				c.current = false
		cam.current = true
		await process_frame
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	if img == null:
		print("[world_runner] no image (headless?)")
		return
	img.save_png(path)
	_shots += 1
	print("[world_runner] screenshot " + path)


## Print every converted behaviour with the state of its object references (null = not bound).
func _dump_refs(n: Node) -> void:
	if n.has_meta("udon_class"):
		var line: String = "  %s [%s]" % [str(_scene.get_path_to(n)), str(n.get_meta("udon_class"))]
		var bad: Array = []
		if n.has_meta("udon_refs"):
			var refs: Dictionary = n.get_meta("udon_refs")
			for k in refs.keys():
				var v = n.get(str(k))
				if v == null:
					bad.append(str(k) + "=null")
				elif v is Array:
					var nulls: int = 0
					for e in v:
						if e == null:
							nulls += 1
					if nulls > 0:
						bad.append("%s[%d/%d null]" % [str(k), nulls, v.size()])
		print(line + ("  UNBOUND: " + ", ".join(bad) if not bad.is_empty() else ""))
	for c in n.get_children():
		_dump_refs(c)


## Rebuild every converted script with debug information (the sandbox does that when a script has
## breakpoints; line 1 is a comment, so nothing halts) so guest backtraces name their functions.
func _debug_scripts() -> void:
	var manifest: String = str(ProjectSettings.get_setting("udon/manifest", "res://converted/udon_manifest.json"))
	var dir := DirAccess.open(manifest.get_base_dir())
	if dir == null:
		return
	var n: int = 0
	for f in dir.get_files():
		if f.ends_with(".sgd"):
			var scr = load(manifest.get_base_dir().path_join(f))
			if scr != null and scr.has_method("set_breakpoints"):
				scr.set_breakpoints(PackedInt32Array([1]))
				n += 1
	print("[world_runner] debug builds for %d scripts" % n)


func _count(n: Node) -> int:
	var c: int = 1
	for ch in n.get_children():
		c += _count(ch)
	return c


func _count_udon(n: Node) -> int:
	var c: int = 1 if n.has_meta("udon_class") else 0
	for ch in n.get_children():
		c += _count_udon(ch)
	return c
