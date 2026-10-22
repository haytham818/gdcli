# gdcli

A CLI that lets an agent drive a **running Godot editor** through its own APIs, instead of
patching `.tscn` text or installing an MCP server that floods the prompt with tool schemas.

## Why not the alternatives

* **MCP server** — the tool schemas (dozens of them) sit in the conversation forever. The
  transport is not the problem; the surface is. A CLI keeps the surface in the shell.
* **Editing `.tscn` by hand** — inheritance and instanced scenes are not representable as
  text patches without a lossless parser, and a bad patch makes the engine refuse the file.
* **Runtime `PackedScene` round-trip** (`instantiate()` + `pack()`) — flattens the inherited
  root (godot#27243) and loses instance ownership. Verified locally.
* **PTY/AT-SPI/xdotool automation** — Godot's AccessKit tree exposes editor chrome only
  (buttons, tabs, dock shells). Verified on 4.7.2: 107 nodes, zero `tree item`, zero
  `menu item`, no `EditableText`. Scene content and menus are invisible to it.
* **PTY-free GUI process injection** — the release binary is fully stripped (`nm` symtab 0),
  so `gdb call` needs a per-version C++ shim; and injection only reaches the same
  `EditorInterface` API a plugin already has.

A plugin is the only supported way in, and it is the cheapest of all of them.

## Architecture

```
agent ──▶ gdcli (Rust, single binary) ──NDJSON/tcp 127.0.0.1──▶ EditorPlugin (GDScript)
                                                                  ├─ EditorInterface
                                                                  ├─ EditorUndoRedoManager
                                                                  └─ EditorFileSystem
```

* Rust 2024 edition. Dependencies: `clap` (derive), `serde`, `serde_json`. No async — one
  blocking loopback connection with a line protocol is enough and keeps lifetimes simple.
* Plugin assets are embedded in the binary with `include_str!` and installed by
  `gdcli plugin install`, which also enables them in `project.godot`'s `[editor_plugins]`.
  First install requires an editor restart.
* Protocol: see `docs/PROTOCOL.md`.

## Layout

```
assets/addons/gdcli/         GDScript plugin, embedded into the binary
  plugin.cfg
  plugin.gd                  lifecycle, socket, main-thread queue, dispatch
  commands/{meta,editor,scene,node,prop}.gd
src/                         CLI
docs/                        design + protocol
tests/fixture/               throwaway Godot project (instanced scene) for E2E
scripts/e2e.sh               launch editor, run commands, assert the saved .tscn
```

## What the editor API actually can and cannot do (4.7.2)

Available: scene open/close/save/save-as/reload, open + unsaved scene roots, node
add/remove/reparent/duplicate/rename, property read/write/reset on any object (nodes and
`res://` resources), signal connect/disconnect, groups, instancing a sub-scene as a child,
script check/open/goto, project settings, autoloads, input map, plugin enable/disable,
filesystem scan/reimport, editor UI (main screen, bottom panel, selection, inspector,
toasts, play/stop, 2D/3D viewport screenshots), and read-only access to a running game's
output and remote tree via `EditorDebuggerPlugin._capture`.

Not possible, and therefore not exposed:

1. **Editable children / editing inside an instance.** `Node` only has
   `set_scene_instance_load_placeholder`; the editable flag has no scripting API.
2. **New inherited scene.** `EditorSceneManager` is C++-only; `SceneState` is read-only.
3. **Gizmo drags and viewport picking.** Set transforms as properties instead.
4. **Editing a non-current open scene.** `get_open_scene_roots()` reads them; writing means
   switching the active scene, which is visible to the user.
5. **Sending commands to the running game.** `EditorDebuggerSession.send_message` works,
   but the game needs an `EngineDebugger` capture registered — that is a runtime autoload,
   tracked as M4 (`gdcli runtime install`).
6. **Command palette listing/execution.** `EditorCommandPalette` exposes only
   `add_command`/`remove_command`; the plugin registers into it instead.

Side effects to document for users: saving through the engine rewrites the scene header
(adds `unique_id`, reorders uids), so diffs are noisy; the plugin's undo entries appear in
the user's history as `gdcli: <cmd>`.

## Milestones

* **M1** — `plugin install/status`, `editor status`, `scene open/save/save-as/tree/roots`,
  `node add/rm/mv/dup/rename`, `prop get/set/list/reset`, `raw`, `batch`, undo + dry-run.
* **M2** — signals, groups, instancing as a child, resources, project/autoload/input,
  filesystem scan/reimport, script check/open.
* **M3** — editor UI operations, screenshots, play/stop, read-only game state.
* **M4** — optional runtime autoload for game-side writes.

## Conventions

* Every mutating request is one undoable action, validated before it mutates.
* `Node.get_path()` is never used as an address (it returns editor-internal paths).
* The plugin never blocks the main thread; slow work returns an `op` id.
* The plugin must survive bad input: validate arguments, return `BAD_ARGS`, never crash the
  editor, because a plugin crash takes the user's unsaved work with it.
