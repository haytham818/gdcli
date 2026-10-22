extends RefCounted

const M = preload("meta.gd")


static func register(reg: Dictionary) -> void:
	reg["scene.open"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _open(args, opts)
	reg["scene.save"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _save(args, opts)
	reg["scene.save_as"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _save_as(args, opts)
	reg["scene.reload"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _reload(args, opts)
	reg["scene.roots"] = func(_args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _roots()
	reg["scene.tree"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _tree(args, opts)


static func _scene_path_of(root: Node) -> String:
	return M.localize(root.scene_file_path)


static func _check_scene(path: String) -> Dictionary:
	if not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
		return M.err("NOT_FOUND", "scene '%s' does not exist" % path)
	var extension := path.get_extension().to_lower()
	if extension != "tscn" and extension != "scn" and extension != "res":
		return M.err("NOT_FOUND", "'%s' is not a PackedScene" % path)
	var packed = ResourceLoader.load(path, "PackedScene")
	if not (packed is PackedScene):
		return M.err("NOT_FOUND", "'%s' is not a PackedScene" % path)
	return {}


static func _open(args: Dictionary, opts: Dictionary) -> Dictionary:
	var path := str(args.get("path", "")).strip_edges()
	if path == "":
		return M.err("BAD_ARGS", "missing `path`")
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return M.err("BAD_ARGS", "`path` must be a res:// or user:// scene path")
	var check := _check_scene(path)
	if check.has("error"):
		return check

	var edited := M.edited_root()
	if edited != null and _scene_path_of(edited) == path:
		return M.ok({"path": path})

	if bool(opts.get("dry_run", false)):
		var data := {"path": path}
		data["planned"] = [{"op": "open_scene", "path": path}]
		return M.ok(data)

	# open_scene_from_path() returns void: the plugin polls for up to 120 frames
	# before answering, see plugin.gd::_advance_pending().
	EditorInterface.open_scene_from_path(path)
	return {"__pending": {"kind": "scene_open", "path": path}}


static func _save(_args: Dictionary, opts: Dictionary) -> Dictionary:
	var root := M.edited_root()
	if root == null:
		return M.err("NO_SCENE", "no scene is being edited")
	var path := _scene_path_of(root)
	if path == "":
		return M.err("BAD_ARGS", "the edited scene has no file path",
			"use `gdcli scene save-as <path>`")
	if bool(opts.get("dry_run", false)):
		var data := {"path": path}
		data["planned"] = [{"op": "save_scene", "path": path}]
		return M.ok(data)
	var error := EditorInterface.save_scene()
	if error != OK:
		return M.err("GODOT_ERROR", "save_scene() failed: %s" % error_string(error))
	return M.ok({"path": path})


static func _save_as(args: Dictionary, opts: Dictionary) -> Dictionary:
	var path := str(args.get("path", "")).strip_edges()
	if path == "":
		return M.err("BAD_ARGS", "missing `path`")
	if not path.begins_with("res://"):
		return M.err("BAD_ARGS", "`path` must be a res:// path")
	if path.get_extension().to_lower() != "tscn":
		return M.err("BAD_ARGS", "scene paths must end in .tscn")

	var root := M.edited_root()
	if root == null:
		return M.err("NO_SCENE", "no scene is being edited")

	if bool(opts.get("dry_run", false)):
		var data := {"path": path}
		data["planned"] = [{"op": "save_scene_as", "path": path}]
		return M.ok(data)

	var absolute := ProjectSettings.globalize_path(path)
	var directory := absolute.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		var error := DirAccess.make_dir_recursive_absolute(directory)
		if error != OK:
			return M.err("GODOT_ERROR", "cannot create '%s': %s" % [directory, error_string(error)])

	# `open` has no counterpart in the 4.7 API: save_scene_as() always makes the
	# saved scene current, so the argument is accepted but not forwarded.
	EditorInterface.save_scene_as(path, true)
	var new_root := M.edited_root()
	if new_root == null or _scene_path_of(new_root) != path:
		return M.err("GODOT_ERROR", "save_scene_as('%s') did not change the edited scene" % path)
	return M.ok({"path": path})


static func _reload(args: Dictionary, opts: Dictionary) -> Dictionary:
	var path := str(args.get("path", "")).strip_edges()
	if path == "":
		var root := M.edited_root()
		if root == null:
			return M.err("NO_SCENE", "no scene is being edited")
		path = _scene_path_of(root)
		if path == "":
			return M.err("BAD_ARGS", "the edited scene has no file path")
	var check := _check_scene(path)
	if check.has("error"):
		return check
	if bool(opts.get("dry_run", false)):
		var data := {}
		data["planned"] = [{"op": "reload_scene", "path": path}]
		return M.ok(data)
	EditorInterface.reload_scene_from_path(path)
	return M.ok({})


static func _roots() -> Dictionary:
	var unsaved := Array(EditorInterface.get_unsaved_scenes())
	var scenes: Array = []
	for root in EditorInterface.get_open_scene_roots():
		var path := _scene_path_of(root)
		scenes.append({
			"path": path,
			"unsaved": path == "" or unsaved.has(root.scene_file_path) or unsaved.has(path),
		})
	return M.ok({"scenes": scenes})


static func _tree(args: Dictionary, opts: Dictionary) -> Dictionary:
	var target := str(args.get("path", "")).strip_edges()
	var depth: int = maxi(0, int(args.get("depth", 0)))
	var with_props := bool(args.get("props", false))

	var root: Node = null
	var scene_root: Node = null
	if target == "" or target == ".":
		root = M.edited_root()
		if root == null:
			return M.err("NO_SCENE", "no scene is being edited")
		scene_root = root
	elif target.begins_with("res://") and not target.contains("::"):
		root = M.root_for_scene(target)
		if root == null:
			return M.err("NOT_FOUND", "scene '%s' is not open" % target,
				"open it first with `gdcli scene open`")
		scene_root = root
	else:
		var resolved := M.resolve_target(target, false)
		if resolved.has("error"):
			return resolved["error"]
		root = resolved["obj"]
		scene_root = resolved["root"]

	if bool(opts.get("dry_run", false)):
		return M.ok({"scene": _scene_path_of(scene_root), "nodes": []})

	var nodes: Array = []
	_walk(root, root, 0, depth, with_props, scene_root, nodes)
	return M.ok({"scene": _scene_path_of(scene_root), "nodes": nodes})


static func _walk(root: Node, node: Node, level: int, depth: int, with_props: bool,
		scene_root: Node, out: Array) -> void:
	out.append(M.node_info(root, node, with_props, scene_root))
	if depth > 0 and level >= depth - 1:
		return
	for child in node.get_children():
		_walk(root, child, level + 1, depth, with_props, scene_root, out)
