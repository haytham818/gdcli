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
  "plugin_version": "0.2.0",
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
  "plugin_version": "0.2.0",
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

## 7. Commands (M1)

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
holds at most `limit` of the most recent actions. `dry_run` returns
``{"would_undo":[names...]}` / `{"would_redo":[names...]}` (only those keys, not the normal
`data` of §4) and mutates nothing. `opts.undo` is
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
