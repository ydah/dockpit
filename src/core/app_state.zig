const std = @import("std");

const git = @import("git.zig");
const log_buffer = @import("log_buffer.zig");
const task = @import("task.zig");

pub const Pane = enum {
    tasks,
    output,
};

pub const Action = union(enum) {
    select_previous,
    select_next,
    focus_next,
    clear_log,
    set_status: []const u8,
    set_git: git.GitSummary,
    set_last_task: []const u8,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    project_root: []const u8,
    tasks: []const task.TaskSpec,
    selected_task: usize = 0,
    focused_pane: Pane = .tasks,
    log: log_buffer.LogBuffer,
    git_summary: git.GitSummary = .{},
    last_task_id: ?[]const u8 = null,
    status_message: []const u8 = "",

    pub fn init(
        allocator: std.mem.Allocator,
        project_root: []const u8,
        tasks: []const task.TaskSpec,
        git_summary: git.GitSummary,
    ) AppState {
        return .{
            .allocator = allocator,
            .project_root = project_root,
            .tasks = tasks,
            .log = log_buffer.LogBuffer.init(allocator, 10_000),
            .git_summary = git_summary,
        };
    }

    pub fn deinit(self: *AppState) void {
        self.log.deinit();
        self.* = undefined;
    }

    pub fn dispatch(self: *AppState, action: Action) void {
        switch (action) {
            .select_previous => self.selectPrevious(),
            .select_next => self.selectNext(),
            .focus_next => self.focused_pane = if (self.focused_pane == .tasks) .output else .tasks,
            .clear_log => self.log.clear(),
            .set_status => |message| self.status_message = message,
            .set_git => |summary| self.git_summary = summary,
            .set_last_task => |task_id| self.last_task_id = task_id,
        }
    }

    pub fn selectedTask(self: AppState) ?task.TaskSpec {
        if (self.tasks.len == 0) return null;
        return self.tasks[self.selected_task];
    }

    fn selectPrevious(self: *AppState) void {
        if (self.tasks.len == 0 or self.selected_task == 0) return;
        self.selected_task -= 1;
    }

    fn selectNext(self: *AppState) void {
        if (self.tasks.len == 0) return;
        if (self.selected_task + 1 >= self.tasks.len) return;
        self.selected_task += 1;
    }
};

test "app state moves selection within bounds" {
    const tasks = [_]task.TaskSpec{
        .{ .id = "one", .label = "one", .argv = &.{"one"}, .cwd = ".", .source = .config },
        .{ .id = "two", .label = "two", .argv = &.{"two"}, .cwd = ".", .source = .config },
    };
    var state = AppState.init(std.testing.allocator, ".", &tasks, .{});
    defer state.deinit();

    state.dispatch(.select_previous);
    try std.testing.expectEqual(@as(usize, 0), state.selected_task);

    state.dispatch(.select_next);
    try std.testing.expectEqual(@as(usize, 1), state.selected_task);

    state.dispatch(.select_next);
    try std.testing.expectEqual(@as(usize, 1), state.selected_task);

    state.dispatch(.select_previous);
    try std.testing.expectEqual(@as(usize, 0), state.selected_task);
}

test "app state ignores selection movement with no tasks" {
    var state = AppState.init(std.testing.allocator, ".", &.{}, .{});
    defer state.deinit();

    state.dispatch(.select_next);
    try std.testing.expectEqual(@as(usize, 0), state.selected_task);
    try std.testing.expectEqual(@as(?task.TaskSpec, null), state.selectedTask());
}

test "app state clears log" {
    var state = AppState.init(std.testing.allocator, ".", &.{}, .{});
    defer state.deinit();

    try state.log.push(.stdout, "hello", 1);
    state.dispatch(.clear_log);

    try std.testing.expectEqual(@as(usize, 0), state.log.items().len);
}

test "app state toggles focus and updates status" {
    var state = AppState.init(std.testing.allocator, ".", &.{}, .{});
    defer state.deinit();

    state.dispatch(.focus_next);
    state.dispatch(.{ .set_status = "ready" });

    try std.testing.expectEqual(Pane.output, state.focused_pane);
    try std.testing.expectEqualStrings("ready", state.status_message);
}
