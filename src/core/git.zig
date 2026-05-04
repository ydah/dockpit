const std = @import("std");

pub const GitSummary = struct {
    in_repo: bool = false,
    branch: []const u8 = "none",
    modified: usize = 0,
    added: usize = 0,
    deleted: usize = 0,
    untracked: usize = 0,

    pub fn none() GitSummary {
        return .{};
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
    return summary;
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
