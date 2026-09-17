## `System.Text.StringBuilder` for converted scripts.
extends RefCounted

var _s: String = ""

func _init(initial: String = "") -> void:
	_s = initial

func append(v) -> RefCounted:
	_s += str(v)
	return self

func insert(i: int, v) -> RefCounted:
	_s = _s.insert(clampi(i, 0, _s.length()), str(v))
	return self

func remove(i: int, n: int) -> RefCounted:
	_s = _s.erase(i, n)
	return self

func replace(a: String, b: String) -> RefCounted:
	_s = _s.replace(a, b)
	return self

func replace_range(a: String, b: String, start: int, count: int) -> RefCounted:
	var head: String = _s.substr(0, start)
	var mid: String = _s.substr(start, count).replace(a, b)
	var tail: String = _s.substr(start + count)
	_s = head + mid + tail
	return self

func clear() -> RefCounted:
	_s = ""
	return self

func length() -> int:
	return _s.length()

func set_length(n: int) -> void:
	if n < _s.length():
		_s = _s.substr(0, n)
	else:
		_s = _s.rpad(n, " ")

func char_at(i: int) -> String:
	return _s[i] if i >= 0 and i < _s.length() else ""

## `sb[i] = c`
func set_char(i: int, c) -> void:
	if i >= 0 and i < _s.length():
		_s = _s.substr(0, i) + str(c).substr(0, 1) + _s.substr(i + 1)

func to_string() -> String:
	return _s

func _to_string() -> String:
	return _s
