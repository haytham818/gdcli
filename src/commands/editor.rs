use serde_json::json;

use crate::commands::Call;
use crate::error::{Error, Result};

/// Both ends clamp: the plugin repeats the clamp, the CLI fails fast on nonsense.
const MAX_COUNT: i64 = 100;

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

fn clamp_count(count: i64) -> i64 {
    count.clamp(1, MAX_COUNT)
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
