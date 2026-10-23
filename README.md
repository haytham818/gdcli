<p align="center">
  <img src="https://raw.githubusercontent.com/haytham818/gdcli/main/docs/assets/banner.png" alt="gdcli — control a running Godot editor from the command line">
</p>

# gdcli

Control a running Godot editor from the command line, just as you would by hand.

**Documentation: <https://haytham818.github.io/gdcli/>**
[![skills.sh](https://skills.sh/b/haytham818/gdcli)](https://skills.sh/haytham818/gdcli/gdcli)

## Install

```sh
# 1. from crates.io
cargo install gdcli-cli

# ...or straight from the repository
cargo install --git https://github.com/haytham818/gdcli

# 2. prebuilt binary (linux/macos)
curl -fsSL https://github.com/haytham818/gdcli/releases/latest/download/install.sh | sh

# 3. prebuilt binary (windows)
irm https://github.com/haytham818/gdcli/releases/latest/download/install.ps1 | iex
```

The installers accept `GDCLI_VERSION` (pin a release), `GDCLI_INSTALL_DIR` (default
`~/.local/bin` on unix, `%LOCALAPPDATA%\gdcli\bin` on Windows) and verify the download
against the release's `SHA256SUMS`. `install.sh` also respects `GDCLI_BASE_URL` for mirrors.

Then wire it into a project:

```sh
gdcli plugin install --project /path/to/game   # writes addons/gdcli and enables it
# restart the Godot editor once
gdcli editor status
```

`--private` additionally gitignores `addons/gdcli/` so the bridge never reaches a shared
repository.

`--check` reports what would change without writing anything.


## Use it from an agent

Paste this into Claude Code, Codex, OpenCode or any agent with a shell:

> Set up gdcli for me. Run `cargo install gdcli-cli`, then `gdcli plugin install --project <path to my Godot game>` (ask me for the path), then `npx skills add haytham818/gdcli@gdcli -g -y -a '*'` so you also get the gdcli skill. Finish by running `gdcli editor status`; if the editor is not running, tell me to start it and rerun.

The skill is what teaches an agent to reach for `gdcli` instead of editing `.tscn` files: it
carries the command recipes, the exit-code table and the failure modes that matter. It lives in
[`skills/gdcli`](skills/gdcli) and is published through
[skills.sh](https://skills.sh/haytham818/gdcli/gdcli).

`gdcli plugin install` offers to install it for you in a terminal; `--with-skill` and
`--no-skill` decide up front, and both are no-ops in scripts.

## Usage

```sh
gdcli editor status
gdcli scene tree --depth 2
gdcli node add Sprite2D --parent Main --name Hero
gdcli prop set Hero position 'Vector2(64, 96)'
gdcli prop set Hero texture 'res://art/hero.png' --as ref
gdcli scene save
```

Every mutation is one undoable step named `gdcli: <cmd>`

`--dry-run` returns the plan without touching anything.

`gdcli batch` takes NDJSON on stdin when an agent needs several operations in one connection.

## Requirements

Requirements: Godot 4.4+ (developed against 4.7.2)

## License

MIT
