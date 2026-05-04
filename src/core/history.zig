const std = @import("std");

const runner = @import("runner.zig");
const task = @import("task.zig");

pub const Entry = struct {
    timestamp_ms: u64,
    task_id: []const u8,
    exit_code: ?u8,
    elapsed_ms: u64,

    pub fn status(self: Entry) Status {
        if (self.exit_code) |code| return if (code == 0) .success else .failed;
        return .signal;
    }
};

pub const Status = enum {
    all,
    success,
    failed,
    signal,

    pub fn label(status: Status) []const u8 {
        return switch (status) {
            .all => "all",
            .success => "success",
            .failed => "failed",
            .signal => "signal",
        };
    }
};

pub const Filter = struct {
    task_id: ?[]const u8 = null,
    status: Status = .all,

    pub fn matches(self: Filter, entry: Entry) bool {
        if (self.task_id) |task_id| {
            if (!std.mem.eql(u8, task_id, entry.task_id)) return false;
        }
        if (self.status == .all) return true;
        return entry.status() == self.status;
    }
};

const DiskEntry = struct {
    timestamp_ms: u64,
    task_id: []const u8,
    exit_code: ?u8,
    elapsed_ms: u64,
};

pub fn appendRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    item: task.TaskSpec,
    result: runner.RunResult,
) !void {
    try appendEntry(allocator, io, project_root, .{
        .timestamp_ms = timestampMs(io),
        .task_id = item.id,
        .exit_code = result.exitCode(),
        .elapsed_ms = result.elapsed_ms,
    });
}

pub fn appendEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    entry: Entry,
) !void {
    const state_dir = try std.fs.path.join(allocator, &.{ project_root, ".dockpit" });
    defer allocator.free(state_dir);
    try std.Io.Dir.cwd().createDirPath(io, state_dir);

    const path = try historyPath(allocator, project_root);
    defer allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(DiskEntry{
        .timestamp_ms = entry.timestamp_ms,
        .task_id = entry.task_id,
        .exit_code = entry.exit_code,
        .elapsed_ms = entry.elapsed_ms,
    }, .{}, &out.writer);
    try out.writer.writeByte('\n');

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, out.written(), stat.size);
}

pub fn loadRecent(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    limit: usize,
) ![]Entry {
    return loadRecentFiltered(allocator, io, project_root, limit, .{});
}

pub fn loadRecentFiltered(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    limit: usize,
    filter: Filter,
) ![]Entry {
    if (limit == 0) return allocator.alloc(Entry, 0);

    const path = try historyPath(allocator, project_root);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return allocator.alloc(Entry, 0),
        else => |e| return e,
    };
    defer allocator.free(bytes);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |item| freeEntry(allocator, item);
        entries.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(DiskEntry, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const entry = Entry{
            .timestamp_ms = parsed.value.timestamp_ms,
            .task_id = parsed.value.task_id,
            .exit_code = parsed.value.exit_code,
            .elapsed_ms = parsed.value.elapsed_ms,
        };
        if (!filter.matches(entry)) continue;

        if (entries.items.len == limit) {
            freeEntry(allocator, entries.orderedRemove(0));
        }

        try entries.append(allocator, .{
            .timestamp_ms = entry.timestamp_ms,
            .task_id = try allocator.dupe(u8, parsed.value.task_id),
            .exit_code = entry.exit_code,
            .elapsed_ms = entry.elapsed_ms,
        });
    }

    return entries.toOwnedSlice(allocator);
}

pub fn clear(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) !void {
    const path = try historyPath(allocator, project_root);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => |e| return e,
    };
}

pub fn loadLatestTaskId(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
) !?[]const u8 {
    const entries = try loadRecent(allocator, io, project_root, 1);
    defer allocator.free(entries);
    if (entries.len == 0) return null;
    return entries[0].task_id;
}

pub fn freeEntry(allocator: std.mem.Allocator, entry: Entry) void {
    allocator.free(entry.task_id);
}

fn historyPath(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ project_root, ".dockpit", "history.log" });
}

fn timestampMs(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
}

test "history appends and loads recent entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try appendEntry(allocator, std.testing.io, root, .{
        .timestamp_ms = 1,
        .task_id = "build",
        .exit_code = 0,
        .elapsed_ms = 10,
    });
    try appendEntry(allocator, std.testing.io, root, .{
        .timestamp_ms = 2,
        .task_id = "test\nwith escape",
        .exit_code = 1,
        .elapsed_ms = 20,
    });

    const entries = try loadRecent(allocator, std.testing.io, root, 8);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u64, 1), entries[0].timestamp_ms);
    try std.testing.expectEqualStrings("build", entries[0].task_id);
    try std.testing.expectEqual(@as(?u8, 1), entries[1].exit_code);
    try std.testing.expectEqualStrings("test\nwith escape", entries[1].task_id);
}

test "history returns the latest task id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try appendEntry(allocator, std.testing.io, root, .{
        .timestamp_ms = 1,
        .task_id = "old",
        .exit_code = 0,
        .elapsed_ms = 10,
    });
    try appendEntry(allocator, std.testing.io, root, .{
        .timestamp_ms = 2,
        .task_id = "new",
        .exit_code = null,
        .elapsed_ms = 0,
    });

    const task_id = (try loadLatestTaskId(allocator, std.testing.io, root)).?;
    try std.testing.expectEqualStrings("new", task_id);
}

test "history filters by task and status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try appendEntry(allocator, std.testing.io, root, .{
        .timestamp_ms = 1,
        .task_id = "build",
        .exit_code = 0,
        .elapsed_ms = 10,
    });
    try appendEntry(allocator, std.testing.io, root, .{
        .timestamp_ms = 2,
        .task_id = "test",
        .exit_code = 1,
        .elapsed_ms = 20,
    });
    try appendEntry(allocator, std.testing.io, root, .{
        .timestamp_ms = 3,
        .task_id = "test",
        .exit_code = 0,
        .elapsed_ms = 30,
    });

    const entries = try loadRecentFiltered(allocator, std.testing.io, root, 8, .{
        .task_id = "test",
        .status = .failed,
    });

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("test", entries[0].task_id);
    try std.testing.expectEqual(@as(?u8, 1), entries[0].exit_code);
}

test "history clear removes stored entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try appendEntry(allocator, std.testing.io, root, .{
        .timestamp_ms = 1,
        .task_id = "build",
        .exit_code = 0,
        .elapsed_ms = 10,
    });

    try clear(allocator, std.testing.io, root);
    const entries = try loadRecent(allocator, std.testing.io, root, 8);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
