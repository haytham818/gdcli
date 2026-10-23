@tool
extends EditorPlugin

# gdcli editor bridge: NDJSON over a loopback TCP socket, executed on the editor
# main thread. See docs/protocol.md. A malformed request must never take the
# editor down, because that takes the user's unsaved work with it.

const PROTOCOL := 1
const MAX_LINE := 1 << 20
const OPEN_TIMEOUT_FRAMES := 120
const GAME_TIMEOUT_MS := 3000

const NO_GAME_HINT := "install the runtime with `gdcli runtime install`, then play the game"

## Single source of truth for the version: plugin.cfg next to this script. Cargo.toml carries
## the same string and `src/assets.rs` fails the build when they drift.
var _version := "unknown"

const ENDPOINT_DIR := "res://.godot/gdcli"
const ENDPOINT_PATH := "res://.godot/gdcli/endpoint.json"
const SCREENSHOT_DIR := "res://.godot/gdcli/screenshots"
const PALETTE_META := "gdcli_palette_keys"

const Meta = preload("commands/meta.gd")
const EditorCommands = preload("commands/editor.gd")
const SceneCommands = preload("commands/scene.gd")
const NodeCommands = preload("commands/node.gd")
const PropCommands = preload("commands/prop.gd")
const SignalCommands = preload("commands/signal.gd")
const GroupCommands = preload("commands/group.gd")
const ResCommands = preload("commands/res.gd")
const ProjectCommands = preload("commands/project.gd")
const InputCommands = preload("commands/input.gd")
const FsCommands = preload("commands/fs.gd")
const ScriptCommands = preload("commands/script.gd")
const GameCommands = preload("commands/game.gd")
const DebugCapture = preload("debug_capture.gd")

# Command palette. EditorCommandPalette is write-only, so this list is the
# only source of truth for `editor.palette.list`; the callables are exactly what
# the palette holds, so `palette.run` takes the same path as a human click.
var _palette_entries: Array = []
# Palette screenshots reuse editor.gd's deferred capture but belong to no client,
# so they are advanced here once per frame instead of in a connection's slot.
var _palette_captures: Array = []

var _registry: Dictionary = {}
var _server: TCPServer = null
var _port: int = 0
var _token: String = ""
var debug_capture: EditorDebuggerPlugin = null
# Each client: {"peer": StreamPeerTCP, "buf": PackedByteArray, "authed": bool, "pending": Dictionary}
var _clients: Array = []
# Runtime bridge correlation: one request at a time per client, keyed by id.
var _game_seq: int = 0
var _game_awaiting: Dictionary = {}
var _game_replies: Dictionary = {}


func _read_plugin_version() -> String:
	var script := get_script() as Script
	if script == null:
		return "unknown"
	var cfg := ConfigFile.new()
	if cfg.load(script.resource_path.get_base_dir().path_join("plugin.cfg")) != OK:
		return "unknown"
	return str(cfg.get_value("plugin", "version", "unknown"))


func _enter_tree() -> void:
	_version = _read_plugin_version()
	_registry = {}
	for module in [Meta, EditorCommands, SceneCommands, NodeCommands, PropCommands,
			SignalCommands, GroupCommands, ResCommands, ProjectCommands, InputCommands,
			FsCommands, ScriptCommands, GameCommands]:
		module.register(_registry)
	debug_capture = DebugCapture.new() as EditorDebuggerPlugin
	add_debugger_plugin(debug_capture)
	debug_capture.set("bridge", self)
	_token = Crypto.new().generate_random_bytes(32).hex_encode()
	_start_server()
	_write_endpoint()
	set_process(true)
	_build_palette_entries()
	register_palette()


func _exit_tree() -> void:
	set_process(false)
	_palette_captures.clear()
	unregister_palette()
	if debug_capture != null:
		remove_debugger_plugin(debug_capture)
		debug_capture = null
	for client in _clients:
		var peer: StreamPeerTCP = client["peer"]
		if peer != null:
			peer.disconnect_from_host()
	_clients.clear()
	_game_awaiting.clear()
	_game_replies.clear()
	if _server != null:
		_server.stop()
		_server = null
	if FileAccess.file_exists(ENDPOINT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ENDPOINT_PATH))


func _process(_delta: float) -> void:
	_advance_palette_captures()
	if _server == null:
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			break
		peer.set_no_delay(true)
		_clients.append({
			"peer": peer,
			"buf": PackedByteArray(),
			"authed": false,
			"pending": {},
		})
	for i in range(_clients.size() - 1, -1, -1):
		if not _pump_client(_clients[i]):
			_abandon_game_pending(_clients[i])
			_clients.remove_at(i)


func capabilities() -> Array:
	var names := _registry.keys()
	names.sort()
	return names


func ping_data() -> Dictionary:
	return {
		"protocol": PROTOCOL,
		"plugin_version": _version,
		"godot": String(Engine.get_version_info()["string"]),
		"project": ProjectSettings.globalize_path("res://"),
		"capabilities": capabilities(),
	}


# --- server lifecycle --------------------------------------------------------

func _start_server() -> void:
	var base := randi_range(40000, 49960)
	for attempt in range(20):
		var port := base + attempt
		if port > 50000:
			port = 40000 + (port - 50000) - 1
		var server := TCPServer.new()
		if server.listen(port, "127.0.0.1") == OK:
			_server = server
			_port = port
			return
		server.stop()
	push_warning("gdcli: no free loopback port in 40000..50000; bridge disabled")
	_server = null
	_port = 0


func _write_endpoint() -> void:
	if _port == 0:
		return
	var absolute_dir := ProjectSettings.globalize_path(ENDPOINT_DIR)
	var error := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_warning("gdcli: cannot create '%s': %s" % [absolute_dir, error_string(error)])
		return
	var file := FileAccess.open(ENDPOINT_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("gdcli: cannot write '%s': %s"
			% [ENDPOINT_PATH, error_string(FileAccess.get_open_error())])
		return
	file.store_string(JSON.stringify({
		"protocol": PROTOCOL,
		"plugin_version": _version,
		"port": _port,
		"token": _token,
		"pid": OS.get_process_id(),
		"project": ProjectSettings.globalize_path("res://"),
		"godot": String(Engine.get_version_info()["string"]),
	}, "  "))
	file.close()


# --- command palette ----------------------------------------------------
#
# EditorCommandPalette only takes `add_command`/`remove_command`; there is no way
# to read it back. The registry below is therefore the source of truth for
# `editor.palette.list`, and the callables it holds are the ones a click runs.


func _build_palette_entries() -> void:
	_palette_entries = [
		{
			"name": "gdcli: Screenshot 2D view",
			"key": "gdcli_screenshot_2d",
			"callable": _palette_screenshot_2d,
		},
		{
			"name": "gdcli: Screenshot whole editor",
			"key": "gdcli_screenshot_whole",
			"callable": _palette_screenshot_whole,
		},
		{
			"name": "gdcli: Show bridge status",
			"key": "gdcli_bridge_status",
			"callable": _palette_bridge_status,
		},
	]


# Returns the palette, or null on an engine/build without one. Startup must not
# break on an older editor, so every palette call goes through this.
func _command_palette() -> Variant:
	if not EditorInterface.has_method("get_command_palette"):
		return null
	var palette: Variant = EditorInterface.get_command_palette()
	if palette == null or not palette.has_method("add_command"):
		return null
	return palette


# Public so a reload probe can call it twice. A key this plugin already owns is
# removed before it is added again, so a plugin reload cannot duplicate an entry.
# remove_command() logs an engine error for a key the palette does not hold, and
# the palette has no getter, so the owned keys are remembered on the palette
# object itself: it outlives a plugin (and a script) reload, whereas a static
# variable does not.
func register_palette() -> void:
	var palette: Variant = _command_palette()
	if palette == null:
		return
	var keys: Array = palette.get_meta(PALETTE_META, [])
	var can_remove: bool = palette.has_method("remove_command")
	for entry in _palette_entries:
		var key := String(entry["key"])
		if can_remove and keys.has(key):
			palette.remove_command(key)
		palette.add_command(String(entry["name"]), key, entry["callable"], "gdcli")
		if not keys.has(key):
			keys.append(key)
	palette.set_meta(PALETTE_META, keys)


func unregister_palette() -> void:
	var palette: Variant = _command_palette()
	if palette == null:
		return
	var keys: Array = palette.get_meta(PALETTE_META, [])
	if palette.has_method("remove_command"):
		for key in keys:
			palette.remove_command(String(key))
	palette.remove_meta(PALETTE_META)


# Registration order; `editor.palette.list` reports exactly these names.
func palette_names() -> Array:
	var names: Array = []
	for entry in _palette_entries:
		names.append(String(entry["name"]))
	return names


# Calls the Callable the palette holds, so the effect is the one a human click
# has. Screenshot entries return as soon as the capture is scheduled.
# Returns false when no entry carries that name.
func palette_run(name: String) -> bool:
	for entry in _palette_entries:
		if String(entry["name"]) == name:
			var action: Callable = entry["callable"]
			action.call()
			return true
	return false


func palette_has(name: String) -> bool:
	for entry in _palette_entries:
		if String(entry["name"]) == name:
			return true
	return false


func _palette_screenshot_2d() -> void:
	_start_palette_screenshot("2d", "shot2d")


func _palette_screenshot_whole() -> void:
	_start_palette_screenshot("whole", "shotwhole")


func _start_palette_screenshot(view: String, stem: String) -> void:
	var target := _screenshot_target(stem)
	if bool(target.get("headless", false)):
		# No texture under a dummy renderer: say what to do about it instead of
		# writing an empty file (PROTOCOL section 10).
		_toast(EditorCommands.HEADLESS_HINT)
		return
	var needed := 1
	if view != "whole":
		# The 2D sub-viewport keeps a 2x2 placeholder until two frames rendered.
		EditorInterface.set_main_screen_editor("2D")
		needed = EditorCommands.SCREENSHOT_FRAMES
	_palette_captures.append({
		"kind": "screenshot",
		"needed": needed,
		"frames": 0,
		"view": view,
		"absolute": target["absolute"],
		"reported": target["absolute"],
	})


# `res://.godot/gdcli/screenshots/<stem>-<unix_ms>.png`; the directory is created
# by editor.gd's poll_screenshot when the file is written.
func _screenshot_target(stem: String) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return {"headless": true}
	var stamp := int(Time.get_unix_time_from_system() * 1000.0)
	var absolute := ProjectSettings.globalize_path(SCREENSHOT_DIR).path_join(
		"%s-%d.png" % [stem, stamp])
	return {"headless": false, "absolute": absolute}


func _advance_palette_captures() -> void:
	if _palette_captures.is_empty():
		return
	var waiting: Array = []
	for pending in _palette_captures:
		pending["frames"] = int(pending["frames"]) + 1
		var reply: Dictionary = EditorCommands.poll_screenshot(pending)
		if reply.is_empty():
			waiting.append(pending)
			continue
		_report_palette_capture(pending, reply)
	_palette_captures = waiting


func _report_palette_capture(pending: Dictionary, reply: Dictionary) -> void:
	if bool(reply.get("ok", false)):
		_toast(String(pending["absolute"]))
		return
	var error: Variant = reply.get("error", {})
	var message := "screenshot failed"
	var hint := ""
	if typeof(error) == TYPE_DICTIONARY:
		message = String(error.get("message", message))
		hint = String(error.get("hint", ""))
	if hint != "":
		message = "%s - %s" % [message, hint]
	_toast(message)


func _palette_bridge_status() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var scene := "(no scene)"
	if root != null:
		var path := ProjectSettings.localize_path(root.scene_file_path)
		scene = path if path != "" else String(root.name)
	var port: String = str(_port) if _port > 0 else "bridge off"
	var state := "playing" if EditorInterface.is_playing_scene() else "stopped"
	_toast("%s \u00b7 %s \u00b7 %s \u00b7 %s" % [port, _version, scene, state])


func _toast(message: String) -> void:
	var toaster: Variant = EditorInterface.get_editor_toaster()
	if toaster == null:
		return
	toaster.push_toast(message, EditorToaster.SEVERITY_INFO, "")


# --- socket loop -------------------------------------------------------------

# Returns false when the client has to be dropped.
func _pump_client(client: Dictionary) -> bool:
	var peer: StreamPeerTCP = client["peer"]
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false

	if not client["pending"].is_empty() and _advance_pending(client):
		return true
	if not client["pending"].is_empty():
		# One in-flight request per connection: keep the rest buffered for later.
		return true

	var available := peer.get_available_bytes()
	if available > 0:
		var chunk := peer.get_partial_data(available)
		if chunk[0] != OK:
			return false
		var buf: PackedByteArray = client["buf"]
		buf.append_array(chunk[1])
		client["buf"] = buf

	var buf: PackedByteArray = client["buf"]
	# Bytes, not text: a UTF-8 sequence may be split across reads, so only decode
	# complete newline-terminated lines.
	if buf.size() > MAX_LINE and buf.find(10) == -1:
		_send(client, _error_reply(null, false, "BAD_ARGS", "request line exceeds 1 MiB"))
		return false

	while true:
		var newline := buf.find(10)
		if newline == -1:
			break
		if newline > MAX_LINE:
			_send(client, _error_reply(null, false, "BAD_ARGS", "request line exceeds 1 MiB"))
			return false
		var line := buf.slice(0, newline).get_string_from_utf8()
		buf = buf.slice(newline + 1)
		client["buf"] = buf
		if line.strip_edges() == "":
			continue
		if not _handle_line(client, line):
			return false
		if not client["pending"].is_empty():
			break
	client["buf"] = buf
	return true


func _handle_line(client: Dictionary, line: String) -> bool:
	var json := JSON.new()
	if json.parse(line) != OK:
		_send(client, _error_reply(null, false, "BAD_ARGS",
			"invalid JSON: %s" % json.get_error_message()))
		return bool(client["authed"])
	var payload: Variant = json.data
	if typeof(payload) != TYPE_DICTIONARY:
		_send(client, _error_reply(null, false, "BAD_ARGS", "request must be a JSON object"))
		return bool(client["authed"])

	if not bool(client["authed"]):
		var token: Variant = payload.get("token", null)
		if typeof(token) != TYPE_STRING or String(token) != _token:
			# Wrong token: close without a reply.
			var peer: StreamPeerTCP = client["peer"]
			peer.disconnect_from_host()
			return false
		client["authed"] = true
		_send(client, {"ok": true, "data": ping_data()})
		return true

	var has_id: bool = payload.has("id")
	var id: Variant = payload.get("id", null)
	var cmd: Variant = payload.get("cmd", null)
	if typeof(cmd) != TYPE_STRING or String(cmd) == "":
		_send(client, _error_reply(id, has_id, "BAD_ARGS", "missing `cmd`"))
		return true

	var args: Variant = payload.get("args", {})
	if args == null:
		args = {}
	if typeof(args) != TYPE_DICTIONARY:
		_send(client, _error_reply(id, has_id, "BAD_ARGS", "`args` must be an object"))
		return true

	var opts: Variant = payload.get("opts", {})
	if opts == null:
		opts = {}
	if typeof(opts) != TYPE_DICTIONARY:
		_send(client, _error_reply(id, has_id, "BAD_ARGS", "`opts` must be an object"))
		return true

	var reply := _dispatch(client, String(cmd), args, opts, id, has_id)
	if not reply.is_empty():
		_send(client, reply)
	return true


func _dispatch(client: Dictionary, cmd: String, args: Dictionary, opts: Dictionary,
		id: Variant, has_id: bool) -> Dictionary:
	if not _registry.has(cmd):
		return _error_reply(id, has_id, "UNKNOWN_CMD", "unknown command '%s'" % cmd,
			"run `gdcli raw meta.capabilities`")
	if not opts.has("undo"):
		opts["undo"] = true
	if not opts.has("dry_run"):
		opts["dry_run"] = false
	opts["plugin"] = self

	var result: Variant = _registry[cmd].call(args, opts)
	if typeof(result) != TYPE_DICTIONARY:
		return _error_reply(id, has_id, "INTERNAL",
			"command '%s' returned an invalid result" % cmd)

	if result.has("__pending"):
		var pending: Dictionary = result["__pending"]
		pending["id"] = id
		pending["has_id"] = has_id
		pending["frames"] = 0
		client["pending"] = pending
		return {}

	return _reply(id, has_id, result)


# Some engine calls return void and only take effect a frame later (scene.open,
# screenshots after a main-screen switch, play). Commands hand back a
# {"__pending": {...}} marker; the plugin polls it once per frame and answers
# the client when it resolves, so the editor main thread never blocks.
func _advance_pending(client: Dictionary) -> bool:
	var pending: Dictionary = client["pending"]
	pending["frames"] = int(pending["frames"]) + 1
	var reply := {}
	match String(pending.get("kind", "scene_open")):
		"screenshot":
			reply = EditorCommands.poll_screenshot(pending)
		"play":
			reply = EditorCommands.poll_play(pending)
		"game":
			reply = _poll_game(pending)
		_:
			reply = _poll_scene_open(pending)
	if reply.is_empty():
		return false
	_send(client, _reply(pending["id"], pending["has_id"], reply))
	client["pending"] = {}
	return true


# open_scene_from_path() returns void, so scene.open defers its reply until the
# edited root actually points at the requested scene.
func _poll_scene_open(pending: Dictionary) -> Dictionary:
	var want := String(pending["path"])
	var root := EditorInterface.get_edited_scene_root()
	if root != null and ProjectSettings.localize_path(root.scene_file_path) == want:
		return Meta.ok({"path": want})
	if int(pending["frames"]) >= OPEN_TIMEOUT_FRAMES:
		return Meta.err("GODOT_ERROR", "timed out waiting for '%s' to open" % want,
			"check that the scene loads without errors")
	return {}


# --- runtime bridge -----------------------------------------------------

# Sends `gdcli:req` over the live debugger session and hands the request to the
# deferred mechanism: the reply arrives asynchronously through `_capture`.
# game.gd calls this; a dead/missing runtime answers NO_GAME after 3 s.
#
# `fallback` is a command's answer for a runtime that never replies (used by
# `game.status`, whose local data is already complete except for `capturing`).
# `timeout_ms` shortens the wait when a missing runtime is the expected case.
func game_request(cmd: String, args: Dictionary, fallback: Dictionary = {},
		timeout_ms: int = GAME_TIMEOUT_MS) -> Dictionary:
	var session := _game_session()
	if session == null:
		return Meta.err("NO_GAME", "no running game", NO_GAME_HINT)
	_game_seq += 1
	var key := str(_game_seq)
	_game_awaiting[key] = true
	session.send_message("gdcli:req", [_game_seq, cmd, args])
	# `id` belongs to the client request and is overwritten by _dispatch, so the
	# correlation key travels under its own name.
	var pending := {
		"kind": "game",
		"game_id": key,
		"cmd": cmd,
		"deadline": Time.get_ticks_msec() + timeout_ms,
	}
	if not fallback.is_empty():
		pending["fallback"] = fallback
	return {"__pending": pending}


func _game_session() -> EditorDebuggerSession:
	if debug_capture == null:
		return null
	for candidate in debug_capture.get_sessions():
		if candidate != null and candidate.is_active():
			return candidate
	return null


# Called by debug_capture.gd for every `gdcli:` message from the game.
func on_game_message(message: String, data: Array, _session_id: int) -> void:
	if message != "gdcli:res" or data.size() < 3:
		return
	var key := str(data[0])
	if not _game_awaiting.has(key):
		# Late reply for a timed-out request: drop it.
		return
	_game_awaiting.erase(key)
	_game_replies[key] = {"ok": bool(data[1]), "payload": data[2]}


# Called by _advance_pending(); {} keeps waiting, anything else is the reply.
func _poll_game(pending: Dictionary) -> Dictionary:
	var key := String(pending["game_id"])
	if _game_replies.has(key):
		var reply: Dictionary = _game_replies[key]
		_game_replies.erase(key)
		var payload: Variant = reply["payload"]
		if bool(reply["ok"]):
			if typeof(payload) != TYPE_DICTIONARY:
				return Meta.err("INTERNAL", "the game sent a malformed reply")
			if pending.has("fallback"):
				# `game.status`: the runtime only contributes `capturing`.
				var merged: Dictionary = pending["fallback"]
				merged["capturing"] = bool(payload.get("capturing", false))
				return Meta.ok(merged)
			return Meta.ok(payload)
		if typeof(payload) == TYPE_DICTIONARY and payload.has("code") and payload.has("message"):
			var error := {
				"code": String(payload["code"]),
				"message": String(payload["message"]),
			}
			if payload.has("hint") and String(payload["hint"]) != "":
				error["hint"] = String(payload["hint"])
			return {"ok": false, "error": error}
		return Meta.err("INTERNAL", "the game sent a malformed error")
	if Time.get_ticks_msec() >= int(pending["deadline"]):
		_game_awaiting.erase(key)
		if pending.has("fallback"):
			return Meta.ok(pending["fallback"])
		return Meta.err("NO_GAME", "no reply from the running game", NO_GAME_HINT)
	return {}


# The client went away before its reply did; forget the correlation id so a
# late answer is not stored forever.
func _abandon_game_pending(client: Dictionary) -> void:
	var pending: Variant = client.get("pending", {})
	if typeof(pending) != TYPE_DICTIONARY or pending.is_empty():
		return
	if String(pending.get("kind", "")) == "game":
		var key := String(pending["game_id"])
		_game_awaiting.erase(key)
		_game_replies.erase(key)


# --- wire helpers ------------------------------------------------------------

func _send(client: Dictionary, reply: Dictionary) -> void:
	var peer: StreamPeerTCP = client["peer"]
	var line := JSON.stringify(reply, "", false, true) + "\n"
	if peer.put_data(line.to_utf8_buffer()) != OK:
		peer.disconnect_from_host()


func _reply(id: Variant, has_id: bool, result: Dictionary) -> Dictionary:
	if has_id:
		result["id"] = id
	return result


func _error_reply(id: Variant, has_id: bool, code: String, message: String,
		hint: String = "") -> Dictionary:
	return _reply(id, has_id, Meta.err(code, message, hint))
