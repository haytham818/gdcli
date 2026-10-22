@tool
extends EditorDebuggerPlugin

# Collects what a running game prints so `game.logs` can report it. The editor
# forwards debugger traffic here; this plugin never sends anything back.

const MAX_ENTRIES := 500

var _entries: Array = []


# Only these prefixes are wanted; the editor keeps handling them itself.
func _has_capture(prefix: String) -> bool:
	return prefix == "output" or prefix == "error" or prefix == "stack_dump"


func _capture(message: String, data: Array, session_id: int) -> bool:
	match message:
		"output":
			for item in data:
				if item is Array or item is PackedStringArray:
					_append("output", _join(item), session_id)
				else:
					_append("output", _line(item), session_id)
		"error", "stack_dump":
			_append("error", _join(data), session_id)
	return false


func logs(limit: int) -> Array:
	if limit <= 0 or _entries.is_empty():
		return []
	var start := maxi(0, _entries.size() - limit)
	return _entries.slice(start)


func clear() -> void:
	_entries.clear()


func count() -> int:
	return _entries.size()


func _append(kind: String, text: String, session: int) -> void:
	_entries.append({"kind": kind, "text": text, "session": session})
	if _entries.size() > MAX_ENTRIES:
		_entries = _entries.slice(_entries.size() - MAX_ENTRIES)


# Debugger "output" payloads are arrays of strings, but a single print may also
# arrive as one nested array of lines, so flatten both shapes.
func _join(values: Array) -> String:
	var parts := PackedStringArray()
	for value in values:
		parts.append(_line(value))
	return "\n".join(parts)


func _line(value: Variant) -> String:
	if value is Array or value is PackedStringArray:
		return _join(Array(value))
	var text := String(value)
	if text.ends_with("\n"):
		text = text.substr(0, text.length() - 1)
	if text.ends_with("\r"):
		text = text.substr(0, text.length() - 1)
	return text
