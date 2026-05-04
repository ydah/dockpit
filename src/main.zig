const std = @import("std");
const Io = std.Io;

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

    if (options.run_task_id) |task_id| {
        const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
        const tasks = try dockpit.detect.detectTasks(arena, init.io, project_root, options.config_path);
        const item = findTask(tasks, task_id) orelse {
            std.debug.print("dockpit: unknown task id '{s}'\n", .{task_id});
            std.process.exit(1);
        };
        const result = try dockpit.runner.runTask(arena, init.io, item, init.environ_map);
        try printRunResult(init.io, item, result);
        if (result.exitCode()) |code| {
            std.process.exit(code);
        }
        std.process.exit(1);
    } else if (options.print_tasks) {
        const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
        const tasks = try dockpit.detect.detectTasks(arena, init.io, project_root, options.config_path);
        try printTasks(init.io, project_root, tasks);
        return;
    }

    const io = init.io;
    var buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll("dockpit: no mode selected yet\n");
    try stdout.flush();
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
        \\  --no-git              Disable Git status discovery.
        \\  --help                Show this help.
        \\  --version             Show version.
        \\
    );
    try stdout.flush();
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
