# gdcli command surface

Every command accepts `--project DIR`, `--json`, `--quiet`; mutating ones also accept
`--dry-run` and `--no-undo`. `<path>` values are relative to the edited scene root (`"."` is
the root). `<target>` is a node path or a `res://x.tres` resource.

## Editor

| Command | Purpose |
| --- | --- |
| `editor status` | project, Godot version, edited scene, open scenes, unsaved, main screen, selection, play state |
| `editor undo [--count N]` / `editor redo` / `editor history [--limit N]` | the edited scene's undo stack |
| `editor select <path...> [--add]` | select nodes |
| `editor inspect <target>` | show an object in the inspector |
| `editor main-screen <2d\|3d\|script\|assetlib>` | switch the main screen |
| `editor toast <message>` | show a notification in the editor |
| `editor screenshot --out FILE [--viewport 2d\|3d\|whole]` | real PNG, written by the editor |
| `editor play [--mode main\|current\|scene] [--scene res] [--wait]` / `editor stop` | run the project |
| `editor palette list` / `editor palette run <name>` | the three `gdcli:` command-palette entries |

## Scene and nodes

| Command | Purpose |
| --- | --- |
| `scene roots` | every open scene |
| `scene tree [--depth N] [--props]` | the edited scene as a tree |
| `scene open <res>` / `scene save` / `scene save-as <res>` / `scene reload` | scene lifecycle |
| `node add <Type> [--script res] [--parent P] [--name N] [--index I]` | create a node |
| `node rm <path>` / `node mv <path> --to <parent> [--index I]` / `node dup <path> [--name N]` / `node rename <path> <name>` | move, copy, delete |
| `node instance <res> [--parent P] [--name N]` | instantiate another scene as a child |

## Properties

| Command | Purpose |
| --- | --- |
| `prop list <target> [--filter S] [--changed]` | list properties |
| `prop get <target> <name>` | read one |
| `prop set <target> <name> <value> [--as gd\|json\|ref\|expr]` | write one |
| `prop reset <target> <name>` | restore the default |

`--as` modes: `gd` = `str_to_var` (`Vector2(1, 2)`, `Color(1,0,0,1)`, `[1,2]`), `json` = parse
then coerce, `ref` = `load()` a `res://` path, `expr` = evaluate a GDScript expression.

## Signals, groups, resources

| Command | Purpose |
| --- | --- |
| `signal list <target> [--connected-only]` / `signal connect <src> <signal> <to> <method> [--flags N] [--allow-missing]` / `signal disconnect …` | connections |
| `group list <target> [--builtin]` / `group add <target> <group>` / `group remove <target> <group>` | groups |
| `res new <Type> <res>` / `res info <res>` / `res duplicate <from> <to>` | resources (properties via `prop`) |

## Project

| Command | Purpose |
| --- | --- |
| `project setting get <key>` / `project setting set <key> <value> [--as]` | project settings |
| `project autoload list` / `add <name> <res>` / `remove <name>` | singletons |
| `project plugins list` / `enable <name>` / `disable <name>` | editor plugins by name |
| `project input actions` / `list [--action N]` / `add-action` / `remove-action` / `rename-action` / `add-event` / `remove-event` | input map |
| `fs status` / `fs scan [--sources] [--wait]` / `fs reimport <path...> [--wait]` | imports |
| `script check <path...>` / `script open <path> [--line N]` / `script files` / `script save-all` | scripts |

Input events accept `--key K`, `--physical-key K`, `--mouse B`, `--joy-button N`,
`--joy-axis N --axis-value F`, `--json SPEC` or `--raw TEXT`, plus `--modifiers` and
`--device`.

## Running game (needs `runtime install`)

| Command | Purpose |
| --- | --- |
| `runtime install` / `runtime uninstall` / `runtime status` | the `GdcliRuntime` autoload |
| `game ping` / `game status` | runtime version, scene, fps, session state |
| `game tree [--depth N] [--props]` / `game get <path> <prop>` / `game set <path> <prop> <value> [--as]` | live scene tree and properties |
| `game eval <expr> [--path P]` | evaluate GDScript inside the game (arbitrary code) |
| `game logs [--limit N] [--clear] [--kind output\|error\|warning]` | captured game output |
| `game screenshot --out FILE` | the game's own viewport |

## Escape hatches

| Command | Purpose |
| --- | --- |
| `raw <cmd> [--args '<json>']` | any protocol command, including `meta.capabilities` |
| `batch` | NDJSON requests on stdin, one connection, responses in order |
| `plugin install [--check] [--private] [--with-skill]` / `plugin status` / `plugin upgrade` | the bridge itself |
