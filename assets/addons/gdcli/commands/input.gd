extends RefCounted

# input.* commands (PROTOCOL section 13).
#
# The input map lives in project settings, so this module only converts the small
# event DSL to real InputEvent objects and lets the engine serialize them
# (`ProjectSettings.set_setting("input/<action>", {...})` + `save()`), which is
# what produces the canonical `[input]` block in project.godot.
#
# Actions are listed from the file, not from ProjectSettings.get_property_list():
# the engine registers dozens of built-in `input/ui_*` defaults that are not in
# the project's `[input]` section, and `input.list` must only report real actions.

const M = preload("meta.gd")

const INPUT_PREFIX := "input/"
const PROJECT_FILE := "res://project.godot"
const DEFAULT_DEADZONE := 0.5

const MODIFIERS := ["shift", "ctrl", "alt", "meta"]

const MOUSE_BUTTONS := {
	"none": MOUSE_BUTTON_NONE,
	"left": MOUSE_BUTTON_LEFT,
	"right": MOUSE_BUTTON_RIGHT,
	"middle": MOUSE_BUTTON_MIDDLE,
	"wheel_up": MOUSE_BUTTON_WHEEL_UP,
	"wheel_down": MOUSE_BUTTON_WHEEL_DOWN,
	"wheel_left": MOUSE_BUTTON_WHEEL_LEFT,
	"wheel_right": MOUSE_BUTTON_WHEEL_RIGHT,
	"xbutton1": MOUSE_BUTTON_XBUTTON1,
	"xbutton2": MOUSE_BUTTON_XBUTTON2,
}

const MOUSE_NAMES := {
	MOUSE_BUTTON_LEFT: "left",
	MOUSE_BUTTON_RIGHT: "right",
	MOUSE_BUTTON_MIDDLE: "middle",
	MOUSE_BUTTON_WHEEL_UP: "wheel_up",
	MOUSE_BUTTON_WHEEL_DOWN: "wheel_down",
	MOUSE_BUTTON_WHEEL_LEFT: "wheel_left",
	MOUSE_BUTTON_WHEEL_RIGHT: "wheel_right",
	MOUSE_BUTTON_XBUTTON1: "xbutton1",
	MOUSE_BUTTON_XBUTTON2: "xbutton2",
}

const EVENT_HINT := "event specs look like {\"type\":\"key\",\"key\":\"Space\"} or {\"type\":\"joy_button\",\"button\":0}"
const ACTIONS_HINT := "run `gdcli project input actions`"
const KEY_HINT := "key names are the ones OS.find_keycode_from_string accepts, e.g. Space, F1, A"


static func register(reg: Dictionary) -> void:
	reg["input.list"] = func(args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _list(args)
	reg["input.action.add"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _action_add(args, opts)
	reg["input.action.remove"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _action_remove(args, opts)
	reg["input.action.rename"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _action_rename(args, opts)
	reg["input.event.add"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _event_add(args, opts)
	reg["input.event.remove"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _event_remove(args, opts)


static func _s(args: Dictionary, key: String, fallback: String = "") -> String:
	var value: Variant = args.get(key, fallback)
	if value == null:
		return fallback
	return str(value)


static func _dry(opts: Dictionary) -> bool:
	return bool(opts.get("dry_run", false))


# --- reading -----------------------------------------------------------------

# Names of the actions actually stored in project.godot's `[input]` section.
static func _action_names() -> Array:
	var names: Array = []
	var cfg := ConfigFile.new()
	if cfg.load(PROJECT_FILE) != OK:
		return names
	if not cfg.has_section("input"):
		return names
	for key in cfg.get_section_keys("input"):
		names.append(String(key))
	names.sort()
	return names


static func _has_action(name: String) -> bool:
	return _action_names().has(name)


# A missing or partial entry reads as deadzone 0.5 / [], never as an error.
static func _read_action(name: String) -> Dictionary:
	var key := INPUT_PREFIX + name
	if not ProjectSettings.has_setting(key):
		return {"deadzone": DEFAULT_DEADZONE, "events": []}
	return _normalize_action(ProjectSettings.get_setting(key))


static func _normalize_action(value: Variant) -> Dictionary:
	var deadzone := DEFAULT_DEADZONE
	var events: Array = []
	if value is Dictionary:
		var raw_deadzone: Variant = value.get("deadzone", DEFAULT_DEADZONE)
		if typeof(raw_deadzone) == TYPE_INT or typeof(raw_deadzone) == TYPE_FLOAT:
			deadzone = float(raw_deadzone)
		var raw_events: Variant = value.get("events", [])
		if raw_events is Array:
			events = raw_events
	return {"deadzone": deadzone, "events": events}


# --- writing -----------------------------------------------------------------

static func _write_action(name: String, deadzone: float, events: Array) -> Dictionary:
	ProjectSettings.set_setting(INPUT_PREFIX + name, {"deadzone": deadzone, "events": events})
	return _save()


static func _erase_action(name: String) -> Dictionary:
	# A null value removes the setting; the engine drops an empty `[input]` section
	# from project.godot on save, so no orphan entry is left behind.
	ProjectSettings.set_setting(INPUT_PREFIX + name, null)
	return _save()


static func _save() -> Dictionary:
	var error := ProjectSettings.save()
	if error != OK:
		return M.err("GODOT_ERROR", "could not save project settings: %s" % error_string(error))
	return {}


static func _name_error(name: String) -> String:
	if name == "":
		return "missing `name`"
	if name.begins_with(INPUT_PREFIX):
		return "action names must not start with '%s'" % INPUT_PREFIX
	return ""


static func _deadzone_arg(args: Dictionary) -> Dictionary:
	if not args.has("deadzone") or args["deadzone"] == null:
		return {"deadzone": DEFAULT_DEADZONE}
	var value: Variant = args["deadzone"]
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return {"error": M.err("BAD_ARGS", "`deadzone` must be a number")}
	return {"deadzone": float(value)}


static func _as_int(value: Variant, what: String) -> Dictionary:
	match typeof(value):
		TYPE_INT:
			return {"value": int(value)}
		TYPE_FLOAT:
			var number := float(value)
			if is_finite(number) and number == floor(number):
				return {"value": int(number)}
	return {"error": M.err("BAD_ARGS", "`%s` must be an integer" % what)}


static func _device_arg(spec: Dictionary) -> Dictionary:
	var raw: Variant = spec.get("device", -1)
	if raw == null:
		raw = -1
	return _as_int(raw, "device")


# --- input.list --------------------------------------------------------------

static func _list(args: Dictionary) -> Dictionary:
	var only := _s(args, "action").strip_edges()
	var actions: Array = []
	for name in _action_names():
		if only != "" and String(name) != only:
			continue
		var action := _read_action(String(name))
		actions.append({
			"name": String(name),
			"deadzone": action["deadzone"],
			"events": _events_out(action["events"]),
		})
	return M.ok({"actions": actions})


static func _events_out(events: Array) -> Array:
	var out: Array = []
	for i in range(events.size()):
		out.append(_event_out(events[i], i))
	return out


# Every output event carries its index in the stored array, which is the address
# `input.event.remove` expects.
static func _event_out(event: Variant, index: int) -> Dictionary:
	if event is InputEventKey:
		var key := event as InputEventKey
		# Exactly one of keycode/physical_keycode is the DSL's shape. Neither is
		# text input; both is a binding the DSL cannot express, so both fall back
		# to raw and still round-trip.
		if (key.keycode != 0) != (key.physical_keycode != 0):
			return {
				"type": "key",
				"key": _key_name(key.keycode),
				"physical_key": _key_name(key.physical_keycode),
				"modifiers": _modifier_list(key),
				"echo": key.echo,
				"device": key.device,
				"index": index,
			}
	elif event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		return {
			"type": "mouse",
			"button": _mouse_name(mouse.button_index),
			"modifiers": _modifier_list(mouse),
			"device": mouse.device,
			"index": index,
		}
	elif event is InputEventJoypadButton:
		var button := event as InputEventJoypadButton
		return {
			"type": "joy_button",
			"button": button.button_index,
			"device": button.device,
			"index": index,
		}
	elif event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		return {
			"type": "joy_axis",
			"axis": motion.axis,
			"value": motion.axis_value,
			"device": motion.device,
			"index": index,
		}
	# Outside the DSL: the raw form round-trips through str_to_var.
	var out := {"raw": var_to_str(event), "index": index}
	return out


static func _key_name(code: int) -> Variant:
	if code == 0:
		return null
	return OS.get_keycode_string(code)


static func _mouse_name(index: int) -> Variant:
	if MOUSE_NAMES.has(index):
		return MOUSE_NAMES[index]
	return index


static func _modifier_list(event: InputEventWithModifiers) -> Array:
	var out: Array = []
	if event.shift_pressed:
		out.append("shift")
	if event.ctrl_pressed:
		out.append("ctrl")
	if event.alt_pressed:
		out.append("alt")
	if event.meta_pressed:
		out.append("meta")
	return out


# --- event spec -> InputEvent ------------------------------------------------

static func _parse_event(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {"error": M.err("BAD_ARGS", "`event` must be an object", EVENT_HINT)}
	var spec: Dictionary = raw
	if spec.has("raw") and spec["raw"] != null:
		var value: Variant = str_to_var(str(spec["raw"]))
		if not (value is InputEvent):
			return {"error": M.err("BAD_ARGS", "`raw` does not hold an InputEvent",
				"pass the text `gdcli project input list` prints")}
		return {"event": value}
	var type := _s(spec, "type").strip_edges().to_lower()
	match type:
		"key":
			return _parse_key(spec)
		"mouse":
			return _parse_mouse(spec)
		"joy_button":
			return _parse_joy_button(spec)
		"joy_axis":
			return _parse_joy_axis(spec)
		"":
			return {"error": M.err("BAD_ARGS", "event needs `type` or `raw`", EVENT_HINT)}
	return {"error": M.err("BAD_ARGS", "unknown event type '%s'" % type, EVENT_HINT)}


static func _parse_key(spec: Dictionary) -> Dictionary:
	var key_name := ""
	var physical_name := ""
	if spec.has("key") and spec["key"] != null:
		key_name = str(spec["key"]).strip_edges()
	if spec.has("physical_key") and spec["physical_key"] != null:
		physical_name = str(spec["physical_key"]).strip_edges()
	if key_name == "" and physical_name == "":
		return {"error": M.err("BAD_ARGS", "`key` or `physical_key` is required", KEY_HINT)}
	if key_name != "" and physical_name != "":
		return {"error": M.err("BAD_ARGS", "use either `key` or `physical_key`, not both", KEY_HINT)}
	var name := key_name if key_name != "" else physical_name
	var code := OS.find_keycode_from_string(name)
	# Unknown names resolve to 0 rather than raising, so 0 is the only signal.
	if code == 0:
		return {"error": M.err("BAD_ARGS", "unknown key name '%s'" % name, KEY_HINT)}

	var event := InputEventKey.new()
	if key_name != "":
		event.keycode = code
	else:
		# Layout-independent binding: physical_keycode set, keycode stays 0.
		event.physical_keycode = code

	var echo: Variant = spec.get("echo", false)
	if echo == null:
		echo = false
	if typeof(echo) != TYPE_BOOL:
		return {"error": M.err("BAD_ARGS", "`echo` must be a boolean")}
	event.echo = bool(echo)

	var modifiers := _parse_modifiers(spec.get("modifiers", null))
	if modifiers.has("error"):
		return modifiers
	var applied := _apply_modifiers(event, modifiers["list"])
	if applied.has("error"):
		return applied
	var device := _device_arg(spec)
	if device.has("error"):
		return device
	event.device = int(device["value"])
	return {"event": event}


static func _parse_mouse(spec: Dictionary) -> Dictionary:
	if not spec.has("button") or spec["button"] == null:
		return {"error": M.err("BAD_ARGS", "`button` is required", EVENT_HINT)}
	var button := -1
	var raw: Variant = spec["button"]
	if typeof(raw) == TYPE_STRING or typeof(raw) == TYPE_STRING_NAME:
		var name := String(raw).strip_edges().to_lower()
		if not MOUSE_BUTTONS.has(name):
			return {"error": M.err("BAD_ARGS", "unknown mouse button '%s'" % name,
				"expected left, right, middle, wheel_up, wheel_down, wheel_left, wheel_right, xbutton1 or xbutton2")}
		button = int(MOUSE_BUTTONS[name])
	else:
		var parsed := _as_int(raw, "button")
		if parsed.has("error"):
			return parsed
		button = int(parsed["value"])
	if button < 0:
		return {"error": M.err("BAD_ARGS", "`button` must be a button index or name")}

	var event := InputEventMouseButton.new()
	event.button_index = button
	var modifiers := _parse_modifiers(spec.get("modifiers", null))
	if modifiers.has("error"):
		return modifiers
	var applied := _apply_modifiers(event, modifiers["list"])
	if applied.has("error"):
		return applied
	var device := _device_arg(spec)
	if device.has("error"):
		return device
	event.device = int(device["value"])
	return {"event": event}


static func _parse_joy_button(spec: Dictionary) -> Dictionary:
	if not spec.has("button") or spec["button"] == null:
		return {"error": M.err("BAD_ARGS", "`button` is required", EVENT_HINT)}
	var parsed := _as_int(spec["button"], "button")
	if parsed.has("error"):
		return parsed
	var button := int(parsed["value"])
	if button < 0 or button >= JOY_BUTTON_MAX:
		return {"error": M.err("BAD_ARGS", "`button` must be in 0..%d" % (JOY_BUTTON_MAX - 1))}
	var rejected := _reject_modifiers(spec)
	if rejected.has("error"):
		return rejected
	var event := InputEventJoypadButton.new()
	event.button_index = button
	var device := _device_arg(spec)
	if device.has("error"):
		return device
	event.device = int(device["value"])
	return {"event": event}


static func _parse_joy_axis(spec: Dictionary) -> Dictionary:
	if not spec.has("axis") or spec["axis"] == null:
		return {"error": M.err("BAD_ARGS", "`axis` is required", EVENT_HINT)}
	var parsed := _as_int(spec["axis"], "axis")
	if parsed.has("error"):
		return parsed
	var axis := int(parsed["value"])
	if axis < 0 or axis >= JOY_AXIS_MAX:
		return {"error": M.err("BAD_ARGS", "`axis` must be in 0..%d" % (JOY_AXIS_MAX - 1))}
	var raw_value: Variant = spec.get("value", 0.0)
	if typeof(raw_value) != TYPE_INT and typeof(raw_value) != TYPE_FLOAT:
		return {"error": M.err("BAD_ARGS", "`value` must be a number")}
	var rejected := _reject_modifiers(spec)
	if rejected.has("error"):
		return rejected
	var event := InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = float(raw_value)
	var device := _device_arg(spec)
	if device.has("error"):
		return device
	event.device = int(device["value"])
	return {"event": event}


# Joypad events cannot carry modifiers; silently dropping them would hide a typo.
static func _reject_modifiers(spec: Dictionary) -> Dictionary:
	var raw: Variant = spec.get("modifiers", null)
	if raw == null:
		return {}
	if raw is Array and (raw as Array).is_empty():
		return {}
	if typeof(raw) == TYPE_STRING and String(raw).strip_edges() == "":
		return {}
	return {"error": M.err("BAD_ARGS", "this event type has no `modifiers`")}


static func _parse_modifiers(raw: Variant) -> Dictionary:
	var out: Array = []
	if raw == null:
		return {"list": out}
	if raw is Array:
		for item in raw:
			var token := _modifier_name(item)
			if token == "":
				return {"error": M.err("BAD_ARGS", "unknown modifier %s" % var_to_str(item),
					"expected shift, ctrl, alt or meta")}
			if not out.has(token):
				out.append(token)
		return {"list": out}
	if typeof(raw) == TYPE_STRING or typeof(raw) == TYPE_STRING_NAME:
		for part in String(raw).replace("+", ",").split(",", false):
			var trimmed := String(part).strip_edges()
			if trimmed == "":
				continue
			var token := _modifier_name(trimmed)
			if token == "":
				return {"error": M.err("BAD_ARGS", "unknown modifier '%s'" % trimmed,
					"expected shift, ctrl, alt or meta")}
			if not out.has(token):
				out.append(token)
		return {"list": out}
	return {"error": M.err("BAD_ARGS", "`modifiers` must be an array of names")}


static func _modifier_name(raw: Variant) -> String:
	if typeof(raw) != TYPE_STRING and typeof(raw) != TYPE_STRING_NAME:
		return ""
	var token := String(raw).strip_edges().to_lower()
	if MODIFIERS.has(token):
		return token
	return ""


static func _apply_modifiers(event: InputEvent, names: Array) -> Dictionary:
	if names.is_empty():
		return {}
	if not (event is InputEventWithModifiers):
		return {"error": M.err("BAD_ARGS", "this event type has no `modifiers`")}
	var with_modifiers := event as InputEventWithModifiers
	with_modifiers.shift_pressed = names.has("shift")
	with_modifiers.ctrl_pressed = names.has("ctrl")
	with_modifiers.alt_pressed = names.has("alt")
	with_modifiers.meta_pressed = names.has("meta")
	return {}


# --- input.action.* ----------------------------------------------------------

static func _action_add(args: Dictionary, opts: Dictionary) -> Dictionary:
	var name := _s(args, "name").strip_edges()
	var invalid := _name_error(name)
	if invalid != "":
		return M.err("BAD_ARGS", invalid)
	var deadzone := _deadzone_arg(args)
	if deadzone.has("error"):
		return deadzone["error"]
	if _has_action(name):
		return M.err("BAD_ARGS", "action '%s' already exists" % name, ACTIONS_HINT)

	var data := {"name": name, "deadzone": deadzone["deadzone"]}
	if _dry(opts):
		data["planned"] = [{"op": "add_action", "name": name, "deadzone": deadzone["deadzone"]}]
		return M.ok(data)

	var written := _write_action(name, deadzone["deadzone"], [])
	if written.has("error"):
		return written
	return M.ok(data)


static func _action_remove(args: Dictionary, opts: Dictionary) -> Dictionary:
	var name := _s(args, "name").strip_edges()
	if name == "":
		return M.err("BAD_ARGS", "missing `name`")
	if not _has_action(name):
		return M.err("NOT_FOUND", "action '%s' not found" % name, ACTIONS_HINT)

	var data := {}
	if _dry(opts):
		data["planned"] = [{"op": "remove_action", "name": name}]
		return M.ok(data)

	var erased := _erase_action(name)
	if erased.has("error"):
		return erased
	return M.ok(data)


static func _action_rename(args: Dictionary, opts: Dictionary) -> Dictionary:
	var from := _s(args, "from").strip_edges()
	var to := _s(args, "to").strip_edges()
	if from == "":
		return M.err("BAD_ARGS", "missing `from`")
	if to == "":
		return M.err("BAD_ARGS", "missing `to`")
	var invalid := _name_error(to)
	if invalid != "":
		return M.err("BAD_ARGS", invalid)
	if not _has_action(from):
		return M.err("NOT_FOUND", "action '%s' not found" % from, ACTIONS_HINT)
	if _has_action(to):
		return M.err("BAD_ARGS", "action '%s' already exists" % to, ACTIONS_HINT)

	var data := {"name": to}
	if _dry(opts):
		data["planned"] = [{"op": "rename_action", "from": from, "to": to}]
		return M.ok(data)

	# Move the stored value verbatim so deadzone and events survive the rename.
	var value: Variant = ProjectSettings.get_setting(INPUT_PREFIX + from)
	ProjectSettings.set_setting(INPUT_PREFIX + to, value)
	ProjectSettings.set_setting(INPUT_PREFIX + from, null)
	var saved := _save()
	if saved.has("error"):
		return saved
	return M.ok(data)


# --- input.event.* -----------------------------------------------------------

static func _event_add(args: Dictionary, opts: Dictionary) -> Dictionary:
	var action := _s(args, "action").strip_edges()
	if action == "":
		return M.err("BAD_ARGS", "missing `action`")
	if not args.has("event") or args["event"] == null:
		return M.err("BAD_ARGS", "missing `event`", EVENT_HINT)
	if not _has_action(action):
		return M.err("NOT_FOUND", "action '%s' not found" % action,
			"add it with `gdcli project input add-action %s`" % action)

	var parsed := _parse_event(args["event"])
	if parsed.has("error"):
		return parsed["error"]
	var event := parsed["event"] as InputEvent

	var entry := _read_action(action)
	# Copy before mutating: the array may be the one ProjectSettings holds.
	var events: Array = entry["events"].duplicate()
	var at := events.size()
	if args.has("index") and args["index"] != null:
		var index := _as_int(args["index"], "index")
		if index.has("error"):
			return index["error"]
		at = int(index["value"])
		if at < 0 or at > events.size():
			return M.err("BAD_ARGS", "`index` must be in 0..%d for action '%s'"
				% [events.size(), action])

	# InputEvent.is_match(other, true): same class and same binding, ignoring nothing.
	for i in range(events.size()):
		var other: Variant = events[i]
		if other is InputEvent and (other as InputEvent).is_match(event, true):
			return M.err("BAD_ARGS", "action '%s' already binds this event at index %d"
				% [action, i])

	var data := {"action": action, "index": at, "event": _event_out(event, at)}
	if _dry(opts):
		data["planned"] = [{"op": "add_event", "action": action, "index": at,
			"event": _event_out(event, at)}]
		return M.ok(data)

	events.insert(at, event)
	var written := _write_action(action, entry["deadzone"], events)
	if written.has("error"):
		return written
	return M.ok(data)


static func _event_remove(args: Dictionary, opts: Dictionary) -> Dictionary:
	var action := _s(args, "action").strip_edges()
	if action == "":
		return M.err("BAD_ARGS", "missing `action`")
	if not args.has("index") or args["index"] == null:
		return M.err("BAD_ARGS", "missing `index`")
	if not _has_action(action):
		return M.err("NOT_FOUND", "action '%s' not found" % action, ACTIONS_HINT)

	var index := _as_int(args["index"], "index")
	if index.has("error"):
		return index["error"]
	var at := int(index["value"])

	var entry := _read_action(action)
	var events: Array = entry["events"].duplicate()
	if at < 0 or at >= events.size():
		return M.err("BAD_ARGS", "`index` %d is out of range; action '%s' has %d event(s)"
			% [at, action, events.size()])

	events.remove_at(at)
	var data := {"action": action, "events": _events_out(events)}
	if _dry(opts):
		data["planned"] = [{"op": "remove_event", "action": action, "index": at}]
		return M.ok(data)

	var written := _write_action(action, entry["deadzone"], events)
	if written.has("error"):
		return written
	return M.ok(data)
