# gdcli

Drive a running Godot editor from the command line — no MCP server, no `.tscn` patching.

The CLI talks NDJSON over loopback to a small `EditorPlugin` living in your project, and the
editor performs each operation through `EditorInterface` and `EditorUndoRedoManager`. That
means scene inheritance, instanced sub-scenes and resource references are handled by the
engine, edits land in your undo history, and nothing is written that Godot cannot parse.

## Install

```sh
cargo install --path .
gdcli plugin install --project /path/to/game   # writes addons/gdcli and enables it
# restart the Godot editor once
```

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
