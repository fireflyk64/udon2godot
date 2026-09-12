## `VRCObjectSync` surface: transform/physics replication of a node.
extends RefCounted

var node: Node = null
var allow_collision_ownership_transfer: bool = true
var force_kinematic_on_remote: bool = false
var _spawn_transform: Transform3D = Transform3D()

func _init(n: Node = null) -> void:
	node = n
	if n is Node3D:
		_spawn_transform = n.global_transform
	if n != null and n.has_meta("udon_object_sync"):
		var c: Dictionary = n.get_meta("udon_object_sync")
		for k in c.keys():
			if str(k) in self:
				set(str(k), c[k])

func flag_discontinuity() -> void:
	if Udon.provider != null and Udon.provider.has_method("flag_discontinuity"):
		Udon.provider.flag_discontinuity(node)

func respawn() -> void:
	if node is Node3D:
		node.global_transform = _spawn_transform
	if node is RigidBody3D:
		node.linear_velocity = Vector3.ZERO
		node.angular_velocity = Vector3.ZERO

func set_gravity(b: bool) -> void:
	if node is RigidBody3D:
		node.gravity_scale = 1.0 if b else 0.0

func set_kinematic(b: bool) -> void:
	if node is RigidBody3D:
		U.rb_set_kinematic(node, b)

func teleport_to(target: Node3D) -> void:
	if node is Node3D and target != null:
		node.global_transform = target.global_transform
