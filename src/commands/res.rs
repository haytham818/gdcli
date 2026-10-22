use serde_json::json;

use crate::commands::Call;

pub fn new(resource_type: &str, path: &str) -> Call {
    Call::write_no_undo("res.new", json!({ "type": resource_type, "path": path }))
}

pub fn info(path: &str) -> Call {
    Call::read("res.info", json!({ "path": path }))
}

pub fn duplicate(from: &str, to: &str) -> Call {
    Call::write_no_undo("res.duplicate", json!({ "from": from, "to": to }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_carries_the_type_and_path() {
        let call = new("Theme", "res://ui/theme.tres");
        assert_eq!(call.cmd, "res.new");
        assert!(call.mutating);
        assert!(!call.undoable);
        assert_eq!(call.args["type"], "Theme");
        assert_eq!(call.args["path"], "res://ui/theme.tres");
    }

    #[test]
    fn info_is_read_only() {
        let call = info("res://ui/theme.tres");
        assert_eq!(call.cmd, "res.info");
        assert!(!call.mutating);
        assert_eq!(call.args["path"], "res://ui/theme.tres");
    }

    #[test]
    fn duplicate_carries_both_paths() {
        let call = duplicate("res://a.tres", "res://b.tres");
        assert_eq!(call.cmd, "res.duplicate");
        assert!(call.mutating);
        assert!(!call.undoable);
        assert_eq!(call.args["from"], "res://a.tres");
        assert_eq!(call.args["to"], "res://b.tres");
    }

    #[test]
    fn non_undoable_writes_omit_undo_but_keep_dry_run() {
        let opts = duplicate("res://a.tres", "res://b.tres").opts(true, true);
        assert_eq!(
            serde_json::to_value(opts.unwrap()).unwrap(),
            json!({ "dry_run": true })
        );
    }
}
