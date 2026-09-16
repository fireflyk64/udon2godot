## MS-VRCSA-Billiards played through the desktop player: only window input reaches the game — the
## 3D START button (head ray + left mouse, UIButton.cs), the lobby canvas buttons (pointer raycast
## → viewport), the cue pickup (pointer → VRC_Pickup), E for desktop aiming, mouse deltas to aim
## and pull, release to shoot. Run with `world_runner.gd --play` on a display
## (scripts/test_world_billiards.sh does, after the headless scenario).
extends RefCounted

const CURSOR_PER_PIXEL: float = 0.0035  # DesktopManager: cursor += Mouse X (= pixels × 0.1) × 0.035

func run(r) -> void:
	await r.wait(30)
	var u: Node = r.u()
	var udon: Node = r.udon()
	var bm: Node = r.behaviour("BilliardsModule")
	var dm: Node = r.behaviour("DesktopManager")
	var player: Node = r.player()
	r.check(player != null and bm != null and dm != null, "desktop player, BilliardsModule and DesktopManager present")
	if player == null or bm == null or dm == null:
		return
	# the START button of the menu canvas (StartMenu is a 100 × 100 container scaled 200×)
	var start: Node = r.find_button("StartButton")
	r.check(start is BaseButton, "START canvas button visible: " + str(start))
	if not (start is BaseButton):
		return
	await r.face_control(start, 1.5)
	await r.wait(5)
	await r.shot("start")
	r.check(udon.local_player().get_tracking_data(0)["position"].y > 1.0, "head tracking data at eye height")
	await r.click_control(start)
	await r.wait(15)
	r.check(bm.get("lobbyOpen") == true, "START clicked through the pointer opened the lobby: lobbyOpen=" + str(bm.get("lobbyOpen")))
	# lobby canvas: join orange (unless the opener is already in), 8 ball, play — through the pointer
	for name in ["JoinOrange", "Mode8Ball", "PlayButton"]:
		var btn: Node = r.find_button(name)
		if name == "JoinOrange" and btn == null:
			print("[play] JoinOrange hidden: the lobby opener is already seated")
			continue
		r.check(btn is BaseButton, name + " is a visible canvas button")
		if not (btn is BaseButton):
			continue
		await r.click_control(btn)
		await r.wait(15)
		await r.shot(name.to_lower())
	r.check(bm.get("gameLive") == true, "game started through the lobby canvas: gameLive=" + str(bm.get("gameLive")))
	if bm.get("gameLive") != true:
		return
	# the orange cue: its primary grip is a VRC_Pickup shown once the game is live
	var cc: Node = bm.get("cueControllers")[0]
	var grip: Node3D = cc.get("primary") as Node3D
	r.check(grip != null and udon.has_component(grip, "pickup"), "orange cue grip is a pickup: " + str(grip))
	if grip == null:
		return
	var gpos: Vector3 = grip.global_position
	var gaway: Vector3 = Vector3(gpos.x, 0.0, gpos.z).normalized()
	await r.place_player(gpos + gaway * 1.2)
	player.look_at_point(gpos)
	await r.wait(5)
	var ptr: Node = udon.pointer()
	await r.mouse_move(r.project(gpos))
	await r.wait(2)
	r.check(str(ptr.hit.get("kind")) == "pickup", "pointer over the cue grip: " + str(ptr.hit.get("kind")) + " " + str(ptr.hit.get("target")))
	await r.click(r.project(gpos))
	await r.wait(10)
	r.check(ptr.held != null and dm.get("holdingCue") == true, "cue picked up through the pointer: holdingCue=" + str(dm.get("holdingCue")))
	await r.shot("cue")
	# E enters the desktop aiming view (top-down camera, cursor, power)
	await r.key(KEY_E, 2)
	await r.wait(10)
	r.check(dm.get("inUI") == true, "E entered the desktop aiming UI: inUI=" + str(dm.get("inUI")))
	for i in range(40):
		if dm.get("canShoot") == true:
			break
		await r.wait(3)
	r.check(dm.get("canShoot") == true, "local player may shoot: canShoot=" + str(dm.get("canShoot")))
	await r.shot("aim")
	# aim at the apex ball: the cursor moves with the mouse deltas, then pull back with Mouse0 held
	var ballsP: Array = bm.get("ballsP")
	var cue: Vector3 = ballsP[0]
	var apex: Vector3 = ballsP[1]
	var cursor: Vector3 = dm.get("cursor") if dm.get("cursor") is Vector3 else Vector3.ZERO
	var need: Vector3 = apex - cursor
	await r.mouse_delta(Vector2(need.x, -need.z) / CURSOR_PER_PIXEL)
	await r.wait(3)
	var cur2 = dm.get("cursor")
	r.check(cur2 is Vector3 and absf(cur2.x - apex.x) < 0.05 and absf(cur2.z - apex.z) < 0.05, "cursor on the apex ball: %s vs %s" % [str(cur2), str(apex)])
	await r.mouse_button(true)
	await r.wait(3)
	r.check(dm.get("isShooting") == true, "holding Mouse0 starts the shot (Input.GetKey(KeyCode.Mouse0)): isShooting=" + str(dm.get("isShooting")))
	var dir: Vector3 = apex - cue
	dir.y = 0.0
	dir = dir.normalized()
	await r.mouse_delta(Vector2(-dir.x, dir.z) * 0.35 / CURSOR_PER_PIXEL)
	await r.wait(3)
	var power = dm.get("power")
	r.check(power is float and power > 0.1, "power built by pulling the mouse back: " + str(power))
	var before: Array = ballsP.duplicate()
	await r.mouse_button(false)
	await r.wait(20)
	r.check(bm.get("isLocalSimulationRunning") == true, "shot fired on release: simulation running")
	await r.shot("shot")
	await r.wait(240)
	var after: Array = bm.get("ballsP")
	var moved: int = 0
	for i in range(mini(before.size(), after.size())):
		if (after[i] - before[i]).length() > 0.01:
			moved += 1
	r.check(moved >= 2, "balls moved after the shot: %d" % moved)
	await r.shot("settled")
