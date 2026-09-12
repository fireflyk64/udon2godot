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
