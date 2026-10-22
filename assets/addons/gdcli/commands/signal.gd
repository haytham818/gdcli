extends RefCounted

const M = preload("meta.gd")

# CONNECT_PERSIST (2, from Object) is the default: the connection is written
# into the .tscn, which is the whole point of a CLI-driven connection.


static func register(reg: Dictionary) -> void:
	reg["signal.list"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _list(args)
	reg["signal.connect"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _connect(args, opts)
	reg["signal.disconnect"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _disconnect(args, opts)


static func _s(args: Dictionary, key: String, fallback: String = "") -> String:
	var value = args.get(key, fallback)
	if value == null:
		return fallback
	return str(value)


static func _flags(args: Dictionary) -> Dictionary:
	var value = args.get("flags", CONNECT_PERSIST)
	if value == null:
		return {"value": CONNECT_PERSIST}
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return {"error": M.err("BAD_ARGS", "`flags` must be an integer")}
	return {"value": int(value)}


# Signals belong to the scene, so the source has to be writable.
static func _source(args: Dictionary) -> Dictionary:
	if not args.has("source"):
		return {"error": M.err("BAD_ARGS", "missing `source`")}
	var lookup := M.resolve_target(_s(args, "source"), false)
	if lookup.has("error"):
		return lookup
	if lookup["read_only"]:
		return {"error": M.err("NO_API", "only the edited scene can be modified",
			"open it first with `gdcli scene open`")}
	return lookup


static func _has_signal(obj: Object, signal_name: String) -> bool:
	for info in obj.get_signal_list():
		if String(info["name"]) == signal_name:
			return true
	return false


# Address of the object a connection points at, as seen from the edited root.
# Lambdas, editor-internal objects and freed objects have no address: null,
# never a crash.
static func _callable_addr(root: Node, callable: Callable) -> Variant:
	var method := String(callable.get_method())
	if method == "" or method.begins_with("<"):
		return null
	var obj: Object = callable.get_object()
	if obj == null or not is_instance_valid(obj):
		return null
	if not (obj is Node):
		return null
	var rel := M.rel_path(root, obj)
	return null if rel == "" else rel


static func _connections(obj: Object, root: Node, signal_name: String) -> Array:
	var out: Array = []
	for connection in obj.get_signal_connection_list(signal_name):
		var callable: Callable = connection["callable"]
		out.append({
			"to": _callable_addr(root, callable),
			"method": String(callable.get_method()),
			"flags": int(connection["flags"]),
		})
	return out


static func _has_scene_target(connections: Array) -> bool:
	for connection in connections:
		if connection["to"] != null:
			return true
	return false


static func _list(args: Dictionary) -> Dictionary:
	if not args.has("target"):
		return M.err("BAD_ARGS", "missing `target`")
	var lookup := M.resolve_target(_s(args, "target"), false)
	if lookup.has("error"):
		return lookup["error"]
	var obj: Object = lookup["obj"]
	var root: Node = lookup["root"]
	var connected_only := bool(args.get("connected_only", false))

	var signals: Array = []
	for info in obj.get_signal_list():
		var name := String(info["name"])
		var connections := _connections(obj, root, name)
		# The editor itself listens to every scene node (SceneTreeEditor and
		# friends). Those connections have no address in the scene, so
		# `connected_only` means "wired to another node of this scene", which
		# is the wiring the CLI can read back and edit.
		if connected_only and not _has_scene_target(connections):
			continue
		signals.append({
			"name": name,
			"args": Array(info.get("args", [])).size(),
			"connections": connections,
		})
	return M.ok({"target": lookup["addr"], "signals": signals})


static func _connect(args: Dictionary, opts: Dictionary) -> Dictionary:
	var lookup := _source(args)
	if lookup.has("error"):
		return lookup["error"]
	var source: Object = lookup["obj"]
	var root: Node = lookup["root"]

	var signal_name := _s(args, "signal")
	if signal_name == "":
		return M.err("BAD_ARGS", "missing `signal`")
	if not _has_signal(source, signal_name):
		return M.err("NOT_FOUND", "signal '%s' not found on '%s'"
			% [signal_name, lookup["addr"]],
			"run `gdcli signal list %s`" % lookup["addr"])

	var method := _s(args, "method")
	if method == "":
		return M.err("BAD_ARGS", "missing `method`")
	var to := _s(args, "to", ".")
	var parsed_flags := _flags(args)
	if parsed_flags.has("error"):
		return parsed_flags["error"]
	var flags := int(parsed_flags["value"])
	var allow_missing := bool(args.get("allow_missing", false))

	# The target must exist even with allow_missing: a Callable needs a real
	# object. allow_missing only skips the method check (a method may arrive
	# later, e.g. from a script that is still being written).
	var target_lookup := M.resolve_target(to, false)
	if target_lookup.has("error"):
		return target_lookup["error"]
	var target: Object = target_lookup["obj"]
	if not allow_missing and not target.has_method(method):
		return M.err("NOT_FOUND", "method '%s' not found on '%s'"
			% [method, target_lookup["addr"]],
			"pass `--allow-missing` to connect anyway")

	var callable := Callable(target, StringName(method))
	if source.is_connected(signal_name, callable):
		return M.err("BAD_ARGS", "'%s' is already connected to '%s.%s'"
			% [signal_name, target_lookup["addr"], method])

	var data := {
		"source": lookup["addr"],
		"signal": signal_name,
		"to": target_lookup["addr"],
		"method": method,
	}

	if bool(opts.get("dry_run", false)):
		data["planned"] = [{
			"op": "connect",
			"source": lookup["addr"],
			"signal": signal_name,
			"to": target_lookup["addr"],
			"method": method,
			"flags": flags,
		}]
		return M.ok(data)

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: signal.connect", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_method(source, "connect", signal_name, callable, flags)
		undo.add_undo_method(source, "disconnect", signal_name, callable)
		undo.commit_action()
	else:
		var error := source.connect(signal_name, callable, flags)
		if error != OK:
			return M.err("GODOT_ERROR", "connect() failed: %s" % error_string(error))
	return M.ok(data)


static func _disconnect(args: Dictionary, opts: Dictionary) -> Dictionary:
	var lookup := _source(args)
	if lookup.has("error"):
		return lookup["error"]
	var source: Object = lookup["obj"]
	var root: Node = lookup["root"]

	var signal_name := _s(args, "signal")
	if signal_name == "":
		return M.err("BAD_ARGS", "missing `signal`")
	if not _has_signal(source, signal_name):
		return M.err("NOT_FOUND", "signal '%s' not found on '%s'"
			% [signal_name, lookup["addr"]],
			"run `gdcli signal list %s`" % lookup["addr"])

	var method := _s(args, "method")
	if method == "":
		return M.err("BAD_ARGS", "missing `method`")
	var target_lookup := M.resolve_target(_s(args, "to", "."), false)
	if target_lookup.has("error"):
		return target_lookup["error"]
	var callable := Callable(target_lookup["obj"], StringName(method))

	var flags := -1
	for connection in source.get_signal_connection_list(signal_name):
		if connection["callable"] == callable:
			flags = int(connection["flags"])
			break
	if flags == -1:
		return M.err("NOT_FOUND", "'%s' is not connected to '%s.%s'"
			% [signal_name, target_lookup["addr"], method],
			"run `gdcli signal list %s --connected-only`" % lookup["addr"])

	var data := {
		"source": lookup["addr"],
		"signal": signal_name,
		"to": target_lookup["addr"],
		"method": method,
	}

	if bool(opts.get("dry_run", false)):
		data["planned"] = [{
			"op": "disconnect",
			"source": lookup["addr"],
			"signal": signal_name,
			"to": target_lookup["addr"],
			"method": method,
		}]
		return M.ok(data)

	if bool(opts.get("undo", true)):
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("gdcli: signal.disconnect", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_method(source, "disconnect", signal_name, callable)
		undo.add_undo_method(source, "connect", signal_name, callable, flags)
		undo.commit_action()
	else:
		# disconnect() returns void in 4.x: verify the connection is gone.
		source.disconnect(signal_name, callable)
		if source.is_connected(signal_name, callable):
			return M.err("GODOT_ERROR", "disconnect() did not remove the connection")
	return M.ok(data)
