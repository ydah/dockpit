const std = @import("std");

const markers = [_][]const u8{
    ".git",
    ".dockpit.json",
    "build.zig",
    "Makefile",
    "makefile",
    "justfile",
    "Justfile",
    "package.json",
    "Cargo.toml",
    "go.mod",
};

pub fn discoverRoot(allocator: std.mem.Allocator, io: std.Io, start_dir: []const u8) ![]u8 {
    const start_real = try std.Io.Dir.cwd().realPathFileAlloc(io, start_dir, allocator);
    defer allocator.free(start_real);

    const start_abs = try allocator.dupe(u8, start_real);
    errdefer allocator.free(start_abs);

    var current = try allocator.dupe(u8, start_abs);
    errdefer allocator.free(current);

    while (true) {
        if (try hasProjectMarker(allocator, io, current)) {
            allocator.free(start_abs);
            errdefer allocator.free(current);
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const parent_copy = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = parent_copy;
    }

    allocator.free(current);
    return start_abs;
}

fn hasProjectMarker(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !bool {
    for (markers) |marker| {
        const marker_path = try std.fs.path.join(allocator, &.{ dir_path, marker });
        defer allocator.free(marker_path);

        if (pathExists(io, marker_path)) return true;
    }

    return false;
}

fn pathExists(io: std.Io, absolute_path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, absolute_path, .{}) catch return false;
    return true;
}

test "discover root from project marker" {
    const allocator = std.testing.allocator;
    const root = try discoverRoot(
        allocator,
        std.testing.io,
        "tests/fixtures/root_discovery/zig_project/src/nested",
    );
    defer allocator.free(root);

    const expected = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests/fixtures/root_discovery/zig_project",
        allocator,
    );
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, root);
}

test "discover root falls back to starting directory" {
    const allocator = std.testing.allocator;

    var random_bytes: [12]u8 = undefined;
    std.testing.io.random(&random_bytes);

    var suffix: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&suffix, &random_bytes);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&path_buffer, "/private/tmp/dockpit-no-marker-{s}", .{suffix});

    try std.Io.Dir.createDirAbsolute(std.testing.io, expected, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, expected) catch {};

    const root = try discoverRoot(allocator, std.testing.io, expected);
    defer allocator.free(root);

    try std.testing.expectEqualStrings(expected, root);
}
