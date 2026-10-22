//! Human, quiet and JSON rendering. Commands only produce `data`; everything
//! the user sees is printed here.

use serde_json::{Value, json};

use crate::client::PROTOCOL;
use crate::commands::runtime::{
    AUTOLOAD_NAME, AUTOLOAD_PATH, AutoloadState, GameState, InstallState, RemoveState,
    RuntimeStatus,
};
use crate::error::{Error, Result};
use crate::install::{InstallReport, Outcome, PluginStatus};

#[derive(Debug, Clone, Copy)]
pub struct Fmt {
    pub json: bool,
    pub quiet: bool,
}

/// Renders one protocol response; `args` is the request that produced it.
pub fn render(fmt: Fmt, cmd: &str, args: &Value, data: &Value) -> Result<()> {
    if fmt.json {
        print_json(data);
        return check_failed(cmd, data);
    }
    if fmt.quiet {
        print_quiet(cmd, args, data);
        return check_failed(cmd, data);
    }

    match cmd {
        "scene.tree" | "game.tree" => render_tree(data),
        "game.eval" => render_eval(data),
        "scene.roots" => render_scene_roots(data),
        "prop.list" => render_prop_list(data),
        "editor.undo" | "editor.redo" => render_history_action(cmd, data),
        "editor.history" => render_history(data),
        "editor.play" | "editor.stop" => render_playing(cmd, data),
        "editor.screenshot" | "game.screenshot" => render_screenshot(data),
        "project.plugins.list" => render_plugins(data),
        "project.plugins.enable" | "project.plugins.disable" => render_plugin_toggle(data),
        "game.logs" => print_lines(&game_log_lines(data)),
        "signal.list" => print_lines(&signal_lines(data)),
        "group.list" => render_group_list(data),
        "script.check" => print_lines(&script_check_lines(data)),
        "script.files" => render_script_files(data),
        "project.autoload.list" => render_autoloads(data),
        "meta.capabilities" => {
            if let Some(capabilities) = data.get("capabilities").and_then(Value::as_array) {
                for capability in capabilities {
                    println!("{}", cell(capability));
                }
            }
        }
        _ => render_object(cmd, data),
    }
    check_failed(cmd, data)
}

/// `script check` is a report, but any failing path is a command failure.
fn check_failed(cmd: &str, data: &Value) -> Result<()> {
    if cmd == "script.check" && script_failed(data) {
        Err(Error::Exit(3))
    } else {
        Ok(())
    }
}

fn script_failed(data: &Value) -> bool {
    data.get("results")
        .and_then(Value::as_array)
        .is_some_and(|results| {
            results
                .iter()
                .any(|result| !result.get("ok").and_then(Value::as_bool).unwrap_or(false))
        })
}

fn print_lines(lines: &[String]) {
    for line in lines {
        println!("{line}");
    }
}

/// Renders `plugin install` / `plugin upgrade`.
pub fn install_report(fmt: Fmt, report: &InstallReport, check: bool) {
    let changed = report.changed();

    if fmt.json {
        let files: Vec<Value> = report
            .files
            .iter()
            .map(|file| json!({"path": file.path, "status": file.outcome.as_str()}))
            .collect();
        let mut payload = json!({
            "project": report.project,
            "check": check,
            "changed": changed,
            "files": files,
            "project_godot": {
                "path": "project.godot",
                "status": report.project_godot.as_str(),
            },
        });
        if let Some(gitignore) = &report.gitignore {
            payload["gitignore"] = json!({
                "path": gitignore.path,
                "entry": gitignore.entry,
                "status": gitignore.outcome.as_str(),
            });
        }
        print_json(&payload);
        return;
    }

    if fmt.quiet {
        for file in &report.files {
            if file.outcome == Outcome::Wrote {
                println!("{}", file.path);
            }
        }
        if report.project_godot == Outcome::Wrote {
            println!("project.godot");
        }
        if report
            .gitignore
            .as_ref()
            .is_some_and(|gitignore| gitignore.outcome == Outcome::Wrote)
        {
            println!(".gitignore");
        }
        return;
    }

    for file in &report.files {
        println!("{:<11} {}", file.outcome.verb(), file.path);
    }
    println!("{:<11} project.godot", report.project_godot.verb());
    if let Some(gitignore) = &report.gitignore {
        println!(
            "{:<11} {} ({})",
            gitignore.outcome.verb(),
            gitignore.path,
            gitignore.entry
        );
    }

    if report.plugin_changed() && !check {
        println!();
        println!("restart the Godot editor to load the plugin");
    }
}

/// Renders `plugin status`; never a failure path, only state.
pub fn plugin_status(fmt: Fmt, status: &PluginStatus) {
    if fmt.json {
        match serde_json::to_string_pretty(status) {
            Ok(text) => println!("{text}"),
            Err(error) => eprintln!("error: cannot serialise status: {error}"),
        }
        return;
    }
    if fmt.quiet {
        println!("{}", status.state);
        return;
    }

    println!("project: {}", status.project);
    if status.endpoint.present {
        match &status.endpoint.error {
            Some(error) => println!(
                "endpoint: present but unreadable: {} ({error})",
                status.endpoint.path
            ),
            None => println!("endpoint: present: {}", status.endpoint.path),
        }
    } else {
        println!("endpoint: missing: {}", status.endpoint.path);
    }
    println!(
        "installed: {}",
        status
            .installed_version
            .as_deref()
            .unwrap_or("not installed")
    );
    println!(
        "embedded: {}",
        status.embedded_version.as_deref().unwrap_or("unknown")
    );
    println!("cli: {}", status.cli_version);
    println!(
        "plugin: {}",
        match &status.live.plugin_version {
            Some(version) => format!("{version} (live)"),
            None => "unavailable (editor not reachable)".to_string(),
        }
    );

    let mut protocols = vec![format!("cli {PROTOCOL}")];
    let mut mismatch = false;
    if let Some(protocol) = status.endpoint.protocol {
        protocols.push(format!("endpoint {protocol}"));
        mismatch |= protocol != PROTOCOL;
    }
    if let Some(protocol) = status.live.protocol {
        protocols.push(format!("live {protocol}"));
        mismatch |= protocol != PROTOCOL;
    }
    println!(
        "protocol: {} ({})",
        protocols.join(", "),
        if mismatch { "mismatch" } else { "match" }
    );

    if status.live.reachable {
        let mut details = Vec::new();
        if let Some(godot) = &status.live.godot {
            details.push(format!("godot {godot}"));
        }
        if let Some(pid) = status.endpoint.pid {
            details.push(format!("pid {pid}"));
        }
        println!(
            "editor: reachable ({})",
            if details.is_empty() {
                "no details".to_string()
            } else {
                details.join(", ")
            }
        );
    } else {
        println!(
            "editor: unreachable: {}",
            status.live.error.as_deref().unwrap_or("no endpoint")
        );
    }
    println!("state: {}", status.state);

    if let Some(installed) = &status.installed_version
        && installed != status.cli_version
        && status.live.reachable
    {
        println!(
            "note: installed plugin is v{installed}, this CLI is v{}",
            status.cli_version
        );
    }
    if let Some(hint) = status.upgrade_hint() {
        println!("note: {hint}");
    }
}

/// Renders `runtime install`: the plugin file report plus the autoload result.
pub fn runtime_install_report(
    fmt: Fmt,
    report: &InstallReport,
    state: InstallState,
    error: Option<&str>,
) {
    if fmt.json {
        let files: Vec<Value> = report
            .files
            .iter()
            .map(|file| json!({"path": file.path, "status": file.outcome.as_str()}))
            .collect();
        let mut autoload = json!({
            "name": AUTOLOAD_NAME,
            "path": AUTOLOAD_PATH,
            "state": state.as_str(),
        });
        if let Some(error) = error {
            autoload["error"] = Value::String(error.to_string());
        }
        print_json(&json!({
            "project": report.project,
            "files": files,
            "project_godot": {
                "path": "project.godot",
                "status": report.project_godot.as_str(),
            },
            "autoload": autoload,
        }));
        return;
    }

    if fmt.quiet {
        for file in &report.files {
            if file.outcome == Outcome::Wrote {
                println!("{}", file.path);
            }
        }
        if report.project_godot == Outcome::Wrote {
            println!("project.godot");
        }
        println!("{}", state.as_str());
        return;
    }

    for file in &report.files {
        println!("{:<11} {}", file.outcome.verb(), file.path);
    }
    println!("{:<11} project.godot", report.project_godot.verb());
    match state {
        InstallState::Added => println!("{:<11} {AUTOLOAD_NAME} -> {AUTOLOAD_PATH}", "autoload"),
        InstallState::AlreadyPresent => {
            println!("{:<11} {AUTOLOAD_NAME} already present", "autoload")
        }
        InstallState::Unavailable => match error {
            Some(error) => println!("{:<11} {AUTOLOAD_NAME} not added: {error}", "autoload"),
            None => println!("{:<11} {AUTOLOAD_NAME} not added", "autoload"),
        },
    }

    if report.changed() {
        println!();
        println!("restart the Godot editor to load the plugin");
    }
}

/// Renders `runtime uninstall`; removing an absent autoload is success.
pub fn runtime_uninstall_report(fmt: Fmt, state: RemoveState) {
    if fmt.json {
        print_json(&json!({
            "name": AUTOLOAD_NAME,
            "state": state.as_str(),
        }));
        return;
    }
    if fmt.quiet {
        println!("{}", state.as_str());
        return;
    }
    match state {
        RemoveState::Removed => println!("removed autoload {AUTOLOAD_NAME}"),
        RemoveState::Absent => println!("autoload {AUTOLOAD_NAME} was not present"),
    }
}

/// Renders `runtime status`: files, autoload and live-game state in one view.
pub fn runtime_status(fmt: Fmt, status: &RuntimeStatus) {
    if fmt.json {
        let autoload = match &status.autoload {
            AutoloadState::Present { path, enabled } => json!({
                "name": AUTOLOAD_NAME,
                "state": "present",
                "path": path,
                "enabled": enabled,
            }),
            AutoloadState::Missing => json!({
                "name": AUTOLOAD_NAME,
                "state": "missing",
            }),
            AutoloadState::Unknown { error } => json!({
                "name": AUTOLOAD_NAME,
                "state": "unknown",
                "error": error,
            }),
        };
        let game = match &status.game {
            GameState::Answering {
                runtime,
                scene,
                fps,
            } => json!({
                "state": "answering",
                "runtime": runtime,
                "scene": scene,
                "fps": fps,
            }),
            GameState::NoGame => json!({"state": "no-game"}),
            GameState::Unknown { error } => json!({
                "state": "unknown",
                "error": error,
            }),
        };
        print_json(&json!({
            "project": status.project,
            "files": {"installed": status.files_installed},
            "autoload": autoload,
            "game": game,
        }));
        return;
    }

    if fmt.quiet {
        println!(
            "{}",
            if status.files_installed {
                "installed"
            } else {
                "not-installed"
            }
        );
        return;
    }

    println!("project: {}", status.project);
    println!(
        "files: {}",
        if status.files_installed {
            "installed"
        } else {
            "missing"
        }
    );
    match &status.autoload {
        AutoloadState::Present { path, enabled } => println!(
            "autoload: present -> {path}{}",
            if *enabled { "" } else { " (disabled)" }
        ),
        AutoloadState::Missing => println!("autoload: missing"),
        AutoloadState::Unknown { error } => println!("autoload: unknown ({error})"),
    }
    match &status.game {
        GameState::Answering {
            runtime,
            scene,
            fps,
        } => println!("game: running (runtime {runtime}, scene {scene}, fps {fps})"),
        GameState::NoGame => println!("game: not running"),
        GameState::Unknown { error } => println!("game: unknown ({error})"),
    }
}

fn print_json(value: &Value) {
    match serde_json::to_string_pretty(value) {
        Ok(text) => println!("{text}"),
        Err(error) => eprintln!("error: cannot serialise response: {error}"),
    }
}

fn print_quiet(cmd: &str, args: &Value, data: &Value) {
    let lines: Vec<String> = match cmd {
        "scene.roots" => entries(data, "scenes", "path"),
        "prop.list" => entries(data, "props", "name"),
        "scene.tree" | "game.tree" => entries(data, "nodes", "path"),
        "editor.history" => entries(data, "actions", "name"),
        "editor.undo" | "editor.redo" => history_action_quiet(cmd, data),
        "meta.capabilities" => entries(data, "capabilities", ""),
        "group.list" => entries(data, "groups", ""),
        "group.add" | "group.remove" => args.get("group").map(cell).into_iter().collect(),
        "signal.connect" | "signal.disconnect" => connected_method(data).into_iter().collect(),
        "editor.status" => scalar(data, "edited_scene").into_iter().collect(),
        "editor.select" => entries(data, "selection", ""),
        "editor.inspect" => scalar(data, "inspected").into_iter().collect(),
        "editor.main_screen" => scalar(data, "main_screen").into_iter().collect(),
        "editor.screenshot" | "game.screenshot" => scalar(data, "path").into_iter().collect(),
        "editor.play" => play_quiet(data),
        "editor.stop" => scalar(data, "playing").into_iter().collect(),
        "editor.toast" | "game.clear" => Vec::new(),
        "game.status" => scalar(data, "sessions").into_iter().collect(),
        "game.logs" => game_log_texts(data),
        "game.ping" => scalar(data, "runtime").into_iter().collect(),
        "game.get" | "game.set" | "game.eval" => scalar(data, "value_text").into_iter().collect(),
        "project.setting.get" => scalar(data, "value_text").into_iter().collect(),
        "project.autoload.list" => entries(data, "autoloads", "name"),
        "project.plugins.list" => entries(data, "plugins", "name"),
        "project.plugins.enable" | "project.plugins.disable" => {
            scalar(data, "name").into_iter().collect()
        }
        "fs.scan" => scalar(data, "started").into_iter().collect(),
        "fs.reimport" => scalar(data, "queued").into_iter().collect(),
        "script.check" => script_check_quiet(data),
        "script.files" => script_files_quiet(data),
        _ => primary_scalar(cmd, data).into_iter().collect(),
    };
    for line in lines {
        println!("{line}");
    }
}

fn scalar(data: &Value, key: &str) -> Option<String> {
    data.get(key).filter(|value| !value.is_null()).map(cell)
}

fn play_quiet(data: &Value) -> Vec<String> {
    if let Some(scene) = scalar(data, "scene") {
        return vec![scene];
    }
    data.get("playing").map(cell).into_iter().collect()
}

fn connected_method(data: &Value) -> Option<String> {
    let to = data.get("to")?.as_str()?;
    let method = data.get("method")?.as_str()?;
    Some(format!("{to}.{method}"))
}

fn entries(data: &Value, key: &str, field: &str) -> Vec<String> {
    let Some(items) = data.get(key).and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .map(|item| {
            if field.is_empty() {
                cell(item)
            } else {
                item.get(field).map(cell).unwrap_or_default()
            }
        })
        .collect()
}

/// The one value a script wants: a path, a rendered property value, a project.
fn primary_scalar(cmd: &str, data: &Value) -> Option<String> {
    let preferred = match cmd {
        "prop.get" | "prop.set" | "game.get" | "game.set" | "game.eval" => "value_text",
        "editor.status" | "meta.ping" => "project",
        _ => "path",
    };
    if let Some(value) = data.get(preferred)
        && !value.is_null()
    {
        return Some(cell(value));
    }
    for key in ["path", "project", "value_text", "name"] {
        if let Some(value) = data.get(key)
            && !value.is_null()
        {
            return Some(cell(value));
        }
    }
    if data.as_object().is_some_and(|object| object.is_empty()) {
        return None;
    }
    serde_json::to_string(data).ok()
}

fn render_tree(data: &Value) {
    for line in tree_lines(data) {
        println!("{line}");
    }
}

/// `scene.tree` and `game.tree` share this flat pre-order shape; indentation
/// comes from the number of separators in each node's path.
fn tree_lines(data: &Value) -> Vec<String> {
    let Some(nodes) = data.get("nodes").and_then(Value::as_array) else {
        return Vec::new();
    };
    let root_path = nodes
        .first()
        .and_then(|node| node.get("path"))
        .and_then(Value::as_str)
        .unwrap_or("");

    let mut lines = Vec::new();
    for node in nodes {
        let path = node.get("path").and_then(Value::as_str).unwrap_or("");
        let depth = if path == root_path {
            0
        } else if root_path.is_empty() || root_path == "." {
            path.matches('/').count() + 1
        } else {
            path.matches('/').count()
        };
        let name = node
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_else(|| path.rsplit('/').next().unwrap_or(path));
        let kind = node.get("type").and_then(Value::as_str).unwrap_or("?");
        let indent = "  ".repeat(depth);

        let mut line = format!("{indent}{name} ({kind})");
        if let Some(script) = node.get("script").and_then(Value::as_str) {
            line.push_str(&format!(" script={script}"));
        }
        if let Some(instance) = node.get("instance").and_then(Value::as_str) {
            line.push_str(&format!(" instance={instance}"));
        }
        lines.push(line);

        if let Some(props) = node.get("props").and_then(Value::as_object) {
            let property_indent = "  ".repeat(depth + 1);
            for (key, value) in props {
                lines.push(format!("{property_indent}{key} = {}", cell(value)));
            }
        }
    }
    lines
}

/// `game.eval` prints only the evaluated value; the type is visible in JSON.
fn render_eval(data: &Value) {
    if let Some(value) = data.get("value_text") {
        println!("{}", cell(value));
    }
}

fn render_scene_roots(data: &Value) {
    let rows = data
        .get("scenes")
        .and_then(Value::as_array)
        .map(|scenes| {
            scenes
                .iter()
                .map(|scene| {
                    vec![
                        scene
                            .get("path")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        yes_no(scene.get("unsaved").and_then(Value::as_bool)),
                    ]
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    print_table(&["SCENE", "UNSAVED"], &rows);
}

fn render_prop_list(data: &Value) {
    let rows = data
        .get("props")
        .and_then(Value::as_array)
        .map(|props| {
            props
                .iter()
                .map(|property| {
                    vec![
                        property
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        property
                            .get("type")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        property.get("value_text").map(cell).unwrap_or_default(),
                        yes_no(property.get("is_default").and_then(Value::as_bool)),
                    ]
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    print_table(&["NAME", "TYPE", "VALUE", "DEFAULT"], &rows);
}

/// One line per connection: `Btn pressed -> Inst/Label.set_text (flags 2)`.
fn signal_lines(data: &Value) -> Vec<String> {
    let target = data.get("target").and_then(Value::as_str).unwrap_or("");
    let mut lines = Vec::new();

    if let Some(signals) = data.get("signals").and_then(Value::as_array) {
        for signal in signals {
            let name = signal.get("name").and_then(Value::as_str).unwrap_or("");
            let Some(connections) = signal.get("connections").and_then(Value::as_array) else {
                continue;
            };
            for connection in connections {
                let to = connection.get("to").and_then(Value::as_str).unwrap_or("?");
                let method = connection
                    .get("method")
                    .and_then(Value::as_str)
                    .unwrap_or("?");
                let flags = connection.get("flags").and_then(Value::as_i64).unwrap_or(2);
                let prefix = if target.is_empty() {
                    name.to_string()
                } else {
                    format!("{target} {name}")
                };
                lines.push(format!("{prefix} -> {to}.{method} (flags {flags})"));
            }
        }
    }

    if lines.is_empty() {
        lines.push("no connections".to_string());
    }
    lines
}

fn render_group_list(data: &Value) {
    let names: Vec<String> = data
        .get("groups")
        .and_then(Value::as_array)
        .map(|groups| groups.iter().map(cell).collect())
        .unwrap_or_default();
    if names.is_empty() {
        println!("no groups");
    } else {
        println!("{}", names.join(", "));
    }
}

fn render_autoloads(data: &Value) {
    let Some(items) = data.get("autoloads").and_then(Value::as_array) else {
        return;
    };
    if items.is_empty() {
        println!("no autoloads");
        return;
    }
    for item in items {
        let name = item.get("name").map(cell).unwrap_or_default();
        let path = item.get("path").map(cell).unwrap_or_default();
        let enabled = item.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        let suffix = if enabled { "" } else { " (disabled)" };
        println!("{name} -> {path}{suffix}");
    }
}

/// `project plugins list`: name, state, version and path in aligned columns.
fn render_plugins(data: &Value) {
    print_table(&["NAME", "STATE", "VERSION", "PATH"], &plugin_rows(data));
}

fn plugin_rows(data: &Value) -> Vec<Vec<String>> {
    data.get("plugins")
        .and_then(Value::as_array)
        .map(|plugins| {
            plugins
                .iter()
                .map(|plugin| {
                    vec![
                        plugin.get("name").map(cell).unwrap_or_default(),
                        if plugin
                            .get("enabled")
                            .and_then(Value::as_bool)
                            .unwrap_or(false)
                        {
                            "enabled".to_string()
                        } else {
                            "disabled".to_string()
                        },
                        plugin
                            .get("version")
                            .filter(|version| !version.is_null())
                            .map(cell)
                            .filter(|version| !version.is_empty())
                            .unwrap_or_else(|| "-".to_string()),
                        plugin.get("path").map(cell).unwrap_or_default(),
                    ]
                })
                .collect()
        })
        .unwrap_or_default()
}

/// `project plugins enable|disable`: `name: enabled|disabled`.
fn render_plugin_toggle(data: &Value) {
    println!("{}", plugin_toggle_line(data));
}

fn plugin_toggle_line(data: &Value) -> String {
    let name = data.get("name").map(cell).unwrap_or_default();
    let enabled = data
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    format!("{name}: {}", if enabled { "enabled" } else { "disabled" })
}

fn script_check_lines(data: &Value) -> Vec<String> {
    let Some(results) = data.get("results").and_then(Value::as_array) else {
        return Vec::new();
    };
    results
        .iter()
        .map(|result| {
            let path = result.get("path").and_then(Value::as_str).unwrap_or("");
            if result.get("ok").and_then(Value::as_bool).unwrap_or(false) {
                return format!("{:<5} {path}", "ok");
            }
            match result.get("error").and_then(Value::as_str) {
                Some(error) if !error.is_empty() => format!("{:<5} {path}: {error}", "error"),
                _ => format!("{:<5} {path}", "error"),
            }
        })
        .collect()
}

fn script_check_quiet(data: &Value) -> Vec<String> {
    let Some(results) = data.get("results").and_then(Value::as_array) else {
        return Vec::new();
    };
    results
        .iter()
        .map(|result| {
            let path = result.get("path").and_then(Value::as_str).unwrap_or("");
            let status = if result.get("ok").and_then(Value::as_bool).unwrap_or(false) {
                "ok"
            } else {
                "error"
            };
            format!("{path}: {status}")
        })
        .collect()
}

fn render_script_files(data: &Value) {
    for (key, heading) in [("open", "open:"), ("unsaved", "unsaved:")] {
        println!("{heading}");
        if let Some(paths) = data.get(key).and_then(Value::as_array) {
            for path in paths {
                println!("  {}", cell(path));
            }
        }
    }
}

fn script_files_quiet(data: &Value) -> Vec<String> {
    let mut paths = entries(data, "open", "");
    paths.extend(entries(data, "unsaved", ""));
    paths
}

fn render_history_action(cmd: &str, data: &Value) {
    let (done_key, done_verb, would_key, would_verb, nothing) = match cmd {
        "editor.redo" => (
            "redone",
            "redid",
            "would_redo",
            "would redo",
            "nothing to redo",
        ),
        _ => (
            "undone",
            "undid",
            "would_undo",
            "would undo",
            "nothing to undo",
        ),
    };

    if let Some(would) = data.get(would_key).and_then(Value::as_array) {
        if would.is_empty() {
            println!("{nothing}");
            return;
        }
        println!(
            "{would_verb} {} {}:",
            would.len(),
            plural(would.len() as i64, "action")
        );
        for name in would {
            println!("  {}", cell(name));
        }
        return;
    }

    let count = data.get(done_key).and_then(Value::as_i64).unwrap_or(0);
    if count <= 0 {
        println!("{nothing}");
        return;
    }
    let mut line = format!("{done_verb} {count} {}", plural(count, "action"));
    if let Some(action) = data.get("action").and_then(Value::as_str) {
        line.push_str(&format!(", now at {action}"));
    }
    println!("{line}");
}

fn history_action_quiet(cmd: &str, data: &Value) -> Vec<String> {
    let (done_key, would_key) = if cmd == "editor.redo" {
        ("redone", "would_redo")
    } else {
        ("undone", "would_undo")
    };
    if let Some(count) = data.get(done_key).and_then(Value::as_i64) {
        return vec![count.to_string()];
    }
    if let Some(would) = data.get(would_key).and_then(Value::as_array) {
        return vec![would.len().to_string()];
    }
    Vec::new()
}

/// The undo stack reads chronologically: oldest first, newest at the bottom.
fn render_history(data: &Value) {
    for line in history_lines(data) {
        println!("{line}");
    }
}

fn history_lines(data: &Value) -> Vec<String> {
    let Some(actions) = data.get("actions").and_then(Value::as_array) else {
        return Vec::new();
    };

    let mut indexed: Vec<(i64, &str, bool)> = actions
        .iter()
        .enumerate()
        .map(|(position, action)| {
            (
                action
                    .get("index")
                    .and_then(Value::as_i64)
                    .unwrap_or(position as i64),
                action.get("name").and_then(Value::as_str).unwrap_or(""),
                action
                    .get("current")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            )
        })
        .collect();
    indexed.sort_by_key(|(index, _, _)| *index);

    let width = indexed
        .iter()
        .map(|(index, _, _)| index.to_string().chars().count())
        .max()
        .unwrap_or(1);

    indexed
        .into_iter()
        .map(|(index, name, current)| {
            let marker = if current { "*" } else { " " };
            format!("{index:>width$} {marker} {name}")
        })
        .collect()
}

fn plural(count: i64, noun: &str) -> String {
    if count == 1 {
        noun.to_string()
    } else {
        format!("{noun}s")
    }
}

/// `editor play` / `editor stop`: a one-line account of the play state.
fn render_playing(cmd: &str, data: &Value) {
    if cmd == "editor.stop" {
        println!("stopped");
        return;
    }
    let playing = data
        .get("playing")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    match (playing, data.get("scene").and_then(Value::as_str)) {
        (true, Some(scene)) => println!("playing {scene}"),
        (true, None) => println!("playing"),
        (false, _) => println!("not playing"),
    }
}

/// The image itself never crosses the wire; only its path and dimensions do.
fn render_screenshot(data: &Value) {
    let path = data.get("path").and_then(Value::as_str).unwrap_or("");
    let width = data.get("width").and_then(Value::as_i64).unwrap_or(0);
    let height = data.get("height").and_then(Value::as_i64).unwrap_or(0);
    println!("{path} ({width}x{height})");
}

/// One line per log entry: `<session> <kind> | <text>`, in arrival order.
fn game_log_lines(data: &Value) -> Vec<String> {
    let Some(lines) = data.get("lines").and_then(Value::as_array) else {
        return Vec::new();
    };
    if lines.is_empty() {
        return vec![
            "no debugger messages captured: Godot 4.7 prints game output to the editor console"
                .to_string(),
        ];
    }
    lines
        .iter()
        .map(|entry| {
            let session = entry.get("session").and_then(Value::as_i64).unwrap_or(0);
            let kind = entry
                .get("kind")
                .and_then(Value::as_str)
                .unwrap_or("output");
            let text = entry.get("text").map(cell).unwrap_or_default();
            format!("{session} {kind} | {text}")
        })
        .collect()
}

fn game_log_texts(data: &Value) -> Vec<String> {
    data.get("lines")
        .and_then(Value::as_array)
        .map(|lines| {
            lines
                .iter()
                .map(|entry| entry.get("text").map(cell).unwrap_or_default())
                .collect()
        })
        .unwrap_or_default()
}

fn render_object(cmd: &str, data: &Value) {
    for line in object_lines(cmd, data) {
        println!("{line}");
    }
}

fn object_lines(cmd: &str, data: &Value) -> Vec<String> {
    let Some(object) = data.as_object() else {
        return vec![cell(data)];
    };
    if object.is_empty() {
        return Vec::new();
    }

    let order = preferred_keys(cmd);
    let mut keys: Vec<&String> = order
        .iter()
        .filter_map(|key| object.get_key_value(*key).map(|(key, _)| key))
        .collect();
    for key in object.keys() {
        if !keys.contains(&key) {
            keys.push(key);
        }
    }

    let width = keys
        .iter()
        .map(|key| key.chars().count())
        .max()
        .unwrap_or(0);
    let mut lines = Vec::new();
    for key in keys {
        let Some(value) = object.get(key) else {
            continue;
        };
        let rendered = cell(value);
        if rendered.is_empty() {
            lines.push(format!("{key}:"));
        } else {
            lines.push(format!("{key:<width$}: {rendered}", width = width));
        }
    }
    lines
}

fn preferred_keys(cmd: &str) -> &'static [&'static str] {
    match cmd {
        "editor.status" => &[
            "project",
            "godot",
            "edited_scene",
            "open_scenes",
            "unsaved",
            "main_screen",
            "selection",
            "inspected",
            "playing",
            "playing_scene",
        ],
        "meta.ping" => &[
            "protocol",
            "plugin_version",
            "godot",
            "project",
            "capabilities",
        ],
        "prop.get" => &["name", "type", "value", "value_text", "is_default"],
        "prop.set" => &["name", "type", "value_text"],
        "node.add" => &["path", "type"],
        "node.instance" => &["path", "scene"],
        "res.info" => &["path", "type", "resource_name"],
        "res.new" => &["path", "type"],
        "project.setting.get" => &["key", "value_text", "type", "exists"],
        "project.setting.set" => &["key", "value_text"],
        "project.autoload.add" => &["name", "path"],
        "signal.connect" | "signal.disconnect" => &["source", "signal", "to", "method"],
        "group.add" | "group.remove" => &["target", "groups"],
        "editor.select" => &["selection"],
        "editor.inspect" => &["inspected"],
        "editor.main_screen" => &["main_screen"],
        "editor.screenshot" => &["path", "width", "height"],
        "editor.play" => &["playing", "scene"],
        "editor.stop" => &["playing"],
        "game.status" => &["sessions", "active"],
        "game.ping" => &["runtime", "scene", "fps"],
        "game.get" | "game.set" => &["name", "type", "value_text"],
        "game.eval" => &["type", "value_text"],
        "fs.status" => &["scanning", "progress", "importing"],
        "script.save_all" => &["saved"],
        _ => &["path", "type", "project", "name", "value_text"],
    }
}

fn print_table(headers: &[&str], rows: &[Vec<String>]) {
    for line in table_lines(headers, rows) {
        println!("{line}");
    }
}

fn table_lines(headers: &[&str], rows: &[Vec<String>]) -> Vec<String> {
    let mut widths: Vec<usize> = headers
        .iter()
        .map(|header| header.chars().count())
        .collect();
    for row in rows {
        for (index, item) in row.iter().enumerate() {
            if let Some(width) = widths.get_mut(index) {
                *width = (*width).max(item.chars().count());
            }
        }
    }

    let mut lines = Vec::with_capacity(rows.len() + 1);
    let mut line = String::new();
    for (index, header) in headers.iter().enumerate() {
        line.push_str(&format!("{header:<width$}", width = widths[index]));
        if index + 1 < headers.len() {
            line.push_str("  ");
        }
    }
    lines.push(line.trim_end().to_string());

    for row in rows {
        let mut line = String::new();
        for (index, item) in row.iter().enumerate() {
            if index >= headers.len() {
                break;
            }
            line.push_str(&format!("{item:<width$}", width = widths[index]));
            if index + 1 < headers.len() {
                line.push_str("  ");
            }
        }
        lines.push(line.trim_end().to_string());
    }
    lines
}

fn yes_no(value: Option<bool>) -> String {
    if value.unwrap_or(false) {
        "yes".to_string()
    } else {
        String::new()
    }
}

fn cell(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        Value::Array(items) if items.iter().any(Value::is_object) => {
            serde_json::to_string(value).unwrap_or_default()
        }
        Value::Array(items) => items.iter().map(cell).collect::<Vec<_>>().join(", "),
        Value::Object(_) => serde_json::to_string(value).unwrap_or_default(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn editor_status_lists_the_m3_state_in_order() {
        let data = json!({
            "project": "/p",
            "godot": "4.7.2-stable",
            "edited_scene": "res://main.tscn",
            "open_scenes": ["res://main.tscn"],
            "unsaved": [],
            "main_screen": "2d",
            "selection": ["Main", "Inst"],
            "inspected": "Inst",
            "playing": true,
            "playing_scene": "res://main.tscn",
        });

        let lines = object_lines("editor.status", &data);
        let keys: Vec<&str> = lines
            .iter()
            .map(|line| line.split(':').next().unwrap_or("").trim_end())
            .collect();
        assert_eq!(
            keys,
            vec![
                "project",
                "godot",
                "edited_scene",
                "open_scenes",
                "unsaved",
                "main_screen",
                "selection",
                "inspected",
                "playing",
                "playing_scene",
            ]
        );

        let value = |key: &str| {
            lines
                .iter()
                .find(|line| line.split(':').next().unwrap_or("").trim_end() == key)
                .and_then(|line| line.split_once(':'))
                .map(|(_, value)| value.trim().to_string())
                .unwrap()
        };
        assert_eq!(value("main_screen"), "2d");
        assert_eq!(value("selection"), "Main, Inst");
        assert_eq!(value("inspected"), "Inst");
    }

    #[test]
    fn game_logs_render_session_kind_and_text() {
        let data = json!({
            "lines": [
                {"kind": "output", "session": 0, "text": "ready"},
                {"kind": "error", "session": 1, "text": "boom"},
            ],
        });
        assert_eq!(
            game_log_lines(&data),
            vec!["0 output | ready", "1 error | boom"]
        );
        assert_eq!(game_log_texts(&data), vec!["ready", "boom"]);

        assert_eq!(
            game_log_lines(&json!({"lines": []})),
            vec![
                "no debugger messages captured: Godot 4.7 prints game output to the editor console"
            ]
        );
        assert!(game_log_lines(&json!({})).is_empty());
        assert!(game_log_texts(&json!({})).is_empty());
    }

    #[test]
    fn history_marks_the_current_action_and_right_aligns_indexes() {
        let data = json!({
            "count": 3,
            "current": 1,
            "actions": [
                {"index": 0, "name": "gdcli: node.add", "current": false},
                {"index": 1, "name": "gdcli: prop.set", "current": true},
                {"index": 2, "name": "gdcli: node.rm", "current": false},
            ],
        });
        assert_eq!(
            history_lines(&data),
            vec![
                "0   gdcli: node.add",
                "1 * gdcli: prop.set",
                "2   gdcli: node.rm",
            ]
        );
    }

    #[test]
    fn history_pads_two_digit_indexes() {
        let data = json!({
            "count": 2,
            "current": 10,
            "actions": [
                {"index": 9, "name": "nine", "current": false},
                {"index": 10, "name": "ten", "current": true},
            ],
        });
        assert_eq!(history_lines(&data), vec![" 9   nine", "10 * ten"]);
    }

    #[test]
    fn history_falls_back_to_position_without_indexes() {
        let data = json!({"actions": [{"name": "first"}, {"name": "second"}]});
        assert_eq!(history_lines(&data), vec!["0   first", "1   second"]);
    }

    #[test]
    fn signal_lines_name_the_target_signal_and_connection() {
        let data = json!({
            "target": "Btn",
            "signals": [
                {
                    "name": "pressed",
                    "args": 0,
                    "connections": [
                        {"to": "Inst/Label", "method": "set_text", "flags": 2},
                        {"to": "Inst", "method": "hide", "flags": 1},
                    ],
                },
                {
                    "name": "toggled",
                    "args": 1,
                    "connections": [{"to": "Inst", "method": "toggle"}],
                },
            ],
        });
        assert_eq!(
            signal_lines(&data),
            vec![
                "Btn pressed -> Inst/Label.set_text (flags 2)",
                "Btn pressed -> Inst.hide (flags 1)",
                "Btn toggled -> Inst.toggle (flags 2)",
            ]
        );
    }

    #[test]
    fn signal_lines_report_no_connections() {
        assert_eq!(
            signal_lines(&json!({"target": "Btn", "signals": []})),
            vec!["no connections"]
        );
        assert_eq!(
            signal_lines(&json!({
                "target": "Btn",
                "signals": [{"name": "pressed", "args": 0, "connections": []}],
            })),
            vec!["no connections"]
        );
    }

    #[test]
    fn game_tree_uses_the_scene_tree_renderer() {
        let data = json!({
            "scene": "res://main.tscn",
            "nodes": [
                {"path": ".", "name": "Main", "type": "Node2D"},
                {"path": "Hero", "name": "Hero", "type": "Sprite2D",
                 "props": {"position": "Vector2(1, 2)"}},
                {"path": "Hero/Label", "name": "Label", "type": "Label"},
            ],
        });
        assert_eq!(
            tree_lines(&data),
            vec![
                "Main (Node2D)",
                "  Hero (Sprite2D)",
                "    position = Vector2(1, 2)",
                "    Label (Label)",
            ]
        );
    }

    #[test]
    fn game_get_renders_the_name_type_and_value() {
        let data = json!({"name": "position", "type": "Vector2", "value_text": "Vector2(3, 4)"});
        assert_eq!(
            object_lines("game.get", &data),
            vec![
                "name      : position",
                "type      : Vector2",
                "value_text: Vector2(3, 4)",
            ]
        );
    }

    #[test]
    fn game_set_renders_the_same_three_keys() {
        let data = json!({"name": "position", "type": "Vector2", "value_text": "Vector2(3, 4)"});
        let lines = object_lines("game.set", &data);
        assert_eq!(
            lines.first().map(String::as_str),
            Some("name      : position")
        );
        assert!(lines.contains(&"value_text: Vector2(3, 4)".to_string()));
    }

    #[test]
    fn plugins_list_aligns_state_version_and_path() {
        let data = json!({
            "plugins": [
                {
                    "name": "alpha",
                    "path": "res://addons/alpha",
                    "enabled": true,
                    "version": "1.2.3",
                },
                {
                    "name": "a-longer-name",
                    "path": "res://addons/a-longer-name",
                    "enabled": false,
                    "version": null,
                },
            ],
        });
        let lines = table_lines(&["NAME", "STATE", "VERSION", "PATH"], &plugin_rows(&data));
        assert_eq!(lines.len(), 3);
        assert_eq!(
            lines[0].split_whitespace().collect::<Vec<_>>(),
            vec!["NAME", "STATE", "VERSION", "PATH"]
        );
        assert_eq!(
            lines[1].split_whitespace().collect::<Vec<_>>(),
            vec!["alpha", "enabled", "1.2.3", "res://addons/alpha"]
        );
        assert_eq!(
            lines[2].split_whitespace().collect::<Vec<_>>(),
            vec![
                "a-longer-name",
                "disabled",
                "-",
                "res://addons/a-longer-name"
            ]
        );

        // The state and path columns start at the same offset in every row.
        assert_eq!(lines[1].find("enabled"), lines[2].find("disabled"));
        assert_eq!(
            lines[1].find("res://addons/alpha"),
            lines[2].find("res://addons/a-longer-name")
        );
    }

    #[test]
    fn plugin_toggle_line_reports_the_confirmed_state() {
        assert_eq!(
            plugin_toggle_line(&json!({"name": "alpha", "enabled": true})),
            "alpha: enabled"
        );
        assert_eq!(
            plugin_toggle_line(&json!({"name": "beta", "enabled": false})),
            "beta: disabled"
        );
    }

    #[test]
    fn script_check_lines_mark_ok_and_errors() {
        let data = json!({
            "results": [
                {"path": "res://a.gd", "ok": true},
                {"path": "res://b.gd", "ok": false, "error": "parse error"},
                {"path": "res://c.gd", "ok": false},
            ],
        });
        assert_eq!(
            script_check_lines(&data),
            vec![
                "ok    res://a.gd",
                "error res://b.gd: parse error",
                "error res://c.gd",
            ]
        );
        assert!(script_failed(&data));

        assert_eq!(
            script_check_quiet(&data),
            vec!["res://a.gd: ok", "res://b.gd: error", "res://c.gd: error"]
        );
    }
}
