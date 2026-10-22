//! `fs.*` requests plus the `--wait` polling state machine (PROTOCOL §9).

use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::client::Client;
use crate::commands::Call;
use crate::error::{Error, Result};

/// Poll cadence used by `--wait`.
pub const POLL_INTERVAL: Duration = Duration::from_millis(200);
/// Total budget for `--wait`.
pub const DEADLINE: Duration = Duration::from_secs(60);

pub fn status() -> Call {
    Call::read("fs.status", json!({}))
}

pub fn scan(sources: bool) -> Call {
    Call::write_no_undo("fs.scan", json!({ "sources": sources }))
}

pub fn reimport(paths: &[String]) -> Call {
    Call::write_no_undo("fs.reimport", json!({ "paths": paths }))
}

/// One `fs.status` payload.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Status {
    pub scanning: bool,
    pub progress: f64,
    pub importing: bool,
}

impl Status {
    pub fn from_json(data: &Value) -> Self {
        Status {
            scanning: data
                .get("scanning")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            progress: data.get("progress").and_then(Value::as_f64).unwrap_or(0.0),
            importing: data
                .get("importing")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }
    }

    pub fn idle(self) -> bool {
        !self.scanning && !self.importing
    }

    /// Godot reports progress as 0..1; accept 0..100 as well.
    pub fn percent(self) -> u8 {
        let fraction = if self.progress <= 1.0 {
            self.progress
        } else {
            self.progress / 100.0
        };
        (fraction.clamp(0.0, 1.0) * 100.0).round() as u8
    }
}

/// Polls until the filesystem is idle, reporting whole-percent changes while
/// scanning. `poll` and `deadline` are parameters so the state machine can be
/// driven by a fake in tests instead of a live editor.
pub fn wait_for_idle<S, P>(
    poll: Duration,
    deadline: Duration,
    mut status: S,
    mut progress: P,
) -> Result<()>
where
    S: FnMut() -> Result<Status>,
    P: FnMut(u8),
{
    let start = Instant::now();
    let mut reported = None;

    loop {
        let current = status()?;
        if current.scanning {
            let percent = current.percent();
            if reported != Some(percent) {
                reported = Some(percent);
                progress(percent);
            }
        }
        if current.idle() {
            return Ok(());
        }
        if start.elapsed() >= deadline {
            return Err(Error::command(
                "GODOT_ERROR",
                format!(
                    "the filesystem did not become idle within {} s",
                    deadline.as_secs()
                ),
                Some("check the FileSystem dock; a scan or import may be stuck"),
            ));
        }
        thread::sleep(poll);
    }
}

/// `--wait` against a live connection.
pub fn wait(client: &mut Client) -> Result<()> {
    wait_for_idle(
        POLL_INTERVAL,
        DEADLINE,
        || {
            client
                .call("fs.status", &json!({}), None)
                .map(|data| Status::from_json(&data))
        },
        |percent| eprintln!("scanning… {percent}%"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_and_reimport_are_mutations_without_undo() {
        let scan = scan(true);
        assert_eq!(scan.cmd, "fs.scan");
        assert!(scan.mutating);
        assert!(!scan.undoable);
        assert_eq!(scan.args["sources"], true);

        let reimport = reimport(&["res://a.png".to_string(), "res://b.png".to_string()]);
        assert_eq!(reimport.cmd, "fs.reimport");
        assert!(reimport.mutating);
        assert!(!reimport.undoable);
        assert_eq!(
            reimport.args["paths"],
            json!(["res://a.png", "res://b.png"])
        );
    }

    #[test]
    fn status_is_read_only() {
        let call = status();
        assert_eq!(call.cmd, "fs.status");
        assert!(!call.mutating);
        assert!(call.opts(true, true).is_none());
    }

    #[test]
    fn wait_stops_when_scanning_and_importing_are_false() {
        let statuses = [
            Status {
                scanning: true,
                progress: 0.0,
                importing: false,
            },
            Status {
                scanning: true,
                progress: 0.42,
                importing: false,
            },
            Status {
                scanning: true,
                progress: 0.42,
                importing: false,
            },
            Status {
                scanning: true,
                progress: 1.0,
                importing: false,
            },
            Status {
                scanning: false,
                progress: 0.0,
                importing: false,
            },
        ];
        let mut remaining = statuses.iter().copied();
        let mut percents = Vec::new();

        wait_for_idle(
            Duration::ZERO,
            DEADLINE,
            || Ok(remaining.next().expect("the poller asked too often")),
            |percent| percents.push(percent),
        )
        .unwrap();

        assert_eq!(percents, vec![0, 42, 100]);
        assert!(remaining.next().is_none(), "the poller stopped early");
    }

    #[test]
    fn wait_keeps_polling_while_importing() {
        let statuses = [
            Status {
                scanning: false,
                progress: 0.0,
                importing: true,
            },
            Status {
                scanning: false,
                progress: 0.0,
                importing: false,
            },
        ];
        let mut remaining = statuses.iter().copied();
        let mut polls = 0;

        wait_for_idle(
            Duration::ZERO,
            DEADLINE,
            || {
                polls += 1;
                Ok(remaining.next().expect("the poller asked too often"))
            },
            |_| {},
        )
        .unwrap();

        assert_eq!(polls, 2);
    }

    #[test]
    fn wait_times_out_with_a_command_error() {
        let error = wait_for_idle(
            Duration::ZERO,
            Duration::ZERO,
            || {
                Ok(Status {
                    scanning: true,
                    progress: 0.5,
                    importing: false,
                })
            },
            |_| {},
        )
        .unwrap_err();

        assert_eq!(error.exit_code(), 3);
        assert!(error.message().contains("GODOT_ERROR"));
        assert!(error.message().contains("did not become idle"));
    }

    #[test]
    fn wait_returns_at_once_when_already_idle() {
        let mut percents = Vec::new();
        wait_for_idle(
            Duration::ZERO,
            DEADLINE,
            || {
                Ok(Status {
                    scanning: false,
                    progress: 0.0,
                    importing: false,
                })
            },
            |percent| percents.push(percent),
        )
        .unwrap();
        assert!(percents.is_empty());
    }

    #[test]
    fn percent_accepts_both_scales() {
        let status = |progress| Status {
            scanning: true,
            progress,
            importing: false,
        };
        assert_eq!(status(0.42).percent(), 42);
        assert_eq!(status(42.0).percent(), 42);
        assert_eq!(status(0.0).percent(), 0);
        assert_eq!(status(1.0).percent(), 100);
    }

    #[test]
    fn status_defaults_missing_fields_to_idle() {
        let status = Status::from_json(&json!({}));
        assert!(status.idle());
        assert_eq!(status.progress, 0.0);
    }

    #[test]
    fn waits_use_the_documented_cadence_and_deadline() {
        assert_eq!(POLL_INTERVAL, Duration::from_millis(200));
        assert_eq!(DEADLINE, Duration::from_secs(60));
    }
}
