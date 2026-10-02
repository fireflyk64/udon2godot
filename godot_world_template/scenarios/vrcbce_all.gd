## vrcbce's sample scene (Samples~/Demo Scene/VRCBilliardsCE_All_Tables): several tables side by
## side, each an instance of another table prefab with its own PoolStateManager, menu and
## balls (one of them the fox table with its fur balls). Every table is taken through a game on
## its own: unlocked, joined, started, a break played, the turn ended. None may touch another.
extends RefCounted

func run(r):
	await r.wait(30)
	var u = r.u()
	var managers: Array = []
	for n in r._all(r.find(".")):
		if n.has_meta("udon_class") and str(n.get_meta("udon_class")) == "PoolStateManager":
			managers.append(n)
	r.check(managers.size() >= 3, "the sample scene's tables, each with its PoolStateManager: %d" % managers.size())
	var idle: int = 0
	for mgr in managers:
		if mgr.get("isTableLocked") == true and mgr.get("isGameInMenus") == true:
			idle += 1
	r.check(idle == managers.size(), "every table starts locked, in its menus: %d of %d" % [idle, managers.size()])
	r.shot("idle")
	for index in range(managers.size()):
		var mgr: Node = managers[index]
		var table: Node = _table_of(r, mgr)
		var name: String = String(table.name) if table != null else "table %d" % index
		var menu: Node = mgr.get("poolMenu") as Node
		r.check(table != null and menu != null, "%s: its menu: %s" % [name, str(menu)])
		if table == null or menu == null:
			continue
		# the menu: buttons of a canvas, or objects with colliders that are used (their
		# behaviour passes the event on), found by the event either sends
		r.check(_send(r, table, "_UnlockTable"), "%s: something unlocks the table" % name)
		await r.wait(10)
		r.check(mgr.get("isTableLocked") == false, "%s: unlocked" % name)
		r.check(_send(r, table, "_SignUpAsPlayer1"), "%s: something signs the player up" % name)
		await r.wait(10)
		r.check(_send(r, table, "_StartGame"), "%s: something starts the game" % name)
		await r.wait(30)
		r.check(mgr.get("isGameInMenus") == false, "%s: the game started" % name)
		var waited: int = 0
		while float(mgr.get("introAnimTimer")) > 0.0 and waited < 900:
			await r.wait(10)
			waited += 10
		# the break: the cue ball towards the rack
		var balls = mgr.get("ballTransforms")
		var pos: Array = mgr.get("currentBallPositions")
		var before: Array = pos.duplicate()
		var target := Vector3.ZERO
		var count: int = 0
		for i in range(1, mini(16, pos.size())):
			if balls is Array and i < balls.size() and (balls[i] as Node3D).is_visible_in_tree():
				target += pos[i]
				count += 1
		r.check(count >= 9, "%s: racked balls on the table: %d" % [name, count])
		if count == 0:
			continue
		var dir: Vector3 = target / float(count) - (pos[0] as Vector3)
		dir.y = 0.0
		var v: Array = mgr.get("currentBallVelocities")
		v[0] = dir.normalized() * 4.0
		mgr.set("currentBallVelocities", v)
		mgr.HandleCueBallHit()
		await r.wait(120)
		var after: Array = mgr.get("currentBallPositions")
		var moved: int = 0
		for i in range(mini(before.size(), after.size())):
			if ((after[i] as Vector3) - (before[i] as Vector3)).length() > 0.01:
				moved += 1
		r.check(moved >= 3, "%s: balls moved after the break: %d" % [name, moved])
		var frames: int = 0
		while mgr.get("turnIsRunning") == true and frames < 1500:
			await r.wait(30)
			frames += 30
		r.check(mgr.get("turnIsRunning") == false, "%s: the balls come to rest and the turn ends (after %d more frames)" % [name, frames])
		# the other tables were not touched
		var others_idle: int = 0
		for j in range(index + 1, managers.size()):
			if managers[j].get("isTableLocked") == true and managers[j].get("isGameInMenus") == true:
				others_idle += 1
		r.check(others_idle == managers.size() - index - 1, "%s: the tables not yet played are still locked: %d" % [name, others_idle])
	r.shot("played")
	return true


## The table (a child of the scene's root) a node belongs to.
func _table_of(r, n: Node) -> Node:
	var root: Node = r.find(".")
	var cur: Node = n
	while cur != null and cur.get_parent() != root:
		cur = cur.get_parent()
	return cur


## Use what sends `event` below `table`: the first canvas button whose click does, or the
## first object whose behaviour passes it on when it is used (ActivaterUdonEvent).
func _send(r, table: Node, event: String) -> bool:
	for n in r._all(table):
		if n is BaseButton:
			for sig in ["pressed", "toggled"]:
				for c in n.get_signal_connection_list(sig):
					var call: Callable = c["callable"]
					if call.get_bound_arguments().has(event):
						r.u().ui_press(n, null)
						return true
	for n in r._all(table):
		if n.has_meta("udon_class") and str(n.get_meta("udon_class")) == "ActivaterUdonEvent" and str(n.get("eventName")) == event:
			n.Interact()
			return true
	return false
