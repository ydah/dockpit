const std = @import("std");

const fuzzy = @import("fuzzy.zig");
const git = @import("git.zig");
const log_buffer = @import("log_buffer.zig");
const task = @import("task.zig");

pub const Pane = enum {
    tasks,
    output,
};

pub const Mode = enum {
    normal,
    search,
    palette,
};

pub const Action = union(enum) {
    select_previous,
    select_next,
    focus_next,
    clear_log,
    enter_search,
    exit_mode,
    append_search_text: []const u8,
    backspace_search,
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
    mode: Mode = .normal,
    search_query: std.ArrayList(u8) = .empty,
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
        self.search_query.deinit(self.allocator);
        self.log.deinit();
        self.* = undefined;
    }

    pub fn dispatch(self: *AppState, action: Action) void {
        switch (action) {
            .select_previous => self.selectPrevious(),
            .select_next => self.selectNext(),
            .focus_next => self.focused_pane = if (self.focused_pane == .tasks) .output else .tasks,
            .clear_log => self.log.clear(),
            .enter_search => self.mode = .search,
            .exit_mode => self.mode = .normal,
            .append_search_text => |text| self.appendSearchText(text) catch {},
            .backspace_search => self.backspaceSearch(),
            .set_status => |message| self.status_message = message,
            .set_git => |summary| self.git_summary = summary,
            .set_last_task => |task_id| self.last_task_id = task_id,
        }
    }

    pub fn selectedTask(self: AppState) ?task.TaskSpec {
        if (self.tasks.len == 0) return null;
        if (!self.taskVisible(self.selected_task)) return null;
        return self.tasks[self.selected_task];
    }

    pub fn taskVisible(self: AppState, index: usize) bool {
        if (index >= self.tasks.len) return false;
        if (self.search_query.items.len == 0) return true;
        const item = self.tasks[index];
        return fuzzy.matches(self.search_query.items, item.id) or
            fuzzy.matches(self.search_query.items, item.label) or
            fuzzy.matches(self.search_query.items, item.source.label());
    }

    pub fn visibleTaskCount(self: AppState) usize {
        var count: usize = 0;
        for (0..self.tasks.len) |index| {
            if (self.taskVisible(index)) count += 1;
        }
        return count;
    }

    fn selectPrevious(self: *AppState) void {
        if (self.tasks.len == 0) return;
        var index = self.selected_task;
        while (index > 0) {
            index -= 1;
            if (self.taskVisible(index)) {
                self.selected_task = index;
                return;
            }
        }
    }

    fn selectNext(self: *AppState) void {
        if (self.tasks.len == 0) return;
        var index = self.selected_task + 1;
        while (index < self.tasks.len) : (index += 1) {
            if (self.taskVisible(index)) {
                self.selected_task = index;
                return;
            }
        }
    }

    fn appendSearchText(self: *AppState, text: []const u8) !void {
        try self.search_query.appendSlice(self.allocator, text);
        self.ensureSelectionVisible();
    }

    fn backspaceSearch(self: *AppState) void {
        if (self.search_query.items.len == 0) return;
        _ = self.search_query.pop();
        self.ensureSelectionVisible();
    }

    fn ensureSelectionVisible(self: *AppState) void {
        if (self.tasks.len == 0 or self.taskVisible(self.selected_task)) return;
        for (0..self.tasks.len) |index| {
            if (self.taskVisible(index)) {
                self.selected_task = index;
                return;
            }
        }
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

test "app state filters tasks with fuzzy search" {
    const tasks = [_]task.TaskSpec{
        .{ .id = "zig-build", .label = "zig build", .argv = &.{"one"}, .cwd = ".", .source = .zig },
        .{ .id = "go-test", .label = "go test", .argv = &.{"two"}, .cwd = ".", .source = .go },
    };
    var state = AppState.init(std.testing.allocator, ".", &tasks, .{});
    defer state.deinit();

    state.dispatch(.enter_search);
    state.dispatch(.{ .append_search_text = "gt" });

    try std.testing.expectEqual(Mode.search, state.mode);
    try std.testing.expectEqual(@as(usize, 1), state.visibleTaskCount());
    try std.testing.expectEqualStrings("go-test", state.selectedTask().?.id);
}

test "app state toggles focus and updates status" {
    var state = AppState.init(std.testing.allocator, ".", &.{}, .{});
    defer state.deinit();

    state.dispatch(.focus_next);
    state.dispatch(.{ .set_status = "ready" });

    try std.testing.expectEqual(Pane.output, state.focused_pane);
    try std.testing.expectEqualStrings("ready", state.status_message);
}
