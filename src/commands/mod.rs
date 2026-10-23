//! Thin mappers from CLI arguments to wire requests. No rendering here.

pub mod batch;
pub mod editor;
pub mod fs;
pub mod game;
pub mod group;
pub mod input;
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

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::client::Opts;
use crate::error::{Error, Result};

/// One wire request plus whether the undo/dry-run options apply to it.
#[derive(Debug)]
pub struct Call {
    pub cmd: String,
    pub args: Value,
    pub mutating: bool,
    /// Whether `opts.undo` applies; false for history actions such as undo/redo.
    pub undoable: bool,
    /// Renderer key when one wire command backs several CLI views.
    pub view: Option<&'static str>,
}

impl Call {
    pub fn read(cmd: &str, args: Value) -> Self {
        Call {
            cmd: cmd.to_string(),
            args,
            mutating: false,
            undoable: false,
            view: None,
        }
    }

    pub fn write(cmd: &str, args: Value) -> Self {
        Call {
            cmd: cmd.to_string(),
            args,
            mutating: true,
            undoable: true,
            view: None,
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
            view: None,
        }
    }

    /// Renders this response under a CLI-specific key, for commands whose wire
    /// reply is shared by more than one view (`input.list` backs both
    /// `input actions` and `input list`).
    pub fn with_view(mut self, key: &'static str) -> Self {
        self.view = Some(key);
        self
    }

    pub fn render_key(&self) -> &str {
        self.view.unwrap_or(&self.cmd)
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

/// The absolute path a screenshot request carries: create the parent
/// directories, resolve them, then append the file name.
pub fn absolute_output(out: &Path) -> Result<String> {
    let name = out
        .file_name()
        .ok_or_else(|| Error::usage(format!("--out must name a file: {}", out.display())))?;
    let parent = out
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent)
        .map_err(|error| Error::usage(format!("cannot create {}: {error}", parent.display())))?;
    let parent = std::fs::canonicalize(parent)
        .map_err(|error| Error::usage(format!("cannot resolve {}: {error}", parent.display())))?;
    Ok(without_verbatim_prefix(parent.join(name))
        .to_string_lossy()
        .into_owned())
}

/// `canonicalize` on Windows returns `\\?\D:\...` (and `\\?\UNC\...` for shares). Godot
/// does not understand those prefixes, so hand the editor a plain path.
fn without_verbatim_prefix(path: PathBuf) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        return PathBuf::from(format!(r"\\{rest}"));
    }
    if let Some(rest) = text.strip_prefix(r"\\?\") {
        return PathBuf::from(rest);
    }
    path
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::without_verbatim_prefix;

    #[test]
    fn strips_windows_verbatim_prefixes() {
        assert_eq!(
            without_verbatim_prefix(PathBuf::from(r"\\?\D:\a\b.png")),
            PathBuf::from(r"D:\a\b.png")
        );
        assert_eq!(
            without_verbatim_prefix(PathBuf::from(r"\\?\UNC\srv\share\b.png")),
            PathBuf::from(r"\\srv\share\b.png")
        );
        assert_eq!(
            without_verbatim_prefix(PathBuf::from("/tmp/b.png")),
            PathBuf::from("/tmp/b.png")
        );
    }
}
