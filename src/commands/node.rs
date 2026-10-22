use serde_json::{Value, json};

use crate::commands::Call;
use crate::error::{Error, Result};

/// Exactly one of `<type>` or `--script` identifies the node (PROTOCOL §7).
pub fn add(
    node_type: Option<&str>,
    script: Option<&str>,
    parent: Option<&str>,
    name: Option<&str>,
    index: Option<i64>,
) -> Result<Call> {
    if node_type.is_some() == script.is_some() {
        return Err(Error::usage(
            "node add takes either a node type or --script SCRIPT, not both",
        ));
    }

    let mut args = json!({});
    if let Some(node_type) = node_type {
        args["type"] = Value::String(node_type.to_string());
    }
    if let Some(script) = script {
        args["script"] = Value::String(script.to_string());
    }
    if let Some(parent) = parent {
        args["parent"] = Value::String(parent.to_string());
    }
    if let Some(name) = name {
        args["name"] = Value::String(name.to_string());
    }
    if let Some(index) = index {
        args["index"] = json!(index);
    }
    Ok(Call::write("node.add", args))
}

pub fn remove(path: &str) -> Call {
    Call::write("node.rm", json!({ "path": path }))
}

pub fn mv(path: &str, to: &str, index: Option<i64>) -> Call {
    let mut args = json!({ "path": path, "to": to });
    if let Some(index) = index {
        args["index"] = json!(index);
    }
    Call::write("node.mv", args)
}

pub fn dup(path: &str, name: Option<&str>) -> Call {
    let mut args = json!({ "path": path });
    if let Some(name) = name {
        args["name"] = Value::String(name.to_string());
    }
    Call::write("node.dup", args)
}

pub fn rename(path: &str, name: &str) -> Call {
    Call::write("node.rename", json!({ "path": path, "name": name }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_requires_exactly_one_kind() {
        assert!(add(None, None, None, None, None).is_err());
        assert!(add(Some("Sprite2D"), Some("res://hero.gd"), None, None, None).is_err());
        assert!(add(Some("Sprite2D"), None, None, None, None).is_ok());
        assert!(add(None, Some("res://hero.gd"), None, None, None).is_ok());
    }

    #[test]
    fn add_forwards_the_placement_flags() {
        let call = add(Some("Sprite2D"), None, Some("Main"), Some("Hero"), Some(1)).unwrap();
        assert_eq!(call.cmd, "node.add");
        assert!(call.mutating);
        assert_eq!(call.args["type"], "Sprite2D");
        assert_eq!(call.args["parent"], "Main");
        assert_eq!(call.args["name"], "Hero");
        assert_eq!(call.args["index"], 1);
        assert!(call.args.get("script").is_none());
    }

    #[test]
    fn mv_forwards_the_new_parent_and_index() {
        let call = mv("Main/Hero", "Main", Some(2));
        assert_eq!(call.args["to"], "Main");
        assert_eq!(call.args["index"], 2);
    }

    #[test]
    fn dup_omits_an_absent_name() {
        let call = dup("Main/Hero", None);
        assert!(call.args.get("name").is_none());
    }
}
