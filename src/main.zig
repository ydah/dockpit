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

    if (options.print_tasks) {
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
