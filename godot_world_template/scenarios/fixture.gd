## tests/unity_fixture: checks that the pipeline (unidot + udon_integration + runtime) reproduces
## Unity's numbers for the converted Fixture.cs and wires its Button.onClick persistent call.
extends RefCounted

func run(r) -> void:
	await r.wait(20)
	var fx: Node = r.behaviour("Fixture")
	r.check(fx != null, "Fixture behaviour present")
	if fx == null:
		return
	var checks: int = int(fx.get("checks"))
	var failures: int = int(fx.get("failures"))
	r.check(failures == 0, "script checks: %d failure(s) of %d\n%s" % [failures, checks, str(fx.get("log"))])
	r.check(checks >= 20, "script ran %d checks" % checks)
	var probe: Node = r.find("Probe")
	r.check(probe is Node3D and is_equal_approx((probe as Node3D).global_position.x, -1.0), "Godot node is the mirror image (x = -1)")
	var btn: Node = r.find("Button")
	r.check(btn is BaseButton, "Button became a Godot BaseButton: " + str(btn))
	if btn != null:
		r.u().ui_press(btn, null)
		await r.wait(3)
	r.check(int(fx.get("pressed")) == 1, "onClick → SendCustomEvent(OnPressed): pressed=" + str(fx.get("pressed")))
	r.check(r.find("Floor/BoxCollider") is StaticBody3D, "collider became a StaticBody3D child named after the component")
	r.check(r.find("Floor/MeshRenderer") is MeshInstance3D, "MeshRenderer child")
	var lbl: Node = r.find("Label")
	r.check(lbl is Label and lbl.get_theme_color("font_outline_color") == Color.YELLOW and lbl.get_theme_constant("outline_size") == 2, "imported Outline → theme overrides: " + str(lbl))
	var cvc: Node = r.find("Canvas/Viewport/Canvas")
	r.check(cvc is Control and is_equal_approx((cvc as Control).modulate.a, 0.8), "imported CanvasGroup alpha → modulate")
	var gp: Node = r.find("Probe/Marker/ParticleSystem")
	r.check(gp is GPUParticles3D, "ParticleSystem became a GPUParticles3D: " + str(gp))
	if gp is GPUParticles3D:
		var pm: ParticleProcessMaterial = gp.process_material
		r.check(gp.amount == 24 and gp.one_shot and bool(gp.get_meta("udon_play_on_awake", false)), "amount = rate × lifetime, one shot, play on awake: %d %s" % [gp.amount, gp.one_shot])
		r.check(pm != null and is_equal_approx(pm.scale_max, 0.3) and is_equal_approx(pm.initial_velocity_min, 2.0) and is_equal_approx(pm.initial_velocity_max, 4.0), "process material size/speed")
		r.check(pm != null and pm.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_RING and is_equal_approx(pm.spread, 20.0) and is_equal_approx(pm.emission_ring_radius, 0.25), "cone shape → ring emission")
		r.check(pm != null and pm.color_ramp != null and pm.turbulence_enabled, "colour ramp and turbulence")
		r.check(gp.material_override is BaseMaterial3D and gp.material_override.billboard_mode == BaseMaterial3D.BILLBOARD_PARTICLES, "billboard particle material")
	await _ui_checks(r, fx)


## UiCanvas: 1000 × 600 px at scale 0.001 (1 × 0.6 m) centred at Unity (0, 1.5, 3); buttons TL/TR/
## BL/BR (120 × 60, centres 60 px in from the corners), Center (200 × 80), ScaledBtn (80 × 30 inside a
## 2× container at (0, 200)), a nested canvas with a text. Checks the plane fit, the world ↔ canvas
## mapping and clicks through it; with a display, samples the rendered colours at the projected
## button centres (texture orientation) and clicks through the window.
func _ui_checks(r, fx: Node) -> void:
	var cv: Node = r.find("UiCanvas")
	r.check(cv != null and cv.has_meta("udon_canvas"), "UiCanvas imported as a world canvas")
	if cv == null or not cv.has_meta("udon_canvas"):
		return
	var cfg: Dictionary = cv.get_meta("udon_canvas")
	var ps: Vector2 = cfg.get("plane_size", Vector2.ZERO)
	r.check(ps.is_equal_approx(Vector2(1000, 600)), "plane fits the canvas rect exactly (no container overflow): " + str(ps))
	var vp: SubViewport = cv.get_node_or_null(cfg.get("viewport", NodePath()))
	r.check(vp != null and vp.size == Vector2i(1024, 615), "viewport 1024 px per metre: " + str(vp.size if vp else null))
	var u: Node = r.u()
	# expected Unity world positions of the button pivots
	var expect: Dictionary = {"TL": Vector3(-0.44, 1.77, 3), "TR": Vector3(0.44, 1.77, 3), "BL": Vector3(-0.44, 1.23, 3), "BR": Vector3(0.44, 1.23, 3), "Center": Vector3(0, 1.5, 3), "ScaledBtn": Vector3(0, 1.7, 3)}
	var counters: Dictionary = {"TL": "pressedTL", "TR": "pressedTR", "BL": "pressedBL", "BR": "pressedBR", "Center": "pressedCenter", "ScaledBtn": "pressedScaled"}
	for name in expect:
		var btn: Node = r.find(name)
		r.check(btn is BaseButton, name + " is a button: " + str(btn))
		if not (btn is BaseButton):
			continue
		var pos: Vector3 = u.get_position(btn)
		r.check(pos.is_equal_approx(expect[name]), "%s world position %s (expected %s)" % [name, str(pos), str(expect[name])])
		# viewport pixel of the pivot vs. the control's own centre in the viewport
		var px: Vector2 = u.ui_world_to_viewport(cv, expect[name])
		var own: Vector2 = btn.get_global_transform() * (btn.size * 0.5)
		r.check(px.distance_to(own) < 1.0, "%s pivot maps to the control's centre: %s vs %s" % [name, str(px), str(own)])
		var back: Vector3 = u.ui_viewport_to_world(cv, px)
		r.check(back.is_equal_approx(expect[name]), "%s viewport → world round trip: %s" % [name, str(back)])
		var before: int = int(fx.get(counters[name]))
		u.ui_click_world(cv, expect[name])
		await r.wait(3)
		r.check(int(fx.get(counters[name])) == before + 1 and str(fx.get("lastPressed")) == name.trim_suffix("Btn"), "%s pressed through ui_click_world: %d → %d, last=%s" % [name, before, int(fx.get(counters[name])), str(fx.get("lastPressed"))])
	# A canvas parented under a child of a prefab instance (EmyChess hangs its menus on nodes of FBX
	# instances): the RectTransform is a child of a stripped Transform. Holder is at Unity (4, 0, 3),
	# its child Screen 1 m above, the 0.4 x 0.2 m canvas sits on it with ScreenBtn in the middle.
	var scv: Node = r.find("ScreenCanvas")
	var sbtn: Node = r.find("ScreenBtn")
	r.check(scv != null and scv.has_meta("udon_canvas") and sbtn is BaseButton, "canvas under a prefab-instance child is imported with its button: %s %s" % [str(scv), str(sbtn)])
	if scv != null and scv.has_meta("udon_canvas") and sbtn is BaseButton:
		var holder: Node = r.find("Holder")
		r.check(holder != null and holder.is_ancestor_of(scv), "the canvas hangs under the prefab instance: " + str(scv.get_path()))
		var spos: Vector3 = u.get_position(sbtn)
		r.check(spos.is_equal_approx(Vector3(4, 1, 3)), "ScreenBtn world position %s (expected (4, 1, 3))" % str(spos))
		var sbefore: int = int(fx.get("screenPressed"))
		u.ui_click_world(scv, Vector3(4, 1, 3))
		await r.wait(3)
		r.check(int(fx.get("screenPressed")) == sbefore + 1, "ScreenBtn pressed through ui_click_world: %d → %d" % [sbefore, int(fx.get("screenPressed"))])
	# Instance overrides of a scripted component inside the prefab: unidot passes them as a virtual
	# object without m_Script, the plugin finds the class through the node the prefab built.
	var hs: Node = r.behaviour("HolderScreen")
	r.check(hs != null and hs.name == "Screen", "scripted child of the prefab instance: " + str(hs))
	if hs != null:
		r.check(int(hs.get("number")) == 7 and str(hs.get("label")) == "prefab", "value override on the instance (7), untouched field keeps the prefab's: %s %s" % [str(hs.get("number")), str(hs.get("label"))])
		r.check(hs.get("target") == r.find("Target"), "reference override points at an object of the scene: " + str(hs.get("target")))
	var nested: Node = r.find("NestedText")
	r.check(nested is Control and nested.get_global_rect().size.x > 0 and vp != null and Rect2(Vector2.ZERO, Vector2(vp.size)).encloses(nested.get_global_rect()), "nested canvas text lies inside the viewport: " + str(nested.get_global_rect() if nested is Control else null))
	# a text stays inside the plane; a control outside the rect would have grown the plane (checked above)
	if DisplayServer.get_name() == "headless":
		print("[fixture] headless: rendering and window-input checks skipped")
		return
	# camera 1.2 m in front of the canvas (its readable side is -Z in Unity = -Z here too)
	r._place_camera(u.to_gd_v(Vector3(0, 1.5, 1.8)), u.to_gd_v(Vector3(0, 1.5, 3)))
	r.camera().fov = 60
	await r.wait(3)
	await r.shot("ui")
	var colors: Dictionary = {"TL": Color(1, 0, 0), "TR": Color(0, 1, 0), "BL": Color(0, 0, 1), "BR": Color(1, 1, 0), "Center": Color(1, 1, 1), "ScaledBtn": Color(1, 0, 1)}
	var win: Vector2 = Vector2(r.root.get_viewport().get_visible_rect().size)
	var tl_px: Vector2 = r.project(u.to_gd_v(expect["TL"]))
	var br_px: Vector2 = r.project(u.to_gd_v(expect["BR"]))
	r.check(tl_px.x < win.x * 0.5 and tl_px.y < win.y * 0.5 and br_px.x > win.x * 0.5 and br_px.y > win.y * 0.5, "TL projects to the upper left and BR to the lower right of the window: %s %s" % [str(tl_px), str(br_px)])
	for name in colors:
		var wp: Vector2 = r.project(u.to_gd_v(expect[name]))
		var c: Color = await r.pixel(wp)
		var want: Color = colors[name]
		var ok: bool = absf(c.r - want.r) < 0.3 and absf(c.g - want.g) < 0.3 and absf(c.b - want.b) < 0.3
		r.check(ok, "%s renders its colour at the projected pivot %s: %s (want %s)" % [name, str(wp), str(c), str(want)])
	# clicks through the window: the pointer must raycast the canvas and push the event into it
	for name in counters:
		var before: int = int(fx.get(counters[name]))
		await r.click(r.project(u.to_gd_v(expect[name])))
		await r.wait(3)
		r.check(int(fx.get(counters[name])) == before + 1, "%s pressed by a window click: %d → %d" % [name, before, int(fx.get(counters[name]))])
	# slider: press near the left end, drag to the right, release (Unity Slider → HSlider)
	var sl: Node = r.find("Slider")
	r.check(sl is HSlider and is_equal_approx(sl.value, 0.25), "Slider imported as HSlider at 0.25: " + str(sl))
	if sl is HSlider:
		await r.mouse_move(r.project(r.control_world_at(sl, Vector2(0.1, 0.5))))
		await r.mouse_button(true)
		await r.wait(2)
		await r.mouse_move(r.project(r.control_world_at(sl, Vector2(0.5, 0.5))))
		await r.wait(2)
		await r.mouse_move(r.project(r.control_world_at(sl, Vector2(0.9, 0.5))))
		await r.wait(2)
		await r.mouse_button(false)
		await r.wait(3)
		r.check(sl.value > 0.7, "slider dragged through the pointer: value=%.2f" % sl.value)
		r.check(int(fx.get("sliderChanged")) >= 1 and absf(float(fx.get("sliderValue")) - sl.value) < 0.01, "onValueChanged reached the script: %d change(s), value %.2f" % [int(fx.get("sliderChanged")), float(fx.get("sliderValue"))])
	# toggle: one click turns it on and fires onValueChanged
	var tg: Node = r.find("Toggle")
	r.check(tg is BaseButton and tg.toggle_mode and not tg.button_pressed, "Toggle imported as a toggle button, off")
	if tg is BaseButton:
		await r.click(r.project(r.control_world(tg)))
		await r.wait(3)
		r.check(tg.button_pressed and int(fx.get("toggled")) == 1 and bool(fx.get("toggleOn")), "toggle clicked on: isOn=%s, %d event(s)" % [str(fx.get("toggleOn")), int(fx.get("toggled"))])
	# input field: click to focus, type through the window (the pointer forwards keys to the canvas), Enter submits
	var inp: Node = r.find("Input")
	r.check(inp is LineEdit, "InputField imported as LineEdit: " + str(inp))
	if inp is LineEdit:
		await r.click(r.project(r.control_world(inp)))
		await r.wait(2)
		await r.type_text("hi 42", true)
		await r.wait(3)
		r.check(inp.text == "hi 42", "typed text landed in the field: '%s'" % inp.text)
		r.check(int(fx.get("inputEnded")) >= 1 and str(fx.get("inputText")) == "hi 42", "onEndEdit reached the script: '%s' (%d)" % [str(fx.get("inputText")), int(fx.get("inputEnded"))])
	# scroll rect: Item2 starts below the visible part; the wheel scrolls it into view, then it is clicked
	var sc: Node = r.find("Scroll")
	var item2: Node = r.find("Item2")
	r.check(sc is ScrollContainer and item2 is BaseButton, "ScrollRect imported as ScrollContainer with its items: " + str(sc))
	if sc is ScrollContainer and item2 is BaseButton:
		await r.wait(3)
		r.check(sc.get_v_scroll_bar().max_value - sc.get_v_scroll_bar().page > 200.0, "content is taller than the viewport: range %.0f" % (sc.get_v_scroll_bar().max_value - sc.get_v_scroll_bar().page))
		r.check(not sc.get_global_rect().encloses(Rect2(item2.get_global_transform() * Vector2.ZERO, Vector2.ONE)), "Item2 starts outside the visible part")
		await r.mouse_move(r.project(r.control_world(sc)))
		await r.wheel(-12)
		await r.wait(5)
		r.check(sc.scroll_vertical > 150, "wheel scrolled the rect through the pointer: scroll_vertical=%d" % sc.scroll_vertical)
		r.check(int(fx.get("scrollEvents")) >= 1 and float(fx.get("scrollY")) < 0.5, "ScrollRect.onValueChanged reached the script: %d event(s), normalized y %.2f" % [int(fx.get("scrollEvents")), float(fx.get("scrollY"))])
		await r.click(r.project(r.control_world(item2)))
		await r.wait(3)
		r.check(int(fx.get("itemPressed")) == 2, "Item2 clicked after scrolling: itemPressed=%d" % int(fx.get("itemPressed")))
		await r.shot("scrolled")
	# dropdown: a click opens the popup inside the canvas viewport, a second click picks "Blue"
	var dd: Node = r.find("Dropdown")
	r.check(dd is OptionButton and dd.item_count == 3 and dd.selected == 0, "Dropdown imported as OptionButton with 3 options: " + str(dd))
	if dd is OptionButton:
		await r.click(r.project(r.control_world(dd)))
		await r.wait(5)
		var pop: PopupMenu = dd.get_popup()
		r.check(pop.visible, "dropdown popup opened by the pointer")
		await r.shot("dropdown")
		if pop.visible:
			var cvn: Node = u._ui_world_canvas(dd)
			var row: float = float(pop.size.y) / 3.0
			var ppx: Vector2 = Vector2(pop.position) + Vector2(pop.size.x * 0.5, row * 2.5)
			await r.click(r.project(u.to_gd_v(u.ui_viewport_to_world(cvn, ppx))))
			await r.wait(5)
		r.check(dd.selected == 2 and int(fx.get("dropdownChanged")) == 1 and int(fx.get("dropdownValue")) == 2, "picked the third option through the pointer: selected=%d, script saw %d" % [dd.selected, int(fx.get("dropdownValue"))])
	# screen-space overlay canvas: Godot's own GUI handles the click at the control's window rect
	var ob: Node = r.find("OverlayBtn")
	r.check(ob is BaseButton and ob.is_visible_in_tree(), "overlay button imported: " + str(ob))
	if ob is BaseButton:
		var rect: Rect2 = ob.get_global_rect()
		r.check(rect.position.x < 200 and rect.position.y < 100, "overlay button at the window's top-left: " + str(rect))
		await r.click(rect.get_center())
		await r.wait(3)
		r.check(int(fx.get("overlayPressed")) == 1, "overlay button clicked through the window: %d" % int(fx.get("overlayPressed")))
