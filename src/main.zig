const std = @import("std");
const Io = std.Io;

pub const std_options: std.Options = .{ .log_level = .warn };

const dockpit = @import("dockpit");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = dockpit.cli.parse(args) catch |err| {
        std.debug.print("dockpit: {s}\n\n", .{@errorName(err)});
        printHelp(init.io) catch {};
        return err;
    };

    if (options.help) {
        try printHelp(init.io);
        return;
    }
    if (options.version) {
        try printVersion(init.io);
        return;
    }

    if (options.clear_history or options.history) {
        const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
        if (options.clear_history) {
            try dockpit.history.clear(arena, init.io, project_root);
            if (!options.history) {
                try printLine(init.io, "history cleared");
                return;
            }
        }
        const entries = try dockpit.history.loadRecentFiltered(arena, init.io, project_root, options.history_limit, .{
            .task_id = options.history_task_id,
            .status = historyStatus(options.history_status),
        });
        try printHistory(init.io, project_root, entries);
        return;
    }

    if (options.run_task_id) |task_id| {
        const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
        const tasks = try detectTasks(arena, init.io, project_root, options.config_path, options.strict_config);
        const item = findTask(tasks, task_id) orelse {
            std.debug.print("dockpit: unknown task id '{s}'\n", .{task_id});
            std.process.exit(1);
        };
        const result = try dockpit.runner.runTask(arena, init.io, item, init.environ_map);
        dockpit.history.appendRun(arena, init.io, project_root, item, result) catch {};
        try printRunResult(init.io, item, result);
        try printFailures(init.io, arena, result);
        if (result.exitCode()) |code| {
            std.process.exit(code);
        }
        std.process.exit(1);
    } else if (options.print_tasks) {
        const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
        const tasks = try detectTasks(arena, init.io, project_root, options.config_path, options.strict_config);
        try printTasks(init.io, project_root, tasks);
        return;
    }

    const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
    const tasks = try detectTasks(arena, init.io, project_root, options.config_path, options.strict_config);
    const settings = dockpit.config.loadSettings(arena, init.io, project_root, options.config_path) catch |err| settings: {
        if (options.strict_config) return err;
        std.debug.print("dockpit: ignoring invalid settings: {s}\n", .{@errorName(err)});
        break :settings dockpit.config.Settings{};
    };
    const git_summary = if (options.no_git) dockpit.git.GitSummary.none() else dockpit.git.loadSummary(arena, init.io, project_root);
    try dockpit.tui.run(arena, init.io, init.environ_map, project_root, tasks, git_summary, !options.no_git, settings);
}

fn printVersion(io: std.Io) !void {
    var buffer: [128]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("dockpit {s}\n", .{dockpit.version});
    try stdout.flush();
}

fn printHelp(io: std.Io) !void {
    var buffer: [2048]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(
        \\Usage: dockpit [options]
        \\
        \\Options:
        \\  --project-dir <path>  Project directory. Defaults to current directory.
        \\  --config <path>       Config path. Defaults to .dockpit.json.
        \\  --print-tasks         Print detected tasks and exit.
        \\  --run <task-id>       Run a task without starting the TUI.
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

fn detectTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    config_path: []const u8,
    strict_config: bool,
) ![]dockpit.task.TaskSpec {
    return if (strict_config)
        dockpit.detect.detectTasksStrict(allocator, io, project_root, config_path)
    else
        dockpit.detect.detectTasks(allocator, io, project_root, config_path);
}

fn historyStatus(status: dockpit.cli.HistoryStatus) dockpit.history.Status {
    return switch (status) {
        .all => .all,
        .success => .success,
        .failed => .failed,
        .signal => .signal,
    };
}

fn printTasks(io: std.Io, project_root: []const u8, tasks: []const dockpit.task.TaskSpec) !void {
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

fn printHistory(io: std.Io, project_root: []const u8, entries: []const dockpit.history.Entry) !void {
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

fn printLine(io: std.Io, line: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("{s}\n", .{line});
    try stdout.flush();
}

fn findTask(tasks: []const dockpit.task.TaskSpec, task_id: []const u8) ?dockpit.task.TaskSpec {
    for (tasks) |item| {
        if (std.mem.eql(u8, item.id, task_id)) return item;
    }

    return null;
}

fn printRunResult(io: std.Io, item: dockpit.task.TaskSpec, result: dockpit.runner.RunResult) !void {
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

fn printFailures(io: std.Io, allocator: std.mem.Allocator, result: dockpit.runner.RunResult) !void {
    const code = result.exitCode() orelse 1;
    if (code == 0) return;

    const failures = try dockpit.failures.parse(allocator, result.stdout, result.stderr, 12);
    if (failures.len == 0) return;

    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll("\nfailures:\n");
    for (failures) |failure| {
        try stdout.print("- [{s}] {s}\n", .{ failure.kind.label(), failure.message });
    }
    try stdout.flush();
}
