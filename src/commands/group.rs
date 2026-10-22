use serde_json::json;

use crate::commands::Call;

pub fn list(target: &str, builtin: bool) -> Call {
    Call::read(
        "group.list",
        json!({ "target": target, "builtin": builtin }),
    )
}

pub fn add(target: &str, group: &str) -> Call {
    Call::write("group.add", json!({ "target": target, "group": group }))
}

pub fn remove(target: &str, group: &str) -> Call {
    Call::write("group.remove", json!({ "target": target, "group": group }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_forwards_the_builtin_flag() {
        let call = list("Main", true);
        assert_eq!(call.cmd, "group.list");
        assert!(!call.mutating);
        assert_eq!(call.args["target"], "Main");
        assert_eq!(call.args["builtin"], true);
        assert_eq!(list("Main", false).args["builtin"], false);
    }

    #[test]
    fn add_and_remove_are_undoable_writes() {
        let add = add("Main/Hero", "enemies");
        assert_eq!(add.cmd, "group.add");
        assert!(add.mutating);
        assert!(add.undoable);
        assert_eq!(add.args["target"], "Main/Hero");
        assert_eq!(add.args["group"], "enemies");

        let remove = remove("Main/Hero", "enemies");
        assert_eq!(remove.cmd, "group.remove");
        assert!(remove.mutating);
        assert!(remove.undoable);
        assert_eq!(remove.args["group"], "enemies");
    }
}
