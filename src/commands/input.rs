//! `input.*` requests: the project's input map (PROTOCOL §13).
//!
//! The plugin owns the semantics (key names, duplicate bindings, action name
//! rules); the CLI only turns the flags into one event spec per call. Every
//! mutation goes through `ProjectSettings.save()` on the editor side and is
//! never undoable.

use serde_json::{Value, json};

use crate::commands::Call;
use crate::error::{Error, Result};

const SOURCES: &str = "--key, --physical-key, --mouse, --joy-button, --joy-axis, --json or --raw";

/// The event-source flags and their modifiers from one `add-event` call.
#[derive(Debug, Default, Clone)]
pub struct Event {
    pub key: Option<String>,
    pub physical_key: Option<String>,
    pub mouse: Option<String>,
    pub joy_button: Option<i64>,
    pub joy_axis: Option<i64>,
    pub json: Option<String>,
    pub raw: Option<String>,
    pub modifiers: Option<String>,
    pub device: Option<i64>,
    pub axis_value: Option<f64>,
}

impl Event {
    /// The one wire event spec, or a usage error when the flag combination is
    /// structurally invalid. Semantic validation belongs to the plugin.
    pub fn into_spec(self) -> Result<Value> {
        let given: Vec<&'static str> = [
            self.key.is_some().then_some("--key"),
            self.physical_key.is_some().then_some("--physical-key"),
            self.mouse.is_some().then_some("--mouse"),
            self.joy_button.is_some().then_some("--joy-button"),
            self.joy_axis.is_some().then_some("--joy-axis"),
            self.json.is_some().then_some("--json"),
            self.raw.is_some().then_some("--raw"),
        ]
        .into_iter()
        .flatten()
        .collect();

        let source = match given.as_slice() {
            [source] => *source,
            [] => {
                return Err(Error::usage(format!(
                    "add-event needs exactly one event source: {SOURCES}"
                )));
            }
            several => {
                return Err(Error::usage(format!(
                    "add-event takes exactly one event source (got {})",
                    several.join(" and ")
                )));
            }
        };

        let takes_modifiers = matches!(source, "--key" | "--physical-key" | "--mouse");
        if self.modifiers.is_some() && !takes_modifiers {
            return Err(Error::usage(format!(
                "--modifiers only applies to --key, --physical-key and --mouse (got {source})"
            )));
        }
        if self.device.is_some() && !matches!(source, "--joy-button" | "--joy-axis") {
            return Err(Error::usage(format!(
                "--device only applies to --joy-button and --joy-axis (got {source})"
            )));
        }
        if self.axis_value.is_some() && source != "--joy-axis" {
            return Err(Error::usage(format!(
                "--axis-value only applies to --joy-axis (got {source})"
            )));
        }

        let modifiers = split_modifiers(self.modifiers.as_deref());
        let spec = match source {
            "--key" => json!({
                "type": "key",
                "key": self.key.unwrap_or_default(),
                "modifiers": modifiers,
            }),
            "--physical-key" => json!({
                "type": "key",
                "physical_key": self.physical_key.unwrap_or_default(),
                "modifiers": modifiers,
            }),
            "--mouse" => json!({
                "type": "mouse",
                "button": mouse_button(self.mouse.unwrap_or_default()),
                "modifiers": modifiers,
            }),
            "--joy-button" => json!({
                "type": "joy_button",
                "button": self.joy_button.unwrap_or_default(),
                "device": self.device.unwrap_or(-1),
            }),
            "--joy-axis" => json!({
                "type": "joy_axis",
                "axis": self.joy_axis.unwrap_or_default(),
                "value": self.axis_value.unwrap_or(1.0),
                "device": self.device.unwrap_or(-1),
            }),
            "--json" => parse_json_spec(self.json.as_deref().unwrap_or_default())?,
            "--raw" => json!({ "raw": self.raw.unwrap_or_default() }),
            _ => unreachable!("one source was matched above"),
        };
        Ok(spec)
    }
}

/// `--json SPEC` is passed through as written, not re-shaped.
fn parse_json_spec(spec: &str) -> Result<Value> {
    let value: Value = serde_json::from_str(spec)
        .map_err(|error| Error::usage(format!("--json is not valid JSON: {error}")))?;
    if !value.is_object() {
        return Err(Error::usage("--json must be a JSON object"));
    }
    Ok(value)
}

/// Numbers stay numbers so the plugin reads `"button": 1`; names stay strings.
fn mouse_button(button: String) -> Value {
    match button.parse::<i64>() {
        Ok(number) => Value::from(number),
        Err(_) => Value::String(button),
    }
}

/// `shift,ctrl` → `["shift", "ctrl"]`; empty entries are dropped.
fn split_modifiers(modifiers: Option<&str>) -> Vec<String> {
    modifiers
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .map(str::to_string)
        .collect()
}

/// `project input actions`: names and deadzones, still `input.list` on the wire.
pub fn actions() -> Call {
    Call::read("input.list", json!({})).with_view("input.actions")
}

pub fn list(action: Option<&str>) -> Call {
    let args = match action {
        Some(action) => json!({ "action": action }),
        None => json!({}),
    };
    Call::read("input.list", args)
}

pub fn add_action(name: &str, deadzone: f64) -> Call {
    Call::write_no_undo(
        "input.action.add",
        json!({ "name": name, "deadzone": deadzone }),
    )
}

pub fn remove_action(name: &str) -> Call {
    Call::write_no_undo("input.action.remove", json!({ "name": name }))
}

pub fn rename_action(old: &str, new: &str) -> Call {
    Call::write_no_undo("input.action.rename", json!({ "from": old, "to": new }))
}

pub fn add_event(action: &str, event: Event) -> Result<Call> {
    Ok(Call::write_no_undo(
        "input.event.add",
        json!({ "action": action, "event": event.into_spec()? }),
    ))
}

pub fn remove_event(action: &str, index: i64) -> Result<Call> {
    if index < 0 {
        return Err(Error::usage("--index must not be negative"));
    }
    Ok(Call::write_no_undo(
        "input.event.remove",
        json!({ "action": action, "index": index }),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(event: Event) -> Value {
        event.into_spec().expect("valid event")
    }

    #[test]
    fn maps_a_logical_key() {
        let value = spec(Event {
            key: Some("Space".into()),
            ..Event::default()
        });
        assert_eq!(
            value,
            json!({"type": "key", "key": "Space", "modifiers": []})
        );
    }

    #[test]
    fn maps_a_physical_key_without_a_keycode() {
        let value = spec(Event {
            physical_key: Some("A".into()),
            ..Event::default()
        });
        assert_eq!(
            value,
            json!({"type": "key", "physical_key": "A", "modifiers": []})
        );
        assert!(value.get("key").is_none());
    }

    #[test]
    fn maps_a_named_mouse_button() {
        let value = spec(Event {
            mouse: Some("wheel_up".into()),
            ..Event::default()
        });
        assert_eq!(
            value,
            json!({"type": "mouse", "button": "wheel_up", "modifiers": []})
        );
    }

    #[test]
    fn maps_a_numeric_mouse_button_as_a_number() {
        let value = spec(Event {
            mouse: Some("3".into()),
            ..Event::default()
        });
        assert_eq!(value["button"], json!(3));
        assert!(value["button"].is_number());

        let named = spec(Event {
            mouse: Some("left".into()),
            ..Event::default()
        });
        assert_eq!(named["button"], json!("left"));
    }

    #[test]
    fn maps_a_joy_button_with_the_default_device() {
        let value = spec(Event {
            joy_button: Some(2),
            ..Event::default()
        });
        assert_eq!(
            value,
            json!({"type": "joy_button", "button": 2, "device": -1})
        );
    }

    #[test]
    fn maps_a_joy_axis_with_its_value_and_device() {
        let value = spec(Event {
            joy_axis: Some(1),
            axis_value: Some(-1.0),
            device: Some(0),
            ..Event::default()
        });
        assert_eq!(
            value,
            json!({"type": "joy_axis", "axis": 1, "value": -1.0, "device": 0})
        );
    }

    #[test]
    fn a_joy_axis_defaults_to_positive_one() {
        let value = spec(Event {
            joy_axis: Some(4),
            ..Event::default()
        });
        assert_eq!(value["value"], json!(1.0));
        assert_eq!(value["device"], json!(-1));
    }

    #[test]
    fn maps_a_json_spec_verbatim() {
        let source = r#"{"type":"key","key":"J","modifiers":["alt"],"echo":true}"#;
        let value = spec(Event {
            json: Some(source.into()),
            ..Event::default()
        });
        assert_eq!(value, serde_json::from_str::<Value>(source).unwrap());
    }

    #[test]
    fn maps_a_raw_event() {
        let value = spec(Event {
            raw: Some("Object(InputEventScreenTouch,...)".into()),
            ..Event::default()
        });
        assert_eq!(value, json!({"raw": "Object(InputEventScreenTouch,...)"}));
    }

    #[test]
    fn rejects_zero_sources() {
        let error = Event::default().into_spec().unwrap_err();
        assert_eq!(error.exit_code(), 1);
        assert!(error.message().contains("exactly one event source"));
        assert!(error.message().contains("--joy-axis"));
    }

    #[test]
    fn rejects_two_sources() {
        let error = Event {
            key: Some("Space".into()),
            mouse: Some("left".into()),
            ..Event::default()
        }
        .into_spec()
        .unwrap_err();
        assert_eq!(error.exit_code(), 1);
        assert!(error.message().contains("--key and --mouse"));
    }

    #[test]
    fn rejects_modifiers_outside_key_and_mouse() {
        for event in [
            Event {
                joy_button: Some(0),
                modifiers: Some("shift".into()),
                ..Event::default()
            },
            Event {
                raw: Some("Object()".into()),
                modifiers: Some("shift".into()),
                ..Event::default()
            },
        ] {
            let error = event.into_spec().unwrap_err();
            assert_eq!(error.exit_code(), 1);
            assert!(error.message().contains("--modifiers"));
        }
    }

    #[test]
    fn rejects_axis_value_without_a_joy_axis() {
        for event in [
            Event {
                key: Some("Space".into()),
                axis_value: Some(0.5),
                ..Event::default()
            },
            Event {
                joy_button: Some(1),
                axis_value: Some(0.5),
                ..Event::default()
            },
        ] {
            let error = event.into_spec().unwrap_err();
            assert_eq!(error.exit_code(), 1);
            assert!(error.message().contains("--axis-value"));
        }
    }

    #[test]
    fn rejects_device_outside_the_joypad_forms() {
        for event in [
            Event {
                key: Some("Space".into()),
                device: Some(0),
                ..Event::default()
            },
            Event {
                mouse: Some("left".into()),
                device: Some(0),
                ..Event::default()
            },
            Event {
                raw: Some("Object()".into()),
                device: Some(0),
                ..Event::default()
            },
        ] {
            let error = event.into_spec().unwrap_err();
            assert_eq!(error.exit_code(), 1);
            assert!(error.message().contains("--device"));
        }
    }

    #[test]
    fn splits_modifiers_and_drops_empty_entries() {
        assert_eq!(
            split_modifiers(Some("shift, ctrl,,alt,")),
            vec!["shift", "ctrl", "alt"]
        );
        assert!(split_modifiers(Some(",")).is_empty());
        assert!(split_modifiers(None).is_empty());

        let value = spec(Event {
            key: Some("Space".into()),
            modifiers: Some("shift,ctrl".into()),
            ..Event::default()
        });
        assert_eq!(value["modifiers"], json!(["shift", "ctrl"]));
    }

    #[test]
    fn rejects_invalid_json_specs() {
        for source in ["{", "[]", "42"] {
            let error = Event {
                json: Some(source.into()),
                ..Event::default()
            }
            .into_spec()
            .unwrap_err();
            assert_eq!(error.exit_code(), 1);
            assert!(error.message().contains("--json"));
        }
    }

    #[test]
    fn actions_and_list_share_the_wire_command() {
        let actions = actions();
        assert_eq!(actions.cmd, "input.list");
        assert_eq!(actions.args, json!({}));
        assert_eq!(actions.render_key(), "input.actions");
        assert!(!actions.mutating);

        let unfiltered = list(None);
        assert_eq!(unfiltered.cmd, "input.list");
        assert_eq!(unfiltered.args, json!({}));
        assert_eq!(unfiltered.render_key(), "input.list");

        let filtered = list(Some("jump"));
        assert_eq!(filtered.args, json!({ "action": "jump" }));
    }

    #[test]
    fn action_mutations_are_non_undoable() {
        let add = add_action("jump", 0.2);
        assert_eq!(add.cmd, "input.action.add");
        assert_eq!(add.args, json!({"name": "jump", "deadzone": 0.2}));
        assert!(add.mutating);
        assert!(!add.undoable);
        assert!(add.opts(true, true).unwrap().undo.is_none());

        let remove = remove_action("jump");
        assert_eq!(remove.cmd, "input.action.remove");
        assert_eq!(remove.args, json!({"name": "jump"}));
        assert!(remove.mutating);
        assert!(!remove.undoable);

        let rename = rename_action("old", "new");
        assert_eq!(rename.cmd, "input.action.rename");
        assert_eq!(rename.args, json!({"from": "old", "to": "new"}));
        assert!(rename.mutating);
        assert!(!rename.undoable);
    }

    #[test]
    fn add_event_carries_one_spec() {
        let call = add_event(
            "jump",
            Event {
                key: Some("Space".into()),
                ..Event::default()
            },
        )
        .unwrap();
        assert_eq!(call.cmd, "input.event.add");
        assert_eq!(call.args["action"], "jump");
        assert_eq!(
            call.args["event"],
            json!({"type": "key", "key": "Space", "modifiers": []})
        );
        assert!(call.mutating);
        assert!(!call.undoable);
        assert!(call.opts(true, true).unwrap().undo.is_none());

        let error = add_event("jump", Event::default()).unwrap_err();
        assert_eq!(error.exit_code(), 1);
    }

    #[test]
    fn remove_event_forwards_the_index() {
        let call = remove_event("jump", 3).unwrap();
        assert_eq!(call.cmd, "input.event.remove");
        assert_eq!(call.args, json!({"action": "jump", "index": 3}));
        assert!(call.mutating);
        assert!(!call.undoable);

        let error = remove_event("jump", -1).unwrap_err();
        assert_eq!(error.exit_code(), 1);
        assert!(error.message().contains("--index"));
    }

    #[test]
    fn dry_run_reaches_the_plugin_without_undo() {
        let call = add_action("jump", 0.5);
        let opts = call.opts(true, true).expect("mutating commands carry opts");
        assert_eq!(opts.undo, None);
        assert!(opts.dry_run);
    }
}
