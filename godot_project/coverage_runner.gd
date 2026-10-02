extends SceneTree
## Runs the converted coverage fixtures (tests/coverage/*.cs → converted_coverage/*.sgd).
## Each fixture exposes `RunTests()`, optionally `AfterFrames()`, and the fields
## `failures`, `failCount`, `total`. The runner builds the scene nodes each fixture expects.

var _U: Node
var _Udon: Node
var total_fail: int = 0
var total_checks: int = 0

func _init() -> void:
	ProjectSettings.set_setting("sandbox/binary_translation/auto_bake", false)
	await process_frame
	await process_frame
	_U = root.get_node("U")
	_Udon = root.get_node("Udon")
	var only: Array = OS.get_cmdline_user_args()
	var names: Array = ["TCoord", "TMath", "TMathB", "TStrings", "TArrays", "TTransform", "TPhysics", "TMedia", "TUI", "TRect", "TWidgets", "TVRC", "T2D", "TParticles", "TSystem", "TNav", "TAnim", "TExt", "TOverloads", "TNulls"]
	for n in names:
		if not only.is_empty() and not only.has(n):
			continue
		await run_fixture(n)
	print("COVERAGE DONE: %d checks, %d failure(s)" % [total_checks, total_fail])
	quit(mini(total_fail, 125))

func run_fixture(name: String) -> void:
	var path := "res://converted_coverage/%s.sgd" % name
	var script = load(path)
	if script == null:
		print("== %s: LOAD FAILED" % name)
		total_fail += 1
		return
	var host := Node3D.new()
	host.name = "Host_" + name
	root.add_child(host)
	var target := Node3D.new()
	target.name = "T"
	target.set_script(script)
	_build_scene(name, target, host)
	host.add_child(target)
	if not target.has_method("RunTests"):
		print("== %s: COMPILE FAILED" % name)
		total_fail += 1
		host.queue_free()
		return
	_wire(name, target, host, script)
	await process_frame
	await process_frame
	if name == "TNav":
		# the navigation map syncs on physics ticks
		for i in range(3):
			await physics_frame
	if name == "TCoord" or name == "TRect":
		_U.coord_mode = _U.CoordMode.UNIDOT
	target.call("RunTests")
	var extra: Array = []
	if name == "TRect":
		_U.coord_mode = _U.CoordMode.UNITY
	if name == "TCoord":
		_U.coord_mode = _U.CoordMode.UNITY
		if not target.global_position.is_equal_approx(Vector3(-1, 2, 3)):
			extra.append("Godot node position is the mirror of the Unity one: " + str(target.global_position))
		var camn: Node3D = host.get_node("CamGO/Camera")
		if not (-camn.global_transform.basis.z).is_equal_approx(Vector3(-1, 0, 0)):
			extra.append("Godot camera looks along the mirrored Unity forward: " + str(-camn.global_transform.basis.z))
	extra.append_array(_godot_checks(name, target, host))
	if not extra.is_empty():
		var fc0: int = int(target.get("failCount"))
		var fl: Array = target.get("failures")
		for e in extra:
			fl[fc0] = e
			fc0 += 1
		target.set("failCount", fc0)
		target.set("total", int(target.get("total")) + extra.size())
	if target.has_method("AfterFrames"):
		if name == "TRect":
			_U.coord_mode = _U.CoordMode.UNIDOT
		if name == "TVRC":
			# a remote player joins after the tests ran
			var p = load("res://addons/udon_runtime/udon_player.gd").new()
			p.player_id = 2
			p.display_name = "Remote"
			_Udon.provider.add_player(p)
		# physics fixtures wait for real physics steps (headless process frames can outrun them)
		var physics: bool = name in ["TPhysics", "T2D"]
		var frames: int = 90 if physics else 8
		# at least `frames` frames and 150 ms: fixtures schedule SendCustomEventDelayedSeconds(0.05),
		# and headless process frames take anything from 1 ms to tens of ms depending on the load
		var t0: int = Time.get_ticks_msec()
		var i: int = 0
		while i < frames or Time.get_ticks_msec() - t0 < 150:
			if physics:
				await physics_frame
			else:
				await process_frame
			i += 1
		target.call("AfterFrames")
		if name == "TRect":
			_U.coord_mode = _U.CoordMode.UNITY
	var late: Array = _godot_checks_late(name, target, host)
	if not late.is_empty():
		var fc1: int = int(target.get("failCount"))
		var fl1: Array = target.get("failures")
		for e in late:
			fl1[fc1] = e
			fc1 += 1
		target.set("failCount", fc1)
		target.set("total", int(target.get("total")) + late.size())
	var fc: int = int(target.get("failCount"))
	var tot: int = int(target.get("total"))
	var fails: Array = target.get("failures")
	var done: bool = bool(target.get("done"))
	total_fail += fc
	total_checks += tot
	print("== %s: %d/%d passed%s" % [name, tot - fc, tot, "" if done else "  (ABORTED: RunTests did not finish)"])
	if not done:
		total_fail += 1
	for i in range(fc):
		print("   FAIL %s" % str(fails[i]))
	host.queue_free()
	await process_frame

## Engine-side checks that need the frames after RunTests (solvers, physics).
func _godot_checks_late(name: String, target: Node3D, _host: Node3D) -> Array:
	var out: Array = []
	match name:
		"TWidgets":
			# what the script set is what the controls draw
			var wroot: Control = _U.RT.root_control(_host.get_node("Canvas"))
			var label: RichTextLabel = wroot.get_node("Label")
			if label.get_parsed_text() != "LOCALPLAYER WON":
				out.append("the text set by the script is drawn without tags, cased by its style: " + label.get_parsed_text())
			if not label.text.contains("[font_size=13]") or not label.text.contains("[color=#FFD700]") or not label.text.begins_with("[b]"):
				out.append("... as BBCode: " + label.text)
			if label.get_theme_font_size("normal_font_size") != 25:
				out.append("font size 24.5 is drawn at 25: %d" % label.get_theme_font_size("normal_font_size"))
			if not label.get_theme_color("default_color").is_equal_approx(Color(1, 0, 0, 0.5)) or not is_equal_approx(label.self_modulate.a, 1.0):
				out.append("text colour drawn: %s, modulate %s" % [str(label.get_theme_color("default_color")), str(label.self_modulate)])
			var fitted: RichTextLabel = wroot.get_node("Fitted")
			var fs: int = fitted.get_theme_font_size("normal_font_size")
			if fs >= 60 or fs < 8 or fitted.get_content_height() > 30.5:
				out.append("the auto-sized text is fitted to its rect: size %d, content height %d" % [fs, fitted.get_content_height()])
			var image: TextureRect = wroot.get_node("Image")
			if not image.visible or image.self_modulate.a != 0.0 or not (wroot.get_node("Image/Kid") as Control).is_visible_in_tree():
				out.append("a disabled Image draws nothing but stays visible with its children: %s" % str(image.self_modulate))
			var button: Button = wroot.get_node("Button")
			var box: StyleBox = button.get_theme_stylebox("normal")
			if not (box is StyleBoxFlat) or not (box as StyleBoxFlat).bg_color.is_equal_approx(Color(0, 0, 1, 0.5)):
				out.append("the button draws its disabled colour: " + str(box.get("bg_color")))
			var mark: TextureRect = wroot.get_node("Toggle/Background/Checkmark")
			if not mark.self_modulate.is_equal_approx(Color(0.1, 0.1, 0.1, 1)):
				out.append("the check mark of the toggle that is on is drawn: " + str(mark.self_modulate))
			var fill: Control = wroot.get_node("Slider/Fill Area/Fill")
			# right to left at 0.875: the fill covers the right 87.5 % of the 160 wide area, plus its size delta
			if absf(fill.size.x - 150.0) > 0.01 or absf(fill.position.x - 15.0) > 0.01:
				out.append("the fill rect follows its anchors: x %s, width %s" % [str(fill.position.x), str(fill.size.x)])
			var bar: TextureRect = wroot.get_node("Bar")
			var bar_sprite: Dictionary = bar.get_meta("unidot_graphic").get("sprite", {})
			if not is_equal_approx(float(bar_sprite.get("amount", -1.0)), 0.25) or int(bar_sprite.get("origin", -1)) != 1 or bar.self_modulate.a != 0.0 or not is_equal_approx(bar.size.x, 128.0):
				out.append("the filled Image draws a quarter from the right through its helper: %s" % str(bar_sprite))
			var l3d: Label3D = _host.get_node("Text3D/TextMeshPro")
			if l3d.text != "Winner" or not l3d.modulate.is_equal_approx(Color(0, 1, 0, 1)):
				out.append("the 3D text draws what the script set: %s %s" % [l3d.text, str(l3d.modulate)])
		"TRect":
			# the script moved `Mover` onto a 3D spot: it is drawn there, on a canvas of its own
			var RT = _U.RT
			var cv: Node = _host.get_node("Canvas")
			var mover: Control = target.get("mover")
			var child: Control = target.get("child")
			var itemb: Control = target.get("itemB")
			var centre: Vector3 = RT.drawn_point(mover, mover.size * 0.5)
			var edge: Vector3 = RT.drawn_point(mover, Vector2(mover.size.x, mover.size.y * 0.5))
			var want: Dictionary = {
				"the moved rect got a canvas of its own": RT.holder_of(mover) != null and RT.is_island(RT.holder_of(mover)),
				"it is drawn on the spot (%s)" % str(centre): centre.distance_to(Vector3(3, 0.5, -1)) < 0.003,
				# 40 units wide at scale 0.01, turned 90 degrees about y: +x points along -z
				"... facing the spot's way (%s)" % str(edge): edge.distance_to(Vector3(3, 0.5, -1.2)) < 0.003,
				"the canvas still has three child objects": RT.logical_children(cv).size() == 3,
				"Control rotation is the Unity z angle, negated": is_equal_approx(child.rotation, -PI / 2.0),
				"Control scale": child.scale.is_equal_approx(Vector2(2, 2)),
				"SetParent moved the control under the panel": itemb.get_parent() == target.get("panel"),
			}
			for k in want:
				if not want[k]:
					out.append("engine: " + k)
		"TAnim":
			var want: Dictionary = {
				"follower moved by the solver": target.get_node("Follower").position.is_equal_approx(Vector3(4, 2, 0)),
				"scaled node scale 2": target.get_node("Scaled").scale.is_equal_approx(Vector3(2, 2, 2)),
			}
			for k in want:
				if not want[k]:
					out.append("engine: " + k)
	return out

## Engine-side verification of what the converted script set (the script only sees round trips).
func _godot_checks(name: String, target: Node3D, _host: Node3D) -> Array:
	var out: Array = []
	match name:
		"TPhysics":
			var body: RigidBody3D = target.get_node("Body")
			var pm: PhysicsMaterial = _host.get_node("Floor").physics_material_override
			var want: Dictionary = {
				"includeLayers 1<<5 folded into collision_mask": body.collision_mask == (1 | (1 << 5)),
				"providesContacts enabled contact monitor": body.contact_monitor and body.max_contacts_reported >= 8,
				"PhysicMaterial Minimum bounce → absorbent": pm != null and pm.absorbent and not pm.rough,
			}
			for k in want:
				if not want[k]:
					out.append("engine: " + k)
		"T2D":
			var groove: GrooveJoint2D = _host.get_node("World2D/Slider")
			var space: RID = _host.get_viewport().world_2d.space
			var want: Dictionary = {
				"SliderJoint2D limits → groove length 3": is_equal_approx(groove.length, 3.0) and is_equal_approx(groove.initial_offset, 1.0),
				"linearSleepTolerance → space param": is_equal_approx(PhysicsServer2D.space_get_param(space, PhysicsServer2D.SPACE_PARAM_BODY_LINEAR_VELOCITY_SLEEP_THRESHOLD), 0.02),
				"velocityIterations → solver iterations": int(PhysicsServer2D.space_get_param(space, PhysicsServer2D.SPACE_PARAM_SOLVER_ITERATIONS)) == 10,
			}
			for k in want:
				if not want[k]:
					out.append("engine: " + k)
		"TParticles":
			var p: GPUParticles3D = target.get_node("Emitter")
			var pm: ParticleProcessMaterial = p.process_material
			var dm: BaseMaterial3D = p.draw_pass_1.surface_get_material(0)
			var want: Dictionary = {
				"amount 50": p.amount == 50,
				"one_shot": p.one_shot,
				"lifetime 2.5": is_equal_approx(p.lifetime, 2.5),
				"scale 0.5..1.5": is_equal_approx(pm.scale_min, 0.5) and is_equal_approx(pm.scale_max, 1.5),
				"initial velocity 3": is_equal_approx(pm.initial_velocity_max, 3.0),
				"color red": pm.color == Color.RED,
				"world space": not p.local_coords,
				"gravity 0.5 g": is_equal_approx(pm.gravity.y, -9.81 * 0.5),
				"sphere r=0.5": pm.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_SPHERE and is_equal_approx(pm.emission_sphere_radius, 0.5),
				"color ramp": pm.color_ramp != null,
				"scale curve": pm.scale_curve != null,
				"turbulence 0.3": pm.turbulence_enabled and is_equal_approx(pm.turbulence_noise_strength, 0.3),
				"trail 0.4": p.trail_enabled and is_equal_approx(p.trail_lifetime, 0.4),
				"sheet 4x2": dm.particles_anim_h_frames == 4 and dm.particles_anim_v_frames == 2,
				"angular velocity 180": is_equal_approx(pm.angular_velocity_max, 180.0),
				"collision bounce 0.7": pm.collision_mode == ParticleProcessMaterial.COLLISION_RIGID and is_equal_approx(pm.collision_bounce, 0.7),
				"mesh render mode": dm.billboard_mode == BaseMaterial3D.BILLBOARD_DISABLED,
				"playing after Play": p.emitting,
			}
			for k in want:
				if not want[k]:
					out.append("engine: " + k)
		"TMedia":
			var mesh: MeshInstance3D = target.get_node("Mesh")
			var mat: BaseMaterial3D = mesh.material_override
			var cam: Camera3D = target.get_node("Cam")
			var sun: DirectionalLight3D = target.get_node("Sun")
			var want: Dictionary = {
				"PropertyToID colour reached albedo": mat != null and is_equal_approx(mat.albedo_color.r, 1.0) and is_equal_approx(mat.albedo_color.g, 0.0),
				"Material.SetFloat by id → metallic": mat != null and is_equal_approx(mat.metallic, 0.75),
				"forceRenderingOff reset → visible": mesh.visible,
				"localBounds → custom_aabb": is_equal_approx(mesh.custom_aabb.size.x, 3.0),
				"physical camera attributes": cam.attributes is CameraAttributesPhysical and is_equal_approx(cam.attributes.exposure_aperture, 5.6) and is_equal_approx(cam.attributes.exposure_sensitivity, 400.0),
				"shadow distance 80": is_equal_approx(sun.directional_shadow_max_distance, 80.0),
				"shadow cascades 2": sun.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
				"shadow split 2 = 0.3": is_equal_approx(sun.directional_shadow_split_2, 0.3),
			}
			for k in want:
				if not want[k]:
					out.append("engine: " + k)
		"TNav":
			var link: NavigationLink3D = _host.get_node("Link")
			var want: Dictionary = {
				"costModifier 3 → travel_cost": is_equal_approx(link.travel_cost, 3.0),
				"area 2 → navigation layer bit": link.navigation_layers == (1 << 2),
				"activated false → link disabled": not link.enabled,
				"startTransform follows the region": link.start_position.is_equal_approx(link.to_local(_host.get_node("Region").global_position)),
				"AddLink/RemoveLink leaves no node": _host.get_tree().current_scene == null or _host.get_tree().current_scene.find_child("NavMeshLink", true, false) == null,
			}
			for k in want:
				if not want[k]:
					out.append("engine: " + k)
		"TUI":
			var ui := _host.get_node("UI")
			var tmp: Label = ui.get_node("TMP")
			var btn: Button = ui.get_node("Button")
			var rect: Control = ui.get_node("Rect")
			var want: Dictionary = {
				"TMP right aligned": tmp.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT,
				"TMP ellipsis": tmp.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS,
				"TMP max lines 2": tmp.max_lines_visible == 2,
				"TMP no autowrap": tmp.autowrap_mode == TextServer.AUTOWRAP_OFF,
				"outline colour override": tmp.has_theme_color_override("font_outline_color") and tmp.get_theme_color("font_outline_color") == Color.BLUE,
				"outline size 2": tmp.get_theme_constant("outline_size") == 2,
				"button normal colour tints": btn.get_theme_stylebox("normal") is StyleBoxFlat and (btn.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == Color.RED,
				"button focus neighbour": btn.focus_neighbor_bottom == btn.get_path_to(ui.get_node("Slider")),
				"mask clips": rect.clip_contents,
				"layout preferred width": is_equal_approx((rect.get_meta("unidot_layout_element")["pref"] as Vector2).x, 120.0),
				"layout flexible": is_equal_approx((rect.get_meta("unidot_layout_element")["flex"] as Vector2).x, 2.0),
			}
			for k in want:
				if not want[k]:
					out.append("engine: " + k)
		_:
			pass
	return out


func _box_body(name: String, size: Vector3, pos: Vector3, rigid: bool) -> CollisionObject3D:
	var b: CollisionObject3D = RigidBody3D.new() if rigid else StaticBody3D.new()
	b.name = name
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	b.add_child(cs)
	b.position = pos
	return b

func _build_scene(name: String, target: Node3D, host: Node3D) -> void:
	match name:
		"TTransform":
			var child := Node3D.new()
			child.name = "Child"
			var gc := Node3D.new()
			gc.name = "GrandChild"
			child.add_child(gc)
			target.add_child(child)
			var other := Node3D.new()
			other.name = "Other"
			host.add_child(other)
			target.add_child(_box_body("Body", Vector3.ONE, Vector3(0, 3, 0), true))
			var mesh := MeshInstance3D.new()
			mesh.name = "Mesh"
			mesh.mesh = BoxMesh.new()
			target.add_child(mesh)
		"TParticles":
			var ps := GPUParticles3D.new()
			ps.name = "Emitter"
			ps.process_material = ParticleProcessMaterial.new()
			var quad := QuadMesh.new()
			var mat := StandardMaterial3D.new()
			mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
			quad.material = mat
			ps.draw_pass_1 = quad
			ps.emitting = false
			target.add_child(ps)
		"TPhysics":
			var body := _box_body("Body", Vector3.ONE, Vector3(0, 5, 0), true)
			target.add_child(body)
			host.add_child(_box_body("Floor", Vector3(100, 1, 100), Vector3(0, -0.5, 0), false))
			var area := Area3D.new()
			area.name = "Trigger"
			var cs := CollisionShape3D.new()
			var sphere := SphereShape3D.new()
			sphere.radius = 3.0
			cs.shape = sphere
			area.add_child(cs)
			area.position = Vector3(0, 1, 0)
			host.add_child(area)
			# the character controller is a component of the script's object, like the body
			var cc := CharacterBody3D.new()
			cc.name = "Controller"
			var ccs := CollisionShape3D.new()
			var cap := CapsuleShape3D.new()
			cap.radius = 0.5
			cap.height = 2.0
			ccs.shape = cap
			cc.add_child(ccs)
			cc.position = Vector3(20, 1.5, 20)
			target.add_child(cc)
		"TMedia":
			var audio := AudioStreamPlayer3D.new()
			audio.name = "Audio"
			var gen := AudioStreamWAV.new()
			gen.format = AudioStreamWAV.FORMAT_8_BITS
			gen.mix_rate = 8000
			var data := PackedByteArray()
			data.resize(8000)
			for i in range(8000):
				data[i] = int(127 + 100 * sin(i * 0.1))
			gen.data = data
			audio.stream = gen
			target.add_child(audio)
			var anim := AnimationPlayer.new()
			anim.name = "Anim"
			var lib := AnimationLibrary.new()
			var a := Animation.new()
			a.length = 2.0
			var tr := a.add_track(Animation.TYPE_VALUE)
			a.track_set_path(tr, "../Mesh:rotation")
			a.track_insert_key(tr, 0.0, Vector3.ZERO)
			a.track_insert_key(tr, 2.0, Vector3(0, TAU, 0))
			lib.add_animation("spin", a)
			anim.add_animation_library("", lib)
			target.add_child(anim)
			var ps := GPUParticles3D.new()
			ps.name = "Particles"
			ps.emitting = false
			ps.process_material = ParticleProcessMaterial.new()
			target.add_child(ps)
			var mesh := MeshInstance3D.new()
			mesh.name = "Mesh"
			mesh.mesh = BoxMesh.new()
			mesh.material_override = StandardMaterial3D.new()
			target.add_child(mesh)
			var light := OmniLight3D.new()
			light.name = "Light"
			target.add_child(light)
			var cam := Camera3D.new()
			cam.name = "Cam"
			cam.position = Vector3(0, 1, 5)
			target.add_child(cam)
			cam.make_current()
			var sun := DirectionalLight3D.new()
			sun.name = "Sun"
			target.add_child(sun)
			var line := Node3D.new()
			line.name = "Line"
			target.add_child(line)
		"TUI":
			var layer := CanvasLayer.new()
			layer.name = "UI"
			host.add_child(layer)
			var lbl := Label.new()
			lbl.name = "Text"
			layer.add_child(lbl)
			var tmp := Label.new()
			tmp.name = "TMP"
			layer.add_child(tmp)
			var sl := HSlider.new()
			sl.name = "Slider"
			layer.add_child(sl)
			var tg := CheckBox.new()
			tg.name = "Toggle"
			layer.add_child(tg)
			var img := TextureRect.new()
			img.name = "Image"
			layer.add_child(img)
			var inp := LineEdit.new()
			inp.name = "Input"
			layer.add_child(inp)
			var dd := OptionButton.new()
			dd.name = "Dropdown"
			layer.add_child(dd)
			var rect := Control.new()
			rect.name = "Rect"
			rect.set_meta("unidot_layout_element", {"min": Vector2(-1, -1), "pref": Vector2(-1, -1), "flex": Vector2(-1, -1), "ignore": false, "priority": 1, "enabled": true})
			layer.add_child(rect)
			var btn := Button.new()
			btn.name = "Button"
			layer.add_child(btn)
			var l3 := Label3D.new()
			l3.name = "Label3D"
			target.add_child(l3)
		"TRect":
			# a world canvas built with the importer's own code (unidot's rect_transform.gd):
			# 400 x 200 at Unity (1, 1, 2), scale 0.01
			var RT = _U.RT
			var defaults: Dictionary = RT._defaults()
			var cv := Node3D.new()
			cv.name = "Canvas"
			host.add_child(cv)
			var croot := Control.new()
			croot.name = "Canvas"
			RT.build_island(cv, croot, {"anchored_position": Vector2(1, 1), "z": 2.0, "size_delta": Vector2(400, 200), "scale": Vector3(0.01, 0.01, 0.01), "anchor_min": Vector2.ZERO, "anchor_max": Vector2.ZERO})
			var mk := func(cls: String, nm: String, parent: Control, v: Dictionary) -> Control:
				var c: Control = ClassDB.instantiate(cls)
				c.name = nm
				parent.add_child(c)
				var full: Dictionary = defaults.duplicate()
				full.merge(v, true)
				RT.set_values(c, full)
				return c
			var panel: Control = mk.call("Control", "Panel", croot, {"size_delta": Vector2(200, 100)})
			mk.call("TextureRect", "Child", panel, {"anchored_position": Vector2(20, 10), "size_delta": Vector2(40, 20)})
			var lst: Control = mk.call("Control", "List", croot, {"anchored_position": Vector2(150, 0), "size_delta": Vector2(100, 200)})
			lst.set_meta("unidot_layout", {"type": "vertical", "padding": [4, 4, 4, 4], "spacing": 2.0, "align": 0, "control_w": true, "control_h": false, "expand_w": true, "expand_h": false, "scale_w": false, "scale_h": false, "reverse": false})
			lst.set_meta("unidot_fitter", {"h": 0, "v": 0})
			mk.call("TextureRect", "ItemA", lst, {"size_delta": Vector2(10, 20)}).set_meta("unidot_no_sprite", true)
			var ib: Control = mk.call("TextureRect", "ItemB", lst, {"size_delta": Vector2(10, 30)})
			ib.set_meta("unidot_no_sprite", true)
			ib.set_meta("unidot_layout_element", {"min": Vector2(-1, -1), "pref": Vector2(-1, -1), "flex": Vector2(-1, -1), "ignore": false, "priority": 1, "enabled": true})
			_U._ui_layout_helper(lst, true)
			mk.call("TextureRect", "Mover", croot, {"anchored_position": Vector2(-150, 50), "size_delta": Vector2(40, 40)})
			var spot := Node3D.new()
			spot.name = "Spot"
			host.add_child(spot)
			spot.position = Vector3(-3, 0.5, -1)                                # Unity (3, 0.5, -1)
			spot.quaternion = Quaternion(0.0, -sin(PI / 4.0), 0.0, cos(PI / 4.0))  # Unity 90 degrees about y
		"TWidgets":
			# texts, graphics and selectables as the importer leaves them: metadata rendered by
			# unidot's runtime modules, helper children for what follows input
			var RT = _U.RT
			var defaults: Dictionary = RT._defaults()
			var cv := Node3D.new()
			cv.name = "Canvas"
			host.add_child(cv)
			var croot := Control.new()
			croot.name = "Canvas"
			RT.build_island(cv, croot, {"anchored_position": Vector2(0, 1), "z": 2.0, "size_delta": Vector2(400, 300), "scale": Vector3(0.01, 0.01, 0.01), "anchor_min": Vector2.ZERO, "anchor_max": Vector2.ZERO})
			var mk := func(cls: String, nm: String, parent: Control, v: Dictionary) -> Control:
				var c: Control = ClassDB.instantiate(cls)
				c.name = nm
				parent.add_child(c)
				var full: Dictionary = defaults.duplicate()
				full.merge(v, true)
				RT.set_values(c, full)
				return c
			var helper := func(c: Control, nm: String, script: Script) -> void:
				var h := Node.new()
				h.name = nm
				h.set_meta(RT.META_HELPER, true)
				h.set_script(script)
				c.add_child(h)
			var label: RichTextLabel = mk.call("RichTextLabel", "Label", croot, {"anchored_position": Vector2(0, 120), "size_delta": Vector2(300, 40)})
			_U.UiText.set_fonts(label)
			label.set_meta(_U.UiText.META, {"text": "<b>Start</b>", "tmp": true, "rich": true, "size": 20.0, "style": 0, "auto": false, "min": 18.0, "max": 72.0, "wrap": true, "overflow": 0})
			_U.UiText.render(label)
			_U.UiGraphic.update(label, {"color": Color.WHITE})
			var fitted: RichTextLabel = mk.call("RichTextLabel", "Fitted", croot, {"anchored_position": Vector2(0, 80), "size_delta": Vector2(200, 30)})
			_U.UiText.set_fonts(fitted)
			fitted.set_meta(_U.UiText.META, {"text": "Auto sized text that has to shrink", "tmp": true, "rich": true, "size": 60.0, "style": 0, "auto": true, "min": 8.0, "max": 60.0, "wrap": true, "overflow": 0})
			_U.UiText.render(fitted)
			helper.call(fitted, _U.UiText.HELPER, _U._UiTextFit)
			var image: Control = mk.call("TextureRect", "Image", croot, {"anchored_position": Vector2(-150, 40), "size_delta": Vector2(60, 40)})
			_U.UiGraphic.update(image, {"color": Color(1, 0.5, 0.25, 1)})
			mk.call("TextureRect", "Kid", image, {"size_delta": Vector2(20, 20)})
			var bar: TextureRect = mk.call("TextureRect", "Bar", croot, {"anchored_position": Vector2(-120, -100), "size_delta": Vector2(128, 32)})
			bar.texture = GradientTexture2D.new()
			var bar_draw := Control.new()
			bar_draw.name = _U._UiSprite.HELPER
			bar_draw.set_meta(RT.META_HELPER, true)
			bar_draw.show_behind_parent = true
			bar_draw.set_script(_U._UiSprite)
			bar.add_child(bar_draw)
			bar_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
			_U.UiGraphic.update(bar, {"color": Color.WHITE, "sprite": {"type": 3, "method": 0, "origin": 0, "amount": 1.0, "clockwise": true}})
			var button: Button = mk.call("Button", "Button", croot, {"anchored_position": Vector2(0, 40), "size_delta": Vector2(120, 30)})
			_U.UiGraphic.update(button, {"color": Color.WHITE})
			button.set_meta(_U.UiSelectable.META, {"transition": 1, "target": NodePath("."), "colors": {"normalColor": Color(1, 1, 1, 0), "highlightedColor": Color(1, 1, 1, 1), "pressedColor": Color(0.8, 0.8, 0.8, 1), "selectedColor": Color(1, 1, 1, 1), "disabledColor": Color(0.8, 0.8, 0.8, 0.5), "colorMultiplier": 1.0, "fadeDuration": 0.1}})
			helper.call(button, _U.UiSelectable.HELPER, _U.UiSelectable)
			var toggle: Button = mk.call("Button", "Toggle", croot, {"anchored_position": Vector2(0, 0), "size_delta": Vector2(120, 24)})
			toggle.toggle_mode = true
			var back: Control = mk.call("TextureRect", "Background", toggle, {"size_delta": Vector2(20, 20)})
			var mark: Control = mk.call("TextureRect", "Checkmark", back, {"size_delta": Vector2(16, 16)})
			_U.UiGraphic.update(back, {"color": Color.WHITE})
			_U.UiGraphic.update(mark, {"color": Color(0.1, 0.1, 0.1, 1)})
			toggle.set_meta(_U.UiSelectable.META, {"transition": 1, "target": toggle.get_path_to(back), "graphic": toggle.get_path_to(mark)})
			helper.call(toggle, _U.UiSelectable.HELPER, _U.UiSelectable)
			var slider: HSlider = mk.call("HSlider", "Slider", croot, {"anchored_position": Vector2(0, -40), "size_delta": Vector2(160, 20)})
			slider.max_value = 1.0
			slider.step = 0.0
			slider.value = 0.5
			var area: Control = mk.call("Control", "Fill Area", slider, {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(1, 1), "size_delta": Vector2.ZERO})
			var fill: Control = mk.call("TextureRect", "Fill", area, {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(0.9, 1), "size_delta": Vector2(10, 0)})
			var knob: Control = mk.call("TextureRect", "Handle", area, {"anchor_min": Vector2(0.9, 0), "anchor_max": Vector2(0.9, 1), "size_delta": Vector2(20, 0)})
			slider.set_meta(_U.UiSelectable.META, {"transition": 1, "target": slider.get_path_to(knob), "fill": slider.get_path_to(fill), "handle": slider.get_path_to(knob), "direction": 0})
			helper.call(slider, _U.UiSelectable.HELPER, _U.UiSelectable)
			for c in [button, toggle, slider]:
				_U.UiSelectable.refresh_static(c)   # the importer's last step
			# a Dropdown with Unity's objects: caption, and a template with one item
			var dd: OptionButton = mk.call("OptionButton", "Dropdown", croot, {"anchored_position": Vector2(120, 100), "size_delta": Vector2(120, 30)})
			for o in ["A", "B", "C"]:
				dd.add_item(o)
			dd.select(0)
			var text := func(nm: String, parent: Control, v: Dictionary) -> RichTextLabel:
				var l: RichTextLabel = mk.call("RichTextLabel", nm, parent, v)
				_U.UiText.set_fonts(l)
				l.set_meta(_U.UiText.META, {"text": "", "tmp": false, "rich": false, "size": 14.0, "style": 0, "wrap": false, "overflow": 0})
				_U.UiText.render(l)
				_U.UiGraphic.update(l, {"color": Color.BLACK})
				return l
			var caption: RichTextLabel = text.call("Label", dd, {"anchor_min": Vector2.ZERO, "anchor_max": Vector2.ONE, "size_delta": Vector2.ZERO})
			var template: Control = mk.call("TextureRect", "Template", dd, {"anchor_min": Vector2(0, 0), "anchor_max": Vector2(1, 0), "pivot": Vector2(0.5, 1), "anchored_position": Vector2(0, 2), "size_delta": Vector2(0, 150)})
			var content: Control = mk.call("Control", "Content", template, {"anchor_min": Vector2(0, 1), "anchor_max": Vector2(1, 1), "pivot": Vector2(0.5, 1), "size_delta": Vector2(0, 28)})
			var item: Button = mk.call("Button", "Item", content, {"anchor_min": Vector2(0, 0.5), "anchor_max": Vector2(1, 0.5), "size_delta": Vector2(0, 20)})
			item.toggle_mode = true
			var item_label: RichTextLabel = text.call("Item Label", item, {"anchor_min": Vector2.ZERO, "anchor_max": Vector2.ONE, "size_delta": Vector2.ZERO})
			_U.set_active(template, false)   # hidden, and not processing: what the importer leaves for an inactive object
			dd.set_meta(_U._UiDropdown.META, {"caption": dd.get_path_to(caption), "template": dd.get_path_to(template), "item_text": dd.get_path_to(item_label)})
			helper.call(dd, _U._UiDropdown.HELPER, _U._UiDropdown)
			_U._UiDropdown.refresh_caption(dd)
			# a scroll view: 200 x 200, the viewport stretched over it, content 500 high anchored to
			# its top, a vertical Scrollbar with its handle
			var sv: Control = mk.call("Control", "Scroll", croot, {"anchored_position": Vector2(-250, -100), "size_delta": Vector2(200, 200)})
			var sview: Control = mk.call("Control", "Viewport", sv, {"anchor_min": Vector2.ZERO, "anchor_max": Vector2.ONE, "pivot": Vector2(0, 1), "size_delta": Vector2.ZERO})
			var scontent: Control = mk.call("Control", "Content", sview, {"anchor_min": Vector2(0, 1), "anchor_max": Vector2(1, 1), "pivot": Vector2(0, 1), "size_delta": Vector2(0, 500)})
			var sbar: VScrollBar = mk.call("VScrollBar", "Scrollbar", sv, {"anchor_min": Vector2(1, 0), "anchor_max": Vector2(1, 1), "pivot": Vector2(1, 1), "size_delta": Vector2(20, 0)})
			sbar.min_value = 0.0
			sbar.max_value = 1.0
			sbar.step = 0.0
			sbar.page = 0.0
			var sarea: Control = mk.call("Control", "Sliding Area", sbar, {"anchor_min": Vector2.ZERO, "anchor_max": Vector2.ONE, "size_delta": Vector2(-20, -20)})
			var shandle: Control = mk.call("TextureRect", "Handle", sarea, {"anchor_min": Vector2.ZERO, "anchor_max": Vector2(1, 0.2), "size_delta": Vector2(20, 20)})
			sbar.set_meta("unidot_scrollbar", {"direction": 2, "size": 0.2})
			sbar.set_meta(_U.UiSelectable.META, {"transition": 0, "handle": sbar.get_path_to(shandle), "direction": 2})
			helper.call(sbar, _U.UiSelectable.HELPER, _U.UiSelectable)
			sv.set_meta(_U._UiScroll.META, {"content": sv.get_path_to(scontent), "viewport": sv.get_path_to(sview), "vbar": sv.get_path_to(sbar),
				"horizontal": false, "vertical": true, "movement": 2, "elasticity": 0.1, "inertia": true, "deceleration": 0.135, "sensitivity": 1.0, "visibility": [0, 0], "spacing": [0.0, 0.0]})
			helper.call(sv, _U._UiScroll.HELPER, _U._UiScroll)
			var t3 := Node3D.new()
			t3.name = "Text3D"
			host.add_child(t3)
			var l3d := Label3D.new()
			l3d.name = "TextMeshPro"
			l3d.font_size = 64
			l3d.set_meta(_U.UiText.META, {"text": "ready", "tmp": true, "rich": true, "size": 2.0, "style": 0, "wrap": false, "overflow": 0})
			t3.add_child(l3d)
			_U.UiText.render(l3d)
			_U.UiGraphic.update(l3d, {"color": Color.WHITE})
		"TVRC":
			var other := Node3D.new()
			other.name = "Other"
			host.add_child(other)
			for n in ["Pickup", "Station", "Synced"]:
				var nd := Node3D.new()
				nd.name = n
				host.add_child(nd)
			var pool := Node3D.new()
			pool.name = "Pool"
			for i in range(2):
				var c := Node3D.new()
				c.name = "Item%d" % i
				pool.add_child(c)
			host.add_child(pool)
		"TCoord":
			# unidot convention: Unity (x, y, z) sits at Godot (-x, y, z); rotations are (x, -y, -z, w)
			target.position = Vector3(-1, 2, 3)
			var child := Node3D.new()
			child.name = "Child"
			child.position = Vector3(-1, 0, 2)
			target.add_child(child)
			var cam_go := Node3D.new()
			cam_go.name = "CamGO"
			var s45: float = sin(PI / 4.0)
			cam_go.quaternion = Quaternion(0.0, -s45, 0.0, cos(PI / 4.0))
			cam_go.position = Vector3(0, 1, -4)
			host.add_child(cam_go)
			var cam := Camera3D.new()
			cam.name = "Camera"
			cam.transform = Transform3D(Basis.from_euler(Vector3(0.0, PI, 0.0)))
			cam_go.add_child(cam)
			cam.make_current()
			var body := _box_body("Body", Vector3.ONE, Vector3(0, 1, 0), true)
			body.gravity_scale = 0.0
			host.add_child(body)
			var wall := _box_body("BoxCollider", Vector3.ONE, Vector3(-5, 0, 0), false)
			host.add_child(wall)
		"TAnim":
			var tgt := Node3D.new()
			tgt.name = "Target"
			tgt.position = Vector3(4, 1, 0)
			host.add_child(tgt)
			for n in ["Follower", "Aimer", "Scaled", "ParentFollower"]:
				var node := Node3D.new()
				node.name = n
				target.add_child(node)
		"TNav":
			var region := NavigationRegion3D.new()
			region.name = "Region"
			var nm := NavigationMesh.new()
			nm.vertices = PackedVector3Array([Vector3(-10, 0, -10), Vector3(-10, 0, 10), Vector3(10, 0, 10), Vector3(10, 0, -10)])
			nm.add_polygon(PackedInt32Array([0, 1, 2, 3]))
			region.navigation_mesh = nm
			host.add_child(region)
			var link := NavigationLink3D.new()
			link.name = "Link"
			link.start_position = Vector3(0, 0, 0)
			link.end_position = Vector3(5, 0, 5)
			host.add_child(link)
			var mover := CharacterBody3D.new()
			mover.name = "Mover"
			var agent := NavigationAgent3D.new()
			agent.name = "Agent"
			mover.add_child(agent)
			mover.position = Vector3(-5, 0, -5)
			target.add_child(mover)
		"T2D":
			# the fixture works in metres like Unity 2D; Godot's default 980 px/s² would tunnel
			PhysicsServer2D.area_set_param(root.world_2d.space, PhysicsServer2D.AREA_PARAM_GRAVITY, 9.8)
			var root2d := Node2D.new()
			root2d.name = "World2D"
			host.add_child(root2d)
			# the body is a component of the script's object so its collision callbacks reach it
			var body := RigidBody2D.new()
			body.name = "Body2D"
			var cs := CollisionShape2D.new()
			var circ := CircleShape2D.new()
			circ.radius = 0.5
			cs.shape = circ
			body.add_child(cs)
			body.position = Vector2(0, -5)
			target.add_child(body)
			var floor2d := StaticBody2D.new()
			floor2d.name = "Floor2D"
			var fcs := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = Vector2(200, 1)
			fcs.shape = rect
			floor2d.add_child(fcs)
			floor2d.position = Vector2(0, 0.5)
			root2d.add_child(floor2d)
			var groove := GrooveJoint2D.new()
			groove.name = "Slider"
			groove.position = Vector2(30, -2)
			root2d.add_child(groove)
		_:
			pass

func _wire(name: String, t: Node3D, host: Node3D, script) -> void:
	match name:
		"TTransform":
			t.set("child", t.get_node("Child"))
			var other := host.get_node("Other")
			other.set_script(script)
			t.set("other", other)
			t.set("body", t.get_node("Body"))
			t.set("meshObj", t.get_node("Mesh"))
		"TParticles":
			t.set("ps", t.get_node("Emitter"))
		"TPhysics":
			t.set("body", t.get_node("Body"))
			t.set("floorCol", host.get_node("Floor"))
			t.set("trigger", host.get_node("Trigger"))
			t.set("controller", t.get_node("Controller"))
		"TMedia":
			t.set("audio", t.get_node("Audio"))
			t.set("clip", t.get_node("Audio").stream)
			t.set("animator", t.get_node("Anim"))
			t.set("particles", t.get_node("Particles"))
			t.set("meshRenderer", t.get_node("Mesh"))
			t.set("light", t.get_node("Light"))
			t.set("cam", t.get_node("Cam"))
			t.set("line", t.get_node("Line"))
		"TUI":
			var ui := host.get_node("UI")
			t.set("uiText", ui.get_node("Text"))
			t.set("tmpText", ui.get_node("TMP"))
			t.set("slider", ui.get_node("Slider"))
			t.set("toggle", ui.get_node("Toggle"))
			t.set("image", ui.get_node("Image"))
			t.set("input", ui.get_node("Input"))
			t.set("dropdown", ui.get_node("Dropdown"))
			t.set("rect", ui.get_node("Rect"))
			t.set("button", ui.get_node("Button"))
			t.set("label3d", t.get_node("Label3D"))
		"TRect":
			var cv := host.get_node("Canvas")
			var croot: Control = _U.RT.root_control(cv)
			t.set("canvas", cv)
			t.set("panel", croot.get_node("Panel"))
			t.set("child", croot.get_node("Panel/Child"))
			t.set("list", croot.get_node("List"))
			t.set("itemA", croot.get_node("List/ItemA"))
			t.set("itemB", croot.get_node("List/ItemB"))
			t.set("mover", croot.get_node("Mover"))
			t.set("spot", host.get_node("Spot"))
		"TWidgets":
			var wroot: Control = _U.RT.root_control(host.get_node("Canvas"))
			t.set("label", wroot.get_node("Label"))
			t.set("fitted", wroot.get_node("Fitted"))
			t.set("image", wroot.get_node("Image"))
			t.set("kid", wroot.get_node("Image/Kid"))
			t.set("button", wroot.get_node("Button"))
			t.set("buttonImage", wroot.get_node("Button"))
			t.set("toggle", wroot.get_node("Toggle"))
			t.set("check", wroot.get_node("Toggle/Background/Checkmark"))
			t.set("slider", wroot.get_node("Slider"))
			t.set("fill", wroot.get_node("Slider/Fill Area/Fill"))
			t.set("handle", wroot.get_node("Slider/Fill Area/Handle"))
			t.set("text3d", host.get_node("Text3D"))
			t.set("bar", wroot.get_node("Bar"))
			t.set("dropdown", wroot.get_node("Dropdown"))
			t.set("tmpDropdown", wroot.get_node("Dropdown"))
			t.set("caption", wroot.get_node("Dropdown/Label"))
			t.set("spare", GradientTexture2D.new())
			t.set("scroll", wroot.get_node("Scroll"))
			t.set("scrollContent", wroot.get_node("Scroll/Viewport/Content"))
			t.set("scrollBar", wroot.get_node("Scroll/Scrollbar"))
		"TVRC":
			var other := host.get_node("Other")
			other.set_script(script)
			t.set("other", other)
			t.set("pickupObj", host.get_node("Pickup"))
			t.set("stationObj", host.get_node("Station"))
			t.set("syncedObj", host.get_node("Synced"))
			t.set("poolObj", host.get_node("Pool"))
			# OnStationEntered goes to the behaviours on the station's own node: the fixture is the station
			t.set("stationObj", t)
			_Udon.register_component(t, "station")
			_Udon.station(t)
			_Udon.register_component(host.get_node("Pickup"), "pickup")
			_Udon.pickup(host.get_node("Pickup"))
			_Udon.register_component(host.get_node("Synced"), "object_sync")
			_Udon.object_sync(host.get_node("Synced"))
			_Udon.register_component(host.get_node("Pool"), "object_pool")
			_Udon.object_pool(host.get_node("Pool"))
		"TCoord":
			t.set("child", t.get_node("Child"))
			t.set("camGO", host.get_node("CamGO"))
			t.set("cam", host.get_node("CamGO/Camera"))
			t.set("body", host.get_node("Body"))
			t.set("wall", host.get_node("BoxCollider"))
		"TAnim":
			t.set("target", host.get_node("Target"))
			t.set("follower", t.get_node("Follower"))
			t.set("aimer", t.get_node("Aimer"))
			t.set("scaled", t.get_node("Scaled"))
			t.set("parentFollower", t.get_node("ParentFollower"))
		"TNav":
			t.set("link", host.get_node("Link"))
			t.set("agent", t.get_node("Mover/Agent"))
			t.set("region", host.get_node("Region"))
		"T2D":
			t.set("body", t.get_node("Body2D"))
			t.set("floorCol", host.get_node("World2D/Floor2D"))
			t.set("slider", host.get_node("World2D/Slider"))
		_:
			pass
