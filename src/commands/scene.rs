use serde_json::json;

use crate::commands::Call;

pub fn open(resource: &str) -> Call {
    Call::write("scene.open", json!({ "path": resource }))
}

pub fn save() -> Call {
    Call::write("scene.save", json!({}))
}

pub fn save_as(resource: &str) -> Call {
    Call::write("scene.save_as", json!({ "path": resource }))
}

pub fn reload(resource: Option<&str>) -> Call {
    match resource {
        Some(path) => Call::write("scene.reload", json!({ "path": path })),
        None => Call::write("scene.reload", json!({})),
    }
}

pub fn roots() -> Call {
    Call::read("scene.roots", json!({}))
}

pub fn tree(depth: u32, props: bool) -> Call {
    Call::read("scene.tree", json!({ "depth": depth, "props": props }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn save_as_sends_the_target_path() {
        let call = save_as("res://other.tscn");
        assert_eq!(call.cmd, "scene.save_as");
        assert_eq!(call.args["path"], "res://other.tscn");
    }

    #[test]
    fn tree_defaults_to_unlimited_depth_without_props() {
        let call = tree(0, false);
        assert_eq!(call.cmd, "scene.tree");
        assert_eq!(call.args["depth"], 0);
        assert_eq!(call.args["props"], false);
        assert!(!call.mutating);
    }

    #[test]
    fn reload_without_a_path_is_an_empty_request() {
        assert_eq!(reload(None).args, json!({}));
        assert_eq!(
            reload(Some("res://main.tscn")).args["path"],
            "res://main.tscn"
        );
    }
}
