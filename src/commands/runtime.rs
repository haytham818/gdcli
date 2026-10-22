//! `runtime install` / `runtime uninstall` / `runtime status` (PROTOCOL §11).
//!
//! The runtime files are the same embedded plugin assets `plugin install`
//! writes; the extra step is the `GdcliRuntime` autoload, which can only be
//! registered by a live editor.

use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};

use crate::assets;
use crate::client::Client;
use crate::error::{Error, Result};
use crate::install;
use crate::output::{self, Fmt};

pub const AUTOLOAD_NAME: &str = "GdcliRuntime";
pub const AUTOLOAD_PATH: &str = "res://addons/gdcli/runtime/gdcli_runtime.gd";

/// `game.ping` answers within a few seconds; a CLI-side probe must not wait for
/// the default two-minute read timeout.
const GAME_PING_TIMEOUT: Duration = Duration::from_secs(5);

pub enum Action {
    Install,
    Uninstall,
    Status,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallState {
    Added,
    AlreadyPresent,
    Unavailable,
}

impl InstallState {
    pub fn as_str(self) -> &'static str {
        match self {
            InstallState::Added => "added",
            InstallState::AlreadyPresent => "already-present",
            InstallState::Unavailable => "unavailable",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoveState {
    Removed,
    Absent,
}

impl RemoveState {
    pub fn as_str(self) -> &'static str {
        match self {
            RemoveState::Removed => "removed",
            RemoveState::Absent => "absent",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutoloadState {
    Present { path: String, enabled: bool },
    Missing,
    Unknown { error: String },
}

#[derive(Debug, Clone, PartialEq)]
pub enum GameState {
    Answering {
        runtime: String,
        scene: String,
        fps: f64,
    },
    NoGame,
    Unknown {
        error: String,
    },
}

#[derive(Debug, Clone)]
pub struct RuntimeStatus {
    pub project: String,
    pub files_installed: bool,
    pub autoload: AutoloadState,
    pub game: GameState,
}

impl RuntimeStatus {
    /// The runtime files are what `runtime install` owns; the editor and game
    /// are reported but do not change the exit code.
    pub fn is_ok(&self) -> bool {
        self.files_installed
    }
}

pub fn run(project: Option<&Path>, action: Action, fmt: Fmt) -> Result<()> {
    let project = crate::client::discover_project(project)?;
    match action {
        Action::Install => install(&project, fmt),
        Action::Uninstall => uninstall(&project, fmt),
        Action::Status => status(&project, fmt),
    }
}

fn install(project: &Path, fmt: Fmt) -> Result<()> {
    let report = install::install(project, false, false)?;

    let mut client = match Client::connect(project) {
        Ok(client) => client,
        Err(error) => {
            let message = error.message();
            output::runtime_install_report(fmt, &report, InstallState::Unavailable, Some(&message));
            if error.exit_code() == 2 {
                return Err(Error::not_connected(
                    "the plugin files were installed, but the GdcliRuntime autoload needs a live editor",
                )
                .with_hint("start the Godot editor and rerun `gdcli runtime install`"));
            }
            return Err(error);
        }
    };

    match add_autoload(&mut client) {
        Ok(state) => {
            output::runtime_install_report(fmt, &report, state, None);
            Ok(())
        }
        Err(error) => {
            output::runtime_install_report(
                fmt,
                &report,
                InstallState::Unavailable,
                Some(&error.message()),
            );
            Err(error)
        }
    }
}

fn add_autoload(client: &mut Client) -> Result<InstallState> {
    let args = json!({ "name": AUTOLOAD_NAME, "path": AUTOLOAD_PATH });
    classify_add(client.call("project.autoload.add", &args, None))
}

/// The plugin answers `BAD_ARGS` for a duplicate autoload. That specific case
/// is success: installing twice must be idempotent.
fn classify_add(result: Result<Value>) -> Result<InstallState> {
    match result {
        Ok(_) => Ok(InstallState::Added),
        Err(error) if is_duplicate_autoload(&error) => Ok(InstallState::AlreadyPresent),
        Err(error) => Err(error),
    }
}

fn is_duplicate_autoload(error: &Error) -> bool {
    matches!(
        error,
        Error::Command { code, message, .. }
            if code == "BAD_ARGS"
                && message.contains("already exists")
                && message.contains(AUTOLOAD_NAME)
    )
}

fn uninstall(project: &Path, fmt: Fmt) -> Result<()> {
    let mut client = Client::connect(project)?;
    let args = json!({ "name": AUTOLOAD_NAME });
    let state = match client.call("project.autoload.remove", &args, None) {
        Ok(_) => RemoveState::Removed,
        Err(Error::Command { code, .. }) if code == "NOT_FOUND" => RemoveState::Absent,
        Err(error) => return Err(error),
    };
    output::runtime_uninstall_report(fmt, state);
    Ok(())
}

fn status(project: &Path, fmt: Fmt) -> Result<()> {
    let files = files_installed(project);

    let (autoload, game) = match Client::connect(project) {
        Ok(mut client) => (probe_autoload(&mut client), probe_game(&mut client)),
        Err(error) => {
            let message = error.message();
            (
                AutoloadState::Unknown {
                    error: message.clone(),
                },
                GameState::Unknown { error: message },
            )
        }
    };

    let status = build_status(project.display().to_string(), files, autoload, game);
    output::runtime_status(fmt, &status);

    if status.is_ok() {
        Ok(())
    } else {
        Err(Error::Exit(2))
    }
}

fn build_status(
    project: String,
    files_installed: bool,
    autoload: AutoloadState,
    game: GameState,
) -> RuntimeStatus {
    RuntimeStatus {
        project,
        files_installed,
        autoload,
        game,
    }
}

/// True when every embedded plugin asset (including the runtime script) exists.
fn files_installed(project: &Path) -> bool {
    assets::FILES
        .iter()
        .all(|asset| project.join(asset.path).is_file())
}

fn probe_autoload(client: &mut Client) -> AutoloadState {
    match client.call("project.autoload.list", &json!({}), None) {
        Ok(data) => autoload_from_list(&data),
        Err(error) => AutoloadState::Unknown {
            error: error.message(),
        },
    }
}

fn autoload_from_list(data: &Value) -> AutoloadState {
    let entry = data
        .get("autoloads")
        .and_then(Value::as_array)
        .and_then(|autoloads| {
            autoloads
                .iter()
                .find(|entry| entry.get("name").and_then(Value::as_str) == Some(AUTOLOAD_NAME))
        });

    match entry {
        Some(entry) => AutoloadState::Present {
            path: entry
                .get("path")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            enabled: entry
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(true),
        },
        None => AutoloadState::Missing,
    }
}

fn probe_game(client: &mut Client) -> GameState {
    game_from_result(client.call_with_timeout("game.ping", &json!({}), None, GAME_PING_TIMEOUT))
}

/// `NO_GAME` is data: the runtime is not installed or no game is running.
fn game_from_result(result: Result<Value>) -> GameState {
    match result {
        Ok(data) => GameState::Answering {
            runtime: string_field(&data, "runtime"),
            scene: string_field(&data, "scene"),
            fps: data.get("fps").and_then(Value::as_f64).unwrap_or(0.0),
        },
        Err(Error::Command { code, .. }) if code == "NO_GAME" => GameState::NoGame,
        Err(error) => GameState::Unknown {
            error: error.message(),
        },
    }
}

fn string_field(data: &Value, key: &str) -> String {
    data.get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::parse_response;

    fn fake_error(line: &str) -> Error {
        parse_response(line).expect_err("response should fail")
    }

    #[test]
    fn add_is_idempotent_for_the_duplicate_autoload_error() {
        let line = r#"{"id":"1","ok":false,"error":{"code":"BAD_ARGS","message":"autoload 'GdcliRuntime' already exists"}}"#;
        assert_eq!(
            classify_add(Err(fake_error(line))).unwrap(),
            InstallState::AlreadyPresent
        );
    }

    #[test]
    fn add_succeeds_on_a_normal_reply() {
        assert_eq!(
            classify_add(Ok(json!({"name": AUTOLOAD_NAME}))).unwrap(),
            InstallState::Added
        );
    }

    #[test]
    fn add_does_not_swallow_other_bad_args() {
        let line =
            r#"{"id":"1","ok":false,"error":{"code":"BAD_ARGS","message":"missing `path`"}}"#;
        let error = classify_add(Err(fake_error(line))).unwrap_err();
        assert_eq!(error.exit_code(), 3);
    }

    #[test]
    fn add_does_not_swallow_another_autoload_conflict() {
        let line = r#"{"id":"1","ok":false,"error":{"code":"BAD_ARGS","message":"autoload 'Other' already exists"}}"#;
        assert!(classify_add(Err(fake_error(line))).is_err());
    }

    #[test]
    fn autoload_list_is_filtered_for_the_runtime() {
        let data = json!({
            "autoloads": [
                {"name": "Game", "path": "res://game.gd", "enabled": true},
                {"name": "GdcliRuntime", "path": AUTOLOAD_PATH, "enabled": true},
            ],
        });
        assert_eq!(
            autoload_from_list(&data),
            AutoloadState::Present {
                path: AUTOLOAD_PATH.to_string(),
                enabled: true,
            }
        );

        assert_eq!(
            autoload_from_list(&json!({
                "autoloads": [{"name": "Game", "path": "res://game.gd"}],
            })),
            AutoloadState::Missing
        );
        assert_eq!(autoload_from_list(&json!({})), AutoloadState::Missing);
    }

    #[test]
    fn game_ping_distinguishes_no_game_from_other_failures() {
        assert_eq!(
            game_from_result(Ok(json!({
                "runtime": "0.5.0",
                "scene": "res://main.tscn",
                "fps": 59.5,
            }))),
            GameState::Answering {
                runtime: "0.5.0".to_string(),
                scene: "res://main.tscn".to_string(),
                fps: 59.5,
            }
        );

        let no_game = fake_error(
            r#"{"id":"1","ok":false,"error":{"code":"NO_GAME","message":"no runtime"}}"#,
        );
        assert_eq!(game_from_result(Err(no_game)), GameState::NoGame);

        let other =
            fake_error(r#"{"id":"1","ok":false,"error":{"code":"INTERNAL","message":"boom"}}"#);
        assert!(matches!(
            game_from_result(Err(other)),
            GameState::Unknown { .. }
        ));
    }

    #[test]
    fn status_depends_only_on_the_installed_files() {
        let autoloads = [
            AutoloadState::Present {
                path: AUTOLOAD_PATH.to_string(),
                enabled: true,
            },
            AutoloadState::Missing,
            AutoloadState::Unknown {
                error: "no editor".to_string(),
            },
        ];
        let games = [
            GameState::Answering {
                runtime: "0.5.0".to_string(),
                scene: "res://main.tscn".to_string(),
                fps: 60.0,
            },
            GameState::NoGame,
        ];

        for files in [false, true] {
            for autoload in &autoloads {
                for game in &games {
                    let status =
                        build_status("/p".to_string(), files, autoload.clone(), game.clone());
                    assert_eq!(status.is_ok(), files);
                    assert_eq!(status.files_installed, files);
                    assert_eq!(&status.autoload, autoload);
                    assert_eq!(&status.game, game);
                }
            }
        }
    }

    #[test]
    fn files_installed_requires_the_runtime_asset() {
        let dir = std::env::temp_dir().join(format!("gdcli-runtime-status-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        assert!(!files_installed(&dir));

        for asset in assets::FILES {
            let path = dir.join(asset.path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, asset.content).unwrap();
        }
        assert!(files_installed(&dir));

        std::fs::remove_file(dir.join("addons/gdcli/runtime/gdcli_runtime.gd")).unwrap();
        assert!(!files_installed(&dir));

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
