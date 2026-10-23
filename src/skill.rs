//! The companion agent skill, published through skills.sh.
//!
//! `gdcli plugin install` offers it once, in a terminal. It is never load-bearing: a failure
//! to reach npx or the network prints a hint and leaves the plugin installed.

use std::io::{self, IsTerminal, Write};
use std::process::Command;

use crate::output::Fmt;

/// `owner/repo@skill`, as accepted by the skills CLI.
pub const SKILL: &str = "haytham818/gdcli@gdcli";

/// Builds the non-interactive install, safe to paste anywhere.
///
/// The agent list is explicit and bounded: with `-y` and no `-a` the skills CLI either guesses
/// from what is installed or, when nothing matches, links the skill into every agent directory
/// it knows about (dozens). Four mainstream agents is a reasonable default; anyone else adds
/// another `-a <agent>`.
pub fn default_command() -> String {
    format!("npx --yes skills add {SKILL} -g -y -a claude-code -a codex -a opencode -a cursor")
}

/// Overrides the installer command, for offline machines and for tests.
pub const OVERRIDE_ENV: &str = "GDCLI_SKILL_CMD";

#[derive(Debug, PartialEq, Eq)]
pub enum Plan {
    Install,
    Ask,
    Skip,
}

/// What to do about the skill, from the two flags and whether a human is watching.
pub fn plan(with_skill: bool, no_skill: bool, interactive: bool) -> Plan {
    if with_skill {
        Plan::Install
    } else if no_skill || !interactive {
        Plan::Skip
    } else {
        Plan::Ask
    }
}

pub fn command_from(override_value: Option<String>) -> String {
    override_value.unwrap_or_else(default_command)
}

pub fn command() -> String {
    command_from(
        std::env::var(OVERRIDE_ENV)
            .ok()
            .filter(|value| !value.is_empty()),
    )
}

/// Runs after a successful `plugin install`; never returns an error.
pub fn offer(with_skill: bool, no_skill: bool, fmt: Fmt) {
    let interactive =
        !fmt.json && !fmt.quiet && io::stdin().is_terminal() && io::stderr().is_terminal();

    let install = match plan(with_skill, no_skill, interactive) {
        Plan::Install => true,
        Plan::Skip => {
            // --no-skill means "do not mention it"; a non-interactive run still gets the hint.
            if !no_skill && !fmt.json && !fmt.quiet {
                hint();
            }
            false
        }
        Plan::Ask => ask(),
    };

    if install {
        install_skill();
    }
}

fn hint() {
    eprintln!();
    eprintln!("The gdcli agent skill teaches your coding agents to use this CLI:");
    eprintln!("  {}", default_command());
    eprintln!("Pass --with-skill to install it now, or --no-skill to silence this.");
    eprintln!();
}

fn ask() -> bool {
    eprint!("Install the gdcli agent skill for your coding agents? [Y/n] ");
    let _ = io::stderr().flush();

    let mut answer = String::new();
    if io::stdin().read_line(&mut answer).is_err() {
        return false;
    }
    matches!(
        answer.trim().to_ascii_lowercase().as_str(),
        "" | "y" | "yes"
    )
}

fn install_skill() {
    let command = command();
    eprintln!("Installing the gdcli skill: {command}");

    let status = if cfg!(windows) {
        Command::new("cmd").args(["/C", &command]).status()
    } else {
        Command::new("sh").args(["-c", &command]).status()
    };

    match status {
        Ok(status) if status.success() => eprintln!("The gdcli skill is installed."),
        Ok(status) => {
            eprintln!("warning: the skill installer exited with {status}.");
            eprintln!("Run it yourself when convenient: {command}");
        }
        Err(error) => {
            eprintln!("warning: could not run the skill installer: {error}");
            eprintln!("Run it yourself when convenient: {command}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_terminal_asks_and_flags_decide() {
        assert_eq!(plan(false, false, true), Plan::Ask);
        assert_eq!(plan(true, false, false), Plan::Install);
        assert_eq!(plan(true, false, true), Plan::Install);
        assert_eq!(plan(false, true, true), Plan::Skip);
        assert_eq!(plan(false, false, false), Plan::Skip);
    }

    #[test]
    fn the_command_is_overridable_and_pins_the_skill() {
        let command = command_from(None);
        assert!(command.contains(SKILL), "{command}");
        assert!(command.contains("-g"), "{command}");
        assert!(command.contains("-y"), "{command}");
        assert!(command.contains("-a claude-code"), "{command}");
        assert!(!command.contains("-a '*'"), "{command}");
        assert_eq!(
            command_from(Some("sh /tmp/fake.sh".to_string())),
            "sh /tmp/fake.sh"
        );
    }
}
