## Desktop player smoke test on tests/unity_fixture (run with --play on a display): walks, jumps,
## frees the mouse and clicks the UiCanvas through the player's camera, and reports tracking data.
extends RefCounted

func run(r) -> void:
	await r.wait(10)
	var u: Node = r.u()
	var udon: Node = r.udon()
	var player: Node = r.player()
	r.check(player is CharacterBody3D, "desktop player spawned: " + str(player))
	if player == null:
		return
	r.check(udon.local_player().node == player, "Udon.local_player().node is the desktop player")
	r.check(r.root.get_viewport().get_camera_3d() == player.camera, "player camera is current")
	await r.wait(20)  # settle on the floor
	var p0: Vector3 = player.global_position
	r.check(player.is_on_floor(), "player stands on the floor at y=%.2f" % p0.y)
	await r.key(KEY_W, 30)
	var p1: Vector3 = player.global_position
	r.check(p1.z - p0.z > 0.5, "W walks forward along +Z: %.2f m" % (p1.z - p0.z))
	await r.key(KEY_S, 30)
	r.check(absf(player.global_position.z - p0.z) < 0.3, "S walks back: z=%.2f" % player.global_position.z)
	await r.key(KEY_D, 20)
	r.check(player.global_position.x - p0.x < -0.2, "D strafes to screen-right (-X): %.2f" % (player.global_position.x - p0.x))
	await r.key(KEY_A, 20)
	var top: float = player.global_position.y
	await r.key(KEY_SPACE, 2)
	for i in range(20):
		await r.wait(1)
		top = maxf(top, player.global_position.y)
	r.check(top - p0.y > 0.1, "Space jumps: rose %.2f m" % (top - p0.y))
	var head: Dictionary = udon.local_player().get_tracking_data(0)
	var body: Vector3 = u.get_position(player)
	r.check(absf(head["position"].y - (body.y + 1.6)) < 0.05, "head tracking data at eye height: %s vs body %s" % [str(head["position"]), str(body)])
	r.check(absf(head["position"].x - body.x) < 0.05, "head tracking data above the body (x)")
	# the fixture canvas sits 3 m ahead at eye height; free the mouse and click its buttons
	await r.wait(30)
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		await r.key(KEY_ESCAPE)
	r.check(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED, "Esc frees the mouse")
	var fx: Node = r.behaviour("Fixture")
	for name in {"TL": [Vector3(-0.44, 1.77, 3), "pressedTL"], "BR": [Vector3(0.44, 1.23, 3), "pressedBR"], "Center": [Vector3(0, 1.5, 3), "pressedCenter"]}.keys():
		var e: Array = {"TL": [Vector3(-0.44, 1.77, 3), "pressedTL"], "BR": [Vector3(0.44, 1.23, 3), "pressedBR"], "Center": [Vector3(0, 1.5, 3), "pressedCenter"]}[name]
		var before: int = int(fx.get(e[1]))
		var px: Vector2 = r.project(u.to_gd_v(e[0]))
		await r.click(px)
		await r.wait(3)
		r.check(int(fx.get(e[1])) == before + 1, "%s clicked through the player's camera at %s: %d → %d" % [name, str(px), before, int(fx.get(e[1]))])
	await r.shot("player")
