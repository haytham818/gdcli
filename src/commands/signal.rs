use serde_json::json;

use crate::commands::Call;

/// `CONNECT_PERSIST`: serialize the connection into the scene (PROTOCOL §9).
pub const DEFAULT_FLAGS: i64 = 2;

pub fn list(target: &str, connected_only: bool) -> Call {
    Call::read(
        "signal.list",
        json!({ "target": target, "connected_only": connected_only }),
    )
}

pub fn connect(
    source: &str,
    signal: &str,
    to: &str,
    method: &str,
    flags: i64,
    allow_missing: bool,
) -> Call {
    Call::write(
        "signal.connect",
        json!({
            "source": source,
            "signal": signal,
            "to": to,
            "method": method,
            "flags": flags,
            "allow_missing": allow_missing,
        }),
    )
}

pub fn disconnect(source: &str, signal: &str, to: &str, method: &str) -> Call {
    Call::write(
        "signal.disconnect",
        json!({
            "source": source,
            "signal": signal,
            "to": to,
            "method": method,
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_persistent_connections() {
        assert_eq!(DEFAULT_FLAGS, 2);
        let call = connect(
            "Btn",
            "pressed",
            "Inst/Label",
            "set_text",
            DEFAULT_FLAGS,
            false,
        );
        assert_eq!(call.cmd, "signal.connect");
        assert!(call.mutating);
        assert!(call.undoable);
        assert_eq!(call.args["flags"], 2);
        assert_eq!(call.args["allow_missing"], false);
    }

    #[test]
    fn connect_forwards_every_argument() {
        let call = connect("Btn", "pressed", ".", "hide", 1, true);
        assert_eq!(call.args["source"], "Btn");
        assert_eq!(call.args["signal"], "pressed");
        assert_eq!(call.args["to"], ".");
        assert_eq!(call.args["method"], "hide");
        assert_eq!(call.args["flags"], 1);
        assert_eq!(call.args["allow_missing"], true);
    }

    #[test]
    fn disconnect_carries_the_full_address() {
        let call = disconnect("Btn", "pressed", "Inst/Label", "set_text");
        assert_eq!(call.cmd, "signal.disconnect");
        assert_eq!(call.args["source"], "Btn");
        assert_eq!(call.args["to"], "Inst/Label");
        assert_eq!(call.args["method"], "set_text");
    }

    #[test]
    fn list_is_read_only_and_forwards_the_filters() {
        let call = list("Main", true);
        assert_eq!(call.cmd, "signal.list");
        assert!(!call.mutating);
        assert_eq!(call.args["target"], "Main");
        assert_eq!(call.args["connected_only"], true);
    }
}
