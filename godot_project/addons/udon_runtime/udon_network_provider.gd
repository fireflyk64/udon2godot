## Multiplayer world provider over Godot's high-level multiplayer API (ENet).
##
## Star topology: every message goes to the server, which relays it. The server is peer 1 and
## plays the VRChat "master" / instance owner. Implements players (join/leave, names, proxy
## transforms), ownership with `OnOwnershipRequest`, network events with targets, manual and
## continuous variable sync with late-joiner snapshots and Linear/Smooth interpolation, object
## sync (transform replication with discontinuity), pickups, stations, server time, and player
## data persistence.
##
##     var net := UdonNetworkProvider.new()
##     Udon.set_provider(net)
##     net.host(7777)            # or net.join("127.0.0.1", 7777)
##     net.register_player_node($Player)   # the local player's body (optional)
class_name UdonNetworkProvider
extends UdonWorldProvider

signal connected(peer_id: int)
signal connection_failed()
signal disconnected()
signal player_joined(player)
signal player_left(player)
signal settled()

const SERVER_ID := 1

## Local display name announced to other peers.
var local_display_name: String = "Player"
## Variable / transform replication rate for continuous sync and object sync.
var sync_rate_hz: float = 10.0
## File used by the server for PlayerData persistence.
var player_data_path: String = "user://udon_player_data.dat"

var peer: ENetMultiplayerPeer = null
var _is_server: bool = false
var _connected: bool = false
var _settled: bool = false
var _player_names: Dictionary = {}     # peer id → display name (server authoritative)
var _proxies: Dictionary = {}          # peer id → Node3D proxy for remote players
var _player_node: Node3D = null        # the local player's body
var _owner_paths: Dictionary = {}      # node path → peer id
var _pending_owner: Dictionary = {}    # path → requester id (server, waiting for owner answer)
var _snapshots: Dictionary = {}        # server cache: path → [data, send_time]
var _last_sent: Dictionary = {}        # path → last data sent (continuous mode diffing)
var _interp: Dictionary = {}           # path → {var: [from, to, elapsed, duration]}
var _obj_sync: Dictionary = {}         # path → {"node": Node3D, "target": Transform3D, "vel": Vector3, "t": float, "teleport": bool}
var _discontinuity: Dictionary = {}    # path → true when the next transform update teleports
var _accum: float = 0.0
var _time_offset_ms: int = 0
var _ping_sent_ms: int = 0
var _persist: Dictionary = {}          # display name → {key: value} (server)

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

func _world_ready(udon: Node) -> void:
	super._world_ready(udon)
	# data changes are reported when the server has them, restores when its data has arrived
	raise_player_data_events = false
	restore_on_join = false
	# placeholder id until connected; replaced in place by `_setup_local_player`
	_local_player.display_name = local_display_name

## Joins are replayed for late behaviours only once connected; before that the local player is a
## placeholder that `_setup_local_player` announces when the connection comes up.
func _on_behaviour_registered(b: Node) -> void:
	if replay_joins and _connected:
		call_deferred("_replay_joins", b)

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func host(port: int, max_clients: int = 32) -> Error:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_clients)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_is_server = true
	_connected = true
	_load_persist()
	_setup_local_player(SERVER_ID)
	_player_names[SERVER_ID] = local_display_name
	_settled = true
	settled.emit()
	connected.emit(SERVER_ID)
	return OK

func join(address: String, port: int) -> Error:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_is_server = false
	return OK

func leave() -> void:
	if peer != null:
		peer.close()
	multiplayer.multiplayer_peer = null
	_connected = false
	_settled = false

func is_server() -> bool:
	return _is_server

func is_connected_to_world() -> bool:
	return _connected

## The local player object exists before the connection (scripts may cache
## `Networking.LocalPlayer` in Start); connecting updates it in place.
func _setup_local_player(id: int) -> void:
	var p = _local_player
	if p == null:
		p = UdonPlayer.new()
		p.is_local = true
	p.player_id = id
	p.display_name = local_display_name
	p.is_master = id == SERVER_ID
	p.is_instance_owner = id == SERVER_ID
	p.node = _player_node
	_local_player = p
	_players.clear()
	_players.append(p)
	Udon.broadcast_event("OnPlayerJoined", [p])
	player_joined.emit(p)

## The local player's body; its transform is replicated to other peers.
func register_player_node(n: Node3D) -> void:
	_player_node = n
	if _local_player != null:
		_local_player.node = n

func _on_connected_to_server() -> void:
	_connected = true
	_setup_local_player(multiplayer.get_unique_id())
	_ping_sent_ms = Time.get_ticks_msec()
	_rpc_hello.rpc_id(SERVER_ID, local_display_name, _ping_sent_ms)
	connected.emit(multiplayer.get_unique_id())

func _on_connection_failed() -> void:
	connection_failed.emit()

func _on_server_disconnected() -> void:
	_connected = false
	_settled = false
	for p in _players.duplicate():
		if not p.is_local:
			remove_player(p)
	disconnected.emit()

func _on_peer_connected(_id: int) -> void:
	pass # players are announced after `_rpc_hello`

func _on_peer_disconnected(id: int) -> void:
	if _is_server:
		_rpc_player_left.rpc(id)
		_apply_player_left(id)
		# ownership of the leaving player's objects falls back to the master
		for path in _owner_paths.keys():
			if _owner_paths[path] == id:
				_rpc_apply_owner.rpc(path, SERVER_ID)
				_apply_owner(path, SERVER_ID)

# ---------------------------------------------------------------------------
# Players
# ---------------------------------------------------------------------------

@rpc("any_peer", "reliable")
func _rpc_hello(display_name: String, client_ms: int) -> void:
	if not _is_server:
		return
	var id := multiplayer.get_remote_sender_id()
	_player_names[id] = display_name
	# Tell everyone (including the newcomer) about the newcomer.
	_rpc_player_joined.rpc(id, display_name)
	_apply_player_joined(id, display_name)
	# Full state for the newcomer: players, ownership, snapshots, persisted data, time.
	_rpc_state.rpc_id(id, _player_names.duplicate(), _owner_paths.duplicate(), _snapshots_for_join(), _persist.get(display_name, {}), client_ms, Time.get_ticks_msec())

func _snapshots_for_join() -> Dictionary:
	var out: Dictionary = {}
	for path in _snapshots.keys():
		out[path] = _snapshots[path]
	return out

@rpc("authority", "reliable")
func _rpc_player_joined(id: int, display_name: String) -> void:
	_apply_player_joined(id, display_name)

func _apply_player_joined(id: int, display_name: String) -> void:
	if id == multiplayer.get_unique_id():
		return
	if get_player_by_id(id) != null:
		return
	var p = UdonPlayer.new()
	p.player_id = id
	p.display_name = display_name
	p.is_local = false
	p.is_master = id == SERVER_ID
	p.is_instance_owner = id == SERVER_ID
	p.node = _proxy_for(id)
	add_player(p)
	player_joined.emit(p)

@rpc("authority", "reliable")
func _rpc_player_left(id: int) -> void:
	_apply_player_left(id)

func _apply_player_left(id: int) -> void:
	var p = get_player_by_id(id)
	_player_names.erase(id)
	if p != null:
		remove_player(p)
		player_left.emit(p)
	if _proxies.has(id):
		_proxies[id].queue_free()
		_proxies.erase(id)

@rpc("authority", "reliable")
func _rpc_state(names: Dictionary, owners: Dictionary, snapshots: Dictionary, my_data: Dictionary, client_ms: int, server_ms: int) -> void:
	# clock: offset so that local_ms + offset ≈ server_ms
	var now := Time.get_ticks_msec()
	var rtt := now - client_ms
	_time_offset_ms = server_ms + rtt / 2 - now
	for id in names.keys():
		_apply_player_joined(int(id), names[id])
	for path in owners.keys():
		_owner_paths[path] = int(owners[path])
	for path in snapshots.keys():
		var snap: Array = snapshots[path]
		_apply_vars(String(path), snap[0], float(snap[1]), true)
	var lp = _local_player
	if lp != null:
		_player_data[lp.player_id] = my_data.duplicate()
		Udon.broadcast_event("OnPlayerRestored", [lp])
	_settled = true
	settled.emit()

func master():
	return get_player_by_id(SERVER_ID) if not _is_server else _local_player

func instance_owner():
	return master()

func _proxy_for(id: int) -> Node3D:
	if not _proxies.has(id):
		var n := Node3D.new()
		n.name = "RemotePlayer%d" % id
		add_child(n)
		_proxies[id] = n
	return _proxies[id]

@rpc("any_peer", "unreliable_ordered")
func _rpc_player_state(pos: Vector3, rot: Quaternion, vel: Vector3) -> void:
	var id := multiplayer.get_remote_sender_id()
	if _is_server:
		# relay to everyone else
		for pid in multiplayer.get_peers():
			if pid != id:
				_rpc_player_state_from.rpc_id(pid, id, pos, rot, vel)
	_apply_player_state(id, pos, rot, vel)

@rpc("authority", "unreliable_ordered")
func _rpc_player_state_from(id: int, pos: Vector3, rot: Quaternion, vel: Vector3) -> void:
	_apply_player_state(id, pos, rot, vel)

func _apply_player_state(id: int, pos: Vector3, rot: Quaternion, vel: Vector3) -> void:
	var p = get_player_by_id(id)
	if p == null:
		return
	var n := _proxy_for(id)
	n.global_position = pos
	U.set_global_rotation(n, rot)
	p._velocity = vel

# ---------------------------------------------------------------------------
# Ownership
# ---------------------------------------------------------------------------

func _path(node: Node) -> String:
	return String(node.get_path())

func _node(path: String) -> Node:
	return get_tree().root.get_node_or_null(path)

func owner_of(node: Node):
	if node == null:
		return null
	var id: int = int(_owner_paths.get(_path(node), SERVER_ID))
	var p = get_player_by_id(id)
	return p if p != null else master()

func set_owner_of(player, node: Node) -> void:
	if node == null or player == null:
		return
	var path := _path(node)
	var requested: int = player.player_id
	if int(_owner_paths.get(path, SERVER_ID)) == requested:
		return
	if _is_server:
		_server_request_owner(path, multiplayer.get_unique_id(), requested)
	else:
		_rpc_request_owner.rpc_id(SERVER_ID, path, requested)

@rpc("any_peer", "reliable")
func _rpc_request_owner(path: String, requested: int) -> void:
	if not _is_server:
		return
	_server_request_owner(path, multiplayer.get_remote_sender_id(), requested)

func _server_request_owner(path: String, requester: int, requested: int) -> void:
	var current: int = int(_owner_paths.get(path, SERVER_ID))
	if current == requested:
		return
	if current == multiplayer.get_unique_id():
		# the server owns it: evaluate OnOwnershipRequest locally
		if _evaluate_ownership_request(path, requester, requested):
			_grant_owner(path, requested)
	else:
		_pending_owner[path] = requester
		_rpc_ownership_query.rpc_id(current, path, requester, requested)

@rpc("authority", "reliable")
func _rpc_ownership_query(path: String, requester: int, requested: int) -> void:
	var ok := _evaluate_ownership_request(path, requester, requested)
	_rpc_ownership_answer.rpc_id(SERVER_ID, path, requested, ok)

@rpc("any_peer", "reliable")
func _rpc_ownership_answer(path: String, requested: int, ok: bool) -> void:
	if not _is_server:
		return
	if multiplayer.get_remote_sender_id() != int(_owner_paths.get(path, SERVER_ID)):
		return
	_pending_owner.erase(path)
	if ok:
		_grant_owner(path, requested)

func _evaluate_ownership_request(path: String, requester: int, requested: int) -> bool:
	var node := _node(path)
	if node == null:
		return true
	var req = get_player_by_id(requester)
	var reqd = get_player_by_id(requested)
	if node.has_method("OnOwnershipRequest"):
		return bool(node.call("OnOwnershipRequest", req, reqd))
	return true

func _grant_owner(path: String, id: int) -> void:
	_rpc_apply_owner.rpc(path, id)
	_apply_owner(path, id)

@rpc("authority", "reliable")
func _rpc_apply_owner(path: String, id: int) -> void:
	_apply_owner(path, id)

func _apply_owner(path: String, id: int) -> void:
	var prev: int = int(_owner_paths.get(path, SERVER_ID))
	_owner_paths[path] = id
	if prev == id:
		return
	var node := _node(path)
	var p = get_player_by_id(id)
	if node != null and p != null:
		Udon._ownership_transferred(node, p)

func is_object_ready(_node: Node) -> bool:
	return _settled

func is_network_settled() -> bool:
	return _settled

func server_time_ms() -> int:
	return Time.get_ticks_msec() + _time_offset_ms - _start_ms

# ---------------------------------------------------------------------------
# Network events
# ---------------------------------------------------------------------------

func send_network_event(behaviour: Node, target: int, event_name: String, args: Array) -> void:
	if not _connected:
		return
	var path := _path(behaviour)
	var sender := multiplayer.get_unique_id()
	if _is_server:
		_relay_event(path, target, event_name, args, sender)
	else:
		_rpc_relay_event.rpc_id(SERVER_ID, path, target, event_name, args)

@rpc("any_peer", "reliable")
func _rpc_relay_event(path: String, target: int, event_name: String, args: Array) -> void:
	if not _is_server:
		return
	_relay_event(path, target, event_name, args, multiplayer.get_remote_sender_id())

## Server side: deliver to the peers a NetworkEventTarget denotes. `All` arrives here as
## `Others` because the sender already ran it locally.
func _relay_event(path: String, target: int, event_name: String, args: Array, sender: int) -> void:
	match target:
		Udon.NetworkEventTarget_Owner:
			var owner_id: int = int(_owner_paths.get(path, SERVER_ID))
			if owner_id == multiplayer.get_unique_id():
				_deliver_event(path, event_name, args, sender)
			else:
				_rpc_deliver_event.rpc_id(owner_id, path, event_name, args, sender)
		Udon.NetworkEventTarget_Self:
			if sender == multiplayer.get_unique_id():
				_deliver_event(path, event_name, args, sender)
			else:
				_rpc_deliver_event.rpc_id(sender, path, event_name, args, sender)
		_:
			# Others / All-from-remote: everyone except the sender
			if sender != multiplayer.get_unique_id():
				_deliver_event(path, event_name, args, sender)
			for pid in multiplayer.get_peers():
				if pid != sender:
					_rpc_deliver_event.rpc_id(pid, path, event_name, args, sender)

@rpc("authority", "reliable")
func _rpc_deliver_event(path: String, event_name: String, args: Array, sender: int) -> void:
	_deliver_event(path, event_name, args, sender)

func _deliver_event(path: String, event_name: String, args: Array, sender: int) -> void:
	var node := _node(path)
	if node == null:
		return
	Udon.receive_network_event(node, event_name, args, get_player_by_id(sender))

# ---------------------------------------------------------------------------
# Variable synchronization
# ---------------------------------------------------------------------------

func serialize(behaviour: Node, data: Dictionary) -> Dictionary:
	if not _connected:
		return {"success": false, "byteCount": 0}
	var path := _path(behaviour)
	if int(_owner_paths.get(path, SERVER_ID)) != multiplayer.get_unique_id():
		push_warning("RequestSerialization on %s by a non-owner is ignored" % path)
		return {"success": false, "byteCount": 0}
	var send_time: float = float(server_time_ms()) / 1000.0
	_last_sent[path] = data.duplicate(true)
	if _is_server:
		_snapshots[path] = [data, send_time]
		_rpc_deliver_vars.rpc(path, data, send_time)
	else:
		_rpc_relay_vars.rpc_id(SERVER_ID, path, data, send_time)
	return {"success": true, "byteCount": var_to_bytes(data).size()}

@rpc("any_peer", "reliable")
func _rpc_relay_vars(path: String, data: Dictionary, send_time: float) -> void:
	if not _is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if int(_owner_paths.get(path, SERVER_ID)) != sender:
		return
	_snapshots[path] = [data, send_time]
	_apply_vars(path, data, send_time, false)
	for pid in multiplayer.get_peers():
		if pid != sender:
			_rpc_deliver_vars.rpc_id(pid, path, data, send_time)

@rpc("authority", "reliable")
func _rpc_deliver_vars(path: String, data: Dictionary, send_time: float) -> void:
	_apply_vars(path, data, send_time, false)

func _apply_vars(path: String, data: Dictionary, send_time: float, initial: bool) -> void:
	var node := _node(path)
	if node == null or not node.has_method("udon_deserialize"):
		return
	var modes: Dictionary = node.udon_sync_var_modes() if node.has_method("udon_sync_var_modes") else {}
	var immediate: Dictionary = {}
	for k in data.keys():
		var mode: String = str(modes.get(k, "None"))
		if not initial and (mode == "Linear" or mode == "Smooth") and _interpolable(node.get(k), data[k]):
			if not _interp.has(path):
				_interp[path] = {}
			_interp[path][k] = [node.get(k), data[k], 0.0, 1.0 / maxf(sync_rate_hz, 1.0)]
		else:
			immediate[k] = data[k]
	var result := {"sendTime": send_time, "receiveTime": float(server_time_ms()) / 1000.0}
	if immediate.is_empty() and not data.is_empty():
		# still raise OnDeserialization for interpolated-only updates
		node.udon_deserialize({}, result)
	else:
		node.udon_deserialize(immediate, result)

func _interpolable(a, b) -> bool:
	var t := typeof(a)
	return t == typeof(b) and (t == TYPE_FLOAT or t == TYPE_INT or t == TYPE_VECTOR3 or t == TYPE_VECTOR2 or t == TYPE_QUATERNION or t == TYPE_COLOR)

func _step_interpolation(delta: float) -> void:
	for path in _interp.keys():
		var node := _node(path)
		var vars: Dictionary = _interp[path]
		if node == null:
			_interp.erase(path)
			continue
		for k in vars.keys():
			var e: Array = vars[k]
			e[2] = minf(float(e[2]) + delta, float(e[3]))
			var t: float = float(e[2]) / float(e[3])
			var a = e[0]
			var b = e[1]
			var v
			match typeof(a):
				TYPE_QUATERNION:
					v = (a as Quaternion).slerp(b, t)
				TYPE_INT:
					v = int(roundf(lerpf(float(a), float(b), t)))
				TYPE_FLOAT:
					v = lerpf(a, b, t)
				_:
					v = lerp(a, b, t)
			node.set(k, v)
			if t >= 1.0:
				vars.erase(k)
		if vars.is_empty():
			_interp.erase(path)

## Continuous sync: owners re-send changed synced variables at `sync_rate_hz`.
func _tick_continuous() -> void:
	var me := multiplayer.get_unique_id()
	for b in Udon.behaviours():
		if not b.has_method("udon_sync_mode"):
			continue
		var mode: String = b.udon_sync_mode()
		if mode != "continuous" and mode != "any":
			continue
		var synced: Array = b.udon_synced_vars()
		if synced.is_empty():
			continue
		var path := _path(b)
		if int(_owner_paths.get(path, SERVER_ID)) != me:
			continue
		var data: Dictionary = b.udon_serialize()
		if _last_sent.get(path, null) != data:
			serialize(b, data)

# ---------------------------------------------------------------------------
# Object sync (transform replication)
# ---------------------------------------------------------------------------

func object_sync(node: Node):
	var adapter = super.object_sync(node)
	if node is Node3D:
		var path := _path(node)
		if not _obj_sync.has(path):
			_obj_sync[path] = {"node": node, "target": node.global_transform, "vel": Vector3.ZERO, "t": 1.0, "teleport": false}
	return adapter

func flag_discontinuity(node: Node) -> void:
	_discontinuity[_path(node)] = true

func _tick_object_sync() -> void:
	var me := multiplayer.get_unique_id()
	for path in _obj_sync.keys():
		var e: Dictionary = _obj_sync[path]
		var n = e["node"]
		if not is_instance_valid(n):
			_obj_sync.erase(path)
			continue
		if int(_owner_paths.get(path, SERVER_ID)) != me:
			continue
		var vel: Vector3 = n.linear_velocity if n is RigidBody3D else Vector3.ZERO
		var tp: bool = _discontinuity.get(path, false)
		_discontinuity.erase(path)
		if _is_server:
			_rpc_deliver_transform.rpc(path, n.global_transform, vel, tp)
		else:
			_rpc_relay_transform.rpc_id(SERVER_ID, path, n.global_transform, vel, tp)

@rpc("any_peer", "unreliable_ordered")
func _rpc_relay_transform(path: String, xf: Transform3D, vel: Vector3, teleport: bool) -> void:
	if not _is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if int(_owner_paths.get(path, SERVER_ID)) != sender:
		return
	_apply_transform(path, xf, vel, teleport)
	for pid in multiplayer.get_peers():
		if pid != sender:
			_rpc_deliver_transform.rpc_id(pid, path, xf, vel, teleport)

@rpc("authority", "unreliable_ordered")
func _rpc_deliver_transform(path: String, xf: Transform3D, vel: Vector3, teleport: bool) -> void:
	_apply_transform(path, xf, vel, teleport)

func _apply_transform(path: String, xf: Transform3D, vel: Vector3, teleport: bool) -> void:
	var node := _node(path)
	if not (node is Node3D):
		return
	if not _obj_sync.has(path):
		_obj_sync[path] = {"node": node, "target": xf, "vel": vel, "t": 0.0, "teleport": teleport}
	var e: Dictionary = _obj_sync[path]
	e["target"] = xf
	e["vel"] = vel
	e["t"] = 0.0
	e["teleport"] = teleport
	if node is RigidBody3D:
		node.freeze = true
	if teleport:
		node.global_transform = xf
		e["t"] = 1.0

func _step_object_sync(delta: float) -> void:
	var me := multiplayer.get_unique_id()
	var interval: float = 1.0 / maxf(sync_rate_hz, 1.0)
	for path in _obj_sync.keys():
		var e: Dictionary = _obj_sync[path]
		var n = e["node"]
		if not is_instance_valid(n) or int(_owner_paths.get(path, SERVER_ID)) == me:
			continue
		if float(e["t"]) >= 1.0:
			continue
		e["t"] = minf(float(e["t"]) + delta / interval, 1.0)
		n.global_transform = n.global_transform.interpolate_with(e["target"], float(e["t"]))

# ---------------------------------------------------------------------------
# Pickups & stations
# ---------------------------------------------------------------------------

func pickup(node: Node):
	var a = super.pickup(node)
	if a != null and "provider" in a:
		a.provider = self
	return a

## Called by the pickup adapter when the local player grabs/drops; replicated to others.
func replicate_pickup(node: Node, held: bool, hand: int) -> void:
	if not _connected:
		return
	var path := _path(node)
	var me := multiplayer.get_unique_id()
	if held:
		set_owner_of(_local_player, node)
	if _is_server:
		_rpc_pickup_state.rpc(path, held, me, hand)
	else:
		_rpc_relay_pickup.rpc_id(SERVER_ID, path, held, hand)

@rpc("any_peer", "reliable")
func _rpc_relay_pickup(path: String, held: bool, hand: int) -> void:
	if not _is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	_apply_pickup(path, held, sender, hand)
	for pid in multiplayer.get_peers():
		if pid != sender:
			_rpc_pickup_state.rpc_id(pid, path, held, sender, hand)

@rpc("authority", "reliable")
func _rpc_pickup_state(path: String, held: bool, holder: int, hand: int) -> void:
	_apply_pickup(path, held, holder, hand)

func _apply_pickup(path: String, held: bool, holder: int, hand: int) -> void:
	var node := _node(path)
	if node == null:
		return
	var a = super.pickup(node)
	if a == null:
		return
	a.is_held = held
	a.current_player = get_player_by_id(holder) if held else null
	a.current_hand = hand if held else 0

func station(node: Node):
	var a = super.station(node)
	if a != null and "provider" in a:
		a.provider = self
	return a

func replicate_station(node: Node, entered: bool) -> void:
	if not _connected:
		return
	var path := _path(node)
	if _is_server:
		_rpc_station_state.rpc(path, entered, multiplayer.get_unique_id())
	else:
		_rpc_relay_station.rpc_id(SERVER_ID, path, entered)

@rpc("any_peer", "reliable")
func _rpc_relay_station(path: String, entered: bool) -> void:
	if not _is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	_apply_station(path, entered, sender)
	for pid in multiplayer.get_peers():
		if pid != sender:
			_rpc_station_state.rpc_id(pid, path, entered, sender)

@rpc("authority", "reliable")
func _rpc_station_state(path: String, entered: bool, who: int) -> void:
	_apply_station(path, entered, who)

func _apply_station(path: String, entered: bool, who: int) -> void:
	var node := _node(path)
	var p = get_player_by_id(who)
	if node == null or p == null:
		return
	var a = super.station(node)
	if entered:
		a.occupant = p
		a._dispatch("OnStationEntered", p)
	else:
		a.occupant = null
		a._dispatch("OnStationExited", p)

# ---------------------------------------------------------------------------
# Player data persistence (server authoritative, replicated to all peers)
# ---------------------------------------------------------------------------

func player_data_set(key: String, value) -> void:
	var lp = _local_player
	if lp == null:
		return
	super.player_data_set(key, value)
	if _is_server:
		_persist_store(lp.display_name, key, value)
		_rpc_player_data.rpc(lp.player_id, key, value)
		Udon.broadcast_event("OnPlayerDataUpdated", [lp, [{"Key": key, "State": 1}]])
	else:
		_rpc_relay_player_data.rpc_id(SERVER_ID, key, value)

func player_data_remove(key: String) -> void:
	player_data_set(key, null)

@rpc("any_peer", "reliable")
func _rpc_relay_player_data(key: String, value) -> void:
	if not _is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var name_: String = str(_player_names.get(sender, ""))
	_persist_store(name_, key, value)
	_apply_player_data(sender, key, value)
	for pid in multiplayer.get_peers():
		if pid != sender:
			_rpc_player_data.rpc_id(pid, sender, key, value)

@rpc("authority", "reliable")
func _rpc_player_data(id: int, key: String, value) -> void:
	_apply_player_data(id, key, value)

func _apply_player_data(id: int, key: String, value) -> void:
	if not _player_data.has(id):
		_player_data[id] = {}
	if value == null:
		_player_data[id].erase(key)
	else:
		_player_data[id][key] = value
	var p = get_player_by_id(id)
	if p != null:
		Udon.broadcast_event("OnPlayerDataUpdated", [p, [{"Key": key, "State": 1}]])

func _persist_store(name_: String, key: String, value) -> void:
	if not _persist.has(name_):
		_persist[name_] = {}
	if value == null:
		_persist[name_].erase(key)
	else:
		_persist[name_][key] = value
	_save_persist()

func _load_persist() -> void:
	_persist = load_variant_file(player_data_path)

func _save_persist() -> void:
	save_variant_file(player_data_path, _persist)

# ---------------------------------------------------------------------------
# Per-frame work
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	super._process(delta)
	if not _connected:
		return
	_step_interpolation(delta)
	_step_object_sync(delta)
	_accum += delta
	if _accum >= 1.0 / maxf(sync_rate_hz, 1.0):
		_accum = 0.0
		_tick_continuous()
		_tick_object_sync()
		if _player_node != null:
			var vel: Vector3 = _player_node.velocity if _player_node is CharacterBody3D else Vector3.ZERO
			if _is_server:
				for pid in multiplayer.get_peers():
					_rpc_player_state_from.rpc_id(pid, SERVER_ID, _player_node.global_position, U.get_global_rotation(_player_node), vel)
			else:
				_rpc_player_state.rpc_id(SERVER_ID, _player_node.global_position, U.get_global_rotation(_player_node), vel)
