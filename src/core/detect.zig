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
    try detectMakeTasks(allocator, io, project_root, &tasks);
    try detectJustTasks(allocator, io, project_root, &tasks);
    try detectNpmTasks(allocator, io, project_root, &tasks);
    try detectCargoTasks(allocator, io, project_root, &tasks);
    try detectGoTasks(allocator, io, project_root, &tasks);
    try detectDockerComposeTasks(allocator, io, project_root, &tasks);

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

fn detectMakeTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    const contents = try readFirstProjectFile(allocator, io, project_root, &.{ "Makefile", "makefile" }) orelse return;
    defer allocator.free(contents);

    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(allocator);

    try collectPhonyMakeTargets(allocator, contents, &targets);
    if (targets.items.len == 0) {
        try collectMakeRuleTargets(allocator, contents, &targets);
    }

    for (targets.items) |target| {
        defer allocator.free(target);
        const id = try prefixedId(allocator, "make", target);
        defer allocator.free(id);
        const label = try prefixedLabel(allocator, "make", target);
        defer allocator.free(label);

        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            id,
            label,
            &.{ "make", target },
            project_root,
            .make,
        ));
    }
}

fn detectJustTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    const contents = try readFirstProjectFile(allocator, io, project_root, &.{ "justfile", "Justfile" }) orelse return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon_index];
        if (!isJustRecipeName(name)) continue;

        const id = try prefixedId(allocator, "just", name);
        defer allocator.free(id);
        const label = try prefixedLabel(allocator, "just", name);
        defer allocator.free(label);

        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            id,
            label,
            &.{ "just", name },
            project_root,
            .just,
        ));
    }
}

fn detectNpmTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    const contents = try readFirstProjectFile(allocator, io, project_root, &.{"package.json"}) orelse return;
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;
    const scripts = root.object.get("scripts") orelse return;
    if (scripts != .object) return;

    var iterator = scripts.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;

        const name = entry.key_ptr.*;
        const id = try prefixedId(allocator, "npm", name);
        defer allocator.free(id);
        const label = try std.fmt.allocPrint(allocator, "npm run {s}", .{name});
        defer allocator.free(label);

        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            id,
            label,
            &.{ "npm", "run", name },
            project_root,
            .npm,
        ));
    }
}

fn detectCargoTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    if (!try hasFile(allocator, io, project_root, "Cargo.toml")) return;

    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "cargo-build",
        "cargo build",
        &.{ "cargo", "build" },
        project_root,
        .cargo,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "cargo-test",
        "cargo test",
        &.{ "cargo", "test" },
        project_root,
        .cargo,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "cargo-run",
        "cargo run",
        &.{ "cargo", "run" },
        project_root,
        .cargo,
    ));
}

fn detectGoTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    if (!try hasFile(allocator, io, project_root, "go.mod")) return;

    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "go-test",
        "go test ./...",
        &.{ "go", "test", "./..." },
        project_root,
        .go,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "go-build",
        "go build ./...",
        &.{ "go", "build", "./..." },
        project_root,
        .go,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "go-run",
        "go run .",
        &.{ "go", "run", "." },
        project_root,
        .go,
    ));
}

fn detectDockerComposeTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    if (!try hasAnyFile(
        allocator,
        io,
        project_root,
        &.{ "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml" },
    )) return;

    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "compose-up",
        "docker compose up",
        &.{ "docker", "compose", "up" },
        project_root,
        .docker,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "compose-down",
        "docker compose down",
        &.{ "docker", "compose", "down" },
        project_root,
        .docker,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "compose-ps",
        "docker compose ps",
        &.{ "docker", "compose", "ps" },
        project_root,
        .docker,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "compose-logs",
        "docker compose logs --tail=200",
        &.{ "docker", "compose", "logs", "--tail=200" },
        project_root,
        .docker,
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

fn hasAnyFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    names: []const []const u8,
) !bool {
    for (names) |name| {
        if (try hasFile(allocator, io, project_root, name)) return true;
    }
    return false;
}

fn readFirstProjectFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    names: []const []const u8,
) !?[]u8 {
    for (names) |name| {
        const path = try std.fs.path.join(allocator, &.{ project_root, name });
        defer allocator.free(path);

        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => |e| return e,
        };
    }

    return null;
}

fn collectPhonyMakeTargets(
    allocator: std.mem.Allocator,
    contents: []const u8,
    targets: *std.ArrayList([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, ".PHONY:")) continue;

        var names = std.mem.tokenizeAny(u8, line[".PHONY:".len..], " \t");
        while (names.next()) |name| {
            if (!isMakeTargetName(name)) continue;
            try appendUniqueName(allocator, targets, name);
        }
    }
}

fn collectMakeRuleTargets(
    allocator: std.mem.Allocator,
    contents: []const u8,
    targets: *std.ArrayList([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon_index];
        if (!isMakeTargetName(name)) continue;
        try appendUniqueName(allocator, targets, name);
    }
}

fn appendUniqueName(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    name: []const u8,
) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }

    try names.append(allocator, try allocator.dupe(u8, name));
}

fn isMakeTargetName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfAny(u8, name, " \t/%") != null) return false;

    for (name) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '_' or char == '.' or char == '-') continue;
        return false;
    }

    return true;
}

fn isJustRecipeName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;

    for (name[1..]) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '_' or char == '-') continue;
        return false;
    }

    return true;
}

fn prefixedId(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, name });
}

fn prefixedLabel(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, name });
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

test "detect make tasks from phony targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/make_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("make-build", tasks[0].id);
    try std.testing.expectEqualStrings("make", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("build", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("make-test", tasks[1].id);
}

test "detect just tasks from simple recipes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/just_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("just-build", tasks[0].id);
    try std.testing.expectEqualStrings("just", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("build", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("just-test", tasks[1].id);
}

test "detect npm package scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/node_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("npm-dev", tasks[0].id);
    try std.testing.expectEqualStrings("npm", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("run", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("dev", tasks[0].argv[2]);
    try std.testing.expectEqualStrings("npm-test", tasks[1].id);
}

test "detect cargo tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/cargo_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 3), tasks.len);
    try std.testing.expectEqualStrings("cargo-build", tasks[0].id);
    try std.testing.expectEqualStrings("cargo-test", tasks[1].id);
    try std.testing.expectEqualStrings("cargo-run", tasks[2].id);
}

test "detect go tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/go_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 3), tasks.len);
    try std.testing.expectEqualStrings("go-test", tasks[0].id);
    try std.testing.expectEqualStrings("go-build", tasks[1].id);
    try std.testing.expectEqualStrings("go-run", tasks[2].id);
}

test "detect docker compose tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/compose_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 4), tasks.len);
    try std.testing.expectEqualStrings("compose-up", tasks[0].id);
    try std.testing.expectEqualStrings("docker", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("compose", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("compose-down", tasks[1].id);
    try std.testing.expectEqualStrings("compose-ps", tasks[2].id);
    try std.testing.expectEqualStrings("compose-logs", tasks[3].id);
    try std.testing.expectEqual(task.TaskSource.docker, tasks[0].source);
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
