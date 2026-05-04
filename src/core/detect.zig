const std = @import("std");

const config = @import("config.zig");
const task = @import("task.zig");

pub fn detectTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    config_path: []const u8,
) ![]task.TaskSpec {
    return detectTasksWithConfigMode(allocator, io, project_root, config_path, false);
}

pub fn detectTasksStrict(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    config_path: []const u8,
) ![]task.TaskSpec {
    return detectTasksWithConfigMode(allocator, io, project_root, config_path, true);
}

fn detectTasksWithConfigMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    config_path: []const u8,
    strict_config: bool,
) ![]task.TaskSpec {
    var tasks: std.ArrayList(task.TaskSpec) = .empty;
    errdefer tasks.deinit(allocator);

    const config_tasks = config.loadConfigTasks(allocator, io, project_root, config_path) catch |err| {
        if (strict_config) return err;
        return detectAutoTasks(allocator, io, project_root, &tasks);
    };
    defer allocator.free(config_tasks);
    for (config_tasks) |config_task| {
        try tasks.append(allocator, config_task);
    }

    return detectAutoTasks(allocator, io, project_root, &tasks);
}

fn detectAutoTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) ![]task.TaskSpec {
    try detectZigTasks(allocator, io, project_root, tasks);
    try detectMakeTasks(allocator, io, project_root, tasks);
    try detectJustTasks(allocator, io, project_root, tasks);
    try detectNpmTasks(allocator, io, project_root, tasks);
    try detectDenoTasks(allocator, io, project_root, tasks);
    try detectCargoTasks(allocator, io, project_root, tasks);
    try detectGoTasks(allocator, io, project_root, tasks);
    try detectPythonTasks(allocator, io, project_root, tasks);
    try detectRubyTasks(allocator, io, project_root, tasks);
    try detectNixTasks(allocator, io, project_root, tasks);
    try detectTaskfileTasks(allocator, io, project_root, tasks);
    try detectMiseTasks(allocator, io, project_root, tasks);
    try detectDockerComposeTasks(allocator, io, project_root, tasks);

    return tasks.toOwnedSlice(allocator);
}

fn detectZigTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    const contents = try readFirstProjectFile(allocator, io, project_root, &.{"build.zig"}) orelse return;
    defer allocator.free(contents);

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

    var steps: std.ArrayList([]const u8) = .empty;
    defer steps.deinit(allocator);
    try collectZigBuildSteps(allocator, contents, &steps);

    for (steps.items) |step| {
        defer allocator.free(step);
        const id = try prefixedId(allocator, "zig", step);
        defer allocator.free(id);
        const label = try std.fmt.allocPrint(allocator, "zig build {s}", .{step});
        defer allocator.free(label);

        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            id,
            label,
            &.{ "zig", "build", step },
            project_root,
            .zig,
        ));
    }
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

    const manager = try detectPackageManager(allocator, io, project_root, root);
    var iterator = scripts.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;

        const name = entry.key_ptr.*;
        const id = try prefixedId(allocator, manager.name, name);
        defer allocator.free(id);
        const label = try std.fmt.allocPrint(allocator, "{s} run {s}", .{ manager.name, name });
        defer allocator.free(label);

        if (manager.source == .yarn) {
            try appendUniqueTask(allocator, tasks, try makeTask(
                allocator,
                id,
                label,
                &.{ "yarn", "run", name },
                project_root,
                manager.source,
            ));
        } else {
            try appendUniqueTask(allocator, tasks, try makeTask(
                allocator,
                id,
                label,
                &.{ manager.name, "run", name },
                project_root,
                manager.source,
            ));
        }
    }
}

const PackageManager = struct {
    name: []const u8,
    source: task.TaskSource,
};

fn detectPackageManager(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    package_json: std.json.Value,
) !PackageManager {
    if (package_json == .object) {
        if (package_json.object.get("packageManager")) |value| {
            if (value == .string) {
                if (matchesPackageManager(value.string, "pnpm")) return .{ .name = "pnpm", .source = .pnpm };
                if (matchesPackageManager(value.string, "yarn")) return .{ .name = "yarn", .source = .yarn };
                if (matchesPackageManager(value.string, "bun")) return .{ .name = "bun", .source = .bun };
                if (matchesPackageManager(value.string, "npm")) return .{ .name = "npm", .source = .npm };
            }
        }
    }

    if (try hasFile(allocator, io, project_root, "pnpm-lock.yaml")) return .{ .name = "pnpm", .source = .pnpm };
    if (try hasFile(allocator, io, project_root, "yarn.lock")) return .{ .name = "yarn", .source = .yarn };
    if (try hasAnyFile(allocator, io, project_root, &.{ "bun.lock", "bun.lockb" })) return .{ .name = "bun", .source = .bun };
    return .{ .name = "npm", .source = .npm };
}

fn matchesPackageManager(value: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, value, name)) return true;
    return value.len > name.len and
        std.mem.startsWith(u8, value, name) and
        value[name.len] == '@';
}

fn detectDenoTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    const contents = try readFirstProjectFile(allocator, io, project_root, &.{ "deno.json", "deno.jsonc" }) orelse return;
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;
    const deno_tasks = root.object.get("tasks") orelse return;
    if (deno_tasks != .object) return;

    var iterator = deno_tasks.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string and entry.value_ptr.* != .object) continue;

        const name = entry.key_ptr.*;
        const id = try prefixedId(allocator, "deno", name);
        defer allocator.free(id);
        const label = try std.fmt.allocPrint(allocator, "deno task {s}", .{name});
        defer allocator.free(label);

        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            id,
            label,
            &.{ "deno", "task", name },
            project_root,
            .deno,
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

fn detectPythonTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    if (!try hasAnyFile(allocator, io, project_root, &.{ "pyproject.toml", "requirements.txt", "setup.py" })) return;

    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "python-test",
        "python -m pytest",
        &.{ "python", "-m", "pytest" },
        project_root,
        .python,
    ));
}

fn detectRubyTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    if (!try hasFile(allocator, io, project_root, "Gemfile")) return;

    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "ruby-test",
        "bundle exec rake test",
        &.{ "bundle", "exec", "rake", "test" },
        project_root,
        .ruby,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "ruby-rspec",
        "bundle exec rspec",
        &.{ "bundle", "exec", "rspec" },
        project_root,
        .ruby,
    ));
}

fn detectNixTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    if (!try hasFile(allocator, io, project_root, "flake.nix")) return;

    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "nix-check",
        "nix flake check",
        &.{ "nix", "flake", "check" },
        project_root,
        .nix,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "nix-build",
        "nix build",
        &.{ "nix", "build" },
        project_root,
        .nix,
    ));
    try appendUniqueTask(allocator, tasks, try makeTask(
        allocator,
        "nix-develop",
        "nix develop",
        &.{ "nix", "develop" },
        project_root,
        .nix,
    ));
}

fn detectTaskfileTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    const contents = try readFirstProjectFile(allocator, io, project_root, &.{ "Taskfile.yml", "Taskfile.yaml" }) orelse return;
    defer allocator.free(contents);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    try collectYamlSectionKeys(allocator, contents, "tasks", &names);

    for (names.items) |name| {
        defer allocator.free(name);
        const id = try prefixedId(allocator, "task", name);
        defer allocator.free(id);
        const label = try std.fmt.allocPrint(allocator, "task {s}", .{name});
        defer allocator.free(label);

        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            id,
            label,
            &.{ "task", name },
            project_root,
            .taskfile,
        ));
    }
}

fn detectMiseTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    const contents = try readFirstProjectFile(allocator, io, project_root, &.{ "mise.toml", ".mise.toml" }) orelse return;
    defer allocator.free(contents);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    try collectMiseTaskNames(allocator, contents, &names);

    for (names.items) |name| {
        defer allocator.free(name);
        const id = try prefixedId(allocator, "mise", name);
        defer allocator.free(id);
        const label = try std.fmt.allocPrint(allocator, "mise run {s}", .{name});
        defer allocator.free(label);

        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            id,
            label,
            &.{ "mise", "run", name },
            project_root,
            .mise,
        ));
    }
}

fn detectDockerComposeTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    const contents = try readFirstProjectFile(
        allocator,
        io,
        project_root,
        &.{ "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml" },
    ) orelse return;
    defer allocator.free(contents);

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

    var services: std.ArrayList([]const u8) = .empty;
    defer services.deinit(allocator);
    try collectYamlSectionKeys(allocator, contents, "services", &services);

    for (services.items) |service| {
        defer allocator.free(service);

        const up_id = try prefixedId(allocator, "compose-up", service);
        defer allocator.free(up_id);
        const up_label = try std.fmt.allocPrint(allocator, "docker compose up {s}", .{service});
        defer allocator.free(up_label);
        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            up_id,
            up_label,
            &.{ "docker", "compose", "up", service },
            project_root,
            .docker,
        ));

        const restart_id = try prefixedId(allocator, "compose-restart", service);
        defer allocator.free(restart_id);
        const restart_label = try std.fmt.allocPrint(allocator, "docker compose restart {s}", .{service});
        defer allocator.free(restart_label);
        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            restart_id,
            restart_label,
            &.{ "docker", "compose", "restart", service },
            project_root,
            .docker,
        ));

        const logs_id = try prefixedId(allocator, "compose-logs", service);
        defer allocator.free(logs_id);
        const logs_label = try std.fmt.allocPrint(allocator, "docker compose logs --tail=200 {s}", .{service});
        defer allocator.free(logs_label);
        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            logs_id,
            logs_label,
            &.{ "docker", "compose", "logs", "--tail=200", service },
            project_root,
            .docker,
        ));

        const build_id = try prefixedId(allocator, "compose-build", service);
        defer allocator.free(build_id);
        const build_label = try std.fmt.allocPrint(allocator, "docker compose build {s}", .{service});
        defer allocator.free(build_label);
        try appendUniqueTask(allocator, tasks, try makeTask(
            allocator,
            build_id,
            build_label,
            &.{ "docker", "compose", "build", service },
            project_root,
            .docker,
        ));
    }
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
        .description = try allocator.dupe(u8, ""),
        .group = try allocator.dupe(u8, ""),
    };
}

fn discardTask(allocator: std.mem.Allocator, item: task.TaskSpec) void {
    allocator.free(item.id);
    allocator.free(item.label);
    for (item.argv) |arg| allocator.free(arg);
    allocator.free(item.argv);
    allocator.free(item.cwd);
    allocator.free(item.env);
    allocator.free(item.description);
    allocator.free(item.group);
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

fn collectZigBuildSteps(
    allocator: std.mem.Allocator,
    contents: []const u8,
    steps: *std.ArrayList([]const u8),
) !void {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, contents, index, ".step(")) |match_index| {
        index = match_index + ".step(".len;
        if (isInLineComment(contents, match_index)) continue;

        var cursor = index;
        skipWhitespace(contents, &cursor);
        const name = try parseZigStringLiteral(allocator, contents, &cursor) orelse continue;
        defer allocator.free(name);
        if (!isMakeTargetName(name)) continue;
        try appendUniqueName(allocator, steps, name);
    }
}

fn collectYamlSectionKeys(
    allocator: std.mem.Allocator,
    contents: []const u8,
    section_name: []const u8,
    names: *std.ArrayList([]const u8),
) !void {
    var in_section = false;
    var section_indent: usize = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const without_cr = std.mem.trimEnd(u8, raw_line, "\r");
        const stripped = std.mem.trimStart(u8, without_cr, " \t");
        if (stripped.len == 0 or stripped[0] == '#') continue;

        const indent = without_cr.len - stripped.len;
        if (!in_section) {
            const header = try std.fmt.allocPrint(allocator, "{s}:", .{section_name});
            defer allocator.free(header);
            if (std.mem.eql(u8, stripped, header)) {
                in_section = true;
                section_indent = indent;
            }
            continue;
        }

        if (indent <= section_indent) {
            in_section = false;
            continue;
        }
        if (indent != section_indent + 2) continue;

        const colon_index = std.mem.indexOfScalar(u8, stripped, ':') orelse continue;
        const raw_name = std.mem.trim(u8, stripped[0..colon_index], " \t");
        const name = trimOptionalQuotes(raw_name);
        if (!isSimpleTaskName(name)) continue;
        try appendUniqueName(allocator, names, name);
    }
}

fn collectMiseTaskNames(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]const u8),
) !void {
    var in_tasks_table = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            in_tasks_table = std.mem.eql(u8, line, "[tasks]");
            if (std.mem.startsWith(u8, line, "[tasks.") and std.mem.endsWith(u8, line, "]")) {
                const raw_name = line["[tasks.".len .. line.len - 1];
                const name = trimOptionalQuotes(raw_name);
                if (isSimpleTaskName(name)) try appendUniqueName(allocator, names, name);
            }
            continue;
        }

        if (!in_tasks_table) continue;
        const equals_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const raw_name = std.mem.trim(u8, line[0..equals_index], " \t");
        const name = trimOptionalQuotes(raw_name);
        if (isSimpleTaskName(name)) try appendUniqueName(allocator, names, name);
    }
}

fn parseZigStringLiteral(
    allocator: std.mem.Allocator,
    contents: []const u8,
    cursor: *usize,
) !?[]const u8 {
    if (cursor.* >= contents.len or contents[cursor.*] != '"') return null;
    cursor.* += 1;

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(allocator);

    while (cursor.* < contents.len) {
        const char = contents[cursor.*];
        cursor.* += 1;

        switch (char) {
            '"' => {
                const owned = try value.toOwnedSlice(allocator);
                return owned;
            },
            '\n', '\r' => break,
            '\\' => {
                if (cursor.* >= contents.len) break;
                const escaped = contents[cursor.*];
                cursor.* += 1;
                try value.append(allocator, escaped);
            },
            else => try value.append(allocator, char),
        }
    }

    value.deinit(allocator);
    return null;
}

fn skipWhitespace(contents: []const u8, cursor: *usize) void {
    while (cursor.* < contents.len) : (cursor.* += 1) {
        switch (contents[cursor.*]) {
            ' ', '\t', '\n', '\r' => continue,
            else => return,
        }
    }
}

fn isInLineComment(contents: []const u8, index: usize) bool {
    const line_start = if (std.mem.lastIndexOfScalar(u8, contents[0..index], '\n')) |newline| newline + 1 else 0;
    return std.mem.indexOf(u8, contents[line_start..index], "//") != null;
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

fn isSimpleTaskName(name: []const u8) bool {
    if (name.len == 0) return false;

    for (name) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '_' or char == '.' or char == '-' or char == ':') continue;
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

fn trimOptionalQuotes(value: []const u8) []const u8 {
    if (value.len < 2) return value;
    if ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\''))
    {
        return value[1 .. value.len - 1];
    }
    return value;
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

test "detect zig build steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/zig_steps_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 4), tasks.len);
    try std.testing.expectEqualStrings("zig-build", tasks[0].id);
    try std.testing.expectEqualStrings("zig-test", tasks[1].id);
    try std.testing.expectEqualStrings("zig-fmt", tasks[2].id);
    try std.testing.expectEqualStrings("zig", tasks[2].argv[0]);
    try std.testing.expectEqualStrings("build", tasks[2].argv[1]);
    try std.testing.expectEqualStrings("fmt", tasks[2].argv[2]);
    try std.testing.expectEqualStrings("zig-release-safe", tasks[3].id);
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

test "detect package scripts with package manager metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/pnpm_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("pnpm-dev", tasks[0].id);
    try std.testing.expectEqualStrings("pnpm", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("run", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("dev", tasks[0].argv[2]);
    try std.testing.expectEqual(task.TaskSource.pnpm, tasks[0].source);
    try std.testing.expectEqualStrings("pnpm-test", tasks[1].id);
}

test "detect deno tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/deno_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("deno-dev", tasks[0].id);
    try std.testing.expectEqualStrings("deno", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("task", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("dev", tasks[0].argv[2]);
    try std.testing.expectEqualStrings("deno-test", tasks[1].id);
    try std.testing.expectEqual(task.TaskSource.deno, tasks[0].source);
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

test "detect python tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/python_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expectEqualStrings("python-test", tasks[0].id);
    try std.testing.expectEqualStrings("python", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("-m", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("pytest", tasks[0].argv[2]);
    try std.testing.expectEqual(task.TaskSource.python, tasks[0].source);
}

test "detect ruby tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/ruby_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("ruby-test", tasks[0].id);
    try std.testing.expectEqualStrings("bundle", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("exec", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("ruby-rspec", tasks[1].id);
    try std.testing.expectEqual(task.TaskSource.ruby, tasks[0].source);
}

test "detect nix flake tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/nix_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 3), tasks.len);
    try std.testing.expectEqualStrings("nix-check", tasks[0].id);
    try std.testing.expectEqualStrings("nix-build", tasks[1].id);
    try std.testing.expectEqualStrings("nix-develop", tasks[2].id);
    try std.testing.expectEqual(task.TaskSource.nix, tasks[0].source);
}

test "detect taskfile tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/taskfile_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("task-build", tasks[0].id);
    try std.testing.expectEqualStrings("task", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("build", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("task-test", tasks[1].id);
    try std.testing.expectEqual(task.TaskSource.taskfile, tasks[0].source);
}

test "detect mise tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/mise_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "missing.json");

    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("mise-build", tasks[0].id);
    try std.testing.expectEqualStrings("mise", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("run", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("build", tasks[0].argv[2]);
    try std.testing.expectEqualStrings("mise-test", tasks[1].id);
    try std.testing.expectEqual(task.TaskSource.mise, tasks[0].source);
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

    try std.testing.expectEqual(@as(usize, 8), tasks.len);
    try std.testing.expectEqualStrings("compose-up", tasks[0].id);
    try std.testing.expectEqualStrings("docker", tasks[0].argv[0]);
    try std.testing.expectEqualStrings("compose", tasks[0].argv[1]);
    try std.testing.expectEqualStrings("compose-down", tasks[1].id);
    try std.testing.expectEqualStrings("compose-ps", tasks[2].id);
    try std.testing.expectEqualStrings("compose-logs", tasks[3].id);
    try std.testing.expectEqualStrings("compose-up-app", tasks[4].id);
    try std.testing.expectEqualStrings("app", tasks[4].argv[3]);
    try std.testing.expectEqualStrings("compose-restart-app", tasks[5].id);
    try std.testing.expectEqualStrings("compose-logs-app", tasks[6].id);
    try std.testing.expectEqualStrings("app", tasks[6].argv[4]);
    try std.testing.expectEqualStrings("compose-build-app", tasks[7].id);
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

test "detect falls back on invalid config by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    const tasks = try detectTasks(allocator, std.testing.io, root, "broken.json");

    try std.testing.expectEqual(@as(usize, 0), tasks.len);
}

test "detect strict config returns invalid config errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/config_project",
        allocator,
    );

    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        detectTasksStrict(allocator, std.testing.io, root, "broken.json"),
    );
}
