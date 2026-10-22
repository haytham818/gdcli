extends RefCounted

const M = preload("meta.gd")


static func register(reg: Dictionary) -> void:
	reg["fs.status"] = func(_args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _status()
	reg["fs.scan"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _scan(args)
	reg["fs.reimport"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _reimport(args)


static func _filesystem() -> Dictionary:
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return {"error": M.err("NO_API", "no resource filesystem is available")}
	return {"fs": fs}


static func _status() -> Dictionary:
	var lookup := _filesystem()
	if lookup.has("error"):
		return lookup["error"]
	var fs: EditorFileSystem = lookup["fs"]
	return M.ok({
		"scanning": fs.is_scanning(),
		"progress": fs.get_scanning_progress(),
		"importing": fs.is_importing(),
	})


# Scanning is asynchronous: report that it started and never wait for it.
static func _scan(args: Dictionary) -> Dictionary:
	var lookup := _filesystem()
	if lookup.has("error"):
		return lookup["error"]
	var fs: EditorFileSystem = lookup["fs"]
	var method := "scan_sources" if bool(args.get("sources", false)) else "scan"
	if not fs.has_method(method):
		return M.err("NO_API", "EditorFileSystem has no %s()" % method)
	fs.call(method)
	return M.ok({"started": true})


# reimport_files() has returned void since 4.4; check the bound signature instead
# of guessing, so `queued` stays honest on engines where it returns Error.
static func _return_type(cls: String, method: String) -> int:
	if not ClassDB.class_has_method(cls, method):
		return -1
	for info in ClassDB.class_get_method_list(cls):
		if String(info["name"]) == method:
			return int(info["return"]["type"])
	return -1


static func _reimport(args: Dictionary) -> Dictionary:
	var raw = args.get("paths", null)
	if raw == null or typeof(raw) != TYPE_ARRAY or Array(raw).is_empty():
		return M.err("BAD_ARGS", "`paths` must be a non-empty array of resource paths")
	var paths := PackedStringArray()
	for item in Array(raw):
		if typeof(item) != TYPE_STRING:
			return M.err("BAD_ARGS", "`paths` must contain only strings")
		var path := String(item).strip_edges()
		if not (path.begins_with("res://") or path.begins_with("user://")):
			return M.err("BAD_ARGS", "'%s' must be a res:// or user:// path" % path)
		paths.append(path)

	var lookup := _filesystem()
	if lookup.has("error"):
		return lookup["error"]
	var fs: EditorFileSystem = lookup["fs"]
	var kind := _return_type("EditorFileSystem", "reimport_files")
	if kind == TYPE_INT:
		var error := int(fs.call("reimport_files", paths))
		if error != OK:
			return M.err("GODOT_ERROR", "reimport_files() failed: %s" % error_string(error))
	else:
		fs.call("reimport_files", paths)
	return M.ok({"queued": paths.size()})
