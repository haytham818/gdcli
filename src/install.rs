//! `plugin install` / `plugin upgrade` / `plugin status`.

use std::fs;
use std::io::ErrorKind;
use std::path::Path;

use serde::Serialize;

use crate::assets;
use crate::client::{Client, Endpoint, PROTOCOL};
use crate::error::{Error, Result};

/// Entry this CLI adds to `project.godot`'s `[editor_plugins] enabled`.
pub const PLUGIN_PATH: &str = "res://addons/gdcli/plugin.cfg";

const INSTALLED_CFG: &str = "addons/gdcli/plugin.cfg";

/// Entry `--private` appends to the project's `.gitignore`.
pub const GITIGNORE_ENTRY: &str = "addons/gdcli/";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Wrote,
    Unchanged,
    WouldWrite,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Wrote => "wrote",
            Outcome::Unchanged => "unchanged",
            Outcome::WouldWrite => "would-write",
        }
    }

    pub fn verb(self) -> &'static str {
        match self {
            Outcome::Wrote => "wrote",
            Outcome::Unchanged => "unchanged",
            Outcome::WouldWrite => "would write",
        }
    }
}

pub struct FileReport {
    pub path: &'static str,
    pub outcome: Outcome,
}

/// The `.gitignore` patch `plugin install --private` performs.
pub struct GitignoreReport {
    pub path: &'static str,
    pub entry: &'static str,
    pub outcome: Outcome,
}

pub struct InstallReport {
    pub project: String,
    pub files: Vec<FileReport>,
    pub project_godot: Outcome,
    /// `Some` only for `--private`.
    pub gitignore: Option<GitignoreReport>,
}

impl InstallReport {
    pub fn changed(&self) -> bool {
        self.plugin_changed()
            || self
                .gitignore
                .as_ref()
                .is_some_and(|gitignore| gitignore.outcome != Outcome::Unchanged)
    }

    /// Whether the editor has to restart to pick up the install.
    pub fn plugin_changed(&self) -> bool {
        self.project_godot != Outcome::Unchanged
            || self
                .files
                .iter()
                .any(|file| file.outcome != Outcome::Unchanged)
    }
}

/// Writes the embedded plugin into the project and enables it.
///
/// With `private`, also adds `addons/gdcli/` to the project's `.gitignore`;
/// `check` reports that write without performing it.
pub fn install(project: &Path, check: bool, private: bool) -> Result<InstallReport> {
    let mut files = Vec::with_capacity(assets::FILES.len());
    for asset in assets::FILES {
        files.push(write_asset(project, asset, check)?);
    }

    let config_path = project.join("project.godot");
    let text = fs::read_to_string(&config_path)
        .map_err(|error| Error::usage(format!("cannot read {}: {error}", config_path.display())))?;
    let (patched, changed) = enable_plugin(&text, PLUGIN_PATH)?;
    let project_godot = if !changed {
        Outcome::Unchanged
    } else if check {
        Outcome::WouldWrite
    } else {
        fs::write(&config_path, patched).map_err(|error| {
            Error::usage(format!("cannot write {}: {error}", config_path.display()))
        })?;
        Outcome::Wrote
    };

    let gitignore = if private {
        Some(patch_gitignore(project, check)?)
    } else {
        None
    };

    Ok(InstallReport {
        project: project.display().to_string(),
        files,
        project_godot,
        gitignore,
    })
}

/// Adds `GITIGNORE_ENTRY` to `<project>/.gitignore`, creating the file when
/// missing. Existing bytes and line endings are preserved.
fn patch_gitignore(project: &Path, check: bool) -> Result<GitignoreReport> {
    let path = project.join(".gitignore");
    let current = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == ErrorKind::NotFound => String::new(),
        Err(error) => {
            return Err(Error::usage(format!(
                "cannot read {}: {error}",
                path.display()
            )));
        }
    };

    let (patched, changed) = add_gitignore_entry(&current, GITIGNORE_ENTRY);
    let outcome = if !changed {
        Outcome::Unchanged
    } else if check {
        Outcome::WouldWrite
    } else {
        fs::write(&path, patched)
            .map_err(|error| Error::usage(format!("cannot write {}: {error}", path.display())))?;
        Outcome::Wrote
    };

    Ok(GitignoreReport {
        path: ".gitignore",
        entry: GITIGNORE_ENTRY,
        outcome,
    })
}

/// Appends `entry` to a `.gitignore` unless an equivalent pattern is present,
/// keeping the file's line endings.
pub fn add_gitignore_entry(text: &str, entry: &str) -> (String, bool) {
    if text.lines().any(|line| ignores_entry(line, entry)) {
        return (text.to_string(), false);
    }

    let newline = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let mut output = String::with_capacity(text.len() + entry.len() + newline.len());
    output.push_str(text);
    if !text.is_empty() && !text.ends_with('\n') {
        output.push_str(newline);
    }
    output.push_str(entry);
    output.push_str(newline);
    (output, true)
}

/// Whether one `.gitignore` line ignores the same directory as `entry`.
fn ignores_entry(line: &str, entry: &str) -> bool {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') || line.starts_with('!') {
        return false;
    }
    normalise_pattern(line) == normalise_pattern(entry)
}

fn normalise_pattern(pattern: &str) -> &str {
    pattern.trim_start_matches('/').trim_end_matches('/')
}

fn write_asset(project: &Path, asset: &assets::Asset, check: bool) -> Result<FileReport> {
    let destination = project.join(asset.path);
    let current = match fs::read(&destination) {
        Ok(bytes) => Some(bytes),
        Err(error) if error.kind() == ErrorKind::NotFound => None,
        Err(error) => {
            return Err(Error::usage(format!(
                "cannot read {}: {error}",
                destination.display()
            )));
        }
    };

    if current.as_deref() == Some(asset.content.as_bytes()) {
        return Ok(FileReport {
            path: asset.path,
            outcome: Outcome::Unchanged,
        });
    }
    if check {
        return Ok(FileReport {
            path: asset.path,
            outcome: Outcome::WouldWrite,
        });
    }

    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            Error::usage(format!("cannot create {}: {error}", parent.display()))
        })?;
    }
    fs::write(&destination, asset.content).map_err(|error| {
        Error::usage(format!("cannot write {}: {error}", destination.display()))
    })?;
    Ok(FileReport {
        path: asset.path,
        outcome: Outcome::Wrote,
    })
}

/// Inserts `plugin` into `[editor_plugins] enabled`, touching nothing else.
///
/// Returns the patched text and whether it differs from the input.
pub fn enable_plugin(text: &str, plugin: &str) -> Result<(String, bool)> {
    let mut lines: Vec<String> = text.split('\n').map(str::to_string).collect();

    if let Some(start) = lines
        .iter()
        .position(|line| body(line).trim() == "[editor_plugins]")
    {
        let end = lines
            .iter()
            .enumerate()
            .skip(start + 1)
            .find(|(_, line)| is_section_header(body(line)))
            .map(|(index, _)| index)
            .unwrap_or(lines.len());

        let enabled =
            (start + 1..end).find(|&index| key_value(body(&lines[index]), "enabled").is_some());
        let Some(index) = enabled else {
            // Section exists, key does not: insert the key right below the header.
            let newline = if lines[start].ends_with('\r') {
                "\r"
            } else {
                ""
            };
            lines.insert(
                start + 1,
                format!("enabled=PackedStringArray(\"{plugin}\"){newline}"),
            );
            return Ok((lines.join("\n"), true));
        };

        let line_body = body(&lines[index]);
        let Some(value) = key_value(line_body, "enabled") else {
            return Err(unpatchable());
        };
        let value_start = line_body.len() - value.len();
        let entries = quoted_strings(value).unwrap_or_default();
        if entries.iter().any(|entry| entry == plugin) {
            return Ok((text.to_string(), false));
        }

        let new_value = push_entry(value, plugin)?;
        let patched = format!("{}{}", &line_body[..value_start], new_value);
        lines[index] = if lines[index].ends_with('\r') {
            format!("{patched}\r")
        } else {
            patched
        };
        return Ok((lines.join("\n"), true));
    }

    // No section at all: append one, keeping every existing line intact.
    let newline = if text.contains("\r\n") { "\r" } else { "" };
    let mut output = lines;
    if output.last().is_none_or(|line| !line.is_empty()) {
        output.push(String::new());
    }
    if output.len() >= 2 && !body(&output[output.len() - 2]).trim().is_empty() {
        output.insert(output.len() - 1, newline.to_string());
    }
    output.insert(output.len() - 1, format!("[editor_plugins]{newline}"));
    output.insert(
        output.len() - 1,
        format!("enabled=PackedStringArray(\"{plugin}\"){newline}"),
    );
    Ok((output.join("\n"), true))
}

fn unpatchable() -> Error {
    Error::usage("cannot patch [editor_plugins]: `enabled` is not a PackedStringArray")
}

/// Appends `plugin` to a `PackedStringArray(...)` value, preserving its spacing.
fn push_entry(value: &str, plugin: &str) -> Result<String> {
    let (Some(open), Some(close)) = (value.find('('), value.rfind(')')) else {
        return Err(unpatchable());
    };
    if close < open || !value[..open].trim_end().ends_with("PackedStringArray") {
        return Err(unpatchable());
    }
    let inner = &value[open + 1..close];
    let tail = &value[close + 1..];
    let entries = quoted_strings(inner).unwrap_or_default();
    let inner = if entries.is_empty() {
        format!("\"{plugin}\"")
    } else {
        format!("{}, \"{plugin}\"", inner.trim_end())
    };
    Ok(format!("{}({inner}){tail}", &value[..open]))
}

/// Naive ConfigFile section header check; strings never start a line here.
fn is_section_header(line: &str) -> bool {
    let line = line.trim();
    line.starts_with('[') && line.ends_with(']')
}

fn body(line: &str) -> &str {
    line.strip_suffix('\r').unwrap_or(line)
}

fn key_value<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let line = line.trim_start();
    let after = line.strip_prefix(key)?;
    if !after.starts_with('=') && !after.starts_with(char::is_whitespace) {
        return None;
    }
    let after = after.trim_start();
    let value = after.strip_prefix('=')?;
    Some(value.trim_start())
}

/// Double-quoted strings inside a Godot array literal; `None` when unbalanced.
fn quoted_strings(text: &str) -> Option<Vec<String>> {
    let mut entries = Vec::new();
    let mut characters = text.chars();
    while let Some(character) = characters.next() {
        if character != '"' {
            continue;
        }
        let mut entry = String::new();
        let mut escaped = false;
        let mut closed = false;
        for character in characters.by_ref() {
            if escaped {
                entry.push(character);
                escaped = false;
            } else if character == '\\' {
                entry.push(character);
                escaped = true;
            } else if character == '"' {
                closed = true;
                break;
            } else {
                entry.push(character);
            }
        }
        if !closed {
            return None;
        }
        entries.push(entry);
    }
    Some(entries)
}

#[derive(Debug, Serialize)]
pub struct PluginStatus {
    pub project: String,
    pub state: &'static str,
    pub cli_version: &'static str,
    pub embedded_version: Option<String>,
    pub installed_version: Option<String>,
    pub endpoint: EndpointStatus,
    pub live: LiveStatus,
}

#[derive(Debug, Serialize)]
pub struct EndpointStatus {
    pub present: bool,
    pub path: String,
    pub protocol: Option<u32>,
    pub plugin_version: Option<String>,
    pub pid: Option<u32>,
    pub godot: Option<String>,
    pub project: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct LiveStatus {
    pub reachable: bool,
    pub plugin_version: Option<String>,
    pub protocol: Option<u32>,
    pub godot: Option<String>,
    pub project: Option<String>,
    pub capabilities: Vec<String>,
    pub error: Option<String>,
}

impl PluginStatus {
    pub fn is_ok(&self) -> bool {
        self.state == "ok"
    }

    /// `None` when the editor answered with a matching protocol and version.
    pub fn upgrade_hint(&self) -> Option<&'static str> {
        if self.state == "ok" {
            return None;
        }
        if self.live.reachable {
            return Some("run `gdcli plugin upgrade`, then restart the Godot editor");
        }
        if self.installed_version.as_deref() != Some(self.cli_version) {
            return Some("run `gdcli plugin install` or `gdcli plugin upgrade`");
        }
        Some("start the Godot editor with the plugin enabled")
    }
}

/// Inspects installed, endpoint and live plugin state without failing the CLI.
pub fn status(project: &Path) -> PluginStatus {
    let cli_version = env!("CARGO_PKG_VERSION");
    let endpoint_path = Endpoint::path(project);
    let installed_version = fs::read_to_string(project.join(INSTALLED_CFG))
        .ok()
        .and_then(|text| assets::plugin_version(&text));

    let mut endpoint = EndpointStatus {
        present: endpoint_path.is_file(),
        path: endpoint_path.display().to_string(),
        protocol: None,
        plugin_version: None,
        pid: None,
        godot: None,
        project: None,
        error: None,
    };
    let mut live = LiveStatus {
        reachable: false,
        plugin_version: None,
        protocol: None,
        godot: None,
        project: None,
        capabilities: Vec::new(),
        error: None,
    };

    if endpoint.present {
        match Endpoint::read(project) {
            Ok(parsed) => {
                endpoint.protocol = Some(parsed.protocol);
                endpoint.plugin_version = Some(parsed.plugin_version);
                endpoint.pid = parsed.pid;
                endpoint.godot = parsed.godot;
                endpoint.project = parsed.project;

                match Client::connect(project) {
                    Ok(client) => {
                        let ping = client.ping();
                        live.reachable = true;
                        live.plugin_version = Some(ping.plugin_version.clone());
                        live.protocol = Some(ping.protocol);
                        live.godot = Some(ping.godot.clone());
                        live.project = Some(ping.project.clone());
                        live.capabilities = ping.capabilities.clone();
                    }
                    Err(error) => live.error = Some(error.message()),
                }
            }
            Err(error) => endpoint.error = Some(error.message()),
        }
    }

    let state = if live.reachable
        && live.protocol == Some(PROTOCOL)
        && live.plugin_version.as_deref() == Some(cli_version)
    {
        "ok"
    } else if live.reachable {
        "mismatch"
    } else if endpoint.present || installed_version.is_some() {
        "no-editor"
    } else {
        "not-installed"
    };

    PluginStatus {
        project: project.display().to_string(),
        state,
        cli_version,
        embedded_version: assets::embedded_version(),
        installed_version,
        endpoint,
        live,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENABLED: &str = "enabled=PackedStringArray(\"res://addons/gdcli/plugin.cfg\")";

    #[test]
    fn appends_the_section_when_it_is_missing() {
        let text = "config_version=5\n\n[application]\n\nconfig/name=\"fixture\"\n";
        let (patched, changed) = enable_plugin(text, PLUGIN_PATH).unwrap();

        assert!(changed);
        assert!(patched.starts_with(text));
        assert!(patched.ends_with(&format!("\n\n[editor_plugins]\n{ENABLED}\n")));

        // Running again is a no-op.
        let (again, changed) = enable_plugin(&patched, PLUGIN_PATH).unwrap();
        assert!(!changed);
        assert_eq!(again, patched);
    }

    #[test]
    fn appends_a_missing_trailing_newline_before_the_section() {
        let text = "config_version=5\n\n[application]\n\nconfig/name=\"fixture\"";
        let (patched, changed) = enable_plugin(text, PLUGIN_PATH).unwrap();

        assert!(changed);
        assert_eq!(patched, format!("{text}\n\n[editor_plugins]\n{ENABLED}\n"));
    }

    #[test]
    fn keeps_existing_entries_when_adding_to_the_array() {
        let text = concat!(
            "config_version=5\n",
            "\n",
            "[editor_plugins]\n",
            "\n",
            "enabled=PackedStringArray(\"res://addons/other/plugin.cfg\")\n",
            "\n",
            "[rendering]\n",
            "\n",
            "renderer/rendering_method=\"gl_compatibility\"\n",
        );
        let (patched, changed) = enable_plugin(text, PLUGIN_PATH).unwrap();

        assert!(changed);
        assert_eq!(
            patched,
            concat!(
                "config_version=5\n",
                "\n",
                "[editor_plugins]\n",
                "\n",
                "enabled=PackedStringArray(\"res://addons/other/plugin.cfg\", \"res://addons/gdcli/plugin.cfg\")\n",
                "\n",
                "[rendering]\n",
                "\n",
                "renderer/rendering_method=\"gl_compatibility\"\n",
            )
        );
    }

    #[test]
    fn inserts_the_key_into_an_existing_section() {
        let text = "[editor_plugins]\n\n[rendering]\n";
        let (patched, _) = enable_plugin(text, PLUGIN_PATH).unwrap();

        assert_eq!(
            patched,
            format!("[editor_plugins]\n{ENABLED}\n\n[rendering]\n")
        );
        assert_eq!(enable_plugin(&patched, PLUGIN_PATH).unwrap().0, patched);
    }

    #[test]
    fn leaves_an_already_enabled_plugin_byte_identical() {
        let text = "[editor_plugins]\nenabled = PackedStringArray(\"res://addons/other/plugin.cfg\" , \"res://addons/gdcli/plugin.cfg\")\n";
        let (patched, changed) = enable_plugin(text, PLUGIN_PATH).unwrap();

        assert!(!changed);
        assert_eq!(patched, text);
    }

    #[test]
    fn handles_empty_arrays() {
        let (patched, changed) = enable_plugin(
            "[editor_plugins]\nenabled=PackedStringArray()\n",
            PLUGIN_PATH,
        )
        .unwrap();

        assert!(changed);
        assert_eq!(patched, format!("[editor_plugins]\n{ENABLED}\n"));
    }

    #[test]
    fn preserves_crlf_line_endings() {
        let text = "config_version=5\r\n\r\n[application]\r\n";
        let (patched, changed) = enable_plugin(text, PLUGIN_PATH).unwrap();

        assert!(changed);
        assert_eq!(
            patched,
            format!(
                "config_version=5\r\n\r\n[application]\r\n\r\n[editor_plugins]\r\n{ENABLED}\r\n"
            )
        );
    }

    #[test]
    fn refuses_a_value_it_cannot_parse() {
        let error = enable_plugin("[editor_plugins]\nenabled=true\n", PLUGIN_PATH).unwrap_err();
        assert_eq!(error.exit_code(), 1);
        assert!(error.message().contains("PackedStringArray"));
    }

    fn temp_project(label: &str) -> std::path::PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "gdcli-install-test-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            label
        ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("project.godot"), "config_version=5\n").unwrap();
        path
    }

    #[test]
    fn appends_the_gitignore_entry_after_existing_content() {
        let (patched, changed) = add_gitignore_entry(".godot/\n*.tmp\n", GITIGNORE_ENTRY);
        assert!(changed);
        assert_eq!(patched, ".godot/\n*.tmp\naddons/gdcli/\n");
    }

    #[test]
    fn adds_the_missing_newline_before_the_gitignore_entry() {
        let (patched, changed) = add_gitignore_entry(".godot/", GITIGNORE_ENTRY);
        assert!(changed);
        assert_eq!(patched, ".godot/\naddons/gdcli/\n");
    }

    #[test]
    fn leaves_an_already_ignored_addon_untouched() {
        for text in [
            ".godot/\naddons/gdcli/\n",
            "addons/gdcli\n",
            "/addons/gdcli/\n",
            "  addons/gdcli/  \r\n",
        ] {
            assert_eq!(
                add_gitignore_entry(text, GITIGNORE_ENTRY),
                (text.to_string(), false),
                "unexpected change for {text:?}"
            );
        }
    }

    #[test]
    fn preserves_crlf_line_endings_in_gitignore() {
        let (patched, changed) = add_gitignore_entry(".godot\r\n", GITIGNORE_ENTRY);
        assert!(changed);
        assert_eq!(patched, ".godot\r\naddons/gdcli/\r\n");
    }

    #[test]
    fn creates_the_gitignore_file_when_missing() {
        let project = temp_project("gitignore-create");
        let report = patch_gitignore(&project, false).unwrap();

        assert_eq!(report.path, ".gitignore");
        assert_eq!(report.entry, GITIGNORE_ENTRY);
        assert_eq!(report.outcome, Outcome::Wrote);
        assert_eq!(
            fs::read_to_string(project.join(".gitignore")).unwrap(),
            "addons/gdcli/\n"
        );

        // A second run is a no-op.
        let again = patch_gitignore(&project, false).unwrap();
        assert_eq!(again.outcome, Outcome::Unchanged);

        fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn check_reports_the_gitignore_write_without_touching_it() {
        let project = temp_project("gitignore-check-missing");
        let report = patch_gitignore(&project, true).unwrap();

        assert_eq!(report.outcome, Outcome::WouldWrite);
        assert!(!project.join(".gitignore").exists());

        fs::write(project.join(".gitignore"), ".godot/\n").unwrap();
        let report = patch_gitignore(&project, true).unwrap();
        assert_eq!(report.outcome, Outcome::WouldWrite);
        assert_eq!(
            fs::read_to_string(project.join(".gitignore")).unwrap(),
            ".godot/\n"
        );

        fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn install_check_does_not_create_the_gitignore() {
        let project = temp_project("install-check");
        let report = install(&project, true, true).unwrap();

        assert!(
            report
                .gitignore
                .as_ref()
                .is_some_and(|gitignore| { gitignore.outcome == Outcome::WouldWrite })
        );
        assert!(!project.join(".gitignore").exists());

        fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn install_private_writes_the_gitignore_and_reports_it() {
        let project = temp_project("install-private");
        let report = install(&project, false, true).unwrap();

        assert!(report.changed());
        assert!(report.plugin_changed());
        assert_eq!(report.gitignore.as_ref().unwrap().outcome, Outcome::Wrote);
        assert_eq!(
            fs::read_to_string(project.join(".gitignore")).unwrap(),
            "addons/gdcli/\n"
        );

        fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn install_without_private_leaves_the_gitignore_alone() {
        let project = temp_project("install-no-private");
        let report = install(&project, false, false).unwrap();

        assert!(report.gitignore.is_none());
        assert!(!project.join(".gitignore").exists());

        fs::remove_dir_all(&project).unwrap();
    }
}
