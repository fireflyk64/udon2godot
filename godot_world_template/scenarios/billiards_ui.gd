## MS-VRCSA-Billiards: screenshots of the table's UI in each game state, taken from in front of
## the elements the table script places (run on a display with `--shot <dir>/ui.png`), and the
## check that every one of them faces the camera placed on its readable side.
extends RefCounted


func run(r):
	await r.wait(30)
	var bm: Node = r.behaviour("BilliardsModule")
	var menu: Node = r.behaviour("MenuManager")
	r.check(bm != null and menu != null, "BilliardsModule and MenuManager present")
	if bm == null or menu == null:
		return
	await _view(r, bm, "intl.menu/StartMenu/StartButton", 1.2, "start")
	await _wide(r, "idle_wide")
	menu.StartButton()
	await r.wait(10)
	await _view(r, bm, "intl.menu/MenuAnchor/LobbyMenu", 1.6, "lobby")
	await _view(r, bm, "intl.menu/MenuAnchor/JoinMenu", 1.0, "join_lobby")
	menu.JoinOrange()
	await r.wait(10)
	menu.Mode8Ball()
	await r.wait(10)
	await _view(r, bm, "intl.menu/MenuAnchor/LobbyMenu", 1.6, "lobby_8ball")
	menu.PlayButton()
	await r.wait(30)
	r.check(bm.get("gameLive") == true, "game started")
	await _view(r, bm, "intl.scorecardinfo/player0-name/pname0", 1.2, "name0")
	await _view(r, bm, "intl.scorecardinfo/player0-score", 1.0, "score0")
	await _view(r, bm, "intl.menu/MenuAnchor/JoinMenu", 1.0, "join_game")
	await _view(r, bm, "intl.menu/OtherMenu", 1.0, "other")
	await _wide(r, "game_wide")
	return true


## Camera `dist` metres in front of a UI element (its readable side), looking at its centre.
func _view(r, bm: Node, path: String, dist: float, tag: String) -> void:
	var u: Node = r.u()
	var n: Node = u.find_transform(bm, path)
	var ctl: Control = u._ui_ctl(n) if n != null else null
	r.check(ctl != null, path + " found")
	if ctl == null:
		return
	var c: Vector3 = r.control_world(ctl)
	var right: Vector3 = r.control_world_at(ctl, Vector2(1.0, 0.5)) - r.control_world_at(ctl, Vector2(0.0, 0.5))
	var down: Vector3 = r.control_world_at(ctl, Vector2(0.5, 1.0)) - r.control_world_at(ctl, Vector2(0.5, 0.0))
	var normal: Vector3 = -right.cross(down).normalized()
	r.check(c.is_finite() and normal.is_finite() and normal.length() > 0.5, "%s is drawn in the world: centre %s, %.2f x %.2f m, shown=%s" % [path, str(c), right.length(), down.length(), str(ctl.is_visible_in_tree())])
	if not c.is_finite() or not normal.is_finite():
		return
	r._place_camera(c + normal * dist, c)
	await r.wait(3)
	await r.shot(tag)


func _wide(r, tag: String) -> void:
	r._place_camera(Vector3(2.6, 2.4, -2.6), Vector3(0, 0.9, 0))
	await r.wait(3)
	await r.shot(tag)
