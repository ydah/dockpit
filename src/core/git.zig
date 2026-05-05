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

pub const ChangeState = enum {
    untracked,
    modified,
    added,
    deleted,
    renamed,
    copied,
    type_changed,
    unmerged,
    unknown,

    pub fn label(state: ChangeState) []const u8 {
        return switch (state) {
            .untracked => "untracked",
            .modified => "modified",
            .added => "added",
            .deleted => "deleted",
            .renamed => "renamed",
            .copied => "copied",
            .type_changed => "type",
            .unmerged => "unmerged",
            .unknown => "unknown",
        };
    }
};

pub const ChangedFile = struct {
    index_status: u8,
    worktree_status: u8,
    path: []const u8,
    old_path: []const u8 = "",
    staged: bool = false,
    state: ChangeState = .unknown,
};

pub const ChangedFileList = struct {
    allocator: std.mem.Allocator,
    items: []ChangedFile,

    pub fn deinit(self: *ChangedFileList) void {
        for (self.items) |item| freeChangedFile(self.allocator, item);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn emptyChangedFiles(allocator: std.mem.Allocator) ChangedFileList {
    return .{ .allocator = allocator, .items = &.{} };
}

pub fn loadSummary(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) GitSummary {
    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return .none();
    defer allocator.free(branch_result.stdout);
    defer allocator.free(branch_result.stderr);
    if (!isSuccess(branch_result.term)) return .none();

    const status_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024),
    }) catch return .none();
    defer allocator.free(status_result.stdout);
    defer allocator.free(status_result.stderr);
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
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isSuccess(result.term)) return emptyWorktrees(allocator);

    const items = parseWorktreePorcelain(allocator, result.stdout) catch return emptyWorktrees(allocator);
    return .{ .allocator = allocator, .items = items };
}

pub fn loadChangedFiles(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) ChangedFileList {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024),
    }) catch return emptyChangedFiles(allocator);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isSuccess(result.term)) return emptyChangedFiles(allocator);

    const items = parseChangedFiles(allocator, result.stdout) catch return emptyChangedFiles(allocator);
    return .{ .allocator = allocator, .items = items };
}

pub fn stagePath(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, path: []const u8) !void {
    try validateRelativePath(path);
    try runGitNoOutput(allocator, io, project_root, &.{ "git", "add", "--", path });
}

pub fn unstagePath(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, path: []const u8) !void {
    try validateRelativePath(path);
    try runGitNoOutput(allocator, io, project_root, &.{ "git", "restore", "--staged", "--", path });
}

pub fn discardChangedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    item: ChangedFile,
) !void {
    try validateRelativePath(item.path);

    if (item.state == .untracked) {
        try deleteWorktreeFile(allocator, io, project_root, item.path);
        return;
    }

    if (item.state == .added and item.index_status == 'A') {
        try runGitNoOutput(allocator, io, project_root, &.{ "git", "restore", "--staged", "--", item.path });
        deleteWorktreeFile(allocator, io, project_root, item.path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        };
        return;
    }

    try runGitNoOutput(allocator, io, project_root, &.{ "git", "restore", "--staged", "--worktree", "--", item.path });
}

pub fn diffPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    path: []const u8,
    staged: bool,
) ![]u8 {
    try validateRelativePath(path);
    const staged_argv: []const []const u8 = &.{ "git", "diff", "--cached", "--", path };
    const unstaged_argv: []const []const u8 = &.{ "git", "diff", "--", path };
    const argv = if (staged) staged_argv else unstaged_argv;

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stderr);

    if (!isSuccess(result.term)) {
        defer allocator.free(result.stdout);
        return allocator.dupe(u8, result.stderr);
    }
    return result.stdout;
}

pub fn diffChangedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    item: ChangedFile,
) ![]u8 {
    if (item.state == .untracked) return untrackedDiff(allocator, io, project_root, item.path);
    return diffPath(allocator, io, project_root, item.path, item.staged);
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

pub fn parseChangedFiles(allocator: std.mem.Allocator, contents: []const u8) ![]ChangedFile {
    var items: std.ArrayList(ChangedFile) = .empty;
    errdefer {
        for (items.items) |item| freeChangedFile(allocator, item);
        items.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len < 3) continue;

        const index_status = line[0];
        const worktree_status = line[1];
        const raw_path = std.mem.trim(u8, line[3..], " \t");
        if (raw_path.len == 0) continue;

        var old_path: []const u8 = "";
        var path = raw_path;
        if (std.mem.indexOf(u8, raw_path, " -> ")) |arrow| {
            old_path = raw_path[0..arrow];
            path = raw_path[arrow + " -> ".len ..];
        }

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_old_path = try allocator.dupe(u8, old_path);
        errdefer allocator.free(owned_old_path);

        try items.append(allocator, .{
            .index_status = index_status,
            .worktree_status = worktree_status,
            .path = owned_path,
            .old_path = owned_old_path,
            .staged = isStagedStatus(index_status),
            .state = changeState(index_status, worktree_status),
        });
    }

    return items.toOwnedSlice(allocator);
}

fn isModifiedStatus(status: u8) bool {
    return switch (status) {
        'M', 'R', 'C', 'U' => true,
        else => false,
    };
}

fn isStagedStatus(status: u8) bool {
    return status != ' ' and status != '?';
}

fn changeState(index_status: u8, worktree_status: u8) ChangeState {
    if (index_status == '?' and worktree_status == '?') return .untracked;
    if (index_status == 'U' or worktree_status == 'U') return .unmerged;
    if (index_status == 'R' or worktree_status == 'R') return .renamed;
    if (index_status == 'C' or worktree_status == 'C') return .copied;
    if (index_status == 'T' or worktree_status == 'T') return .type_changed;
    if (index_status == 'A' or worktree_status == 'A') return .added;
    if (index_status == 'D' or worktree_status == 'D') return .deleted;
    if (index_status == 'M' or worktree_status == 'M') return .modified;
    return .unknown;
}

fn runGitNoOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isSuccess(result.term)) return error.GitCommandFailed;
}

fn untrackedDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    path: []const u8,
) ![]u8 {
    try validateRelativePath(path);
    const absolute_path = try std.fs.path.join(allocator, &.{ project_root, path });
    defer allocator.free(absolute_path);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, absolute_path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(contents);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("--- /dev/null\n+++ b/{s}\n@@\n", .{path});
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        try out.writer.writeByte('+');
        try out.writer.writeAll(line);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn deleteWorktreeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    path: []const u8,
) !void {
    const absolute_path = try std.fs.path.join(allocator, &.{ project_root, path });
    defer allocator.free(absolute_path);
    try std.Io.Dir.cwd().deleteFile(io, absolute_path);
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.UnsafePath;
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.UnsafePath;
    }
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

fn freeChangedFile(allocator: std.mem.Allocator, item: ChangedFile) void {
    allocator.free(item.path);
    allocator.free(item.old_path);
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

test "parse changed files from porcelain output" {
    const items = try parseChangedFiles(std.testing.allocator,
        \\ M src/main.zig
        \\A  README.md
        \\?? new.txt
        \\R  old.txt -> moved.txt
        \\
    );
    defer {
        for (items) |item| freeChangedFile(std.testing.allocator, item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("src/main.zig", items[0].path);
    try std.testing.expect(!items[0].staged);
    try std.testing.expectEqual(ChangeState.modified, items[0].state);
    try std.testing.expectEqualStrings("README.md", items[1].path);
    try std.testing.expect(items[1].staged);
    try std.testing.expectEqual(ChangeState.added, items[1].state);
    try std.testing.expectEqual(ChangeState.untracked, items[2].state);
    try std.testing.expectEqualStrings("moved.txt", items[3].path);
    try std.testing.expectEqualStrings("old.txt", items[3].old_path);
    try std.testing.expectEqual(ChangeState.renamed, items[3].state);
}

test "untracked diff renders file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fmt.allocPrint(allocator, "{s}/new.txt", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "hello\n" });

    const diff = try untrackedDiff(std.testing.allocator, std.testing.io, root, "new.txt");
    defer std.testing.allocator.free(diff);

    try std.testing.expect(std.mem.indexOf(u8, diff, "+++ b/new.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+hello") != null);
}

test "relative path validation rejects unsafe paths" {
    try validateRelativePath("src/main.zig");
    try std.testing.expectError(error.UnsafePath, validateRelativePath(""));
    try std.testing.expectError(error.UnsafePath, validateRelativePath("../secret"));
    try std.testing.expectError(error.UnsafePath, validateRelativePath("/tmp/secret"));
}

test "discard changed file restores tracked changes and deletes untracked files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try runGitForTest(allocator, std.testing.io, root, &.{ "git", "init" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/tracked.txt", .{root}), .data = "original\n" });
    try runGitForTest(allocator, std.testing.io, root, &.{ "git", "add", "tracked.txt" });
    try runGitForTest(allocator, std.testing.io, root, &.{ "git", "-c", "user.name=dockpit", "-c", "user.email=dockpit@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "init" });

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/tracked.txt", .{root}), .data = "changed\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/new.txt", .{root}), .data = "new\n" });

    var changes = loadChangedFiles(allocator, std.testing.io, root);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 2), changes.items.len);
    for (changes.items) |item| {
        try discardChangedFile(allocator, std.testing.io, root, item);
    }

    const tracked = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/tracked.txt", .{root}), allocator, .limited(1024));
    try std.testing.expectEqualStrings("original\n", tracked);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/new.txt", .{root}), .{}),
    );
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

fn runGitForTest(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isSuccess(result.term)) return error.GitCommandFailed;
}
