const std = @import("std");

pub const LogKind = enum {
    stdout,
    stderr,
    system,
};

pub const LogLine = struct {
    kind: LogKind,
    text: []const u8,
    timestamp_ms: u64,
};

pub const LogBuffer = struct {
    allocator: std.mem.Allocator,
    max_lines: usize,
    lines: std.ArrayList(LogLine) = .empty,

    pub fn init(allocator: std.mem.Allocator, max_lines: usize) LogBuffer {
        return .{
            .allocator = allocator,
            .max_lines = max_lines,
        };
    }

    pub fn deinit(self: *LogBuffer) void {
        self.clear();
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *LogBuffer, kind: LogKind, text: []const u8, timestamp_ms: u64) !void {
        if (self.max_lines == 0) return;

        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);

        try self.lines.append(self.allocator, .{
            .kind = kind,
            .text = owned_text,
            .timestamp_ms = timestamp_ms,
        });

        while (self.lines.items.len > self.max_lines) {
            const removed = self.lines.orderedRemove(0);
            self.allocator.free(removed.text);
        }
    }

    pub fn clear(self: *LogBuffer) void {
        for (self.lines.items) |line| {
            self.allocator.free(line.text);
        }
        self.lines.clearRetainingCapacity();
    }

    pub fn items(self: *const LogBuffer) []const LogLine {
        return self.lines.items;
    }
};

test "log buffer push stores lines" {
    var buffer = LogBuffer.init(std.testing.allocator, 10);
    defer buffer.deinit();

    try buffer.push(.stdout, "hello", 12);

    try std.testing.expectEqual(@as(usize, 1), buffer.items().len);
    try std.testing.expectEqual(LogKind.stdout, buffer.items()[0].kind);
    try std.testing.expectEqualStrings("hello", buffer.items()[0].text);
    try std.testing.expectEqual(@as(u64, 12), buffer.items()[0].timestamp_ms);
}

test "log buffer clear removes lines" {
    var buffer = LogBuffer.init(std.testing.allocator, 10);
    defer buffer.deinit();

    try buffer.push(.stderr, "first", 1);
    try buffer.push(.system, "second", 2);
    buffer.clear();

    try std.testing.expectEqual(@as(usize, 0), buffer.items().len);
}

test "log buffer drops oldest lines when full" {
    var buffer = LogBuffer.init(std.testing.allocator, 2);
    defer buffer.deinit();

    try buffer.push(.stdout, "one", 1);
    try buffer.push(.stdout, "two", 2);
    try buffer.push(.stdout, "three", 3);

    try std.testing.expectEqual(@as(usize, 2), buffer.items().len);
    try std.testing.expectEqualStrings("two", buffer.items()[0].text);
    try std.testing.expectEqualStrings("three", buffer.items()[1].text);
}

test "zero capacity log buffer ignores pushes" {
    var buffer = LogBuffer.init(std.testing.allocator, 0);
    defer buffer.deinit();

    try buffer.push(.stdout, "ignored", 1);

    try std.testing.expectEqual(@as(usize, 0), buffer.items().len);
}
