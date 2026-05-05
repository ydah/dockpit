const std = @import("std");

const task = @import("task.zig");

const default_max_output_bytes = 1024 * 1024 * 16;

pub const RunnerError = error{
    InvalidTask,
};

pub const StreamKind = enum {
    stdout,
    stderr,
};

pub const StreamCallback = *const fn (context: *anyopaque, kind: StreamKind, bytes: []const u8) anyerror!void;

pub const RunOptions = struct {
    timeout_ms: ?u64 = null,
    max_output_bytes: usize = default_max_output_bytes,
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
    const Context = struct {
        fn onOutput(_: *anyopaque, _: StreamKind, _: []const u8) !void {}
    };

    var cancel_requested = std.atomic.Value(bool).init(false);
    var context = Context{};
    return runTaskStreaming(
        allocator,
        io,
        item,
        base_env,
        &cancel_requested,
        &context,
        Context.onOutput,
    );
}

const EnvState = struct {
    map: std.process.Environ.Map = undefined,
    active: bool = false,
    base_ptr: ?*const std.process.Environ.Map = null,

    fn init(
        allocator: std.mem.Allocator,
        item: task.TaskSpec,
        base_env: ?*const std.process.Environ.Map,
    ) !EnvState {
        var state = EnvState{};

        if (item.inherit_env and item.env.len == 0) {
            state.base_ptr = base_env;
            return state;
        }

        state.map = if (item.inherit_env)
            if (base_env) |env| try env.clone(allocator) else std.process.Environ.Map.init(allocator)
        else
            std.process.Environ.Map.init(allocator);
        state.active = true;

        for (item.env) |entry| {
            try state.map.put(entry.key, entry.value);
        }
        return state;
    }

    fn ptr(state: *const EnvState) ?*const std.process.Environ.Map {
        if (state.active) return &state.map;
        return state.base_ptr;
    }

    fn deinit(state: *EnvState) void {
        if (state.active) state.map.deinit();
    }
};

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

    var env_state = try EnvState.init(allocator, item, base_env);
    defer env_state.deinit();
    const options = runOptions(item);

    const start = std.Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = item.argv,
        .cwd = .{ .path = item.cwd },
        .environ_map = env_state.ptr(),
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

    var forced_term: ?std.process.Child.Term = null;
    const poll_timeout: std.Io.Timeout = .{
        .duration = .{
            .raw = .fromMilliseconds(50),
            .clock = .awake,
        },
    };

    while (true) {
        if (cancel_requested.load(.acquire)) {
            child.kill(io);
            forced_term = .{ .unknown = 130 };
            break;
        }
        if (timedOut(io, start, options.timeout_ms)) {
            child.kill(io);
            forced_term = .{ .unknown = 124 };
            break;
        }

        multi_reader.fill(1, poll_timeout) catch |err| switch (err) {
            error.Timeout => continue,
            error.EndOfStream => break,
            else => |e| return e,
        };

        try drainBuffered(allocator, stdout_reader, &stdout, .stdout, context, callback);
        try drainBuffered(allocator, stderr_reader, &stderr, .stderr, context, callback);
        if (stdout.items.len > options.max_output_bytes or stderr.items.len > options.max_output_bytes) return error.StreamTooLong;
    }

    try drainBuffered(allocator, stdout_reader, &stdout, .stdout, context, callback);
    try drainBuffered(allocator, stderr_reader, &stderr, .stderr, context, callback);
    if (stdout.items.len > options.max_output_bytes or stderr.items.len > options.max_output_bytes) return error.StreamTooLong;
    if (forced_term == null) try multi_reader.checkAnyError();

    const term: std.process.Child.Term = forced_term orelse try child.wait(io);
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

fn runOptions(item: task.TaskSpec) RunOptions {
    return .{
        .timeout_ms = item.timeout_ms,
        .max_output_bytes = item.max_output_bytes orelse default_max_output_bytes,
    };
}

fn timedOut(io: std.Io, start: std.Io.Timestamp, timeout_ms: ?u64) bool {
    const timeout = timeout_ms orelse return false;
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    return @as(u64, @intCast(@max(0, elapsed))) >= timeout;
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

test "run task enforces max output bytes" {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const item = task.TaskSpec{
        .id = "echo",
        .label = "echo",
        .argv = &.{ "/bin/echo", "hello" },
        .cwd = cwd,
        .source = .config,
        .max_output_bytes = 1,
    };

    try std.testing.expectError(
        error.StreamTooLong,
        runTask(std.testing.allocator, std.testing.io, item, null),
    );
}

test "run task honors timeout" {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const item = task.TaskSpec{
        .id = "sleep",
        .label = "sleep",
        .argv = &.{ "/bin/sleep", "5" },
        .cwd = cwd,
        .source = .config,
        .timeout_ms = 50,
    };

    const result = try runTask(std.testing.allocator, std.testing.io, item, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .unknown = 124 }, result.term);
}

test "run task can disable inherited environment" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("DOCKPIT_TEST_ENV", "visible");

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const inherited = task.TaskSpec{
        .id = "env",
        .label = "env",
        .argv = &.{"/usr/bin/env"},
        .cwd = cwd,
        .source = .config,
    };
    const inherited_result = try runTask(std.testing.allocator, std.testing.io, inherited, &env_map);
    defer inherited_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, inherited_result.stdout, "DOCKPIT_TEST_ENV=visible") != null);

    const isolated = task.TaskSpec{
        .id = "env",
        .label = "env",
        .argv = &.{"/usr/bin/env"},
        .cwd = cwd,
        .source = .config,
        .inherit_env = false,
    };
    const isolated_result = try runTask(std.testing.allocator, std.testing.io, isolated, &env_map);
    defer isolated_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, isolated_result.stdout, "DOCKPIT_TEST_ENV=visible") == null);
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
