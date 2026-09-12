## `VRCPlayerApi` abstraction. A game subclasses this (or duck-types the same surface) to expose
## its own player objects; the default is a stationary local player.
extends RefCounted

const TRACKING_HEAD := 0
const TRACKING_LEFT_HAND := 1
const TRACKING_RIGHT_HAND := 2
const TRACKING_ORIGIN := 3
const TRACKING_AVATAR_ROOT := 4

var player_id: int = 0
var display_name: String = ""
var is_local: bool = false
var is_master: bool = false
var is_instance_owner: bool = false
var is_suspended: bool = false
var _valid: bool = true

## Optional node that represents the player in the scene (position/rotation source).
var node: Node3D = null

var _tags: Dictionary = {}
var _voice: Dictionary = {"gain": 15.0, "distance_near": 0.0, "distance_far": 25.0, "volumetric_radius": 0.0, "lowpass": true}
var _avatar_audio: Dictionary = {}
var _locomotion: Dictionary = {"walk_speed": 2.0, "run_speed": 4.0, "strafe_speed": 2.0, "jump_impulse": 3.0, "gravity_strength": 1.0}
var _combat: Dictionary = {"max_hitpoints": 100.0, "hitpoints": 100.0}
var _eye_height: float = 1.6
var _velocity: Vector3 = Vector3.ZERO
var _immobilized: bool = false
var _pickups_enabled: bool = true
var _in_vr: bool = false

func is_valid() -> bool:
	return _valid

func is_user_in_vr() -> bool:
	return _in_vr

func is_player_grounded() -> bool:
	if node is CharacterBody3D:
		return node.is_on_floor()
	return true

func get_position() -> Vector3:
	return U.get_position(node) if node != null else Vector3.ZERO

func get_rotation() -> Quaternion:
	return U.get_global_rotation(node) if node != null else Quaternion()

func get_velocity() -> Vector3:
	if node is CharacterBody3D:
		return U.from_gd_v(node.velocity)
	if node is RigidBody3D:
		return U.from_gd_v(node.linear_velocity)
	return _velocity

func set_velocity(v: Vector3) -> void:
	_velocity = v
	if node is CharacterBody3D:
		node.velocity = U.to_gd_v(v)
	elif node is RigidBody3D:
		node.linear_velocity = U.to_gd_v(v)

## Returns {"position": Vector3, "rotation": Quaternion} for a TrackingDataType.
func get_tracking_data(kind: int) -> Dictionary:
	var pos: Vector3 = get_position()
	var rot: Quaternion = get_rotation()
	match kind:
		TRACKING_HEAD:
			pos += Vector3(0.0, _eye_height, 0.0)
		TRACKING_LEFT_HAND:
			pos += rot * Vector3(-0.3, _eye_height * 0.6, 0.3)
		TRACKING_RIGHT_HAND:
			pos += rot * Vector3(0.3, _eye_height * 0.6, 0.3)
		_:
			pass
	return {"position": pos, "rotation": rot}

func get_bone_position(_bone: int) -> Vector3:
	return get_position()

func get_bone_rotation(_bone: int) -> Quaternion:
	return get_rotation()

func teleport_to(pos: Vector3, rot: Quaternion, _orientation: int = 0, _lerp_on_remote: bool = false) -> void:
	if node != null:
		U.set_position(node, pos)
		U.set_global_rotation(node, rot)

func respawn(_index: int = 0) -> void:
	Udon.broadcast_event("OnPlayerRespawn", [self])

func immobilize(b: bool) -> void:
	_immobilized = b

func is_immobilized() -> bool:
	return _immobilized

func use_attached_station() -> void:
	pass

func enable_pickups(b: bool) -> void:
	_pickups_enabled = b

func get_pickup_in_hand(_hand: int):
	return null

func play_haptic_event_in_hand(_hand: int, _duration: float, _amplitude: float, _frequency: float) -> void:
	pass

func set_player_tag(tag: String, value: String) -> void:
	_tags[tag] = value

func get_player_tag(tag: String) -> String:
	return _tags.get(tag, "")

func clear_player_tags() -> void:
	_tags.clear()

func get_voice(key: String):
	return _voice.get(key)

func set_voice(key: String, value) -> void:
	_voice[key] = value

func set_avatar_audio(key: String, value) -> void:
	_avatar_audio[key] = value

func get_locomotion(key: String) -> float:
	return float(_locomotion.get(key, 0.0))

func set_locomotion(key: String, value: float) -> void:
	_locomotion[key] = value

func get_avatar_eye_height() -> float:
	return _eye_height

func set_avatar_eye_height(h: float) -> void:
	_eye_height = h

func get_language() -> String:
	return "en"

func combat_get(key: String) -> float:
	return float(_combat.get(key, 0.0))

func combat_set(key: String, value: float) -> void:
	_combat[key] = value

func _to_string() -> String:
	return "UdonPlayer(%d %s)" % [player_id, display_name]
