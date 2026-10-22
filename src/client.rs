//! Project discovery, endpoint discovery, the TCP connection and framing
//! (docs/PROTOCOL.md §1–§4).

use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::{Error, Result};

/// Wire protocol version spoken by this build.
pub const PROTOCOL: u32 = 1;

/// Endpoint file, relative to the project root.
pub const ENDPOINT_REL: &str = ".godot/gdcli/endpoint.json";

const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const READ_TIMEOUT: Duration = Duration::from_secs(120);
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_LINE: usize = 1024 * 1024;

/// `<project>/.godot/gdcli/endpoint.json`, written by the plugin on startup.
#[derive(Debug, Clone, Deserialize)]
pub struct Endpoint {
    pub protocol: u32,
    pub plugin_version: String,
    pub port: u16,
    pub token: String,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub godot: Option<String>,
}

impl Endpoint {
    pub fn path(project: &Path) -> PathBuf {
        project.join(ENDPOINT_REL)
    }

    pub fn read(project: &Path) -> Result<Endpoint> {
        let path = Self::path(project);
        let text = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err(Error::not_connected(format!(
                    "no gdcli endpoint for {}: start the Godot editor with the plugin enabled, or run `gdcli plugin install`",
                    project.display()
                )));
            }
            Err(error) => {
                return Err(Error::not_connected(format!(
                    "cannot read {}: {error}",
                    path.display()
                )));
            }
        };
        serde_json::from_str(&text).map_err(|error| {
            Error::protocol(format!(
                "malformed endpoint file {}: {error}",
                path.display()
            ))
            .with_hint("restart the Godot editor so it rewrites the endpoint file")
        })
    }
}

/// Answer to the handshake, which is the `meta.ping` payload.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Ping {
    pub protocol: u32,
    #[serde(default)]
    pub plugin_version: String,
    #[serde(default)]
    pub godot: String,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub capabilities: Vec<String>,
}

/// Per-request options, omitted for read-only commands.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct Opts {
    /// `None` leaves `opts.undo` out entirely, as undo/redo require.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub undo: Option<bool>,
    pub dry_run: bool,
}

/// One blocking loopback connection.
#[derive(Debug)]
pub struct Client {
    reader: BufReader<TcpStream>,
    ping: Ping,
    next_id: u64,
}

impl Client {
    /// Reads the endpoint, connects and performs the handshake.
    pub fn connect(project: &Path) -> Result<Client> {
        let endpoint = Endpoint::read(project)?;
        let address = SocketAddr::from(([127, 0, 0, 1], endpoint.port));
        let stream = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT).map_err(|error| {
            Error::not_connected(format!(
                "cannot connect to the Godot editor on {address}: {error}"
            ))
            .with_hint("is the editor still running with the gdcli plugin enabled?")
        })?;
        stream
            .set_read_timeout(Some(READ_TIMEOUT))
            .and_then(|()| stream.set_write_timeout(Some(WRITE_TIMEOUT)))
            .and_then(|()| stream.set_nodelay(true))
            .map_err(|error| {
                Error::not_connected(format!("cannot configure the connection: {error}"))
            })?;

        let mut client = Client {
            reader: BufReader::new(stream),
            ping: Ping::default(),
            next_id: 0,
        };
        let ping = client.handshake(&endpoint)?;
        client.ping = ping;
        Ok(client)
    }

    /// The handshake payload (protocol, plugin version, capabilities).
    pub fn ping(&self) -> &Ping {
        &self.ping
    }

    /// Sends a command, after checking that the plugin advertises it.
    pub fn call(&mut self, cmd: &str, args: &Value, opts: Option<Opts>) -> Result<Value> {
        if !self.ping.capabilities.iter().any(|known| known == cmd) {
            return Err(Error::protocol(format!(
                "plugin v{} does not implement {cmd}",
                self.ping.plugin_version
            ))
            .with_hint("run `gdcli plugin upgrade`"));
        }
        self.call_raw(cmd, args, opts)
    }

    /// Sends a command without consulting the capability list (`raw`, `batch`).
    pub fn call_raw(&mut self, cmd: &str, args: &Value, opts: Option<Opts>) -> Result<Value> {
        let line = self.request_line(cmd, args, opts)?;
        let reply = self.exchange(&line)?;
        parse_response(&reply)
    }

    /// Builds the request line with the next id.
    pub fn request_line(&mut self, cmd: &str, args: &Value, opts: Option<Opts>) -> Result<String> {
        self.next_id += 1;
        let mut request = json!({
            "id": self.next_id.to_string(),
            "cmd": cmd,
            "args": args,
        });
        if let Some(opts) = opts {
            request["opts"] = serde_json::to_value(opts).map_err(|error| {
                Error::protocol(format!("cannot serialise request options: {error}"))
            })?;
        }
        let line = request.to_string();
        if line.len() > MAX_LINE {
            return Err(Error::usage("request exceeds the 1 MiB protocol limit"));
        }
        Ok(line)
    }

    /// Sends one line and returns the raw response line.
    pub fn exchange(&mut self, line: &str) -> Result<String> {
        self.write_line(line)?;
        self.read_line()?
            .ok_or_else(|| Error::not_connected("the editor closed the connection"))
    }

    fn handshake(&mut self, endpoint: &Endpoint) -> Result<Ping> {
        let mut payload = json!({"token": endpoint.token, "protocol": PROTOCOL})
            .to_string()
            .into_bytes();
        payload.push(b'\n');
        let stream = self.reader.get_mut();
        stream
            .write_all(&payload)
            .and_then(|()| stream.flush())
            .map_err(|_| token_rejected())?;

        let reply = match self.read_raw_line() {
            Ok(Some(reply)) => reply,
            Ok(None) => return Err(token_rejected()),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::ConnectionReset
                        | io::ErrorKind::ConnectionAborted
                        | io::ErrorKind::BrokenPipe
                        | io::ErrorKind::UnexpectedEof
                ) =>
            {
                return Err(token_rejected());
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                return Err(
                    Error::protocol("the editor did not answer the handshake in time")
                        .with_hint("restart the Godot editor"),
                );
            }
            Err(error) => {
                return Err(Error::protocol(format!("handshake failed: {error}")));
            }
        };
        let reply = reply.trim_end_matches(['\r', '\n']);
        if reply.len() > MAX_LINE {
            return Err(Error::protocol(
                "handshake reply exceeds the 1 MiB protocol limit",
            ));
        }

        let value: Value = serde_json::from_str(reply).map_err(|error| {
            Error::protocol(format!(
                "malformed handshake reply from the plugin: {error}: {reply}"
            ))
        })?;
        let ok = value.get("ok").and_then(Value::as_bool).unwrap_or(false);
        if !ok {
            let error = value.get("error");
            let code = error
                .and_then(|entry| entry.get("code"))
                .and_then(Value::as_str)
                .unwrap_or("INTERNAL");
            let message = error
                .and_then(|entry| entry.get("message"))
                .and_then(Value::as_str)
                .unwrap_or("handshake rejected");
            return Err(
                Error::protocol(format!("handshake rejected: {code}: {message}"))
                    .with_hint("restart the Godot editor"),
            );
        }

        let data = value
            .get("data")
            .cloned()
            .ok_or_else(|| Error::protocol(format!("handshake reply carries no data: {reply}")))?;
        let ping: Ping = serde_json::from_value(data)
            .map_err(|error| Error::protocol(format!("malformed handshake payload: {error}")))?;
        if ping.protocol != PROTOCOL {
            return Err(Error::protocol(format!(
                "protocol mismatch: the plugin speaks v{}, gdcli speaks v{}",
                ping.protocol, PROTOCOL
            ))
            .with_hint("run `gdcli plugin upgrade`"));
        }
        Ok(ping)
    }

    /// Reads one `\n`-terminated line, refusing to buffer past the limit.
    fn read_raw_line(&mut self) -> io::Result<Option<String>> {
        let mut line = String::new();
        let read = self
            .reader
            .by_ref()
            .take((MAX_LINE + 2) as u64)
            .read_line(&mut line)?;
        if read == 0 {
            return Ok(None);
        }
        Ok(Some(line))
    }

    fn read_line(&mut self) -> Result<Option<String>> {
        match self.read_raw_line() {
            Ok(Some(line)) => {
                let line = line.trim_end_matches(['\r', '\n']);
                if line.len() > MAX_LINE {
                    return Err(Error::protocol(
                        "response line exceeds the 1 MiB protocol limit",
                    ));
                }
                Ok(Some(line.to_string()))
            }
            Ok(None) => Ok(None),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                Err(Error::not_connected(format!(
                    "timed out waiting for the editor after {} s",
                    READ_TIMEOUT.as_secs()
                )))
            }
            Err(error) if error.kind() == io::ErrorKind::InvalidData => Err(Error::protocol(
                "the editor sent a line that is not valid UTF-8",
            )),
            Err(error) => Err(Error::not_connected(format!(
                "cannot read from the editor: {error}"
            ))),
        }
    }

    fn write_line(&mut self, line: &str) -> Result<()> {
        if line.len() > MAX_LINE {
            return Err(Error::usage("request exceeds the 1 MiB protocol limit"));
        }
        let mut payload = Vec::with_capacity(line.len() + 1);
        payload.extend_from_slice(line.as_bytes());
        payload.push(b'\n');
        let stream = self.reader.get_mut();
        stream
            .write_all(&payload)
            .and_then(|()| stream.flush())
            .map_err(|error| Error::not_connected(format!("cannot send to the editor: {error}")))
    }
}

/// The plugin closes the socket without a reply when the token is wrong.
fn token_rejected() -> Error {
    Error::protocol("token rejected: the editor closed the connection")
        .with_hint("the endpoint file may be stale; restart the Godot editor")
}

/// Parses one response line; `Error::Command` carries `ok: false` payloads.
pub fn parse_response(line: &str) -> Result<Value> {
    let value: Value = serde_json::from_str(line).map_err(|error| {
        Error::protocol(format!(
            "malformed response from the plugin: {error}: {line}"
        ))
    })?;
    let ok = value.get("ok").and_then(Value::as_bool).ok_or_else(|| {
        Error::protocol(format!(
            "response from the plugin has no `ok` field: {line}"
        ))
    })?;
    if ok {
        return Ok(value.get("data").cloned().unwrap_or(Value::Null));
    }

    let error = value.get("error");
    let code = error
        .and_then(|entry| entry.get("code"))
        .and_then(Value::as_str)
        .unwrap_or("INTERNAL");
    let message = error
        .and_then(|entry| entry.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("command failed");
    let hint = error
        .and_then(|entry| entry.get("hint"))
        .and_then(Value::as_str);
    Err(Error::command(code, message, hint))
}

/// Walks up from `start` (or the current directory) to the project root.
pub fn discover_project(start: Option<&Path>) -> Result<PathBuf> {
    let start = match start {
        Some(path) => path.to_path_buf(),
        None => env::current_dir()
            .map_err(|error| Error::usage(format!("cannot read the current directory: {error}")))?,
    };
    if !start.exists() {
        return Err(Error::usage(format!(
            "project path does not exist: {}",
            start.display()
        )));
    }

    let mut directory = fs::canonicalize(&start)
        .map_err(|error| Error::usage(format!("cannot resolve {}: {error}", start.display())))?;
    if directory.is_file() {
        if directory
            .file_name()
            .is_some_and(|name| name == "project.godot")
            && let Some(parent) = directory.parent()
        {
            return Ok(parent.to_path_buf());
        }
        return Err(Error::usage(format!(
            "not a project directory: {}",
            start.display()
        )));
    }

    loop {
        if directory.join("project.godot").is_file() {
            return Ok(directory);
        }
        if !directory.pop() {
            return Err(Error::usage(format!(
                "no project.godot found in {} or any parent directory (use --project DIR)",
                start.display()
            )));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn temp_dir(label: &str) -> PathBuf {
        let mut path = env::temp_dir();
        path.push(format!(
            "gdcli-test-{}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst),
            label
        ));
        fs::create_dir_all(&path).expect("create temp dir");
        path
    }

    #[test]
    fn finds_the_project_root_from_a_nested_directory() {
        let root = temp_dir("discover");
        fs::write(root.join("project.godot"), "config_version=5\n").unwrap();
        let nested = root.join("scenes/ui");
        fs::create_dir_all(&nested).unwrap();

        let found = discover_project(Some(&nested)).unwrap();
        assert_eq!(found, fs::canonicalize(&root).unwrap());

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn accepts_the_project_file_itself() {
        let root = temp_dir("project-file");
        let config = root.join("project.godot");
        fs::write(&config, "config_version=5\n").unwrap();

        let found = discover_project(Some(&config)).unwrap();
        assert_eq!(found, fs::canonicalize(&root).unwrap());

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn reports_a_missing_project_clearly() {
        let root = temp_dir("no-project");
        let error = discover_project(Some(&root)).unwrap_err();
        assert_eq!(error.exit_code(), 1);
        assert!(error.message().contains("no project.godot found"));

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn parses_ok_and_error_responses() {
        let data = parse_response(r#"{"id":"1","ok":true,"data":{"path":"Main"}}"#).unwrap();
        assert_eq!(data["path"], "Main");

        let error = parse_response(
            r#"{"id":"2","ok":false,"error":{"code":"NOT_FOUND","message":"missing","hint":"look"}}"#,
        )
        .unwrap_err();
        assert_eq!(error.exit_code(), 3);
        assert_eq!(error.message(), "NOT_FOUND: missing");
        assert_eq!(error.hint(), Some("look"));
    }

    #[test]
    fn maps_malformed_responses_to_a_protocol_error() {
        let error = parse_response("not json").unwrap_err();
        assert_eq!(error.exit_code(), 4);
        assert!(error.message().contains("not json"));
    }

    /// A one-shot server: accepts, answers the handshake, then closes.
    fn serve_once(protocol: u32, capabilities: &[&str]) -> PathBuf {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let address = listener.local_addr().expect("local address");
        let capabilities: Vec<String> = capabilities.iter().map(|name| name.to_string()).collect();

        std::thread::spawn(move || {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            let mut reader = BufReader::new(stream.try_clone().expect("clone stream"));
            let mut handshake = String::new();
            if reader.read_line(&mut handshake).is_err() {
                return;
            }
            let reply = json!({
                "ok": true,
                "data": {
                    "protocol": protocol,
                    "plugin_version": "0.1.0",
                    "godot": "4.7.2-stable",
                    "project": "/tmp/project",
                    "capabilities": capabilities,
                }
            });
            let _ = stream.write_all(format!("{reply}\n").as_bytes());
            let _ = stream.flush();
            // Keep the socket open until the client drops it.
            let mut rest = String::new();
            let _ = reader.read_line(&mut rest);
        });

        let project = temp_dir("endpoint");
        fs::write(project.join("project.godot"), "config_version=5\n").unwrap();
        fs::create_dir_all(project.join(".godot/gdcli")).unwrap();
        let endpoint = json!({
            "protocol": PROTOCOL,
            "plugin_version": "0.1.0",
            "port": address.port(),
            "token": "0123456789abcdef",
        });
        fs::write(Endpoint::path(&project), endpoint.to_string()).unwrap();
        project
    }

    #[test]
    fn handshakes_and_checks_capabilities() {
        let project = serve_once(PROTOCOL, &["meta.ping", "prop.get"]);
        let mut client = Client::connect(&project).unwrap();
        assert_eq!(client.ping().protocol, PROTOCOL);
        assert_eq!(client.ping().plugin_version, "0.1.0");

        let error = client.call("node.add", &json!({}), None).unwrap_err();
        assert_eq!(error.exit_code(), 4);
        assert!(error.message().contains("does not implement node.add"));

        fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn refuses_a_plugin_with_another_protocol() {
        let project = serve_once(2, &[]);
        let error = Client::connect(&project).unwrap_err();
        assert_eq!(error.exit_code(), 4);
        assert!(error.message().contains("protocol mismatch"));
        assert_eq!(error.hint(), Some("run `gdcli plugin upgrade`"));

        fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn reports_a_closed_handshake_as_a_rejected_token() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            if let Ok((stream, _)) = listener.accept() {
                drop(stream);
            }
        });

        let project = temp_dir("rejected");
        fs::write(project.join("project.godot"), "config_version=5\n").unwrap();
        fs::create_dir_all(project.join(".godot/gdcli")).unwrap();
        fs::write(
            Endpoint::path(&project),
            json!({"protocol": 1, "plugin_version": "0.1.0", "port": address.port(), "token": "x"})
                .to_string(),
        )
        .unwrap();

        let error = Client::connect(&project).unwrap_err();
        assert_eq!(error.exit_code(), 4);
        assert!(error.message().contains("token rejected"));

        fs::remove_dir_all(&project).unwrap();
    }
}
