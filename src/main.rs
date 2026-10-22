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
        undo: !cli.no_undo,
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
            output::render(format, "raw", &data);
            Ok(())
        }
        Command::Editor { command } => {
            let call = match command {
                EditorCommand::Status => commands::editor::status(),
            };
            execute(&project, call, format, opts)
        }
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
    }
}

fn execute(project: &Path, call: Call, format: Fmt, opts: Opts) -> Result<()> {
    let mut client = Client::connect(project)?;
    let data = client.call(
        &call.cmd,
        &call.args,
        if call.mutating { Some(opts) } else { None },
    )?;
    output::render(format, &call.cmd, &data);
    Ok(())
}
