use serde_json::json;

use crate::commands::Call;

pub fn setting_get(key: &str) -> Call {
    Call::read("project.setting.get", json!({ "key": key }))
}

/// `mode` is one of `gd`, `json`, `ref`, `expr` (PROTOCOL §6, §9).
pub fn setting_set(key: &str, value: &str, mode: &str) -> Call {
    Call::write_no_undo(
        "project.setting.set",
        json!({ "key": key, "value": value, "as": mode }),
    )
}

pub fn autoload_list() -> Call {
    Call::read("project.autoload.list", json!({}))
}

pub fn autoload_add(name: &str, path: &str) -> Call {
    Call::write_no_undo(
        "project.autoload.add",
        json!({ "name": name, "path": path }),
    )
}

pub fn autoload_remove(name: &str) -> Call {
    Call::write_no_undo("project.autoload.remove", json!({ "name": name }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setting_get_is_read_only() {
        let call = setting_get("application/config/name");
        assert_eq!(call.cmd, "project.setting.get");
        assert!(!call.mutating);
        assert_eq!(call.args["key"], "application/config/name");
    }

    #[test]
    fn setting_set_forwards_the_parser() {
        let call = setting_set("display/window/size/viewport_width", "1280", "json");
        assert_eq!(call.cmd, "project.setting.set");
        assert!(call.mutating);
        assert!(!call.undoable);
        assert_eq!(call.args["key"], "display/window/size/viewport_width");
        assert_eq!(call.args["value"], "1280");
        assert_eq!(call.args["as"], "json");
    }

    #[test]
    fn autoload_commands_are_not_undoable() {
        let list = autoload_list();
        assert_eq!(list.cmd, "project.autoload.list");
        assert!(!list.mutating);

        let add = autoload_add("Game", "res://game.gd");
        assert_eq!(add.cmd, "project.autoload.add");
        assert_eq!(add.args["name"], "Game");
        assert_eq!(add.args["path"], "res://game.gd");
        assert!(!add.undoable);

        let remove = autoload_remove("Game");
        assert_eq!(remove.cmd, "project.autoload.remove");
        assert_eq!(remove.args["name"], "Game");
        assert!(!remove.undoable);
    }
}
