# When something fails

Errors arrive on stderr as `error: CODE: message` plus a `hint:` line, and the process exits
with a code from the table in `SKILL.md`. Read the code before retrying.

## `exit 2` — no endpoint

```
error: no gdcli endpoint for /path/to/game: start the Godot editor with the plugin enabled
```

The CLI found `project.godot` but no running editor that hosts the plugin.

1. `gdcli plugin install --project /path/to/game` (idempotent).
2. Restart the editor — a plugin only loads at startup.
3. `gdcli editor status` again.

A stale endpoint from a killed editor shows up as `Connection refused`; starting the editor
again overwrites it.

## `exit 4` — version mismatch

The CLI and the installed plugin disagree. Run `gdcli plugin upgrade`, then restart the
editor. `gdcli plugin status` shows both versions and whether the live plugin answers.

If a command is missing rather than mismatched, ask the plugin what it has:

```sh
gdcli raw meta.capabilities --quiet
```

## `NO_SCENE`

Nothing is open in the editor. `gdcli scene open res://main.tscn` (paths from
`gdcli scene roots` or the filesystem).

## `NOT_FOUND`

A node, property, signal or resource does not exist. Get the exact path from
`gdcli scene tree --json` and the exact property name from `gdcli prop list <target>`; do not
guess.

## `NO_API`

The engine cannot do this. Common causes:

- a screenshot under `--headless` — use a real editor or `xvfb-run`;
- editing inside an instanced scene (`editable children` has no scripting API);
- a plugin.cfg that is on disk but not yet in the editor's filesystem cache — `gdcli fs scan --wait`.

## `NO_GAME`

`game.*` needs three things: the runtime autoload, a running game, and the plugin's session.

```sh
gdcli runtime install
gdcli editor play --wait
gdcli game ping          # answers within a second when it works
```

"No running game" means no session at all; "no reply from the running game" means the session
exists but the autoload is missing (usually because the project was installed after the game
was launched, or the export does not ship `plugin.cfg`).

## `GODOT_ERROR`

The engine refused the call. `project.setting.set` and input-map edits rewrite
`project.godot`; if the message mentions a property or a file, read it literally — the plugin
only reports what the engine said.

## `BAD_ARGS`

Usually a value that the parser could not read. With `--as gd` a bare string is not a literal:
`patched` fails, `'"patched"'` works. Prefer the narrowest mode that fits (`gd` for math
types, `ref` for resource paths, `json` for structures).

## The editor hangs or a command never returns

The plugin runs everything on the editor's main thread. A huge `fs scan` or a very large scene
tree can take a while; `--wait` polls with a timeout. If the editor itself is stuck in a modal
dialog (an import error, a save confirmation), no command will answer — ask the user to look at
the editor window.
