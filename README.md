# gdcli

Drive a running Godot editor from the command line — no MCP server, no `.tscn` patching.

The CLI talks NDJSON over loopback to a small `EditorPlugin` living in your project, and the
editor performs each operation through `EditorInterface` and `EditorUndoRedoManager`. That
means scene inheritance, instanced sub-scenes and resource references are handled by the
engine, edits land in your undo history, and nothing is written that Godot cannot parse.

## Install

Three ways, all producing the same single binary:

```sh
# 1. from source
cargo install --path .        # or: cargo install --git https://github.com/haytham818/gdcli

# 2. prebuilt binary (linux/macos)
curl -fsSL https://github.com/haytham818/gdcli/releases/latest/download/install.sh | sh

# 3. prebuilt binary (windows)
irm https://github.com/haytham818/gdcli/releases/latest/download/install.ps1 | iex
```

The installers accept `GDCLI_VERSION` (pin a release), `GDCLI_INSTALL_DIR` (default
`~/.local/bin` on unix, `%LOCALAPPDATA%\gdcli\bin` on Windows) and verify the download
against the release's `SHA256SUMS`. `install.sh` also respects `GDCLI_BASE_URL` for mirrors.

Then wire it into a project:

```sh
gdcli plugin install --project /path/to/game   # writes addons/gdcli and enables it
# restart the Godot editor once
gdcli editor status
```

`--private` additionally gitignores `addons/gdcli/` so the bridge never reaches a shared
repository; `--check` reports what would change without writing anything.

Requirements: Godot 4.4+ (developed against 4.7.2), Linux/macOS/Windows, and Python 3 only
if you want to run the end-to-end suite.

## Use

```sh
gdcli editor status
gdcli scene tree --depth 2
gdcli node add Sprite2D --parent Main --name Hero
gdcli prop set Hero position 'Vector2(64, 96)'
gdcli prop set Hero texture 'res://art/hero.png' --as ref
gdcli scene save
```

Every mutation is one undoable step named `gdcli: <cmd>`, and `--dry-run` returns the plan
without touching anything. `gdcli batch` takes NDJSON on stdin when an agent needs several
operations in one connection.

## Requirements

Godot 4.4+ (developed against 4.7.2). The plugin is plain GDScript; there is no native
component and nothing version-pinned.

## Status

M1: plugin install/status, editor status, scene open/save/save-as/reload/tree/roots, node
add/rm/mv/dup/rename, property get/set/list/reset, raw passthrough, batch.

See `docs/DESIGN.md` for what the editor API cannot do, and `docs/PROTOCOL.md` for the wire
format.
