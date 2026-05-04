const std = @import("std");

pub const max_files = 2_000;

pub const FileStamp = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i96,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    files: []FileStamp,

    pub fn deinit(self: *Snapshot) void {
        for (self.files) |file| self.allocator.free(file.path);
        self.allocator.free(self.files);
        self.* = undefined;
    }

    pub fn changedSince(self: Snapshot, previous: Snapshot) bool {
        if (self.files.len != previous.files.len) return true;
        for (self.files, previous.files) |current, old| {
            if (!std.mem.eql(u8, current.path, old.path)) return true;
            if (current.size != old.size) return true;
            if (current.mtime_ns != old.mtime_ns) return true;
        }
        return false;
    }
};

pub fn capture(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
) !Snapshot {
    return captureWithIgnore(allocator, io, project_root, &.{});
}

pub fn captureWithIgnore(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    extra_ignore: []const []const u8,
) !Snapshot {
    var root = try std.Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayList(FileStamp) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file.path);
        files.deinit(allocator);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and ignoredPath(entry.path, entry.basename, extra_ignore)) {
            walker.leave(io);
            continue;
        }
        if (entry.kind != .file) continue;
        if (ignoredPath(entry.path, entry.basename, extra_ignore)) continue;
        if (files.items.len >= max_files) break;

        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        try files.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
        });
    }

    std.sort.heap(FileStamp, files.items, {}, lessThan);
    return .{
        .allocator = allocator,
        .files = try files.toOwnedSlice(allocator),
    };
}

fn ignoredPath(path: []const u8, basename: []const u8, extra_ignore: []const []const u8) bool {
    if (ignoredDir(basename)) return true;
    for (extra_ignore) |pattern| {
        if (pattern.len == 0) continue;
        if (std.mem.eql(u8, basename, pattern)) return true;
        if (std.mem.eql(u8, path, pattern)) return true;
        if (std.mem.startsWith(u8, path, pattern) and path.len > pattern.len and path[pattern.len] == std.fs.path.sep) return true;
    }
    return false;
}

fn ignoredDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, "target") or
        std.mem.eql(u8, name, ".dockpit");
}

fn lessThan(_: void, a: FileStamp, b: FileStamp) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

test "watch snapshot detects file changes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fmt.allocPrint(allocator, "{s}/file.txt", .{root});

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "one" });
    var first = try capture(std.testing.allocator, std.testing.io, root);
    defer first.deinit();

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "two!" });
    var second = try capture(std.testing.allocator, std.testing.io, root);
    defer second.deinit();

    try std.testing.expect(second.changedSince(first));
}

test "watch snapshot ignores generated directories" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.dockpit", .{root});
    const cache_file = try std.fmt.allocPrint(allocator, "{s}/history.log", .{cache_dir});

    try std.Io.Dir.cwd().createDirPath(std.testing.io, cache_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = cache_file, .data = "ignored" });

    var snap = try capture(std.testing.allocator, std.testing.io, root);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 0), snap.files.len);
}

test "watch snapshot applies configured ignore names" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const ignored_dir = try std.fmt.allocPrint(allocator, "{s}/dist", .{root});
    const ignored_file = try std.fmt.allocPrint(allocator, "{s}/dist/app.js", .{root});
    const kept_file = try std.fmt.allocPrint(allocator, "{s}/src.zig", .{root});

    try std.Io.Dir.cwd().createDirPath(std.testing.io, ignored_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ignored_file, .data = "ignored" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = kept_file, .data = "kept" });

    var snap = try captureWithIgnore(std.testing.allocator, std.testing.io, root, &.{"dist"});
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 1), snap.files.len);
    try std.testing.expectEqualStrings("src.zig", snap.files[0].path);
}
