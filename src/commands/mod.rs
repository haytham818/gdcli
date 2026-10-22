//! Thin mappers from CLI arguments to wire requests. No rendering here.

pub mod batch;
pub mod editor;
pub mod fs;
pub mod game;
pub mod group;
pub mod node;
pub mod plugin;
pub mod project;
pub mod prop;
pub mod raw;
pub mod res;
pub mod runtime;
pub mod scene;
pub mod script;
pub mod signal;

use serde_json::Value;

use crate::client::Opts;

/// One wire request plus whether the undo/dry-run options apply to it.
#[derive(Debug)]
pub struct Call {
    pub cmd: String,
    pub args: Value,
    pub mutating: bool,
    /// Whether `opts.undo` applies; false for history actions such as undo/redo.
    pub undoable: bool,
}

impl Call {
    pub fn read(cmd: &str, args: Value) -> Self {
        Call {
            cmd: cmd.to_string(),
            args,
            mutating: false,
            undoable: false,
        }
    }

    pub fn write(cmd: &str, args: Value) -> Self {
        Call {
            cmd: cmd.to_string(),
            args,
            mutating: true,
            undoable: true,
        }
    }

    /// A mutating command whose effect is not part of the scene undo history
    /// (resources, project settings, filesystem, scripts). It takes `dry_run`
    /// but never `undo`.
    pub fn write_no_undo(cmd: &str, args: Value) -> Self {
        Call {
            cmd: cmd.to_string(),
            args,
            mutating: true,
            undoable: false,
        }
    }

    /// A mutating command that acts on the undo history itself (undo/redo).
    pub fn history(cmd: &str, args: Value) -> Self {
        Self::write_no_undo(cmd, args)
    }

    /// Per-request options; reads carry none, history actions omit `undo`.
    pub fn opts(&self, undo: bool, dry_run: bool) -> Option<Opts> {
        self.mutating.then(|| Opts {
            undo: self.undoable.then_some(undo),
            dry_run,
        })
    }
}
