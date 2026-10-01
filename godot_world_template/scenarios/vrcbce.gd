## vrcbce (VRCBilliards Community Edition), one table prefab as the scene: unlock the table, sign
## up, start an 8-ball game and break, through the menu's own buttons (menu → PoolStateManager →
## synced state → physics → ball transforms), with the ball shadows following by their
## PositionConstraints.
extends RefCounted

func run(r):
	await r.wait(30)
	var mgr: Node = r.behaviour("PoolStateManager")
	var menu: Node = r.behaviour("PoolMenu")
	r.check(mgr != null, "PoolStateManager behaviour present (a partial class of eight files)")
	r.check(menu != null, "PoolMenu behaviour present")
	if mgr == null or menu == null:
		return
	var u = r.u()
	# the program has more fields than the sandbox used to allow properties (256): the last
	# ones declared are still there
	var names: Dictionary = {}
	for p in mgr.get_property_list():
		names[str(p["name"])] = true
	var missing: Array = []
	for f in ["ballTransforms", "ballShadowPosConstraints", "isGameInMenus", "isTableLocked", "turnIsRunning", "currentBallPositions", "currentBallVelocities", "isCueOutOfBounds", "_preventEndOfTurn"]:
		if not names.has(f):
			missing.append(f)
	r.check(missing.is_empty(), "fields of PoolStateManager are properties of its program: missing " + str(missing))
	var balls = mgr.get("ballTransforms")
	r.check(balls is Array and balls.size() == 16 and balls[0] is Node3D and balls[15] is Node3D, "16 balls wired: " + str(balls.size() if balls is Array else balls))
	var cons = mgr.get("ballShadowPosConstraints")
	r.check(cons is Array and cons.size() == 16 and cons[0] is Node, "16 shadow constraints wired: " + str(cons.size() if cons is Array else cons))
	r.check(mgr.get("isTableLocked") == true and mgr.get("isGameInMenus") == true, "a locked table in its menus at start: locked=%s menus=%s" % [str(mgr.get("isTableLocked")), str(mgr.get("isGameInMenus"))])
	r.shot("idle")

	# unlock: an object with a collider that is used (ActivaterUdonEvent.Interact passes the
	# event on), or in other menu styles a UI button that calls that Interact
	var unlock_button: BaseButton = _button_sending(r, "_UnlockTable")
	var unlock_object: Node = null
	for n in r._all(r.find(".")):
		if n.has_meta("udon_class") and str(n.get_meta("udon_class")) == "ActivaterUdonEvent" and str(n.get("eventName")) == "_UnlockTable":
			unlock_object = n
	r.check(unlock_button != null or unlock_object != null, "something unlocks the table: button %s, object %s" % [str(unlock_button), str(unlock_object)])
	if unlock_button != null:
		u.ui_press(unlock_button, null)
	elif unlock_object != null:
		r.check(unlock_object.get("behaviour") == menu, "the unlock object's target is the menu: " + str(unlock_object.get("behaviour")))
		unlock_object.Interact()
	await r.wait(10)
	# sign up, start: the buttons of the menu, found by the event they send
	r.check(mgr.get("isTableLocked") == false, "the table is unlocked: isTableLocked=" + str(mgr.get("isTableLocked")))
	var join: BaseButton = _button_sending(r, "_SignUpAsPlayer1")
	r.check(join != null and join.is_visible_in_tree(), "the main menu shows the sign-up button once unlocked: " + str(join))
	if join != null:
		u.ui_press(join, null)
		await r.wait(10)
	r.check(menu.get("isSignedUpToPlay") == true and menu.get("canStartGame") == true, "signed up as player 1: signedUp=%s canStart=%s" % [str(menu.get("isSignedUpToPlay")), str(menu.get("canStartGame"))])
	var start: BaseButton = _button_sending(r, "_StartGame")
	r.check(start != null, "a button sends _StartGame")
	if start != null:
		u.ui_press(start, null)
		await r.wait(30)
	r.check(mgr.get("isGameInMenus") == false, "the game started: isGameInMenus=" + str(mgr.get("isGameInMenus")))
	# the intro animation drops the balls in one by one and places the shadows itself; the
	# delayed event that ends it hands the shadows back to their constraints
	var waited: int = 0
	while float(mgr.get("introAnimTimer")) > 0.0 and waited < 900:
		await r.wait(10)
		waited += 10
	await r.wait(5)
	var active: int = 0
	for c in cons:
		if u.constraint_get(c, "active", false) == true:
			active += 1
	r.check(float(mgr.get("introAnimTimer")) <= 0.0 and active == 16, "after the intro animation (%d frames) the 16 shadow constraints are active again: %d" % [waited, active])
	r.shot("racked")
	var pos: Array = mgr.get("currentBallPositions")
	r.check(pos.size() == 16, "ball positions: " + str(pos.size()))
	# the balls are where the state says (table-local positions), each shadow under its ball
	var apart: int = 0
	for i in range(mini(16, pos.size())):
		var b: Node3D = balls[i]
		if b.is_visible_in_tree() and ((u.get_local_position(b) as Vector3) - (pos[i] as Vector3)).length() > 0.005:
			apart += 1
	r.check(apart == 0, "ball transforms are at the state's positions: %d apart" % apart)
	var loose: Array = []
	for i in range(16):
		var c: Node = cons[i]
		var b: Node3D = balls[i]
		if c is Node3D and b.is_visible_in_tree() and (c as Node3D).is_visible_in_tree():
			var d: Vector3 = (u.get_position(c) as Vector3) - (u.get_position(b) as Vector3)
			if Vector2(d.x, d.z).length() > 0.002:
				loose.append(i)
	r.check(loose.is_empty(), "every ball shadow is under its ball (PositionConstraint): loose " + str(loose))

	# the break: the cue ball towards the rack
	var before: Array = pos.duplicate()
	var target: Vector3 = Vector3.ZERO
	var count: int = 0
	for i in range(1, 16):
		if (balls[i] as Node3D).is_visible_in_tree():
			target += pos[i]
			count += 1
	r.check(count >= 9, "racked balls on the table: %d" % count)
	if count == 0:
		return
	var dir: Vector3 = target / float(count) - (pos[0] as Vector3)
	dir.y = 0.0
	var v: Array = mgr.get("currentBallVelocities")
	v[0] = dir.normalized() * 4.0
	mgr.set("currentBallVelocities", v)
	mgr.HandleCueBallHit()
	await r.wait(15)
	r.check(mgr.get("turnIsRunning") == true, "the turn runs after the hit: " + str(mgr.get("turnIsRunning")))
	r.shot("shot_a")
	await r.wait(120)
	r.shot("shot_b")
	var after: Array = mgr.get("currentBallPositions")
	var moved: int = 0
	for i in range(mini(before.size(), after.size())):
		if ((after[i] as Vector3) - (before[i] as Vector3)).length() > 0.01:
			moved += 1
	r.check(moved >= 3, "balls moved after the break: %d" % moved)
	# ... and the shadows went with them
	loose = []
	for i in range(16):
		var c: Node = cons[i]
		var b: Node3D = balls[i]
		if c is Node3D and b.is_visible_in_tree() and (c as Node3D).is_visible_in_tree() and u.constraint_get(c, "active", false) == true:
			var d: Vector3 = (u.get_position(c) as Vector3) - (u.get_position(b) as Vector3)
			if Vector2(d.x, d.z).length() > 0.002:
				loose.append(i)
	active = 0
	for c in cons:
		if u.constraint_get(c, "active", false) == true:
			active += 1
	r.check(loose.is_empty() and active >= 10, "the shadows follow the moving balls (%d constraints active): loose %s" % [active, str(loose)])
	# the simulation comes to rest and the turn ends
	var frames: int = 0
	while mgr.get("turnIsRunning") == true and frames < 1500:
		await r.wait(30)
		frames += 30
	r.check(mgr.get("turnIsRunning") == false, "the balls come to rest and the turn ends (after %d more frames)" % frames)
	r.shot("settled")
	print("[scenario] team2 turn=%s foul=%s game over=%s" % [str(mgr.get("isTeam2Turn")), str(mgr.get("isFoul")), str(mgr.get("isGameOver"))])
	return true


## The first button whose click sends `event` to a behaviour (the UnityEvent the importer wired):
## by SendCustomEvent, or by the Interact of a behaviour that passes it on (ActivaterUdonEvent,
## how the table is unlocked).
func _button_sending(r, event: String) -> BaseButton:
	for n in r._all(r.find(".")):
		if n is BaseButton:
			for sig in ["pressed", "toggled"]:
				for c in n.get_signal_connection_list(sig):
					var call: Callable = c["callable"]
					if call.get_bound_arguments().has(event):
						return n
					var target: Object = call.get_object()
					if call.get_method() == &"Interact" and target != null and str(target.get("eventName")) == event:
						return n
	return null
