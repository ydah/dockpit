const std = @import("std");

const task = @import("task.zig");

pub const RunnerError = error{
    InvalidTask,
};

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    elapsed_ms: u64,

    pub fn exitCode(result: RunResult) ?u8 {
        return switch (result.term) {
            .exited => |code| code,
            else => null,
        };
    }
};

pub fn runTask(
    allocator: std.mem.Allocator,
    io: std.Io,
    item: task.TaskSpec,
    base_env: ?*const std.process.Environ.Map,
) !RunResult {
    if (item.argv.len == 0) return error.InvalidTask;

    var env_map: std.process.Environ.Map = undefined;
    var env_ptr: ?*const std.process.Environ.Map = null;
    var has_env_map = false;
    defer if (has_env_map) env_map.deinit();

    if (item.env.len > 0) {
        env_map = if (base_env) |env| try env.clone(allocator) else std.process.Environ.Map.init(allocator);
        has_env_map = true;
        for (item.env) |entry| {
            try env_map.put(entry.key, entry.value);
        }
        env_ptr = &env_map;
    }

    const start = std.Io.Clock.awake.now(io);
    const result = try std.process.run(allocator, io, .{
        .argv = item.argv,
        .cwd = .{ .path = item.cwd },
        .environ_map = env_ptr,
        .stdout_limit = .limited(1024 * 1024 * 16),
        .stderr_limit = .limited(1024 * 1024 * 16),
    });
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
        .elapsed_ms = @intCast(@max(0, elapsed)),
    };
}

test "run task captures stdout" {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const item = task.TaskSpec{
        .id = "echo",
        .label = "echo",
        .argv = &.{ "/bin/echo", "hello" },
        .cwd = cwd,
        .source = .config,
    };

    const result = try runTask(std.testing.allocator, std.testing.io, item, null);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
