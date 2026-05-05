const std = @import("std");

pub const std_options: std.Options = .{ .log_level = .warn };

const dockpit = @import("dockpit");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = dockpit.cli.parse(args) catch |err| {
        std.debug.print("dockpit: {s}\n\n", .{@errorName(err)});
        dockpit.cli_output.printHelp(init.io) catch {};
        return err;
    };

    if (options.help) {
        try dockpit.cli_output.printHelp(init.io);
        return;
    }
    if (options.version) {
        try dockpit.cli_output.printVersion(init.io, dockpit.version);
        return;
    }

    if (options.clear_history or options.history) {
        const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
        if (options.clear_history) {
            try dockpit.history.clear(arena, init.io, project_root);
            if (!options.history) {
                try dockpit.cli_output.printLine(init.io, "history cleared");
                return;
            }
        }
        const entries = try dockpit.history.loadRecentFiltered(arena, init.io, project_root, options.history_limit, .{
            .task_id = options.history_task_id,
            .status = historyStatus(options.history_status),
        });
        if (options.json) {
            try dockpit.cli_output.printHistoryJson(init.io, project_root, entries);
        } else {
            try dockpit.cli_output.printHistory(init.io, project_root, entries);
        }
        return;
    }

    if (options.run_task_id) |task_id| {
        const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
        const tasks = try detectTasks(arena, init.io, project_root, options.config_path, options.strict_config);
        try applyEnvOverrides(arena, tasks, options.envOverrides());
        const item = findTask(tasks, task_id) orelse {
            std.debug.print("dockpit: unknown task id '{s}'\n", .{task_id});
            std.process.exit(1);
        };
        const result = try dockpit.runner.runTask(arena, init.io, item, init.environ_map);
        dockpit.history.appendRun(arena, init.io, project_root, item, result) catch {};
        try dockpit.cli_output.printRunResult(init.io, item, result);
        try dockpit.cli_output.printFailures(init.io, arena, result);
        if (result.exitCode()) |code| {
            std.process.exit(code);
        }
        std.process.exit(1);
    } else if (options.print_tasks) {
        const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
        const tasks = try detectTasks(arena, init.io, project_root, options.config_path, options.strict_config);
        if (options.json) {
            try dockpit.cli_output.printTasksJson(init.io, project_root, tasks);
        } else {
            try dockpit.cli_output.printTasks(init.io, project_root, tasks);
        }
        return;
    }

    const project_root = try dockpit.project.discoverRoot(arena, init.io, options.project_dir orelse ".");
    const tasks = try detectTasks(arena, init.io, project_root, options.config_path, options.strict_config);
    try applyEnvOverrides(arena, tasks, options.envOverrides());
    const settings = dockpit.config.loadSettings(arena, init.io, project_root, options.config_path) catch |err| settings: {
        if (options.strict_config) return err;
        std.debug.print("dockpit: ignoring invalid settings: {s}\n", .{@errorName(err)});
        break :settings dockpit.config.Settings{};
    };
    const git_summary = if (options.no_git) dockpit.git.GitSummary.none() else dockpit.git.loadSummary(arena, init.io, project_root);
    try dockpit.tui.run(arena, init.io, init.environ_map, project_root, tasks, git_summary, !options.no_git, settings);
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

fn applyEnvOverrides(
    allocator: std.mem.Allocator,
    tasks: []dockpit.task.TaskSpec,
    overrides: []const []const u8,
) !void {
    if (overrides.len == 0) return;

    for (tasks) |*item| {
        const old_env = item.env;
        const merged = try allocator.alloc(dockpit.task.EnvVar, old_env.len + overrides.len);

        var index: usize = 0;
        errdefer {
            for (merged[0..index]) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            allocator.free(merged);
        }
        for (old_env) |entry| {
            merged[index] = .{
                .key = try allocator.dupe(u8, entry.key),
                .value = try allocator.dupe(u8, entry.value),
            };
            index += 1;
        }
        for (overrides) |override| {
            const equals = std.mem.indexOfScalar(u8, override, '=') orelse unreachable;
            merged[index] = .{
                .key = try allocator.dupe(u8, override[0..equals]),
                .value = try allocator.dupe(u8, override[equals + 1 ..]),
            };
            index += 1;
        }

        for (old_env) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        allocator.free(old_env);
        item.env = merged;
    }
}

fn findTask(tasks: []const dockpit.task.TaskSpec, task_id: []const u8) ?dockpit.task.TaskSpec {
    for (tasks) |item| {
        if (std.mem.eql(u8, item.id, task_id)) return item;
    }

    return null;
}
