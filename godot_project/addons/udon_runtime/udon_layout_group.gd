## Unity UI auto layout for the Control this node is a child of (unidot's udon_integration adds it
## as a helper child named "UdonLayout", so the Control stays free for an Udon behaviour script).
##
## The parent's metadata describes the Unity components of that GameObject:
##   udon_layout  {type: "horizontal" | "vertical" | "grid", padding: [left, right, top, bottom],
##                 spacing, align (0..8, UpperLeft .. LowerRight), control_w, control_h, expand_w,
##                 expand_h, reverse, and for grids cell: Vector2, spacing2: Vector2, corner, axis,
##                 constraint (0 flexible, 1 columns, 2 rows), count}
##   udon_fitter  {h, v}   ContentSizeFitter: 0 unconstrained, 1 min size, 2 preferred size
## Children may carry  udon_layout_element {min: Vector2, pref: Vector2, flex: Vector2, ignore}
## with -1 for "not set" (Unity's LayoutElement).
##
## Sizes follow HorizontalOrVerticalLayoutGroup: every child has a minimum, preferred and
## flexible size per axis; the available space goes to the minimums first, then to the preferred
## sizes, the rest to flexible children. A child whose size is not controlled keeps its own.
extends Node

var _host: Control = null
var _queued: bool = false
var _busy: bool = false


func _ready() -> void:
	_host = get_parent() as Control
	if _host == null:
		return
	_host.child_order_changed.connect(queue_layout)
	_host.resized.connect(queue_layout)
	_host.child_entered_tree.connect(_watch)
	for c in _host.get_children():
		_watch(c)
	queue_layout()


func _watch(c: Node) -> void:
	if c is Control and c != _host:
		if not c.visibility_changed.is_connected(queue_layout):
			c.visibility_changed.connect(queue_layout)
		if not c.minimum_size_changed.is_connected(queue_layout):
			c.minimum_size_changed.connect(queue_layout)
		if not c.resized.is_connected(_child_resized):
			c.resized.connect(_child_resized)
	queue_layout()


func _child_resized() -> void:
	if not _busy:
		queue_layout()


## LayoutRebuilder.MarkLayoutForRebuild: the layout runs once at the end of the frame.
func queue_layout() -> void:
	if _queued or _busy or not is_inside_tree():
		return
	_queued = true
	call_deferred("layout_now")


func _children() -> Array:
	var out: Array = []
	for c in _host.get_children():
		if not (c is Control) or not c.visible:
			continue
		if c.has_meta("udon_layout_element") and bool(c.get_meta("udon_layout_element").get("ignore", false)):
			continue
		out.append(c)
	return out


static func layout_of(c: Control) -> Node:
	var l: Node = c.get_node_or_null("UdonLayout")
	return l if l != null and l.has_method("preferred_size") else null


## [min, preferred, flexible] of a child along one axis (0 = x, 1 = y).
func _child_sizes(c: Control, axis: int, controlled: bool, force_expand: bool) -> Array:
	if not controlled:
		var s: float = c.size[axis] * absf(c.scale[axis])
		return [s, s, 1.0 if force_expand else 0.0]
	var mn: float = 0.0
	var pref: float = _natural(c)[axis]
	var flex: float = 0.0
	if c.has_meta("udon_layout_element"):
		var le: Dictionary = c.get_meta("udon_layout_element")
		var lmin: Vector2 = le.get("min", Vector2(-1, -1))
		var lpref: Vector2 = le.get("pref", Vector2(-1, -1))
		var lflex: Vector2 = le.get("flex", Vector2(-1, -1))
		if lmin[axis] >= 0.0:
			mn = lmin[axis]
		if lpref[axis] >= 0.0:
			pref = lpref[axis]
		if lflex[axis] >= 0.0:
			flex = lflex[axis]
	pref = maxf(pref, mn)
	if force_expand:
		flex = maxf(flex, 1.0)
	return [mn, pref, flex]


## Preferred size of content Unity measures itself: texts, nested layout groups, sprites.
func _natural(c: Control) -> Vector2:
	var nested: Node = layout_of(c)
	if nested != null:
		return nested.preferred_size()
	if c is Label:
		return c.get_minimum_size()
	if c is RichTextLabel:
		return Vector2(c.size.x, c.get_content_height())
	if c is TextureRect and c.texture != null and c.texture.get_width() > 4:
		return c.texture.get_size()
	return Vector2.ZERO


func _cfg() -> Dictionary:
	return _host.get_meta("udon_layout") if _host != null and _host.has_meta("udon_layout") else {}


## Size this group asks for (LayoutGroup.preferredWidth / preferredHeight), padding included.
func preferred_size() -> Vector2:
	return _measure(1)


func minimum_size() -> Vector2:
	return _measure(0)


## which: 0 = minimum, 1 = preferred
func _measure(which: int) -> Vector2:
	var cfg: Dictionary = _cfg()
	var pad: Array = cfg.get("padding", [0, 0, 0, 0])
	var kids: Array = _children()
	var out := Vector2(float(pad[0]) + float(pad[1]), float(pad[2]) + float(pad[3]))
	var kind: String = str(cfg.get("type", ""))
	if kind == "grid":
		var cell: Vector2 = cfg.get("cell", Vector2(100, 100))
		var gap: Vector2 = cfg.get("spacing2", Vector2.ZERO)
		var dims: Vector2i = _grid_dims(cfg, kids.size(), _host.size - out)
		return out + Vector2(dims.x * cell.x + maxi(dims.x - 1, 0) * gap.x, dims.y * cell.y + maxi(dims.y - 1, 0) * gap.y)
	if kind != "horizontal" and kind != "vertical":
		# a ContentSizeFitter without a layout group: the object's own content (a text)
		if _host is Label:
			return _host.get_minimum_size()
		if _host is RichTextLabel:
			return Vector2(_host.size.x, _host.get_content_height())
		return _host.size
	var axis: int = 0 if kind == "horizontal" else 1
	var cross: int = 1 - axis
	var along: float = 0.0
	var across: float = 0.0
	for c in kids:
		along += _child_sizes(c, axis, bool(cfg.get("control_w" if axis == 0 else "control_h", false)), bool(cfg.get("expand_w" if axis == 0 else "expand_h", false)))[which]
		across = maxf(across, _child_sizes(c, cross, bool(cfg.get("control_w" if cross == 0 else "control_h", false)), false)[which])
	along += float(cfg.get("spacing", 0.0)) * maxi(kids.size() - 1, 0)
	var res := out
	res[axis] += along
	res[cross] += across
	return res


func layout_now() -> void:
	_queued = false
	if _host == null or _busy:
		return
	_busy = true
	_fit()
	var cfg: Dictionary = _cfg()
	match str(cfg.get("type", "")):
		"horizontal":
			_linear(cfg, 0)
		"vertical":
			_linear(cfg, 1)
		"grid":
			_grid(cfg)
	_busy = false


## ContentSizeFitter: the object takes its minimum / preferred size on the fitted axes and grows
## away from its pivot, as a RectTransform does.
func _fit() -> void:
	if not _host.has_meta("udon_fitter"):
		return
	var f: Dictionary = _host.get_meta("udon_fitter")
	var want: Vector2 = _host.size
	var modes: Array = [int(f.get("h", 0)), int(f.get("v", 0))]
	for axis in range(2):
		if modes[axis] == 1:
			want[axis] = minimum_size()[axis]
		elif modes[axis] == 2:
			want[axis] = preferred_size()[axis]
	if want.is_equal_approx(_host.size):
		return
	var pivot := Vector2(_host.pivot_offset.x / _host.size.x if _host.size.x > 0.0 else 0.0, _host.pivot_offset.y / _host.size.y if _host.size.y > 0.0 else 0.0)
	var delta: Vector2 = want - _host.size
	var pos: Vector2 = _host.position - delta * pivot
	# sizes are set directly on the fitted axes: stretching anchors there would fight them
	for axis in range(2):
		if modes[axis] != 0:
			_free_axis(_host, axis)
	_host.size = want
	_host.position = pos
	_host.pivot_offset = pivot * want


## Collapse the anchors of one axis to the parent's origin without moving the rectangle.
static func _free_axis(c: Control, axis: int) -> void:
	var a: int = SIDE_LEFT if axis == 0 else SIDE_TOP
	var b: int = SIDE_RIGHT if axis == 0 else SIDE_BOTTOM
	if c.get_anchor(a) != 0.0 or c.get_anchor(b) != 0.0:
		c.set_anchor(a, 0.0, false, false)
		c.set_anchor(b, 0.0, false, false)


func _place(c: Control, axis: int, pos: float, size: float, set_size: bool) -> void:
	_free_axis(c, axis)
	if set_size:
		var s: Vector2 = c.size
		s[axis] = size / maxf(absf(c.scale[axis]), 0.0001)
		c.size = s
	var p: Vector2 = c.position
	p[axis] = pos
	c.position = p


func _linear(cfg: Dictionary, axis: int) -> void:
	var kids: Array = _children()
	if bool(cfg.get("reverse", false)):
		kids.reverse()
	var pad: Array = cfg.get("padding", [0, 0, 0, 0])
	var pad_start: Array = [float(pad[0]), float(pad[2])]
	var pad_total: Array = [float(pad[0]) + float(pad[1]), float(pad[2]) + float(pad[3])]
	var align: int = int(cfg.get("align", 0))
	var align_frac: Array = [(align % 3) * 0.5, (align / 3) * 0.5]
	var control: Array = [bool(cfg.get("control_w", false)), bool(cfg.get("control_h", false))]
	var expand: Array = [bool(cfg.get("expand_w", false)), bool(cfg.get("expand_h", false))]
	var spacing: float = float(cfg.get("spacing", 0.0))
	var cross: int = 1 - axis
	# --- along the layout axis ---
	var sizes: Array = []
	var total_min: float = 0.0
	var total_pref: float = 0.0
	var total_flex: float = 0.0
	for c in kids:
		var s: Array = _child_sizes(c, axis, control[axis], expand[axis])
		sizes.append(s)
		total_min += s[0]
		total_pref += s[1]
		total_flex += s[2]
	var gaps: float = spacing * maxi(kids.size() - 1, 0)
	var available: float = _host.size[axis] - pad_total[axis] - gaps
	var min_to_pref: float = 0.0
	if total_pref > total_min:
		min_to_pref = clampf((available - total_min) / (total_pref - total_min), 0.0, 1.0)
	var surplus: float = maxf(available - total_pref, 0.0)
	var per_flex: float = surplus / total_flex if total_flex > 0.0 else 0.0
	var used: float = (total_pref if available >= total_pref else maxf(total_min, available)) + gaps
	var pos: float = pad_start[axis]
	if total_flex <= 0.0:
		pos += maxf(_host.size[axis] - pad_total[axis] - used, 0.0) * align_frac[axis]
	for i in range(kids.size()):
		var c: Control = kids[i]
		var s: Array = sizes[i]
		var slot: float = lerpf(s[0], s[1], min_to_pref) + s[2] * per_flex
		if control[axis]:
			_place(c, axis, pos, slot, true)
		else:
			var own: float = c.size[axis] * absf(c.scale[axis])
			_place(c, axis, pos + (slot - own) * align_frac[axis], own, false)
		pos += slot + spacing
	# --- across ---
	var inner: float = _host.size[cross] - pad_total[cross]
	for c in kids:
		var s: Array = _child_sizes(c, cross, control[cross], expand[cross])
		if control[cross]:
			var want: float = inner if s[2] > 0.0 else clampf(s[1], s[0], maxf(inner, s[0]))
			_place(c, cross, pad_start[cross] + (inner - want) * align_frac[cross], want, true)
		else:
			var own: float = c.size[cross] * absf(c.scale[cross])
			_place(c, cross, pad_start[cross] + (inner - own) * align_frac[cross], own, false)


func _grid_dims(cfg: Dictionary, count: int, inner: Vector2) -> Vector2i:
	var cell: Vector2 = cfg.get("cell", Vector2(100, 100))
	var gap: Vector2 = cfg.get("spacing2", Vector2.ZERO)
	var constraint: int = int(cfg.get("constraint", 0))
	var n: int = maxi(int(cfg.get("count", 2)), 1)
	var cols: int
	var rows: int
	if constraint == 1:
		cols = n
		rows = ceili(float(count) / cols)
	elif constraint == 2:
		rows = n
		cols = ceili(float(count) / rows)
	elif int(cfg.get("axis", 0)) == 0:
		cols = maxi(1, floori((inner.x + gap.x + 0.001) / (cell.x + gap.x)))
		rows = ceili(float(count) / cols)
	else:
		rows = maxi(1, floori((inner.y + gap.y + 0.001) / (cell.y + gap.y)))
		cols = ceili(float(count) / rows)
	return Vector2i(maxi(cols, 1), maxi(rows, 1))


func _grid(cfg: Dictionary) -> void:
	var kids: Array = _children()
	var pad: Array = cfg.get("padding", [0, 0, 0, 0])
	var cell: Vector2 = cfg.get("cell", Vector2(100, 100))
	var gap: Vector2 = cfg.get("spacing2", Vector2.ZERO)
	var inner: Vector2 = _host.size - Vector2(float(pad[0]) + float(pad[1]), float(pad[2]) + float(pad[3]))
	var dims: Vector2i = _grid_dims(cfg, kids.size(), inner)
	var corner: int = int(cfg.get("corner", 0))
	var along_x: bool = int(cfg.get("axis", 0)) == 0
	var align: int = int(cfg.get("align", 0))
	var used := Vector2(mini(dims.x, maxi(kids.size(), 1)) * cell.x + maxi(mini(dims.x, kids.size()) - 1, 0) * gap.x, dims.y * cell.y + maxi(dims.y - 1, 0) * gap.y)
	var origin := Vector2(float(pad[0]), float(pad[2])) + Vector2(maxf(inner.x - used.x, 0.0) * (align % 3) * 0.5, maxf(inner.y - used.y, 0.0) * (align / 3) * 0.5)
	for i in range(kids.size()):
		var col: int = i % dims.x if along_x else i / dims.y
		var row: int = i / dims.x if along_x else i % dims.y
		if corner % 2 == 1:
			col = dims.x - 1 - col
		if corner >= 2:
			row = dims.y - 1 - row
		var c: Control = kids[i]
		_place(c, 0, origin.x + col * (cell.x + gap.x), cell.x, true)
		_place(c, 1, origin.y + row * (cell.y + gap.y), cell.y, true)
