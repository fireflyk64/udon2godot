## Varneon's UdonEssentials example scene: player list, simple player settings, groups and the
## event dispatcher, driven by the join of the local player and by frames.
extends RefCounted

## Receives the dispatcher's delegate events (an UdonSharpBehaviour would declare these methods).
class Probe:
	extends Node
	var updates: int = 0
	var late_updates: int = 0
	var fixed_updates: int = 0
	func udon_class() -> String:
		return "Probe"
	func SendCustomEvent(name: String) -> void:
		match name:
			"_UpdateDelegate":
				updates += 1
			"_LateUpdateDelegate":
				late_updates += 1
			"_FixedUpdateDelegate":
				fixed_updates += 1

func run(r) -> void:
	await r.wait(40)
	var udon: Node = r.udon()
	var me = udon.local_player()
	r.check(me != null, "local player exists")
	# --- player list -------------------------------------------------------------------------
	var pl: Node = r.behaviour("Playerlist")
	r.check(pl != null, "Playerlist behaviour present")
	if pl != null:
		var list: Node = pl.get("PlayerList")
		var online: Node = pl.get("TextPlayersOnline")
		var master: Node = pl.get("TextInstanceMaster")
		r.check(list != null and online != null and master != null, "Playerlist references resolved: %s %s %s" % [str(list), str(online), str(master)])
		if list != null:
			var items: Array = []
			for c in list.get_children():
				if c is Control and c.visible:
					items.append(c)
			r.check(items.size() == 1, "one entry for the local player: %d" % items.size())
			var shown: String = ""
			if items.size() > 0:
				for n in r._all(items[0]):
					if n is Label and str(n.text) == str(me.display_name):
						shown = str(n.text)
			r.check(shown != "", "the entry shows the player's display name (%s)" % str(me.display_name))
		if online != null:
			r.check(str(online.text).begins_with("1 /"), "players online: " + str(online.text))
		if master != null:
			r.check(str(master.text) == str(me.display_name), "instance master: " + str(master.text))
		await r.wait(70)
		var in_world: Node = pl.get("TextTimeInWorld")
		r.check(in_world != null and str(in_world.text).begins_with("00:00:0"), "time in world ticks as hh:mm:ss: " + str(in_world.text if in_world else null))
	# --- simple player settings --------------------------------------------------------------
	var sps: Node = r.behaviour("SimplePlayerSettings")
	r.check(sps != null, "SimplePlayerSettings behaviour present")
	if sps != null and me != null:
		r.check(is_equal_approx(float(me.get_locomotion("walk_speed")), float(sps.get("walkSpeed"))) and is_equal_approx(float(me.get_locomotion("run_speed")), float(sps.get("runSpeed"))), "walk / run speed applied on join: %s / %s" % [str(me.get_locomotion("walk_speed")), str(me.get_locomotion("run_speed"))])
		r.check(is_equal_approx(float(me.get_locomotion("jump_impulse")), float(sps.get("jumpImpulse"))), "jump impulse applied: " + str(me.get_locomotion("jump_impulse")))
	# --- groups ------------------------------------------------------------------------------
	var groups: Node = r.behaviour("Groups")
	r.check(groups != null, "Groups behaviour present")
	if groups != null:
		groups._AddPlayersToGroup("Testers", [str(me.display_name)])
		var idx: Array = groups._GetGroupIndicesOfPlayer(str(me.display_name))
		print("[scenario] groups of the local player: ", idx)
		r.check(idx is Array, "_GetGroupIndicesOfPlayer answers: " + str(idx))
	# --- event dispatcher --------------------------------------------------------------------
	var ed: Node = r.behaviour("EventDispatcher")
	r.check(ed != null, "EventDispatcher behaviour present")
	if ed != null:
		var probe := Probe.new()
		probe.name = "DispatcherProbe"
		ed.get_parent().add_child(probe)
		ed._AddUpdateDelegate(probe)
		ed._AddLateUpdateDelegate(probe)
		ed._AddFixedUpdateDelegate(probe)
		await r.wait(30)
		r.check(probe.updates >= 20 and probe.late_updates >= 20 and probe.fixed_updates >= 10, "delegates dispatched each frame: update %d, late %d, fixed %d" % [probe.updates, probe.late_updates, probe.fixed_updates])
		ed._RemoveUpdateDelegate(probe)
		await r.wait(5)
		var frozen: int = probe.updates
		await r.wait(10)
		r.check(probe.updates == frozen and probe.late_updates > 30, "a removed delegate stops, the others go on: update %d, late %d" % [probe.updates, probe.late_updates])
	await r.shot("essentials")
