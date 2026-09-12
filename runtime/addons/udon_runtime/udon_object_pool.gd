## `VRCObjectPool` surface: a fixed set of child nodes that are activated on spawn.
extends RefCounted

var node: Node = null
var pool: Array = []

func _init(n: Node = null) -> void:
	node = n
	if n != null and n.has_meta("udon_object_pool") and n.get_meta("udon_object_pool").has("pool"):
		# explicit pool written by the scene converter (VRCObjectPool.Pool)
		for np in n.get_meta("udon_object_pool")["pool"]:
			var c: Node = n.get_node_or_null(np) if np is NodePath else null
			if c != null:
				pool.append(c)
				U.set_active(c, false)
	elif n != null:
		for c in n.get_children():
			pool.append(c)
			U.set_active(c, false)

func try_to_spawn() -> Node:
	for c in pool:
		if is_instance_valid(c) and not U.is_active(c):
			U.set_active(c, true)
			if c.has_method("OnSpawn"):
				c.call("OnSpawn")
			return c
	return null

func return_object(obj: Node) -> void:
	if obj != null and pool.has(obj):
		U.set_active(obj, false)

func shuffle() -> void:
	pool.shuffle()
