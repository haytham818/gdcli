---
name: gdcli
description: Drive a running Godot editor from the command line — read and edit scenes, nodes, properties, signals, input maps, screenshots and the running game through the editor's own APIs. Use whenever a task touches a Godot project, .tscn/.tres files, scene trees, or anything that would otherwise mean clicking in the Godot editor.
license: MIT
---

# gdcli

`gdcli` controls a **running Godot editor** over a local socket. Every operation is performed
by the editor itself through `EditorInterface` and `EditorUndoRedoManager`, so scene
inheritance, instanced sub-scenes and resource references survive, and each command is one
undo step named `gdcli: <cmd>`.

Use it instead of:

- editing `.tscn` / `.tres` / `project.godot` by hand (you will corrupt them),
- asking the user to click through the editor,
- installing an MCP server (its tool schemas never leave the context).

## Check the setup first

```sh
gdcli --version              # installed?
gdcli editor status         # project, open scene, play state
```

| Result | Meaning | Fix |
| --- | --- | --- |
| `gdcli: command not found` | not installed | `cargo install gdcli-cli` or `npx skills add haytham818/gdcli@gdcli -g -y` docs: <https://haytham818.github.io/gdcli/> |
| exit `2`, `no endpoint for …` | the editor is closed or the plugin is not installed | `gdcli plugin install --project <dir>`, then restart the editor |
| exit `4` | CLI and plugin versions disagree | `gdcli plugin upgrade`, then restart the editor |

Never run `gdcli project plugins disable gdcli` — it tears down the connection mid-request.

## The loop

```sh
gdcli editor status                        # 1. what is open
gdcli scene tree --json                    # 2. read before writing (paths come from here)
gdcli node add Sprite2D --name Hero --dry-run --json   # 3. check the plan
gdcli node add Sprite2D --name Hero        # 4. apply
gdcli scene tree --json                    # 5. verify
gdcli editor screenshot --out /tmp/after.png          # 6. look when layout matters
gdcli editor undo                          # 7. walk back if it went wrong
```

Always pass `--json` for machine output, and `--dry-run` before anything destructive
(`node rm`, `node mv`, `prop reset`).

## Recipes

```sh
# find things
gdcli scene roots
gdcli scene tree --depth 2 --props
gdcli prop list Hero --changed
gdcli raw meta.capabilities --quiet        # everything this plugin supports

# edit
gdcli node add Sprite2D --parent World --name Hero
gdcli prop set Hero position 'Vector2(64, 96)'
gdcli prop set Hero texture 'res://art/hero.png' --as ref
gdcli prop set Hero modulate 'Color(1, 0.5, 0.5, 1)'
gdcli node mv Hero --to Actors --index 0
gdcli node instance res://props/crate.tscn --parent World --name Crate
gdcli node rm Hero
gdcli scene save

# signals and groups
gdcli signal connect Btn pressed Player _on_pressed
gdcli signal list Btn --connected-only
gdcli group add Hero gameplay

# input map
gdcli project input add-action jump --deadzone 0.2
gdcli project input add-event jump --key Space --modifiers shift
gdcli project input add-event jump --joy-button 0

# project
gdcli project setting set application/config/description "My game"
gdcli project autoload add Game res://autoload/game.gd
gdcli fs scan --wait
gdcli script check res://player.gd

# look at it
gdcli editor screenshot --out /tmp/view.png --viewport 2d
gdcli editor play --wait
gdcli editor stop
```

Several operations at once, one connection:

```sh
printf '%s\n' '{"cmd":"scene.tree","args":{}}' '{"cmd":"prop.get","args":{"target":"Hero","name":"position"}}' | gdcli batch
```

## The running game (opt-in)

`game.*` needs the runtime autoload inside the project; install it once, then play:

```sh
gdcli runtime install
gdcli editor play --wait
gdcli game ping
gdcli game tree --depth 1
gdcli game get Inst/Label text
gdcli game set Inst/Label text '"patched"'
gdcli game eval '1 + 1'
gdcli game logs --kind error
gdcli game screenshot --out /tmp/game.png
```

Requests into the game time out after three seconds with `NO_GAME` instead of blocking the
editor. `game.logs` captures the game's own `print` / `printerr` / `push_error` /
`push_warning` output.

## Rules that prevent damage

- **Node paths are relative to the edited scene root and the root is `"."`** —
  `Inst/Label`, not `Main/Inst/Label`.
- **Never edit `.tscn`, `.tres` or `project.godot` directly.** If a command is missing, say so
  or use `gdcli raw`; do not write files behind the editor's back.
- The engine rewrites the scene header on save (`unique_id=`, uid order). Judge the semantic
  diff, not the bytes.
- Screenshots need a real renderer: under `--headless` every screenshot returns `NO_API`.
- `--as` decides how a value is parsed: `gd` (default, `str_to_var`), `json`, `ref`, `expr`.
- Exit codes: `0` ok, `1` usage, `2` not connected, `3` command failed, `4` version mismatch.

## Details

- Full command surface: `references/commands.md`
- Failure modes and their fixes: `references/troubleshooting.md`
- Design rationale and API limits: <https://haytham818.github.io/gdcli/design/>
- Wire protocol, if you need to call the socket directly: <https://haytham818.github.io/gdcli/protocol/>
