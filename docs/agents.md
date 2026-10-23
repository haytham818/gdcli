# For agents

`gdcli` is built for a model with a shell. Commands return structured data, mutations are
undoable, and nothing needs to be clicked.

## The loop that works

```sh
gdcli editor status                 # 1. what is open, is anything unsaved
gdcli scene tree --props --json     # 2. read before you write
gdcli node add Sprite2D --name Hero --dry-run --json   # 3. check the plan
gdcli node add Sprite2D --name Hero                    # 4. apply
gdcli scene tree --json             # 5. verify
gdcli editor screenshot --out /tmp/after.png           # 6. look at it when it matters
```

If step 5 disagrees with what you wanted, `gdcli editor undo` walks it back — one undo step
per command, named `gdcli: <cmd>`.

## Rules of thumb

- **Prefer `--json`.** Human output is for people; parse the envelope instead. Errors go to
  stderr with a stable code and a `hint`.
- **Read the tree first.** `scene tree --json` gives exact paths; guessing paths wastes turns.
- **Node paths are relative to the edited scene root**, and the root is `"."`. `Inst/Label`,
  never `Main/Inst/Label` (that form is accepted too, but do not generate it).
- **Batch what belongs together.** `gdcli batch` takes NDJSON on stdin and reuses one
  connection; it is the difference between one round trip and ten.
- **Use `--dry-run` before anything destructive** (`node rm`, `node mv`, `prop reset`).
- **Do not edit `.tscn` or `project.godot` by hand.** If a command does not exist, say so
  instead of writing files behind the editor's back.
- **Do not disable the `gdcli` plugin** to "clean up" — `project plugins disable gdcli` tears
  down the connection mid-request.

## Exit codes

| Code | Meaning | What to do |
| --- | --- | --- |
| `0` | success | — |
| `1` | usage error | fix the arguments; do not retry unchanged |
| `2` | not connected | start the editor, or run `gdcli plugin install` |
| `3` | the command failed | read `error.code` and `error.hint`; fix the cause |
| `4` | protocol/version mismatch | `gdcli plugin upgrade`, then restart the editor |

## Discovering what is supported

```sh
gdcli raw meta.capabilities --quiet
```

The plugin lists every command it implements. The CLI refuses commands a plugin version does
not advertise, so an older plugin degrades cleanly instead of failing mid-scene.

## Common traps

!!! warning "`--out` paths are resolved by the editor"

    Pass a relative path (it lands in the project) or an absolute one. The editor writes the
    file, so a sandbox that only sees the CLI's filesystem will not see it.

!!! warning "Saving rewrites the scene header"

    The engine adds `unique_id=` attributes and reorders uids when it saves. That is normal;
    review the semantic diff, not the bytes.

!!! warning "Game commands need the runtime"

    `game.*` answers `NO_GAME` until `gdcli runtime install` has been run **and** the game is
    playing. The runtime is a project file, not part of the CLI.

!!! warning "Screenshots need a renderer"

    `editor screenshot` and `game screenshot` return `NO_API` under `--headless`. Use a normal
    editor session or xvfb.
