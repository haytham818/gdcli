@tool
extends EditorDebuggerPlugin

# Collects what a running game prints so `game.logs` can report it, and routes
# the runtime bridge's replies to the editor plugin. The editor forwards debugger
# traffic here; only bridge replies and the runtime's log batches are consumed.

const MAX_ENTRIES := 500

# PROTOCOL section 14: the runtime forwards the game's own log stream here, so
# `game.logs` has content for locally launched games.
const KINDS := ["output", "error", "warning"]

# Measured on 4.7.2: `_has_capture` is asked with the part before the first
# colon ("gdcli" for a "gdcli:res" message), while `_capture` receives the full
# message. Registering "gdcli" is therefore enough and stays narrow.
const CAPTURES := ["output", "error", "stack_dump", "gdcli"]

var _entries: Array = []
# Set by plugin.gd; receives the game's `gdcli:res` replies for correlation.
var bridge: Object = null


func _has_capture(prefix: String) -> bool:
	return CAPTURES.has(prefix)


func _capture(message: String, data: Array, session_id: int) -> bool:
	if message == "gdcli:log":
		# [[{kind,text}, ...]]: one batch per game frame.
		for batch in data:
			if batch is Array:
				_append_batch(batch, session_id)
		return true
	if message.begins_with("gdcli:"):
		if bridge != null:
			bridge.on_game_message(message, data, session_id)
		return true
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


func logs(limit: int, kind: String = "") -> Array:
	if limit <= 0 or _entries.is_empty():
		return []
	var source := _entries
	if kind != "":
		source = []
		for entry in _entries:
			if String(entry["kind"]) == kind:
				source.append(entry)
	var start := maxi(0, source.size() - limit)
	return source.slice(start)


func clear() -> void:
	_entries.clear()


func count() -> int:
	return _entries.size()


func _append_batch(batch: Array, session: int) -> void:
	for entry in batch:
		if not (entry is Dictionary):
			continue
		var kind: Variant = entry.get("kind", "output")
		if typeof(kind) != TYPE_STRING or not KINDS.has(kind):
			continue
		_append(String(kind), _line(str(entry.get("text", ""))), session)


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
