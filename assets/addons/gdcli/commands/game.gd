extends RefCounted

# game.* reads what the EditorDebuggerPlugin captured from running games, and
# Forwards commands to the `GdcliRuntime` autoload inside the game over the
# live debugger session.

const M = preload("meta.gd")

const DEFAULT_LIMIT := 200
const KINDS := ["output", "error", "warning"]

# A live runtime answers `game.ping` within a frame; this only bounds the wait
# for a project that has no runtime autoload (where `capturing` is false).
const STATUS_TIMEOUT_MS := 1000


static func register(reg: Dictionary) -> void:
	reg["game.status"] = func(_args: Dictionary, opts: Dictionary) -> Dictionary:
		return _status(opts)
	reg["game.logs"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _logs(args, opts)
	reg["game.clear"] = func(_args: Dictionary, opts: Dictionary) -> Dictionary:
		return _clear(opts)
	reg["game.ping"] = func(_args: Dictionary, opts: Dictionary) -> Dictionary:
		return _remote("game.ping", {}, opts)
	reg["game.tree"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _remote("game.tree", args, opts)
	reg["game.get"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _remote("game.get", args, opts)
	reg["game.set"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		# `game.set` mutates the running game, so a CLI dry run has to be
		# validated in the game too; the flag rides along inside the args.
		if bool(opts.get("dry_run", false)):
			args = args.duplicate()
			args["dry_run"] = true
		return _remote("game.set", args, opts)
	reg["game.eval"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _remote("game.eval", args, opts)
	# The runtime captures and writes the PNG inside the game; only the resulting
	# path and dimensions come back, never image bytes (PROTOCOL section 12).
	# Screenshots write a file, so `dry_run` rides along (section 4): the runtime
	# validates the path and answers `planned` without capturing or writing.
	reg["game.screenshot"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		if bool(opts.get("dry_run", false)):
			args = args.duplicate()
			args["dry_run"] = true
		return _remote("game.screenshot", args, opts)


# The reply arrives later; plugin.gd owns the correlation id, the 3 s timeout
# and the NO_GAME error, so the editor main thread never blocks.
static func _remote(cmd: String, args: Dictionary, opts: Dictionary) -> Dictionary:
	return opts["plugin"].game_request(cmd, args)


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
	var data := {
		"sessions": sessions.size(),
		# A game launched from the editor is "active" even before the debugger
		# session finishes handshaking.
		"active": active or EditorInterface.is_playing_scene(),
		"capturing": false,
	}
	if not active:
		return M.ok(data)
	# Only the runtime knows whether its logger is installed (PROTOCOL section
	# 14), so ask it in the same `game.ping` every other game command uses. The
	# reply arrives deferred; `data` is what to answer if the runtime never does
	# (a project without the autoload), so `status` never fails for that reason.
	return opts["plugin"].game_request("game.ping", {}, data, STATUS_TIMEOUT_MS)


static func _logs(args: Dictionary, opts: Dictionary) -> Dictionary:
	var raw: Variant = args.get("limit", DEFAULT_LIMIT)
	if raw == null:
		raw = DEFAULT_LIMIT
	if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
		return M.err("BAD_ARGS", "`limit` must be an integer")
	var limit := maxi(0, int(raw))
	var clear := bool(args.get("clear", false))
	var kind := ""
	var raw_kind: Variant = args.get("kind", null)
	if raw_kind != null:
		if typeof(raw_kind) != TYPE_STRING or not KINDS.has(String(raw_kind)):
			return M.err("BAD_ARGS", "`kind` must be output, error or warning",
				"omit it to read every kind")
		kind = String(raw_kind)

	var capture := _capture(opts)
	var lines: Array = []
	if capture != null:
		lines = capture.logs(limit, kind)
		if clear:
			capture.clear()
	return M.ok({"lines": lines})


static func _clear(opts: Dictionary) -> Dictionary:
	var capture := _capture(opts)
	if capture != null:
		capture.clear()
	return M.ok({})
