## Base class of every script converted by udon2godot.
##
## Mirrors `UdonSharpBehaviour`: dispatches Unity/VRChat lifecycle events to methods that keep
## their C# names (`Start`, `Update`, `Interact`, `OnPlayerJoined`, ...), implements the
## SendCustomEvent family, delayed events, network events and variable sync through the `Udon`
## world provider.
##
## A converted script is attached to a Node (usually a Node3D, or a Control for UI) that plays the role of the
## Unity GameObject. `gameObject`, `transform` and every component reference resolve to nodes.
extends Node

## Interaction (VRC_Interactable) surface — the world calls `Interact()` when the local player uses the object.
var DisableInteractive: bool = false
var InteractionText: String = "Use"
## Interaction distance of the UdonBehaviour component (VRChat `proximity`).
var proximity: float = 2.0
## Sync method chosen on the UdonBehaviour component in the scene (Networking.SyncType: 0 unknown,
## 1 none, 2 manual, 3 continuous); overrides the script's [UdonBehaviourSyncMode] when set.
var udon_sync_method: int = 0
## Unity `Behaviour.enabled`: when false, Update/FixedUpdate/LateUpdate are not dispatched.
var enabled: bool = true:
	set(v):
		var was: bool = enabled
		enabled = v
		if _udon_ready and was != v:
			if v:
				_udon_call("OnEnable")
			else:
				_udon_call("OnDisable")

var _udon_ready: bool = false
var _udon_started: bool = false
var _udon_has: Dictionary = {}
var _udon_timers: Array = []      # [{"name": String, "time": float}] seconds-delayed events
var _udon_frame_timers: Array = [] # [{"name": String, "frame": int}]
var _udon_late: Array = []        # events queued for EventTiming.LateUpdate
var _udon_pending_ser: bool = false

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_udon_bind_refs()
	if has_meta("udon_behaviour"):
		# settings of the UdonBehaviour component written by the scene converter
		var cfg: Dictionary = get_meta("udon_behaviour")
		InteractionText = str(cfg.get("interact_text", InteractionText))
		proximity = float(cfg.get("proximity", proximity))
		udon_sync_method = int(cfg.get("sync_method", 0))
		if cfg.has("enabled"):
			enabled = bool(cfg["enabled"])
	for n in ["Start", "Update", "FixedUpdate", "LateUpdate", "PostLateUpdate", "OnEnable", "OnDisable", "OnDestroy", "Interact", "OnDeserialization", "OnPreSerialization", "OnPostSerialization"]:
		_udon_has[n] = has_method(n)
	Udon._register_behaviour(self)
	_udon_ready = true
	if enabled:
		_udon_call("OnEnable")
	# Unity runs Start right before the first Update of the object (never after an Update).
	call_deferred("_udon_start")

## Object references written by the scene importer as NodePaths (metadata/udon_refs) become the
## exported Node values before any event runs. Missing targets stay null.
func _udon_bind_refs() -> void:
	if not has_meta("udon_refs"):
		return
	var refs: Dictionary = get_meta("udon_refs")
	for k in refs.keys():
		var v = refs[k]
		if v is NodePath:
			var n: Node = get_node_or_null(v)
			if n != null:
				set(str(k), n)
			else:
				push_warning("udon2godot: %s.%s: reference %s not found" % [name, str(k), str(v)])
		elif v is Array:
			var cur = get(str(k))
			var arr: Array = cur if cur is Array else []
			if arr.size() < v.size():
				arr.resize(v.size())
			for i in range(v.size()):
				if v[i] is NodePath:
					arr[i] = get_node_or_null(v[i])
					if arr[i] == null:
						push_warning("udon2godot: %s.%s[%d]: reference %s not found" % [name, str(k), i, str(v[i])])
			set(str(k), arr)

func _udon_start() -> void:
	if _udon_started or not is_instance_valid(self):
		return
	_udon_started = true
	if _udon_has.get("Start", false):
		call("Start")

func _exit_tree() -> void:
	if _udon_ready:
		Udon._unregister_behaviour(self)
		_udon_call("OnDestroy")

func _process(delta: float) -> void:
	Udon._note_process(delta)
	if not _udon_started:
		_udon_start()
	_udon_run_timers(delta)
	if enabled and _udon_has.get("Update", false):
		call("Update")
	# LateUpdate runs after every Update of this frame; a deferred call approximates that.
	if enabled and (_udon_has.get("LateUpdate", false) or not _udon_late.is_empty() or _udon_has.get("PostLateUpdate", false)):
		call_deferred("_udon_late_update")

func _udon_late_update() -> void:
	if not is_instance_valid(self) or not _udon_ready:
		return
	if _udon_has.get("LateUpdate", false):
		call("LateUpdate")
	var late: Array = _udon_late
	_udon_late = []
	for name in late:
		_udon_call(name)
	if _udon_has.get("PostLateUpdate", false):
		call("PostLateUpdate")

func _physics_process(delta: float) -> void:
	Udon._note_physics(delta)
	if not _udon_started:
		_udon_start()
	if enabled and _udon_has.get("FixedUpdate", false):
		call("FixedUpdate")

func _udon_run_timers(delta: float) -> void:
	if not _udon_timers.is_empty():
		var due: Array = []
		var i: int = 0
		while i < _udon_timers.size():
			var t: Dictionary = _udon_timers[i]
			t["time"] = float(t["time"]) - delta
			if float(t["time"]) <= 0.0:
				due.append(t)
				_udon_timers.remove_at(i)
			else:
				i += 1
		for t in due:
			_udon_fire(t)
	if not _udon_frame_timers.is_empty():
		var frame: int = Engine.get_process_frames()
		var due2: Array = []
		var j: int = 0
		while j < _udon_frame_timers.size():
			var t2: Dictionary = _udon_frame_timers[j]
			if int(t2["frame"]) <= frame:
				due2.append(t2)
				_udon_frame_timers.remove_at(j)
			else:
				j += 1
		for t2 in due2:
			_udon_fire(t2)

func _udon_fire(t: Dictionary) -> void:
	if int(t.get("timing", 0)) == 1:
		_udon_late.append(t["name"])
	else:
		_udon_call(t["name"])

## Call an event method by name if this behaviour defines it.
func _udon_call(name: String, args: Array = []) -> bool:
	if has_method(name):
		callv(name, args)
		return true
	return false

# ---------------------------------------------------------------------------
# UdonSharpBehaviour API
# ---------------------------------------------------------------------------

func udon_class() -> String:
	return "UdonBehaviour"

func udon_class_chain() -> Array:
	return ["UdonBehaviour"]

func udon_synced_vars() -> Array:
	return []

func udon_sync_mode() -> String:
	return "any"

func udon_field_callbacks() -> Dictionary:
	return {}

func udon_network_callable() -> Array:
	return []

## Is this behaviour (or one of its C# bases) named `class_name`?
func udon_is(class_name_: String) -> bool:
	if class_name_ in ["UdonSharpBehaviour", "UdonBehaviour", "MonoBehaviour", "Behaviour", "Component"]:
		return true
	return udon_class_chain().has(class_name_)

func SendCustomEvent(event_name: String) -> void:
	if not _udon_call(event_name):
		push_warning("SendCustomEvent: %s has no event '%s'" % [name, event_name])

func SendCustomEventDelayedSeconds(event_name: String, delay: float, timing: int = 0) -> void:
	_udon_timers.append({"name": event_name, "time": maxf(delay, 0.0), "timing": timing})

func SendCustomEventDelayedFrames(event_name: String, frames: int, timing: int = 0) -> void:
	_udon_frame_timers.append({"name": event_name, "frame": Engine.get_process_frames() + maxi(frames, 1), "timing": timing})

## Network event: `target` is a NetworkEventTarget (Owner=0, All=1, Others=2, Self=3).
func SendCustomNetworkEvent(target: int, event_name: String, args: Array = []) -> void:
	Udon.send_network_event(self, target, event_name, args)

## Called by the world provider when a network event arrives for this behaviour.
func _udon_receive_network_event(event_name: String, args: Array, sender) -> void:
	Udon._begin_network_call(sender)
	_udon_call(event_name, args)
	Udon._end_network_call()

func RequestSerialization() -> void:
	if _udon_pending_ser:
		return
	_udon_pending_ser = true
	call_deferred("_udon_do_serialize")

func _udon_do_serialize() -> void:
	_udon_pending_ser = false
	if not is_instance_valid(self):
		return
	_udon_call("OnPreSerialization")
	var data: Dictionary = udon_serialize()
	var result: Dictionary = Udon.serialize(self, data)
	_udon_call("OnPostSerialization", [result])

## Snapshot of all [UdonSynced] members.
func udon_serialize() -> Dictionary:
	var d: Dictionary = {}
	for v in udon_synced_vars():
		d[v] = get(v)
	return d

## Apply a snapshot received from the network, honouring [FieldChangeCallback] properties,
## then raise OnDeserialization.
func udon_deserialize(data: Dictionary, result: Dictionary = {}) -> void:
	var callbacks: Dictionary = udon_field_callbacks()
	for k in data.keys():
		if callbacks.has(k):
			# [FieldChangeCallback] names a property; converted scripts expose it as set_<Prop>().
			var setter: String = callbacks[k]
			if has_method(setter):
				call(setter, data[k])
			else:
				set(k, data[k])
		else:
			set(k, data[k])
	if has_method("OnDeserialization"):
		# Both overloads exist in UdonSharp; the converted script keeps the C# arity.
		var argc: int = -1
		for m in get_method_list():
			if m["name"] == "OnDeserialization":
				argc = m["args"].size()
				break
		if argc == 1:
			call("OnDeserialization", result)
		else:
			call("OnDeserialization")

func GetProgramVariable(var_name: String):
	return get(var_name)

func SetProgramVariable(var_name: String, value) -> void:
	set(var_name, value)

# Unity Behaviour/Component conveniences used by the catalog defaults.
func Interact() -> void:
	pass
