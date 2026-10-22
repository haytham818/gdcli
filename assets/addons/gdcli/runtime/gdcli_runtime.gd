extends Node

# Autoload `GdcliRuntime`: lets the gdcli editor plugin drive the running game.
#
# The plugin sends `gdcli:req` over the live debugger session; this node answers
# `gdcli:res` on the game's main thread. It is deliberately self-contained: no
# editor command module is preloaded, because this file also ships into exported
# games where `EditorInterface` does not exist.
#
# Measured on 4.7.2: a capture registered as "gdcli" is called for messages
# "gdcli:<suffix>" with (suffix, data) and must return bool. Without a debugger
# the node never registers, never prints and never answers.

const CAPTURE := "gdcli"
const RUNTIME_VERSION := "0.6.0"

# A fresh game still has an empty viewport texture; the same two-frame wait the
# editor screenshots use (PROTOCOL section 10) applies here.
const SHOT_FRAMES := 2
const NO_DISPLAY_HINT := "run the game with a display (not --headless), e.g. under xvfb-run"

const DENY_PROPS := [
	"script",
	"resource_path",
	"resource_name",
	"resource_scene_unique_id",
	"resource_local_to_scene",
]

var _registered := false
var _class_props: Dictionary = {}


func _ready() -> void:
	if not EngineDebugger.is_active():
		return
	var capture_name := StringName(CAPTURE)
	if EngineDebugger.has_capture(capture_name):
		return
	EngineDebugger.register_message_capture(capture_name, _on_request)
	_registered = true


func _exit_tree() -> void:
	if not _registered:
		return
	_registered = false
	var capture_name := StringName(CAPTURE)
	if EngineDebugger.has_capture(capture_name):
		EngineDebugger.unregister_message_capture(capture_name)


# --- debugger transport ------------------------------------------------------

# Called by the engine for every `gdcli:<suffix>` message from the editor.
func _on_request(suffix: String, data: Array) -> bool:
	if suffix != "req":
		return false
	if data.size() < 3:
		return true
	var id: Variant = data[0]
	var cmd := String(data[1])
	var args: Variant = data[2]
	if typeof(args) != TYPE_DICTIONARY:
		_reply(id, false, _err("BAD_ARGS", "`args` must be an object"))
		return true
	var result: Dictionary
	if cmd == "game.ping":
		result = _ping()
	elif cmd == "game.tree":
		result = _tree(args)
	elif cmd == "game.get":
		result = _get_prop(args)
	elif cmd == "game.set":
		result = _set_prop(args)
	elif cmd == "game.eval":
		result = _eval(args)
	elif cmd == "game.screenshot":
		# Replies later, after two rendered frames; it owns its own reply.
		call_deferred("_screenshot", id, args)
		return true
	else:
		result = _err("UNKNOWN_CMD", "unknown command '%s'" % cmd,
			"run `gdcli game --help`")
	_reply(id, bool(result.get("ok", false)), result.get("data", result.get("error", {})))
	return true


# The game side of the bridge: `[id, ok, payload]`, payload is the data object
# or the error object. Never fails, never throws.
func _reply(id: Variant, ok: bool, payload: Variant) -> void:
	if not EngineDebugger.is_active():
		return
	EngineDebugger.send_message("gdcli:res", [id, ok, payload])


# --- commands ----------------------------------------------------------------

func _ping() -> Dictionary:
	var root := _root()
	return _ok({
		"runtime": RUNTIME_VERSION,
		"scene": _scene_path(root),
		"fps": float(Engine.get_frames_per_second()),
	})


func _tree(args: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("NO_SCENE", "the game has no scene tree yet")
	var depth := maxi(0, _int(args, "depth", 0))
	var with_props := bool(args.get("props", false))
	var nodes: Array = []
	_walk(root, root, 0, depth, with_props, nodes)
	return _ok({"scene": _scene_path(root), "nodes": nodes})


func _get_prop(args: Dictionary) -> Dictionary:
	var prop_name := String(args.get("name", ""))
	if prop_name == "":
		return _err("BAD_ARGS", "missing `name`")
	var lookup := _resolve(args)
	if lookup.has("error"):
		return lookup["error"]
	var obj: Object = lookup["obj"]
	var prop := _find_property(obj, prop_name)
	if prop.is_empty():
		return _err("NOT_FOUND", "property '%s' not found on '%s'" % [prop_name, lookup["addr"]],
			"run `gdcli game tree %s --props`" % lookup["addr"])
	return _ok(_value_info(prop_name, prop, obj.get(prop_name)))


func _set_prop(args: Dictionary) -> Dictionary:
	var prop_name := String(args.get("name", ""))
	if prop_name == "":
		return _err("BAD_ARGS", "missing `name`")
	if not args.has("value"):
		return _err("BAD_ARGS", "missing `value`")
	var lookup := _resolve(args)
	if lookup.has("error"):
		return lookup["error"]
	var obj: Object = lookup["obj"]
	var prop := _find_property(obj, prop_name)
	if prop.is_empty():
		return _err("NOT_FOUND", "property '%s' not found on '%s'" % [prop_name, lookup["addr"]],
			"run `gdcli game tree %s --props`" % lookup["addr"])
	if (int(prop["usage"]) & PROPERTY_USAGE_READ_ONLY) != 0:
		return _err("BAD_ARGS", "property '%s' is read-only" % prop_name)

	var mode := String(args.get("as", "gd")).strip_edges()
	if mode == "":
		mode = "gd"
	var raw: Variant = args["value"]
	var raw_text := raw if raw is String else str(raw)
	var parsed := _parse_value(obj, prop, raw_text, mode)
	if parsed.has("error"):
		return parsed["error"]
	var value: Variant = parsed["value"]
	if bool(args.get("dry_run", false)):
		var planned := {
			"name": prop_name,
			"type": _type_name(prop),
			"value_text": var_to_str(value),
		}
		planned["planned"] = [{
			"op": "set_property",
			"target": lookup["addr"],
			"name": prop_name,
			"value_text": var_to_str(value),
		}]
		return _ok(planned)
	obj.set(prop_name, value)
	return _ok(_value_info(prop_name, prop, obj.get(prop_name)))


func _eval(args: Dictionary) -> Dictionary:
	var expr := String(args.get("expr", ""))
	if expr.strip_edges() == "":
		return _err("BAD_ARGS", "missing `expr`")

	var base: Object = null
	var raw_path: Variant = args.get("path", null)
	if raw_path != null and typeof(raw_path) == TYPE_STRING:
		var path := String(raw_path).strip_edges()
		if path != "":
			var lookup := _lookup(path)
			if lookup.has("error"):
				return lookup["error"]
			base = lookup["obj"]

	var expression := Expression.new()
	if expression.parse(expr) != OK:
		return _err("BAD_ARGS", "cannot parse expression: %s" % expression.get_error_text())
	var value: Variant = expression.execute([], base)
	if expression.has_execute_failed():
		return _err("BAD_ARGS", "expression failed: %s" % expression.get_error_text())
	return _ok({"type": _type_of(value), "value_text": var_to_str(value)})


# `game.screenshot` (PROTOCOL section 12): capture the game's viewport, write the
# PNG here and answer `{path,width,height}` — the editor only correlates ids, no
# image bytes cross the debugger. Runs as a coroutine so the two-frame wait does
# not block the game; the reply goes out when it resumes.
func _screenshot(id: Variant, args: Dictionary) -> void:
	var target := _output_path(args.get("path", null))
	if target.has("error"):
		_fail(id, target["error"])
		return
	if DisplayServer.get_name() == "headless":
		_fail(id, _no_display())
		return
	# Same ordering as editor.screenshot (section 10): no rendering surface means
	# NO_API, and a dry run only reports what it would write.
	if bool(args.get("dry_run", false)):
		_reply(id, true, {
			"path": String(target["reported"]),
			"planned": [{"op": "screenshot", "path": String(target["absolute"])}],
		})
		return

	for _i in range(SHOT_FRAMES):
		await get_tree().process_frame

	var viewport := get_viewport()
	var texture: Texture2D = viewport.get_texture() if viewport != null else null
	# A dummy renderer still has a viewport, but get_image() returns null or an
	# empty image; never write a file in that case.
	var image: Image = texture.get_image() if texture != null else null
	if image == null or image.is_empty():
		_fail(id, _no_display())
		return

	var absolute := String(target["absolute"])
	var directory := absolute.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		var made := DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			_fail(id, _err("GODOT_ERROR", "cannot create '%s': %s"
				% [directory, error_string(made)]))
			return
	var error := image.save_png(absolute)
	if error != OK:
		_fail(id, _err("GODOT_ERROR", "cannot save '%s': %s"
			% [absolute, error_string(error)]))
		return
	_reply(id, true, {
		"path": String(target["reported"]),
		"width": image.get_width(),
		"height": image.get_height(),
	})


# _err() builds a full envelope, so a non-ok reply unwraps it: the game side of
# the bridge sends [id, ok, payload] where payload is the error object itself.
func _fail(id: Variant, envelope: Dictionary) -> void:
	_reply(id, false, envelope["error"])


func _no_display() -> Dictionary:
	return _err("NO_API", "the game has no rendering surface to capture", NO_DISPLAY_HINT)


# Relative paths resolve against the game's project root; res:// and user:// keep
# their protocol form in the reply, absolute and relative inputs answer absolutely.
# Returns {"absolute","reported"} or {"error": <envelope>}.
func _output_path(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_STRING:
		return {"error": _err("BAD_ARGS", "missing `path`")}
	var path := String(raw).strip_edges()
	if path == "":
		return {"error": _err("BAD_ARGS", "missing `path`")}
	if path.begins_with("res://") or path.begins_with("user://"):
		return {"absolute": ProjectSettings.globalize_path(path), "reported": path}
	if path.is_absolute_path():
		var absolute := path.simplify_path()
		return {"absolute": absolute, "reported": absolute}
	var joined := ProjectSettings.globalize_path("res://").path_join(path).simplify_path()
	return {"absolute": joined, "reported": joined}


# --- addressing --------------------------------------------------------------

# The game's address root: the current scene, so `game get Inst/Label text`
# means Main/Inst/Label regardless of the debugger's own /root Window.
func _root() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	if tree.current_scene != null:
		return tree.current_scene
	return tree.root


func _scene_path(root: Node) -> String:
	if root == null or root == get_tree().root:
		return ""
	var path := String(root.scene_file_path)
	return ProjectSettings.localize_path(path) if path != "" else ""


func _resolve(args: Dictionary) -> Dictionary:
	return _lookup(String(args.get("path", "")))


func _lookup(rel: String) -> Dictionary:
	var root := _root()
	if root == null:
		return {"error": _err("NO_SCENE", "the game has no scene tree yet")}
	var node := _find_node(root, rel)
	if node == null:
		return {"error": _err("NOT_FOUND", "node '%s' not found" % rel,
			"run `gdcli game tree`")}
	return {"obj": node, "root": root, "addr": _rel_path(root, node)}


func _find_node(root: Node, rel: String) -> Node:
	var path := rel.strip_edges()
	if path == "" or path == ".":
		return root
	var node := root.get_node_or_null(NodePath(path))
	if node != null:
		return node
	# Accept a leading root name ("Main/Inst") as the editor does.
	var root_name := String(root.name)
	if path == root_name:
		return root
	if path.begins_with(root_name + "/"):
		return root.get_node_or_null(NodePath(path.substr(root_name.length() + 1)))
	return null


func _rel_path(root: Node, node: Node) -> String:
	if root == null or node == null:
		return ""
	if node == root:
		return "."
	if not root.is_ancestor_of(node):
		return ""
	return String(root.get_path_to(node))


# --- tree nodes --------------------------------------------------------------

func _walk(root: Node, node: Node, level: int, depth: int, with_props: bool,
		out: Array) -> void:
	out.append(_node_info(root, node, with_props))
	if depth > 0 and level >= depth - 1:
		return
	for child in node.get_children():
		_walk(root, child, level + 1, depth, with_props, out)


func _node_info(root: Node, node: Node, with_props: bool) -> Dictionary:
	var info := {
		"path": _rel_path(root, node),
		"name": String(node.name),
		"type": node.get_class(),
		"script": null,
		"instance": null,
		"owner": null,
		"children": node.get_child_count(),
	}
	var script: Script = node.get_script()
	if script != null and String(script.resource_path) != "":
		info["script"] = String(script.resource_path)
	var instance := String(node.scene_file_path)
	if instance != "" and node != root:
		info["instance"] = ProjectSettings.localize_path(instance)
	if node.owner != null and root.is_ancestor_of(node.owner):
		info["owner"] = _rel_path(root, node.owner)

	if with_props:
		var props := {}
		for prop in _property_infos(node):
			var prop_name := String(prop["name"])
			var value: Variant = node.get(prop_name)
			if _is_default(node, prop_name, value):
				continue
			props[prop_name] = var_to_str(value)
		info["props"] = props
	return info


# --- properties --------------------------------------------------------------

func _property_infos(obj: Object) -> Array:
	var out: Array = []
	for prop in obj.get_property_list():
		var usage: int = int(prop["usage"])
		if (usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		if (usage & PROPERTY_USAGE_GROUP) != 0:
			continue
		if (usage & PROPERTY_USAGE_SUBGROUP) != 0:
			continue
		if (usage & PROPERTY_USAGE_INTERNAL) != 0:
			continue
		if (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var prop_name := String(prop["name"])
		if prop_name.begins_with("_") or DENY_PROPS.has(prop_name):
			continue
		out.append(prop)
	return out


func _find_property(obj: Object, prop_name: String) -> Dictionary:
	for prop in _property_infos(obj):
		if String(prop["name"]) == prop_name:
			return prop
	return {}


# `scene.tree --props` (section 7) lists non-default values only; the same shape
# in game.tree means the same filter. Script-declared properties have no
# reliable default in a running game, so they stay (they are the interesting
# ones); engine properties are compared with ClassDB's default.
func _is_default(obj: Object, prop_name: String, value: Variant) -> bool:
	if obj.property_can_revert(prop_name):
		return _same(value, obj.property_get_revert(prop_name))
	var cls := obj.get_class()
	if not _class_prop_names(cls).has(prop_name):
		return false
	return _same(value, ClassDB.class_get_property_default_value(cls, prop_name))


func _class_prop_names(cls: String) -> Dictionary:
	var names: Dictionary = _class_props.get(cls, {})
	if names.is_empty():
		for prop in ClassDB.class_get_property_list(cls):
			names[String(prop["name"])] = true
		_class_props[cls] = names
	return names


func _same(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == b
	var ta := typeof(a)
	var tb := typeof(b)
	if ta != tb:
		if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
			return float(a) == float(b)
		return false
	return a == b


func _value_info(prop_name: String, prop: Dictionary, value: Variant) -> Dictionary:
	return {
		"name": prop_name,
		"type": _type_name(prop),
		"value_text": var_to_str(value),
	}


func _type_name(prop: Dictionary) -> String:
	if int(prop["type"]) == TYPE_OBJECT:
		var hint := String(prop.get("hint_string", ""))
		if hint != "":
			return hint
	return type_string(int(prop["type"]))


func _type_of(value: Variant) -> String:
	if value is Object:
		if value == null:
			return "null"
		return (value as Object).get_class()
	return type_string(typeof(value))


func _int(args: Dictionary, key: String, fallback: int) -> int:
	var raw: Variant = args.get(key, fallback)
	if raw == null:
		return fallback
	if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
		return fallback
	return int(raw)


# --- value parsing (PROTOCOL section 6) --------------------------------------

func _parse_value(obj: Object, prop: Dictionary, raw: String, mode: String) -> Dictionary:
	var type: int = int(prop["type"])
	var hint := String(prop.get("hint_string", ""))
	var value: Variant = null

	match mode:
		"gd":
			value = str_to_var(raw)
			if value == null and raw.strip_edges() != "null":
				return {"error": _err("BAD_ARGS",
					"cannot parse '%s' as a GDScript literal" % raw,
					"values use var_to_str syntax, e.g. Vector2(10, 20)")}
		"json":
			var json := JSON.new()
			if json.parse(raw) != OK:
				return {"error": _err("BAD_ARGS", "invalid JSON: %s" % json.get_error_message())}
			value = _coerce(json.data, type, hint)
		"ref":
			if not (raw.begins_with("res://") or raw.begins_with("user://")):
				return {"error": _err("BAD_ARGS", "`ref` expects a res:// or user:// path")}
			if not ResourceLoader.exists(raw):
				return {"error": _err("NOT_FOUND", "resource '%s' not found" % raw)}
			value = load(raw)
		"expr":
			return {"error": _err("BAD_ARGS", "`expr` is editor-side only; use `gd`, `json` or `ref`")}
		_:
			return {"error": _err("BAD_ARGS", "unknown `as` mode '%s'" % mode,
				"expected gd, json or ref")}

	if not _type_matches(value, type, hint):
		return {"error": _err("BAD_ARGS", "value of type %s does not match property type %s"
			% [type_string(typeof(value)), type_string(type)])}
	return {"value": value}


func _coerce(value: Variant, type: int, _hint: String) -> Variant:
	if value == null:
		return null
	if type == TYPE_OBJECT:
		if value is String:
			return load(value)
		return value
	if typeof(value) == type:
		return value
	match type:
		TYPE_INT:
			if value is float or value is bool or value is String:
				return int(value)
		TYPE_FLOAT:
			if value is int or value is bool or value is String:
				return float(value)
		TYPE_STRING:
			return str(value)
		TYPE_STRING_NAME:
			return StringName(str(value))
		TYPE_NODE_PATH:
			return NodePath(str(value))
		TYPE_VECTOR2:
			if value is Array and value.size() >= 2:
				return Vector2(float(value[0]), float(value[1]))
			if value is Dictionary and value.has("x") and value.has("y"):
				return Vector2(float(value["x"]), float(value["y"]))
		TYPE_VECTOR2I:
			if value is Array and value.size() >= 2:
				return Vector2i(int(value[0]), int(value[1]))
			if value is Dictionary and value.has("x") and value.has("y"):
				return Vector2i(int(value["x"]), int(value["y"]))
		TYPE_VECTOR3:
			if value is Array and value.size() >= 3:
				return Vector3(float(value[0]), float(value[1]), float(value[2]))
			if value is Dictionary and value.has("x") and value.has("y") and value.has("z"):
				return Vector3(float(value["x"]), float(value["y"]), float(value["z"]))
		TYPE_VECTOR3I:
			if value is Array and value.size() >= 3:
				return Vector3i(int(value[0]), int(value[1]), int(value[2]))
			if value is Dictionary and value.has("x") and value.has("y") and value.has("z"):
				return Vector3i(int(value["x"]), int(value["y"]), int(value["z"]))
		TYPE_COLOR:
			if value is Array and value.size() >= 3:
				var alpha := float(value[3]) if value.size() >= 4 else 1.0
				return Color(float(value[0]), float(value[1]), float(value[2]), alpha)
		TYPE_RECT2:
			if value is Array and value.size() >= 4:
				return Rect2(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	return value


func _type_matches(value: Variant, type: int, hint: String) -> bool:
	if type == TYPE_NIL:
		return value == null
	if type == TYPE_OBJECT:
		if value == null:
			return true
		if not (value is Object):
			return false
		if hint == "":
			return true
		# Resource properties usually carry a list of allowed classes
		# ("CanvasItemMaterial,ShaderMaterial"), script properties a script path.
		for part in hint.split(","):
			var wanted := part.strip_edges()
			if wanted == "":
				continue
			if value.is_class(wanted):
				return true
			var script: Script = value.get_script()
			if script != null:
				if String(script.resource_path) == wanted:
					return true
				if String(script.get_global_name()) == wanted:
					return true
				if String(script.get_instance_base_type()) == wanted:
					return true
		return false
	return typeof(value) == type


# --- replies -----------------------------------------------------------------

func _ok(data: Dictionary) -> Dictionary:
	return {"ok": true, "data": data}


func _err(code: String, message: String, hint: String = "") -> Dictionary:
	var error := {"code": code, "message": message}
	if hint != "":
		error["hint"] = hint
	return {"ok": false, "error": error}
