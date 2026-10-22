//! Errors and their exit codes (see docs/PROTOCOL.md §8).

use std::fmt;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug)]
pub enum Error {
    /// Bad invocation or a local file that could not be written. Exit 1.
    Usage(String),
    /// No endpoint file, or the editor cannot be reached. Exit 2.
    NotConnected {
        message: String,
        hint: Option<String>,
    },
    /// The plugin answered `ok: false`. Exit 3.
    Command {
        code: String,
        message: String,
        hint: Option<String>,
    },
    /// Framing, protocol or version problem. Exit 4.
    Protocol {
        message: String,
        hint: Option<String>,
    },
    /// Exit with a code and no message; state has already been reported.
    Exit(i32),
}

impl Error {
    pub fn usage(message: impl Into<String>) -> Self {
        Error::Usage(message.into())
    }

    pub fn not_connected(message: impl Into<String>) -> Self {
        Error::NotConnected {
            message: message.into(),
            hint: None,
        }
    }

    pub fn protocol(message: impl Into<String>) -> Self {
        Error::Protocol {
            message: message.into(),
            hint: None,
        }
    }

    pub fn command(
        code: impl Into<String>,
        message: impl Into<String>,
        hint: Option<&str>,
    ) -> Self {
        Error::Command {
            code: code.into(),
            message: message.into(),
            hint: hint.map(str::to_string),
        }
    }

    pub fn with_hint(mut self, hint: impl Into<String>) -> Self {
        match &mut self {
            Error::NotConnected { hint: slot, .. }
            | Error::Command { hint: slot, .. }
            | Error::Protocol { hint: slot, .. } => *slot = Some(hint.into()),
            Error::Usage(_) | Error::Exit(_) => {}
        }
        self
    }

    pub fn exit_code(&self) -> i32 {
        match self {
            Error::Usage(_) => 1,
            Error::NotConnected { .. } => 2,
            Error::Command { .. } => 3,
            Error::Protocol { .. } => 4,
            Error::Exit(code) => *code,
        }
    }

    pub fn message(&self) -> String {
        match self {
            Error::Usage(message) => message.clone(),
            Error::NotConnected { message, .. } => message.clone(),
            Error::Command { code, message, .. } => format!("{code}: {message}"),
            Error::Protocol { message, .. } => message.clone(),
            Error::Exit(_) => String::new(),
        }
    }

    pub fn hint(&self) -> Option<&str> {
        match self {
            Error::NotConnected { hint, .. }
            | Error::Command { hint, .. }
            | Error::Protocol { hint, .. } => hint.as_deref(),
            Error::Usage(_) | Error::Exit(_) => None,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message())
    }
}

impl std::error::Error for Error {}
