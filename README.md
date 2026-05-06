<div align="center">

# dockpit

A modern project cockpit for running development tasks from a visual terminal UI, built in Zig.

[Key Features](#key-features) - [Usage](#usage) - [Install](#install) - [Customize](#customize) - [FAQ](#faq) - [License](#license)

[![CI](https://github.com/ydah/dockpit/actions/workflows/ci.yml/badge.svg)](https://github.com/ydah/dockpit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/ydah/dockpit)](https://github.com/ydah/dockpit/releases)
[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-f7a41d.svg)](https://ziglang.org/)

</div>

`dockpit` discovers common project tasks, runs them without shell-string execution, and keeps command output, Git status, file changes, worktrees, jobs, and run history in one terminal workspace.

---

## Key Features

### Visual Task Cockpit

Launch `dockpit` in a project and get a focused task list, streaming output pane, Git summary, and compact status bar.

```sh
dockpit
```

Tasks can be selected, searched, rerun, cancelled, inspected, and watched for file changes without leaving the TUI.

### Smart Task Detection

`dockpit` detects common build, test, run, and service commands from project files.

| Ecosystem | Detected tasks |
| --- | --- |
| Zig | `zig build`, `zig build test`, simple `b.step("name", ...)` steps |
| Node | `npm`, `pnpm`, `yarn`, or `bun` package scripts |
| Workspaces | npm/pnpm/yarn workspaces, `pnpm-workspace.yaml`, Cargo workspace members, `go.work` modules |
| Rust | `cargo build`, `cargo test`, `cargo run` |
| Go | `go test ./...`, `go build ./...`, `go run .` |
| Make / just / Taskfile / mise | Simple targets, recipes, tasks, and mise tasks |
| Python / Ruby / Nix | `pytest`, Bundler test commands, Nix flake commands |
| Docker Compose | Stack commands plus service up/restart/logs/build tasks |

### Streaming Runner

Tasks run through argv arrays with `std.process.Child`, never through shell strings. Output streams into the TUI while commands run in background threads.

```sh
dockpit --run zig-build
dockpit --run npm-test --env NODE_ENV=test
```

Configured tasks can set environment variables, choose whether to inherit the parent environment, and apply timeout/output limits.

### Git Changes and Worktrees

Inspect repository state without leaving the app.

| Key | Action |
| --- | --- |
| `g` | Refresh Git status |
| `f` | Open changed files |
| `Space` | Stage or unstage the selected file |
| `Enter` | Append a diff to the output pane |
| `D` twice | Discard the selected change with confirmation |
| `t` | Show Git worktrees |

Untracked file deletion is confirmation-backed.

### Run History

Per-project run history is stored in `.dockpit/history.log` and can be reviewed from the TUI or CLI.

```sh
dockpit --history
dockpit --history --history-status failed --history-limit 10
dockpit --history --json
```

Inside the TUI, use `h` for history, `a`/`s`/`e`/`S` to filter all/success/failed/signal entries, `i` for details, and `C` twice to clear history.

### Command Palette and Search

Use `/` for fuzzy task search, `:` for the command palette, and output focus plus `/` to search logs.

---

## Usage

### Basic Commands

```sh
# Start the TUI in the current project
dockpit

# Print detected tasks
dockpit --print-tasks
dockpit --print-tasks --json

# Run one task without the TUI
dockpit --run zig-build

# Use another project root
dockpit --project-dir ../my-project --print-tasks
```

### History Commands

```sh
# Print recent runs
dockpit --history

# Filter history
dockpit --history --history-status failed --history-limit 10
dockpit --history-task zig-test

# Clear stored history
dockpit --clear-history
```

### Validation and Git Options

```sh
# Disable Git discovery
dockpit --no-git

# Fail on invalid config instead of falling back to auto detection
dockpit --strict-config --print-tasks
```

### TUI Key Bindings

| Key | Action |
| --- | --- |
| `Enter` | Run selected task |
| `j` / `Down` | Select next task or scroll output |
| `k` / `Up` | Select previous task or scroll output |
| `/` | Search tasks; with output focused, search output |
| `:` | Open command palette |
| `r` | Rerun the last task |
| `x` | Cancel the newest running task |
| `c` | Clear output |
| `g` | Refresh Git status |
| `f` | Show Git changes |
| `t` | Show Git worktrees |
| `i` | Show selected task details |
| `J` | Show running jobs |
| `h` | Show run history |
| `w` | Toggle file-watch rerun |
| `Tab` | Switch focus between tasks and output |
| `?` | Show help |
| `q` / `Ctrl+C` | Quit when no task is running |

---

## Install

### Build from source

This project targets Zig 0.16.0.

```sh
git clone https://github.com/ydah/dockpit.git
cd dockpit
zig build -Doptimize=ReleaseSafe
```

The executable is installed at:

```sh
zig-out/bin/dockpit
```

### Development run

```sh
zig build run
```

### Release artifacts

Tagged releases are built by GitHub Actions for Linux and macOS, with SHA-256 checksum files attached.

---

## Customize

### Config File

Create `.dockpit.json` in the project root.

```json
{
  "version": 3,
  "theme": "high-contrast",
  "default_task": "dev",
  "default_group": "project",
  "runner": {
    "inherit_env": true,
    "timeout_ms": 120000,
    "max_output_bytes": 16777216
  },
  "watch": {
    "debounce_ms": 1000,
    "ignore": ["dist", "tmp"]
  },
  "keybindings": {
    "rerun": "ctrl+r",
    "palette": "p"
  },
  "tasks": [
    {
      "id": "dev",
      "label": "dev server",
      "cmd": ["npm", "run", "dev"],
      "cwd": ".",
      "description": "Start the development server",
      "group": "serve",
      "watch": false,
      "timeout_ms": 60000,
      "max_output_bytes": 8388608,
      "env": {
        "NODE_ENV": "development"
      }
    },
    {
      "id": "test",
      "label": "all tests",
      "cmd": ["zig", "build", "test"]
    }
  ]
}
```

### Task Fields

| Field | Description |
| --- | --- |
| `id` | Unique task id |
| `label` | Display label; defaults to `id` |
| `cmd` | Required argv array |
| `cwd` | Working directory; defaults to project root |
| `env` | Extra environment values |
| `description` | Detail text shown in the TUI |
| `group` | Task group label |
| `default` | Marks the default task; only one task may set it |
| `watch` | Enables or disables file-watch rerun for the task |
| `inherit_env` | Uses the parent process environment when true |
| `timeout_ms` | Kills the task after this duration |
| `max_output_bytes` | Maximum stdout or stderr capture size |

`cmd` must be a non-empty argv array. User-configured commands are not executed through a shell.

### Themes

Built-in themes:

| Theme | Notes |
| --- | --- |
| `default` | Terminal-native styling |
| `dark` | Low-contrast dark terminal palette |
| `light` | Light terminal palette |
| `high-contrast` | Strong selection and status styling |

### Keybinding Names

Configurable keybinding names include:

```text
run, rerun, cancel, clear, git, changes, worktrees, details,
jobs, history, watch, search, palette, focus, help, quit
```

Keybindings must be unique.

---

## Auto Detection

`dockpit` detects tasks from these project markers:

| File | Tasks |
| --- | --- |
| `.dockpit.json` | Configured tasks |
| `build.zig` | Zig build/test and simple build steps |
| `Makefile` / `makefile` | `.PHONY` targets or simple targets |
| `justfile` / `Justfile` | Simple recipes without arguments |
| `package.json` | Package scripts through npm/pnpm/yarn/bun |
| `pnpm-workspace.yaml` | Workspace package scripts |
| `deno.json` / `deno.jsonc` | `deno task <name>` |
| `Cargo.toml` | Cargo root and workspace member tasks |
| `go.mod` / `go.work` | Go module and workspace tasks |
| `pyproject.toml` / `requirements.txt` / `setup.py` | `python -m pytest` |
| `Gemfile` | Bundler test commands |
| `flake.nix` | Nix flake commands |
| `Taskfile.yml` / `Taskfile.yaml` | Taskfile tasks |
| `mise.toml` / `.mise.toml` | mise tasks |
| Compose YAML files | Docker Compose stack and service tasks |

---

## FAQ

### A command is missing from the task list

Add it explicitly to `.dockpit.json`.

```json
{
  "tasks": [
    {
      "id": "fmt",
      "cmd": ["zig", "fmt", "."]
    }
  ]
}
```

### My config is invalid but dockpit still starts

By default, invalid config falls back to auto detection. Use strict mode when validating config:

```sh
dockpit --strict-config --print-tasks
```

### Can dockpit run shell snippets?

No. `cmd` is an argv array by design. Use a script file if you need shell features, then call that script from `cmd`.

```json
{
  "id": "deploy",
  "cmd": ["./script/deploy.sh"]
}
```

### Where is run history stored?

In the project root:

```text
.dockpit/history.log
```

### How do I reset history?

```sh
dockpit --clear-history
```

### TUI output is too large

Set a task or runner limit:

```json
{
  "runner": {
    "max_output_bytes": 16777216
  }
}
```

---

## Project Goals

- Fast startup with useful zero-config task discovery.
- Visual-first local development workflow in one terminal screen.
- Safe command execution through argv arrays, not shell strings.
- Core logic that stays independent from the TUI.
- Practical Git, history, watch, and workspace support without heavyweight dependencies.

---

## Development

```sh
zig fmt .
zig build test
zig build
zig build -Doptimize=ReleaseSafe
```

Useful smoke checks:

```sh
zig build run -- --print-tasks
zig build run -- --project-dir tests/fixtures/pnpm_workspace_file_project --print-tasks --json
zig build run -- --history --json
```

---

## Credits

- [libvaxis](https://github.com/rockorager/libvaxis) for the TUI foundation.
- Zig's standard library for process execution, JSON parsing, and portable IO.

## License

MIT. See [LICENSE](LICENSE).
