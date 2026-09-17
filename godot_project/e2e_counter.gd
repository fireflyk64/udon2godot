extends SceneTree
## End-to-end test: drive the converted Counter.sgd through its lifecycle.

var failures: int = 0
var _U: Node = null
var _Udon: Node = null

func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		failures += 1
		print("  FAIL ", what)

func _init() -> void:
	ProjectSettings.set_setting("sandbox/binary_translation/auto_bake", false)
	await process_frame
	await process_frame
	_U = root.get_node_or_null("U")
	_Udon = root.get_node_or_null("Udon")
	check(_U != null and _Udon != null, "autoloads U and Udon present")
	var script = load("res://converted/Counter.sgd")
	check(script != null, "Counter.sgd loads")
	var host := Node3D.new()
	host.name = "CounterHost"
	var target := Node3D.new()
	target.name = "Target"
	target.position = Vector3(3, 0, 0)
	root.add_child(target)
	var other_host := Node3D.new()
	other_host.name = "Other"
	other_host.set_script(script)
	other_host.set("target", target)
	root.add_child(other_host)
	other_host.set("other", host)
	host.set_script(script)
	host.set("target", target)
	host.set("other", other_host)
	var toggle := Node3D.new()
	toggle.name = "Toggle"
	root.add_child(toggle)
	host.set("toggleObjects", [toggle])
	root.add_child(host)
	check(host.has_method("Start") and host.has_method("Update"), "Start/Update compiled")
	check(host.udon_class() == "Counter", "udon_class()")
	check(host.udon_synced_vars() == ["count", "_phase"], "udon_synced_vars()")
	check(host.udon_sync_mode() == "manual", "udon_sync_mode()")
	await process_frame
	await process_frame
	check(host._udon_started, "Start dispatched by runtime")
	check(host.get("localPlayer") != null, "Networking.LocalPlayer resolved")
	check(str(host.get("label")).begins_with("c0 2.00 phase=Idle"), "string formatting in Start: " + str(host.get("label")))
	check(host.get("flags").size() == 10, "new bool[MAX]")
	check(host.get("grid")[1][2] == 4.5, "2D array")
	var p0: Vector3 = host.get("positions")[1]
	check(p0.is_equal_approx(Vector3(1, 0.5, 2)), "Vector3 ctor + up*0.5: " + str(p0))
	check(target.global_position.is_equal_approx(Vector3(0, 0, 2)), "transform.forward * speed (Unity axes): " + str(target.global_position))
	# Interact: ownership, count++, phase property setter, network event to self, delayed event
	host.call("Interact")
	check(host.get("count") == 1, "count++ after Interact")
	check(host.get("_phase") == 5, "Phase property setter → _phase = Running(5)")
	check(host.get("Total") == 1, "SendCustomNetworkEvent(All) delivered locally with args")
	check(not _U.is_active(toggle), "OnBump toggled SetActive")
	check(_Udon.is_owner(host), "Networking.SetOwner")
	await process_frame
	check(host.get("Total") == 2, "RequestSerialization → serialize → (loopback) OnDeserialization; Total=" + str(host.get("Total")))
	# Update runs each frame: rotation applied
	var rot_before: Quaternion = host.quaternion
	await process_frame
	check(not host.quaternion.is_equal_approx(rot_before), "Update rotated the node")
	# Delayed event fires after 3s
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3300 and host.get("count") != 0:
		await process_frame
	check(host.get("count") == 0, "SendCustomEventDelayedSeconds(Reset, 3s) fired")
	check(host.get("_phase") == 0, "Reset set Phase = Idle")
	# out-param method
	check(is_equal_approx(host.call("Sum"), 2.0), "TryGet(out) + Sum: " + str(host.call("Sum")))
	# deserialization with FieldChangeCallback
	host.udon_deserialize({"count": 7, "_phase": 6})
	check(host.get("count") == 7 and host.get("_phase") == 6 and host.get("Total") == 14, "udon_deserialize applied callback + OnDeserialization")
	print("E2E DONE: %d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
