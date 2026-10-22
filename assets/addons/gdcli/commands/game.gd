extends RefCounted

# game.* reads what the EditorDebuggerPlugin captured from running games.
# Read-only: sending commands into the game needs a runtime autoload (M4).

const M = preload("meta.gd")

const DEFAULT_LIMIT := 200


static func register(reg: Dictionary) -> void:
	reg["game.status"] = func(_args: Dictionary, opts: Dictionary) -> Dictionary:
		return _status(opts)
	reg["game.logs"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _logs(args, opts)
	reg["game.clear"] = func(_args: Dictionary, opts: Dictionary) -> Dictionary:
		return _clear(opts)


static func _capture(opts: Dictionary) -> RefCounted:
	return opts["plugin"].debug_capture


static func _status(opts: Dictionary) -> Dictionary:
	var capture := _capture(opts)
	var sessions: Array = []
	var active := false
	if capture != null:
		sessions = capture.get_sessions()
		for session in sessions:
			if session != null and session.is_active():
				active = true
				break
	return M.ok({
		"sessions": sessions.size(),
		# A game launched from the editor is "active" even before the debugger
		# session finishes handshaking.
		"active": active or EditorInterface.is_playing_scene(),
	})


static func _logs(args: Dictionary, opts: Dictionary) -> Dictionary:
	var raw: Variant = args.get("limit", DEFAULT_LIMIT)
	if raw == null:
		raw = DEFAULT_LIMIT
	if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
		return M.err("BAD_ARGS", "`limit` must be an integer")
	var limit := maxi(0, int(raw))
	var clear := bool(args.get("clear", false))

	var capture := _capture(opts)
	var lines: Array = []
	if capture != null:
		lines = capture.logs(limit)
		if clear:
			capture.clear()
	return M.ok({"lines": lines})


static func _clear(opts: Dictionary) -> Dictionary:
	var capture := _capture(opts)
	if capture != null:
		capture.clear()
	return M.ok({})
