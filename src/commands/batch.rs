//! `batch`: NDJSON in, NDJSON out, one handshake, one connection.

use std::io::{self, BufRead, Write};

use serde_json::Value;

use crate::client::Client;
use crate::error::{Error, Result};

/// Streams responses as they arrive. Returns `true` when any response was
/// `ok: false`.
pub fn run(client: &mut Client) -> Result<bool> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut output = io::BufWriter::new(stdout.lock());
    let mut failed = false;
    let mut line_number: u64 = 0;

    for line in stdin.lock().lines() {
        line_number += 1;
        let line = line.map_err(|error| Error::usage(format!("cannot read stdin: {error}")))?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let request = match normalise(line, line_number) {
            Ok(request) => request,
            Err(message) => {
                failed = true;
                write_line(
                    &mut output,
                    &error_reply(&line_number.to_string(), "BAD_ARGS", &message).to_string(),
                )?;
                continue;
            }
        };

        let reply = client.exchange(&request)?;
        let value: Value = serde_json::from_str(&reply).map_err(|error| {
            Error::protocol(format!(
                "malformed response from the plugin: {error}: {reply}"
            ))
        })?;
        let ok = value
            .get("ok")
            .and_then(Value::as_bool)
            .ok_or_else(|| Error::protocol(format!("response has no `ok` field: {reply}")))?;
        if !ok {
            failed = true;
        }
        write_line(&mut output, &reply)?;
    }

    output
        .flush()
        .map_err(|error| Error::usage(format!("cannot write stdout: {error}")))?;
    Ok(failed)
}

fn write_line(output: &mut io::BufWriter<io::StdoutLock<'_>>, line: &str) -> Result<()> {
    writeln!(output, "{line}")
        .and_then(|()| output.flush())
        .map_err(|error| Error::usage(format!("cannot write stdout: {error}")))
}

/// Assigns the line number as `id` when the request has none.
fn normalise(line: &str, line_number: u64) -> std::result::Result<String, String> {
    let value: Value =
        serde_json::from_str(line).map_err(|error| format!("invalid JSON: {error}"))?;
    let Value::Object(mut request) = value else {
        return Err("request must be a JSON object".to_string());
    };
    if !request.contains_key("id") {
        request.insert("id".to_string(), Value::String(line_number.to_string()));
    }
    serde_json::to_string(&request).map_err(|error| format!("cannot serialise request: {error}"))
}

fn error_reply(id: &str, code: &str, message: &str) -> Value {
    serde_json::json!({
        "id": id,
        "ok": false,
        "error": { "code": code, "message": message },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assigns_the_line_number_when_the_id_is_absent() {
        let request = normalise(r#"{"cmd":"meta.ping"}"#, 7).unwrap();
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["id"], "7");
        assert_eq!(value["cmd"], "meta.ping");
    }

    #[test]
    fn keeps_an_explicit_id() {
        let request = normalise(r#"{"id":"abc","cmd":"meta.ping"}"#, 7).unwrap();
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["id"], "abc");
    }

    #[test]
    fn rejects_non_object_lines() {
        assert!(normalise("42", 1).is_err());
        assert!(normalise("{", 1).is_err());
    }
}
