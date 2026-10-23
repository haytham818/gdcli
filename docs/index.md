---
hide:
  - navigation
---

# gdcli

Drive a **running Godot editor** from the command line, just as you would by hand.

```sh
gdcli scene tree --depth 2
gdcli node add Sprite2D --parent Main --name Hero
gdcli prop set Hero position 'Vector2(64, 96)'
gdcli scene save
```

`gdcli` talks to a small editor plugin over loopback, and the plugin performs every operation
through `EditorInterface` and `EditorUndoRedoManager`. Nothing is written by hand, so scene
inheritance, instanced sub-scenes and resource references survive, and every change lands in
your undo history as one `gdcli: <cmd>` step.

## Why not something else

<div class="grid cards" markdown>

-   :material-connection: **An MCP server**

    ---

    Tool schemas (dozens of them) sit in the conversation forever. The transport is not the
    problem; the surface is. A CLI keeps the surface in the shell.

-   :fontawesome-solid-file-code: **Editing `.tscn` by hand**

    ---

    Inheritance and instanced scenes are not representable as text patches without a lossless
    parser, and one bad patch makes the engine refuse the file.

-   :material-cursor-default-click: **Screen automation**

    ---

    Godot's accessibility tree exposes editor chrome only: buttons, tabs and dock shells. The
    scene tree, inspector rows and menus are invisible to it.

-   :material-bug: **Injecting into the editor process**

    ---

    The release binary is fully stripped, so this needs a per-version C++ shim — and it only
    reaches the same `EditorInterface` API a plugin already has.

</div>

[Read the full design](design.md){ .md-button .md-button--primary }
[Wire protocol](protocol.md){ .md-button }

## What it can do

<div class="grid cards" markdown>

-   :material-file-tree: **Scene editing**

    ---

    Nodes, properties, signals, groups, instanced sub-scenes, undo/redo.

-   :material-cog: **Project data**

    ---

    Settings, autoloads, the input map, plugin toggles, filesystem scans, script checks.

-   :material-monitor-screenshot: **Editor UI**

    ---

    Selection, inspector, main screen, toasts, real PNG screenshots, play/stop.

-   :material-gamepad-variant: **The running game**

    ---

    Inspect and change live nodes, evaluate expressions, capture `print` output.

</div>

## Install

```sh
cargo install gdcli-cli
gdcli plugin install --project /path/to/game
# restart the Godot editor once
gdcli editor status
```

Prebuilt binaries and one-line installers are on the [install page](install.md).

## Where to go next

| If you want to… | Read |
| --- | --- |
| set up a project | [Install](install.md) |
| edit a scene from the shell | [Usage](usage.md) |
| let an agent drive Godot | [For agents](agents.md) |
| know why it is built this way | [Design](design.md) |
| implement a client | [Wire protocol](protocol.md) |
