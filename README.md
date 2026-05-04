# dockpit

`dockpit` is a Zig TUI project cockpit for local development workflows.

The MVP discovers common project tasks, runs them without shell-string execution, and shows command output plus a compact Git status in one terminal screen.

## Development

This project targets Zig 0.16.0.

```sh
zig fmt .
zig build test
zig build
```

The implementation plan lives in [docs/codex-tasks.md](docs/codex-tasks.md), and the product design lives in [docs/design.md](docs/design.md).
