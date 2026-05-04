# dockpit

`dockpit` is a Zig TUI project cockpit for local development workflows.

The MVP discovers common project tasks, runs them without shell-string execution, and shows command output plus a compact Git status in one terminal screen.

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
| `r` | Rerun the last task |
| `x` | Request cancellation for the running task |
| `c` | Clear output |
| `g` | Refresh Git status |

## Configuration

Create `.dockpit.json` in the project root:

```json
{
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

## MVP Limits

- One task runs at a time.
- TUI task execution runs in a background thread, but output is appended after the task exits.
- `x` records a cancellation request safely; full process termination is still limited.
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
