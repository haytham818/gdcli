//! `game.*` requests: read-only views of the running game's debug sessions.

use serde_json::json;

use crate::commands::Call;
use crate::error::{Error, Result};

pub fn status() -> Call {
    Call::read("game.status", json!({}))
}

/// The last `limit` log lines; `clear` empties the ring buffer afterwards.
pub fn logs(limit: i64, clear: bool) -> Result<Call> {
    if limit < 0 {
        return Err(Error::usage("--limit must not be negative"));
    }
    Ok(Call::read(
        "game.logs",
        json!({ "limit": limit, "clear": clear }),
    ))
}

pub fn clear() -> Call {
    Call::write_no_undo("game.clear", json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_is_read_only() {
        let call = status();
        assert_eq!(call.cmd, "game.status");
        assert!(!call.mutating);
        assert!(call.opts(true, true).is_none());
    }

    #[test]
    fn logs_forwards_limit_and_clear() {
        let call = logs(50, true).unwrap();
        assert_eq!(call.cmd, "game.logs");
        assert!(!call.mutating);
        assert_eq!(call.args["limit"], 50);
        assert_eq!(call.args["clear"], true);
        assert!(call.opts(true, true).is_none());
    }

    #[test]
    fn logs_rejects_a_negative_limit() {
        assert!(logs(-1, false).is_err());
        assert!(logs(0, false).is_ok());
    }

    #[test]
    fn clear_is_a_non_undoable_mutation() {
        let call = clear();
        assert_eq!(call.cmd, "game.clear");
        assert!(call.mutating);
        assert!(!call.undoable);
        assert!(call.opts(true, true).unwrap().undo.is_none());
    }
}
