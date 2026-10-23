# gdcli wire protocol (v1)

The CLI never edits `.tscn` text. It talks to a small `EditorPlugin` running inside the
user's Godot editor, and the editor performs every operation through `EditorInterface`
and `EditorUndoRedoManager`.

Both sides are implemented against this document. Change it first, then the code.

## 1. Discovery

The plugin writes an endpoint file when it comes up:

```
<project>/.godot/gdcli/endpoint.json
```

```json
{
  "protocol": 1,
  "plugin_version": "0.9.1",
  "port": 41234,
  "token": "9f2c...64 hex chars",
  "pid": 745244,
  "project": "/abs/path/to/project",
  "godot": "4.7.2-stable"
}
```

`<project>` is `ProjectSettings.globalize_path("res://")`. `.godot/` is already ignored by
Godot's own `.gitignore`, so the file never reaches the repository.

The CLI locates the project by walking up from `--project` (default: cwd) until it finds
`project.godot`. Only loopback addresses are used.

The plugin deletes the endpoint file on `_exit_tree`.

## 2. Framing

NDJSON over TCP, one request per line, one response per line, UTF-8, `\n` terminated.
Maximum line length 1 MiB; exceeding it is a protocol error and the connection closes.

Requests are processed **serially on the editor main thread**. There is at most one
in-flight request per connection. The server must never block the main thread: anything
asynchronous (filesystem scans, imports) returns an `op` id instead of waiting.

## 3. Handshake

The first line the client sends is:

```json
{"token": "<token from endpoint.json>", "protocol": 1}
```

The server replies with the `meta.ping` payload, or closes the connection without a
reply when the token is wrong.

```json
{"ok": true, "data": {
  "protocol": 1,
  "plugin_version": "0.9.1",
  "godot": "4.7.2-stable",
  "project": "/abs/path",
  "capabilities": ["scene.open", "node.add", "..."]
}}
```

`capabilities` lists the command names the plugin implements. The CLI uses it to fail
early with a useful message instead of sending an unknown command.

## 4. Requests and responses

```json
{"id": "3", "cmd": "node.add", "args": {"type": "Sprite2D", "name": "Hero"},
 "opts": {"undo": true, "dry_run": false}}
```

`opts.undo` defaults to `true`, `opts.dry_run` to `false`. `id` is echoed back.

```json
{"id": "3", "ok": true, "data": {"path": "Hero", "type": "Sprite2D"}}
{"id": "3", "ok": false, "error": {"code": "NOT_FOUND", "message": "node 'Hero' not found",
                                    "hint": "run `gdcli scene tree`"}}
```

`error.code` is one of:

| code | meaning |
| --- | --- |
| `UNKNOWN_CMD` | command not implemented by this plugin version |
| `BAD_ARGS` | missing/invalid argument |
| `NOT_FOUND` | node, resource or scene does not exist |
| `NO_SCENE` | no edited scene is open |
| `NO_API` | the engine version lacks the required API |
| `NO_GAME` | no running game, or it has no `GdcliRuntime` autoload |
| `GODOT_ERROR` | an engine call returned an error |
| `INTERNAL` | unexpected failure; `message` carries the detail |

`dry_run` runs every validation and returns the same `data` the real call would, plus
`"planned": [{"op": "add_child", "parent": "Main", "node": "Hero"}]`, without mutating
anything.

Every mutating command that can be expressed as an undoable action commits exactly one
`UndoRedo` action named `gdcli: <cmd>`, with the edited scene root as its context, so it
appears as a single step in the user's Ctrl+Z. `opts.undo: false` skips the action and
mutates directly (bulk/batch use).

## 5. Addressing

* `""` or `"."` — the edited scene root. Addresses never include the root's own name;
  `Main/Inst` and `Inst` are both accepted on input, and `"."`/`Inst`/`Inst/Label` are what
  the plugin emits.
* `"res://main.tscn::Main/Inst"` — an explicit scene. Only the currently edited scene is
  writable; other scenes are read-only and return `NO_API` on mutation.
* A bare `"res://x.tres"` target means the `Resource` at that path, for `prop.*` only.

`Node.get_path()` is **never** used to build or compare addresses: inside a plugin it
returns editor-internal paths such as `/root/@EditorNode@19544/.../Main`. Always compute
paths relative to `EditorInterface.get_edited_scene_root()`.

## 6. Value parsing (`prop.set --as`)

The CLI passes the value through as a string plus a mode; the engine parses it.

| `as` | parser |
| --- | --- |
| `gd` (default) | `str_to_var`, the inverse of `var_to_str`: `Vector2(10, 20)`, `Color(1,0,0,1)`, `[1,2]`, `{"a":1}`, `NodePath("..")` |
| `json` | `JSON.parse_string`, then coerced to the current property type |
| `ref` | treated as a `res://` path and `load()`ed |
| `expr` | `Expression.parse/execute` in plugin context — arbitrary code, documented as unsafe |

## 7. Core commands

`data` shapes are exact; extra fields may be added later, never removed.

### meta

| cmd | args | data |
| --- | --- | --- |
| `meta.ping` | — | see handshake payload |
| `meta.capabilities` | — | `{"capabilities": [...]}` |

### editor

| cmd | args | data |
| --- | --- | --- |
| `editor.status` | — | `{"project","godot","edited_scene","open_scenes":[str],"unsaved":[str],"playing":bool,"playing_scene"}` |
| `editor.undo` | `{"count":int=1}` | `{"undone":int,"action":str?,"can_undo":bool,"can_redo":bool,"history_count":int}` |
| `editor.redo` | `{"count":int=1}` | `{"redone":int,"action":str?,"can_undo":bool,"can_redo":bool,"history_count":int}` |
| `editor.history` | `{"limit":int=20}` | `{"count":int,"current":int,"actions":[{"index":int,"name":str,"current":bool}]}` |

Undo and redo act on the **currently edited scene's** history:
`EditorInterface.get_editor_undo_redo().get_history_undo_redo(manager.get_object_history_id(root))`.
`EditorUndoRedoManager` itself exposes no `undo()`/`redo()`; only the per-object `UndoRedo`
returned by `get_history_undo_redo()` does. `count`: missing or `null` → 1, any number → truncated and clamped to 1..100, any other JSON
type → `BAD_ARGS`. `history.actions` is ordered by **ascending** `index` (oldest first) and
holds at most `limit` of the most recent actions. `dry_run` returns `{"would_undo":[names...]}` or `{"would_redo":[names...]}` (only those
keys, not the normal `data` of §4) and mutates nothing. `opts.undo` is
ignored here — an undo is not itself undoable. No edited scene → `NO_SCENE`.

### scene

| cmd | args | data |
| --- | --- | --- |
| `scene.open` | `{"path"}` | `{"path"}` — must poll `get_edited_scene_root()` for up to 120 frames; `open_scene_from_path()` returns `void` |
| `scene.save` | — | `{"path"}` |
| `scene.save_as` | `{"path"}` | `{"path"}` — 4.7 always makes the new scene current |
| `scene.reload` | `{"path"?}` | `{}` |
| `scene.roots` | — | `{"scenes":[{"path","unsaved":bool}]}` |
| `scene.tree` | `{"path"?,"depth":int=0,"props":bool=false}` | `{"scene","nodes":[node]}` |

`scene.tree.path`: empty or `"."` means the edited scene; `res://x.tscn` means another open
scene; anything else is a node path (optionally `res://x.tscn::Node`). `nodes` is always a
flat pre-order list and the subtree root's own `path` is `"."`.

`node`:

```json
{"path": "Inst", "name": "Inst", "type": "Node2D", "script": "res://x.gd",
 "instance": "res://sub.tscn", "owner": ".", "children": 2,
 "props": {"position": "Vector2(10, 20)"}}
```

`depth: 0` means unlimited. `props` includes every non-default property as text.

### node

| cmd | args | data |
| --- | --- | --- |
| `node.add` | `{"type"?,"script"?,"parent"?,"name"?,"index"?}` | `{"path","type"}` |
| `node.rm` | `{"path"}` | `{}` |
| `node.mv` | `{"path","to","index"?}` | `{"path"}` |
| `node.dup` | `{"path","name"?}` | `{"path"}` |
| `node.rename` | `{"path","name"}` | `{"path"}` |

Rules: exactly one of `type`/`script`; a script target is instantiated with
`load(path).new()` so C# and GDScript classes both work; the new node gets
`owner = edited root` and an undo action that removes it.

### prop

| cmd | args | data |
| --- | --- | --- |
| `prop.list` | `{"target","filter"?,"changed":bool=false}` | `{"target","props":[prop]}` |
| `prop.get` | `{"target","name"}` | `{"name","type","value","value_text","is_default"}` |
| `prop.set` | `{"target","name","value","as"?}` | `{"name","type","value_text"}` |
| `prop.reset` | `{"target","name"}` | `{}` |

`prop` = `{"name","type","value_text","is_default"}`. `prop.set` validates that the
property exists and that the parsed value converts to its type before mutating.

## 8. CLI-side conventions

* Exit codes: `0` ok, `1` usage, `2` not connected (no endpoint / connection refused),
  `3` command failed, `4` protocol or version mismatch.
* `--json` prints the raw `data` as JSON; `--quiet` prints only the primary scalar
  (`path`, `value_text`, ...); default output is human tables.
* `batch` reads NDJSON requests from stdin (same shape as §4) and writes NDJSON responses
  in order, on a single connection.
* On a `4` exit the CLI suggests `gdcli plugin upgrade`.

## 9. Scenes, project data and scripts

Same envelope and rules as §4. `opts.undo` applies only where noted; resource, project,
filesystem and script commands are not undoable and ignore it.

### signal

| cmd | args | data |
| --- | --- | --- |
| `signal.list` | `{"target","connected_only":bool=false}` | `{"target","signals":[{"name","args":int,"connections":[{"to","method","flags":int}]}]}` |
| `signal.connect` | `{"source","signal","to","method","flags":int=2,"allow_missing":bool=false}` | `{"source","signal","to","method"}` |
| `signal.disconnect` | `{"source","signal","to","method"}` | `{"source","signal","to","method"}` |

`flags` defaults to `CONNECT_PERSIST` (2) so the connection is serialized into the scene.
`signal` must exist on `source`; `to`/`method` must resolve unless `allow_missing` is set.
Both commands are one undo action (`connect`/`disconnect`).

### group

| cmd | args | data |
| --- | --- | --- |
| `group.list` | `{"target","builtin":bool=false}` | `{"target","groups":[str]}` |
| `group.add` | `{"target","group"}` | `{"target","groups":[str]}` |
| `group.remove` | `{"target","group"}` | `{"target","groups":[str]}` |

Groups are added persistent (`add_to_group(name, true)`) so they reach the `.tscn`.
`builtin` includes engine-internal groups (names starting with `_`). Undoable.

### node (additional)

| cmd | args | data |
| --- | --- | --- |
| `node.instance` | `{"scene","parent"?,"name"?,"index"?}` | `{"path","scene"}` |

Instantiates with `GEN_EDIT_STATE_INSTANCE`, sets `owner` to the edited root and is one undo
action. The saved node must carry `instance=ExtResource(...)` — that is the acceptance test.

### res

| cmd | args | data |
| --- | --- | --- |
| `res.new` | `{"type","path"}` | `{"path","type"}` |
| `res.info` | `{"path"}` | `{"path","type","resource_name"}` |
| `res.duplicate` | `{"from","to"}` | `{"path"}` |

Property access on a `res://` file goes through `prop.*` (§5, §7). Not undoable.

### project

| cmd | args | data |
| --- | --- | --- |
| `project.setting.get` | `{"key"}` | `{"key","value_text","type","exists":bool}` |
| `project.setting.set` | `{"key","value","as"?}` | `{"key","value_text"}` |
| `project.autoload.list` | — | `{"autoloads":[{"name","path","enabled":bool}]}` |
| `project.autoload.add` | `{"name","path"}` | `{"name","path"}` |
| `project.autoload.remove` | `{"name"}` | `{}` |

`setting.set` writes through `ProjectSettings.set_setting` + `ProjectSettings.save()`, which
rewrites `project.godot` (formatting may change; this is the engine's writer, not ours).
Autoloads use `EditorPlugin.add_autoload_singleton` / `remove_autoload_singleton`. Not undoable.

`autoload.add` rewrites the stored value from 4.7's `*uid://...` to `*res://...` before saving:
the editor only publishes a new uid to `.godot/uid_cache.bin` later, so a game launched right
after the change cannot resolve the uid and silently skips the autoload.

### fs

| cmd | args | data |
| --- | --- | --- |
| `fs.status` | — | `{"scanning":bool,"progress":float,"importing":bool}` |
| `fs.scan` | `{"sources":bool=false}` | `{"started":true}` |
| `fs.reimport` | `{"paths":[str]}` | `{"queued":int}` |

Scanning is asynchronous and never blocks the editor main thread. `gdcli --wait` polls
`fs.status` every 200 ms up to 60 s and fails with `GODOT_ERROR` on timeout.

### script

| cmd | args | data |
| --- | --- | --- |
| `script.check` | `{"paths":[str]}` | `{"results":[{"path","ok":bool,"error":str?}]}` |
| `script.open` | `{"path","line":int=0}` | `{}` |
| `script.files` | — | `{"open":[str],"unsaved":[str]}` |
| `script.save_all` | — | `{"saved":int}` |

`check` is load-based (`ResourceLoader.load` with `CACHE_MODE_IGNORE`): it reports whether a
script parses, not where. Print the editor's error panel / use `godot --check-only` for
column-level detail.

## 10. Editor UI, screenshots and play control

### editor (additional)

| cmd | args | data |
| --- | --- | --- |
| `editor.select` | `{"paths":[str],"add":bool=false}` | `{"selection":[str]}` |
| `editor.inspect` | `{"target"}` | `{"inspected":str}` |
| `editor.main_screen` | `{"name":"2d"\|"3d"\|"script"\|"assetlib"}` | `{"main_screen":str}` |
| `editor.toast` | `{"message"}` | `{}` |
| `editor.screenshot` | `{"viewport":"2d"\|"3d"\|"whole","path"}` | `{"path","width","height"}` |
| `editor.play` | `{"mode":"main"\|"current"\|"scene","scene"?}` | `{"playing":bool,"scene":str?}` |
| `editor.stop` | — | `{"playing":false}` |

`editor.status` gains `main_screen`, `selection` (`[str]`) and `inspected` (`str?`).

Main-screen names: `2d`, `3d`, `script`, `assetlib` (mapped to the editor's `Asset Store` on
4.7), and `game` may come back from `status` when the user sits on the game view even though
it is not a valid input name. The readback walks the main-screen container for the visible
child, because it is wrapped in `WindowWrapper` on 4.7.

Screenshot rules, all verified on 4.7.2:

* `viewport: "whole"` captures the whole editor window:
  `EditorInterface.get_base_control().get_viewport().get_texture().get_image()`.
* `viewport: "2d"|"3d"` must first call `EditorInterface.set_main_screen_editor(...)` and then
  wait **two rendered frames** before reading `get_editor_viewport_2d/3d().get_texture()`.
  Reading immediately after the switch yields a 2×2 placeholder.
* The plugin writes the PNG itself (`Image.save_png`) and returns its dimensions; image bytes
  are never sent over the protocol. `path` may be absolute or project-relative.
* `dry_run` validates the request and returns `planned` without `width`/`height`, since
  nothing was rendered.
* Under a dummy renderer (`--headless`) there is no texture: return `NO_API` with a hint
  pointing at a real display or xvfb. Never return an empty image.

`editor.play` returns as soon as the editor reports playing; `gdcli --wait` polls
`editor.status` every 200 ms up to 30 s. `editor.stop` is idempotent.

The `game.*` commands live with what they need: the debugger bridge in §11 (ping, tree, get,
set, eval), screenshots in §12, and logs/`status`/`clear` in §14. Nothing about the running
game is defined in this section.

## 11. Running game bridge

The bridge is opt-in: it needs the `GdcliRuntime` autoload inside the game, installed with
`gdcli runtime install` (which writes `res://addons/gdcli/runtime/gdcli_runtime.gd` and adds
the autoload through `EditorPlugin.add_autoload_singleton`). Without it every `game.*` request
below answers `NO_GAME`.

### game (additional)

| cmd | args | data |
| --- | --- | --- |
| `game.ping` | — | `{"runtime":str,"scene":str,"fps":float}` |
| `game.tree` | `{"depth":int=0,"props":bool=false}` | `{"scene","nodes":[node]}` |
| `game.get` | `{"path","name"}` | `{"name","type","value_text"}` |
| `game.set` | `{"path","name","value","as"?}` | `{"name","type","value_text"}` |
| `game.eval` | `{"expr","path"?}` | `{"type","value_text"}` |

`nodes` uses the same shape as `scene.tree` (§7). `depth: 0` is unlimited.

### Transport

The editor plugin owns correlation ids and forwards over the live debugger session:

```
editor → game   session.send_message("gdcli:req", [id, cmd, args])
game → editor   EngineDebugger.send_message("gdcli:res", [id, ok, payload])
```

The runtime autoload registers `EngineDebugger.register_message_capture("gdcli", cb)` in
`_ready` and answers on the game's main thread. A request with no reply within **3 s** fails
with `NO_GAME` ("no reply from the running game"). Requests are serialized; the plugin keeps
the pending reply in its deferred mechanism (the same one used by `scene.open`), so the
editor main thread never blocks.

`game.set` reuses the §6 value modes inside the game (`gd`, `json`, `ref`); `expr` is
editor-side only and meaningless here. `game.eval` parses with `Expression`, executes with the
node at `path` as base instance (or no base), and returns `var_to_str(result)`. It runs
arbitrary code inside the game and is documented as such — it is never implicit.

The runtime must be inert when no debugger is attached (`EngineDebugger.is_active()` false)
and must never print to stdout on its own.

## 12. Plugin toggles and game screenshots

### project (additional)

| cmd | args | data |
| --- | --- | --- |
| `project.plugins.list` | — | `{"plugins":[{"name","path","enabled":bool,"version":str?}]}` |
| `project.plugins.enable` | `{"name"}` | `{"name","enabled":true}` |
| `project.plugins.disable` | `{"name"}` | `{"name","enabled":false}` |

`list` merges two sources: every `res://addons/*/plugin.cfg` found on disk (parsed with
`ConfigFile`, so `name` and `version` come from the file) and the editor's enabled state via
`EditorInterface.is_plugin_enabled(name)`. `enable`/`disable` call
`EditorInterface.set_plugin_enabled(name, bool)` and re-read the state before replying;
`name` is the plugin's `name` field, not its directory.

`list` is sorted by `name`; `version` is `null` when the config omits it, and a malformed
`plugin.cfg` (no `name`) is skipped rather than reported. If `set_plugin_enabled` leaves the
state unchanged the command answers `GODOT_ERROR` with a `gdcli fs scan --wait` hint — the
plugin is visible in `list` but not yet in the editor's cache, so `NOT_FOUND` would lie.
`enable`/`disable` honour `dry_run` and return `planned`.

Disabling `gdcli` itself tears down the bridge mid-request, so the reply may never arrive —
that is expected, not a bug. Toggling requires the plugin to be in the editor's filesystem
cache; run `fs scan --wait` first if it was just written.

### game (additional)

| cmd | args | data |
| --- | --- | --- |
| `game.screenshot` | `{"path"}` | `{"path","width","height"}` |

The **runtime** captures `get_viewport().get_texture().get_image()` on the game's main
thread, waits two rendered frames first, and writes the PNG itself (`Image.save_png`), the
same contract as §10 editor screenshots: no image bytes on the wire, `path` may be absolute
or project-relative, parent directories are created. With a dummy renderer (a game started
headless) there is no texture: `NO_API` with a display hint, never an empty file.

CLI surface for all of the above plus the private install mode:

```
gdcli project plugins list
gdcli project plugins enable <name>
gdcli project plugins disable <name>
gdcli game screenshot --out <path>
gdcli plugin install [--check] [--private]
```

`--private` additionally appends `addons/gdcli/` to the project's `.gitignore` (created if
absent, idempotent) so the installed files never reach a shared repository. The
`[editor_plugins]` line in `project.godot` is still written and is still tracked — a teammate
without the addon will see a missing-plugin warning, so either everyone runs
`gdcli plugin install` or the addon is committed instead.

## 13. Input map

The input map is project settings, so the plugin only converts a small event DSL to real
`InputEvent` objects and lets the engine serialize them (`ProjectSettings.set_setting(
"input/<action>", {"deadzone": float, "events": Array})` + `save()`). Verified output on
4.7.2 is the canonical block real projects contain.

### input

| cmd | args | data |
| --- | --- | --- |
| `input.list` | `{"action"?}` | `{"actions":[{"name","deadzone":float,"events":[event]}]}` |
| `input.action.add` | `{"name","deadzone":float=0.5}` | `{"name","deadzone"}` |
| `input.action.remove` | `{"name"}` | `{}` |
| `input.action.rename` | `{"from","to"}` | `{"name"}` |
| `input.event.add` | `{"action","event":spec,"index"?}` | `{"action","index","event":event}` |
| `input.event.remove` | `{"action","index"}` | `{"action","events":[event]}` |

`actions` is sorted by name. Every event in the output carries its `index` in the stored
array, which is the address `input.event.remove` expects.

### Event spec

```json
{"type": "key",        "key": "Space", "physical_key": null, "modifiers": ["shift"], "echo": false}
{"type": "mouse",      "button": "left", "modifiers": []}
{"type": "joy_button", "button": 0, "device": -1}
{"type": "joy_axis",   "axis": 1, "value": -1.0, "device": -1}
{"raw": "Object(InputEventScreenTouch,...)"}
```

* Exactly one of `key` / `physical_key` for `type: "key"`. `physical_key` sets
  `physical_keycode` and leaves `keycode` at 0 (Godot's convention for layout-independent
  bindings). A name that `OS.find_keycode_from_string` resolves to 0 is `BAD_ARGS`.
* `modifiers` accepts `shift`, `ctrl`, `alt`, `meta` (case-insensitive).
* `device` defaults to **-1 and is always written explicitly**: letting the engine default it
  produces `"device": 16 / 32 / 3` depending on the event class, which looks like a
  device-restricted binding and does not match hand-written projects.
* `{"raw": ...}` is `str_to_var` and reconstructs any event class; the output falls back to
  the same form for event types outside the DSL, so `input.list` can always round-trip.

### Rules

* Actions are enumerated from the **on-disk `[input]` section**, not from
  `ProjectSettings.get_property_list()`: the latter also reports every built-in `input/ui_*`
  action, so an empty project would look non-empty and built-ins could not be overridden.
* `input.list` with an `action` that does not exist is `{"actions":[]}`, not `NOT_FOUND` — it
  is a filter. `action.remove`/`rename` on a missing source is `NOT_FOUND`.
* `deadzone` is only required to be a number; it is not range-checked.
* Joypad events carrying `modifiers` are `BAD_ARGS` rather than silently dropping them.
* A key event whose on-disk `keycode` and `physical_keycode` are both non-zero cannot be
  expressed in the DSL, so it round-trips as `{"raw": ...}`.
* `input.event.add` accepts `index` 0..len (len means append); `event.remove` needs 0..len-1.
* Note: `InputEventScreenTouch.is_match(other, true)` is false even for an
  identical event on 4.7.2, so raw touch events are not duplicate-checked.
* Action names must be non-empty and must not start with `input/`. Adding an existing action
  or renaming onto an existing one is `BAD_ARGS`.
* `input.event.add` into a missing action is `NOT_FOUND` (hint: `add-action`). A duplicate
  binding is `BAD_ARGS` and reports the existing index; comparison uses
  `InputEvent.is_match(other, true)`. `index` defaults to append.
* `input.event.remove` with an out-of-range index is `BAD_ARGS`.
* Mutations are **not undoable** (`opts.undo` is ignored); each one calls
  `ProjectSettings.save()`, so `project.godot` is rewritten by the engine. `dry_run` returns
  `planned` and changes nothing.
* A missing `[input]` section, or an entry without `deadzone`/`events`, reads as
  `deadzone 0.5` / `[]` and never crashes.
* The editor's running game is not affected; the map applies to the next play.

CLI surface:

```
gdcli project input actions
gdcli project input list [--action NAME]
gdcli project input add-action <name> [--deadzone F]
gdcli project input remove-action <name>
gdcli project input rename-action <old> <new>
gdcli project input add-event <action> (--key K | --physical-key K | --mouse B |
        --joy-button N | --joy-axis N --axis-value F | --json SPEC | --raw TEXT)
        [--modifiers shift,ctrl] [--device N]
gdcli project input remove-event <action> --index N
```

## 14. Game log capture

`game.logs` finally has content: 4.7's debugger only carries `game_view:*`, so the **runtime**
captures the game's own log stream and forwards it.

### How the capture works

Measured on 4.7.2: `Logger` exists and `OS.add_logger` / `OS.remove_logger` accept a GDScript
subclass. `_log_message(message, error)` receives `print` and `printerr` (`error == true`);
`_log_error(function, file, line, code, rationale, editor_notify, error_type, backtraces)`
receives `push_warning` (`error_type == 1`) and `push_error` (`error_type == 0`).

`GdcliRuntime` therefore installs a logger when `EngineDebugger.is_active()` and removes it in
`_exit_tree`. Entries are buffered and flushed **at most once per frame** as a single
`EngineDebugger.send_message("gdcli:log", [[{kind,text}, ...]])`, because sending from inside
the logging callback would re-enter the engine's logger. Pending is capped at 500 entries per
frame; the overflow is reported as one `{"kind":"warning","text":"… N messages dropped"}`.

Mapping: `_log_message` → `output` (or `error` when the `error` flag is set, i.e. `printerr`);
`_log_error` → `warning` when `error_type == 1`, otherwise `error` (`2` is a GDScript runtime
error). Trailing newlines are trimmed.

Text shaping matters on 4.7.2: `rationale` is **always empty** and the message arrives in
`code`, so `code` is used and `rationale` is the fallback. `file`/`line` point at
`core/variant/variant_utility.cpp`, not the script, so the location is only appended when
`file` is a `res://`/`user://` path; otherwise the first `script_backtraces` frame is used and
C++ paths never reach the log.

Overflow keeps the newest entries: the batch including the marker is capped at 500, the
oldest are dropped, and the marker is placed first so the editor's own 500-entry ring buffer
cannot evict it. The runtime runs with `PROCESS_MODE_ALWAYS` so a paused game still flushes.

The editor's `debug_capture.gd` appends those entries to the same 500-entry ring buffer that
`game.logs` reads, so `game.logs` needs no code change beyond the extra `kind`.

### game (additional)

| cmd | args | data |
| --- | --- | --- |
| `game.logs` | `{"limit":int=200,"clear":bool=false,"kind"?:"output"\|"error"\|"warning"}` | `{"lines":[{"kind","text","session"}]}` |
| `game.status` | — | `{"sessions":int,"active":bool,"capturing":bool}` |
| `game.clear` | — | `{}` |

`capturing` is true when the runtime has a logger installed. `game.status` asks the runtime
via `game.ping` when a session is active and falls back to `capturing: false` after ~1 s when
no runtime answers, so it never hangs or fails.

Known interaction: an *uncaught* GDScript error pauses the game at the editor's breakpoint, so
the frame flush stops and buffered lines only arrive after the game resumes; `editor.stop` on a
paused game may drop the last batch. `push_error`/`push_warning` do not pause. Without the runtime autoload
(`gdcli runtime install`) `game.logs` stays empty — that is the only supported way to read a
local game's output on 4.7, because the debugger does not carry it.

CLI:

```
gdcli game logs [--limit N] [--clear] [--kind output|error|warning]
```

## 15. Command palette

The editor's command palette (`EditorCommandPalette`) can only be written to:
`add_command(name, key_name, callable, shortcut_text)` and `remove_command(key_name)` — there is
no way to list or invoke other people's entries. So gdcli registers a few of its own and exposes
exactly those.

### editor (additional)

| cmd | args | data |
| --- | --- | --- |
| `editor.palette.list` | — | `{"entries":[str]}` |
| `editor.palette.run` | `{"name"}` | `{"name"}` |

Entries are registered in `_enter_tree` and removed in `_exit_tree`; both operate on a key list
the plugin stores as palette metadata, because `remove_command` on a key that was never added
logs an engine error and the palette cannot be enumerated. Everything is prefixed `gdcli: ` so
the entries group together in the palette search:

| entry | effect |
| --- | --- |
| `gdcli: Screenshot 2D view` | capture the 2D viewport, write `.godot/gdcli/screenshots/shot2d-<ms>.png`, toast the path |
| `gdcli: Screenshot whole editor` | same for the whole window, `.godot/gdcli/screenshots/shotwhole-<ms>.png` |
| `gdcli: Show bridge status` | toast `port · plugin version · edited scene · playing/stopped` |

`palette.run` invokes the same `Callable` a human click would, and returns once the action is
**scheduled** — the screenshot actions finish two frames later, so a client checks the file
after a short wait. Unknown name → `NOT_FOUND` with a `palette list` hint. `.godot/` is already
ignored by Godot's own `.gitignore`, so screenshots never reach the repository.

CLI:

```
gdcli editor palette list
gdcli editor palette run <name>
```
