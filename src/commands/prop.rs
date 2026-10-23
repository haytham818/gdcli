use serde_json::{Value, json};

use crate::commands::Call;

pub fn list(target: &str, filter: Option<&str>, changed: bool, all: bool) -> Call {
    let mut args = json!({ "target": target, "changed": changed });
    if all {
        args["all"] = Value::Bool(true);
    }
    if let Some(filter) = filter {
        args["filter"] = Value::String(filter.to_string());
    }
    Call::read("prop.list", args)
}

pub fn get(target: &str, name: &str) -> Call {
    Call::read("prop.get", json!({ "target": target, "name": name }))
}

/// `mode` is one of `gd`, `json`, `ref`, `expr` (PROTOCOL §6).
pub fn set(target: &str, name: &str, value: &str, mode: &str) -> Call {
    Call::write(
        "prop.set",
        json!({ "target": target, "name": name, "value": value, "as": mode }),
    )
}

pub fn reset(target: &str, name: &str) -> Call {
    Call::write("prop.reset", json!({ "target": target, "name": name }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_sends_the_all_flag_only_when_asked() {
        assert!(list("Main", None, false, false).args.get("all").is_none());
        assert_eq!(list("Main", None, false, true).args["all"], true);
    }

    #[test]
    fn set_forwards_the_value_and_its_parser() {
        let call = set("Main/Hero", "position", "Vector2(10, 20)", "gd");
        assert_eq!(call.cmd, "prop.set");
        assert!(call.mutating);
        assert_eq!(call.args["value"], "Vector2(10, 20)");
        assert_eq!(call.args["as"], "gd");

        let call = set("res://theme.tres", "default_font_size", "16", "json");
        assert_eq!(call.args["as"], "json");
    }

    #[test]
    fn list_omits_an_absent_filter_and_forwards_changed() {
        let call = list("Main", None, true, false);
        assert_eq!(call.cmd, "prop.list");
        assert!(!call.mutating);
        assert_eq!(call.args["changed"], true);
        assert!(call.args.get("filter").is_none());

        assert_eq!(
            list("Main", Some("visible"), false, false).args["filter"],
            "visible"
        );
    }

    #[test]
    fn reset_is_a_mutating_command() {
        let call = reset("Main", "visible");
        assert_eq!(call.cmd, "prop.reset");
        assert!(call.mutating);
    }
}
