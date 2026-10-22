extends RefCounted

const M = preload("meta.gd")


static func register(reg: Dictionary) -> void:
	reg["group.list"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _list(args)
	reg["group.add"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _add(args, opts)
	reg["group.remove"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _remove(args, opts)


static func _s(args: Dictionary, key: String, fallback: String = "") -> String:
	var value = args.get(key, fallback)
	if value == null:
		return fallback
	return str(value)


static func _target(args: Dictionary) -> Dictionary:
	if not args.has("target"):
		return {"error": M.err("BAD_ARGS", "missing `target`")}
	var lookup := M.resolve_target(_s(args, "target"), false)
	if lookup.has("error"):
		return lookup
	if lookup["read_only"]:
		return {"error": M.err("NO_API", "only the edited scene can be modified",
			"open it first with `gdcli scene open`")}
	return lookup


# Group names starting with `_` are engine-internal (the editor adds several).
static func _groups(node: Node, builtin: bool) -> Array:
	var out: Array = []
	for group in node.get_groups():
		var name := String(group)
		if not builtin and name.begins_with("_"):
			continue
		out.append(name)
	out.sort()
	return out


static func _list(args: Dictionary) -> Dictionary:
	if not args.has("target"):
		return M.err("BAD_ARGS", "missing `target`")
	var lookup := M.resolve_target(_s(args, "target"), false)
	if lookup.has("error"):
		return lookup["error"]
	var builtin := bool(args.get("builtin", false))
	return M.ok({
		"target": lookup["addr"],
		"groups": _groups(lookup["obj"], builtin),
	})


static func _group_name(args: Dictionary) -> Dictionary:
	var group := _s(args, "group").strip_edges()
	if group == "":
		return {"error": M.err("BAD_ARGS", "missing `group`")}
	return {"value": group}


static func _add(args: Dictionary, opts: Dictionary) -> Dictionary:
	var lookup := _target(args)
	if lookup.has("error"):
		return lookup["error"]
	var parsed := _group_name(args)
	if parsed.has("error"):
		return parsed["error"]
	var group := String(parsed["value"])
	var node: Node = lookup["obj"]
	var root: Node = lookup["root"]
	if not M.is_writable(root, node):
		return M.instance_error(root, node)

	var already := node.is_in_group(group)
	if not already and bool(opts.get("dry_run", false)):
		var data := {"target": lookup["addr"], "groups": _groups(node, false)}
		data["planned"] = [{"op": "add_to_group", "target": lookup["addr"], "group": group}]
		return M.ok(data)

	if not already:
		if bool(opts.get("undo", true)):
			var undo := EditorInterface.get_editor_undo_redo()
			undo.create_action("gdcli: group.add", UndoRedo.MERGE_DISABLE, root)
			undo.add_do_method(node, "add_to_group", group, true)
			undo.add_undo_method(node, "remove_from_group", group)
			undo.commit_action()
		else:
			node.add_to_group(group, true)

	return M.ok({"target": lookup["addr"], "groups": _groups(node, false)})


static func _remove(args: Dictionary, opts: Dictionary) -> Dictionary:
	var lookup := _target(args)
	if lookup.has("error"):
		return lookup["error"]
	var parsed := _group_name(args)
	if parsed.has("error"):
		return parsed["error"]
	var group := String(parsed["value"])
	var node: Node = lookup["obj"]
	var root: Node = lookup["root"]
	if not M.is_writable(root, node):
		return M.instance_error(root, node)
	if not node.is_in_group(group):
		return M.err("NOT_FOUND", "'%s' is not in group '%s'"
			% [lookup["addr"], group],
			"run `gdcli group list %s`" % lookup["addr"])

	if bool(opts.get("dry_run", false)):
		var data := {"target": lookup["addr"], "groups": _groups(node, false)}
		data["planned"] = [{
			"op": "remove_from_group",
			"target": lookup["addr"],
			"group": group,
		}]
		return M.ok(data)

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: group.remove", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_method(node, "remove_from_group", group)
		undo.add_undo_method(node, "add_to_group", group, true)
		undo.commit_action()
	else:
		node.remove_from_group(group)

	return M.ok({"target": lookup["addr"], "groups": _groups(node, false)})
