const std = @import("std");

const config = @import("config.zig");
const task = @import("task.zig");

pub fn detectTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    config_path: []const u8,
) ![]task.TaskSpec {
    var tasks: std.ArrayList(task.TaskSpec) = .empty;
    errdefer tasks.deinit(allocator);

    const config_tasks = try config.loadConfigTasks(allocator, io, project_root, config_path);
    defer allocator.free(config_tasks);
    for (config_tasks) |config_task| {
        try tasks.append(allocator, config_task);
    }

    try detectZigTasks(allocator, io, project_root, &tasks);

    return tasks.toOwnedSlice(allocator);
}

fn detectZigTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    if (!try hasFile(allocator, io, project_root, "build.zig")) return;

    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "zig-build",
        "zig build",
        &.{ "zig", "build" },
        project_root,
        .zig,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "zig-test",
        "zig build test",
        &.{ "zig", "build", "test" },
        project_root,
        .zig,
    ));
}

fn appendUniqueTask(
    allocator: std.mem.Allocator,
    tasks: *std.ArrayList(task.TaskSpec),
    candidate: task.TaskSpec,
) !void {
    for (tasks.items) |existing| {
        if (std.mem.eql(u8, existing.id, candidate.id) or existing.commandEquals(candidate)) {
            discardTask(allocator, candidate);
            return;
        }
    }

    try tasks.append(allocator, candidate);
}

fn makeTask(
    allocator: std.mem.Allocator,
    id: []const u8,
    label: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    source: task.TaskSource,
) !task.TaskSpec {
    const owned_argv = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(owned_argv);

    for (argv, 0..) |arg, index| {
        owned_argv[index] = try allocator.dupe(u8, arg);
    }

    return .{
        .id = try allocator.dupe(u8, id),
        .label = try allocator.dupe(u8, label),
        .argv = owned_argv,
        .cwd = try allocator.dupe(u8, cwd),
        .source = source,
        .env = try allocator.alloc(task.EnvVar, 0),
    };
}

fn discardTask(allocator: std.mem.Allocator, item: task.TaskSpec) void {
    allocator.free(item.id);
    allocator.free(item.label);
    for (item.argv) |arg| allocator.free(arg);
    allocator.free(item.argv);
    allocator.free(item.cwd);
    allocator.free(item.env);
}

fn hasFile(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ project_root, name });
    defer allocator.free(path);

    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "detect zig project tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/zig_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("zig-build", tasks[0].id);
    try std.testing.expectEqualStrings("zig-test", tasks[1].id);
}

test "detect keeps config task over duplicate zig id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/zig_config_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, ".dockpit.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("zig-build", tasks[0].id);
    try std.testing.expectEqualStrings("custom build", tasks[0].label);
    try std.testing.expectEqual(task.TaskSource.config, tasks[0].source);
    try std.testing.expectEqualStrings("zig-test", tasks[1].id);
}
