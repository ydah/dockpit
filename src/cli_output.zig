const std = @import("std");
const Io = std.Io;

const failures = @import("core/failures.zig");
const history = @import("core/history.zig");
const runner = @import("core/runner.zig");
const task = @import("core/task.zig");

pub fn printVersion(io: std.Io, version: []const u8) !void {
    var buffer: [128]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("dockpit {s}\n", .{version});
    try stdout.flush();
}

pub fn printHelp(io: std.Io) !void {
    var buffer: [3072]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(
        \\Usage: dockpit [options]
        \\
        \\Options:
        \\  --project-dir <path>  Project directory. Defaults to current directory.
        \\  --config <path>       Config path. Defaults to .dockpit.json.
        \\  --print-tasks         Print detected tasks and exit.
        \\  --json                Print machine-readable JSON for list commands.
        \\  --run <task-id>       Run a task without starting the TUI.
        \\  --env <KEY=VALUE>     Add or override an environment value for runs.
        \\  --history             Print recent run history and exit.
        \\  --history-task <id>   Filter history to one task id.
        \\  --history-status <s>  Filter history: all, success, failed, signal.
        \\  --history-limit <n>   Limit history rows. Defaults to 20.
        \\  --clear-history       Clear stored run history.
        \\  --no-git              Disable Git status discovery.
        \\  --strict-config       Fail instead of falling back on invalid config.
        \\  --help                Show this help.
        \\  --version             Show version.
        \\
    );
    try stdout.flush();
}

pub fn printTasks(io: std.Io, project_root: []const u8, tasks: []const task.TaskSpec) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("project: {s}\n", .{project_root});
    try stdout.writeAll("id                 source  command\n");
    try stdout.writeAll("-----------------  ------  -------\n");

    for (tasks) |item| {
        try stdout.print("{s:<17}  {s:<6}  ", .{ item.id, item.source.label() });
        for (item.argv, 0..) |arg, index| {
            if (index > 0) try stdout.writeByte(' ');
            try stdout.writeAll(arg);
        }
        try stdout.writeByte('\n');
    }

    if (tasks.len == 0) {
        try stdout.writeAll("(no tasks detected)\n");
    }

    try stdout.flush();
}

pub fn printTasksJson(io: std.Io, project_root: []const u8, tasks: []const task.TaskSpec) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll("{\"project\":");
    try std.json.Stringify.value(project_root, .{}, stdout);
    try stdout.writeAll(",\"tasks\":[");
    for (tasks, 0..) |item, index| {
        if (index > 0) try stdout.writeByte(',');
        try stdout.writeAll("{\"id\":");
        try std.json.Stringify.value(item.id, .{}, stdout);
        try stdout.writeAll(",\"label\":");
        try std.json.Stringify.value(item.label, .{}, stdout);
        try stdout.writeAll(",\"source\":");
        try std.json.Stringify.value(item.source.label(), .{}, stdout);
        try stdout.writeAll(",\"cwd\":");
        try std.json.Stringify.value(item.cwd, .{}, stdout);
        try stdout.writeAll(",\"description\":");
        try std.json.Stringify.value(item.description, .{}, stdout);
        try stdout.writeAll(",\"group\":");
        try std.json.Stringify.value(item.group, .{}, stdout);
        try stdout.print(",\"default\":{},\"watch\":{},\"inherit_env\":{}", .{
            item.default_task,
            item.watch,
            item.inherit_env,
        });
        if (item.timeout_ms) |timeout_ms| {
            try stdout.print(",\"timeout_ms\":{d}", .{timeout_ms});
        } else {
            try stdout.writeAll(",\"timeout_ms\":null");
        }
        if (item.max_output_bytes) |limit| {
            try stdout.print(",\"max_output_bytes\":{d}", .{limit});
        } else {
            try stdout.writeAll(",\"max_output_bytes\":null");
        }
        try stdout.writeAll(",\"argv\":[");
        for (item.argv, 0..) |arg, arg_index| {
            if (arg_index > 0) try stdout.writeByte(',');
            try std.json.Stringify.value(arg, .{}, stdout);
        }
        try stdout.writeAll("]}");
    }
    try stdout.writeAll("]}\n");
    try stdout.flush();
}

pub fn printHistory(io: std.Io, project_root: []const u8, entries: []const history.Entry) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("project: {s}\n", .{project_root});
    try stdout.writeAll("timestamp_ms       task               status   elapsed_ms\n");
    try stdout.writeAll("-----------------  -----------------  -------  ----------\n");
    for (entries) |entry| {
        try stdout.print("{d:<17}  {s:<17}  {s:<7}  {d}\n", .{
            entry.timestamp_ms,
            entry.task_id,
            entry.status().label(),
            entry.elapsed_ms,
        });
    }
    if (entries.len == 0) {
        try stdout.writeAll("(no history)\n");
    }
    try stdout.flush();
}

pub fn printHistoryJson(io: std.Io, project_root: []const u8, entries: []const history.Entry) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll("{\"project\":");
    try std.json.Stringify.value(project_root, .{}, stdout);
    try stdout.writeAll(",\"history\":[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try stdout.writeByte(',');
        try stdout.print("{{\"timestamp_ms\":{d},\"task_id\":", .{entry.timestamp_ms});
        try std.json.Stringify.value(entry.task_id, .{}, stdout);
        try stdout.writeAll(",\"status\":");
        try std.json.Stringify.value(entry.status().label(), .{}, stdout);
        if (entry.exit_code) |code| {
            try stdout.print(",\"exit_code\":{d}", .{code});
        } else {
            try stdout.writeAll(",\"exit_code\":null");
        }
        try stdout.print(",\"elapsed_ms\":{d}}}", .{entry.elapsed_ms});
    }
    try stdout.writeAll("]}\n");
    try stdout.flush();
}

pub fn printLine(io: std.Io, line: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("{s}\n", .{line});
    try stdout.flush();
}

pub fn printRunResult(io: std.Io, item: task.TaskSpec, result: runner.RunResult) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeByte('$');
    for (item.argv) |arg| {
        try stdout.writeByte(' ');
        try stdout.writeAll(arg);
    }
    try stdout.writeByte('\n');

    try stdout.writeAll(result.stdout);
    try stdout.writeAll(result.stderr);

    switch (result.term) {
        .exited => |code| try stdout.print("\nexit {d} ({d} ms)\n", .{ code, result.elapsed_ms }),
        .signal => |signal| try stdout.print("\nsignal {d} ({d} ms)\n", .{ @intFromEnum(signal), result.elapsed_ms }),
        .stopped => |signal| try stdout.print("\nstopped {d} ({d} ms)\n", .{ @intFromEnum(signal), result.elapsed_ms }),
        .unknown => |code| try stdout.print("\nunknown {d} ({d} ms)\n", .{ code, result.elapsed_ms }),
    }

    try stdout.flush();
}

pub fn printFailures(io: std.Io, allocator: std.mem.Allocator, result: runner.RunResult) !void {
    const code = result.exitCode() orelse 1;
    if (code == 0) return;

    const parsed = try failures.parse(allocator, result.stdout, result.stderr, 12);
    defer failures.freeFailures(allocator, parsed);
    if (parsed.len == 0) return;

    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll("\nfailures:\n");
    for (parsed) |failure| {
        try stdout.print("- [{s}] {s}\n", .{ failure.kind.label(), failure.message });
    }
    try stdout.flush();
}
