extends RefCounted

const M = preload("meta.gd")


static func register(reg: Dictionary) -> void:
	reg["editor.status"] = func(_args: Dictionary, _opts: Dictionary) -> Dictionary:
		return _status()


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
