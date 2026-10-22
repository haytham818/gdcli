use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::client::Client;
use crate::commands::{Call, absolute_output};
use crate::error::{Error, Result};

/// Both ends clamp: the plugin repeats the clamp, the CLI fails fast on nonsense.
const MAX_COUNT: i64 = 100;

/// Poll cadence used by `editor play --wait`.
pub const PLAY_POLL_INTERVAL: Duration = Duration::from_millis(200);
/// Total budget for `editor play --wait`.
pub const PLAY_DEADLINE: Duration = Duration::from_secs(30);

pub fn status() -> Call {
    Call::read("editor.status", json!({}))
}

/// Undo `count` actions of the edited scene's history.
pub fn undo(count: i64) -> Call {
    Call::history("editor.undo", json!({ "count": clamp_count(count) }))
}

/// Redo `count` actions of the edited scene's history.
pub fn redo(count: i64) -> Call {
    Call::history("editor.redo", json!({ "count": clamp_count(count) }))
}

/// List the edited scene's undo history, oldest first.
pub fn history(limit: i64) -> Result<Call> {
    if limit < 1 {
        return Err(Error::usage("--limit must be at least 1"));
    }
    Ok(Call::read("editor.history", json!({ "limit": limit })))
}

/// Select 1..N nodes in the editor; without `add` the selection is replaced.
pub fn select(paths: &[String], add: bool) -> Call {
    Call::write_no_undo("editor.select", json!({ "paths": paths, "add": add }))
}

/// Open a node in the inspector.
pub fn inspect(target: &str) -> Call {
    Call::write_no_undo("editor.inspect", json!({ "target": target }))
}

/// Switch the editor's main screen.
pub fn main_screen(name: &str) -> Call {
    Call::write_no_undo("editor.main_screen", json!({ "name": name }))
}

/// Show a toast notification in the editor.
pub fn toast(message: &str) -> Call {
    Call::write_no_undo("editor.toast", json!({ "message": message }))
}

/// Save a screenshot; the plugin writes the PNG, so only its path crosses the wire.
pub fn screenshot(viewport: &str, out: &Path) -> Result<Call> {
    Ok(Call::write_no_undo(
        "editor.screenshot",
        json!({ "viewport": viewport, "path": absolute_output(out)? }),
    ))
}

/// Start playing the project. `--scene` only makes sense with `--mode scene`.
pub fn play(mode: &str, scene: Option<&str>) -> Result<Call> {
    if scene.is_some() && mode != "scene" {
        return Err(Error::usage("--scene is only valid with --mode scene"));
    }
    let mut args = json!({ "mode": mode });
    if let Some(scene) = scene {
        args["scene"] = json!(scene);
    }
    Ok(Call::write_no_undo("editor.play", args))
}

/// Stop the running game; idempotent on the plugin side.
pub fn stop() -> Call {
    Call::write_no_undo("editor.stop", json!({}))
}

fn clamp_count(count: i64) -> i64 {
    count.clamp(1, MAX_COUNT)
}

/// One `editor.status` payload's play state.
fn playing(data: &Value) -> bool {
    data.get("playing")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// Polls `editor.status` until the game is playing. `poll` and `deadline` are
/// parameters so the state machine runs against a fake in tests.
pub fn wait_for_play<S>(poll: Duration, deadline: Duration, mut status: S) -> Result<()>
where
    S: FnMut() -> Result<bool>,
{
    let start = Instant::now();
    loop {
        if status()? {
            return Ok(());
        }
        if start.elapsed() >= deadline {
            return Err(Error::command(
                "GODOT_ERROR",
                format!(
                    "the editor did not start playing within {} s",
                    deadline.as_secs()
                ),
                Some(
                    "check the editor for a failed launch; `gdcli editor status` reports play state",
                ),
            ));
        }
        thread::sleep(poll);
    }
}

/// `--wait` against a live connection.
pub fn wait(client: &mut Client) -> Result<()> {
    wait_for_play(PLAY_POLL_INTERVAL, PLAY_DEADLINE, || {
        client
            .call("editor.status", &json!({}), None)
            .map(|data| playing(&data))
    })
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
            "gdcli-editor-test-{}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst),
            label
        ));
        fs::create_dir_all(&path).expect("create temp dir");
        path
    }

    #[test]
    fn undo_and_redo_default_to_one_action() {
        assert_eq!(undo(1).args["count"], 1);
        assert_eq!(redo(1).args["count"], 1);
    }

    #[test]
    fn count_is_clamped_to_the_protocol_range() {
        assert_eq!(undo(0).args["count"], 1);
        assert_eq!(undo(-7).args["count"], 1);
        assert_eq!(undo(42).args["count"], 42);
        assert_eq!(undo(101).args["count"], 100);
        assert_eq!(redo(1000).args["count"], 100);
    }

    #[test]
    fn undo_and_redo_send_dry_run_without_an_undo_flag() {
        let call = undo(2);
        assert_eq!(call.cmd, "editor.undo");
        assert!(call.mutating);
        assert!(!call.undoable);

        let opts = call.opts(true, true).unwrap();
        assert_eq!(
            serde_json::to_value(opts).unwrap(),
            serde_json::json!({ "dry_run": true })
        );

        let opts = redo(2).opts(true, false).unwrap();
        assert_eq!(
            serde_json::to_value(opts).unwrap(),
            serde_json::json!({ "dry_run": false })
        );
    }

    #[test]
    fn history_is_read_only_and_forwards_the_limit() {
        let call = history(20).unwrap();
        assert_eq!(call.cmd, "editor.history");
        assert!(!call.mutating);
        assert_eq!(call.args["limit"], 20);
        assert!(call.opts(true, true).is_none());
    }

    #[test]
    fn history_rejects_a_limit_below_one() {
        assert!(history(0).is_err());
        assert!(history(-1).is_err());
    }

    #[test]
    fn select_and_inspect_are_not_undoable() {
        let select = select(&["Main".to_string(), "Main/Inst".to_string()], true);
        assert_eq!(select.cmd, "editor.select");
        assert_eq!(select.args["paths"], json!(["Main", "Main/Inst"]));
        assert_eq!(select.args["add"], true);
        assert!(select.mutating);
        assert!(!select.undoable);
        assert!(select.opts(true, true).unwrap().undo.is_none());

        let inspect = inspect("Main/Inst");
        assert_eq!(inspect.cmd, "editor.inspect");
        assert_eq!(inspect.args["target"], "Main/Inst");
        assert!(inspect.mutating);
        assert!(!inspect.undoable);
        assert!(inspect.opts(true, true).unwrap().undo.is_none());
    }

    #[test]
    fn select_clears_the_selection_by_default() {
        assert_eq!(select(&["Main".to_string()], false).args["add"], false);
    }

    #[test]
    fn main_screen_and_toast_forward_their_argument() {
        let main_screen = main_screen("3d");
        assert_eq!(main_screen.cmd, "editor.main_screen");
        assert_eq!(main_screen.args["name"], "3d");
        assert!(main_screen.mutating);
        assert!(!main_screen.undoable);

        let toast = toast("saved");
        assert_eq!(toast.cmd, "editor.toast");
        assert_eq!(toast.args["message"], "saved");
        assert!(toast.mutating);
        assert!(!toast.undoable);
    }

    #[test]
    fn play_defaults_are_validated_and_forwarded() {
        let call = play("main", None).unwrap();
        assert_eq!(call.cmd, "editor.play");
        assert_eq!(call.args["mode"], "main");
        assert!(call.args.get("scene").is_none());
        assert!(call.mutating);
        assert!(!call.undoable);
        assert!(call.opts(true, true).unwrap().undo.is_none());

        let scene = play("scene", Some("res://main.tscn")).unwrap();
        assert_eq!(scene.args["mode"], "scene");
        assert_eq!(scene.args["scene"], "res://main.tscn");
    }

    #[test]
    fn scene_requires_scene_mode() {
        let error = play("main", Some("res://main.tscn")).unwrap_err();
        assert_eq!(error.exit_code(), 1);
        assert!(error.message().contains("--mode scene"));

        let error = play("current", Some("res://main.tscn")).unwrap_err();
        assert_eq!(error.exit_code(), 1);
    }

    #[test]
    fn stop_is_a_non_undoable_mutation() {
        let stop = stop();
        assert_eq!(stop.cmd, "editor.stop");
        assert!(stop.mutating);
        assert!(!stop.undoable);
        assert_eq!(stop.args, json!({}));
    }

    #[test]
    fn screenshot_resolves_the_output_under_its_parent() {
        let root = temp_dir("screenshot");
        let out = root.join("nest/deeper/shot.png");

        let call = screenshot("2d", &out).unwrap();
        let expected = fs::canonicalize(root.join("nest/deeper"))
            .unwrap()
            .join("shot.png");
        assert_eq!(call.cmd, "editor.screenshot");
        assert_eq!(call.args["viewport"], "2d");
        assert_eq!(call.args["path"], expected.to_string_lossy().as_ref());
        assert!(expected.is_absolute());
        assert!(root.join("nest/deeper").is_dir());

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn screenshot_resolves_a_bare_file_name_in_the_current_directory() {
        let call = screenshot("whole", Path::new("shot.png")).unwrap();
        let expected = env::current_dir().unwrap().join("shot.png");
        assert_eq!(call.args["path"], expected.to_string_lossy().as_ref());
    }

    #[test]
    fn screenshot_rejects_a_path_without_a_file_name() {
        assert!(screenshot("2d", Path::new("/")).is_err());
    }

    #[test]
    fn wait_stops_at_the_first_playing_status() {
        let mut remaining = [false, false, true].into_iter();
        let mut polls = 0;
        wait_for_play(Duration::ZERO, PLAY_DEADLINE, || {
            polls += 1;
            Ok(remaining.next().expect("the poller asked too often"))
        })
        .unwrap();
        assert_eq!(polls, 3);
    }

    #[test]
    fn wait_returns_at_once_when_already_playing() {
        let mut polls = 0;
        wait_for_play(Duration::ZERO, PLAY_DEADLINE, || {
            polls += 1;
            Ok(true)
        })
        .unwrap();
        assert_eq!(polls, 1);
    }

    #[test]
    fn wait_times_out_with_a_command_error() {
        let error = wait_for_play(Duration::ZERO, Duration::ZERO, || Ok(false)).unwrap_err();
        assert_eq!(error.exit_code(), 3);
        assert!(error.message().contains("GODOT_ERROR"));
        assert!(error.message().contains("did not start playing"));
    }

    #[test]
    fn wait_propagates_poll_errors() {
        let error = wait_for_play(Duration::ZERO, PLAY_DEADLINE, || {
            Err(Error::not_connected("gone"))
        })
        .unwrap_err();
        assert_eq!(error.exit_code(), 2);
    }

    #[test]
    fn play_wait_uses_the_documented_cadence_and_deadline() {
        assert_eq!(PLAY_POLL_INTERVAL, Duration::from_millis(200));
        assert_eq!(PLAY_DEADLINE, Duration::from_secs(30));
    }
}
