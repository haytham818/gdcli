use serde_json::json;

use crate::commands::Call;

pub fn status() -> Call {
    Call::read("editor.status", json!({}))
}
