use std::path::Path;

use crate::client;
use crate::error::{Error, Result};
use crate::install;
use crate::output::{self, Fmt};

pub enum Action {
    Install { check: bool, private: bool },
    Upgrade,
    Status,
}

pub fn run(project: Option<&Path>, action: Action, fmt: Fmt) -> Result<()> {
    let project = client::discover_project(project)?;
    match action {
        Action::Install { check, private } => {
            let report = install::install(&project, check, private)?;
            output::install_report(fmt, &report, check);
            Ok(())
        }
        Action::Upgrade => {
            let report = install::install(&project, false, false)?;
            output::install_report(fmt, &report, false);
            Ok(())
        }
        Action::Status => {
            let status = install::status(&project);
            output::plugin_status(fmt, &status);
            if status.is_ok() {
                Ok(())
            } else {
                // Inspection command: report the state, do not error out.
                Err(Error::Exit(2))
            }
        }
    }
}
