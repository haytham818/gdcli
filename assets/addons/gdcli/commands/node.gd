extends RefCounted

const M = preload("meta.gd")


static func register(reg: Dictionary) -> void:
	reg["node.add"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _add(args, opts)
	reg["node.instance"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _instance(args, opts)
	reg["node.rm"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _remove(args, opts)
	reg["node.mv"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _move(args, opts)
	reg["node.dup"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _duplicate(args, opts)
	reg["node.rename"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _rename(args, opts)


static func _s(args: Dictionary, key: String, fallback: String = "") -> String:
	var value = args.get(key, fallback)
	if value == null:
		return fallback
	return str(value)


static func _i(args: Dictionary, key: String, fallback: int) -> int:
	var value = args.get(key, fallback)
	if value == null:
		return fallback
	return int(value)


static func _resolve(target: String) -> Dictionary:
	var resolved := M.resolve_target(target, false)
	if resolved.has("error"):
		return resolved
	if resolved["read_only"]:
		return {"error": M.err("NO_API", "only the edited scene can be modified",
			"open it first with `gdcli scene open`")}
	return resolved


static func _add(args: Dictionary, opts: Dictionary) -> Dictionary:
	var type := _s(args, "type")
	var script_path := _s(args, "script")
	if (type == "") == (script_path == ""):
		return M.err("BAD_ARGS", "exactly one of `type` and `script` is required")

	var parent_lookup := _resolve(_s(args, "parent", ""))
	if parent_lookup.has("error"):
		return parent_lookup["error"]
	var parent: Node = parent_lookup["obj"]
	var root: Node = parent_lookup["root"]
	if not M.is_writable(root, parent):
		return M.instance_error(root, parent)

	var name := _s(args, "name")
	var name_given := name != ""
	if name_given:
		if name != name.validate_node_name():
			return M.err("BAD_ARGS", "invalid node name '%s'" % name)
		if parent.get_node_or_null(NodePath(name)) != null:
			return M.err("BAD_ARGS", "a child named '%s' already exists under '%s'"
				% [name, M.rel_path(root, parent)])

	var index := _i(args, "index", -1)
	if index < -1 or index > parent.get_child_count():
		return M.err("BAD_ARGS", "`index` must be between 0 and %d" % parent.get_child_count())

	var node_type := type
	if type != "":
		if not ClassDB.class_exists(type):
			return M.err("NOT_FOUND", "class '%s' does not exist" % type)
		if not ClassDB.can_instantiate(type):
			return M.err("BAD_ARGS", "class '%s' cannot be instantiated" % type)
		if type != "Node" and not ClassDB.is_parent_class(type, "Node"):
			return M.err("BAD_ARGS", "class '%s' is not a Node" % type)
		if not name_given:
			name = M.unique_name(parent, type)
	else:
		if not ResourceLoader.exists(script_path):
			return M.err("NOT_FOUND", "script '%s' not found" % script_path)
		var script = load(script_path)
		if script == null or not (script is Script):
			return M.err("BAD_ARGS", "'%s' is not a script" % script_path)
		var base := String(script.get_instance_base_type())
		if base != "Node" and not ClassDB.is_parent_class(base, "Node"):
			return M.err("BAD_ARGS", "script '%s' does not extend Node" % script_path)
		node_type = base
		if not name_given:
			var global_name := String(script.get_global_name())
			name = M.unique_name(parent, global_name if global_name != "" else script_path.get_file().get_basename())

	var path := name if M.rel_path(root, parent) == "." else "%s/%s" % [M.rel_path(root, parent), name]

	if bool(opts.get("dry_run", false)):
		var data := {"path": path, "type": node_type}
		data["planned"] = [{
			"op": "add_child",
			"parent": M.rel_path(root, parent),
			"node": name,
			"type": node_type,
		}]
		return M.ok(data)

	var node: Node = null
	if type != "":
		var made_type = ClassDB.instantiate(type)
		if not (made_type is Node):
			return M.err("GODOT_ERROR", "could not instantiate '%s'" % type)
		node = made_type
	else:
		var made_script = load(script_path).new()
		if not (made_script is Node):
			return M.err("GODOT_ERROR", "could not instantiate '%s'" % script_path)
		node = made_script
	node.name = name

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: node.add", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_method(parent, "add_child", node, true)
		if index >= 0 and index < parent.get_child_count():
			undo.add_do_method(parent, "move_child", node, index)
		undo.add_do_property(node, "owner", root)
		undo.add_do_reference(node)
		undo.add_undo_method(parent, "remove_child", node)
		undo.commit_action()
	else:
		parent.add_child(node, true)
		if index >= 0 and index < parent.get_child_count() - 1:
			parent.move_child(node, index)
		node.owner = root

	return M.ok({"path": M.rel_path(root, node), "type": node.get_class()})


static func _instance(args: Dictionary, opts: Dictionary) -> Dictionary:
	var scene_path := _s(args, "scene")
	if scene_path == "":
		return M.err("BAD_ARGS", "missing `scene`")
	if not (scene_path.begins_with("res://") or scene_path.begins_with("user://")):
		return M.err("BAD_ARGS", "`scene` must be a res:// or user:// scene path")
	if not ResourceLoader.exists(scene_path):
		return M.err("NOT_FOUND", "scene '%s' not found" % scene_path)
	var packed := load(scene_path)
	if not (packed is PackedScene):
		return M.err("BAD_ARGS", "'%s' is not a PackedScene" % scene_path)
	scene_path = M.localize(scene_path)

	var parent_lookup := _resolve(_s(args, "parent", ""))
	if parent_lookup.has("error"):
		return parent_lookup["error"]
	var parent: Node = parent_lookup["obj"]
	var root: Node = parent_lookup["root"]
	if not M.is_writable(root, parent):
		return M.instance_error(root, parent)

	var name := _s(args, "name")
	var name_given := name != ""
	if name_given:
		if name != name.validate_node_name():
			return M.err("BAD_ARGS", "invalid node name '%s'" % name)
		if parent.get_node_or_null(NodePath(name)) != null:
			return M.err("BAD_ARGS", "a child named '%s' already exists under '%s'"
				% [name, M.rel_path(root, parent)])
	var index := _i(args, "index", -1)
	if index < -1 or index > parent.get_child_count():
		return M.err("BAD_ARGS", "`index` must be between 0 and %d" % parent.get_child_count())

	if bool(opts.get("dry_run", false)):
		var planned_name := name if name_given else String(packed.get_state().get_node_name(0))
		var planned_path := planned_name if M.rel_path(root, parent) == "." \
			else "%s/%s" % [M.rel_path(root, parent), planned_name]
		var data := {"path": planned_path, "scene": scene_path}
		data["planned"] = [{
			"op": "instance",
			"parent": M.rel_path(root, parent),
			"node": planned_name,
			"scene": scene_path,
		}]
		return M.ok(data)

	var node: Node = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if node == null:
		return M.err("GODOT_ERROR", "could not instantiate '%s'" % scene_path)
	if not name_given:
		name = M.unique_name(parent, String(node.name))
	node.name = name

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: node.instance", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_method(parent, "add_child", node, true)
		if index >= 0 and index < parent.get_child_count():
			undo.add_do_method(parent, "move_child", node, index)
		undo.add_do_property(node, "owner", root)
		undo.add_do_reference(node)
		undo.add_undo_method(parent, "remove_child", node)
		undo.commit_action()
	else:
		parent.add_child(node, true)
		if index >= 0 and index < parent.get_child_count() - 1:
			parent.move_child(node, index)
		node.owner = root

	return M.ok({"path": M.rel_path(root, node), "scene": scene_path})


static func _remove(args: Dictionary, opts: Dictionary) -> Dictionary:
	if not args.has("path"):
		return M.err("BAD_ARGS", "missing `path`")
	var lookup := _resolve(_s(args, "path"))
	if lookup.has("error"):
		return lookup["error"]
	var node: Node = lookup["obj"]
	var root: Node = lookup["root"]
	if node == root:
		return M.err("BAD_ARGS", "cannot remove the edited scene root")
	if not M.is_writable(root, node):
		return M.instance_error(root, node)
	var parent := node.get_parent()
	if parent == null:
		return M.err("GODOT_ERROR", "node '%s' has no parent" % M.rel_path(root, node))
	var addr := M.rel_path(root, node)
	var index := node.get_index()
	var old_owner := node.owner

	if bool(opts.get("dry_run", false)):
		var data := {}
		data["planned"] = [{"op": "remove_child", "parent": M.rel_path(root, parent), "node": addr}]
		return M.ok(data)

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: node.rm", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_method(parent, "remove_child", node)
		undo.add_undo_method(parent, "add_child", node, true)
		undo.add_undo_method(parent, "move_child", node, index)
		undo.add_undo_method(node, "set_owner", old_owner)
		# The node was added by the undo side: it is freed when the undo history
		# is discarded, not when the redo history is discarded (Godot's own
		# delete-node pattern).
		undo.add_undo_reference(node)
		undo.commit_action()
	else:
		parent.remove_child(node)
		node.queue_free()
	return M.ok({})


static func _move(args: Dictionary, opts: Dictionary) -> Dictionary:
	if not args.has("path"):
		return M.err("BAD_ARGS", "missing `path`")
	if not args.has("to"):
		return M.err("BAD_ARGS", "missing `to`")
	var lookup := _resolve(_s(args, "path"))
	if lookup.has("error"):
		return lookup["error"]
	var node: Node = lookup["obj"]
	var root: Node = lookup["root"]
	if node == root:
		return M.err("BAD_ARGS", "cannot move the edited scene root")
	if not M.is_writable(root, node):
		return M.instance_error(root, node)

	var dest_lookup := _resolve(_s(args, "to"))
	if dest_lookup.has("error"):
		return dest_lookup["error"]
	var dest: Node = dest_lookup["obj"]
	if not M.is_writable(root, dest):
		return M.instance_error(root, dest)
	if dest == node:
		return M.err("BAD_ARGS", "cannot move a node into itself")
	if node.is_ancestor_of(dest):
		return M.err("BAD_ARGS", "cannot move a node into its own descendant")

	var old_parent := node.get_parent()
	if old_parent == null:
		return M.err("GODOT_ERROR", "node '%s' has no parent" % M.rel_path(root, node))
	var old_index := node.get_index()
	var old_owner := node.owner
	var index := _i(args, "index", -1)
	var limit := dest.get_child_count()
	if index > limit:
		return M.err("BAD_ARGS", "`index` must be between 0 and %d" % limit)

	var new_owner: Node = old_owner
	if new_owner == null or not (new_owner == dest or new_owner.is_ancestor_of(dest)):
		new_owner = root
	var new_path := String(node.name) if M.rel_path(root, dest) == "." \
		else "%s/%s" % [M.rel_path(root, dest), node.name]

	if bool(opts.get("dry_run", false)):
		var data := {"path": new_path}
		data["planned"] = [{
			"op": "reparent",
			"node": M.rel_path(root, node),
			"to": M.rel_path(root, dest),
			"index": index,
		}]
		return M.ok(data)

	if dest == old_parent:
		if index < 0 or index == old_index:
			return M.ok({"path": M.rel_path(root, node)})
		if bool(opts.get("undo", true)):
			var undo_order := EditorInterface.get_editor_undo_redo()
			undo_order.create_action("gdcli: node.mv", UndoRedo.MERGE_DISABLE, root)
			undo_order.add_do_method(old_parent, "move_child", node, mini(index, old_parent.get_child_count() - 1))
			undo_order.add_undo_method(old_parent, "move_child", node, old_index)
			undo_order.commit_action()
		else:
			old_parent.move_child(node, mini(index, old_parent.get_child_count() - 1))
		return M.ok({"path": M.rel_path(root, node)})

	if bool(opts.get("undo", true)):
		var undo_reparent := EditorInterface.get_editor_undo_redo()
		undo_reparent.create_action("gdcli: node.mv", UndoRedo.MERGE_DISABLE, root)
		undo_reparent.add_do_method(node, "reparent", dest, false)
		undo_reparent.add_do_method(node, "set_owner", new_owner)
		if index >= 0:
			undo_reparent.add_do_method(dest, "move_child", node, mini(index, dest.get_child_count()))
		undo_reparent.add_undo_method(node, "reparent", old_parent, false)
		undo_reparent.add_undo_method(node, "set_owner", old_owner)
		undo_reparent.add_undo_method(old_parent, "move_child", node, old_index)
		undo_reparent.commit_action()
	else:
		node.reparent(dest, false)
		node.owner = new_owner
		if index >= 0:
			dest.move_child(node, mini(index, dest.get_child_count() - 1))

	return M.ok({"path": M.rel_path(root, node)})


static func _duplicate(args: Dictionary, opts: Dictionary) -> Dictionary:
	if not args.has("path"):
		return M.err("BAD_ARGS", "missing `path`")
	var lookup := _resolve(_s(args, "path"))
	if lookup.has("error"):
		return lookup["error"]
	var node: Node = lookup["obj"]
	var root: Node = lookup["root"]
	if node == root:
		return M.err("BAD_ARGS", "cannot duplicate the edited scene root")
	var parent := node.get_parent()
	if parent == null:
		return M.err("GODOT_ERROR", "node '%s' has no parent" % M.rel_path(root, node))

	var name := _s(args, "name")
	if name != "":
		if name != name.validate_node_name():
			return M.err("BAD_ARGS", "invalid node name '%s'" % name)
		if parent.get_node_or_null(NodePath(name)) != null:
			return M.err("BAD_ARGS", "a child named '%s' already exists under '%s'"
				% [name, M.rel_path(root, parent)])
	else:
		name = M.unique_name(parent, String(node.name))

	var path := name if M.rel_path(root, parent) == "." \
		else "%s/%s" % [M.rel_path(root, parent), name]

	if bool(opts.get("dry_run", false)):
		var data := {"path": path}
		data["planned"] = [{
			"op": "duplicate",
			"node": M.rel_path(root, node),
			"name": name,
		}]
		return M.ok(data)

	var copy: Node = node.duplicate()
	copy.name = name
	var index := node.get_index() + 1

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: node.dup", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_method(parent, "add_child", copy, true)
		undo.add_do_method(parent, "move_child", copy, index)
		undo.add_do_reference(copy)
		undo.add_undo_method(parent, "remove_child", copy)
		undo.commit_action()
		# owner can only be assigned once the copy is in the tree
		_own_subtree(root, copy)
	else:
		parent.add_child(copy, true)
		parent.move_child(copy, index)
		_own_subtree(root, copy)

	return M.ok({"path": M.rel_path(root, copy)})


# Children of an instance root belong to the instanced scene, not to this scene:
# only the instance root itself is owned by the edited scene.
static func _own_subtree(root: Node, node: Node) -> void:
	node.owner = root
	if String(node.scene_file_path) != "":
		return
	for child in node.get_children():
		_own_subtree(root, child)


static func _rename(args: Dictionary, opts: Dictionary) -> Dictionary:
	if not args.has("path"):
		return M.err("BAD_ARGS", "missing `path`")
	var lookup := _resolve(_s(args, "path"))
	if lookup.has("error"):
		return lookup["error"]
	var node: Node = lookup["obj"]
	var root: Node = lookup["root"]
	if not M.is_writable(root, node):
		return M.instance_error(root, node)
	var name := _s(args, "name")
	if name == "":
		return M.err("BAD_ARGS", "missing `name`")
	if name != name.validate_node_name():
		return M.err("BAD_ARGS", "invalid node name '%s'" % name)
	if name == String(node.name):
		return M.ok({"path": M.rel_path(root, node)})
	var parent := node.get_parent()
	if parent != null and parent.get_node_or_null(NodePath(name)) != null:
		return M.err("BAD_ARGS", "a child named '%s' already exists under '%s'"
			% [name, M.rel_path(root, parent)])

	var old_name := String(node.name)
	if bool(opts.get("dry_run", false)):
		var predicted := M.rel_path(root, node)
		if parent != null:
			predicted = name if M.rel_path(root, parent) == "." \
				else "%s/%s" % [M.rel_path(root, parent), name]
		var data := {"path": predicted}
		data["planned"] = [{"op": "set_name", "node": M.rel_path(root, node), "name": name}]
		return M.ok(data)

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: node.rename", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_property(node, "name", name)
		undo.add_undo_property(node, "name", old_name)
		undo.commit_action()
	else:
		node.name = name

	return M.ok({"path": M.rel_path(root, node)})
