const std = @import("std");

const task = @import("task.zig");

pub const ConfigError = error{
    InvalidConfig,
    EmptyTaskId,
    EmptyCommandArg,
    DuplicateTaskId,
    DuplicateDefaultTask,
    InvalidCwd,
    DuplicateKeyBinding,
};

pub const Theme = enum {
    default,
    dark,
    light,
    high_contrast,

    pub fn label(theme: Theme) []const u8 {
        return switch (theme) {
            .default => "default",
            .dark => "dark",
            .light => "light",
            .high_contrast => "high-contrast",
        };
    }
};

pub const KeyBindings = struct {
    run: []const u8 = "enter",
    rerun: []const u8 = "r",
    cancel: []const u8 = "x",
    clear: []const u8 = "c",
    git: []const u8 = "g",
    changes: []const u8 = "f",
    worktrees: []const u8 = "t",
    watch: []const u8 = "w",
    search: []const u8 = "/",
    palette: []const u8 = ":",
    details: []const u8 = "i",
    focus: []const u8 = "tab",
    help: []const u8 = "?",
    jobs: []const u8 = "J",
    history: []const u8 = "h",
    quit: []const u8 = "q",
};

pub const Settings = struct {
    theme: Theme = .default,
    keybindings: KeyBindings = .{},
    watch: WatchSettings = .{},
};

pub const WatchSettings = struct {
    debounce_ms: u64 = 1000,
    ignore: []const []const u8 = &.{},
};

pub fn loadSettings(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    config_path: []const u8,
) !Settings {
    const path = try resolveConfigPath(allocator, project_root, config_path);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{},
        else => |e| return e,
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidConfig;

    var settings = Settings{};
    if (root.object.get("theme")) |theme_value| {
        settings.theme = try parseTheme(theme_value);
    }
    if (root.object.get("keybindings")) |keybindings_value| {
        settings.keybindings = try parseKeybindings(allocator, keybindings_value, settings.keybindings);
        try validateKeybindings(settings.keybindings);
    }
    if (root.object.get("watch")) |watch_value| {
        settings.watch = try parseWatchSettings(allocator, watch_value);
    }
    return settings;
}

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
    errdefer {
        for (tasks.items) |item| item.deinit(allocator);
        tasks.deinit(allocator);
    }
    var has_default = false;

    for (tasks_value.array.items) |task_value| {
        const item = try parseTask(allocator, io, project_root, task_value);
        validateTask(tasks.items, item, &has_default) catch |err| {
            item.deinit(allocator);
            return err;
        };
        tasks.append(allocator, item) catch |err| {
            item.deinit(allocator);
            return err;
        };
    }

    return tasks.toOwnedSlice(allocator);
}

fn parseTheme(value: std.json.Value) !Theme {
    const name = try requiredString(value);
    if (std.mem.eql(u8, name, "default")) return .default;
    if (std.mem.eql(u8, name, "dark")) return .dark;
    if (std.mem.eql(u8, name, "light")) return .light;
    if (std.mem.eql(u8, name, "high-contrast") or std.mem.eql(u8, name, "high_contrast")) return .high_contrast;
    return error.InvalidConfig;
}

fn parseKeybindings(allocator: std.mem.Allocator, value: std.json.Value, defaults: KeyBindings) !KeyBindings {
    if (value != .object) return error.InvalidConfig;
    var bindings = defaults;

    inline for (@typeInfo(KeyBindings).@"struct".fields) |field| {
        if (value.object.get(field.name)) |binding_value| {
            @field(bindings, field.name) = try allocator.dupe(u8, try requiredString(binding_value));
        }
    }
    return bindings;
}

fn parseWatchSettings(allocator: std.mem.Allocator, value: std.json.Value) !WatchSettings {
    if (value != .object) return error.InvalidConfig;

    var settings = WatchSettings{};
    if (value.object.get("debounce_ms")) |debounce_value| {
        settings.debounce_ms = try positiveInteger(debounce_value);
    }
    if (value.object.get("ignore")) |ignore_value| {
        if (ignore_value != .array) return error.InvalidConfig;
        const ignore = try allocator.alloc([]const u8, ignore_value.array.items.len);
        errdefer allocator.free(ignore);
        for (ignore_value.array.items, 0..) |entry, index| {
            const pattern = try requiredString(entry);
            if (pattern.len == 0) return error.InvalidConfig;
            ignore[index] = try allocator.dupe(u8, pattern);
        }
        settings.ignore = ignore;
    }
    return settings;
}

fn parseTask(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, value: std.json.Value) !task.TaskSpec {
    if (value != .object) return error.InvalidConfig;

    const id = try requiredString(value.object.get("id"));
    if (id.len == 0) return error.EmptyTaskId;
    const cmd = value.object.get("cmd") orelse return error.InvalidConfig;
    if (cmd != .array or cmd.array.items.len == 0) return error.InvalidConfig;

    const argv = try allocator.alloc([]const u8, cmd.array.items.len);
    @memset(argv, "");
    errdefer {
        for (argv) |arg| if (arg.len > 0) allocator.free(arg);
        allocator.free(argv);
    }
    for (cmd.array.items, 0..) |arg_value, index| {
        const arg = try requiredString(arg_value);
        if (arg.len == 0) return error.EmptyCommandArg;
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
    errdefer allocator.free(cwd);
    try validateCwd(io, cwd);

    const env = if (value.object.get("env")) |env_value|
        try parseEnv(allocator, env_value)
    else
        try allocator.alloc(task.EnvVar, 0);

    const description = if (value.object.get("description")) |description_value|
        try allocator.dupe(u8, try requiredString(description_value))
    else
        try allocator.dupe(u8, "");

    const group = if (value.object.get("group")) |group_value|
        try allocator.dupe(u8, try requiredString(group_value))
    else
        try allocator.dupe(u8, "");

    const default_task = if (value.object.get("default")) |default_value|
        try optionalBool(default_value)
    else
        false;

    const watch = if (value.object.get("watch")) |watch_value|
        try optionalBool(watch_value)
    else
        true;

    return .{
        .id = try allocator.dupe(u8, id),
        .label = label,
        .argv = argv,
        .cwd = cwd,
        .source = .config,
        .env = env,
        .description = description,
        .group = group,
        .default_task = default_task,
        .watch = watch,
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

fn validateTask(existing: []const task.TaskSpec, item: task.TaskSpec, has_default: *bool) !void {
    for (existing) |previous| {
        if (std.mem.eql(u8, previous.id, item.id)) return error.DuplicateTaskId;
    }
    if (!item.default_task) return;
    if (has_default.*) return error.DuplicateDefaultTask;
    has_default.* = true;
}

fn validateKeybindings(bindings: KeyBindings) !void {
    const info = @typeInfo(KeyBindings).@"struct";
    inline for (info.fields, 0..) |left, left_index| {
        const left_value = @field(bindings, left.name);
        if (left_value.len == 0) return error.InvalidConfig;
        inline for (info.fields, 0..) |right, right_index| {
            if (right_index <= left_index) continue;
            const right_value = @field(bindings, right.name);
            if (std.mem.eql(u8, left_value, right_value)) return error.DuplicateKeyBinding;
        }
    }
}

fn validateCwd(io: std.Io, cwd: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, cwd, .{}) catch return error.InvalidCwd;
    dir.close(io);
}

fn requiredString(value: ?std.json.Value) ![]const u8 {
    const actual = value orelse return error.InvalidConfig;
    if (actual != .string) return error.InvalidConfig;
    return actual.string;
}

fn optionalBool(value: std.json.Value) !bool {
    if (value != .bool) return error.InvalidConfig;
    return value.bool;
}

fn positiveInteger(value: std.json.Value) !u64 {
    if (value != .integer) return error.InvalidConfig;
    if (value.integer <= 0) return error.InvalidConfig;
    return @intCast(value.integer);
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
    try std.testing.expectEqualStrings("Start the development server", tasks[0].description);
    try std.testing.expectEqualStrings("serve", tasks[0].group);
    try std.testing.expect(tasks[0].default_task);
    try std.testing.expect(!tasks[0].watch);
}

test "load settings from dockpit json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    const settings = try loadSettings(allocator, std.testing.io, root, "settings.json");

    try std.testing.expectEqual(Theme.high_contrast, settings.theme);
    try std.testing.expectEqualStrings("ctrl+r", settings.keybindings.rerun);
    try std.testing.expectEqualStrings("enter", settings.keybindings.run);
    try std.testing.expectEqual(@as(u64, 250), settings.watch.debounce_ms);
    try std.testing.expectEqual(@as(usize, 2), settings.watch.ignore.len);
    try std.testing.expectEqualStrings("tmp", settings.watch.ignore[0]);
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

test "duplicate task ids return an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    try std.testing.expectError(
        error.DuplicateTaskId,
        loadConfigTasks(allocator, std.testing.io, root, "duplicate_task.json"),
    );
}

test "duplicate default tasks return an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    try std.testing.expectError(
        error.DuplicateDefaultTask,
        loadConfigTasks(allocator, std.testing.io, root, "duplicate_default.json"),
    );
}

test "invalid cwd returns an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    try std.testing.expectError(
        error.InvalidCwd,
        loadConfigTasks(allocator, std.testing.io, root, "invalid_cwd.json"),
    );
}

test "duplicate keybindings return an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    try std.testing.expectError(
        error.DuplicateKeyBinding,
        loadSettings(allocator, std.testing.io, root, "duplicate_keybindings.json"),
    );
}
