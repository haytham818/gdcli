extends RefCounted

const M = preload("meta.gd")


static func register(reg: Dictionary) -> void:
	reg["res.new"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _new(args)
	reg["res.info"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _info(args)
	reg["res.duplicate"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _duplicate(args)


static func _s(args: Dictionary, key: String, fallback: String = "") -> String:
	var value = args.get(key, fallback)
	if value == null:
		return fallback
	return str(value)


static func _resource_path(raw: String) -> Dictionary:
	if raw == "":
		return {"error": M.err("BAD_ARGS", "missing resource path")}
	if not (raw.begins_with("res://") or raw.begins_with("user://")):
		return {"error": M.err("BAD_ARGS", "'%s' must be a res:// or user:// path" % raw)}
	return {"value": raw}


# ResourceSaver only writes into an existing directory.
static func _ensure_dir(path: String) -> Dictionary:
	var directory := ProjectSettings.globalize_path(path).get_base_dir()
	if DirAccess.dir_exists_absolute(directory):
		return {}
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		return {"error": M.err("GODOT_ERROR", "cannot create '%s': %s"
			% [directory, error_string(error)])}
	return {}


static func _save(resource: Resource, path: String) -> Dictionary:
	var dir := _ensure_dir(path)
	if dir.has("error"):
		return dir
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		return {"error": M.err("GODOT_ERROR", "could not save '%s': %s"
			% [path, error_string(error)])}
	return {}


static func _new(args: Dictionary) -> Dictionary:
	var type := _s(args, "type")
	if type == "":
		return M.err("BAD_ARGS", "missing `type`")
	if not ClassDB.class_exists(type):
		return M.err("NOT_FOUND", "class '%s' does not exist" % type)
	if not ClassDB.can_instantiate(type):
		return M.err("BAD_ARGS", "class '%s' cannot be instantiated" % type)
	var parsed := _resource_path(_s(args, "path"))
	if parsed.has("error"):
		return parsed["error"]
	var path := String(parsed["value"])

	var resource: Object = ClassDB.instantiate(type)
	if resource == null:
		return M.err("GODOT_ERROR", "could not instantiate '%s'" % type)
	if not (resource is Resource):
		if resource is Node:
			resource.free()
		return M.err("BAD_ARGS", "'%s' is not a Resource" % type)
	var result := _save(resource, path)
	if result.has("error"):
		return result["error"]
	return M.ok({"path": path, "type": resource.get_class()})


static func _info(args: Dictionary) -> Dictionary:
	var parsed := _resource_path(_s(args, "path"))
	if parsed.has("error"):
		return parsed["error"]
	var path := String(parsed["value"])
	if not ResourceLoader.exists(path):
		return M.err("NOT_FOUND", "resource '%s' not found" % path)
	var resource: Resource = load(path)
	if resource == null:
		return M.err("GODOT_ERROR", "could not load resource '%s'" % path)
	return M.ok({
		"path": path,
		"type": resource.get_class(),
		"resource_name": String(resource.resource_name),
	})


static func _duplicate(args: Dictionary) -> Dictionary:
	var parsed_from := _resource_path(_s(args, "from"))
	if parsed_from.has("error"):
		return parsed_from["error"]
	var from := String(parsed_from["value"])
	var parsed_to := _resource_path(_s(args, "to"))
	if parsed_to.has("error"):
		return parsed_to["error"]
	var to := String(parsed_to["value"])
	if not ResourceLoader.exists(from):
		return M.err("NOT_FOUND", "resource '%s' not found" % from)
	var source: Resource = load(from)
	if source == null:
		return M.err("GODOT_ERROR", "could not load resource '%s'" % from)
	var copy := source.duplicate()
	if copy == null:
		return M.err("GODOT_ERROR", "could not duplicate '%s'" % from)
	var result := _save(copy, to)
	if result.has("error"):
		return result["error"]
	return M.ok({"path": to})
