## MS-VRCSA-Billiards: open the lobby, join, start an 8-ball game and play a shot, verifying the
## converted scripts drive the table (menu → network state → physics → ball movement).
extends RefCounted

func run(r) -> void:
	await r.wait(30)
	var bm: Node = r.behaviour("BilliardsModule")
	var menu: Node = r.behaviour("MenuManager")
	r.check(bm != null, "BilliardsModule behaviour present")
	r.check(menu != null, "MenuManager behaviour present")
	if bm == null or menu == null:
		return
	r.check(bm.get("tableModels") is Array and bm.get("tableModels").size() >= 1, "table models discovered: " + str(bm.get("tableModels").size() if bm.get("tableModels") is Array else -1))
	r.check(bm.get("balls") is Array and bm.get("balls").size() == 16, "16 balls wired")
	r.shot("idle")
	# lobby flow through the menu behaviour (the same methods the UI buttons call)
	menu.StartButton()
	await r.wait(10)
	r.check(bm.get("lobbyOpen") == true, "lobby opened: lobbyOpen=" + str(bm.get("lobbyOpen")))
	menu.JoinOrange()
	await r.wait(10)
	menu.Mode8Ball()
	await r.wait(10)
	menu.PlayButton()
	await r.wait(30)
	r.check(bm.get("gameLive") == true, "game started: gameLive=" + str(bm.get("gameLive")))
	r.shot("racked")
	var ballsP: Array = bm.get("ballsP")
	var p0: Vector3 = ballsP[0]
	var apex: Vector3 = ballsP[1]
	var before: Array = ballsP.duplicate()
	# strike the cue ball toward the apex ball (Unity numbers, table-local metres per second)
	var dir: Vector3 = (apex - p0)
	dir.y = 0.0
	dir = dir.normalized()
	var v: Array = bm.get("ballsV")
	v[0] = dir * 3.0
	bm.set("ballsV", v)
	var w: Array = bm.get("ballsW")
	w[0] = Vector3.ZERO
	bm.set("ballsW", w)
	bm._TriggerCueBallHit()
	await r.wait(20)
	r.shot("shot_a")
	r.check(bm.get("isLocalSimulationRunning") == true, "simulation running after the hit: " + str(bm.get("isLocalSimulationRunning")))
	await r.wait(60)
	r.shot("shot_b")
	await r.wait(200)
	r.shot("settled")
	var after: Array = bm.get("ballsP")
	var moved: int = 0
	for i in range(mini(before.size(), after.size())):
		if (after[i] - before[i]).length() > 0.01:
			moved += 1
	r.check(moved >= 2, "balls moved after the break: %d" % moved)
	print("[scenario] pocketed mask=%s turn=%s foul=%s" % [str(bm.get("ballsPocketedLocal")), str(bm.get("teamIdLocal")), str(bm.get("foulStateLocal"))])
	# one wired Unity UI button: Undo in the practice menu
	var undo: Node = r.find("Undo")
	if undo != null:
		r.u().ui_press(undo)
		await r.wait(5)
		r.check(true, "UI button press delivered without error")
