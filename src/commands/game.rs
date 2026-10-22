//! `game.*` requests: the running game's debug sessions, logs and live tree.
//!
//! `game.ping`, `game.tree`, `game.get`, `game.set` and `game.eval` need the
//! `GdcliRuntime` autoload installed by `gdcli runtime install`.

use std::path::Path;

use serde_json::{Value, json};

use crate::commands::{Call, absolute_output};
use crate::error::{Error, Result};

pub fn status() -> Call {
    Call::read("game.status", json!({}))
}

/// The last `limit` log lines; `clear` empties the ring buffer afterwards.
/// `kind` filters by entry kind on the plugin side and is omitted when absent.
pub fn logs(limit: i64, clear: bool, kind: Option<&str>) -> Result<Call> {
    if limit < 0 {
        return Err(Error::usage("--limit must not be negative"));
    }
    let mut args = json!({ "limit": limit, "clear": clear });
    if let Some(kind) = kind {
        args["kind"] = Value::String(kind.to_string());
    }
    Ok(Call::read("game.logs", args))
}

pub fn clear() -> Call {
    Call::write_no_undo("game.clear", json!({}))
}

/// Asks the running game for its runtime version, scene and frame rate.
pub fn ping() -> Call {
    Call::read("game.ping", json!({}))
}

/// The live scene tree; `depth: 0` is unlimited.
pub fn tree(depth: u32, props: bool) -> Call {
    Call::read("game.tree", json!({ "depth": depth, "props": props }))
}

pub fn get(path: &str, name: &str) -> Call {
    Call::read("game.get", json!({ "path": path, "name": name }))
}

/// `mode` is one of `gd`, `json`, `ref` (PROTOCOL §11). `expr` is deliberately
/// rejected: `game.eval` is the explicit way to run code inside the game.
pub fn set(path: &str, name: &str, value: &str, mode: &str) -> Result<Call> {
    if !matches!(mode, "gd" | "json" | "ref") {
        return Err(Error::usage(format!(
            "--as must be gd, json or ref for game set (got '{mode}')"
        )));
    }
    Ok(Call::write_no_undo(
        "game.set",
        json!({ "path": path, "name": name, "value": value, "as": mode }),
    ))
}

/// Save a screenshot of the running game; the runtime writes the PNG itself
/// (PROTOCOL §12), so only its path crosses the wire.
pub fn screenshot(out: &Path) -> Result<Call> {
    Ok(Call::write_no_undo(
        "game.screenshot",
        json!({ "path": absolute_output(out)? }),
    ))
}

/// Evaluates an arbitrary GDScript expression inside the running game.
///
/// **Dangerous**: this runs arbitrary code in the game process, with the node at
/// `path` (or no node) as the base instance. It is never implicit and is not
/// undoable. There is no confirmation prompt by design.
pub fn eval(expr: &str, path: Option<&str>) -> Call {
    let mut args = json!({ "expr": expr });
    if let Some(path) = path {
        args["path"] = Value::String(path.to_string());
    }
    Call::read("game.eval", args)
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn temp_dir(label: &str) -> PathBuf {
        let mut path = env::temp_dir();
        path.push(format!(
            "gdcli-game-test-{}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst),
            label
        ));
        fs::create_dir_all(&path).expect("create temp dir");
        path
    }

    #[test]
    fn status_is_read_only() {
        let call = status();
        assert_eq!(call.cmd, "game.status");
        assert!(!call.mutating);
        assert!(call.opts(true, true).is_none());
    }

    #[test]
    fn logs_forwards_limit_and_clear() {
        let call = logs(50, true, None).unwrap();
        assert_eq!(call.cmd, "game.logs");
        assert!(!call.mutating);
        assert_eq!(call.args["limit"], 50);
        assert_eq!(call.args["clear"], true);
        assert!(call.args.get("kind").is_none());
        assert!(call.opts(true, true).is_none());
    }

    #[test]
    fn logs_forwards_the_three_kinds() {
        for kind in ["output", "error", "warning"] {
            let call = logs(200, false, Some(kind)).unwrap();
            assert_eq!(call.args["kind"], kind);
        }
    }

    #[test]
    fn logs_rejects_a_negative_limit() {
        assert!(logs(-1, false, None).is_err());
        assert!(logs(0, false, None).is_ok());
    }

    #[test]
    fn clear_is_a_non_undoable_mutation() {
        let call = clear();
        assert_eq!(call.cmd, "game.clear");
        assert!(call.mutating);
        assert!(!call.undoable);
        assert!(call.opts(true, true).unwrap().undo.is_none());
    }

    #[test]
    fn ping_and_tree_are_read_only() {
        let ping = ping();
        assert_eq!(ping.cmd, "game.ping");
        assert!(!ping.mutating);
        assert_eq!(ping.args, json!({}));

        let shallow = tree(0, false);
        assert_eq!(shallow.cmd, "game.tree");
        assert!(!shallow.mutating);
        assert_eq!(shallow.args["depth"], 0);
        assert_eq!(shallow.args["props"], false);

        let deep = tree(3, true);
        assert_eq!(deep.args["depth"], 3);
        assert_eq!(deep.args["props"], true);
    }

    #[test]
    fn get_maps_the_prop_to_name() {
        let call = get("Hero", "position");
        assert_eq!(call.cmd, "game.get");
        assert!(!call.mutating);
        assert_eq!(call.args["path"], "Hero");
        assert_eq!(call.args["name"], "position");
        assert!(call.args.get("prop").is_none());
    }

    #[test]
    fn set_is_a_non_undoable_mutation_with_the_value_mode() {
        let call = set("Hero", "position", "Vector2(1, 2)", "gd").unwrap();
        assert_eq!(call.cmd, "game.set");
        assert!(call.mutating);
        assert!(!call.undoable);
        assert_eq!(call.args["path"], "Hero");
        assert_eq!(call.args["name"], "position");
        assert_eq!(call.args["value"], "Vector2(1, 2)");
        assert_eq!(call.args["as"], "gd");
        assert!(call.opts(true, true).unwrap().undo.is_none());
    }

    #[test]
    fn set_accepts_only_gd_json_and_ref() {
        for mode in ["gd", "json", "ref"] {
            assert!(set("Hero", "position", "1", mode).is_ok());
        }
        for mode in ["expr", "bogus"] {
            let error = set("Hero", "position", "1", mode).unwrap_err();
            assert_eq!(error.exit_code(), 1);
            assert!(error.message().contains("--as"));
        }
    }

    #[test]
    fn screenshot_resolves_the_output_under_its_parent() {
        let root = temp_dir("screenshot");
        let out = root.join("nest/deeper/shot.png");

        let call = screenshot(&out).unwrap();
        let expected = fs::canonicalize(root.join("nest/deeper"))
            .unwrap()
            .join("shot.png");
        assert_eq!(call.cmd, "game.screenshot");
        assert_eq!(call.args["path"], expected.to_string_lossy().as_ref());
        assert!(expected.is_absolute());
        assert!(root.join("nest/deeper").is_dir());
        assert!(call.mutating);
        assert!(!call.undoable);
        assert!(call.opts(true, true).unwrap().undo.is_none());

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn screenshot_resolves_a_bare_file_name_in_the_current_directory() {
        let call = screenshot(Path::new("shot.png")).unwrap();
        let expected = env::current_dir().unwrap().join("shot.png");
        assert_eq!(call.args["path"], expected.to_string_lossy().as_ref());
    }

    #[test]
    fn screenshot_rejects_a_path_without_a_file_name() {
        assert!(screenshot(Path::new("/")).is_err());
    }

    #[test]
    fn eval_forwards_the_expression_and_optional_base_path() {
        let call = eval("fps", None);
        assert_eq!(call.cmd, "game.eval");
        assert!(!call.mutating);
        assert_eq!(call.args["expr"], "fps");
        assert!(call.args.get("path").is_none());

        let call = eval("position.x", Some("Hero"));
        assert_eq!(call.args["expr"], "position.x");
        assert_eq!(call.args["path"], "Hero");
        assert!(call.opts(true, true).is_none());
    }
}
