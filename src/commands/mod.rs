//! Thin mappers from CLI arguments to wire requests. No rendering here.

pub mod batch;
pub mod editor;
pub mod node;
pub mod plugin;
pub mod prop;
pub mod raw;
pub mod scene;

use serde_json::Value;

/// One wire request plus whether the undo/dry-run options apply to it.
pub struct Call {
    pub cmd: String,
    pub args: Value,
    pub mutating: bool,
}

impl Call {
    pub fn read(cmd: &str, args: Value) -> Self {
        Call {
            cmd: cmd.to_string(),
            args,
            mutating: false,
        }
    }

    pub fn write(cmd: &str, args: Value) -> Self {
        Call {
            cmd: cmd.to_string(),
            args,
            mutating: true,
        }
    }
}
