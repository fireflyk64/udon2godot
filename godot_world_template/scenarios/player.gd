## Desktop player smoke test on tests/unity_fixture (run with --play on a display): walks, jumps,
## frees the mouse and clicks the UiCanvas through the player's camera, and reports tracking data.
extends RefCounted

func run(r):
	await r.wait(10)
	var u: Node = r.u()
	var udon: Node = r.udon()
	var player: Node = r.player()
	r.check(player is CharacterBody3D, "desktop player spawned: " + str(player))
	if player == null:
		return
	r.check(udon.local_player().node == player, "Udon.local_player().node is the desktop player")
	var sp: Node = r.find("Spawn")
	r.check(sp is Node3D and Vector2(player.spawn_transform.origin.x, player.spawn_transform.origin.z).distance_to(Vector2(sp.global_position.x, sp.global_position.z)) < 0.01, "spawned at the scene descriptor's spawn: %s vs %s" % [str(player.spawn_transform.origin), str(sp.global_position if sp is Node3D else null)])
	r.check(is_equal_approx(player.respawn_height, -25.0), "respawn height from the descriptor: %.1f" % player.respawn_height)
	r.check(r.root.get_viewport().get_camera_3d() == player.camera, "player camera is current")
	await r.wait(20)  # settle on the floor
	var p0: Vector3 = player.global_position
	r.check(player.is_on_floor(), "player stands on the floor at y=%.2f" % p0.y)
	await r.key(KEY_W, 30)
	var p1: Vector3 = player.global_position
	r.check(p1.z - p0.z > 0.5, "W walks forward along +Z: %.2f m" % (p1.z - p0.z))
	await r.key(KEY_S, 30)
	r.check(player.global_position.z < p1.z - 0.3, "S walks back: z=%.2f (was %.2f)" % [player.global_position.z, p1.z])
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
	# station: a VRCStation on the Chair box at Unity (3, 0.75, 0); look at it, click to sit, Space to leave
	var chair: Node = r.find("Chair")
	var chair_script: Node = r.behaviour("Chair")
	r.check(chair is Node3D and udon.has_component(chair, "station") and chair_script != null, "Chair is a station with a behaviour: " + str(chair))
	if chair is Node3D and chair_script != null:
		var cpos: Vector3 = chair.global_position
		await r.place_player(cpos + Vector3(0, -0.75, -1.6))
		player.look_at_point(cpos)
		await r.wait(3)
		await r.mouse_move(r.project(cpos))
		await r.wait(2)
		var ptr: Node = udon.pointer()
		r.check(str(ptr.hit.get("kind")) == "station" and ptr.hover_text == "Sit", "pointer over the chair: %s '%s'" % [str(ptr.hit.get("kind")), ptr.hover_text])
		await r.click(r.project(cpos))
		await r.wait(5)
		r.check(player.station != null and int(chair_script.get("entered")) == 1, "seated through the pointer: station=%s entered=%d" % [str(player.station), int(chair_script.get("entered"))])
		r.check(player.global_position.distance_to(cpos) < 0.05, "body at the station's enter location: " + str(player.global_position))
		var seated_pos: Vector3 = player.global_position
		await r.key(KEY_W, 20)
		r.check(player.global_position.distance_to(seated_pos) < 0.01, "locomotion ignored while seated")
		await r.shot("seated")
		await r.key(KEY_SPACE, 2)
		await r.wait(10)
		var exit_node: Node3D = chair.get_node_or_null("ChairExit")
		r.check(player.station == null and int(chair_script.get("exited")) == 1, "Space leaves the station: exited=%d" % int(chair_script.get("exited")))
		r.check(exit_node != null and Vector2(player.global_position.x, player.global_position.z).distance_to(Vector2(exit_node.global_position.x, exit_node.global_position.z)) < 0.1, "body at the exit location: %s vs %s" % [str(player.global_position), str(exit_node.global_position if exit_node else null)])
		# VRCPlayerApi.UseAttachedStation from the chair's own script seats the player again
		await r.place_player(cpos + Vector3(0, -0.75, -1.6))
		chair_script.SitMe()
		await r.wait(5)
		r.check(player.station != null and int(chair_script.get("entered")) == 2 and player.global_position.distance_to(cpos) < 0.05, "UseAttachedStation seated the player: entered=%d" % int(chair_script.get("entered")))
		await r.key(KEY_SPACE, 2)
		await r.wait(5)
		r.check(player.station == null and int(chair_script.get("exited")) == 2, "left again: exited=%d" % int(chair_script.get("exited")))
	await r.shot("player")
	return true
