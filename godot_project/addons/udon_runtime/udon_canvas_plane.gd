## World-space Unity canvas plane (created by unidot's udon_integration): shows the SubViewport
## that holds the converted UI on this quad, refits the viewport to the UI's real bounds once the
## controls are laid out, and turns canvases that ended up inside another canvas (prefab instances
## placed under UI) into a texture inside the parent canvas.
@tool
extends MeshInstance3D

@export var viewport_path: NodePath = NodePath("../Viewport")

var _vp: SubViewport = null
var _view: TextureRect = null


func _ready() -> void:
	_vp = get_node_or_null(viewport_path) as SubViewport
	if _vp == null:
		return
	var mat := material_override as BaseMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	else:
		mat = mat.duplicate()
	material_override = mat
	mat.albedo_texture = _vp.get_texture()
	if Engine.is_editor_hint():
		return
	call_deferred("_fit_and_nest")


func _canvas_node() -> Node:
	return get_parent()


func _fit_and_nest() -> void:
	await get_tree().process_frame
	var canvas: Node = _canvas_node()
	if canvas == null or not canvas.has_meta("udon_canvas") or _vp == null:
		return
	_fit(canvas)
	_nest(canvas)


## Resize the viewport and plane to the union of the converted controls (Unity canvases do not
## clip their children).
func _fit(canvas: Node) -> void:
	var cfg: Dictionary = canvas.get_meta("udon_canvas")
	var root: Control = canvas.get_node_or_null(cfg.get("root", NodePath()))
	if root == null:
		return
	var k: float = float(cfg.get("k", 1.0))
	var rsize: Vector2 = cfg.get("size", root.size)
	var union: Rect2 = Rect2(Vector2.ZERO, rsize)
	var base: Vector2 = root.global_position
	for c in root.find_children("*", "Control", true, false):
		if not c.is_visible_in_tree():
			continue
		var r: Rect2 = c.get_global_rect()
		union = union.merge(Rect2((r.position - base) / k, r.size / k))
	if union.size.x <= 0.0 or union.size.y <= 0.0:
		return
	var w: int = clampi(int(ceil(union.size.x * k)), 1, 8192)
	var h: int = clampi(int(ceil(union.size.y * k)), 1, 8192)
	if _vp.size != Vector2i(w, h):
		_vp.size = Vector2i(w, h)
	root.position = -union.position * k
	var pv: Vector2 = cfg.get("pivot", Vector2(0.5, 0.5))
	var center := Vector3(pv.x * rsize.x - union.position.x - union.size.x * 0.5, (1.0 - pv.y) * rsize.y - union.position.y - union.size.y * 0.5, 0.0)
	var quad: QuadMesh = mesh as QuadMesh
	if quad != null:
		quad.size = union.size
	transform = Transform3D(Basis.from_euler(Vector3(0.0, PI, 0.0)), center)
	var area: Area3D = canvas.get_node_or_null("UiShape")
	if area != null:
		area.transform = transform
		var shape: CollisionShape3D = area.get_node_or_null("CollisionShape3D")
		if shape != null and shape.shape is BoxShape3D:
			shape.shape.size = Vector3(union.size.x, union.size.y, 0.01)
	cfg["plane_size"] = union.size
	cfg["offset"] = union.position
	cfg["plane_center"] = center
	canvas.set_meta("udon_canvas", cfg)


## A canvas whose Node3D sits below another canvas (its parent chain passes a converted canvas)
## cannot be a 3D plane there: show its viewport as a control of the enclosing canvas instead.
func _nest(canvas: Node) -> void:
	var anc: Node = canvas.get_parent()
	var host: Control = anc as Control
	while anc != null and not anc.has_meta("udon_canvas"):
		anc = anc.get_parent()
	if anc == null or host == null:
		return
	visible = false
	var area: Area3D = canvas.get_node_or_null("UiShape")
	if area != null:
		area.monitoring = false
		area.monitorable = false
		area.visible = false
	if _view != null:
		return
	_view = TextureRect.new()
	_view.name = String(canvas.name) + "_View"
	_view.texture = _vp.get_texture()
	_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view.stretch_mode = TextureRect.STRETCH_SCALE
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	var cfg: Dictionary = canvas.get_meta("udon_canvas")
	var units: Vector2 = cfg.get("plane_size", cfg.get("size", Vector2(1, 1)))
	var rect: Dictionary = canvas.get_meta("udon_rect") if canvas.has_meta("udon_rect") else {}
	var amin: Vector2 = rect.get("anchor_min", Vector2(0.5, 0.5))
	var amax: Vector2 = rect.get("anchor_max", Vector2(0.5, 0.5))
	var ap: Vector2 = rect.get("anchored_position", Vector2.ZERO)
	var sd: Vector2 = rect.get("size_delta", units)
	var pv: Vector2 = rect.get("pivot", Vector2(0.5, 0.5))
	var sc: Vector2 = rect.get("scale", Vector2.ONE)
	_view.anchor_left = amin.x
	_view.anchor_right = amax.x
	_view.anchor_top = 1.0 - amax.y
	_view.anchor_bottom = 1.0 - amin.y
	_view.offset_left = ap.x - pv.x * sd.x
	_view.offset_right = ap.x + (1.0 - pv.x) * sd.x
	_view.offset_top = -ap.y - (1.0 - pv.y) * sd.y
	_view.offset_bottom = -ap.y + pv.y * sd.y
	_view.scale = sc
	_view.pivot_offset = Vector2(pv.x * sd.x, (1.0 - pv.y) * sd.y)
	# the nested texture covers the union rect, which may extend beyond the canvas rect
	var off: Vector2 = cfg.get("offset", Vector2.ZERO)
	_view.offset_left += off.x
	_view.offset_top += off.y
	_view.offset_right = _view.offset_left + units.x
	_view.offset_bottom = _view.offset_top + units.y
	_view.gui_input.connect(_forward_input)
	host.add_child(_view)
	_view.z_index = 1


func _forward_input(ev: InputEvent) -> void:
	if _vp == null or _view == null:
		return
	var e: InputEvent = ev.duplicate()
	if e is InputEventMouse:
		var local: Vector2 = _view.get_local_mouse_position()
		var px: Vector2 = local / _view.size * Vector2(_vp.size)
		e.position = px
		e.global_position = px
	_vp.push_input(e, true)
