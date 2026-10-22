extends RefCounted

const M = preload("meta.gd")

# Scripts this bridge asked the editor to open. A GUI editor also reports them
# through ScriptEditor, but a --headless editor has no script workspace and
# get_open_scripts() stays empty, so remember the request here. Union, deduped.
static var _opened: Array = []


static func register(reg: Dictionary) -> void:
	reg["script.check"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _check(args)
	reg["script.open"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _open(args)
	reg["script.files"] = func(_args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _files()
	reg["script.save_all"] = func(_args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _save_all()


static func _s(args: Dictionary, key: String, fallback: String = "") -> String:
	var value = args.get(key, fallback)
	if value == null:
		return fallback
	return str(value)


static func _script_paths(args: Dictionary) -> Dictionary:
	var raw = args.get("paths", null)
	if raw == null or typeof(raw) != TYPE_ARRAY or Array(raw).is_empty():
		return {"error": M.err("BAD_ARGS", "`paths` must be a non-empty array of script paths")}
	var paths: Array = []
	for item in Array(raw):
		if typeof(item) != TYPE_STRING:
			return {"error": M.err("BAD_ARGS", "`paths` must contain only strings")}
		var path := String(item).strip_edges()
		if not (path.begins_with("res://") or path.begins_with("user://")):
			return {"error": M.err("BAD_ARGS", "'%s' must be a res:// or user:// path" % path)}
		paths.append(path)
	return {"value": paths}


# Load-based check: does the script parse? CACHE_MODE_IGNORE keeps the editor's
# own compiled copy (and any open script editor state) untouched.
static func _check(args: Dictionary) -> Dictionary:
	var parsed := _script_paths(args)
	if parsed.has("error"):
		return parsed["error"]
	var results: Array = []
	for path in Array(parsed["value"]):
		if not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
			results.append({"path": path, "ok": false, "error": "failed to load (parse error)"})
			continue
		var was_cached := ResourceLoader.has_cached(path)
		var resource: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		# 4.7 hands back a parsed-but-invalid GDScript instead of null for a
		# syntax error, so recompile the throw-away copy to learn the verdict.
		if resource == null:
			results.append({"path": path, "ok": false, "error": "failed to load (parse error)"})
			continue
		if not (resource is Script):
			return M.err("BAD_ARGS", "'%s' is not a script" % path)
		var verdict := {"path": path, "ok": true}
		if resource.reload() != OK:
			verdict = {"path": path, "ok": false, "error": "failed to load (parse error)"}
		# GDScript ignores CACHE_MODE_IGNORE for its own first load: drop the
		# entry this check just created, so the editor re-reads the file later.
		# A script that was cached before the check is the editor's instance and
		# is left untouched.
		if not was_cached:
			resource.set_path("")
		results.append(verdict)
	return M.ok({"results": results})


static func _open(args: Dictionary) -> Dictionary:
	var path := _s(args, "path").strip_edges()
	if path == "":
		return M.err("BAD_ARGS", "missing `path`")
	if not ResourceLoader.exists(path):
		return M.err("NOT_FOUND", "script '%s' not found" % path)
	var script: Resource = load(path)
	if script == null:
		return M.err("GODOT_ERROR", "could not load script '%s'" % path)
	if not (script is Script):
		return M.err("BAD_ARGS", "'%s' is not a script" % path)
	if not _opened.has(path):
		_opened.append(path)

	var raw_line = args.get("line", 0)
	if raw_line == null:
		raw_line = 0
	if typeof(raw_line) != TYPE_INT and typeof(raw_line) != TYPE_FLOAT:
		return M.err("BAD_ARGS", "`line` must be an integer")
	var line := maxi(0, int(raw_line))

	# edit_script() grew `column` and `grab_focus` over time; pass exactly the
	# arguments this engine's signature declares.
	var count := _arg_count("EditorInterface", "edit_script")
	match count:
		0, 1:
			EditorInterface.edit_script(script)
		2:
			EditorInterface.edit_script(script, line)
		3:
			EditorInterface.edit_script(script, line, 0)
		_:
			EditorInterface.edit_script(script, line, 0, true)
	return M.ok({})


static func _arg_count(cls: String, method: String) -> int:
	if not ClassDB.class_has_method(cls, method):
		return -1
	for info in ClassDB.class_get_method_list(cls):
		if String(info["name"]) == method:
			return Array(info["args"]).size()
	return -1


static func _script_editor() -> Dictionary:
	var editor := EditorInterface.get_script_editor()
	if editor == null:
		return {"error": M.err("NO_API", "the script editor is not available")}
	return {"editor": editor}


static func _files() -> Dictionary:
	var open: Array = []
	var unsaved: Array = []
	var lookup := _script_editor()
	if not lookup.has("error"):
		var editor: ScriptEditor = lookup["editor"]
		for script in editor.get_open_scripts():
			if script == null:
				continue
			var path := String(script.resource_path)
			if path != "" and not open.has(path):
				open.append(path)
		for path in editor.get_unsaved_files():
			unsaved.append(M.localize(String(path)))
	# A --headless editor has no script workspace (get_open_scripts() stays
	# empty), so union in what this bridge itself opened.
	for path in _opened:
		if not open.has(path):
			open.append(path)
	open.sort()
	return M.ok({"open": open, "unsaved": unsaved})


static func _save_all() -> Dictionary:
	var lookup := _script_editor()
	if lookup.has("error"):
		return lookup["error"]
	var editor: ScriptEditor = lookup["editor"]
	var saved := Array(editor.get_unsaved_files()).size()
	editor.save_all_scripts()
	return M.ok({"saved": saved})
