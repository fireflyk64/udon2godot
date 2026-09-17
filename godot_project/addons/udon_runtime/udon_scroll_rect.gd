## Unity ScrollRect on a ScrollContainer (set by unidot's udon_integration). Godot scrolls the
## container's first child by that child's minimum size; Unity scrolls `content` inside a stretched
## viewport object. The first child (Unity's Viewport) therefore takes the content's size as its
## minimum on the enabled axes, and `scrolled` fires like ScrollRect.onValueChanged with the
## normalized position (Unity: y = 1 at the top).
extends ScrollContainer

signal scrolled(normalized: Vector2)

var _content: Control = null
## Unity Scrollbar objects linked to this ScrollRect (m_VerticalScrollbar / m_HorizontalScrollbar):
## their value is the normalized position (vertical: 1 = top), in both directions.
var _vbar: Range = null
var _hbar: Range = null
var _syncing: bool = false


func _ready() -> void:
	get_v_scroll_bar().value_changed.connect(_on_bar)
	get_h_scroll_bar().value_changed.connect(_on_bar)
	if has_meta("udon_scroll"):
		var cfg: Dictionary = get_meta("udon_scroll")
		if cfg.get("content") is NodePath:
			_content = get_node_or_null(cfg["content"]) as Control
		if cfg.get("vbar") is NodePath:
			_vbar = get_node_or_null(cfg["vbar"]) as Range
		if cfg.get("hbar") is NodePath:
			_hbar = get_node_or_null(cfg["hbar"]) as Range
	if _vbar != null:
		_vbar.value_changed.connect(_on_unity_bar)
	if _hbar != null:
		_hbar.value_changed.connect(_on_unity_bar)
	if _content != null and not _content.resized.is_connected(_fit):
		_content.resized.connect(_fit)
	call_deferred("_fit")
	call_deferred("_push_to_unity_bars")


## A Unity Scrollbar moved (by the pointer or by a script: `scrollbar.value = 0` scrolls down).
func _on_unity_bar(_value: float) -> void:
	if _syncing:
		return
	_syncing = true
	if _vbar != null:
		var v := get_v_scroll_bar()
		v.value = (1.0 - _vbar.value) * (v.max_value - v.page)
	if _hbar != null:
		var h := get_h_scroll_bar()
		h.value = _hbar.value * (h.max_value - h.page)
	_syncing = false
	_emit_scrolled()


func _push_to_unity_bars() -> void:
	if _syncing:
		return
	_syncing = true
	var n: Vector2 = _normalized()
	if _vbar != null:
		_vbar.set_value_no_signal(n.y)
	if _hbar != null:
		_hbar.set_value_no_signal(n.x)
	_syncing = false


func _fit() -> void:
	if _content == null or get_child_count() == 0:
		return
	var first: Control = get_child(0) as Control
	if first == null:
		return
	# a ScrollContainer gives its child only the minimum size unless it expands: Unity's viewport
	# object is stretched over the scroll rect
	first.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	first.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var want: Vector2 = _content.size * _content.scale.abs()
	var m := Vector2(want.x if horizontal_scroll_mode != SCROLL_MODE_DISABLED else 0.0, want.y if vertical_scroll_mode != SCROLL_MODE_DISABLED else 0.0)
	if not first.custom_minimum_size.is_equal_approx(m):
		first.custom_minimum_size = m


func _normalized() -> Vector2:
	var v := get_v_scroll_bar()
	var h := get_h_scroll_bar()
	var vr: float = v.max_value - v.page
	var hr: float = h.max_value - h.page
	return Vector2(h.value / hr if hr > 0.0 else 0.0, 1.0 - (v.value / vr if vr > 0.0 else 0.0))


func _emit_scrolled() -> void:
	scrolled.emit(_normalized())


func _on_bar(_value: float) -> void:
	_push_to_unity_bars()
	_emit_scrolled()
