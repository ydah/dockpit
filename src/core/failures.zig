const std = @import("std");

pub const FailureKind = enum {
    zig,
    rust,
    go,
    javascript,
    generic,

    pub fn label(kind: FailureKind) []const u8 {
        return switch (kind) {
            .zig => "zig",
            .rust => "rust",
            .go => "go",
            .javascript => "js",
            .generic => "failure",
        };
    }
};

pub const Failure = struct {
    kind: FailureKind,
    message: []const u8,
};

pub fn parse(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    limit: usize,
) ![]Failure {
    if (limit == 0) return allocator.alloc(Failure, 0);

    var failures: std.ArrayList(Failure) = .empty;
    errdefer {
        for (failures.items) |item| freeFailure(allocator, item);
        failures.deinit(allocator);
    }

    try parseStream(allocator, stdout, limit, &failures);
    try parseStream(allocator, stderr, limit, &failures);

    return failures.toOwnedSlice(allocator);
}

pub fn freeFailures(allocator: std.mem.Allocator, items: []Failure) void {
    for (items) |item| freeFailure(allocator, item);
    allocator.free(items);
}

fn parseStream(
    allocator: std.mem.Allocator,
    contents: []const u8,
    limit: usize,
    failures: *std.ArrayList(Failure),
) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        if (failures.items.len >= limit) return;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const kind = classify(line) orelse continue;
        try appendUnique(allocator, failures, kind, line);
    }
}

fn classify(line: []const u8) ?FailureKind {
    if (looksLikeZigError(line)) return .zig;
    if (std.mem.startsWith(u8, line, "error[") or
        std.mem.startsWith(u8, line, "error: ") or
        (std.mem.indexOf(u8, line, " panicked at ") != null and std.mem.startsWith(u8, line, "thread '")))
    {
        return .rust;
    }
    if (std.mem.startsWith(u8, line, "FAIL ") and looksLikeJavascriptFail(line)) return .javascript;
    if (std.mem.startsWith(u8, line, "--- FAIL:") or
        std.mem.startsWith(u8, line, "FAIL\t") or
        (std.mem.startsWith(u8, line, "FAIL ") and !looksLikeJavascriptFail(line)))
    {
        return .go;
    }
    if (std.mem.startsWith(u8, line, "FAIL ") or
        std.mem.startsWith(u8, line, "FAIL  ") or
        std.mem.startsWith(u8, line, "Test failed") or
        std.mem.indexOf(u8, line, "AssertionError") != null)
    {
        return .javascript;
    }
    if (std.mem.indexOf(u8, line, "failed") != null and std.mem.indexOf(u8, line, "test") != null) {
        return .generic;
    }
    return null;
}

fn looksLikeJavascriptFail(line: []const u8) bool {
    return std.mem.indexOf(u8, line, ".js") != null or
        std.mem.indexOf(u8, line, ".jsx") != null or
        std.mem.indexOf(u8, line, ".ts") != null or
        std.mem.indexOf(u8, line, ".tsx") != null;
}

fn looksLikeZigError(line: []const u8) bool {
    const marker = std.mem.indexOf(u8, line, ": error:") orelse return false;
    const prefix = line[0..marker];
    var fields = std.mem.splitScalar(u8, prefix, ':');
    const path = fields.next() orelse return false;
    const line_no = fields.next() orelse return false;
    const col_no = fields.next() orelse return false;
    if (path.len == 0 or line_no.len == 0 or col_no.len == 0) return false;
    return allDigits(line_no) and allDigits(col_no);
}

fn allDigits(value: []const u8) bool {
    for (value) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

fn appendUnique(
    allocator: std.mem.Allocator,
    failures: *std.ArrayList(Failure),
    kind: FailureKind,
    message: []const u8,
) !void {
    for (failures.items) |existing| {
        if (std.mem.eql(u8, existing.message, message)) return;
    }

    const clipped = message[0..@min(message.len, 300)];
    try failures.append(allocator, .{
        .kind = kind,
        .message = try allocator.dupe(u8, clipped),
    });
}

fn freeFailure(allocator: std.mem.Allocator, failure: Failure) void {
    allocator.free(failure.message);
}

test "parse zig compiler errors" {
    const failures = try parse(
        std.testing.allocator,
        "",
        "src/main.zig:10:5: error: expected type 'u8'\n",
        8,
    );
    defer freeFailures(std.testing.allocator, failures);

    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(FailureKind.zig, failures[0].kind);
    try std.testing.expectEqualStrings("src/main.zig:10:5: error: expected type 'u8'", failures[0].message);
}

test "parse common test failure lines" {
    const failures = try parse(
        std.testing.allocator,
        \\--- FAIL: TestThing (0.00s)
        \\FAIL src/example.test.ts
        \\thread 'main' panicked at src/main.rs:3:1
        \\
    ,
        "",
        8,
    );
    defer freeFailures(std.testing.allocator, failures);

    try std.testing.expectEqual(@as(usize, 3), failures.len);
    try std.testing.expectEqual(FailureKind.go, failures[0].kind);
    try std.testing.expectEqual(FailureKind.javascript, failures[1].kind);
    try std.testing.expectEqual(FailureKind.rust, failures[2].kind);
}

test "parse respects limit and skips duplicates" {
    const failures = try parse(
        std.testing.allocator,
        \\src/a.zig:1:1: error: nope
        \\src/a.zig:1:1: error: nope
        \\src/b.zig:2:2: error: nope
        \\
    ,
        "",
        1,
    );
    defer freeFailures(std.testing.allocator, failures);

    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqualStrings("src/a.zig:1:1: error: nope", failures[0].message);
}
