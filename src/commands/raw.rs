use serde_json::Value;

use crate::error::{Error, Result};

#[derive(Debug)]
pub struct RawCall {
    pub cmd: String,
    pub args: Value,
}

pub fn parse(cmd: &str, args: Option<&str>) -> Result<RawCall> {
    if cmd.trim().is_empty() {
        return Err(Error::usage("raw needs a command name"));
    }
    let args = match args {
        None => serde_json::json!({}),
        Some(raw) => {
            let value: Value = serde_json::from_str(raw)
                .map_err(|error| Error::usage(format!("--args is not valid JSON: {error}")))?;
            if !value.is_object() {
                return Err(Error::usage("--args must be a JSON object"));
            }
            value
        }
    };
    Ok(RawCall {
        cmd: cmd.to_string(),
        args,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_empty_args() {
        assert_eq!(
            parse("meta.ping", None).unwrap().args,
            serde_json::json!({})
        );
    }

    #[test]
    fn rejects_non_object_args() {
        let error = parse("meta.ping", Some("[1, 2]")).unwrap_err();
        assert_eq!(error.exit_code(), 1);
    }

    #[test]
    fn rejects_bad_json() {
        assert!(parse("meta.ping", Some("{oops")).is_err());
    }
}
