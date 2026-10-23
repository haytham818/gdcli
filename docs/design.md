# gdcli

A CLI that lets an agent drive a **running Godot editor** through its own APIs, instead of
patching `.tscn` text or installing an MCP server that floods the prompt with tool schemas.

## Why not the alternatives

### **MCP server**  
the tool schemas (dozens of them) sit in the conversation forever. The transport is not the problem; the surface is. A CLI keeps the surface in the shell.

### **Editing `.tscn` by hand**  
inheritance and instanced scenes are not representable as text patches without a lossless parser, and a bad patch makes the engine refuse the file.

### **Runtime `PackedScene` round-trip** (`instantiate()` + `pack()`) 
flattens the inherited root (godot#27243) and loses instance ownership.

### **PTY/AT-SPI/xdotool automation**  
Godot's AccessKit tree exposes editor chrome only (buttons, tabs, dock shells) on current release (4.7.2) : 107 nodes, zero `tree item`, zero `menu item`, no `EditableText`. Scene content and menus are invisible to it.

### **PTY-free GUI process injection**  
the release binary is fully stripped (`nm` symtab 0), so `gdb call` needs a per-version C++ shim; and injection only reaches the same `EditorInterface` API a plugin already has.

A plugin is the only supported way in, and it is the cheapest of all of them.

## Architecture

```
agent/human ──▶ gdcli (Rust) ──NDJSON/tcp 127.0.0.1 ──▶ EditorPlugin (GDScript)
                                                                  ├─ EditorInterface
                                                                  ├─ EditorUndoRedoManager
                                                                  └─ EditorFileSystem

                     opt-in: ──gdcli:req/gdcli:res (debugger)──▶ GdcliRuntime (game autoload)
```

## Layout

```
assets/addons/gdcli/         GDScript plugin, embedded into the binary
  plugin.cfg                 name, version, entry script
  plugin.gd                  lifecycle, socket, main-thread queue, deferred replies
  debug_capture.gd           EditorDebuggerPlugin: ring buffer and game-message routing
  runtime/gdcli_runtime.gd   in-game autoload: bridge, log capture, screenshots
  commands/*.gd              one module per command group (meta, editor, scene, node, prop,
                             signal, group, res, project, fs, script, game, input)
src/                         CLI: clap surface, wire client, installers, renderers
docs/                        design + protocol
tests/fixture/               throwaway Godot project (instanced scene, prints on run)
scripts/e2e.sh               headless and xvfb end-to-end suite
scripts/install.{sh,ps1}     release installers
```

## What the editor API actually can and cannot do

By dumping the `ClassDB`, we can see what the editor API actually can and cannot do.

Available: scene open/close/save/save-as/reload, open + unsaved scene roots, node
add/remove/reparent/duplicate/rename/instance, property read/write/reset on any object (nodes
and `res://` resources), signal connect/disconnect, groups, resource create/inspect/duplicate,
script check/open/save, project settings, autoloads, input map, plugin enable/disable,
filesystem scan/reimport, editor UI (main screen, selection, inspector, toasts, play/stop,
2d/3d/whole-window screenshots), writes to the command palette, and — through the opt-in game
runtime — the running game's scene tree, properties, console output and screenshots.

Not possible, and therefore not exposed:

1. **Editable children / editing inside an instance.** `Node` only has
   `set_scene_instance_load_placeholder`; the editable flag has no scripting API.
2. **New inherited scene.** `EditorSceneManager` is C++-only; `SceneState` is read-only.
3. **Gizmo drags and viewport picking.** Set transforms as properties instead.
4. **Editing a non-current open scene.** `get_open_scene_roots()` reads them; writing means
   switching the active scene, which is visible to the user.
5. **Sending commands to the running game** needs a project-side autoload, installed with
   `gdcli runtime install`: the editor sends `gdcli:req` and `GdcliRuntime` answers
   `gdcli:res`. Without it every `game.*` call is `NO_GAME`.
6. **Reading a local game's stdout through the debugger.** 4.7 only carries `game_view:*`
   messages, so the runtime installs a `Logger` and forwards the game's own output; that is
   what `game.logs` reads. Without the autoload it stays empty.
7. **Switching built-in bottom panels.** Only panels owned by the plugin are addressable via
   `EditorPlugin`; the rest would need UI-tree spelunking that breaks across versions.
8. **Listing or invoking someone else's command palette entries.** `EditorCommandPalette`
   exposes only `add_command`/`remove_command`, so the plugin registers and lists its own.

Side effects to document for users: saving through the engine rewrites the scene header
(adds `unique_id`, reorders uids), so diffs are noisy; the plugin's undo entries appear in
the user's history as `gdcli: <cmd>`.

## Features

**Scene editing** — `scene open/save/save-as/reload/roots/tree`, `node
add/rm/mv/dup/rename/instance`, property `get/set/list/reset` on nodes and `res://`
resources, `signal connect/disconnect`, `group add/remove`, `editor undo/redo/history`, and
`--dry-run` on every mutation.

**Project data** — project settings, autoloads, the input map (actions plus key, mouse and
joypad bindings), plugin enable/disable, filesystem scan/reimport, and script
check/open/save.

**Editor UI** — selection, inspector, main screen switching, toasts, 2d/3d/whole-window
screenshots, and play/stop with `--wait`.

**Running game** (opt-in, `gdcli runtime install`) — `game ping/tree/get/set/eval`,
`screenshot`, and captured `logs`; requests time out after 3 s instead of blocking the
editor.

**For agents** — `--json` and `--quiet` on everything, `batch` for NDJSON pipelines, `raw`
for commands the CLI does not wrap, one undo action per request, and `--private` to keep the
plugin out of a shared repository.

**For humans** — a few `gdcli:` entries in the editor's command palette that trigger the same
actions from the editor side.

## Testing

`scripts/e2e.sh` drives a real editor: a headless pass covers commands and asserts the saved
`.tscn` keeps `instance=ExtResource` and its overrides; `E2E_GUI=1` adds an xvfb pass that
checks screenshots are real PNGs, the game runtime round-trips, and game output is captured.
CI runs it together with `cargo fmt`/`clippy`/`test` and `cargo test` on macOS and Windows.

Tooling note: the editor's command-line scene argument races the first filesystem scan, so a
client that connects as soon as `endpoint.json` exists may see no edited scene yet —
`gdcli scene open` (or a retry) is the reliable path.

Tooling note for GUI tests: run the editor with `WAYLAND_DISPLAY` unset and
`--display-driver x11` under `xvfb-run`. With `WAYLAND_DISPLAY` inherited, the editor runs on
the real Wayland session and the game it spawns (`--display-driver wayland --wid ...`) never
initialises its scene tree, so the runtime autoload never runs and every `game.*` call times
out.

## Conventions

* Every mutating request is one undoable action, validated before it mutates.
* `Node.get_path()` is never used as an address (it returns editor-internal paths).
* The plugin never blocks the main thread; slow work returns an `op` id.
* The plugin must survive bad input: validate arguments, return `BAD_ARGS`, never crash the
  editor, because a plugin crash takes the user's unsaved work with it.
* **One version string**, `assets/addons/gdcli/plugin.cfg`. `Cargo.toml` must carry the same
  value and `src/assets.rs` fails the build if it does not; `plugin.gd` and the runtime read it
  from that file at runtime instead of declaring a constant, and `scripts/e2e.sh` asserts
  CLI == installed plugin.cfg == live plugin == runtime version.
* An exported game does not ship `plugin.cfg`, so `game.ping.runtime` reports `unknown` there.
  The bridge only matters when the game runs from the editor, so that is acceptable.
