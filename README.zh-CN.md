# gdcli

[English](README.md) | 中文

像手动操作一样，从命令行控制正在运行的 Godot 编辑器。

## 安装

```sh
# 1. 从 crates.io 安装
cargo install gdcli-cli

# ……或直接从仓库安装
cargo install --git https://github.com/haytham818/gdcli

# 2. 预编译二进制（linux/macos）
curl -fsSL https://github.com/haytham818/gdcli/releases/latest/download/install.sh | sh

# 3. 预编译二进制（windows）
irm https://github.com/haytham818/gdcli/releases/latest/download/install.ps1 | iex
```

安装脚本支持 `GDCLI_VERSION`（固定某个版本）、`GDCLI_INSTALL_DIR`（unix 默认
`~/.local/bin`，Windows 默认 `%LOCALAPPDATA%\gdcli\bin`），并用发布页的 `SHA256SUMS`
校验下载内容。`install.sh` 还支持 `GDCLI_BASE_URL`，用于指定镜像。

然后把它接入到项目里：

```sh
gdcli plugin install --project /path/to/game   # 写入 addons/gdcli 并在 project.godot 中启用
# 重启一次 Godot 编辑器
gdcli editor status
```

`--private` 会把 `addons/gdcli/` 一并写进 `.gitignore`，这样接入的插件不会进入共享仓库中。

`--check` 只报告将要发生的改动，不写任何文件。

## 用法

```sh
gdcli editor status
gdcli scene tree --depth 2
gdcli node add Sprite2D --parent Main --name Hero
gdcli prop set Hero position 'Vector2(64, 96)'
gdcli prop set Hero texture 'res://art/hero.png' --as ref
gdcli scene save
```

每一次修改都是一条名为 `gdcli: <cmd>` 的可撤销操作。

`--dry-run` 只返回执行计划，不修改任何文件。

当一个 agent 需要在一条连接里连续做多件事时，`gdcli batch` 从 stdin 读取 NDJSON。

## 环境要求

Godot 4.4+（开发时使用 4.7.2）。

## 许可

MIT
