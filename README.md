# dockpit

`dockpit` is a Zig TUI project cockpit for local development workflows.

`dockpit` discovers common project tasks, runs them without shell-string execution, and shows command output plus Git/worktree status in one terminal screen.

## Install

This project targets Zig 0.16.0.

```sh
zig build
```

The executable is installed at `zig-out/bin/dockpit`.

## Usage

Start the TUI in the current project:

```sh
zig build run
```

Print detected tasks without starting the TUI:

```sh
zig build run -- --print-tasks
```

Use a different project directory:

```sh
zig build run -- --project-dir ../my-project --print-tasks
```

Run a task without starting the TUI:

```sh
zig build run -- --run zig-build
```

Print or clear recent run history:

```sh
zig build run -- --history --history-status failed --history-limit 10
zig build run -- --clear-history
```

Disable Git status discovery:

```sh
zig build run -- --no-git
```

Treat invalid configuration as an error instead of falling back to auto detection:

```sh
zig build run -- --strict-config --print-tasks
```

## Key Bindings

| Key | Action |
|---|---|
| `q` / `Ctrl+C` | Quit when no task is running |
| `j` / `Down` | Select next task |
| `k` / `Up` | Select previous task |
| `Enter` | Run selected task |
| `/` | Fuzzy-search tasks; with output focused, search output |
| `:` | Open command palette |
| `r` | Rerun the last task |
| `x` | Cancel the newest running task |
| `c` | Clear output |
| `g` | Refresh Git status |
| `f` | Show Git changes |
| `t` | Show Git worktrees |
| `J` | Show running jobs |
| `h` | Show run history |
| `w` | Toggle file-watch rerun |
| `Tab` | Switch focus between tasks and output |
| `?` | Show help |

## Configuration

Create `.dockpit.json` in the project root:

```json
{
  "theme": "high-contrast",
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
      "default": true,
      "watch": false,
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

`cmd` must be a non-empty argv array. `dockpit` does not run user-configured commands through a shell. Task metadata fields are optional: `description`, `group`, `default`, and `watch`.

Configured task ids must be unique, only one task can set `default: true`, and keybindings cannot collide. Supported themes are `default`, `dark`, `light`, and `high-contrast`. Keybinding names include `run`, `rerun`, `cancel`, `clear`, `git`, `changes`, `worktrees`, `jobs`, `history`, `watch`, `search`, `palette`, `focus`, `help`, and `quit`.

## Auto Detection

`dockpit` detects tasks from these files in the project root:

| File | Tasks |
|---|---|
| `.dockpit.json` | configured tasks |
| `build.zig` | `zig build`, `zig build test`, and simple `b.step("name", ...)` build steps |
| `Makefile` / `makefile` | `.PHONY` targets or simple targets |
| `justfile` / `Justfile` | simple recipes without arguments |
| `package.json` | package scripts via `npm`, `pnpm`, `yarn`, or `bun`, inferred from `packageManager` or lockfiles |
| `deno.json` / `deno.jsonc` | `deno task <name>` |
| `Cargo.toml` | `cargo build`, `cargo test`, `cargo run` |
| `go.mod` | `go test ./...`, `go build ./...`, `go run .` |
| `pyproject.toml` / `requirements.txt` / `setup.py` | `python -m pytest` |
| `Gemfile` | `bundle exec rake test`, `bundle exec rspec` |
| `flake.nix` | `nix flake check`, `nix build`, `nix develop` |
| `Taskfile.yml` / `Taskfile.yaml` | `task <name>` |
| `mise.toml` / `.mise.toml` | `mise run <name>` |
| `compose.yaml` / `compose.yml` / `docker-compose.yml` / `docker-compose.yaml` | Docker Compose up/down/ps/logs plus service up/restart/logs/build tasks |

## Runtime Notes

- Multiple tasks can run concurrently in background threads.
- TUI task output streams while tasks are running.
- `x` requests cancellation and terminates the child process for running background tasks.
- The Git changes view supports `Space` to stage or unstage the selected file and `Enter` to append a diff to output.
- File watching uses a portable polling snapshot, honors each task's `watch` flag, and ignores generated directories such as `.git`, `.zig-cache`, `zig-out`, `node_modules`, `target`, and `.dockpit`.
- Per-project run history is stored in `.dockpit/history.log`.
- Interactive commands should be exposed as non-interactive tasks; dockpit does not allocate a PTY.

## Development

```sh
zig fmt .
zig build test
zig build
zig build -Doptimize=ReleaseSafe
```
