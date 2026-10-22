use serde_json::json;

use crate::commands::Call;

pub fn check(paths: &[String]) -> Call {
    Call::read("script.check", json!({ "paths": paths }))
}

pub fn open(path: &str, line: i64) -> Call {
    Call::write_no_undo("script.open", json!({ "path": path, "line": line }))
}

pub fn files() -> Call {
    Call::read("script.files", json!({}))
}

pub fn save_all() -> Call {
    Call::write_no_undo("script.save_all", json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_sends_every_path_and_is_read_only() {
        let call = check(&["res://a.gd".to_string(), "res://b.gd".to_string()]);
        assert_eq!(call.cmd, "script.check");
        assert!(!call.mutating);
        assert_eq!(call.args["paths"], json!(["res://a.gd", "res://b.gd"]));
    }

    #[test]
    fn open_carries_the_line_and_is_not_undoable() {
        let call = open("res://a.gd", 42);
        assert_eq!(call.cmd, "script.open");
        assert!(call.mutating);
        assert!(!call.undoable);
        assert_eq!(call.args["path"], "res://a.gd");
        assert_eq!(call.args["line"], 42);
    }

    #[test]
    fn files_and_save_all_map_to_their_commands() {
        let files = files();
        assert_eq!(files.cmd, "script.files");
        assert!(!files.mutating);

        let save_all = save_all();
        assert_eq!(save_all.cmd, "script.save_all");
        assert!(save_all.mutating);
        assert!(!save_all.undoable);
    }
}
