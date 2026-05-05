const std = @import("std");

const support = @import("detect_support.zig");
const task = @import("task.zig");

const PackageManager = struct {
    name: []const u8,
    source: task.TaskSource,
};

pub fn detect(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
) !void {
    const contents = try support.readProjectFile(allocator, io, project_root, "package.json") orelse {
        try detectPnpmWorkspaceTasks(allocator, io, project_root, tasks, .{ .name = "pnpm", .source = .pnpm });
        return;
    };
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try detectPnpmWorkspaceTasks(allocator, io, project_root, tasks, .{ .name = "pnpm", .source = .pnpm });
        return;
    }

    const manager = try detectPackageManager(allocator, io, project_root, root);
    if (root.object.get("scripts")) |scripts| {
        try appendPackageScripts(allocator, tasks, scripts, project_root, manager.name, null, manager);
    }
    try detectPackageJsonWorkspaceTasks(allocator, io, project_root, tasks, root, manager);
    try detectPnpmWorkspaceTasks(allocator, io, project_root, tasks, manager);
}

fn appendPackageScripts(
    allocator: std.mem.Allocator,
    tasks: *std.ArrayList(task.TaskSpec),
    scripts: std.json.Value,
    cwd: []const u8,
    id_prefix: []const u8,
    workspace_label: ?[]const u8,
    manager: PackageManager,
) !void {
    if (scripts != .object) return;

    var iterator = scripts.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;

        const name = entry.key_ptr.*;
        const id = try support.prefixedId(allocator, id_prefix, name);
        defer allocator.free(id);
        const label = if (workspace_label) |label_name|
            try std.fmt.allocPrint(allocator, "{s} run {s} ({s})", .{ manager.name, name, label_name })
        else
            try std.fmt.allocPrint(allocator, "{s} run {s}", .{ manager.name, name });
        defer allocator.free(label);

        if (manager.source == .yarn) {
            try support.appendUniqueTask(allocator, tasks, try support.makeTask(
                allocator,
                id,
                label,
                &.{ "yarn", "run", name },
                cwd,
                manager.source,
            ));
        } else {
            try support.appendUniqueTask(allocator, tasks, try support.makeTask(
                allocator,
                id,
                label,
                &.{ manager.name, "run", name },
                cwd,
                manager.source,
            ));
        }
    }
}

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

    if (try support.hasFile(allocator, io, project_root, "pnpm-workspace.yaml")) return .{ .name = "pnpm", .source = .pnpm };
    if (try support.hasFile(allocator, io, project_root, "pnpm-lock.yaml")) return .{ .name = "pnpm", .source = .pnpm };
    if (try support.hasFile(allocator, io, project_root, "yarn.lock")) return .{ .name = "yarn", .source = .yarn };
    if (try support.hasAnyFile(allocator, io, project_root, &.{ "bun.lock", "bun.lockb" })) return .{ .name = "bun", .source = .bun };
    return .{ .name = "npm", .source = .npm };
}

fn matchesPackageManager(value: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, value, name)) return true;
    return value.len > name.len and
        std.mem.startsWith(u8, value, name) and
        value[name.len] == '@';
}

fn detectPackageJsonWorkspaceTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
    package_json: std.json.Value,
    manager: PackageManager,
) !void {
    if (package_json != .object) return;
    const workspaces = package_json.object.get("workspaces") orelse return;

    if (workspaces == .array) {
        for (workspaces.array.items) |pattern_value| {
            if (pattern_value != .string) continue;
            try detectWorkspacePattern(allocator, io, project_root, tasks, pattern_value.string, manager);
        }
        return;
    }

    if (workspaces == .object) {
        const packages = workspaces.object.get("packages") orelse return;
        if (packages != .array) return;
        for (packages.array.items) |pattern_value| {
            if (pattern_value != .string) continue;
            try detectWorkspacePattern(allocator, io, project_root, tasks, pattern_value.string, manager);
        }
    }
}

fn detectPnpmWorkspaceTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
    manager: PackageManager,
) !void {
    const contents = try support.readProjectFile(allocator, io, project_root, "pnpm-workspace.yaml") orelse return;
    defer allocator.free(contents);

    var patterns: std.ArrayList([]const u8) = .empty;
    defer {
        for (patterns.items) |pattern| allocator.free(pattern);
        patterns.deinit(allocator);
    }

    try collectPnpmWorkspacePatterns(allocator, contents, &patterns);
    for (patterns.items) |pattern| {
        try detectWorkspacePattern(allocator, io, project_root, tasks, pattern, manager);
    }
}

fn collectPnpmWorkspacePatterns(
    allocator: std.mem.Allocator,
    contents: []const u8,
    patterns: *std.ArrayList([]const u8),
) !void {
    var in_packages = false;
    var packages_indent: usize = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trimRight(raw_line, "\r \t");
        const without_comment = stripYamlComment(line);
        const trimmed = std.mem.trim(u8, without_comment, " \t");
        if (trimmed.len == 0) continue;

        if (!in_packages) {
            if (std.mem.eql(u8, trimmed, "packages:")) {
                in_packages = true;
                packages_indent = countIndent(without_comment);
            }
            continue;
        }

        const indent = countIndent(without_comment);
        if (indent <= packages_indent and !std.mem.startsWith(u8, trimmed, "-")) {
            break;
        }
        if (!std.mem.startsWith(u8, trimmed, "-")) continue;

        const raw_value = std.mem.trim(u8, trimmed[1..], " \t");
        const value = trimYamlScalar(raw_value);
        if (value.len == 0 or value[0] == '!') continue;
        try appendUniquePattern(allocator, patterns, value);
    }
}

fn appendUniquePattern(
    allocator: std.mem.Allocator,
    patterns: *std.ArrayList([]const u8),
    candidate: []const u8,
) !void {
    for (patterns.items) |existing| {
        if (std.mem.eql(u8, existing, candidate)) return;
    }
    try patterns.append(allocator, try allocator.dupe(u8, candidate));
}

fn stripYamlComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    for (line, 0..) |byte, index| {
        if (quote) |active| {
            if (byte == active) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '#') return trimRight(line[0..index], " \t");
    }
    return line;
}

fn trimRight(value: []const u8, values_to_strip: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and std.mem.indexOfScalar(u8, values_to_strip, value[end - 1]) != null) {
        end -= 1;
    }
    return value[0..end];
}

fn trimYamlScalar(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

fn countIndent(line: []const u8) usize {
    var count: usize = 0;
    for (line) |byte| {
        if (byte == ' ') count += 1 else if (byte == '\t') count += 4 else break;
    }
    return count;
}

fn detectWorkspacePattern(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
    pattern: []const u8,
    manager: PackageManager,
) !void {
    const normalized = std.mem.trim(u8, pattern, " \t\r\n");
    if (normalized.len == 0) return;

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    var iterator = std.mem.splitAny(u8, normalized, "/\\");
    while (iterator.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        try segments.append(allocator, segment);
    }
    if (segments.items.len == 0) return;

    try detectWorkspaceSegments(allocator, io, project_root, tasks, segments.items, 0, manager);
}

fn detectWorkspaceSegments(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_dir: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
    segments: []const []const u8,
    index: usize,
    manager: PackageManager,
) anyerror!void {
    if (index >= segments.len) {
        try detectWorkspacePackage(allocator, io, current_dir, tasks, manager);
        return;
    }

    const segment = segments[index];
    if (std.mem.eql(u8, segment, "**")) {
        try detectWorkspaceSegments(allocator, io, current_dir, tasks, segments, index + 1, manager);
        try visitChildDirs(allocator, io, current_dir, tasks, segments, "*", index, manager, matchAnySegment);
        return;
    }

    if (std.mem.indexOfScalar(u8, segment, '*') != null) {
        try visitChildDirs(allocator, io, current_dir, tasks, segments, segment, index + 1, manager, struct {
            fn matches(pattern: []const u8, name: []const u8) bool {
                return matchesGlobSegment(pattern, name);
            }
        }.matches);
        return;
    }

    const next_dir = try std.fs.path.join(allocator, &.{ current_dir, segment });
    defer allocator.free(next_dir);
    try detectWorkspaceSegments(allocator, io, next_dir, tasks, segments, index + 1, manager);
}

fn visitChildDirs(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_dir: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
    segments: []const []const u8,
    pattern: []const u8,
    next_index: usize,
    manager: PackageManager,
    matches: *const fn ([]const u8, []const u8) bool,
) anyerror!void {
    var dir = std.Io.Dir.cwd().openDir(io, current_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (skipWorkspaceDir(entry.name)) continue;
        if (!matches(pattern, entry.name)) continue;

        const child_dir = try std.fs.path.join(allocator, &.{ current_dir, entry.name });
        defer allocator.free(child_dir);
        try detectWorkspaceSegments(allocator, io, child_dir, tasks, segments, next_index, manager);
    }
}

fn matchAnySegment(_: []const u8, _: []const u8) bool {
    return true;
}

fn skipWorkspaceDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".pnpm") or
        std.mem.eql(u8, name, ".cache");
}

fn matchesGlobSegment(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) return std.mem.eql(u8, pattern, name);

    var remaining = name;
    var parts = std.mem.splitScalar(u8, pattern, '*');
    var first = true;
    var saw_part = false;
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        saw_part = true;
        if (first and !std.mem.startsWith(u8, pattern, "*")) {
            if (!std.mem.startsWith(u8, remaining, part)) return false;
            remaining = remaining[part.len..];
        } else {
            const found = std.mem.indexOf(u8, remaining, part) orelse return false;
            remaining = remaining[found + part.len ..];
        }
        first = false;
    }

    if (!saw_part) return true;
    if (!std.mem.endsWith(u8, pattern, "*")) {
        const last_star = std.mem.lastIndexOfScalar(u8, pattern, '*') orelse 0;
        const suffix = pattern[last_star + 1 ..];
        return std.mem.endsWith(u8, name, suffix);
    }
    return true;
}

fn detectWorkspacePackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_dir: []const u8,
    tasks: *std.ArrayList(task.TaskSpec),
    manager: PackageManager,
) !void {
    const path = try std.fs.path.join(allocator, &.{ package_dir, "package.json" });
    defer allocator.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;
    const scripts = root.object.get("scripts") orelse return;
    if (scripts != .object) return;

    const raw_name = if (root.object.get("name")) |name_value|
        if (name_value == .string) name_value.string else std.fs.path.basename(package_dir)
    else
        std.fs.path.basename(package_dir);
    const workspace_name = try sanitizeWorkspaceName(allocator, raw_name);
    defer allocator.free(workspace_name);
    const id_prefix = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ manager.name, workspace_name });
    defer allocator.free(id_prefix);

    try appendPackageScripts(allocator, tasks, scripts, package_dir, id_prefix, raw_name, manager);
}

fn sanitizeWorkspaceName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var previous_dash = false;
    for (name) |byte| {
        const mapped = switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9' => byte,
            else => '-',
        };
        if (mapped == '-' and (output.written().len == 0 or previous_dash)) continue;
        try output.writer.writeByte(std.ascii.toLower(mapped));
        previous_dash = mapped == '-';
    }

    if (output.written().len == 0) try output.writer.writeAll("workspace");
    return output.toOwnedSlice();
}

test "collect pnpm workspace patterns from yaml" {
    var patterns: std.ArrayList([]const u8) = .empty;
    defer {
        for (patterns.items) |pattern| std.testing.allocator.free(pattern);
        patterns.deinit(std.testing.allocator);
    }

    try collectPnpmWorkspacePatterns(std.testing.allocator,
        \\packages:
        \\  - "apps/*"
        \\  - packages/**
        \\  - '!packages/private'
        \\catalog:
        \\  react: 19.0.0
        \\
    , &patterns);

    try std.testing.expectEqual(@as(usize, 2), patterns.items.len);
    try std.testing.expectEqualStrings("apps/*", patterns.items[0]);
    try std.testing.expectEqualStrings("packages/**", patterns.items[1]);
}

test "glob segment matcher supports wildcards" {
    try std.testing.expect(matchesGlobSegment("*", "web"));
    try std.testing.expect(matchesGlobSegment("app-*", "app-web"));
    try std.testing.expect(matchesGlobSegment("*-api", "dockpit-api"));
    try std.testing.expect(matchesGlobSegment("pkg-*-web", "pkg-admin-web"));
    try std.testing.expect(!matchesGlobSegment("pkg-*-web", "pkg-admin-api"));
}
