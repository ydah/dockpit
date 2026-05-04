const std = @import("std");

pub const GitSummary = struct {
    in_repo: bool = false,
    branch: []const u8 = "none",
    modified: usize = 0,
    added: usize = 0,
    deleted: usize = 0,
    untracked: usize = 0,
    worktrees: usize = 0,

    pub fn none() GitSummary {
        return .{};
    }
};

pub const Worktree = struct {
    path: []const u8,
    head: []const u8 = "",
    branch: []const u8 = "",
    detached: bool = false,
};

pub const WorktreeList = struct {
    allocator: std.mem.Allocator,
    items: []Worktree,

    pub fn deinit(self: *WorktreeList) void {
        for (self.items) |item| {
            self.allocator.free(item.path);
            self.allocator.free(item.head);
            self.allocator.free(item.branch);
        }
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn loadSummary(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) GitSummary {
    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return .none();
    if (!isSuccess(branch_result.term)) return .none();

    const status_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024),
    }) catch return .none();
    if (!isSuccess(status_result.term)) return .none();

    var summary = parsePorcelain(status_result.stdout);
    summary.in_repo = true;
    summary.branch = allocator.dupe(u8, std.mem.trim(u8, branch_result.stdout, " \t\r\n")) catch "unknown";
    var worktrees = loadWorktrees(allocator, io, project_root);
    defer worktrees.deinit();
    summary.worktrees = worktrees.items.len;
    return summary;
}

pub fn loadWorktrees(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) WorktreeList {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "worktree", "list", "--porcelain" },
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024),
    }) catch return emptyWorktrees(allocator);
    if (!isSuccess(result.term)) return emptyWorktrees(allocator);

    const items = parseWorktreePorcelain(allocator, result.stdout) catch return emptyWorktrees(allocator);
    return .{ .allocator = allocator, .items = items };
}

pub fn parseWorktreePorcelain(allocator: std.mem.Allocator, contents: []const u8) ![]Worktree {
    var items: std.ArrayList(Worktree) = .empty;
    errdefer {
        for (items.items) |item| freeWorktree(allocator, item);
        items.deinit(allocator);
    }

    var current: ?Worktree = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) {
            if (current) |item| {
                try items.append(allocator, item);
                current = null;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (current) |item| try items.append(allocator, item);
            current = .{
                .path = try allocator.dupe(u8, line["worktree ".len..]),
                .head = try allocator.dupe(u8, ""),
                .branch = try allocator.dupe(u8, ""),
            };
        } else if (std.mem.startsWith(u8, line, "HEAD ")) {
            if (current) |*item| {
                allocator.free(item.head);
                item.head = try allocator.dupe(u8, line["HEAD ".len..]);
            }
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            if (current) |*item| {
                allocator.free(item.branch);
                item.branch = try allocator.dupe(u8, trimRef(line["branch ".len..]));
            }
        } else if (std.mem.eql(u8, line, "detached")) {
            if (current) |*item| item.detached = true;
        }
    }

    if (current) |item| try items.append(allocator, item);
    return items.toOwnedSlice(allocator);
}

pub fn parsePorcelain(contents: []const u8) GitSummary {
    var summary = GitSummary{ .in_repo = true };

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len < 2) continue;

        const index_status = line[0];
        const worktree_status = line[1];

        if (index_status == '?' and worktree_status == '?') {
            summary.untracked += 1;
            continue;
        }

        if (index_status == 'A' or worktree_status == 'A') summary.added += 1;
        if (index_status == 'D' or worktree_status == 'D') summary.deleted += 1;
        if (isModifiedStatus(index_status) or isModifiedStatus(worktree_status)) summary.modified += 1;
    }

    return summary;
}

fn isModifiedStatus(status: u8) bool {
    return switch (status) {
        'M', 'R', 'C', 'U' => true,
        else => false,
    };
}

fn isSuccess(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn emptyWorktrees(allocator: std.mem.Allocator) WorktreeList {
    return .{ .allocator = allocator, .items = &.{} };
}

fn trimRef(value: []const u8) []const u8 {
    if (std.mem.startsWith(u8, value, "refs/heads/")) return value["refs/heads/".len..];
    return value;
}

fn freeWorktree(allocator: std.mem.Allocator, item: Worktree) void {
    allocator.free(item.path);
    allocator.free(item.head);
    allocator.free(item.branch);
}

test "parse porcelain counts statuses" {
    const summary = parsePorcelain(
        \\ M src/main.zig
        \\A  README.md
        \\ D old.txt
        \\?? new.txt
        \\R  moved.txt
        \\
    );

    try std.testing.expect(summary.in_repo);
    try std.testing.expectEqual(@as(usize, 2), summary.modified);
    try std.testing.expectEqual(@as(usize, 1), summary.added);
    try std.testing.expectEqual(@as(usize, 1), summary.deleted);
    try std.testing.expectEqual(@as(usize, 1), summary.untracked);
}

test "parse porcelain ignores empty lines" {
    const summary = parsePorcelain("\n\n");

    try std.testing.expectEqual(@as(usize, 0), summary.modified);
    try std.testing.expectEqual(@as(usize, 0), summary.untracked);
}

test "parse worktree porcelain output" {
    const items = try parseWorktreePorcelain(std.testing.allocator,
        \\worktree /repo
        \\HEAD abc123
        \\branch refs/heads/main
        \\
        \\worktree /repo-feature
        \\HEAD def456
        \\detached
        \\
    );
    defer {
        for (items) |item| freeWorktree(std.testing.allocator, item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("/repo", items[0].path);
    try std.testing.expectEqualStrings("main", items[0].branch);
    try std.testing.expect(!items[0].detached);
    try std.testing.expect(items[1].detached);
}
