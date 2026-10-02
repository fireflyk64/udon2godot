## vrcbce (VRCBilliards Community Edition) played through the desktop player: only window input
## reaches the game. The menu's canvas buttons unlock the table, sign up and start (pointer
## raycast → viewport), the cue is a VRC_Pickup taken with the pointer, E enters the top-down
## view, the left mouse button (InputUse) is held to build the shot and released to shoot.
## Run with `world_runner.gd --play` on a display (scripts/test_world_community.sh does).
extends RefCounted

func run(r):
	await r.wait(30)
	var udon: Node = r.udon()
	var mgr: Node = r.behaviour("PoolStateManager")
	var player: Node = r.player()
	r.check(player != null and mgr != null, "desktop player and PoolStateManager present")
	if player == null or mgr == null:
		return
	var ptr: Node = udon.pointer()
	# unlock: in this menu style an object with a collider that is used (its behaviour passes
	# the event on), looked at and clicked
	var unlock: Node3D = null
	for n in r._all(r.find(".")):
		if n.has_meta("udon_class") and str(n.get_meta("udon_class")) == "ActivaterUdonEvent" and str(n.get("eventName")) == "_UnlockTable":
			unlock = n as Node3D
	if unlock != null:
		var at: Vector3 = unlock.global_position
		var table_centre: Vector3 = (mgr.get("tableSurface") as Node3D).global_position if mgr.get("tableSurface") is Node3D else Vector3.ZERO
		var out: Vector3 = Vector3(at.x - table_centre.x, 0.0, at.z - table_centre.z).normalized()
		await r.place_player(at + out * 1.0)
		player.look_at_point(at)
		await r.wait(5)
		await r.mouse_move(r.project(at))
		await r.wait(3)
		r.check(str(ptr.hit.get("kind")) == "interact" and ptr.hover_target == unlock, "pointer over the object that unlocks the table: %s %s" % [str(ptr.hit.get("kind")), str(ptr.hover_target)])
		await r.click(r.project(at))
		await r.wait(20)
		r.check(mgr.get("isTableLocked") == false, "used through the pointer: the table is unlocked: " + str(mgr.get("isTableLocked")))
	for event in (["_SignUpAsPlayer1", "_StartGame"] if unlock != null else ["_UnlockTable", "_SignUpAsPlayer1", "_StartGame"]):
		var btn: BaseButton = _button_sending(r, event)
		r.check(btn != null and btn.is_visible_in_tree(), "the menu shows the button that sends %s: %s" % [event, str(btn)])
		if btn == null:
			return
		await r.face_control(btn, 1.2)
		await r.wait(5)
		await r.click_control(btn)
		await r.wait(20)
	r.check(mgr.get("isGameInMenus") == false, "the game started through the menu canvas: isGameInMenus=" + str(mgr.get("isGameInMenus")))
	if mgr.get("isGameInMenus") != false:
		return
	await r.shot("started")
	# the cue of the first player: its handle is a pickup
	var cues = mgr.get("poolCues")
	var grip: Node3D = cues[0] as Node3D if cues is Array and cues.size() > 0 else null
	r.check(grip != null and udon.has_component(grip, "pickup"), "the first cue's handle is a pickup: " + str(grip))
	if grip == null:
		return
	var gpos: Vector3 = grip.global_position
	var table: Node3D = mgr.get("tableSurface") as Node3D
	var centre: Vector3 = table.global_position if table != null else Vector3.ZERO
	var away: Vector3 = Vector3(gpos.x - centre.x, 0.0, gpos.z - centre.z).normalized()
	await r.place_player(gpos + away * 0.9)
	player.look_at_point(gpos)
	await r.wait(5)
	await r.mouse_move(r.project(gpos))
	await r.wait(2)
	r.check(str(ptr.hit.get("kind")) == "pickup", "pointer over the cue's handle: %s %s" % [str(ptr.hit.get("kind")), str(ptr.hit.get("target"))])
	await r.click(r.project(gpos))
	await r.wait(10)
	r.check(ptr.held != null and int(mgr.get("numberOfCuesHeldByLocalPlayer")) == 1, "cue picked up through the pointer: held=%s cues=%s" % [str(ptr.held), str(mgr.get("numberOfCuesHeldByLocalPlayer"))])
	await r.shot("cue")
	# the table knows the player is near it (a trigger around the table), so the top-down view
	# can be entered: E
	for i in range(30):
		if mgr.get("canEnterDesktopTopDownView") == true:
			break
		await r.wait(3)
	r.check(mgr.get("canEnterDesktopTopDownView") == true, "near the table with a cue: the top-down view can be entered")
	# Use enters it (PoolStateManager.InputUse: the release of the click that took the cue is
	# one), and so does E; E leaves it again
	var by_use: bool = mgr.get("isInDesktopTopDownView") == true
	if not by_use:
		await r.key(KEY_E, 2)
		await r.wait(10)
	r.check(mgr.get("isInDesktopTopDownView") == true, "the top-down view is entered (%s): %s" % ["by Use" if by_use else "by E", str(mgr.get("isInDesktopTopDownView"))])
	await r.key(KEY_E, 2)
	await r.wait(10)
	r.check(mgr.get("isInDesktopTopDownView") == false, "E leaves the top-down view: " + str(mgr.get("isInDesktopTopDownView")))
	await r.key(KEY_E, 2)
	await r.wait(10)
	r.check(mgr.get("isInDesktopTopDownView") == true, "... and enters it again: " + str(mgr.get("isInDesktopTopDownView")))
	await r.shot("aim")
	# the aim starts at the middle of the table, where the rack is: hold Use to pull back
	var before: Array = (mgr.get("currentBallPositions") as Array).duplicate()
	await r.mouse_button(true)
	await r.wait(90)
	var force = mgr.get("desktopShootForce")
	r.check(force is float and force > 0.05, "holding the left button builds the shot: " + str(force))
	await r.mouse_button(false)
	await r.wait(20)
	r.check(mgr.get("turnIsRunning") == true, "released: the shot is played, the turn runs: " + str(mgr.get("turnIsRunning")))
	await r.shot("shot")
	await r.wait(240)
	var after: Array = mgr.get("currentBallPositions")
	var moved: int = 0
	for i in range(mini(before.size(), after.size())):
		if ((after[i] as Vector3) - (before[i] as Vector3)).length() > 0.01:
			moved += 1
	r.check(moved >= 2, "balls moved after the shot: %d" % moved)
	await r.shot("settled")
	return true


## The first button whose click sends `event` to a behaviour (the UnityEvent the importer wired).
func _button_sending(r, event: String) -> BaseButton:
	for n in r._all(r.find(".") if r.find(".") != null else null):
		if n is BaseButton:
			for sig in ["pressed", "toggled"]:
				for c in n.get_signal_connection_list(sig):
					var call: Callable = c["callable"]
					if call.get_bound_arguments().has(event):
						return n
	return null
