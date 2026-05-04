const std = @import("std");

const task = @import("task.zig");

pub const ConfigError = error{
    InvalidConfig,
};

pub fn loadConfigTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    config_path: []const u8,
) ![]task.TaskSpec {
    const path = try resolveConfigPath(allocator, project_root, config_path);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return try allocator.alloc(task.TaskSpec, 0),
        else => |e| return e,
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidConfig;

    const tasks_value = root.object.get("tasks") orelse return try allocator.alloc(task.TaskSpec, 0);
    if (tasks_value != .array) return error.InvalidConfig;

    var tasks: std.ArrayList(task.TaskSpec) = .empty;
    errdefer tasks.deinit(allocator);

    for (tasks_value.array.items) |task_value| {
        try tasks.append(allocator, try parseTask(allocator, project_root, task_value));
    }

    return tasks.toOwnedSlice(allocator);
}

fn parseTask(allocator: std.mem.Allocator, project_root: []const u8, value: std.json.Value) !task.TaskSpec {
    if (value != .object) return error.InvalidConfig;

    const id = try requiredString(value.object.get("id"));
    const cmd = value.object.get("cmd") orelse return error.InvalidConfig;
    if (cmd != .array or cmd.array.items.len == 0) return error.InvalidConfig;

    const argv = try allocator.alloc([]const u8, cmd.array.items.len);
    errdefer allocator.free(argv);
    for (cmd.array.items, 0..) |arg_value, index| {
        const arg = try requiredString(arg_value);
        argv[index] = try allocator.dupe(u8, arg);
    }

    const label = if (value.object.get("label")) |label_value|
        try allocator.dupe(u8, try requiredString(label_value))
    else
        try allocator.dupe(u8, id);

    const cwd = if (value.object.get("cwd")) |cwd_value|
        try resolveCwd(allocator, project_root, try requiredString(cwd_value))
    else
        try allocator.dupe(u8, project_root);

    const env = if (value.object.get("env")) |env_value|
        try parseEnv(allocator, env_value)
    else
        try allocator.alloc(task.EnvVar, 0);

    return .{
        .id = try allocator.dupe(u8, id),
        .label = label,
        .argv = argv,
        .cwd = cwd,
        .source = .config,
        .env = env,
    };
}

fn parseEnv(allocator: std.mem.Allocator, value: std.json.Value) ![]task.EnvVar {
    if (value != .object) return error.InvalidConfig;

    var env = try allocator.alloc(task.EnvVar, value.object.count());
    errdefer allocator.free(env);

    var iterator = value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        if (entry.value_ptr.* != .string) return error.InvalidConfig;
        env[index] = .{
            .key = try allocator.dupe(u8, entry.key_ptr.*),
            .value = try allocator.dupe(u8, entry.value_ptr.string),
        };
    }

    return env;
}

fn requiredString(value: ?std.json.Value) ![]const u8 {
    const actual = value orelse return error.InvalidConfig;
    if (actual != .string) return error.InvalidConfig;
    return actual.string;
}

fn resolveConfigPath(allocator: std.mem.Allocator, project_root: []const u8, config_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(config_path)) return allocator.dupe(u8, config_path);
    return std.fs.path.join(allocator, &.{ project_root, config_path });
}

fn resolveCwd(allocator: std.mem.Allocator, project_root: []const u8, cwd: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(cwd)) return allocator.dupe(u8, cwd);
    return std.fs.path.join(allocator, &.{ project_root, cwd });
}

test "load config tasks from dockpit json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    const tasks = try loadConfigTasks(allocator, std.testing.io, root, ".dockpit.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("dev", tasks[0].id);
    try std.testing.expectEqualStrings("dev server", tasks[0].label);
    try std.testing.expectEqualStrings("npm", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("run", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("dev", tasks[0].argv[2]);
    try std.testing.expectEqualStrings(root, tasks[1].cwd);
    try std.testing.expectEqual(@as(usize, 1), tasks[0].env.len);
    try std.testing.expectEqualStrings("NODE_ENV", tasks[0].env[0].key);
}

test "missing config returns empty task list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    const tasks = try loadConfigTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 0), tasks.len);
}

test "broken config returns an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    _ = loadConfigTasks(allocator, std.testing.io, root, "broken.json") catch return;
    return error.TestUnexpectedResult;
}

test "invalid config shape returns an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    try std.testing.expectError(
        error.InvalidConfig,
        loadConfigTasks(allocator, std.testing.io, root, "invalid.json"),
    );
}
