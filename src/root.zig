pub const version = "0.1.0";
pub const cli = @import("cli.zig");
pub const task = @import("core/task.zig");
pub const log_buffer = @import("core/log_buffer.zig");
pub const project = @import("core/project.zig");
pub const config = @import("core/config.zig");
pub const detect = @import("core/detect.zig");
pub const fuzzy = @import("core/fuzzy.zig");
pub const runner = @import("core/runner.zig");
pub const git = @import("core/git.zig");
pub const history = @import("core/history.zig");
pub const failures = @import("core/failures.zig");
pub const watch = @import("core/watch.zig");
pub const app_state = @import("core/app_state.zig");
pub const tui = @import("ui/tui.zig");

test {
    _ = version;
    _ = cli;
    _ = task;
    _ = log_buffer;
    _ = project;
    _ = config;
    _ = detect;
    _ = fuzzy;
    _ = runner;
    _ = git;
    _ = history;
    _ = failures;
    _ = watch;
    _ = app_state;
    _ = tui;
}
