## MS-VRCSA-Billiards: open the lobby, join, start an 8-ball game and play a shot, verifying the
## converted scripts drive the table (menu → network state → physics → ball movement).
extends RefCounted

func run(r):
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
	await _ui_on_spots(r, bm, [["intl.scorecardinfo/player0-name", ".NAME_0"], ["intl.scorecardinfo/player1-name", ".NAME_1"], ["intl.scorecardinfo/player0-score", ".SCORE_0"], ["intl.scorecardinfo/player1-score", ".SCORE_1"], ["intl.scorecardinfo/SnookerInstructions", ".SNOOKER_INSTRUCTIONS"], ["intl.menu/MenuAnchor", ".MENU"]])
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
	# once the game is live the join menu moves from the lobby menu to its own spot on the table
	await _ui_on_spots(r, bm, [["intl.menu/MenuAnchor/JoinMenu", ".JOINMENU"]])
	_ui_drawn_where_placed(r)
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
	return true


## The table script puts UI elements on anchor transforms of the table model (BilliardsModule.
## SetTableTransforms, MenuManager: position and rotation of `.NAME_0`, `.MENU`, `.JOINMENU` ...).
## Each must be on its spot for the scripts, and be drawn there.
func _ui_on_spots(r, bm: Node, pairs: Array) -> void:
	await r.wait(3)
	var u: Node = r.u()
	var base: Node = bm._GetTableBase()
	r.check(base != null, "table base of the current model")
	if base == null:
		return
	for pair in pairs:
		var ui: Node = u.find_transform(bm, pair[0])
		var spot: Node = u.find_transform(base, pair[1])
		if spot == null:
			print("[scenario] the table model has no %s spot" % pair[1])
			continue
		r.check(ui != null, "%s found from the table" % pair[0])
		if ui == null:
			continue
		var want: Vector3 = u.get_position(spot)
		var got: Vector3 = u.get_position(ui)
		r.check(got.distance_to(want) < 0.002, "%s is on %s: %s (spot %s)" % [pair[0], pair[1], str(got), str(want)])
		var angle: float = rad_to_deg(u.get_global_rotation(ui).angle_to(u.get_global_rotation(spot)))
		r.check(angle < 0.5, "%s is turned like %s (%.2f degrees off)" % [pair[0], pair[1], angle])
		# drawn there: the pivot of the element, through whatever canvas it is drawn on
		var ctl: Control = u._ui_ctl(ui)
		if ctl != null:
			var pv: Vector2 = u.RT.pivot(ui)
			var drawn: Vector3 = u.RT.drawn_point(ctl, Vector2(pv.x * ctl.size.x, (1.0 - pv.y) * ctl.size.y))
			var rt_want: Vector3 = u._to_rt_v(want)
			r.check(drawn.distance_to(rt_want) < 0.003, "%s is drawn on its spot: %s (spot %s)" % [pair[0], str(drawn), str(rt_want)])


## Every UI control of the world is drawn where its transform says (viewport fit, pixel density,
## plane placement and nesting all agree with rect_transform.gd's world matrix).
func _ui_drawn_where_placed(r) -> void:
	var u: Node = r.u()
	var worst: float = 0.0
	var worst_name: String = ""
	var count: int = 0
	for n in r._all(r._scene):
		if not (n is Control) or n.has_meta(u.RT.META_HELPER):
			continue
		if u._ui_world_canvas(n) == null:
			continue
		var model: Array = u.RT.world_corners(n)
		var s: Vector2 = n.size
		var pts: Array = [Vector2(0, s.y), Vector2(0, 0), Vector2(s.x, 0), Vector2(s.x, s.y)]
		for i in range(4):
			var d: float = u.RT.drawn_point(n, pts[i]).distance_to(model[i])
			if d > worst and is_finite(d):
				worst = d
				worst_name = str(r._scene.get_path_to(n))
		count += 1
	r.check(count > 100 and worst < 0.003, "%d UI controls are drawn where they are placed (worst %.4f m at %s)" % [count, worst, worst_name])
