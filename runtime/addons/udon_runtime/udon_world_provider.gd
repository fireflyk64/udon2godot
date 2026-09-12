## Abstract world provider.
##
## A Godot game implements VRChat's world services by subclassing this and assigning an
## instance to `Udon.provider` before converted scripts enter the tree. Every method has a
## working single-user default so converted scripts run offline out of the box; override what
## your game supports (networking, players, pickups, stations, input).
class_name UdonWorldProvider
extends Node

const UdonPlayer := preload("res://addons/udon_runtime/udon_player.gd")
const UdonPickup := preload("res://addons/udon_runtime/udon_pickup.gd")
const UdonStation := preload("res://addons/udon_runtime/udon_station.gd")
const UdonObjectSync := preload("res://addons/udon_runtime/udon_object_sync.gd")
const UdonObjectPool := preload("res://addons/udon_runtime/udon_object_pool.gd")
const UdonVideoPlayer := preload("res://addons/udon_runtime/udon_video.gd")

var _local_player = null
var _players: Array = []
var _owners: Dictionary = {}   # node instance id → player
var _adapters: Dictionary = {} # node instance id → {kind: adapter}
var _player_data: Dictionary = {}
var _keys_down: Dictionary = {}
var _keys_prev: Dictionary = {}
var _start_ms: int = 0
## When true (default), RequestSerialization immediately re-delivers the snapshot locally so
## OnDeserialization runs in single-user mode as it would for remote clients.
var loopback_serialization: bool = true

# --- lifecycle -------------------------------------------------------------

func _world_ready(_udon: Node) -> void:
	_start_ms = Time.get_ticks_msec()
	if _local_player == null:
		var p = UdonPlayer.new()
		p.player_id = 1
		p.display_name = "LocalPlayer"
		p.is_local = true
		p.is_master = true
		p.is_instance_owner = true
		_local_player = p
		_players.append(p)
	set_process(true)

func _process(_delta: float) -> void:
	_keys_prev = _keys_down.duplicate()
	_keys_down.clear()

## Behaviours that enter the tree after the world started still get OnPlayerJoined for every player
## already present (VRChat raises it for everyone in the instance when the local player joins).
var replay_joins: bool = true

## Hook: a converted behaviour entered the tree.
func _on_behaviour_registered(b: Node) -> void:
	if replay_joins and _local_player != null:
		call_deferred("_replay_joins", b)

func _replay_joins(b: Node) -> void:
	if not is_instance_valid(b) or not b.is_inside_tree() or not b.has_method("OnPlayerJoined"):
		return
	if b.has_method("_udon_start"):
		b._udon_start()
	for p in _players.duplicate():
		if p._valid:
			b.OnPlayerJoined(p)

# --- players ---------------------------------------------------------------

func local_player():
	return _local_player

func master():
	for p in _players:
		if p.is_master:
			return p
	return _local_player

func instance_owner():
	for p in _players:
		if p.is_instance_owner:
			return p
	return _local_player

func get_player_by_id(id: int):
	for p in _players:
		if p.player_id == id:
			return p
	return null

func get_players() -> Array:
	return _players.duplicate()

## Add a (remote) player; raises OnPlayerJoined on every behaviour.
func add_player(player) -> void:
	if not _players.has(player):
		_players.append(player)
		Udon.broadcast_event("OnPlayerJoined", [player])

## Remove a player; raises OnPlayerLeft, then invalidates the player object.
func remove_player(player) -> void:
	if _players.has(player):
		_players.erase(player)
		Udon.broadcast_event("OnPlayerLeft", [player])
		player._valid = false
		# ownership falls back to master
		for k in _owners.keys():
			if _owners[k] == player:
				_owners[k] = master()

# --- ownership & networking ------------------------------------------------

func is_owner(player, node: Node) -> bool:
	return owner_of(node) == player

func owner_of(node: Node):
	if node == null:
		return null
	var o = _owners.get(node.get_instance_id())
	if o == null:
		return master()
	return o

func set_owner_of(player, node: Node) -> void:
	if node == null:
		return
	_owners[node.get_instance_id()] = player

func is_object_ready(_node: Node) -> bool:
	return true

func server_time_ms() -> int:
	return Time.get_ticks_msec() - _start_ms

func is_clogged() -> bool:
	return false

func is_network_settled() -> bool:
	return true

## Deliver a network event to remote clients. Single-user default: nothing to do.
func send_network_event(_behaviour: Node, _target: int, _event_name: String, _args: Array) -> void:
	pass

## Replicate synced variables. Single-user default: nothing to do; report success.
func serialize(behaviour: Node, data: Dictionary) -> Dictionary:
	var result: Dictionary = {"success": true, "byteCount": var_to_bytes(data).size()}
	if loopback_serialization:
		Udon.receive_serialization(behaviour, data, {"sendTime": Udon.server_time_s(), "receiveTime": Udon.server_time_s()})
	return result

# --- objects ---------------------------------------------------------------

func instantiate(node: Node, parent: Node, _pos: Vector3, _rot: Quaternion, _world_stays: bool) -> Node:
	var copy: Node = node.duplicate()
	var p: Node = parent if parent != null else node.get_parent()
	if p == null:
		p = get_tree().current_scene
	p.add_child(copy)
	return copy

func destroy(node: Node) -> void:
	node.queue_free()

func get_player_objects(_player) -> Array:
	return []

func _adapter(node: Node, kind: String, factory: Callable):
	if node == null:
		return null
	var id: int = node.get_instance_id()
	var d: Dictionary = _adapters.get(id, {})
	if not d.has(kind):
		d[kind] = factory.call(node)
		_adapters[id] = d
	return d[kind]

## GetComponent<VRC_Pickup>() & co: a node has the component when an adapter was registered for it
## (`Udon.pickup(node)`), it is in the `udon_<kind>` group, or it implements the surface itself.
const _SURFACE_METHOD: Dictionary = {"pickup": "drop", "station": "use_station", "object_sync": "flag_discontinuity", "object_pool": "try_to_spawn", "video": "play_url"}

func has_adapter(node: Node, kind: String) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node.is_in_group("udon_" + kind) or node.has_meta("udon_" + kind):
		return true
	if _SURFACE_METHOD.has(kind) and node.has_method(_SURFACE_METHOD[kind]):
		return true
	# adapters created lazily by scripts (Udon.pickup(node) on an arbitrary node) do not count
	return false

## Declare that `node` carries a VRC component (the scene converter does this through the
## `udon_<kind>` group; worlds built by hand call it from GDScript).
func register_component(node: Node, kind: String, config: Dictionary = {}) -> void:
	if node == null:
		return
	node.add_to_group("udon_" + kind, true)
	if not config.is_empty():
		node.set_meta("udon_" + kind, config)

## Pickup adapter. Override to return your own object implementing the UdonPickup surface;
## the default returns the node itself when it exposes the surface, else a generic adapter.
func pickup(node: Node):
	if node != null and node.has_method("drop") and "is_held" in node:
		return node
	return _adapter(node, "pickup", func(n): return UdonPickup.new(n))

func station(node: Node):
	if node != null and node.has_method("use_station"):
		return node
	return _adapter(node, "station", func(n): return UdonStation.new(n))

func object_sync(node: Node):
	if node != null and node.has_method("flag_discontinuity"):
		return node
	return _adapter(node, "object_sync", func(n): return UdonObjectSync.new(n))

func object_pool(node: Node):
	if node != null and node.has_method("try_to_spawn"):
		return node
	return _adapter(node, "object_pool", func(n): return UdonObjectPool.new(n))

func video(node: Node):
	if node != null and node.has_method("play_url"):
		return node
	return _adapter(node, "video", func(n): return UdonVideoPlayer.new(n))

func avatar_pedestal_use(_node: Node, _player) -> void:
	pass

func avatar_pedestal_switch(_node: Node, _id: String) -> void:
	pass

func screen_camera():
	var cam: Camera3D = get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return null
	return {"position": cam.global_position, "rotation": U.get_global_rotation(cam), "fov": cam.fov, "near": cam.near, "far": cam.far, "active": cam.current, "pixel_width": get_viewport().get_visible_rect().size.x, "pixel_height": get_viewport().get_visible_rect().size.y}

func new_image_downloader():
	return null

func load_url_string(_url: String, _behaviour: Node):
	return null

# --- input -----------------------------------------------------------------

## Unity KeyCode → Godot Key. Override for custom bindings.
func keycode_to_key(keycode: int) -> Key:
	return U.keycode_to_godot_key(keycode)

# --- simulated input (tests, bots, replay) --------------------------------------------------
# Values set here take precedence over the real devices until cleared.
var _sim_keys: Dictionary = {}          # keycode → bool
var _sim_axes: Dictionary = {}          # axis name → float
var _sim_buttons: Dictionary = {}       # action name → {held, pressed_frame, released_frame}
var _sim_mouse: Dictionary = {}         # index → bool
var _sim_mouse_position = null          # Vector2 (Unity origin: bottom-left) or null

func simulate_key(keycode: int, pressed: bool) -> void:
	_sim_keys[keycode] = pressed

func simulate_axis(axis: String, value: float) -> void:
	_sim_axes[axis] = value

func simulate_button(button: String, pressed: bool) -> void:
	var f: int = Engine.get_process_frames()
	var st: Dictionary = _sim_buttons.get(button, {"held": false, "pressed_frame": -1, "released_frame": -1})
	if pressed and not st["held"]:
		st["pressed_frame"] = f
	if not pressed and st["held"]:
		st["released_frame"] = f
	st["held"] = pressed
	_sim_buttons[button] = st

func simulate_mouse_button(index: int, pressed: bool) -> void:
	_sim_mouse[index] = pressed

func simulate_mouse_position(p) -> void:
	_sim_mouse_position = p

func clear_simulated_input() -> void:
	_sim_keys.clear()
	_sim_axes.clear()
	_sim_buttons.clear()
	_sim_mouse.clear()
	_sim_mouse_position = null

func get_key(keycode: int) -> bool:
	if _sim_keys.has(keycode):
		return _sim_keys[keycode]
	var k: Key = keycode_to_key(keycode)
	if k == KEY_NONE:
		return false
	if keycode >= 323 and keycode <= 329:
		return Input.is_mouse_button_pressed((keycode - 323 + 1) as MouseButton)
	return Input.is_key_pressed(k)

func get_key_down(keycode: int) -> bool:
	# Edge detection: pressed now and not in the previous frame.
	var now: bool = get_key(keycode)
	var prev: bool = _keys_prev.get(keycode, false)
	_keys_down[keycode] = now
	if not _keys_prev.has(keycode):
		_keys_prev[keycode] = now
		return now
	return now and not prev

func get_key_up(keycode: int) -> bool:
	var now: bool = get_key(keycode)
	var prev: bool = _keys_prev.get(keycode, false)
	_keys_down[keycode] = now
	return prev and not now

## Unity axis names → Godot input actions. Override to map to your project's actions.
func get_axis(axis: String) -> float:
	if _sim_axes.has(axis):
		return float(_sim_axes[axis])
	match axis:
		"Horizontal":
			return Input.get_axis("ui_left", "ui_right")
		"Vertical":
			return Input.get_axis("ui_down", "ui_up")
		"Mouse X":
			return 0.0
		"Mouse Y":
			return 0.0
		_:
			if InputMap.has_action(axis):
				return Input.get_action_strength(axis)
			return 0.0

## mode: 0 = held, 1 = pressed this frame, 2 = released this frame
func get_button(button: String, mode: int) -> bool:
	if _sim_buttons.has(button):
		var st: Dictionary = _sim_buttons[button]
		var f: int = Engine.get_process_frames()
		match mode:
			1:
				return int(st["pressed_frame"]) == f
			2:
				return int(st["released_frame"]) == f
			_:
				return bool(st["held"])
	if not InputMap.has_action(button):
		return false
	match mode:
		1:
			return Input.is_action_just_pressed(button)
		2:
			return Input.is_action_just_released(button)
		_:
			return Input.is_action_pressed(button)

func get_mouse_button(index: int, mode: int) -> bool:
	var b: MouseButton = (index + 1) as MouseButton
	var now: bool = _sim_mouse[index] if _sim_mouse.has(index) else Input.is_mouse_button_pressed(b)
	var key: int = 100000 + index
	var prev: bool = _keys_prev.get(key, false)
	_keys_down[key] = now
	match mode:
		1:
			return now and not prev
		2:
			return prev and not now
		_:
			return now

func mouse_position() -> Vector2:
	if _sim_mouse_position != null:
		return _sim_mouse_position
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	var p: Vector2 = vp.get_mouse_position()
	# Unity's origin is bottom-left.
	return Vector2(p.x, vp.get_visible_rect().size.y - p.y)

func mouse_scroll_delta() -> Vector2:
	return Vector2.ZERO

func any_key(_just_pressed: bool) -> bool:
	return Input.is_anything_pressed()

func is_using_hand_controller() -> bool:
	return false

func last_input_method() -> int:
	return 0

func enable_object_highlight(_node, _enabled: bool) -> void:
	pass

# --- persistence -----------------------------------------------------------

func player_data_set(key: String, value) -> void:
	var lp = _local_player
	var id: int = lp.player_id if lp != null else 0
	if not _player_data.has(id):
		_player_data[id] = {}
	_player_data[id][key] = value

func player_data_get(player, key: String, default):
	if player == null:
		return default
	return _player_data.get(player.player_id, {}).get(key, default)

func player_data_has(player, key: String) -> bool:
	if player == null:
		return false
	return _player_data.get(player.player_id, {}).has(key)

func player_data_keys(player) -> Array:
	if player == null:
		return []
	return _player_data.get(player.player_id, {}).keys()

func player_data_remove(key: String) -> void:
	var lp = _local_player
	if lp != null and _player_data.has(lp.player_id):
		_player_data[lp.player_id].erase(key)
