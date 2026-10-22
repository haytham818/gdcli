extends RefCounted

# meta.* commands, plus the helpers every command module shares.
#
# The add-on ships as a fixed set of embedded files, so there is deliberately no
# separate "util" module: helpers live here to keep the installed file list exact.

const PROTOCOL := 1

const DENY_PROPS := [
	"script",
	"resource_path",
	"resource_name",
	"resource_scene_unique_id",
	"resource_local_to_scene",
]

# class name -> {property name: true}, built once per class
static var _class_prop_names: Dictionary = {}
# "class|script path" -> fresh instance used to read script property defaults
static var _fresh_defaults: Dictionary = {}


static func register(reg: Dictionary) -> void:
	reg["meta.ping"] = func(_args: Dictionary, opts: Dictionary) -> Dictionary:
		return ok(opts["plugin"].ping_data())
	reg["meta.capabilities"] = func(_args: Dictionary, opts: Dictionary) -> Dictionary:
		return ok({"capabilities": opts["plugin"].capabilities()})


# --- reply envelopes ---------------------------------------------------------

static func ok(data: Variant) -> Dictionary:
	return {"ok": true, "data": data}


static func err(code: String, message: String, hint: String = "") -> Dictionary:
	var e := {"code": code, "message": message}
	if hint != "":
		e["hint"] = hint
	return {"ok": false, "error": e}


# --- scene / node addressing -------------------------------------------------

static func edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


static func localize(path: String) -> String:
	if path == "":
		return ""
	return ProjectSettings.localize_path(path)


# Relative address of a node, computed from the edited root (never Node.get_path()).
# The root itself is "."; a direct child is "Inst"; empty means "the edited root" too.
static func rel_path(root: Node, node: Node) -> String:
	if root == null or node == null:
		return ""
	if node == root:
		return "."
	if root.is_ancestor_of(node):
		return String(root.get_path_to(node))
	# Not part of the addressed scene (never reached for scene-owned nodes).
	return ""


static func find_node(root: Node, rel: String) -> Node:
	var path := rel.strip_edges()
	if path == "" or path == ".":
		return root
	var node := root.get_node_or_null(NodePath(path))
	if node != null:
		return node
	# Accept a leading root name ("Main/Inst") in addition to the bare form ("Inst").
	var root_name := String(root.name)
	if path == root_name:
		return root
	if path.begins_with(root_name + "/"):
		return root.get_node_or_null(NodePath(path.substr(root_name.length() + 1)))
	return null


static func root_for_scene(scene_path: String) -> Node:
	var want := localize(scene_path)
	var edited := edited_root()
	if edited != null and localize(edited.scene_file_path) == want:
		return edited
	for root in EditorInterface.get_open_scene_roots():
		if localize(root.scene_file_path) == want:
			return root
	return null


# Resolves an address from PROTOCOL section 5.
# Returns {"obj","root","read_only","addr"} or {"error": <envelope>}.
static func resolve_target(target: String, allow_resource: bool) -> Dictionary:
	var path := target.strip_edges()
	if path == "" or path == ".":
		var edited := edited_root()
		if edited == null:
			return {"error": err("NO_SCENE", "no scene is being edited")}
		return {"obj": edited, "root": edited, "read_only": false, "addr": "."}

	if path.begins_with("res://") or path.begins_with("user://"):
		var sep := path.find("::")
		if sep == -1:
			if not allow_resource:
				return {"error": err("BAD_ARGS", "expected a node path, got resource '%s'" % path)}
			if not ResourceLoader.exists(path):
				return {"error": err("NOT_FOUND", "resource '%s' not found" % path)}
			var res: Resource = load(path)
			if res == null:
				return {"error": err("GODOT_ERROR", "could not load resource '%s'" % path)}
			return {"obj": res, "root": edited_root(), "read_only": false, "addr": path}

		var scene_path := path.substr(0, sep)
		var node_path := path.substr(sep + 2)
		var scene_root := root_for_scene(scene_path)
		if scene_root == null:
			return {"error": err("NOT_FOUND", "scene '%s' is not open" % scene_path,
				"open it with `gdcli scene open`")}
		var node := find_node(scene_root, node_path)
		if node == null:
			return {"error": err("NOT_FOUND", "node '%s' not found in '%s'" % [node_path, scene_path],
				"run `gdcli scene tree`")}
		return {
			"obj": node,
			"root": scene_root,
			"read_only": scene_root != edited_root(),
			"addr": rel_path(scene_root, node),
		}

	var edited := edited_root()
	if edited == null:
		return {"error": err("NO_SCENE", "no scene is being edited")}
	var node := find_node(edited, path)
	if node == null:
		return {"error": err("NOT_FOUND", "node '%s' not found" % path, "run `gdcli scene tree`")}
	return {"obj": node, "root": edited, "read_only": false, "addr": rel_path(edited, node)}


static func node_info(root: Node, node: Node, with_props: bool, scene_root: Node = null) -> Dictionary:
	if scene_root == null:
		scene_root = root
	var info := {
		"path": rel_path(root, node),
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
	if instance != "" and node != scene_root:
		info["instance"] = localize(instance)
	if node.owner != null:
		info["owner"] = rel_path(scene_root, node.owner)

	if with_props:
		var props := {}
		for prop in property_infos(node):
			var value: Variant = node.get(prop["name"])
			if is_default(node, prop, value):
				continue
			props[String(prop["name"])] = value_text(value)
		info["props"] = props
	return info


# Nodes owned by the edited root belong to this scene. Anything else (a child of
# an instanced scene, or an ownerless node) cannot be saved, and the editor's
# editable-children flag has no scripting API.
static func is_writable(root: Node, node: Node) -> bool:
	if node == root:
		return true
	return node.owner == root


static func instance_error(root: Node, node: Node) -> Dictionary:
	return err("NO_API", "cannot edit inside an instanced scene",
		"'%s' belongs to the instanced scene; open that scene to edit it" % rel_path(root, node))


static func unique_name(parent: Node, base: String) -> String:
	var stem := base.validate_node_name()
	if stem == "":
		stem = "Node"
	if parent.get_node_or_null(NodePath(stem)) == null:
		return stem
	var i := 2
	while i < 100000:
		var candidate := "%s%d" % [stem, i]
		if parent.get_node_or_null(NodePath(candidate)) == null:
			return candidate
		i += 1
	return stem


# --- properties --------------------------------------------------------------

static func property_infos(obj: Object) -> Array:
	var out: Array = []
	for prop in obj.get_property_list():
		var usage: int = int(prop["usage"])
		if usage & PROPERTY_USAGE_CATEGORY:
			continue
		if usage & PROPERTY_USAGE_GROUP:
			continue
		if usage & PROPERTY_USAGE_SUBGROUP:
			continue
		if usage & PROPERTY_USAGE_INTERNAL:
			continue
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		if not (usage & PROPERTY_USAGE_STORAGE):
			continue
		var prop_name := String(prop["name"])
		if prop_name.begins_with("_") or DENY_PROPS.has(prop_name):
			continue
		out.append(prop)
	return out


static func find_property(obj: Object, name: String) -> Dictionary:
	for prop in property_infos(obj):
		if String(prop["name"]) == name:
			return prop
	return {}


static func type_name(prop: Dictionary) -> String:
	var type: int = int(prop["type"])
	if type == TYPE_OBJECT:
		var hint := String(prop.get("hint_string", ""))
		if hint != "":
			return hint
	return type_string(type)


static func value_text(value: Variant) -> String:
	return var_to_str(value)


# Everything a reply may contain has to survive JSON.stringify.
static func json_safe(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL:
			return null
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return String(value)
		TYPE_ARRAY:
			var arr: Array = []
			for item in value:
				arr.append(json_safe(item))
			return arr
		TYPE_DICTIONARY:
			var dict := {}
			for key in value.keys():
				dict[String(key)] = json_safe(value[key])
			return dict
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_BYTE_ARRAY:
			var packed: Array = []
			for item in Array(value):
				packed.append(json_safe(item))
			return packed
		TYPE_OBJECT:
			if value == null:
				return null
			return value_text(value)
		_:
			return value_text(value)


static func _class_names_for(cls: String) -> Dictionary:
	var names: Dictionary = _class_prop_names.get(cls, {})
	if names.is_empty():
		for prop in ClassDB.class_get_property_list(cls):
			names[String(prop["name"])] = true
		_class_prop_names[cls] = names
	return names


static func _fresh_default(obj: Object) -> Object:
	var script: Script = obj.get_script()
	var key := obj.get_class()
	if script != null and String(script.resource_path) != "":
		key += "|" + String(script.resource_path)
	if _fresh_defaults.has(key):
		return _fresh_defaults[key]
	var fresh: Object = null
	if script != null:
		# GDScript.can_instantiate() is false for scripts the editor has not
		# compiled yet, but new() still builds a valid instance.
		fresh = script.new()
	elif ClassDB.can_instantiate(obj.get_class()):
		fresh = ClassDB.instantiate(obj.get_class())
	if fresh != null:
		_fresh_defaults[key] = fresh
	return fresh


static func default_value(obj: Object, prop: Dictionary) -> Variant:
	var name := String(prop["name"])
	if obj.property_can_revert(name):
		return obj.property_get_revert(name)
	var cls := obj.get_class()
	if _class_names_for(cls).has(name):
		return ClassDB.class_get_property_default_value(cls, name)
	var fresh := _fresh_default(obj)
	if fresh != null:
		return fresh.get(name)
	return null


static func is_default(obj: Object, prop: Dictionary, value: Variant) -> bool:
	return _same(value, default_value(obj, prop))


static func _same(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == b
	var ta := typeof(a)
	var tb := typeof(b)
	if ta != tb:
		if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
			return float(a) == float(b)
		return false
	return a == b


# --- value parsing (PROTOCOL section 6) --------------------------------------

static func parse_value(obj: Object, prop: Dictionary, raw: String, mode: String) -> Dictionary:
	var type: int = int(prop["type"])
	var hint := String(prop.get("hint_string", ""))
	var value: Variant = null

	match mode:
		"gd":
			value = str_to_var(raw)
			if value == null and raw.strip_edges() != "null":
				return {"error": err("BAD_ARGS", "cannot parse '%s' as a GDScript literal" % raw,
					"values use var_to_str syntax, e.g. Vector2(10, 20)")}
		"json":
			var json := JSON.new()
			if json.parse(raw) != OK:
				return {"error": err("BAD_ARGS", "invalid JSON: %s" % json.get_error_message())}
			value = coerce(json.data, type, hint)
		"ref":
			if not (raw.begins_with("res://") or raw.begins_with("user://")):
				return {"error": err("BAD_ARGS", "`ref` expects a res:// or user:// path")}
			if not ResourceLoader.exists(raw):
				return {"error": err("NOT_FOUND", "resource '%s' not found" % raw)}
			value = load(raw)
		"expr":
			var expression := Expression.new()
			if expression.parse(raw) != OK:
				return {"error": err("BAD_ARGS", "cannot parse expression: %s" % expression.get_error_text())}
			value = expression.execute([], obj)
			if expression.has_execute_failed():
				return {"error": err("BAD_ARGS", "expression failed: %s" % expression.get_error_text())}
		_:
			return {"error": err("BAD_ARGS", "unknown `as` mode '%s'" % mode,
				"expected gd, json, ref or expr")}

	if not type_matches(value, type, hint):
		return {"error": err("BAD_ARGS", "value of type %s does not match property type %s"
			% [type_string(typeof(value)), type_string(type)])}
	return {"value": value}


# Coerces a JSON-parsed value to the shape of the current property type.
static func coerce(value: Variant, type: int, hint: String) -> Variant:
	if value == null:
		return null
	if type == TYPE_OBJECT:
		if value is String:
			var res: Resource = load(value)
			return res
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
			if value is String:
				return Color.from_string(value, Color.BLACK)
		TYPE_RECT2:
			if value is Array and value.size() >= 4:
				return Rect2(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	return value


static func type_matches(value: Variant, type: int, hint: String) -> bool:
	if type == TYPE_NIL:
		return value == null
	if type == TYPE_OBJECT:
		if value == null:
			return true
		if not (value is Object):
			return false
		if hint == "":
			return true
		if value.is_class(hint):
			return true
		var script: Script = value.get_script()
		if script != null and String(script.get_global_name()) == hint:
			return true
		return false
	return typeof(value) == type
