extends RefCounted

const M = preload("meta.gd")

const MAX_STEPS := 100
const DEFAULT_HISTORY_LIMIT := 20


static func register(reg: Dictionary) -> void:
	reg["editor.status"] = func(_args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _status()
	reg["editor.undo"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _step("undo", args, opts)
	reg["editor.redo"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _step("redo", args, opts)
	reg["editor.history"] = func(args: Dictionary, opts: Dictionary) -> Dictionary:
		return _history(args, opts)


static func _status() -> Dictionary:
	var root := M.edited_root()
	var open_scenes: Array = []
	for path in EditorInterface.get_open_scenes():
		open_scenes.append(String(path))
	var unsaved: Array = []
	for path in EditorInterface.get_unsaved_scenes():
		unsaved.append(String(path))
	return M.ok({
		"project": ProjectSettings.globalize_path("res://"),
		"godot": String(Engine.get_version_info()["string"]),
		"edited_scene": M.localize(root.scene_file_path) if root != null else "",
		"open_scenes": open_scenes,
		"unsaved": unsaved,
		"playing": EditorInterface.is_playing_scene(),
		"playing_scene": String(EditorInterface.get_playing_scene()),
	})


# --- undo history ------------------------------------------------------------

# Undo/redo act on the edited scene root's own history. EditorUndoRedoManager
# exposes no undo()/redo() binding; only the per-object UndoRedo does.
# Returns {"history": UndoRedo} or {"error": <envelope>}.
static func _edited_history() -> Dictionary:
	var root := M.edited_root()
	if root == null:
		return {"error": M.err("NO_SCENE", "no scene is being edited")}
	var manager := EditorInterface.get_editor_undo_redo()
	var history: UndoRedo = manager.get_history_undo_redo(manager.get_object_history_id(root))
	if history == null:
		return {"error": M.err("INTERNAL", "the edited scene has no undo history")}
	return {"history": history}


# Missing or null means `fallback`; a JSON number is truncated to int; anything
# else is a type error rather than a silent coercion.
static func _int_arg(args: Dictionary, key: String, fallback: int) -> Dictionary:
	if not args.has(key) or args[key] == null:
		return {"value": fallback}
	var raw: Variant = args[key]
	if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
		return {"error": M.err("BAD_ARGS", "`%s` must be an integer" % key)}
	return {"value": int(raw)}


static func _current_name(history: UndoRedo) -> Variant:
	if history.get_current_action() < 0:
		return null
	var name := history.get_current_action_name()
	return name if name != "" else null


static func _step(kind: String, args: Dictionary, opts: Dictionary) -> Dictionary:
	var lookup := _edited_history()
	if lookup.has("error"):
		return lookup["error"]
	var history: UndoRedo = lookup["history"]

	var parsed := _int_arg(args, "count", 1)
	if parsed.has("error"):
		return parsed["error"]
	var count := clampi(int(parsed["value"]), 1, MAX_STEPS)
	var is_undo := kind == "undo"

	# opts.undo is ignored: undoing is not itself an undoable action.
	if bool(opts.get("dry_run", false)):
		var names: Array = []
		var index := history.get_current_action()
		if not is_undo:
			index += 1
		for _i in range(count):
			if index < 0 or index >= history.get_history_count():
				break
			names.append(history.get_action_name(index))
			if is_undo:
				index -= 1
			else:
				index += 1
		return M.ok({"would_undo": names} if is_undo else {"would_redo": names})

	var done := 0
	for _i in range(count):
		if is_undo:
			if not history.has_undo():
				break
			history.undo()
		else:
			if not history.has_redo():
				break
			history.redo()
		done += 1
	if done > 0:
		# The raw UndoRedo bypasses EditorUndoRedoManager's bookkeeping, so the
		# scene is not flagged dirty by the editor itself.
		EditorInterface.mark_scene_as_unsaved()

	var data := {
		"action": _current_name(history),
		"can_undo": history.has_undo(),
		"can_redo": history.has_redo(),
		"history_count": history.get_history_count(),
	}
	data["undone" if is_undo else "redone"] = done
	return M.ok(data)


static func _history(args: Dictionary, _opts: Dictionary) -> Dictionary:
	var lookup := _edited_history()
	if lookup.has("error"):
		return lookup["error"]
	var history: UndoRedo = lookup["history"]

	var parsed := _int_arg(args, "limit", DEFAULT_HISTORY_LIMIT)
	if parsed.has("error"):
		return parsed["error"]
	var limit := maxi(0, int(parsed["value"]))
	var total := history.get_history_count()
	var current := history.get_current_action()

	# Oldest first (ascending action index), newest `limit` actions only.
	var actions: Array = []
	var index := maxi(0, total - limit)
	while index < total:
		actions.append({
			"index": index,
			"name": history.get_action_name(index),
			"current": index == current,
		})
		index += 1
	return M.ok({"count": total, "current": current, "actions": actions})
