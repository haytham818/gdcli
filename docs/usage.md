# Usage

Every command takes `--project DIR` (default: walk up from the current directory),
`--json`, `--quiet`, and — for mutations — `--dry-run` and `--no-undo`.

## Inspect

```sh
gdcli editor status          # open scenes and play state
gdcli scene roots            # every open scene
gdcli scene tree --depth 2   # the scene as a tree
gdcli scene tree --props     # ...with properties
gdcli prop list Hero --changed
```

`scene tree` prints names with their type and marks instanced scenes:

```text
Main (Node2D)
  Inst (Node2D) instance=res://sub.tscn
    Label (Label)
  Hero (Sprite2D)
```

## Edit a scene

```sh
gdcli node add Sprite2D --parent Main --name Hero
gdcli prop set Hero position 'Vector2(64, 96)'
gdcli prop set Hero texture 'res://art/hero.png' --as ref
gdcli node mv Hero --to World --index 0
gdcli node instance res://props/crate.tscn --parent World --name Crate
gdcli scene save
```

Each of those is one undo step:

```sh
gdcli editor history --limit 5
gdcli editor undo --count 1
gdcli editor redo
```

!!! tip "Look before you leap"

    `--dry-run` validates the whole command and returns the planned operations without
    touching the scene:

    ```json
    {
      "path": "Ghost",
      "planned": [{ "op": "add_child", "parent": ".", "type": "Node2D", "node": "Ghost" }]
    }
    ```

### Values

The engine parses the value, so there is no type table to keep in sync:

| `--as` | Example | Parser |
| --- | --- | --- |
| `gd` (default) | `'Vector2(64, 96)'`, `'Color(1,0,0,1)'` | `str_to_var`, the inverse of `var_to_str` |
| `json` | `'{"a": 1}'` | `JSON.parse_string`, coerced to the property's type |
| `ref` | `'res://art/hero.png'` | `load()` |
| `expr` | `'Vector2(1, 2) * 3'` | `Expression` — arbitrary code, use with care |

## Signals and groups

```sh
gdcli signal connect Btn pressed Player _on_pressed
gdcli signal list Btn --connected-only
gdcli signal disconnect Btn pressed Player _on_pressed
gdcli group add Hero gameplay
gdcli group list Hero
```

Connections are written persistent (`CONNECT_PERSIST`), so they end up in the `.tscn` as
`[connection ...]` and in the user's undo history.

## Project data

```sh
gdcli project setting set application/config/description "My game"
gdcli project autoload add Game res://autoload/game.gd
gdcli project plugins list
gdcli project plugins disable probe
gdcli fs scan --wait
gdcli script check res://player.gd res://enemy.gd
```

The input map has its own small event DSL — keys, mouse buttons, joypad buttons and axes:

```sh
gdcli project input add-action jump --deadzone 0.2
gdcli project input add-event jump --key Space --modifiers shift
gdcli project input add-event jump --joy-button 0
gdcli project input list --action jump
```

```text
jump (deadzone 0.2)
  [0] key key=Space modifiers=shift
  [1] joy_button button=0 device=-1
```

## Screenshots and play

```sh
gdcli editor screenshot --out shot.png            # whole editor window
gdcli editor screenshot --out view.png --viewport 2d
gdcli editor play --wait
gdcli editor stop
```

Screenshots are written by the editor itself; the CLI only hands over a path. That means they
need a real renderer — see [Install](install.md#troubleshooting).

## The running game

The game side is opt-in. Install the runtime autoload once, then play:

```sh
gdcli runtime install
gdcli editor play --wait
gdcli game ping
gdcli game tree --depth 1
gdcli game get Inst/Label text
gdcli game set Inst/Label text '"patched"'
gdcli game eval '1 + 1'
gdcli game logs --kind error
gdcli game screenshot --out game.png
```

Requests into the game time out after three seconds (`NO_GAME`) instead of blocking the
editor. `game.logs` captures the game's own `print`, `printerr`, `push_error` and
`push_warning` output — the runtime forwards it, because Godot's debugger does not carry it.

## Several operations at once

`batch` keeps one connection for a whole NDJSON pipeline, which is much cheaper than starting
over per command:

```sh
printf '%s\n' \
  '{"cmd":"scene.tree","args":{}}' \
  '{"cmd":"prop.get","args":{"target":"Hero","name":"position"}}' \
  | gdcli batch
```

`raw` sends a single protocol command the CLI does not wrap:

```sh
gdcli raw meta.ping
```
