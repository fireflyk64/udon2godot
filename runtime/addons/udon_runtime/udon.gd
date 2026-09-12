## `Udon` autoload — the world provider.
##
## This is the abstraction surface between converted Udon scripts and a Godot game. Everything
## VRChat-specific (players, ownership, networking, pickups, stations, input) is a method here
## or on the adapter objects it returns. A game supplies its own implementation by assigning
## `Udon.provider` to a subclass of [UdonWorldProvider] (see `udon_world_provider.gd`); the
## default provider is a single-user local stand-in that makes converted scripts run offline.
extends Node

const NetworkEventTarget_Owner := 0
const NetworkEventTarget_All := 1
const NetworkEventTarget_Others := 2
const NetworkEventTarget_Self := 3

## The active world provider (see udon_world_provider.gd). Assign before scripts run.
var provider: UdonWorldProvider = null

var _behaviours: Array = []
var _calling_player = null
var _in_network_call: int = 0
var _static_registry: Dictionary = {}  # class name → script resource (for cross-class statics)

# --- frame timing shared with U ---
var _delta: float = 0.0
var _physics_delta: float = 1.0 / 60.0
var _in_physics: bool = false
var _time: float = 0.0
var _fixed_time: float = 0.0
var _last_process_frame: int = -1

func _ready() -> void:
	process_priority = -1000
	if provider == null:
		set_provider(UdonWorldProvider.new())
	_phys_init()

## Install a world provider (a UdonWorldProvider subclass). Replaces the default one.
func set_provider(p: UdonWorldProvider) -> void:
	if provider != null and provider != p:
		provider.queue_free()
	provider = p
	if p.get_parent() == null:
		p.name = "UdonProvider"
		add_child(p)
	p._world_ready(self)

func _process(delta: float) -> void:
	_in_physics = false
	_delta = delta
	_time += delta
	_last_process_frame = Engine.get_process_frames()
	if not U._constraints.is_empty():
		# constraints resolve after every behaviour's Update, like Unity's animation step
		U.call_deferred("solve_constraints")

func _physics_process(delta: float) -> void:
	_physics_delta = delta
	_fixed_time += delta
	if _phys_stay_wanted:
		_phys_stay_step()

func _note_process(_delta: float) -> void:
	_in_physics = false

func _note_physics(_delta: float) -> void:
	_in_physics = true

# ---------------------------------------------------------------------------
# Behaviour registry
# ---------------------------------------------------------------------------

func _register_behaviour(b: Node) -> void:
	if not _behaviours.has(b):
		_behaviours.append(b)
	provider._on_behaviour_registered(b)
	_phys_note_behaviour(b)

func _unregister_behaviour(b: Node) -> void:
	_behaviours.erase(b)

## All live converted behaviours.
func behaviours() -> Array:
	var out: Array = []
	for b in _behaviours:
		if is_instance_valid(b):
			out.append(b)
	return out

## Raise a VRChat world event (OnPlayerJoined, OnPlayerLeft, OnPlayerRespawn, ...) on every behaviour.
func broadcast_event(event_name: String, args: Array = []) -> void:
	for b in behaviours():
		if b.has_method(event_name):
			b.callv(event_name, args)

## VRChat input events (InputJump, InputUse, InputGrab, InputDrop, InputMoveHorizontal,
## InputMoveVertical, InputLookHorizontal, InputLookVertical): `value` is bool for buttons and
## float for axes; hand_type 0 = right, 1 = left; event_type 0 = button, 1 = axis.
func input_event(event_name: String, value, hand_type: int = 0) -> void:
	var args: Dictionary = {"handType": hand_type, "eventType": 1 if typeof(value) == TYPE_FLOAT else 0, "boolValue": value if typeof(value) == TYPE_BOOL else false, "floatValue": value if typeof(value) == TYPE_FLOAT else 0.0}
	for b in behaviours():
		if b.has_method(event_name):
			b.callv(event_name, [value, args])

# --- simulated input for tests and bots (forwarded to the provider) ---------------------------
func simulate_key(keycode: int, pressed: bool) -> void:
	provider.simulate_key(keycode, pressed)

func simulate_axis(axis: String, value: float) -> void:
	provider.simulate_axis(axis, value)

func simulate_button(button: String, pressed: bool) -> void:
	provider.simulate_button(button, pressed)

func simulate_mouse_button(index: int, pressed: bool) -> void:
	provider.simulate_mouse_button(index, pressed)

func simulate_mouse_position(p) -> void:
	provider.simulate_mouse_position(p)

func clear_simulated_input() -> void:
	provider.clear_simulated_input()

# ---------------------------------------------------------------------------
# Players
# ---------------------------------------------------------------------------

func local_player():
	return provider.local_player()

func master():
	return provider.master()

func instance_owner():
	return provider.instance_owner()

func is_master() -> bool:
	var lp = local_player()
	return lp != null and lp.is_master

func is_instance_owner() -> bool:
	var lp = local_player()
	return lp != null and lp.is_instance_owner

func get_player_by_id(id: int):
	return provider.get_player_by_id(id)

func get_players(into: Array) -> Array:
	var players: Array = provider.get_players()
	if into == null:
		return players
	into.resize(maxi(into.size(), players.size()))
	for i in range(players.size()):
		into[i] = players[i]
	return into

func player_count() -> int:
	return provider.get_players().size()

func get_players_with_tag(tag_name: String, value: String) -> Array:
	var out: Array = []
	for p in provider.get_players():
		if p.get_player_tag(tag_name) == value:
			out.append(p.player_id)
	return out

## `Utilities.IsValid` / `player.IsValid()` — accepts players, nodes and nulls.
func is_valid(obj) -> bool:
	if obj == null:
		return false
	if obj is Object:
		if not is_instance_valid(obj):
			return false
		if obj.has_method("is_valid"):
			return obj.is_valid()
		return true
	return true

func player_eq(a, b) -> bool:
	if a == null or b == null:
		return a == b
	if not (is_instance_valid(a) and is_instance_valid(b)):
		return a == b
	if a.has_method("get_player_id") or "player_id" in a:
		return a.player_id == b.player_id
	return a == b

# ---------------------------------------------------------------------------
# Ownership & networking
# ---------------------------------------------------------------------------

func is_owner(node: Node) -> bool:
	return provider.is_owner(local_player(), node)

func is_owner_player(player, node: Node) -> bool:
	return provider.is_owner(player, node)

func owner_of(node: Node):
	return provider.owner_of(node)

func transfer_owner(player, node: Node) -> void:
	var prev = provider.owner_of(node)
	provider.set_owner_of(player, node)
	if prev != player:
		_ownership_transferred(node, player)

func _ownership_transferred(node: Node, player) -> void:
	# Every behaviour on the object hears OnOwnershipTransferred.
	for b in behaviours():
		if b == node or b.is_ancestor_of(node) and b.get_parent() == node.get_parent():
			if b.has_method("OnOwnershipTransferred"):
				b.call("OnOwnershipTransferred", player)
	if node.has_method("OnOwnershipTransferred") and not _behaviours.has(node):
		node.call("OnOwnershipTransferred", player)

func is_object_ready(node: Node) -> bool:
	return provider.is_object_ready(node)

func get_unique_name(node: Node) -> String:
	return String(node.get_path())

func server_time_ms() -> int:
	return provider.server_time_ms()

func server_time_s() -> float:
	return float(provider.server_time_ms()) / 1000.0

func server_delta_time(t1: float, t2: float) -> float:
	return t1 - t2

func network_date_time() -> Dictionary:
	return U.datetime_now(true)

func simulation_time(_node: Node) -> float:
	return float(provider.server_time_ms()) / 1000.0

func simulation_time_player(_player) -> float:
	return float(provider.server_time_ms()) / 1000.0

func is_clogged() -> bool:
	return provider.is_clogged()

func is_network_settled() -> bool:
	return provider.is_network_settled()

func calling_player():
	return _calling_player

func in_network_call() -> bool:
	return _in_network_call > 0

func _begin_network_call(sender) -> void:
	_calling_player = sender
	_in_network_call += 1

func _end_network_call() -> void:
	_in_network_call -= 1
	if _in_network_call <= 0:
		_in_network_call = 0
		_calling_player = null

## Route SendCustomNetworkEvent through the provider. Local targets are delivered immediately.
func send_network_event(behaviour: Node, target: int, event_name: String, args: Array) -> void:
	var lp = local_player()
	match target:
		NetworkEventTarget_Self:
			behaviour._udon_receive_network_event(event_name, args, lp)
		NetworkEventTarget_Owner:
			if is_owner(behaviour):
				behaviour._udon_receive_network_event(event_name, args, lp)
			else:
				provider.send_network_event(behaviour, target, event_name, args)
		NetworkEventTarget_All:
			behaviour._udon_receive_network_event(event_name, args, lp)
			provider.send_network_event(behaviour, NetworkEventTarget_Others, event_name, args)
		_:
			provider.send_network_event(behaviour, target, event_name, args)

## Called by the provider when a remote event arrives.
func receive_network_event(behaviour: Node, event_name: String, args: Array, sender) -> void:
	if is_instance_valid(behaviour) and behaviour.has_method("_udon_receive_network_event"):
		if not behaviour.udon_network_callable().has(event_name) and not args.is_empty():
			push_warning("network event '%s' with arguments on %s is not [NetworkCallable]" % [event_name, behaviour.name])
		behaviour._udon_receive_network_event(event_name, args, sender)

## Serialize a behaviour's synced variables through the provider. Returns a SerializationResult.
func serialize(behaviour: Node, data: Dictionary) -> Dictionary:
	return provider.serialize(behaviour, data)

## Called by the provider when a remote snapshot arrives.
func receive_serialization(behaviour: Node, data: Dictionary, result: Dictionary = {}) -> void:
	if is_instance_valid(behaviour) and behaviour.has_method("udon_deserialize"):
		behaviour.udon_deserialize(data, result)

# ---------------------------------------------------------------------------
# Objects
# ---------------------------------------------------------------------------

## Unity Instantiate. `source` is a scene node (duplicated, like a prefab instance already in
## the scene) or a PackedScene. Prefab assets referenced by converted scripts are imported as
## inactive template nodes under the scene's `UdonPrefabs` container, so both paths meet here.
func instantiate(source) -> Node:
	return _spawn(source, null, false)

func instantiate_in(source, parent: Node, world_position_stays: bool = false) -> Node:
	return _spawn(source, parent, world_position_stays)

func instantiate_at(source, pos: Vector3, rot: Quaternion, parent: Node = null) -> Node:
	var n: Node = _spawn(source, parent, false)
	if n is Node3D:
		U.set_position(n, pos)
		U.set_global_rotation(n, rot)
	return n

func _spawn(source, parent: Node, world_position_stays: bool) -> Node:
	if source is PackedScene:
		var inst: Node = source.instantiate()
		var p: Node = parent if parent != null else get_tree().current_scene
		if p == null:
			p = get_tree().root
		p.add_child(inst)
		_activate_template(inst)
		return inst
	if source == null or not (source is Node) or not is_instance_valid(source):
		push_warning("Instantiate: source is not a node or scene")
		return null
	var n: Node = provider.instantiate(source, parent, Vector3.ZERO, Quaternion(), world_position_stays)
	if n != null and source.has_meta("udon_prefab_template"):
		_activate_template(n)
	return n

## Prefab template nodes are kept inactive; copies come to life.
func _activate_template(n: Node) -> void:
	if n.has_meta("udon_prefab_template"):
		n.remove_meta("udon_prefab_template")
	n.process_mode = Node.PROCESS_MODE_INHERIT
	if n is Node3D or n is CanvasItem:
		n.visible = true

func destroy(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node is Node:
		provider.destroy(node)

func destroy_delayed(node, delay: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var t := get_tree().create_timer(delay)
	t.timeout.connect(func(): destroy(node))

func get_player_objects(player) -> Array:
	return provider.get_player_objects(player)

func find_component_in_player_objects(player, component):
	for go in provider.get_player_objects(player):
		var c = U.get_component_in_children(go, U.type_of(component), true)
		if c != null:
			return c
	return null

# ---------------------------------------------------------------------------
# Component adapters
# ---------------------------------------------------------------------------

func pickup(node: Node):
	return provider.pickup(node)

## Does `node` carry the VRC component `kind` ("pickup", "station", "object_sync", "object_pool",
## "video", ...)? See UdonWorldProvider.has_adapter.
func has_component(node: Node, kind: String) -> bool:
	return provider.has_adapter(node, kind)

## Mark `node` as carrying a VRC component so GetComponent<VRC_Pickup>() & co. find it.
func register_component(node: Node, kind: String, config: Dictionary = {}) -> void:
	provider.register_component(node, kind, config)

func station(node: Node):
	return provider.station(node)

func object_sync(node: Node):
	return provider.object_sync(node)

func object_pool(node: Node):
	return provider.object_pool(node)

func video(node: Node):
	return provider.video(node)

func avatar_pedestal_use(node: Node, player) -> void:
	provider.avatar_pedestal_use(node, player)

func avatar_pedestal_switch(node: Node, id: String) -> void:
	provider.avatar_pedestal_switch(node, id)

func screen_camera():
	return provider.screen_camera()

func new_image_downloader():
	return provider.new_image_downloader()

func load_url_string(url: String, behaviour: Node):
	return provider.load_url_string(url, behaviour)

# ---------------------------------------------------------------------------
# Input (Unity Input class)
# ---------------------------------------------------------------------------

func get_key(keycode: int) -> bool:
	return provider.get_key(keycode)

func get_key_down(keycode: int) -> bool:
	return provider.get_key_down(keycode)

func get_key_up(keycode: int) -> bool:
	return provider.get_key_up(keycode)

func get_key_name(key_name: String) -> bool:
	return provider.get_key(U.keycode_from_name(key_name))

func get_key_name_down(key_name: String) -> bool:
	return provider.get_key_down(U.keycode_from_name(key_name))

func get_key_name_up(key_name: String) -> bool:
	return provider.get_key_up(U.keycode_from_name(key_name))

func get_axis(axis: String) -> float:
	return provider.get_axis(axis)

func get_axis_raw(axis: String) -> float:
	return provider.get_axis(axis)

func get_button(button: String) -> bool:
	return provider.get_button(button, 0)

func get_button_down(button: String) -> bool:
	return provider.get_button(button, 1)

func get_button_up(button: String) -> bool:
	return provider.get_button(button, 2)

func get_mouse_button(index: int) -> bool:
	return provider.get_mouse_button(index, 0)

func get_mouse_button_down(index: int) -> bool:
	return provider.get_mouse_button(index, 1)

func get_mouse_button_up(index: int) -> bool:
	return provider.get_mouse_button(index, 2)

func mouse_position() -> Vector3:
	var p: Vector2 = provider.mouse_position()
	return Vector3(p.x, p.y, 0.0)

func mouse_scroll_delta() -> Vector2:
	return provider.mouse_scroll_delta()

func any_key() -> bool:
	return provider.any_key(false)

func any_key_down() -> bool:
	return provider.any_key(true)

func is_using_hand_controller() -> bool:
	return provider.is_using_hand_controller()

func last_input_method() -> int:
	return provider.last_input_method()

func enable_object_highlight(node, enabled: bool) -> void:
	provider.enable_object_highlight(node, enabled)

# ---------------------------------------------------------------------------
# Persistence (PlayerData)
# ---------------------------------------------------------------------------

func player_data_set(key: String, value) -> void:
	provider.player_data_set(key, value)

func player_data_get(player, key: String, default):
	return provider.player_data_get(player, key, default)

func player_data_has(player, key: String) -> bool:
	return provider.player_data_has(player, key)

func player_data_keys(player) -> Array:
	return provider.player_data_keys(player) if provider.has_method("player_data_keys") else []

## Per-object network statistics come from the provider ("<key>:<object id>") or the global value.
func network_stat_for(obj, key: String, default):
	if obj != null and obj is Object:
		var v = provider.network_stat("%s:%d" % [key, obj.get_instance_id()], null) if provider.has_method("network_stat") else null
		if v != null:
			return v
	return network_stat(key, default)

func player_data_remove(key: String) -> void:
	provider.player_data_remove(key)

# ---------------------------------------------------------------------------
# Cross-class statics (when class_name is not emitted)
# ---------------------------------------------------------------------------

func register_class(class_name_: String, script: Script) -> void:
	_static_registry[class_name_] = script

func call_static(class_name_: String, method: String, args: Array):
	var s = _static_registry.get(class_name_)
	if s == null:
		push_error("Udon.call_static: class '%s' is not registered (Udon.register_class)" % class_name_)
		return null
	return s.callv(method, args)

func static_get(class_name_: String, member: String):
	var s = _static_registry.get(class_name_)
	if s == null:
		return null
	return s.get(member)

# ---------------------------------------------------------------------------
# Extras: network statistics, MIDI, economy, menus, player objects
# ---------------------------------------------------------------------------

## VRC NetworkStats: a provider may override `network_stat(key)`; defaults are zero.
func network_stat(key: String, default):
	if provider.has_method("network_stat"):
		return provider.network_stat(key, default)
	return default

## VRCMidiPlayer commands are forwarded to the provider (`midi_command(node, cmd, args)`).
func midi_command(node: Node, cmd: String, args: Array):
	if provider.has_method("midi_command"):
		return provider.midi_command(node, cmd, args)
	match cmd:
		"is_playing":
			return false
		"get_time":
			return 0.0
		"data":
			return {"tracks": [], "tempo": 120.0, "total_time": 0.0}
		_:
			return null

## VRC Economy (Store / UdonProduct): forwarded to the provider; defaults own nothing.
func economy(cmd: String, args: Array):
	if provider.has_method("economy"):
		return provider.economy(cmd, args)
	match cmd:
		"is_owned", "player_owns", "any_owns":
			return false
		"owners", "world_products":
			return []
		_:
			return null

func open_menu(node: Node) -> void:
	if provider.has_method("open_menu"):
		provider.open_menu(node)

func player_data_all(player) -> Array:
	var out: Array = []
	if player == null:
		return out
	for k in provider._player_data.get(player.player_id, {}).keys():
		out.append({"Key": k, "State": 0, "Owner": player})
	return out

func player_object_init(node: Node) -> void:
	if provider.has_method("player_object_init"):
		provider.player_object_init(node)

func players_in_range(pos: Vector3, radius: float) -> Array:
	var out: Array = []
	for p in provider.get_players():
		if p.get_position().distance_to(pos) <= radius:
			out.append(p)
	return out

# ---------------------------------------------------------------------------
# Collision and trigger callbacks
#
# Unity raises OnTriggerEnter/OnCollisionEnter (and the 2D / player variants) on the behaviours
# of both objects; Godot reports from the Area / RigidBody side only. The hub connects every
# Area3D/Area2D as it enters the tree, and every RigidBody3D/2D once some behaviour defines an
# OnCollision* handler, then forwards each event to the behaviours of both sides. Behaviours
# on a GameObject node, on a helper child, or on the collision object itself all count.
# ---------------------------------------------------------------------------

var _phys_hooked: Dictionary = {}       # collision object instance id → node
var _phys_collisions_wanted: bool = false
var _phys_stay_wanted: bool = false

const _PHYS_EVENTS: Array = ["OnCollisionEnter", "OnCollisionExit", "OnCollisionStay", "OnCollisionEnter2D", "OnCollisionExit2D", "OnCollisionStay2D", "OnPlayerCollisionEnter", "OnPlayerCollisionExit", "OnPlayerCollisionStay"]
const _PHYS_STAY_EVENTS: Array = ["OnTriggerStay", "OnTriggerStay2D", "OnCollisionStay", "OnCollisionStay2D", "OnPlayerTriggerStay", "OnPlayerCollisionStay"]

func _phys_init() -> void:
	get_tree().node_added.connect(_phys_on_node_added)
	_phys_hook_tree(get_tree().root)

func _phys_on_node_added(n: Node) -> void:
	if n is Area3D or n is Area2D or (_phys_collisions_wanted and (n is RigidBody3D or n is RigidBody2D)):
		_phys_hook(n)

func _phys_hook_tree(n: Node) -> void:
	_phys_on_node_added(n)
	for c in n.get_children():
		_phys_hook_tree(c)

## Called on behaviour registration: learn which callbacks exist and hook the behaviour's body.
func _phys_note_behaviour(b: Node) -> void:
	var wants_collisions: bool = false
	for e in _PHYS_EVENTS:
		if b.has_method(e):
			wants_collisions = true
			break
	for e in _PHYS_STAY_EVENTS:
		if b.has_method(e):
			_phys_stay_wanted = true
			break
	if wants_collisions and not _phys_collisions_wanted:
		_phys_collisions_wanted = true
		if is_inside_tree():
			_phys_hook_tree(get_tree().root)
	var co = U._phys_co(b)
	if OS.has_environment("UDON_PHYS_DEBUG"):
		print("[phys] behaviour ", b, " co=", co, " wants=", wants_collisions)
	if co != null:
		_phys_hook(co)

func _phys_hook(co: Node) -> void:
	var id: int = co.get_instance_id()
	if _phys_hooked.has(id):
		return
	if OS.has_environment("UDON_PHYS_DEBUG"):
		print("[phys] hook ", co)
	if co is Area3D:
		co.body_entered.connect(_phys_trigger.bind(co, "Enter", true))
		co.body_exited.connect(_phys_trigger.bind(co, "Exit", true))
		co.area_entered.connect(_phys_trigger.bind(co, "Enter", false))
		co.area_exited.connect(_phys_trigger.bind(co, "Exit", false))
	elif co is Area2D:
		co.body_entered.connect(_phys_trigger2d.bind(co, "Enter", true))
		co.body_exited.connect(_phys_trigger2d.bind(co, "Exit", true))
		co.area_entered.connect(_phys_trigger2d.bind(co, "Enter", false))
		co.area_exited.connect(_phys_trigger2d.bind(co, "Exit", false))
	elif co is RigidBody3D:
		co.contact_monitor = true
		co.max_contacts_reported = maxi(co.max_contacts_reported, 8)
		co.body_entered.connect(_phys_collision.bind(co, "Enter"))
		co.body_exited.connect(_phys_collision.bind(co, "Exit"))
	elif co is RigidBody2D:
		co.contact_monitor = true
		co.max_contacts_reported = maxi(co.max_contacts_reported, 8)
		co.body_entered.connect(_phys_collision2d.bind(co, "Enter"))
		co.body_exited.connect(_phys_collision2d.bind(co, "Exit"))
	else:
		return
	_phys_hooked[id] = co
	co.tree_exiting.connect(_phys_unhook.bind(id))

func _phys_unhook(id: int) -> void:
	_phys_hooked.erase(id)

## The behaviours that receive physics callbacks for a collision object: those whose own
## collision object it is, those living on the same GameObject, and the behaviour the object is
## a direct component child of (hand-built scenes put bodies straight under the script node).
func _phys_targets(co: Node) -> Array:
	var out: Array = []
	var go: Node = U.game_object(co)
	var parent: Node = co.get_parent()
	for b in behaviours():
		if b == co or b == parent or U._phys_co(b) == co or U.game_object(b) == go:
			out.append(b)
	return out

func physics_has_handler(co: Node, method: String) -> bool:
	for b in _phys_targets(co):
		if b.has_method(method):
			return true
	return false

## Raise `method` on every behaviour attached to `co` (used by U for controller hits).
func dispatch_physics(co: Node, method: String, args: Array) -> void:
	for b in _phys_targets(co):
		if b.has_method(method):
			b.callv(method, args)

## The VRCPlayerApi whose body is (or contains) `n`, or null.
func _phys_player_of(n: Node):
	if provider == null or n == null:
		return null
	for p in provider._players:
		if p.node != null and (p.node == n or p.node.is_ancestor_of(n)):
			return p
	return null

func _phys_trigger(other: Node, area: Area3D, phase: String, other_is_body: bool) -> void:
	var player = _phys_player_of(other)
	for b in _phys_targets(area):
		if b.has_method("OnTrigger" + phase):
			b.call("OnTrigger" + phase, other)
		if player != null and b.has_method("OnPlayerTrigger" + phase):
			b.call("OnPlayerTrigger" + phase, player)
	# bodies get no area signals of their own; the other area reports itself
	if other_is_body:
		for b in _phys_targets(other):
			if b.has_method("OnTrigger" + phase):
				b.call("OnTrigger" + phase, area)

func _phys_trigger2d(other: Node, area: Area2D, phase: String, other_is_body: bool) -> void:
	for b in _phys_targets(area):
		if b.has_method("OnTrigger" + phase + "2D"):
			b.call("OnTrigger" + phase + "2D", other)
	if other_is_body:
		for b in _phys_targets(other):
			if b.has_method("OnTrigger" + phase + "2D"):
				b.call("OnTrigger" + phase + "2D", area)

## Contact points between a monitored body and `other` from the body's direct state.
func _phys_contacts(body: RigidBody3D, other: Node, flip: bool) -> Array:
	var out: Array = []
	var st := PhysicsServer3D.body_get_direct_state(body.get_rid())
	if st == null:
		return out
	for i in range(st.get_contact_count()):
		if st.get_contact_collider_object(i) != other:
			continue
		var n: Vector3 = st.get_contact_local_normal(i)
		var imp = st.get_contact_impulse(i)
		var impulse: Vector3 = imp if imp is Vector3 else n * float(imp)
		var c: Dictionary = {"point": U.from_gd_v(st.get_contact_collider_position(i)), "normal": U.from_gd_v(-n if flip else n), "separation": 0.0, "impulse": U.from_gd_v(impulse), "thisCollider": other if flip else body, "otherCollider": body if flip else other}
		out.append(c)
	return out

func _phys_collision_dict(body: RigidBody3D, other: Node, flip: bool) -> Dictionary:
	var contacts: Array = _phys_contacts(body, other, flip)
	var other_v: Vector3 = other.linear_velocity if other is RigidBody3D else (other.velocity if other is CharacterBody3D else Vector3.ZERO)
	var rel: Vector3 = body.linear_velocity - other_v
	var impulse: Vector3 = Vector3.ZERO
	for c in contacts:
		impulse += c["impulse"]
	return {"collider": body if flip else other, "contacts": contacts, "relativeVelocity": U.from_gd_v(-rel if flip else rel), "impulse": impulse}

func _phys_collision(other: Node, body: RigidBody3D, phase: String) -> void:
	var player = _phys_player_of(other)
	var targets: Array = _phys_targets(body)
	if OS.has_environment("UDON_PHYS_DEBUG"):
		print("[phys] collision ", phase, " body=", body, " other=", other, " targets=", targets.size(), " behaviours=", behaviours().size())
	if not targets.is_empty():
		var col: Dictionary = _phys_collision_dict(body, other, false)
		for b in targets:
			if b.has_method("OnCollision" + phase):
				b.call("OnCollision" + phase, col)
			if player != null and b.has_method("OnPlayerCollision" + phase):
				b.call("OnPlayerCollision" + phase, player)
	# a monitored rigid body on the other side reports itself; static bodies do not
	if not (other is RigidBody3D and _phys_hooked.has(other.get_instance_id())):
		var others: Array = _phys_targets(other)
		if not others.is_empty():
			var col2: Dictionary = _phys_collision_dict(body, other, true)
			for b in others:
				if b.has_method("OnCollision" + phase):
					b.call("OnCollision" + phase, col2)

func _phys_contacts2d(body: RigidBody2D, other: Node, flip: bool) -> Array:
	var out: Array = []
	var st := PhysicsServer2D.body_get_direct_state(body.get_rid())
	if st == null:
		return out
	for i in range(st.get_contact_count()):
		if st.get_contact_collider_object(i) != other:
			continue
		var n: Vector2 = st.get_contact_local_normal(i)
		out.append({"point": U.v2_from_gd(st.get_contact_collider_position(i)), "normal": U.v2_from_gd(-n if flip else n), "separation": 0.0, "collider": other if flip else body, "otherCollider": body if flip else other})
	return out

func _phys_collision_dict2d(body: RigidBody2D, other: Node, flip: bool) -> Dictionary:
	var other_v: Vector2 = other.linear_velocity if other is RigidBody2D else Vector2.ZERO
	var rel: Vector2 = body.linear_velocity - other_v
	return {"collider": body if flip else other, "otherCollider": other if flip else body, "contacts": _phys_contacts2d(body, other, flip), "relativeVelocity": U.v2_from_gd(-rel if flip else rel)}

func _phys_collision2d(other: Node, body: RigidBody2D, phase: String) -> void:
	var targets: Array = _phys_targets(body)
	if not targets.is_empty():
		var col: Dictionary = _phys_collision_dict2d(body, other, false)
		for b in targets:
			if b.has_method("OnCollision" + phase + "2D"):
				b.call("OnCollision" + phase + "2D", col)
	if not (other is RigidBody2D and _phys_hooked.has(other.get_instance_id())):
		var others: Array = _phys_targets(other)
		if not others.is_empty():
			var col2: Dictionary = _phys_collision_dict2d(body, other, true)
			for b in others:
				if b.has_method("OnCollision" + phase + "2D"):
					b.call("OnCollision" + phase + "2D", col2)

## OnTriggerStay / OnCollisionStay: raised every physics step while overlapping.
func _phys_stay_step() -> void:
	for id in _phys_hooked.keys():
		var co = _phys_hooked[id]
		if not is_instance_valid(co) or not co.is_inside_tree():
			continue
		var others: Array = []
		if co is Area3D or co is Area2D:
			others = co.get_overlapping_bodies() + co.get_overlapping_areas()
		elif co is RigidBody3D or co is RigidBody2D:
			others = co.get_colliding_bodies()
		if others.is_empty():
			continue
		var is_area: bool = co is Area3D or co is Area2D
		var two_d: bool = co is Area2D or co is RigidBody2D
		var evt: String = ("OnTriggerStay" if is_area else "OnCollisionStay") + ("2D" if two_d else "")
		for other in others:
			var player = _phys_player_of(other) if not two_d else null
			for b in _phys_targets(co):
				if b.has_method(evt):
					if is_area:
						b.call(evt, other)
					elif two_d:
						b.call(evt, _phys_collision_dict2d(co, other, false))
					else:
						b.call(evt, _phys_collision_dict(co, other, false))
				if player != null and b.has_method("OnPlayer" + ("TriggerStay" if is_area else "CollisionStay")):
					b.call("OnPlayer" + ("TriggerStay" if is_area else "CollisionStay"), player)
			if is_area and not (other is Area3D or other is Area2D):
				for b in _phys_targets(other):
					if b.has_method(evt):
						b.call(evt, co)
