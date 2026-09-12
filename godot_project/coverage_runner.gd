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
	var names: Array = ["TCoord", "TMath", "TMathB", "TStrings", "TArrays", "TTransform", "TPhysics", "TMedia", "TUI", "TVRC", "T2D", "TParticles", "TSystem", "TNav", "TAnim"]
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
	if name == "TCoord":
		_U.coord_mode = _U.CoordMode.UNIDOT
	target.call("RunTests")
	var extra: Array = []
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
		if name == "TVRC":
			# a remote player joins after the tests ran
			var p = load("res://addons/udon_runtime/udon_player.gd").new()
			p.player_id = 2
			p.display_name = "Remote"
			_Udon.provider.add_player(p)
		# physics fixtures wait for real physics steps (headless process frames can outrun them)
		var physics: bool = name in ["TPhysics", "T2D"]
		var frames: int = 90 if physics else 8
		for i in range(frames):
			if physics:
				await physics_frame
			else:
				await process_frame
		target.call("AfterFrames")
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
				"button normal colour tints": btn.self_modulate == Color.RED,
				"button focus neighbour": btn.focus_neighbor_bottom == btn.get_path_to(ui.get_node("Slider")),
				"mask clips": rect.clip_contents,
				"layout preferred width": is_equal_approx(rect.custom_minimum_size.x, 120.0),
				"layout flexible": rect.size_flags_horizontal & Control.SIZE_EXPAND != 0,
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
			layer.add_child(rect)
			var btn := Button.new()
			btn.name = "Button"
			layer.add_child(btn)
			var l3 := Label3D.new()
			l3.name = "Label3D"
			target.add_child(l3)
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
