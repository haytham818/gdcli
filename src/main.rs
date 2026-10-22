//! gdcli — drive a running Godot editor through its own APIs.

#![forbid(unsafe_code)]

mod assets;
mod client;
mod commands;
mod error;
mod install;
mod output;

use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand, ValueEnum};

use client::{Client, Opts};
use commands::Call;
use error::{Error, Result};
use output::Fmt;

#[derive(Debug, Parser)]
#[command(
    name = "gdcli",
    version,
    about = "Drive a running Godot editor through its own APIs",
    subcommand_required = true
)]
struct Cli {
    /// Godot project directory (default: walk up from the current directory)
    #[arg(
        long,
        global = true,
        help_heading = "Global options",
        value_name = "DIR"
    )]
    project: Option<PathBuf>,

    /// Print only the response data as JSON
    #[arg(
        long,
        global = true,
        help_heading = "Global options",
        conflicts_with = "quiet"
    )]
    json: bool,

    /// Print only the primary value of the response
    #[arg(long, global = true, help_heading = "Global options")]
    quiet: bool,

    /// Validate a mutating command without changing anything
    #[arg(long, global = true, help_heading = "Global options")]
    dry_run: bool,

    /// Skip the editor undo history entry for a mutating command
    #[arg(long = "no-undo", global = true, help_heading = "Global options")]
    no_undo: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Install, upgrade or inspect the editor-side plugin
    Plugin {
        #[command(subcommand)]
        command: PluginCommand,
    },
    /// Editor state
    Editor {
        #[command(subcommand)]
        command: EditorCommand,
    },
    /// Scene lifecycle and structure
    Scene {
        #[command(subcommand)]
        command: SceneCommand,
    },
    /// Scene nodes
    Node {
        #[command(subcommand)]
        command: NodeCommand,
    },
    /// Object properties
    Prop {
        #[command(subcommand)]
        command: PropCommand,
    },
    /// Signal connections
    Signal {
        #[command(subcommand)]
        command: SignalCommand,
    },
    /// Node groups
    Group {
        #[command(subcommand)]
        command: GroupCommand,
    },
    /// Resources under res://
    Res {
        #[command(subcommand)]
        command: ResCommand,
    },
    /// Project settings and autoloads
    Project {
        #[command(subcommand)]
        command: ProjectCommand,
    },
    /// The editor's filesystem scans and imports
    Fs {
        #[command(subcommand)]
        command: FsCommand,
    },
    /// Scripts open in the editor
    Script {
        #[command(subcommand)]
        command: ScriptCommand,
    },
    /// The running game's debug sessions and logs
    Game {
        #[command(subcommand)]
        command: GameCommand,
    },
    /// Send a raw protocol command
    Raw {
        /// Protocol command name, e.g. meta.capabilities
        cmd: String,
        /// JSON object with the command arguments
        #[arg(long, value_name = "JSON")]
        args: Option<String>,
    },
    /// Read NDJSON requests on stdin, stream NDJSON responses
    Batch,
}

#[derive(Debug, Subcommand)]
enum PluginCommand {
    /// Copy the embedded plugin into the project and enable it
    Install {
        /// Report what would change without writing anything
        #[arg(long)]
        check: bool,
    },
    /// Rewrite the plugin files that differ from the embedded version
    Upgrade,
    /// Compare the embedded, installed, endpoint and live plugin versions
    Status,
}

#[derive(Debug, Subcommand)]
enum EditorCommand {
    /// Project, edited scene, open scenes and play state
    Status,
    /// Undo actions in the edited scene's history
    Undo {
        /// Number of actions to undo, clamped to 1..100
        #[arg(long, default_value_t = 1, value_name = "N")]
        count: i64,
    },
    /// Redo actions in the edited scene's history
    Redo {
        /// Number of actions to redo, clamped to 1..100
        #[arg(long, default_value_t = 1, value_name = "N")]
        count: i64,
    },
    /// Print the edited scene's undo history, oldest first
    History {
        /// Maximum number of actions to show
        #[arg(long, default_value_t = 20, value_name = "N")]
        limit: i64,
    },
    /// Select one or more nodes in the editor
    Select {
        /// Node addresses
        #[arg(required = true, num_args = 1.., value_name = "PATH")]
        paths: Vec<String>,
        /// Add to the current selection instead of replacing it
        #[arg(long)]
        add: bool,
    },
    /// Open a node in the inspector
    Inspect {
        /// Node address
        target: String,
    },
    /// Switch the editor's main screen
    MainScreen {
        /// Main screen to show
        #[arg(value_enum, value_name = "SCREEN")]
        screen: MainScreen,
    },
    /// Show a toast notification in the editor
    Toast {
        /// Message to show
        message: String,
    },
    /// Save a screenshot of the editor viewport
    Screenshot {
        /// Output PNG path; parent directories are created
        #[arg(long, value_name = "PATH")]
        out: PathBuf,
        /// Which viewport to capture
        #[arg(long, value_enum, default_value = "whole", value_name = "VIEW")]
        viewport: Viewport,
    },
    /// Start playing the project
    Play {
        /// What to play
        #[arg(long, value_enum, default_value = "main", value_name = "MODE")]
        mode: PlayMode,
        /// Scene to play; requires --mode scene
        #[arg(long, value_name = "RES")]
        scene: Option<String>,
        /// Wait until the editor reports playing
        #[arg(long)]
        wait: bool,
    },
    /// Stop the running game
    Stop,
}

#[derive(Debug, Subcommand)]
enum SceneCommand {
    /// Open a scene in the editor
    Open {
        /// res:// path of the scene
        res: String,
    },
    /// Save the edited scene
    Save,
    /// Save the edited scene under another path
    SaveAs {
        /// res:// destination path
        res: String,
    },
    /// Reload a scene from disk, discarding unsaved changes
    Reload {
        /// res:// path; defaults to the edited scene
        res: Option<String>,
    },
    /// List open scene roots
    Roots,
    /// Print the edited scene tree
    Tree {
        /// Maximum depth; 0 means unlimited
        #[arg(long, default_value_t = 0, value_name = "N")]
        depth: u32,
        /// Include every non-default property
        #[arg(long)]
        props: bool,
    },
}

#[derive(Debug, Subcommand)]
enum NodeCommand {
    /// Add a node by type or by script
    Add {
        /// Node type, e.g. Sprite2D
        #[arg(value_name = "TYPE")]
        r#type: Option<String>,
        /// Script to instantiate instead of a built-in type
        #[arg(long, value_name = "RES")]
        script: Option<String>,
        /// Parent address; defaults to the edited scene root
        #[arg(long, value_name = "P")]
        parent: Option<String>,
        /// Node name
        #[arg(long, value_name = "N")]
        name: Option<String>,
        /// Position among the parent's children
        #[arg(long, value_name = "I")]
        index: Option<i64>,
    },
    /// Remove a node and its children
    Rm {
        /// Node address
        path: String,
    },
    /// Reparent a node
    Mv {
        /// Node address
        path: String,
        /// New parent address
        #[arg(long, value_name = "PARENT")]
        to: String,
        /// Position among the new parent's children
        #[arg(long, value_name = "I")]
        index: Option<i64>,
    },
    /// Duplicate a node
    Dup {
        /// Node address
        path: String,
        /// Name for the copy
        #[arg(long, value_name = "N")]
        name: Option<String>,
    },
    /// Rename a node
    Rename {
        /// Node address
        path: String,
        /// New name
        name: String,
    },
    /// Instantiate a scene as a child node
    Instance {
        /// res:// path of the scene to instantiate
        scene: String,
        /// Parent address; defaults to the edited scene root
        #[arg(long, value_name = "P")]
        parent: Option<String>,
        /// Node name
        #[arg(long, value_name = "N")]
        name: Option<String>,
        /// Position among the parent's children
        #[arg(long, value_name = "I")]
        index: Option<i64>,
    },
}

#[derive(Debug, Subcommand)]
enum PropCommand {
    /// List properties of a node or a res:// resource
    List {
        /// Node address or res:// resource
        target: String,
        /// Only properties whose name contains this string
        #[arg(long, value_name = "S")]
        filter: Option<String>,
        /// Only non-default properties
        #[arg(long)]
        changed: bool,
    },
    /// Read one property
    Get {
        /// Node address or res:// resource
        target: String,
        /// Property name
        name: String,
    },
    /// Write one property
    Set {
        /// Node address or res:// resource
        target: String,
        /// Property name
        name: String,
        /// Value, parsed according to --as
        value: String,
        /// How the engine parses the value
        #[arg(long = "as", value_enum, default_value = "gd")]
        r#as: ValueAs,
    },
    /// Restore one property to its default
    Reset {
        /// Node address or res:// resource
        target: String,
        /// Property name
        name: String,
    },
}

#[derive(Debug, Subcommand)]
enum SignalCommand {
    /// List a node's signals and their connections
    List {
        /// Node address
        target: String,
        /// Only signals that have connections
        #[arg(long)]
        connected_only: bool,
    },
    /// Connect a signal to a method
    Connect {
        /// Source node address
        source: String,
        /// Signal name
        signal: String,
        /// Target node address
        to: String,
        /// Method on the target
        method: String,
        /// Godot Object.ConnectFlags; 2 is CONNECT_PERSIST
        #[arg(long, default_value_t = commands::signal::DEFAULT_FLAGS, value_name = "N")]
        flags: i64,
        /// Allow a target or method that does not resolve yet
        #[arg(long)]
        allow_missing: bool,
    },
    /// Disconnect a signal from a method
    Disconnect {
        /// Source node address
        source: String,
        /// Signal name
        signal: String,
        /// Target node address
        to: String,
        /// Method on the target
        method: String,
    },
}

#[derive(Debug, Subcommand)]
enum GroupCommand {
    /// List a node's groups
    List {
        /// Node address
        target: String,
        /// Include engine-internal groups
        #[arg(long)]
        builtin: bool,
    },
    /// Add a node to a group
    Add {
        /// Node address
        target: String,
        /// Group name
        group: String,
    },
    /// Remove a node from a group
    Remove {
        /// Node address
        target: String,
        /// Group name
        group: String,
    },
}

#[derive(Debug, Subcommand)]
enum ResCommand {
    /// Create a new resource
    New {
        /// Resource type, e.g. Theme
        #[arg(value_name = "TYPE")]
        r#type: String,
        /// res:// destination path
        path: String,
    },
    /// Show a resource's type and name
    Info {
        /// res:// path
        path: String,
    },
    /// Copy a resource to another path
    Duplicate {
        /// res:// source path
        from: String,
        /// res:// destination path
        to: String,
    },
}

#[derive(Debug, Subcommand)]
enum ProjectCommand {
    /// Read or write a project setting
    Setting {
        #[command(subcommand)]
        command: ProjectSettingCommand,
    },
    /// List, add or remove autoload singletons
    Autoload {
        #[command(subcommand)]
        command: AutoloadCommand,
    },
}

#[derive(Debug, Subcommand)]
enum ProjectSettingCommand {
    /// Read one setting
    Get {
        /// Setting key
        key: String,
    },
    /// Write one setting
    Set {
        /// Setting key
        key: String,
        /// Value, parsed according to --as
        value: String,
        /// How the engine parses the value
        #[arg(long = "as", value_enum, default_value = "gd")]
        r#as: ValueAs,
    },
}

#[derive(Debug, Subcommand)]
enum AutoloadCommand {
    /// List autoload singletons
    List,
    /// Add an autoload singleton
    Add {
        /// Singleton name
        name: String,
        /// res:// path of the script or scene
        path: String,
    },
    /// Remove an autoload singleton
    Remove {
        /// Singleton name
        name: String,
    },
}

#[derive(Debug, Subcommand)]
enum FsCommand {
    /// Report scan and import progress
    Status,
    /// Start a filesystem scan
    Scan {
        /// Also scan the project's source directories
        #[arg(long)]
        sources: bool,
        /// Wait until scanning and importing finish
        #[arg(long)]
        wait: bool,
    },
    /// Reimport the given resources
    Reimport {
        /// res:// paths to reimport
        #[arg(required = true, num_args = 1..)]
        paths: Vec<String>,
        /// Wait until scanning and importing finish
        #[arg(long)]
        wait: bool,
    },
}

#[derive(Debug, Subcommand)]
enum ScriptCommand {
    /// Check that scripts parse
    Check {
        /// res:// paths of the scripts
        #[arg(required = true, num_args = 1..)]
        paths: Vec<String>,
    },
    /// Open a script in the editor
    Open {
        /// res:// path of the script
        path: String,
        /// Line to scroll to
        #[arg(long, default_value_t = 0, value_name = "N")]
        line: i64,
    },
    /// List open and unsaved scripts
    Files,
    /// Save every open script
    SaveAll,
}

#[derive(Debug, Subcommand)]
enum GameCommand {
    /// Report debug session count and activity
    Status,
    /// Print captured game output and errors
    Logs {
        /// Maximum number of entries to show
        #[arg(long, default_value_t = 200, value_name = "N")]
        limit: i64,
        /// Clear the captured log afterwards
        #[arg(long)]
        clear: bool,
    },
    /// Clear the captured log
    Clear,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum ValueAs {
    /// Godot literal, the inverse of var_to_str
    Gd,
    /// JSON, coerced to the property type
    Json,
    /// res:// path loaded as a Resource
    Ref,
    /// Expression evaluated in plugin context (unsafe)
    Expr,
}

impl ValueAs {
    fn as_str(self) -> &'static str {
        match self {
            ValueAs::Gd => "gd",
            ValueAs::Json => "json",
            ValueAs::Ref => "ref",
            ValueAs::Expr => "expr",
        }
    }
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum MainScreen {
    #[value(name = "2d")]
    TwoD,
    #[value(name = "3d")]
    ThreeD,
    Script,
    Assetlib,
}

impl MainScreen {
    fn as_str(self) -> &'static str {
        match self {
            MainScreen::TwoD => "2d",
            MainScreen::ThreeD => "3d",
            MainScreen::Script => "script",
            MainScreen::Assetlib => "assetlib",
        }
    }
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum Viewport {
    #[value(name = "2d")]
    TwoD,
    #[value(name = "3d")]
    ThreeD,
    Whole,
}

impl Viewport {
    fn as_str(self) -> &'static str {
        match self {
            Viewport::TwoD => "2d",
            Viewport::ThreeD => "3d",
            Viewport::Whole => "whole",
        }
    }
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum PlayMode {
    Main,
    Current,
    Scene,
}

impl PlayMode {
    fn as_str(self) -> &'static str {
        match self {
            PlayMode::Main => "main",
            PlayMode::Current => "current",
            PlayMode::Scene => "scene",
        }
    }
}

fn main() {
    std::process::exit(run());
}

fn run() -> i32 {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            let successful = matches!(
                error.kind(),
                clap::error::ErrorKind::DisplayHelp | clap::error::ErrorKind::DisplayVersion
            );
            let _ = error.print();
            return if successful { 0 } else { 1 };
        }
    };

    let format = Fmt {
        json: cli.json,
        quiet: cli.quiet,
    };
    let opts = Opts {
        undo: Some(!cli.no_undo),
        dry_run: cli.dry_run,
    };

    match dispatch(&cli, format, opts) {
        Ok(()) => 0,
        Err(error) => {
            let message = error.message();
            if !message.is_empty() {
                eprintln!("error: {message}");
            }
            if let Some(hint) = error.hint() {
                eprintln!("hint: {hint}");
            }
            error.exit_code()
        }
    }
}

fn dispatch(cli: &Cli, format: Fmt, opts: Opts) -> Result<()> {
    if let Command::Plugin { command } = &cli.command {
        let action = match command {
            PluginCommand::Install { check } => commands::plugin::Action::Install { check: *check },
            PluginCommand::Upgrade => commands::plugin::Action::Upgrade,
            PluginCommand::Status => commands::plugin::Action::Status,
        };
        return commands::plugin::run(cli.project.as_deref(), action, format);
    }

    let project = client::discover_project(cli.project.as_deref())?;

    match &cli.command {
        Command::Plugin { .. } => Err(Error::usage(
            "internal: plugin commands are handled without a connection",
        )),
        Command::Batch => {
            let mut client = Client::connect(&project)?;
            if commands::batch::run(&mut client)? {
                Err(Error::Exit(3))
            } else {
                Ok(())
            }
        }
        Command::Raw { cmd, args } => {
            let raw = commands::raw::parse(cmd, args.as_deref())?;
            let mut client = Client::connect(&project)?;
            let opts = if cli.dry_run || cli.no_undo {
                Some(opts)
            } else {
                None
            };
            let data = client.call_raw(&raw.cmd, &raw.args, opts)?;
            output::render(format, "raw", &raw.args, &data)
        }
        Command::Editor { command } => match command {
            EditorCommand::Play { mode, scene, wait } => {
                let call = commands::editor::play(mode.as_str(), scene.as_deref())?;
                if *wait {
                    execute_playing(&project, call, format, opts)
                } else {
                    execute(&project, call, format, opts)
                }
            }
            _ => {
                let call = match command {
                    EditorCommand::Status => commands::editor::status(),
                    EditorCommand::Undo { count } => commands::editor::undo(*count),
                    EditorCommand::Redo { count } => commands::editor::redo(*count),
                    EditorCommand::History { limit } => commands::editor::history(*limit)?,
                    EditorCommand::Select { paths, add } => commands::editor::select(paths, *add),
                    EditorCommand::Inspect { target } => commands::editor::inspect(target),
                    EditorCommand::MainScreen { screen } => {
                        commands::editor::main_screen(screen.as_str())
                    }
                    EditorCommand::Toast { message } => commands::editor::toast(message),
                    EditorCommand::Screenshot { out, viewport } => {
                        commands::editor::screenshot(viewport.as_str(), out)?
                    }
                    EditorCommand::Play { .. } => unreachable!("play is handled above"),
                    EditorCommand::Stop => commands::editor::stop(),
                };
                execute(&project, call, format, opts)
            }
        },
        Command::Scene { command } => {
            let call = match command {
                SceneCommand::Open { res } => commands::scene::open(res),
                SceneCommand::Save => commands::scene::save(),
                SceneCommand::SaveAs { res } => commands::scene::save_as(res),
                SceneCommand::Reload { res } => commands::scene::reload(res.as_deref()),
                SceneCommand::Roots => commands::scene::roots(),
                SceneCommand::Tree { depth, props } => commands::scene::tree(*depth, *props),
            };
            execute(&project, call, format, opts)
        }
        Command::Node { command } => {
            let call = match command {
                NodeCommand::Add {
                    r#type,
                    script,
                    parent,
                    name,
                    index,
                } => commands::node::add(
                    r#type.as_deref(),
                    script.as_deref(),
                    parent.as_deref(),
                    name.as_deref(),
                    *index,
                )?,
                NodeCommand::Rm { path } => commands::node::remove(path),
                NodeCommand::Mv { path, to, index } => commands::node::mv(path, to, *index),
                NodeCommand::Dup { path, name } => commands::node::dup(path, name.as_deref()),
                NodeCommand::Rename { path, name } => commands::node::rename(path, name),
                NodeCommand::Instance {
                    scene,
                    parent,
                    name,
                    index,
                } => commands::node::instance(scene, parent.as_deref(), name.as_deref(), *index),
            };
            execute(&project, call, format, opts)
        }
        Command::Prop { command } => {
            let call = match command {
                PropCommand::List {
                    target,
                    filter,
                    changed,
                } => commands::prop::list(target, filter.as_deref(), *changed),
                PropCommand::Get { target, name } => commands::prop::get(target, name),
                PropCommand::Set {
                    target,
                    name,
                    value,
                    r#as,
                } => commands::prop::set(target, name, value, r#as.as_str()),
                PropCommand::Reset { target, name } => commands::prop::reset(target, name),
            };
            execute(&project, call, format, opts)
        }
        Command::Signal { command } => {
            let call = match command {
                SignalCommand::List {
                    target,
                    connected_only,
                } => commands::signal::list(target, *connected_only),
                SignalCommand::Connect {
                    source,
                    signal,
                    to,
                    method,
                    flags,
                    allow_missing,
                } => commands::signal::connect(source, signal, to, method, *flags, *allow_missing),
                SignalCommand::Disconnect {
                    source,
                    signal,
                    to,
                    method,
                } => commands::signal::disconnect(source, signal, to, method),
            };
            execute(&project, call, format, opts)
        }
        Command::Group { command } => {
            let call = match command {
                GroupCommand::List { target, builtin } => commands::group::list(target, *builtin),
                GroupCommand::Add { target, group } => commands::group::add(target, group),
                GroupCommand::Remove { target, group } => commands::group::remove(target, group),
            };
            execute(&project, call, format, opts)
        }
        Command::Res { command } => {
            let call = match command {
                ResCommand::New { r#type, path } => commands::res::new(r#type, path),
                ResCommand::Info { path } => commands::res::info(path),
                ResCommand::Duplicate { from, to } => commands::res::duplicate(from, to),
            };
            execute(&project, call, format, opts)
        }
        Command::Project { command } => {
            let call = match command {
                ProjectCommand::Setting { command } => match command {
                    ProjectSettingCommand::Get { key } => commands::project::setting_get(key),
                    ProjectSettingCommand::Set { key, value, r#as } => {
                        commands::project::setting_set(key, value, r#as.as_str())
                    }
                },
                ProjectCommand::Autoload { command } => match command {
                    AutoloadCommand::List => commands::project::autoload_list(),
                    AutoloadCommand::Add { name, path } => {
                        commands::project::autoload_add(name, path)
                    }
                    AutoloadCommand::Remove { name } => commands::project::autoload_remove(name),
                },
            };
            execute(&project, call, format, opts)
        }
        Command::Fs { command } => {
            let (call, wait) = match command {
                FsCommand::Status => (commands::fs::status(), false),
                FsCommand::Scan { sources, wait } => (commands::fs::scan(*sources), *wait),
                FsCommand::Reimport { paths, wait } => (commands::fs::reimport(paths), *wait),
            };
            if wait {
                execute_waiting(&project, call, format, opts)
            } else {
                execute(&project, call, format, opts)
            }
        }
        Command::Script { command } => {
            let call = match command {
                ScriptCommand::Check { paths } => commands::script::check(paths),
                ScriptCommand::Open { path, line } => commands::script::open(path, *line),
                ScriptCommand::Files => commands::script::files(),
                ScriptCommand::SaveAll => commands::script::save_all(),
            };
            execute(&project, call, format, opts)
        }
        Command::Game { command } => {
            let call = match command {
                GameCommand::Status => commands::game::status(),
                GameCommand::Logs { limit, clear } => commands::game::logs(*limit, *clear)?,
                GameCommand::Clear => commands::game::clear(),
            };
            execute(&project, call, format, opts)
        }
    }
}

fn execute(project: &Path, call: Call, format: Fmt, opts: Opts) -> Result<()> {
    let mut client = Client::connect(project)?;
    let data = client.call(
        &call.cmd,
        &call.args,
        call.opts(opts.undo.unwrap_or(true), opts.dry_run),
    )?;
    output::render(format, &call.cmd, &call.args, &data)
}

/// Sends `fs.scan` / `fs.reimport`, waits for the filesystem to settle, then
/// renders the original response.
fn execute_waiting(project: &Path, call: Call, format: Fmt, opts: Opts) -> Result<()> {
    let mut client = Client::connect(project)?;
    let data = client.call(
        &call.cmd,
        &call.args,
        call.opts(opts.undo.unwrap_or(true), opts.dry_run),
    )?;
    commands::fs::wait(&mut client)?;
    output::render(format, &call.cmd, &call.args, &data)
}

/// Sends `editor.play`, waits for the editor to report playing, then renders the
/// response with the confirmed state.
fn execute_playing(project: &Path, call: Call, format: Fmt, opts: Opts) -> Result<()> {
    let mut client = Client::connect(project)?;
    let mut data = client.call(
        &call.cmd,
        &call.args,
        call.opts(opts.undo.unwrap_or(true), opts.dry_run),
    )?;
    commands::editor::wait(&mut client)?;
    if let Some(object) = data.as_object_mut() {
        object.insert("playing".to_string(), serde_json::Value::Bool(true));
    }
    output::render(format, &call.cmd, &call.args, &data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signal_connect_defaults_to_persistent_flags() {
        let cli = Cli::try_parse_from([
            "gdcli",
            "signal",
            "connect",
            "Btn",
            "pressed",
            "Inst",
            "on_pressed",
        ])
        .expect("parse signal connect");

        let Command::Signal {
            command:
                SignalCommand::Connect {
                    flags,
                    allow_missing,
                    ..
                },
        } = cli.command
        else {
            panic!("expected signal connect");
        };
        assert_eq!(flags, 2);
        assert!(!allow_missing);
    }

    #[test]
    fn node_instance_placement_is_optional() {
        let cli = Cli::try_parse_from(["gdcli", "node", "instance", "res://sub.tscn"])
            .expect("parse node instance");

        let Command::Node {
            command:
                NodeCommand::Instance {
                    parent,
                    name,
                    index,
                    ..
                },
        } = cli.command
        else {
            panic!("expected node instance");
        };
        assert!(parent.is_none());
        assert!(name.is_none());
        assert!(index.is_none());
    }

    #[test]
    fn reimport_and_check_need_at_least_one_path() {
        assert!(Cli::try_parse_from(["gdcli", "fs", "reimport"]).is_err());
        assert!(Cli::try_parse_from(["gdcli", "script", "check"]).is_err());
    }

    #[test]
    fn script_open_defaults_to_the_first_line() {
        let cli = Cli::try_parse_from(["gdcli", "script", "open", "res://a.gd"])
            .expect("parse script open");

        let Command::Script {
            command: ScriptCommand::Open { line, .. },
        } = cli.command
        else {
            panic!("expected script open");
        };
        assert_eq!(line, 0);
    }

    #[test]
    fn editor_select_takes_one_or_more_paths() {
        let cli = Cli::try_parse_from(["gdcli", "editor", "select", "Main", "Main/Inst", "--add"])
            .expect("parse editor select");
        let Command::Editor {
            command: EditorCommand::Select { paths, add },
        } = cli.command
        else {
            panic!("expected editor select");
        };
        assert_eq!(paths, vec!["Main".to_string(), "Main/Inst".to_string()]);
        assert!(add);

        assert!(Cli::try_parse_from(["gdcli", "editor", "select"]).is_err());
    }

    #[test]
    fn editor_inspect_main_screen_and_toast_parse() {
        let cli = Cli::try_parse_from(["gdcli", "editor", "inspect", "Inst"]).expect("inspect");
        assert!(matches!(
            cli.command,
            Command::Editor {
                command: EditorCommand::Inspect { .. }
            }
        ));

        let cli = Cli::try_parse_from(["gdcli", "editor", "main-screen", "3d"]).expect("screen");
        let Command::Editor {
            command: EditorCommand::MainScreen { screen },
        } = cli.command
        else {
            panic!("expected editor main-screen");
        };
        assert_eq!(screen.as_str(), "3d");

        let cli = Cli::try_parse_from(["gdcli", "editor", "toast", "hello"]).expect("toast");
        let Command::Editor {
            command: EditorCommand::Toast { message },
        } = cli.command
        else {
            panic!("expected editor toast");
        };
        assert_eq!(message, "hello");

        assert!(Cli::try_parse_from(["gdcli", "editor", "main-screen", "bogus"]).is_err());
    }

    #[test]
    fn editor_screenshot_needs_out_and_defaults_to_the_whole_window() {
        let cli = Cli::try_parse_from(["gdcli", "editor", "screenshot", "--out", "shot.png"])
            .expect("parse screenshot");
        let Command::Editor {
            command: EditorCommand::Screenshot { out, viewport },
        } = cli.command
        else {
            panic!("expected editor screenshot");
        };
        assert_eq!(out, PathBuf::from("shot.png"));
        assert_eq!(viewport.as_str(), "whole");

        assert!(Cli::try_parse_from(["gdcli", "editor", "screenshot"]).is_err());
        assert!(
            Cli::try_parse_from([
                "gdcli",
                "editor",
                "screenshot",
                "--out",
                "shot.png",
                "--viewport",
                "ui",
            ])
            .is_err()
        );
    }

    #[test]
    fn editor_play_defaults_to_main_without_waiting() {
        let cli = Cli::try_parse_from(["gdcli", "editor", "play"]).expect("parse play");
        let Command::Editor {
            command: EditorCommand::Play { mode, scene, wait },
        } = cli.command
        else {
            panic!("expected editor play");
        };
        assert_eq!(mode.as_str(), "main");
        assert!(scene.is_none());
        assert!(!wait);

        let cli = Cli::try_parse_from([
            "gdcli",
            "editor",
            "play",
            "--mode",
            "scene",
            "--scene",
            "res://main.tscn",
            "--wait",
        ])
        .expect("parse scene play");
        let Command::Editor {
            command: EditorCommand::Play { mode, scene, wait },
        } = cli.command
        else {
            panic!("expected editor play");
        };
        assert_eq!(mode.as_str(), "scene");
        assert_eq!(scene.as_deref(), Some("res://main.tscn"));
        assert!(wait);
    }

    #[test]
    fn editor_stop_and_game_commands_parse() {
        let cli = Cli::try_parse_from(["gdcli", "editor", "stop"]).expect("parse stop");
        assert!(matches!(
            cli.command,
            Command::Editor {
                command: EditorCommand::Stop
            }
        ));

        let cli = Cli::try_parse_from(["gdcli", "game", "status"]).expect("parse game status");
        assert!(matches!(
            cli.command,
            Command::Game {
                command: GameCommand::Status
            }
        ));

        let cli = Cli::try_parse_from(["gdcli", "game", "logs"]).expect("parse game logs");
        let Command::Game {
            command: GameCommand::Logs { limit, clear },
        } = cli.command
        else {
            panic!("expected game logs");
        };
        assert_eq!(limit, 200);
        assert!(!clear);

        let cli = Cli::try_parse_from(["gdcli", "game", "logs", "--limit", "10", "--clear"])
            .expect("parse game logs");
        let Command::Game {
            command: GameCommand::Logs { limit, clear },
        } = cli.command
        else {
            panic!("expected game logs");
        };
        assert_eq!(limit, 10);
        assert!(clear);

        let cli = Cli::try_parse_from(["gdcli", "game", "clear"]).expect("parse game clear");
        assert!(matches!(
            cli.command,
            Command::Game {
                command: GameCommand::Clear
            }
        ));
    }
}
