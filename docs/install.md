# Install

`gdcli` is one Rust binary. The editor side is a GDScript plugin that the binary installs into
your project — there is nothing to compile and nothing to download separately.

## The CLI

=== "crates.io"

    ```sh
    cargo install gdcli-cli
    ```

=== "Prebuilt (Linux, macOS)"

    ```sh
    curl -fsSL https://github.com/haytham818/gdcli/releases/latest/download/install.sh | sh
    ```

=== "Prebuilt (Windows)"

    ```powershell
    irm https://github.com/haytham818/gdcli/releases/latest/download/install.ps1 | iex
    ```

=== "From the repository"

    ```sh
    cargo install --git https://github.com/haytham818/gdcli
    ```

The installers verify the download against the release's `SHA256SUMS` and accept:

| Variable | Meaning |
| --- | --- |
| `GDCLI_VERSION` | pin a release, e.g. `0.10.0` or `v0.10.0` |
| `GDCLI_INSTALL_DIR` | where the binary goes; default `~/.local/bin` on unix, `%LOCALAPPDATA%\gdcli\bin` on Windows |
| `GDCLI_BASE_URL` | mirror or self-hosted release directory (`install.sh` only) |

Releases ship `x86_64` builds for Linux (glibc and static musl), macOS (Intel and Apple
silicon) and Windows.

## The editor plugin

```sh
gdcli plugin install --project /path/to/game
```

This writes `addons/gdcli/` and adds one `[editor_plugins]` line to `project.godot`. Then
**restart the editor once** — a plugin is only loaded at startup.

```console
$ gdcli editor status
project      : /home/you/game/
godot        : 4.7.2-stable (official)
edited_scene : res://main.tscn
open_scenes  : res://main.tscn
playing      : false
```

!!! note "Keeping the bridge out of the repository"

    `gdcli plugin install --private` also adds `addons/gdcli/` to `.gitignore`. The
    `[editor_plugins]` line in `project.godot` is still written and still tracked, so a
    teammate without the addon sees a missing-plugin warning — either everyone runs
    `gdcli plugin install`, or the addon is committed.

`gdcli plugin status` reports whether the files, the endpoint and the live plugin agree.
`gdcli plugin upgrade` rewrites the installed files after you upgrade the CLI; a running
editor keeps the old plugin until you restart it.

## The agent skill

`gdcli` ships a companion skill for coding agents at [`skills/gdcli`](https://github.com/haytham818/gdcli/tree/main/skills/gdcli).
`gdcli plugin install` offers to install it when it runs in a terminal; in scripts use

```sh
npx skills add haytham818/gdcli@gdcli -g -y -a claude-code -a codex -a opencode -a cursor
```

or pass `--with-skill` / `--no-skill` to `gdcli plugin install`. The `-a` list is
what the CLI installs for by default; add `-a <agent>` for anything else (Gemini CLI, Windsurf, ...). The skill is listed on
[skills.sh](https://skills.sh/haytham818/gdcli/gdcli) and lives in the repository, so it
travels with the CLI.

## Requirements

- Godot **4.4+** (developed against 4.7.2), any edition; the plugin is plain GDScript.
- Linux, macOS or Windows.
- Python 3 only if you want to run the end-to-end suite.

## Troubleshooting

!!! failure "`no endpoint for <project>`"

    The editor is not running with the plugin enabled, or it was started before
    `plugin install`. Start (or restart) the editor. A stale endpoint from a killed editor is
    harmless: the CLI reports `Connection refused` and exits `2`.

!!! failure "`NO_API: the game has no rendering surface to capture`"

    Screenshots need a real renderer. `--headless` has none — run a normal editor, or under
    xvfb:

    ```sh
    xvfb-run -a -s "-screen 0 1600x1000x24" godot --editor --path /path/to/game
    ```

!!! failure "`NO_GAME`"

    `game.*` commands need the opt-in runtime autoload inside the game:

    ```sh
    gdcli runtime install --project /path/to/game
    gdcli editor play --wait
    gdcli game ping
    ```
