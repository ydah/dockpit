pub const version = "0.1.0";
pub const cli = @import("cli.zig");
pub const task = @import("core/task.zig");
pub const log_buffer = @import("core/log_buffer.zig");
pub const project = @import("core/project.zig");

test {
    _ = version;
    _ = cli;
    _ = task;
    _ = log_buffer;
    _ = project;
}
