const std = @import("std");

const task = @import("task.zig");

const max_output_bytes = 1024 * 1024 * 16;

pub const RunnerError = error{
    InvalidTask,
};

pub const StreamKind = enum {
    stdout,
    stderr,
};

pub const StreamCallback = *const fn (context: *anyopaque, kind: StreamKind, bytes: []const u8) anyerror!void;

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

    pub fn deinit(result: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
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
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
        .elapsed_ms = @intCast(@max(0, elapsed)),
    };
}

pub fn runTaskStreaming(
    allocator: std.mem.Allocator,
    io: std.Io,
    item: task.TaskSpec,
    base_env: ?*const std.process.Environ.Map,
    cancel_requested: *const std.atomic.Value(bool),
    context: *anyopaque,
    callback: StreamCallback,
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
    var child = try std.process.spawn(io, .{
        .argv = item.argv,
        .cwd = .{ .path = item.cwd },
        .environ_map = env_ptr,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);

    var killed = false;
    const poll_timeout: std.Io.Timeout = .{
        .duration = .{
            .raw = .fromMilliseconds(50),
            .clock = .awake,
        },
    };

    while (true) {
        if (cancel_requested.load(.acquire)) {
            child.kill(io);
            killed = true;
            break;
        }

        multi_reader.fill(1, poll_timeout) catch |err| switch (err) {
            error.Timeout => continue,
            error.EndOfStream => break,
            else => |e| return e,
        };

        try drainBuffered(allocator, stdout_reader, &stdout, .stdout, context, callback);
        try drainBuffered(allocator, stderr_reader, &stderr, .stderr, context, callback);
        if (stdout.items.len > max_output_bytes or stderr.items.len > max_output_bytes) return error.StreamTooLong;
    }

    try drainBuffered(allocator, stdout_reader, &stdout, .stdout, context, callback);
    try drainBuffered(allocator, stderr_reader, &stderr, .stderr, context, callback);
    if (!killed) try multi_reader.checkAnyError();

    const term: std.process.Child.Term = if (killed)
        .{ .unknown = 130 }
    else
        try child.wait(io);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    const stdout_owned = try stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_owned);
    const stderr_owned = try stderr.toOwnedSlice(allocator);

    return .{
        .stdout = stdout_owned,
        .stderr = stderr_owned,
        .term = term,
        .elapsed_ms = @intCast(@max(0, elapsed)),
    };
}

fn drainBuffered(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    output: *std.ArrayList(u8),
    kind: StreamKind,
    context: *anyopaque,
    callback: StreamCallback,
) !void {
    const bytes = reader.buffered();
    if (bytes.len == 0) return;

    try output.appendSlice(allocator, bytes);
    try callback(context, kind, bytes);
    reader.tossBuffered();
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

test "streaming task emits output chunks" {
    const Context = struct {
        out: std.ArrayList(u8) = .empty,

        fn onOutput(ptr: *anyopaque, kind: StreamKind, bytes: []const u8) !void {
            try std.testing.expectEqual(StreamKind.stdout, kind);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.out.appendSlice(std.testing.allocator, bytes);
        }
    };

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const item = task.TaskSpec{
        .id = "echo",
        .label = "echo",
        .argv = &.{ "/bin/echo", "hello" },
        .cwd = cwd,
        .source = .config,
    };
    var cancel_requested = std.atomic.Value(bool).init(false);
    var context = Context{};
    defer context.out.deinit(std.testing.allocator);

    const result = try runTaskStreaming(
        std.testing.allocator,
        std.testing.io,
        item,
        null,
        &cancel_requested,
        &context,
        Context.onOutput,
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqualStrings("hello\n", context.out.items);
}

test "streaming task honors cancellation" {
    const Context = struct {
        fn onOutput(_: *anyopaque, _: StreamKind, _: []const u8) !void {}
    };

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const item = task.TaskSpec{
        .id = "sleep",
        .label = "sleep",
        .argv = &.{ "/bin/sleep", "5" },
        .cwd = cwd,
        .source = .config,
    };
    var cancel_requested = std.atomic.Value(bool).init(true);
    var context = Context{};

    const result = try runTaskStreaming(
        std.testing.allocator,
        std.testing.io,
        item,
        null,
        &cancel_requested,
        &context,
        Context.onOutput,
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .unknown = 130 }, result.term);
}
