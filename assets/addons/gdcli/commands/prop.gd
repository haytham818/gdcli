extends RefCounted

const M = preload("meta.gd")


static func register(reg: Dictionary) -> void:
	reg["prop.list"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _list(args, opts)
	reg["prop.get"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _get_value(args, opts)
	reg["prop.set"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _set_value(args, opts)
	reg["prop.reset"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _reset(args, opts)


static func _s(args: Dictionary, key: String, fallback: String = "") -> String:
	var value = args.get(key, fallback)
	if value == null:
		return fallback
	return str(value)


static func _target(args: Dictionary) -> Dictionary:
	if not args.has("target"):
		return {"error": M.err("BAD_ARGS", "missing `target`")}
	var resolved := M.resolve_target(_s(args, "target"), true)
	if resolved.has("error"):
		return resolved
	return resolved


static func _list(args: Dictionary, _opts: Dictionary) -> Dictionary:
	var lookup := _target(args)
	if lookup.has("error"):
		return lookup["error"]
	var obj: Object = lookup["obj"]
	var filter := _s(args, "filter").to_lower()
	var changed := bool(args.get("changed", false))

	var props: Array = []
	for prop in M.property_infos(obj):
		var name := String(prop["name"])
		if filter != "" and not name.to_lower().contains(filter):
			continue
		var value: Variant = obj.get(name)
		var is_default := M.is_default(obj, prop, value)
		if changed and is_default:
			continue
		props.append({
			"name": name,
			"type": M.type_name(prop),
			"value_text": M.value_text(value),
			"is_default": is_default,
		})
	return M.ok({"target": lookup["addr"], "props": props})


static func _get_value(args: Dictionary, _opts: Dictionary) -> Dictionary:
	var lookup := _target(args)
	if lookup.has("error"):
		return lookup["error"]
	var name := _s(args, "name")
	if name == "":
		return M.err("BAD_ARGS", "missing `name`")
	var obj: Object = lookup["obj"]
	var prop := M.find_property(obj, name)
	if prop.is_empty():
		return M.err("NOT_FOUND", "property '%s' not found on '%s'" % [name, lookup["addr"]],
			"run `gdcli prop list %s`" % lookup["addr"])
	var value: Variant = obj.get(name)
	return M.ok({
		"name": name,
		"type": M.type_name(prop),
		"value": M.json_safe(value),
		"value_text": M.value_text(value),
		"is_default": M.is_default(obj, prop, value),
	})


static func _set_value(args: Dictionary, opts: Dictionary) -> Dictionary:
	var lookup := _target(args)
	if lookup.has("error"):
		return lookup["error"]
	var name := _s(args, "name")
	if name == "":
		return M.err("BAD_ARGS", "missing `name`")
	if not args.has("value"):
		return M.err("BAD_ARGS", "missing `value`")
	if lookup["read_only"]:
		return M.err("NO_API", "only the edited scene can be modified")

	var obj: Object = lookup["obj"]
	if obj is Node and not M.is_writable(lookup["root"], obj):
		return M.instance_error(lookup["root"], obj)
	var prop := M.find_property(obj, name)
	if prop.is_empty():
		return M.err("NOT_FOUND", "property '%s' not found on '%s'" % [name, lookup["addr"]],
			"run `gdcli prop list %s`" % lookup["addr"])
	if int(prop["usage"]) & PROPERTY_USAGE_READ_ONLY:
		return M.err("BAD_ARGS", "property '%s' is read-only" % name)

	var mode := _s(args, "as", "gd")
	if mode == "":
		mode = "gd"
	var parsed := M.parse_value(obj, prop, _s(args, "value"), mode)
	if parsed.has("error"):
		return parsed["error"]
	var value: Variant = parsed["value"]
	var old_value: Variant = obj.get(name)
	var value_type := M.type_name(prop)

	if bool(opts.get("dry_run", false)):
		var data := {"name": name, "type": value_type, "value_text": M.value_text(value)}
		data["planned"] = [{
			"op": "set_property",
			"target": lookup["addr"],
			"name": name,
			"value_text": M.value_text(value),
		}]
		return M.ok(data)

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: prop.set", UndoRedo.MERGE_DISABLE, lookup["root"])
		undo.add_do_property(obj, name, value)
		undo.add_undo_property(obj, name, old_value)
		undo.commit_action()
	else:
		obj.set(name, value)

	return M.ok({
		"name": name,
		"type": value_type,
		"value_text": M.value_text(obj.get(name)),
	})


static func _reset(args: Dictionary, opts: Dictionary) -> Dictionary:
	var lookup := _target(args)
	if lookup.has("error"):
		return lookup["error"]
	var name := _s(args, "name")
	if name == "":
		return M.err("BAD_ARGS", "missing `name`")
	if lookup["read_only"]:
		return M.err("NO_API", "only the edited scene can be modified")

	var obj: Object = lookup["obj"]
	if obj is Node and not M.is_writable(lookup["root"], obj):
		return M.instance_error(lookup["root"], obj)
	var prop := M.find_property(obj, name)
	if prop.is_empty():
		return M.err("NOT_FOUND", "property '%s' not found on '%s'" % [name, lookup["addr"]],
			"run `gdcli prop list %s`" % lookup["addr"])
	if int(prop["usage"]) & PROPERTY_USAGE_READ_ONLY:
		return M.err("BAD_ARGS", "property '%s' is read-only" % name)

	var default: Variant = M.default_value(obj, prop)
	var old_value: Variant = obj.get(name)

	if bool(opts.get("dry_run", false)):
		var data := {}
		data["planned"] = [{
			"op": "reset_property",
			"target": lookup["addr"],
			"name": name,
			"value_text": M.value_text(default),
		}]
		return M.ok(data)

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: prop.reset", UndoRedo.MERGE_DISABLE, lookup["root"])
		undo.add_do_property(obj, name, default)
		undo.add_undo_property(obj, name, old_value)
		undo.commit_action()
	else:
		obj.set(name, default)

	return M.ok({})
