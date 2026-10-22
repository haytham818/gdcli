extends RefCounted

const M = preload("meta.gd")

const AUTOLOAD_PREFIX := "autoload/"


static func register(reg: Dictionary) -> void:
	reg["project.setting.get"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _setting_get(args)
	reg["project.setting.set"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _setting_set(args)
	reg["project.autoload.list"] = func(_args: Dictionary, _opts: Dictionary) -> Dictionary:
		return M.ok({"autoloads": _autoloads()})
	reg["project.autoload.add"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _autoload_add(args, opts)
	reg["project.autoload.remove"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _autoload_remove(args, opts)


static func _s(args: Dictionary, key: String, fallback: String = "") -> String:
	var value = args.get(key, fallback)
	if value == null:
		return fallback
	return str(value)


# --- settings ----------------------------------------------------------------

static func _setting_get(args: Dictionary) -> Dictionary:
	var key := _s(args, "key").strip_edges()
	if key == "":
		return M.err("BAD_ARGS", "missing `key`")
	var exists := ProjectSettings.has_setting(key)
	var value: Variant = ProjectSettings.get_setting(key) if exists else null
	return M.ok({
		"key": key,
		"value_text": var_to_str(value),
		"type": type_string(typeof(value)),
		"exists": exists,
	})


static func _setting_set(args: Dictionary) -> Dictionary:
	var key := _s(args, "key").strip_edges()
	if key == "":
		return M.err("BAD_ARGS", "missing `key`")
	if not args.has("value"):
		return M.err("BAD_ARGS", "missing `value`")
	var mode := _s(args, "as", "gd")
	if mode == "":
		mode = "gd"
	var parsed := _parse_setting(key, _s(args, "value"), mode)
	if parsed.has("error"):
		return parsed["error"]

	ProjectSettings.set_setting(key, parsed["value"])
	var error := ProjectSettings.save()
	if error != OK:
		return M.err("GODOT_ERROR", "could not save project settings: %s"
			% error_string(error))
	return M.ok({"key": key, "value_text": var_to_str(ProjectSettings.get_setting(key))})


# Reuses the section 6 parser when the setting already has a value, because its
# type is then known. An unknown key has no type to coerce against, so the mode
# alone decides the value's type.
static func _parse_setting(key: String, raw: String, mode: String) -> Dictionary:
	var known := ProjectSettings.has_setting(key)
	var current: Variant = ProjectSettings.get_setting(key) if known else null
	if known and current != null:
		var prop := {"name": key, "type": typeof(current), "hint_string": ""}
		var parsed := M.parse_value(null, prop, raw, mode)
		if not parsed.has("error"):
			return parsed
		# `gd` is the default mode, and a plain sentence is not a GDScript
		# literal: for a String setting accept the text as typed.
		if mode == "gd" and typeof(current) == TYPE_STRING:
			return {"value": raw}
		return parsed
	return _parse_any(raw, mode)


static func _parse_any(raw: String, mode: String) -> Dictionary:
	match mode:
		"gd":
			var value: Variant = str_to_var(raw)
			if value == null and raw.strip_edges() != "null":
				return {"error": M.err("BAD_ARGS",
					"cannot parse '%s' as a GDScript literal" % raw,
					"values use var_to_str syntax, e.g. \"text\" or Vector2(10, 20)")}
			return {"value": value}
		"json":
			var json := JSON.new()
			if json.parse(raw) != OK:
				return {"error": M.err("BAD_ARGS", "invalid JSON: %s" % json.get_error_message())}
			return {"value": json.data}
		"ref":
			if not (raw.begins_with("res://") or raw.begins_with("user://")):
				return {"error": M.err("BAD_ARGS", "`ref` expects a res:// or user:// path")}
			if not ResourceLoader.exists(raw):
				return {"error": M.err("NOT_FOUND", "resource '%s' not found" % raw)}
			return {"value": load(raw)}
		"expr":
			var expression := Expression.new()
			if expression.parse(raw) != OK:
				return {"error": M.err("BAD_ARGS",
					"cannot parse expression: %s" % expression.get_error_text())}
			var value: Variant = expression.execute([], null)
			if expression.has_execute_failed():
				return {"error": M.err("BAD_ARGS",
					"expression failed: %s" % expression.get_error_text())}
			return {"value": value}
		_:
			return {"error": M.err("BAD_ARGS", "unknown `as` mode '%s'" % mode,
				"expected gd, json, ref or expr")}


# --- autoloads ---------------------------------------------------------------

# 4.7 stores autoloads by UID; show the res:// path the user can act on, and
# fall back to the raw UID when it can no longer be resolved.
static func _autoload_path(raw: String) -> String:
	var path := raw
	if path.begins_with("uid://"):
		var id := ResourceUID.text_to_id(path)
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			var resolved := ResourceUID.get_id_path(id)
			if resolved != "":
				path = resolved
	return M.localize(path)


# 4.7 keeps one setting per autoload (`autoload/<Name>`) whose value carries a
# leading `*` when the singleton is enabled. Older layouts expose a single
# `autoload` dictionary whose keys carry that prefix instead; support both.
static func _autoloads() -> Array:
	var out: Array = []
	if ProjectSettings.has_setting("autoload"):
		var table: Variant = ProjectSettings.get_setting("autoload")
		if table is Dictionary:
			for key in table.keys():
				var name := String(key)
				var enabled := name.begins_with("*")
				if enabled:
					name = name.substr(1)
				var path := String(table[key])
				if path.begins_with("*"):
					path = path.substr(1)
					enabled = true
				out.append({"name": name, "path": _autoload_path(path), "enabled": enabled})
			out.sort_custom(func(a, b): return a["name"] < b["name"])
			return out

	for prop in ProjectSettings.get_property_list():
		var setting := String(prop["name"])
		if not setting.begins_with(AUTOLOAD_PREFIX):
			continue
		var name := setting.substr(AUTOLOAD_PREFIX.length())
		if name == "" or name.contains("/"):
			continue
		var raw := String(ProjectSettings.get_setting(setting))
		var enabled := raw.begins_with("*")
		var path := raw.substr(1) if enabled else raw
		out.append({"name": name, "path": _autoload_path(path), "enabled": enabled})
	out.sort_custom(func(a, b): return a["name"] < b["name"])
	return out


static func _find_autoload(name: String) -> Dictionary:
	for entry in _autoloads():
		if entry["name"] == name:
			return entry
	return {}


static func _autoload_add(args: Dictionary, opts: Dictionary) -> Dictionary:
	var name := _s(args, "name").strip_edges()
	if name == "":
		return M.err("BAD_ARGS", "missing `name`")
	if not name.is_valid_identifier():
		return M.err("BAD_ARGS", "'%s' is not a valid autoload name" % name)
	var path := _s(args, "path").strip_edges()
	if path == "":
		return M.err("BAD_ARGS", "missing `path`")
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return M.err("BAD_ARGS", "`path` must be a res:// or user:// script path")
	if not ResourceLoader.exists(path):
		return M.err("NOT_FOUND", "script '%s' not found" % path)
	var script: Resource = load(path)
	if not (script is Script):
		return M.err("BAD_ARGS", "'%s' is not a script" % path)
	if not _find_autoload(name).is_empty():
		return M.err("BAD_ARGS", "autoload '%s' already exists" % name)

	var plugin: EditorPlugin = opts["plugin"]
	if not plugin.has_method("add_autoload_singleton"):
		return M.err("NO_API", "this engine has no add_autoload_singleton()")
	plugin.add_autoload_singleton(name, path)
	ProjectSettings.save()
	if _find_autoload(name).is_empty():
		return M.err("GODOT_ERROR", "add_autoload_singleton('%s') did not register it" % name)
	return M.ok({"name": name, "path": M.localize(path)})


static func _autoload_remove(args: Dictionary, opts: Dictionary) -> Dictionary:
	var name := _s(args, "name").strip_edges()
	if name == "":
		return M.err("BAD_ARGS", "missing `name`")
	var entry := _find_autoload(name)
	if entry.is_empty():
		return M.err("NOT_FOUND", "autoload '%s' not found" % name,
			"run `gdcli project autoload list`")

	var plugin: EditorPlugin = opts["plugin"]
	if not plugin.has_method("remove_autoload_singleton"):
		return M.err("NO_API", "this engine has no remove_autoload_singleton()")
	plugin.remove_autoload_singleton(name)
	ProjectSettings.save()
	if not _find_autoload(name).is_empty():
		return M.err("GODOT_ERROR", "remove_autoload_singleton('%s') did not remove it" % name)
	return M.ok({})
