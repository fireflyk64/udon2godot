## VR input on tests/unity_fixture with simulated controllers (world_runner.gd --vr-sim): the hands
## are placed and aimed by the scenario and `simulate_button` / `simulate_stick` run the handlers
## the OpenXR controller signals call. Checks the per-hand pointers (canvas presses through each
## controller's ray), InputUse with its hand type, tracking data, stick locomotion and snap turn,
## and sitting in a station with the trigger and leaving with A/X.
extends RefCounted

func run(r) -> void:
	await r.wait(10)
	var u: Node = r.u()
	var udon: Node = r.udon()
	var player: Node = r.player()
	var fx: Node = r.behaviour("Fixture")
	r.check(player != null and player.simulate and fx != null, "VR player with simulated controllers present")
	if player == null or fx == null:
		return
	r.check(udon.local_player().is_user_in_vr(), "Networking.LocalPlayer.IsUserInVR() is true")
	# each hand presses its own button on the world canvas
	var targets: Dictionary = {"right": ["TL", Vector3(-0.44, 1.77, 3), "pressedTL", 0], "left": ["TR", Vector3(0.44, 1.77, 3), "pressedTR", 1]}
	for side in targets:
		var t: Array = targets[side]
		var hand: Node3D = player.hands[side]
		hand.look_at(u.to_gd_v(t[1]), Vector3.UP)
		await r.wait(3)
		var ptr: Node = player.pointers[side]
		r.check(str(ptr.hit.get("kind")) == "canvas", "%s controller ray lands on the canvas: %s" % [side, str(ptr.hit.get("kind"))])
		var before: int = int(fx.get(t[2]))
		var uses: int = int(fx.get("useEvents"))
		player.simulate_button(side, "trigger_click", true)
		await r.wait(2)
		player.simulate_button(side, "trigger_click", false)
		await r.wait(3)
		r.check(int(fx.get(t[2])) == before + 1, "%s trigger pressed %s: %d → %d" % [side, t[0], before, int(fx.get(t[2]))])
		r.check(int(fx.get("useEvents")) == uses + 1 and int(fx.get("lastUseHand")) == t[3], "InputUse raised with handType %d: %d event(s), hand %d" % [t[3], int(fx.get("useEvents")) - uses, int(fx.get("lastUseHand"))])
	# tracking data comes from the controllers and the head
	var rh: Dictionary = udon.local_player().get_tracking_data(2)
	r.check((rh["position"] as Vector3).distance_to(u.from_gd_v(player.hands["right"].global_position)) < 0.001, "right hand tracking data is the controller: " + str(rh["position"]))
	var hd: Dictionary = udon.local_player().get_tracking_data(0)
	r.check((hd["position"] as Vector3).distance_to(u.from_gd_v(player.camera.global_position)) < 0.001, "head tracking data is the headset: " + str(hd["position"]))
	# left stick forward walks along the head's yaw and raises InputMoveVertical
	var p0: Vector3 = player.global_position
	player.simulate_stick("left", Vector2(0, 1))
	for i in range(40):
		await r.root.get_tree().physics_frame
	player.simulate_stick("left", Vector2.ZERO)
	await r.wait(3)
	r.check(player.global_position.z - p0.z > 0.5 and absf(player.global_position.x - p0.x) < 0.05, "left stick walks forward: %s → %s" % [str(p0), str(player.global_position)])
	r.check(is_equal_approx(float(fx.get("moveV")), 0.0), "InputMoveVertical returned to 0 after release: %.2f" % float(fx.get("moveV")))
	# right stick snap turn
	var yaw0: float = player.rotation.y
	player.simulate_stick("right", Vector2(1, 0))
	for i in range(5):
		await r.root.get_tree().physics_frame
	player.simulate_stick("right", Vector2.ZERO)
	await r.wait(2)
	r.check(is_equal_approx(wrapf(player.rotation.y - yaw0, -PI, PI), -deg_to_rad(30.0)), "snap turn of 30 degrees to the right: %.1f" % rad_to_deg(wrapf(player.rotation.y - yaw0, -PI, PI)))
	player.rotation.y = yaw0
	# station: aim the left hand at the chair, trigger sits, A/X leaves
	var chair: Node3D = r.find("Chair")
	var chair_script: Node = r.behaviour("Chair")
	if chair != null and chair_script != null:
		var cpos: Vector3 = chair.global_position
		await r.place_player(cpos + Vector3(0, -0.75, -1.6))
		var lh: Node3D = player.hands["left"]
		lh.look_at(cpos, Vector3.UP)
		await r.wait(3)
		r.check(str(player.pointers["left"].hit.get("kind")) == "station", "left ray on the chair: " + str(player.pointers["left"].hit.get("kind")))
		var entered: int = int(chair_script.get("entered"))
		player.simulate_button("left", "trigger_click", true)
		await r.wait(2)
		player.simulate_button("left", "trigger_click", false)
		await r.wait(3)
		r.check(player.station != null and int(chair_script.get("entered")) == entered + 1 and player.global_position.distance_to(cpos) < 0.05, "trigger seated the VR player: entered=%d" % int(chair_script.get("entered")))
		player.simulate_button("right", "ax_button", true)
		await r.wait(2)
		player.simulate_button("right", "ax_button", false)
		await r.wait(3)
		r.check(player.station == null and int(chair_script.get("exited")) >= 1, "A/X left the station: exited=%d" % int(chair_script.get("exited")))
