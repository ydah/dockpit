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

Disable Git status discovery:

```sh
zig build run -- --no-git
```

## Key Bindings

| Key | Action |
|---|---|
| `q` / `Ctrl+C` | Quit when no task is running |
| `j` / `Down` | Select next task |
| `k` / `Up` | Select previous task |
| `Enter` | Run selected task |
| `/` | Fuzzy-search tasks |
| `:` | Open command palette |
| `r` | Rerun the last task |
| `x` | Request cancellation for the running task |
| `c` | Clear output |
| `g` | Refresh Git status |
| `t` | Show Git worktrees |
| `w` | Toggle file-watch rerun |

## Configuration

Create `.dockpit.json` in the project root:

```json
{
  "theme": "high-contrast",
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

`cmd` must be an argv array. `dockpit` does not run user-configured commands through a shell.

Supported themes are `default`, `dark`, `light`, and `high-contrast`. Keybinding names include `run`, `rerun`, `cancel`, `clear`, `git`, `worktrees`, `watch`, `search`, `palette`, and `quit`.

## Auto Detection

`dockpit` detects tasks from these files in the project root:

| File | Tasks |
|---|---|
| `.dockpit.json` | configured tasks |
| `build.zig` | `zig build`, `zig build test` |
| `Makefile` / `makefile` | `.PHONY` targets or simple targets |
| `justfile` / `Justfile` | simple recipes without arguments |
| `package.json` | `npm run <script>` |
| `Cargo.toml` | `cargo build`, `cargo test`, `cargo run` |
| `go.mod` | `go test ./...`, `go build ./...`, `go run .` |
| `compose.yaml` / `compose.yml` / `docker-compose.yml` / `docker-compose.yaml` | Docker Compose up/down/ps/logs |

## Runtime Notes

- Multiple tasks can run concurrently in background threads.
- TUI task output is appended after each task exits.
- `x` records a cancellation request safely; full process termination is still limited.
- File watching uses a portable polling snapshot and ignores generated directories such as `.git`, `.zig-cache`, `zig-out`, `node_modules`, `target`, and `.dockpit`.
- Per-project run history is stored in `.dockpit/history.log`.
- Interactive terminal commands are not fully emulated.
- Windows support has not been hardened.

## Development

```sh
zig fmt .
zig build test
zig build
zig build -Doptimize=ReleaseSafe
```

The implementation plan lives in [docs/codex-tasks.md](docs/codex-tasks.md), and the product design lives in [docs/design.md](docs/design.md).
