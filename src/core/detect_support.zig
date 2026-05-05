const std = @import("std");

const task = @import("task.zig");

pub fn appendUniqueTask(
    allocator: std.mem.Allocator,
    tasks: *std.ArrayList(task.TaskSpec),
    candidate: task.TaskSpec,
) !void {
    for (tasks.items) |existing| {
        if (std.mem.eql(u8, existing.id, candidate.id) or existing.commandEquals(candidate)) {
            candidate.deinit(allocator);
            return;
        }
    }

    try tasks.append(allocator, candidate);
}

pub fn makeTask(
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

pub fn hasFile(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ project_root, name });
    defer allocator.free(path);

    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn hasAnyFile(
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

pub fn readProjectFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    name: []const u8,
) !?[]u8 {
    const path = try std.fs.path.join(allocator, &.{ project_root, name });
    defer allocator.free(path);

    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => |e| return e,
    };
}

pub fn readFirstProjectFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    names: []const []const u8,
) !?[]u8 {
    for (names) |name| {
        if (try readProjectFile(allocator, io, project_root, name)) |bytes| return bytes;
    }

    return null;
}

pub fn prefixedId(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    try output.writer.writeAll(prefix);
    try output.writer.writeByte('-');
    try appendIdentifier(&output.writer, name);
    return output.toOwnedSlice();
}

pub fn prefixedLabel(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, name });
}

fn appendIdentifier(writer: *std.Io.Writer, value: []const u8) !void {
    var wrote = false;
    var previous_dash = false;
    for (value) |byte| {
        const mapped = switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9' => byte,
            else => '-',
        };
        if (mapped == '-' and (!wrote or previous_dash)) continue;
        try writer.writeByte(std.ascii.toLower(mapped));
        wrote = true;
        previous_dash = mapped == '-';
    }
    if (!wrote) try writer.writeAll("task");
}

test "prefixed id sanitizes names" {
    const id = try prefixedId(std.testing.allocator, "pnpm", "@scope/web:dev");
    defer std.testing.allocator.free(id);

    try std.testing.expectEqualStrings("pnpm-scope-web-dev", id);
}
