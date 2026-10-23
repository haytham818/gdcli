extends RefCounted

const M = preload("meta.gd")

const MAX_STEPS := 100
const DEFAULT_HISTORY_LIMIT := 20
# Switching the main screen is not enough: the sub-viewport keeps its 2x2
# placeholder until two frames have rendered (verified on 4.7.2).
const SCREENSHOT_FRAMES := 2
const PLAY_TIMEOUT_FRAMES := 30

# Verified on 4.7.2: the tab is called "Asset Store" (not "AssetLib"), and the
# 2D screen's node class is CanvasItemEditor.
const MAIN_SCREENS := {"2d": "2D", "3d": "3D", "script": "Script", "assetlib": "Asset Store"}
const SCREENSHOT_VIEWS := ["2d", "3d", "whole"]

const HEADLESS_HINT := "start the editor with a display, or under xvfb: xvfb-run -a godot --editor --path <project>"


static func register(reg: Dictionary) -> void:
	reg["editor.status"] = func(_args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _status()
	reg["editor.undo"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _step("undo", args, opts)
	reg["editor.redo"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _step("redo", args, opts)
	reg["editor.history"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _history(args, opts)
	reg["editor.select"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _select(args, opts)
	reg["editor.inspect"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _inspect(args, opts)
	reg["editor.main_screen"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _main_screen(args, opts)
	reg["editor.toast"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _toast(args, opts)
	reg["editor.screenshot"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _screenshot(args, opts)
	reg["editor.play"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _play(args, opts)
	reg["editor.stop"] = func(_args: Dictionary, opts: Dictionary) -> Dictionary:
		return _stop(opts)
	reg["editor.palette.list"] = func(_args: Dictionary, opts: Dictionary) -> Dictionary:
		return M.ok({"entries": opts["plugin"].palette_names()})
	reg["editor.palette.run"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _palette_run(args, opts)


static func _status() -> Dictionary:
	var root := M.edited_root()
	var open_scenes: Array = []
	for path in EditorInterface.get_open_scenes():
		open_scenes.append(String(path))
	var unsaved: Array = []
	for path in EditorInterface.get_unsaved_scenes():
		unsaved.append(String(path))
	return M.ok({
		"project": ProjectSettings.globalize_path("res://"),
		"godot": String(Engine.get_version_info()["string"]),
		"edited_scene": M.localize(root.scene_file_path) if root != null else "",
		"open_scenes": open_scenes,
		"unsaved": unsaved,
		"playing": EditorInterface.is_playing_scene(),
		"playing_scene": String(EditorInterface.get_playing_scene()),
		"main_screen": main_screen_name(),
		"selection": selection_addresses(),
		"inspected": inspected_address(),
	})


# --- undo history ------------------------------------------------------------

# Undo/redo act on the edited scene root's own history. EditorUndoRedoManager
# exposes no undo()/redo() binding; only the per-object UndoRedo does.
# Returns {"history": UndoRedo} or {"error": <envelope>}.
static func _edited_history() -> Dictionary:
	var root := M.edited_root()
	if root == null:
		return {"error": M.err("NO_SCENE", "no scene is being edited")}
	var manager := EditorInterface.get_editor_undo_redo()
	var history: UndoRedo = manager.get_history_undo_redo(manager.get_object_history_id(root))
	if history == null:
		return {"error": M.err("INTERNAL", "the edited scene has no undo history")}
	return {"history": history}


# Missing or null means `fallback`; a JSON number is truncated to int; anything
# else is a type error rather than a silent coercion.
static func _int_arg(args: Dictionary, key: String, fallback: int) -> Dictionary:
	if not args.has(key) or args[key] == null:
		return {"value": fallback}
	var raw: Variant = args[key]
	if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
		return {"error": M.err("BAD_ARGS", "`%s` must be an integer" % key)}
	return {"value": int(raw)}


static func _current_name(history: UndoRedo) -> Variant:
	if history.get_current_action() < 0:
		return null
	var name := history.get_current_action_name()
	return name if name != "" else null


static func _step(kind: String, args: Dictionary, opts: Dictionary) -> Dictionary:
	var lookup := _edited_history()
	if lookup.has("error"):
		return lookup["error"]
	var history: UndoRedo = lookup["history"]

	var parsed := _int_arg(args, "count", 1)
	if parsed.has("error"):
		return parsed["error"]
	var count := clampi(int(parsed["value"]), 1, MAX_STEPS)
	var is_undo := kind == "undo"

	# opts.undo is ignored: undoing is not itself an undoable action.
	if bool(opts.get("dry_run", false)):
		var names: Array = []
		var index := history.get_current_action()
		if not is_undo:
			index += 1
		for _i in range(count):
			if index < 0 or index >= history.get_history_count():
				break
			names.append(history.get_action_name(index))
			if is_undo:
				index -= 1
			else:
				index += 1
		return M.ok({"would_undo": names} if is_undo else {"would_redo": names})

	var done := 0
	for _i in range(count):
		if is_undo:
			if not history.has_undo():
				break
			history.undo()
		else:
			if not history.has_redo():
				break
			history.redo()
		done += 1
	if done > 0:
		# The raw UndoRedo bypasses EditorUndoRedoManager's bookkeeping, so the
		# scene is not flagged dirty by the editor itself.
		EditorInterface.mark_scene_as_unsaved()

	var data := {
		"action": _current_name(history),
		"can_undo": history.has_undo(),
		"can_redo": history.has_redo(),
		"history_count": history.get_history_count(),
	}
	data["undone" if is_undo else "redone"] = done
	return M.ok(data)


static func _history(args: Dictionary, _opts: Dictionary) -> Dictionary:
	var lookup := _edited_history()
	if lookup.has("error"):
		return lookup["error"]
	var history: UndoRedo = lookup["history"]

	var parsed := _int_arg(args, "limit", DEFAULT_HISTORY_LIMIT)
	if parsed.has("error"):
		return parsed["error"]
	var limit := maxi(0, int(parsed["value"]))
	var total := history.get_history_count()
	var current := history.get_current_action()

	# Oldest first (ascending action index), newest `limit` actions only.
	var actions: Array = []
	var index := maxi(0, total - limit)
	while index < total:
		actions.append({
			"index": index,
			"name": history.get_action_name(index),
			"current": index == current,
		})
		index += 1
	return M.ok({"count": total, "current": current, "actions": actions})


# --- main screen / selection / inspector -------------------------------------

# EditorInterface.get_editor_main_screen() is a container holding exactly one
# visible screen editor. Match the editor's class (names are version-specific);
# screen editors may sit directly in the container or inside a WindowWrapper.
static func main_screen_name() -> String:
	var container: Variant = EditorInterface.get_editor_main_screen()
	if container == null:
		return ""
	for child in container.get_children():
		if not (child is Node):
			continue
		var key := _screen_key(child)
		if key != "":
			return key
	return String((container as Node).name).to_lower()


static func _screen_key(node: Node) -> String:
	if not _shown(node):
		return ""
	match String(node.get_class()):
		"CanvasItemEditor":
			return "2d"
		"Node3DEditor":
			return "3d"
		"ScriptEditor":
			return "script"
		"EditorAssetLibrary", "AssetLib":
			return "assetlib"
		"GameView":
			return "game"
	for child in node.get_children():
		if child is Node:
			var key := _screen_key(child)
			if key != "":
				return key
	return ""


static func _shown(node: Node) -> bool:
	if node is CanvasItem:
		return (node as CanvasItem).is_visible_in_tree()
	var value: Variant = node.get("visible")
	return bool(value) if value != null else true


# Address of a node owned by any open scene; nodes of a non-edited scene carry
# the explicit `res://scene::path` form (PROTOCOL section 5).
static func address_of(node: Node) -> String:
	if node == null:
		return ""
	var edited := M.edited_root()
	if edited != null and (node == edited or edited.is_ancestor_of(node)):
		return M.rel_path(edited, node)
	for root in EditorInterface.get_open_scene_roots():
		if root == null:
			continue
		if node == root or root.is_ancestor_of(node):
			var rel := M.rel_path(root, node)
			var scene := M.localize(root.scene_file_path)
			return "%s::%s" % [scene, rel] if scene != "" else rel
	return ""


static func selection_addresses() -> Array:
	var out: Array = []
	var selection: Variant = EditorInterface.get_selection()
	if selection == null:
		return out
	for node in selection.get_selected_nodes():
		if not (node is Node):
			continue
		var addr := address_of(node)
		if addr != "":
			out.append(addr)
	return out


static func inspected_address() -> Variant:
	var inspector: Variant = EditorInterface.get_inspector()
	if inspector == null:
		return null
	var obj: Object = inspector.get_edited_object()
	if obj == null:
		return null
	if obj is Node:
		var addr := address_of(obj)
		return addr if addr != "" else null
	if obj is Resource:
		var path := String((obj as Resource).resource_path)
		return M.localize(path) if path != "" else null
	return String(obj.get_class())


static func _select(args: Dictionary, opts: Dictionary) -> Dictionary:
	var raw: Variant = args.get("paths", [])
	if typeof(raw) != TYPE_ARRAY:
		return M.err("BAD_ARGS", "`paths` must be an array of node paths")
	var add := bool(args.get("add", false))

	var nodes: Array = []
	var addrs: Array = []
	for item in Array(raw):
		if typeof(item) != TYPE_STRING:
			return M.err("BAD_ARGS", "`paths` must contain only strings")
		var resolved := M.resolve_target(String(item), false)
		if resolved.has("error"):
			return resolved["error"]
		var node: Node = resolved["obj"]
		nodes.append(node)
		addrs.append(address_of(node))

	if bool(opts.get("dry_run", false)):
		var planned: Array = selection_addresses() if add else []
		for addr in addrs:
			if not planned.has(addr):
				planned.append(addr)
		var data := {"selection": planned}
		data["planned"] = [{"op": "select", "paths": addrs, "add": add}]
		return M.ok(data)

	var selection: Variant = EditorInterface.get_selection()
	if not add:
		selection.clear()
	for node in nodes:
		selection.add_node(node)
	return M.ok({"selection": selection_addresses()})


static func _inspect(args: Dictionary, opts: Dictionary) -> Dictionary:
	var raw: Variant = args.get("target", null)
	if typeof(raw) != TYPE_STRING:
		return M.err("BAD_ARGS", "missing `target`")
	var resolved := M.resolve_target(String(raw), true)
	if resolved.has("error"):
		return resolved["error"]
	var addr := String(resolved["addr"])
	if bool(opts.get("dry_run", false)):
		var data := {"inspected": addr}
		data["planned"] = [{"op": "inspect", "target": addr}]
		return M.ok(data)
	EditorInterface.inspect_object(resolved["obj"], "", false)
	return M.ok({"inspected": addr})


static func _main_screen(args: Dictionary, opts: Dictionary) -> Dictionary:
	var raw: Variant = args.get("name", null)
	if typeof(raw) != TYPE_STRING:
		return M.err("BAD_ARGS", "missing `name`", "expected 2d, 3d, script or assetlib")
	var key := String(raw).strip_edges().to_lower()
	if not MAIN_SCREENS.has(key):
		return M.err("BAD_ARGS", "unknown main screen '%s'" % raw,
			"expected 2d, 3d, script or assetlib")
	if bool(opts.get("dry_run", false)):
		var data := {"main_screen": key}
		data["planned"] = [{"op": "set_main_screen", "name": key}]
		return M.ok(data)
	EditorInterface.set_main_screen_editor(String(MAIN_SCREENS[key]))
	var actual := main_screen_name()
	if actual != key:
		# Older editor builds do not expose every screen under a selectable name.
		return M.err("NO_API", "the editor did not switch to '%s'" % key,
			"this editor build has no such main screen (still on '%s')" % actual)
	return M.ok({"main_screen": actual})


static func _toast(args: Dictionary, opts: Dictionary) -> Dictionary:
	var raw: Variant = args.get("message", null)
	if typeof(raw) != TYPE_STRING:
		return M.err("BAD_ARGS", "missing `message`")
	var message := String(raw)
	if message.strip_edges() == "":
		return M.err("BAD_ARGS", "`message` must not be empty")
	if bool(opts.get("dry_run", false)):
		var data := {}
		data["planned"] = [{"op": "toast", "message": message}]
		return M.ok(data)
	var toaster: Variant = EditorInterface.get_editor_toaster()
	if toaster == null:
		return M.err("NO_API", "this editor has no toast notifier")
	toaster.push_toast(message, EditorToaster.SEVERITY_INFO, "")
	return M.ok({})


# --- screenshots -------------------------------------------------------------

# Relative paths resolve against the project root; `res://`/`user://` keep their
# protocol form in the reply, absolute and relative inputs answer absolutely.
# Returns {"absolute","reported"} or {"error": <envelope>}.
static func _output_path(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_STRING:
		return {"error": M.err("BAD_ARGS", "missing `path`")}
	var path := String(raw).strip_edges()
	if path == "":
		return {"error": M.err("BAD_ARGS", "missing `path`")}
	if path.begins_with("res://") or path.begins_with("user://"):
		return {"absolute": ProjectSettings.globalize_path(path), "reported": path}
	if path.is_absolute_path():
		var absolute := path.simplify_path()
		return {"absolute": absolute, "reported": absolute}
	var joined := ProjectSettings.globalize_path("res://").path_join(path).simplify_path()
	return {"absolute": joined, "reported": joined}


static func _screenshot(args: Dictionary, opts: Dictionary) -> Dictionary:
	var raw_view: Variant = args.get("viewport", "whole")
	if typeof(raw_view) != TYPE_STRING:
		return M.err("BAD_ARGS", "`viewport` must be a string")
	var view := String(raw_view).strip_edges().to_lower()
	if not SCREENSHOT_VIEWS.has(view):
		return M.err("BAD_ARGS", "unknown viewport '%s'" % raw_view,
			"expected 2d, 3d or whole")
	var target := _output_path(args.get("path", null))
	if target.has("error"):
		return target["error"]

	if DisplayServer.get_name() == "headless":
		return _no_renderer()

	if bool(opts.get("dry_run", false)):
		var data := {"path": target["reported"]}
		data["planned"] = [{"op": "screenshot", "viewport": view, "path": target["absolute"]}]
		return M.ok(data)

	# A sub-viewport is stale right after the switch: the plugin waits for
	# SCREENSHOT_FRAMES rendered frames before reading it (see plugin.gd).
	var needed := 1
	if view != "whole":
		EditorInterface.set_main_screen_editor("2D" if view == "2d" else "3D")
		needed = SCREENSHOT_FRAMES
	return {"__pending": {
		"kind": "screenshot",
		"needed": needed,
		"view": view,
		"absolute": target["absolute"],
		"reported": target["reported"],
	}}


static func _no_renderer() -> Dictionary:
	return M.err("NO_API", "the editor has no rendering surface to capture",
		HEADLESS_HINT)


# Called by plugin.gd on each later frame; {} means "keep waiting".
static func poll_screenshot(pending: Dictionary) -> Dictionary:
	if int(pending["frames"]) < int(pending["needed"]):
		return {}
	var view := String(pending["view"])
	var viewport: Variant = null
	match view:
		"2d":
			viewport = EditorInterface.get_editor_viewport_2d()
		"3d":
			viewport = EditorInterface.get_editor_viewport_3d(0)
		_:
			var base: Variant = EditorInterface.get_base_control()
			if base != null:
				viewport = base.get_viewport()
	if viewport == null:
		return _no_renderer()
	var texture: Texture2D = viewport.get_texture()
	if texture == null:
		return _no_renderer()
	# Under a dummy renderer the texture exists but get_image() returns null.
	var image: Image = texture.get_image()
	if image == null or image.is_empty():
		return _no_renderer()

	var absolute := String(pending["absolute"])
	var directory := absolute.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		var made := DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return M.err("GODOT_ERROR", "cannot create '%s': %s"
				% [directory, error_string(made)])
	var error: int = image.save_png(absolute)
	if error != OK:
		return M.err("GODOT_ERROR", "cannot save '%s': %s"
			% [absolute, error_string(error)])
	return M.ok({
		"path": String(pending["reported"]),
		"width": image.get_width(),
		"height": image.get_height(),
	})


# --- play / stop -------------------------------------------------------------

static func _play(args: Dictionary, opts: Dictionary) -> Dictionary:
	var raw_mode: Variant = args.get("mode", "main")
	if typeof(raw_mode) != TYPE_STRING:
		return M.err("BAD_ARGS", "`mode` must be a string")
	var mode := String(raw_mode).strip_edges().to_lower()
	var scene := ""

	match mode:
		"main":
			var main := String(ProjectSettings.get_setting("application/run/main_scene", ""))
			if main.strip_edges() == "":
				return M.err("BAD_ARGS", "no main scene is configured",
					"set `application/run/main_scene`, or use `--mode current` / `--mode scene`")
			if not ResourceLoader.exists(main):
				return M.err("BAD_ARGS", "the configured main scene '%s' does not exist" % main,
					"fix `application/run/main_scene` in the project settings")
		"current":
			if M.edited_root() == null:
				return M.err("NO_SCENE", "no scene is being edited")
		"scene":
			var raw_scene: Variant = args.get("scene", null)
			if typeof(raw_scene) != TYPE_STRING or String(raw_scene).strip_edges() == "":
				return M.err("BAD_ARGS", "`mode: scene` requires `scene`")
			scene = String(raw_scene).strip_edges()
			if not scene.begins_with("res://"):
				return M.err("BAD_ARGS", "`scene` must be a res:// scene path")
			if not ResourceLoader.exists(scene):
				return M.err("NOT_FOUND", "scene '%s' does not exist" % scene)
		_:
			return M.err("BAD_ARGS", "unknown mode '%s'" % raw_mode,
				"expected main, current or scene")

	if bool(opts.get("dry_run", false)):
		var data := {"playing": EditorInterface.is_playing_scene()}
		data["scene"] = EditorInterface.get_playing_scene()
		data["planned"] = [{"op": "play", "mode": mode, "scene": scene}]
		return M.ok(data)

	match mode:
		"main":
			EditorInterface.play_main_scene()
		"current":
			EditorInterface.play_current_scene()
		_:
			EditorInterface.play_custom_scene(scene)
	return {"__pending": {
		"kind": "play",
		"needed": 1,
		"timeout": PLAY_TIMEOUT_FRAMES,
		"mode": mode,
	}}


# Called by plugin.gd on each later frame; {} means "keep waiting".
static func poll_play(pending: Dictionary) -> Dictionary:
	if EditorInterface.is_playing_scene():
		var scene := String(EditorInterface.get_playing_scene())
		return M.ok({"playing": true, "scene": scene if scene != "" else null})
	if int(pending["frames"]) >= int(pending["timeout"]):
		return M.err("GODOT_ERROR", "the editor did not start playing",
			"check the game's output for startup errors")
	return {}


static func _stop(opts: Dictionary) -> Dictionary:
	if bool(opts.get("dry_run", false)):
		var data := {"playing": EditorInterface.is_playing_scene()}
		data["planned"] = [{"op": "stop"}]
		return M.ok(data)
	EditorInterface.stop_playing_scene()
	return M.ok({"playing": EditorInterface.is_playing_scene()})


# --- command palette ----------------------------------------------------

# The palette has no read API, so the plugin's own registry answers. Invoking the
# registered Callable is exactly what the palette does on a click; the screenshot
# entries return once the capture is scheduled (it finishes two frames later).
# `dry_run` still validates the name but does not run anything: the actions write
# a file, switch the main screen and toast, so a dry run must leave them alone.
static func _palette_run(args: Dictionary, opts: Dictionary) -> Dictionary:
	var raw: Variant = args.get("name", null)
	if typeof(raw) != TYPE_STRING:
		return M.err("BAD_ARGS", "missing `name`", "run `gdcli editor palette list`")
	var name := String(raw)
	if not bool(opts["plugin"].palette_has(name)):
		return M.err("NOT_FOUND", "no palette entry named '%s'" % name,
			"run `gdcli editor palette list`")
	if bool(opts.get("dry_run", false)):
		var data := {"name": name}
		data["planned"] = [{"op": "palette.run", "name": name}]
		return M.ok(data)
	opts["plugin"].palette_run(name)
	return M.ok({"name": name})
