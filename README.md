<p align="center">
  <img src="https://raw.githubusercontent.com/haytham818/gdcli/main/docs/assets/banner.png" alt="gdcli — control a running Godot editor from the command line">
</p>

# gdcli

Control a running Godot editor from the command line, just as you would by hand.

**Documentation: <https://haytham818.github.io/gdcli/>**

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
