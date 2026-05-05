const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const app_state = @import("../core/app_state.zig");
const config = @import("../core/config.zig");
const failures = @import("../core/failures.zig");
const fuzzy = @import("../core/fuzzy.zig");
const git = @import("../core/git.zig");
const history = @import("../core/history.zig");
const log_buffer = @import("../core/log_buffer.zig");
const runner = @import("../core/runner.zig");
const task = @import("../core/task.zig");
const watch = @import("../core/watch.zig");
const layout = @import("layout.zig");
const widgets = @import("widgets.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    project_root: []const u8,
    tasks: []const task.TaskSpec,
    git_summary: git.GitSummary,
    git_enabled: bool,
    settings: config.Settings,
) !void {
    var tty_buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(io, allocator, env_map, &tty_buffer);
    defer app.deinit();

    var state = app_state.AppState.init(allocator, project_root, tasks, git_summary);
    defer state.deinit();
    if (history.loadLatestTaskId(allocator, io, project_root) catch null) |task_id| {
        state.dispatch(.{ .set_last_task = task_id });
    }

    var root = RootWidget{
        .allocator = allocator,
        .io = io,
        .env_map = env_map,
        .git_enabled = git_enabled,
        .state = &state,
        .settings = settings,
        .task_statuses = try allocator.alloc(TaskStatus, tasks.len),
        .changed_files = git.emptyChangedFiles(allocator),
    };
    defer root.deinit();
    @memset(root.task_statuses, .{});
    try root.refreshHistory();

    try app.run(root.widget(), .{});
}

const RootWidget = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    git_enabled: bool,
    state: *app_state.AppState,
    settings: config.Settings,
    task_statuses: []TaskStatus,
    history_entries: []history.Entry = &.{},
    changed_files: git.ChangedFileList,
    jobs: std.ArrayList(*RunningJob) = .empty,
    next_job_id: usize = 1,
    selected_job_index: usize = 0,
    selected_history_index: usize = 0,
    selected_change_index: usize = 0,
    history_filter: history.Status = .all,
    pending_history_clear: bool = false,
    pending_discard_path: ?[]const u8 = null,
    palette_index: usize = 0,
    palette_query: std.ArrayList(u8) = .empty,
    watch_enabled: bool = false,
    watch_snapshot: ?watch.Snapshot = null,
    last_watch_ms: u64 = 0,

    fn deinit(self: *RootWidget) void {
        if (self.watch_snapshot) |*snapshot| snapshot.deinit();
        for (self.jobs.items) |job| {
            if (!job.done.load(.acquire)) job.cancel_requested.store(true, .release);
            job.thread.join();
            job.deinit();
            self.allocator.destroy(job);
        }
        self.jobs.deinit(self.allocator);
        self.palette_query.deinit(self.allocator);
        self.freePendingDiscardPath();
        self.changed_files.deinit();
        self.freeHistoryEntries();
        self.allocator.free(self.task_statuses);
    }

    fn widget(self: *RootWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = handleEventErased,
            .drawFn = drawErased,
        };
    }

    fn handleEventErased(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn handleEvent(self: *RootWidget, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        switch (event) {
            .key_press => |key| {
                if (try self.handleJobsKey(ctx, key)) return;
                if (try self.handleHistoryKey(ctx, key)) return;
                if (try self.handleChangesKey(ctx, key)) return;
                if (self.handleHelpKey(ctx, key)) return;
                if (self.handleSearchKey(ctx, key)) return;
                if (self.handleLogSearchKey(ctx, key)) return;
                if (try self.handlePaletteKey(ctx, key)) return;
                if (matchesBinding(key, self.settings.keybindings.quit) or key.matches('c', .{ .ctrl = true })) {
                    try self.finishCompletedJobs();
                    if (self.runningJobCount() > 0) {
                        self.state.dispatch(.{ .set_status = "task running" });
                        ctx.consumeAndRedraw();
                        return;
                    }
                    ctx.quit = true;
                    ctx.consume_event = true;
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.focus)) {
                    self.state.dispatch(.focus_next);
                    self.state.dispatch(.{ .set_status = self.focusLabel() });
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.help)) {
                    self.state.dispatch(.exit_mode);
                    self.state.mode = .help;
                    self.state.dispatch(.{ .set_status = "help" });
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.jobs)) {
                    self.state.dispatch(.exit_mode);
                    self.state.mode = .jobs;
                    self.clampSelectedJob();
                    self.state.dispatch(.{ .set_status = "jobs" });
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.history)) {
                    self.state.dispatch(.exit_mode);
                    self.state.mode = .history;
                    self.clampSelectedHistory();
                    self.state.dispatch(.{ .set_status = "history" });
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                    if (self.state.focused_pane == .output) {
                        self.state.dispatch(.scroll_output_down);
                    } else {
                        self.state.dispatch(.select_next);
                    }
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                    if (self.state.focused_pane == .output) {
                        self.state.dispatch(.scroll_output_up);
                    } else {
                        self.state.dispatch(.select_previous);
                    }
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.run)) {
                    if (self.state.selectedTask()) |selected| {
                        try self.startTask(ctx, selected);
                    }
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.rerun)) {
                    if (self.lastTask()) |last| {
                        try self.startTask(ctx, last);
                    }
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.cancel)) {
                    self.requestCancel();
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.git)) {
                    self.refreshGit();
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.changes)) {
                    try self.showChanges();
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.worktrees)) {
                    try self.showWorktrees();
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.details)) {
                    try self.showSelectedTaskDetails();
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.watch)) {
                    try self.toggleWatch(ctx);
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.clear)) {
                    self.state.dispatch(.clear_log);
                    self.state.dispatch(.{ .set_status = "log cleared" });
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.search)) {
                    if (self.state.focused_pane == .output) {
                        self.state.dispatch(.enter_log_search);
                        self.state.dispatch(.{ .set_status = "output search" });
                    } else {
                        self.state.dispatch(.enter_search);
                        self.state.dispatch(.{ .set_status = "search" });
                    }
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.palette)) {
                    self.state.dispatch(.exit_mode);
                    self.state.mode = .palette;
                    self.palette_index = 0;
                    self.palette_query.clearRetainingCapacity();
                    self.state.dispatch(.{ .set_status = "palette" });
                    ctx.consumeAndRedraw();
                }
            },
            .tick => try self.handleTick(ctx),
            else => {},
        }
    }

    fn handleJobsKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
        if (self.state.mode != .jobs) return false;

        if (key.matches(vaxis.Key.escape, .{}) or
            key.matches('c', .{ .ctrl = true }) or
            matchesBinding(key, self.settings.keybindings.quit) or
            matchesBinding(key, self.settings.keybindings.jobs))
        {
            self.state.dispatch(.exit_mode);
            self.state.dispatch(.{ .set_status = "ready" });
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.selected_job_index + 1 < self.jobs.items.len) self.selected_job_index += 1;
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.selected_job_index > 0) self.selected_job_index -= 1;
            ctx.consumeAndRedraw();
            return true;
        }
        if (matchesBinding(key, self.settings.keybindings.cancel)) {
            self.requestCancelSelected();
            ctx.consumeAndRedraw();
            return true;
        }

        ctx.consumeAndRedraw();
        return true;
    }

    fn handleHistoryKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
        if (self.state.mode != .history) return false;

        if (key.matches(vaxis.Key.escape, .{}) or
            key.matches('c', .{ .ctrl = true }) or
            matchesBinding(key, self.settings.keybindings.quit) or
            matchesBinding(key, self.settings.keybindings.history))
        {
            self.state.dispatch(.exit_mode);
            self.state.dispatch(.{ .set_status = "ready" });
            self.pending_history_clear = false;
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            self.pending_history_clear = false;
            if (self.selected_history_index + 1 < self.history_entries.len) self.selected_history_index += 1;
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            self.pending_history_clear = false;
            if (self.selected_history_index > 0) self.selected_history_index -= 1;
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('a', .{})) {
            try self.setHistoryFilter(.all);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('s', .{})) {
            try self.setHistoryFilter(.success);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('e', .{})) {
            try self.setHistoryFilter(.failed);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('S', .{})) {
            try self.setHistoryFilter(.signal);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('C', .{})) {
            try self.clearHistoryWithConfirmation();
            ctx.consumeAndRedraw();
            return true;
        }
        if (matchesBinding(key, self.settings.keybindings.details)) {
            try self.showSelectedHistoryDetails();
            self.pending_history_clear = false;
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{}) or matchesBinding(key, self.settings.keybindings.rerun)) {
            self.pending_history_clear = false;
            if (self.selectedHistoryTask()) |item| {
                try self.startTask(ctx, item);
                self.state.dispatch(.exit_mode);
            } else {
                self.state.dispatch(.{ .set_status = "task missing" });
            }
            ctx.consumeAndRedraw();
            return true;
        }

        self.pending_history_clear = false;
        ctx.consumeAndRedraw();
        return true;
    }

    fn handleChangesKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
        if (self.state.mode != .changes) return false;

        if (key.matches(vaxis.Key.escape, .{}) or
            key.matches('c', .{ .ctrl = true }) or
            matchesBinding(key, self.settings.keybindings.quit) or
            matchesBinding(key, self.settings.keybindings.changes))
        {
            self.state.dispatch(.exit_mode);
            self.state.dispatch(.{ .set_status = "ready" });
            self.clearPendingDiscardPath();
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            self.clearPendingDiscardPath();
            if (self.selected_change_index + 1 < self.changed_files.items.len) self.selected_change_index += 1;
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            self.clearPendingDiscardPath();
            if (self.selected_change_index > 0) self.selected_change_index -= 1;
            ctx.consumeAndRedraw();
            return true;
        }
        if (matchesBinding(key, self.settings.keybindings.git)) {
            self.clearPendingDiscardPath();
            self.refreshGit();
            try self.refreshChanges();
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(' ', .{})) {
            self.clearPendingDiscardPath();
            self.toggleSelectedChange() catch |err| {
                self.state.dispatch(.{ .set_status = @errorName(err) });
            };
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('D', .{})) {
            self.discardSelectedChangeWithConfirmation() catch |err| {
                self.state.dispatch(.{ .set_status = @errorName(err) });
            };
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{}) or key.matches('d', .{})) {
            self.clearPendingDiscardPath();
            self.showSelectedDiff() catch |err| {
                self.state.dispatch(.{ .set_status = @errorName(err) });
            };
            ctx.consumeAndRedraw();
            return true;
        }

        self.clearPendingDiscardPath();
        ctx.consumeAndRedraw();
        return true;
    }

    fn handleSearchKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) bool {
        if (self.state.mode != .search) return false;

        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            self.state.dispatch(.exit_mode);
            self.state.dispatch(.{ .set_status = "ready" });
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            self.state.dispatch(.backspace_search);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            self.state.dispatch(.select_next);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            self.state.dispatch(.select_previous);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.state.selectedTask()) |selected| {
                self.startTask(ctx, selected) catch |err| {
                    self.state.dispatch(.{ .set_status = @errorName(err) });
                };
            }
            self.state.dispatch(.exit_mode);
            ctx.consumeAndRedraw();
            return true;
        }
        if (!key.mods.ctrl and !key.mods.alt) {
            if (key.text) |text| {
                self.state.dispatch(.{ .append_search_text = text });
                ctx.consumeAndRedraw();
                return true;
            }
        }

        return false;
    }

    fn handleLogSearchKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) bool {
        if (self.state.mode != .log_search) return false;

        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            self.state.dispatch(.exit_mode);
            self.state.dispatch(.{ .set_status = "ready" });
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            self.state.dispatch(.backspace_log_search);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            self.state.dispatch(.scroll_output_down);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            self.state.dispatch(.scroll_output_up);
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.state.dispatch(.exit_mode);
            ctx.consumeAndRedraw();
            return true;
        }
        if (!key.mods.ctrl and !key.mods.alt) {
            if (key.text) |text| {
                self.state.dispatch(.{ .append_log_search_text = text });
                ctx.consumeAndRedraw();
                return true;
            }
        }

        return false;
    }

    fn handleHelpKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) bool {
        if (self.state.mode != .help) return false;

        if (key.matches(vaxis.Key.escape, .{}) or
            key.matches('c', .{ .ctrl = true }) or
            matchesBinding(key, self.settings.keybindings.help) or
            matchesBinding(key, self.settings.keybindings.quit))
        {
            self.state.dispatch(.exit_mode);
            self.state.dispatch(.{ .set_status = "ready" });
            ctx.consumeAndRedraw();
            return true;
        }

        ctx.consumeAndRedraw();
        return true;
    }

    fn handlePaletteKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
        if (self.state.mode != .palette) return false;

        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            self.state.dispatch(.exit_mode);
            self.state.dispatch(.{ .set_status = "ready" });
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            self.selectNextPaletteCommand();
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            self.selectPreviousPaletteCommand();
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.palette_query.items.len > 0) _ = self.palette_query.pop();
            self.clampPaletteSelection();
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            const command = self.selectedPaletteCommand() orelse {
                self.state.dispatch(.{ .set_status = "no command" });
                ctx.consumeAndRedraw();
                return true;
            };
            try self.executePaletteCommand(ctx, command.id);
            if (self.state.mode == .palette) self.state.dispatch(.exit_mode);
            ctx.consumeAndRedraw();
            return true;
        }
        if (!key.mods.ctrl and !key.mods.alt) {
            if (key.text) |text| {
                try self.palette_query.appendSlice(self.allocator, text);
                self.clampPaletteSelection();
                ctx.consumeAndRedraw();
                return true;
            }
        }

        return true;
    }

    fn executePaletteCommand(self: *RootWidget, ctx: *vxfw.EventContext, id: PaletteCommandId) !void {
        switch (id) {
            .run_selected => if (self.state.selectedTask()) |selected| try self.startTask(ctx, selected),
            .rerun_last => if (self.lastTask()) |last| try self.startTask(ctx, last),
            .clear_output => {
                self.state.dispatch(.clear_log);
                self.state.dispatch(.{ .set_status = "log cleared" });
            },
            .refresh_git => self.refreshGit(),
            .show_changes => try self.showChanges(),
            .show_worktrees => try self.showWorktrees(),
            .show_task_details => try self.showSelectedTaskDetails(),
            .toggle_watch => try self.toggleWatch(ctx),
            .show_jobs => {
                self.state.dispatch(.exit_mode);
                self.state.mode = .jobs;
                self.clampSelectedJob();
                self.state.dispatch(.{ .set_status = "jobs" });
            },
            .show_history => {
                self.state.dispatch(.exit_mode);
                self.state.mode = .history;
                self.clampSelectedHistory();
                self.state.dispatch(.{ .set_status = "history" });
            },
            .search_tasks => {
                self.state.dispatch(.enter_search);
                self.state.dispatch(.{ .set_status = "search" });
            },
            .quit => {
                try self.finishCompletedJobs();
                if (self.runningJobCount() > 0) {
                    self.state.dispatch(.{ .set_status = "task running" });
                    return;
                }
                ctx.quit = true;
            },
        }
    }

    fn selectedPaletteCommand(self: *RootWidget) ?PaletteCommand {
        var visible_index: usize = 0;
        for (palette_commands) |command| {
            if (!self.paletteCommandVisible(command)) continue;
            if (visible_index == self.palette_index) return command;
            visible_index += 1;
        }
        return null;
    }

    fn paletteCommandVisible(self: *RootWidget, command: PaletteCommand) bool {
        if (self.palette_query.items.len == 0) return true;
        return fuzzy.matches(self.palette_query.items, command.label);
    }

    fn visiblePaletteCommandCount(self: *RootWidget) usize {
        var count: usize = 0;
        for (palette_commands) |command| {
            if (self.paletteCommandVisible(command)) count += 1;
        }
        return count;
    }

    fn clampPaletteSelection(self: *RootWidget) void {
        const count = self.visiblePaletteCommandCount();
        if (count == 0) {
            self.palette_index = 0;
            return;
        }
        self.palette_index = @min(self.palette_index, count - 1);
    }

    fn selectNextPaletteCommand(self: *RootWidget) void {
        const count = self.visiblePaletteCommandCount();
        if (count == 0) {
            self.palette_index = 0;
            return;
        }
        self.palette_index = (self.palette_index + 1) % count;
    }

    fn selectPreviousPaletteCommand(self: *RootWidget) void {
        const count = self.visiblePaletteCommandCount();
        if (count == 0) {
            self.palette_index = 0;
            return;
        }
        self.palette_index = if (self.palette_index == 0) count - 1 else self.palette_index - 1;
    }

    fn startTask(self: *RootWidget, ctx: *vxfw.EventContext, selected: task.TaskSpec) !void {
        try self.finishCompletedJobs();

        const task_index = self.taskIndexById(selected.id);
        self.state.dispatch(.{ .set_last_task = selected.id });
        self.state.dispatch(.{ .set_status = "running" });
        if (task_index) |index| {
            self.task_statuses[index] = .{
                .state = .running,
                .job_id = self.next_job_id,
            };
        }

        const command_line = try formatCommand(self.allocator, selected.argv);
        defer self.allocator.free(command_line);
        try self.state.log.push(.system, command_line, timestampMs(self.io));

        const job = try self.allocator.create(RunningJob);
        job.* = .{
            .id = self.next_job_id,
            .allocator = std.heap.smp_allocator,
            .io = self.io,
            .env_map = self.env_map,
            .task_spec = selected,
            .task_index = task_index,
        };
        self.next_job_id += 1;
        job.thread = try std.Thread.spawn(.{}, RunningJob.run, .{job});
        try self.jobs.append(self.allocator, job);
        try ctx.tick(100, self.widget());
    }

    fn handleTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        try self.drainJobEvents();
        try self.finishCompletedJobs();
        try self.pollWatch(ctx);
        if (self.runningJobCount() > 0) {
            try ctx.tick(100, self.widget());
        } else if (self.watch_enabled) {
            try ctx.tick(1000, self.widget());
        }
        ctx.redraw = true;
    }

    fn toggleWatch(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        if (self.watch_enabled) {
            self.watch_enabled = false;
            if (self.watch_snapshot) |*snapshot| snapshot.deinit();
            self.watch_snapshot = null;
            self.state.dispatch(.{ .set_status = "watch off" });
            return;
        }

        self.watch_snapshot = try self.captureWatchSnapshot();
        self.last_watch_ms = timestampMs(self.io);
        self.watch_enabled = true;
        self.state.dispatch(.{ .set_status = "watch on" });
        try ctx.tick(@intCast(self.settings.watch.debounce_ms), self.widget());
    }

    fn pollWatch(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        if (!self.watch_enabled) return;

        const now = timestampMs(self.io);
        if (now < self.last_watch_ms + self.settings.watch.debounce_ms) return;
        self.last_watch_ms = now;

        var current = self.captureWatchSnapshot() catch |err| {
            self.state.dispatch(.{ .set_status = @errorName(err) });
            return;
        };
        errdefer current.deinit();

        const previous = self.watch_snapshot orelse {
            self.watch_snapshot = current;
            return;
        };
        if (!current.changedSince(previous)) {
            current.deinit();
            return;
        }

        var old = self.watch_snapshot.?;
        old.deinit();
        self.watch_snapshot = current;

        if (self.runningJobCount() > 0) {
            self.state.dispatch(.{ .set_status = "watch changed" });
            return;
        }

        const item = self.lastTask() orelse self.state.selectedTask() orelse {
            self.state.dispatch(.{ .set_status = "watch changed" });
            return;
        };
        if (!item.watch) {
            self.state.dispatch(.{ .set_status = "watch disabled for task" });
            return;
        }
        self.state.dispatch(.{ .set_status = "watch rerun" });
        try self.startTask(ctx, item);
    }

    fn captureWatchSnapshot(self: *RootWidget) !watch.Snapshot {
        return watch.captureWithIgnore(self.allocator, self.io, self.state.project_root, self.settings.watch.ignore);
    }

    fn finishCompletedJobs(self: *RootWidget) !void {
        var index: usize = 0;
        while (index < self.jobs.items.len) {
            const job = self.jobs.items[index];
            try self.drainJobEvent(job, false);
            if (!job.done.load(.acquire)) {
                index += 1;
                continue;
            }
            _ = self.jobs.orderedRemove(index);
            try self.finishJob(job);
        }
        self.clampSelectedJob();
    }

    fn finishJob(self: *RootWidget, job: *RunningJob) !void {
        job.thread.join();
        defer {
            job.deinit();
            self.allocator.destroy(job);
        }
        try self.drainJobEvent(job, true);

        if (job.err_name) |err_name| {
            try self.state.log.push(.stderr, err_name, timestampMs(self.io));
            self.markTaskFinished(job, .failed, null, 0);
            self.state.dispatch(.{ .set_status = "failed to start" });
            return;
        }

        const result = job.result orelse return;
        history.appendRun(self.allocator, self.io, self.state.project_root, job.task_spec, result) catch {
            try self.state.log.push(.stderr, "failed to write history", timestampMs(self.io));
        };
        try self.appendFailureSummary(result);

        const status = if (job.cancel_requested.load(.acquire))
            "cancelled"
        else if (result.exitCode()) |code|
            try std.fmt.allocPrint(self.allocator, "exit {d}", .{code})
        else
            "signal";
        const state: TaskRunState = if (job.cancel_requested.load(.acquire))
            .cancelled
        else if (result.exitCode()) |code|
            if (code == 0) .success else .failed
        else
            .signal;
        self.markTaskFinished(job, state, result.exitCode(), result.elapsed_ms);
        self.refreshHistory() catch {
            try self.state.log.push(.stderr, "failed to reload history", timestampMs(self.io));
        };
        self.state.dispatch(.{ .set_status = status });
        self.refreshGit();
    }

    fn requestCancel(self: *RootWidget) void {
        var index = self.jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.jobs.items[index];
            if (job.done.load(.acquire)) continue;
            job.cancel_requested.store(true, .release);
            self.state.dispatch(.{ .set_status = "cancel requested" });
            return;
        }
        self.state.dispatch(.{ .set_status = "no running task" });
    }

    fn requestCancelSelected(self: *RootWidget) void {
        if (self.jobs.items.len == 0) {
            self.state.dispatch(.{ .set_status = "no running task" });
            return;
        }
        self.clampSelectedJob();
        const job = self.jobs.items[self.selected_job_index];
        if (job.done.load(.acquire)) {
            self.state.dispatch(.{ .set_status = "job already done" });
            return;
        }
        job.cancel_requested.store(true, .release);
        self.state.dispatch(.{ .set_status = "cancel requested" });
    }

    fn markTaskFinished(
        self: *RootWidget,
        job: *RunningJob,
        state: TaskRunState,
        exit_code: ?u8,
        elapsed_ms: u64,
    ) void {
        const index = job.task_index orelse return;
        self.task_statuses[index] = .{
            .state = state,
            .exit_code = exit_code,
            .elapsed_ms = elapsed_ms,
            .job_id = job.id,
        };
    }

    fn refreshHistory(self: *RootWidget) !void {
        self.freeHistoryEntries();
        self.history_entries = try history.loadRecentFiltered(self.allocator, self.io, self.state.project_root, 50, .{
            .status = self.history_filter,
        });
        self.clampSelectedHistory();
        self.applyHistoryToTasks();
    }

    fn setHistoryFilter(self: *RootWidget, status: history.Status) !void {
        self.history_filter = status;
        self.pending_history_clear = false;
        try self.refreshHistory();
        self.state.dispatch(.{ .set_status = status.label() });
    }

    fn clearHistoryWithConfirmation(self: *RootWidget) !void {
        if (!self.pending_history_clear) {
            self.pending_history_clear = true;
            self.state.dispatch(.{ .set_status = "press C again to clear history" });
            return;
        }

        self.pending_history_clear = false;
        try history.clear(self.allocator, self.io, self.state.project_root);
        try self.refreshHistory();
        self.state.dispatch(.{ .set_status = "history cleared" });
    }

    fn showSelectedHistoryDetails(self: *RootWidget) !void {
        if (self.history_entries.len == 0) {
            self.state.dispatch(.{ .set_status = "no history" });
            return;
        }

        self.clampSelectedHistory();
        const entry = self.history_entries[self.selected_history_index];
        try self.state.log.push(.system, "History entry", timestampMs(self.io));
        try self.pushDetailLine("task", entry.task_id);
        try self.pushDetailLine("status", entry.status().label());
        var timestamp_buffer: [32]u8 = undefined;
        try self.pushDetailLine("timestamp ms", try std.fmt.bufPrint(&timestamp_buffer, "{d}", .{entry.timestamp_ms}));
        var elapsed_buffer: [32]u8 = undefined;
        try self.pushDetailLine("elapsed ms", try std.fmt.bufPrint(&elapsed_buffer, "{d}", .{entry.elapsed_ms}));
        if (entry.exit_code) |code| {
            var code_buffer: [16]u8 = undefined;
            try self.pushDetailLine("exit code", try std.fmt.bufPrint(&code_buffer, "{d}", .{code}));
        }
        self.state.focused_pane = .output;
        self.state.dispatch(.{ .set_status = "history details" });
    }

    fn freeHistoryEntries(self: *RootWidget) void {
        for (self.history_entries) |entry| history.freeEntry(self.allocator, entry);
        if (self.history_entries.len > 0) self.allocator.free(self.history_entries);
        self.history_entries = &.{};
    }

    fn applyHistoryToTasks(self: *RootWidget) void {
        for (self.history_entries) |entry| {
            const index = self.taskIndexById(entry.task_id) orelse continue;
            if (self.task_statuses[index].state == .running) continue;
            self.task_statuses[index] = .{
                .state = if (entry.exit_code) |code| if (code == 0) .success else .failed else .signal,
                .exit_code = entry.exit_code,
                .elapsed_ms = entry.elapsed_ms,
            };
        }
    }

    fn clampSelectedJob(self: *RootWidget) void {
        if (self.jobs.items.len == 0) {
            self.selected_job_index = 0;
            return;
        }
        self.selected_job_index = @min(self.selected_job_index, self.jobs.items.len - 1);
    }

    fn clampSelectedHistory(self: *RootWidget) void {
        if (self.history_entries.len == 0) {
            self.selected_history_index = 0;
            return;
        }
        self.selected_history_index = @min(self.selected_history_index, self.history_entries.len - 1);
    }

    fn clampSelectedChange(self: *RootWidget) void {
        if (self.changed_files.items.len == 0) {
            self.selected_change_index = 0;
            return;
        }
        self.selected_change_index = @min(self.selected_change_index, self.changed_files.items.len - 1);
    }

    fn drainJobEvents(self: *RootWidget) !void {
        for (self.jobs.items) |job| {
            try self.drainJobEvent(job, false);
        }
    }

    fn drainJobEvent(self: *RootWidget, job: *RunningJob, flush: bool) !void {
        job.mutex.lockUncancelable(self.io);
        defer job.mutex.unlock(self.io);

        const prefix = if (job.events.items.len > 0 or flush)
            try std.fmt.allocPrint(self.allocator, "[#{d} {s}] ", .{ job.id, job.task_spec.id })
        else
            "";
        defer if (prefix.len > 0) self.allocator.free(prefix);

        for (job.events.items) |event| {
            const kind: log_buffer.LogKind = switch (event.kind) {
                .stdout => .stdout,
                .stderr => .stderr,
            };
            const pending = switch (event.kind) {
                .stdout => &job.pending_stdout,
                .stderr => &job.pending_stderr,
            };
            try appendStreamBytes(&self.state.log, kind, pending, event.bytes, job.allocator, self.allocator, prefix, self.io);
            job.allocator.free(event.bytes);
        }
        job.events.clearRetainingCapacity();

        if (flush) {
            try flushPendingLine(&self.state.log, .stdout, &job.pending_stdout, self.allocator, prefix, self.io);
            try flushPendingLine(&self.state.log, .stderr, &job.pending_stderr, self.allocator, prefix, self.io);
        }
    }

    fn appendFailureSummary(self: *RootWidget, result: runner.RunResult) !void {
        const code = result.exitCode() orelse 1;
        if (code == 0) return;

        const parsed = try failures.parse(self.allocator, result.stdout, result.stderr, 12);
        defer failures.freeFailures(self.allocator, parsed);
        if (parsed.len == 0) return;

        try self.state.log.push(.system, "Failures", timestampMs(self.io));
        for (parsed) |failure| {
            const line = try std.fmt.allocPrint(self.allocator, "[{s}] {s}", .{ failure.kind.label(), failure.message });
            defer self.allocator.free(line);
            try self.state.log.push(.stderr, line, timestampMs(self.io));
        }
    }

    fn refreshGit(self: *RootWidget) void {
        if (!self.git_enabled) {
            self.state.dispatch(.{ .set_status = "git disabled" });
            return;
        }
        self.state.dispatch(.{ .set_git = git.loadSummary(self.allocator, self.io, self.state.project_root) });
    }

    fn showChanges(self: *RootWidget) !void {
        if (!self.git_enabled) {
            self.state.dispatch(.{ .set_status = "git disabled" });
            return;
        }

        try self.refreshChanges();
        self.state.dispatch(.exit_mode);
        self.state.mode = .changes;
        self.state.dispatch(.{ .set_status = "git changes" });
    }

    fn refreshChanges(self: *RootWidget) !void {
        const next = git.loadChangedFiles(self.allocator, self.io, self.state.project_root);
        self.changed_files.deinit();
        self.changed_files = next;
        self.clampSelectedChange();
        self.clearPendingDiscardPath();
    }

    fn toggleSelectedChange(self: *RootWidget) !void {
        if (self.changed_files.items.len == 0) {
            self.state.dispatch(.{ .set_status = "no changes" });
            return;
        }

        self.clampSelectedChange();
        const item = self.changed_files.items[self.selected_change_index];
        if (item.staged) {
            try git.unstagePath(self.allocator, self.io, self.state.project_root, item.path);
            self.state.dispatch(.{ .set_status = "unstaged" });
        } else {
            try git.stagePath(self.allocator, self.io, self.state.project_root, item.path);
            self.state.dispatch(.{ .set_status = "staged" });
        }
        self.refreshGit();
        try self.refreshChanges();
    }

    fn discardSelectedChangeWithConfirmation(self: *RootWidget) !void {
        if (self.changed_files.items.len == 0) {
            self.clearPendingDiscardPath();
            self.state.dispatch(.{ .set_status = "no changes" });
            return;
        }

        self.clampSelectedChange();
        const item = self.changed_files.items[self.selected_change_index];
        if (self.pending_discard_path) |path| {
            if (std.mem.eql(u8, path, item.path)) {
                try git.discardChangedFile(self.allocator, self.io, self.state.project_root, item);
                self.clearPendingDiscardPath();
                self.refreshGit();
                try self.refreshChanges();
                self.state.dispatch(.{ .set_status = "discarded" });
                return;
            }
        }

        self.setPendingDiscardPath(item.path) catch {
            self.state.dispatch(.{ .set_status = "confirm discard" });
            return;
        };
        self.state.dispatch(.{ .set_status = "press D again to discard" });
    }

    fn showSelectedDiff(self: *RootWidget) !void {
        if (self.changed_files.items.len == 0) {
            self.state.dispatch(.{ .set_status = "no changes" });
            return;
        }

        self.clampSelectedChange();
        const item = self.changed_files.items[self.selected_change_index];
        const diff = try git.diffChangedFile(self.allocator, self.io, self.state.project_root, item);
        defer self.allocator.free(diff);

        const title = try std.fmt.allocPrint(self.allocator, "Git diff: {s}", .{item.path});
        defer self.allocator.free(title);
        try self.state.log.push(.system, title, timestampMs(self.io));
        var lines = std.mem.splitScalar(u8, diff, '\n');
        var count: usize = 0;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r");
            if (line.len == 0) continue;
            try self.state.log.push(.stdout, line, timestampMs(self.io));
            count += 1;
        }
        if (count == 0) try self.state.log.push(.system, "(no diff output)", timestampMs(self.io));
        self.state.dispatch(.{ .set_status = "diff shown" });
    }

    fn setPendingDiscardPath(self: *RootWidget, path: []const u8) !void {
        self.freePendingDiscardPath();
        self.pending_discard_path = try self.allocator.dupe(u8, path);
    }

    fn clearPendingDiscardPath(self: *RootWidget) void {
        self.freePendingDiscardPath();
    }

    fn freePendingDiscardPath(self: *RootWidget) void {
        if (self.pending_discard_path) |path| {
            self.allocator.free(path);
            self.pending_discard_path = null;
        }
    }

    fn showWorktrees(self: *RootWidget) !void {
        if (!self.git_enabled) {
            self.state.dispatch(.{ .set_status = "git disabled" });
            return;
        }

        var list = git.loadWorktrees(self.allocator, self.io, self.state.project_root);
        defer list.deinit();

        try self.state.log.push(.system, "Git worktrees", timestampMs(self.io));
        if (list.items.len == 0) {
            try self.state.log.push(.system, "(none)", timestampMs(self.io));
            return;
        }

        for (list.items) |item| {
            const label = if (item.detached)
                try std.fmt.allocPrint(self.allocator, "{s}  detached {s}", .{ item.path, shortHead(item.head) })
            else
                try std.fmt.allocPrint(self.allocator, "{s}  {s}", .{ item.path, item.branch });
            defer self.allocator.free(label);
            try self.state.log.push(.system, label, timestampMs(self.io));
        }
        self.state.dispatch(.{ .set_status = "worktrees shown" });
    }

    fn showSelectedTaskDetails(self: *RootWidget) !void {
        const item = self.state.selectedTask() orelse {
            self.state.dispatch(.{ .set_status = "no task selected" });
            return;
        };

        try self.state.log.push(.system, "Task details", timestampMs(self.io));
        try self.pushDetailLine("id", item.id);
        try self.pushDetailLine("label", item.label);
        try self.pushDetailLine("source", item.source.label());
        if (item.group.len > 0) try self.pushDetailLine("group", item.group);
        if (item.description.len > 0) try self.pushDetailLine("description", item.description);
        try self.pushDetailLine("cwd", item.cwd);
        const command = try formatCommand(self.allocator, item.argv);
        defer self.allocator.free(command);
        try self.pushDetailLine("command", command);
        try self.pushDetailLine("watch", if (item.watch) "on" else "off");
        try self.pushDetailLine("inherit env", if (item.inherit_env) "on" else "off");
        if (item.timeout_ms) |timeout_ms| {
            var timeout_buffer: [32]u8 = undefined;
            try self.pushDetailLine("timeout ms", try std.fmt.bufPrint(&timeout_buffer, "{d}", .{timeout_ms}));
        }
        if (item.max_output_bytes) |limit| {
            var limit_buffer: [32]u8 = undefined;
            try self.pushDetailLine("max output bytes", try std.fmt.bufPrint(&limit_buffer, "{d}", .{limit}));
        }
        self.state.focused_pane = .output;
        self.state.dispatch(.{ .set_status = "task details" });
    }

    fn pushDetailLine(self: *RootWidget, label: []const u8, value: []const u8) !void {
        const line = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ label, value });
        defer self.allocator.free(line);
        try self.state.log.push(.system, line, timestampMs(self.io));
    }

    fn lastTask(self: *RootWidget) ?task.TaskSpec {
        const task_id = self.state.last_task_id orelse return null;
        for (self.state.tasks) |item| {
            if (std.mem.eql(u8, item.id, task_id)) return item;
        }
        return null;
    }

    fn focusLabel(self: *RootWidget) []const u8 {
        return switch (self.state.focused_pane) {
            .tasks => "focus tasks",
            .output => "focus output",
        };
    }

    fn selectedHistoryTask(self: *RootWidget) ?task.TaskSpec {
        if (self.history_entries.len == 0) return null;
        self.clampSelectedHistory();
        return self.taskById(self.history_entries[self.selected_history_index].task_id);
    }

    fn taskById(self: *RootWidget, task_id: []const u8) ?task.TaskSpec {
        for (self.state.tasks) |item| {
            if (std.mem.eql(u8, item.id, task_id)) return item;
        }
        return null;
    }

    fn taskIndexById(self: *RootWidget, task_id: []const u8) ?usize {
        for (self.state.tasks, 0..) |item, index| {
            if (std.mem.eql(u8, item.id, task_id)) return index;
        }
        return null;
    }

    fn runningJobCount(self: *RootWidget) usize {
        var count: usize = 0;
        for (self.jobs.items) |job| {
            if (!job.done.load(.acquire)) count += 1;
        }
        return count;
    }

    fn drawErased(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *RootWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 80;
        const height = ctx.max.height orelse 8;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });

        const panes = layout.compute(width, height);
        self.drawTasks(ctx.arena, surface, panes.tasks);
        self.drawOutput(surface, panes.output);
        self.drawStatus(ctx.arena, surface, panes.status);

        return surface;
    }

    fn drawTasks(self: *RootWidget, arena: std.mem.Allocator, surface: vxfw.Surface, rect: layout.Rect) void {
        const title = if (self.state.focused_pane == .tasks) "Tasks *" else "Tasks";
        widgets.drawBox(surface, rect, title);
        if (rect.height <= 2 or rect.width <= 4) return;

        const max_rows = rect.height - 2;
        const max_width = rect.width - 4;
        var row_index: usize = 0;
        for (self.state.tasks, 0..) |item, index| {
            if (!self.state.taskVisible(index)) continue;
            if (row_index >= max_rows) break;

            const row: u16 = rect.y + 1 + @as(u16, @intCast(row_index));
            const marker = if (index == self.state.selected_task) ">" else " ";
            const style = selectedStyle(self.settings.theme, index == self.state.selected_task);
            const line = formatTaskLine(arena, item, self.task_statuses[index]) catch item.label;
            widgets.writeTextStyled(surface, row, rect.x + 2, marker, style);
            widgets.writeTextClippedStyled(surface, row, rect.x + 4, line, max_width, style);
            row_index += 1;
        }
        if (row_index == 0) {
            widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, "No matching tasks", rect.width - 4);
        }
    }

    fn drawOutput(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        if (self.state.mode == .palette) {
            self.drawPalette(surface, rect);
            return;
        }
        if (self.state.mode == .help) {
            self.drawHelp(surface, rect);
            return;
        }
        if (self.state.mode == .jobs) {
            self.drawJobs(surface, rect);
            return;
        }
        if (self.state.mode == .history) {
            self.drawHistory(surface, rect);
            return;
        }
        if (self.state.mode == .changes) {
            self.drawChanges(surface, rect);
            return;
        }

        const title = if (self.state.mode == .log_search)
            "Output Search"
        else if (self.state.focused_pane == .output)
            "Output *"
        else
            "Output";
        widgets.drawBox(surface, rect, title);
        if (rect.height <= 2 or rect.width <= 4) return;

        const logs = self.state.log.items();
        if (logs.len == 0) {
            widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, "No output yet", rect.width - 4);
            return;
        }
        const visible_logs = self.state.visibleLogCount();
        if (visible_logs == 0) {
            widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, "No matching output", rect.width - 4);
            return;
        }

        const max_rows: usize = rect.height - 2;
        const scroll = @min(self.state.output_scroll, visible_logs);
        const first_visible = if (visible_logs > max_rows + scroll) visible_logs - max_rows - scroll else 0;
        var visible_index: usize = 0;
        var drawn: usize = 0;
        for (logs, 0..) |line, log_index| {
            if (!self.state.logVisible(log_index)) continue;
            if (visible_index < first_visible) {
                visible_index += 1;
                continue;
            }
            if (drawn >= max_rows) break;
            const row: u16 = rect.y + 1 + @as(u16, @intCast(drawn));
            widgets.writeTextClipped(surface, row, rect.x + 2, line.text, rect.width - 4);
            visible_index += 1;
            drawn += 1;
        }
    }

    fn drawPalette(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        widgets.drawBox(surface, rect, "Command Palette");
        if (rect.height <= 2 or rect.width <= 4) return;

        if (std.fmt.allocPrint(self.allocator, "filter: {s}", .{self.palette_query.items})) |query_line| {
            defer self.allocator.free(query_line);
            widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, query_line, rect.width - 4);
        } else |_| {
            widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, "filter", rect.width - 4);
        }

        const max_rows = if (rect.height > 3) rect.height - 3 else 0;
        var visible_index: usize = 0;
        var drawn: usize = 0;
        for (palette_commands) |command| {
            if (!self.paletteCommandVisible(command)) continue;
            if (drawn >= max_rows) break;
            const row: u16 = rect.y + 2 + @as(u16, @intCast(drawn));
            const marker = if (visible_index == self.palette_index) ">" else " ";
            widgets.writeText(surface, row, rect.x + 2, marker);
            widgets.writeTextClipped(surface, row, rect.x + 4, command.label, rect.width - 4);
            visible_index += 1;
            drawn += 1;
        }
        if (drawn == 0) {
            widgets.writeTextClipped(surface, rect.y + 2, rect.x + 2, "No matching commands", rect.width - 4);
        }
    }

    fn drawHelp(_: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        widgets.drawBox(surface, rect, "Help");
        if (rect.height <= 2 or rect.width <= 4) return;

        const lines = [_][]const u8{
            "Enter  run selected task",
            "j/k or arrows  move task selection or scroll focused output",
            "/  search tasks; when output is focused, search output",
            "Tab  switch focus between task list and output",
            ":  command palette",
            "J  show running jobs",
            "h  show run history",
            "f  show Git changes; Space stage/unstage; Enter show diff; D discard",
            "i  show selected task details",
            "r  rerun last task",
            "x  cancel newest running task",
            "w  toggle file-watch rerun",
            "t  show Git worktrees",
            "g  refresh Git status",
            "c  clear output",
            "q or Ctrl+C  quit when no task is running",
            "Esc, q, or ?  close help",
        };
        const max_rows: usize = rect.height - 2;
        for (lines[0..@min(lines.len, max_rows)], 0..) |line, index| {
            const row: u16 = rect.y + 1 + @as(u16, @intCast(index));
            widgets.writeTextClipped(surface, row, rect.x + 2, line, rect.width - 4);
        }
    }

    fn drawJobs(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        widgets.drawBox(surface, rect, "Jobs");
        if (rect.height <= 2 or rect.width <= 4) return;
        if (self.jobs.items.len == 0) {
            widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, "No running jobs", rect.width - 4);
            return;
        }

        const max_rows = rect.height - 2;
        for (self.jobs.items[0..@min(self.jobs.items.len, max_rows)], 0..) |job, index| {
            const row: u16 = rect.y + 1 + @as(u16, @intCast(index));
            const marker = if (index == self.selected_job_index) ">" else " ";
            const state = if (job.done.load(.acquire))
                "done"
            else if (job.cancel_requested.load(.acquire))
                "cancelling"
            else
                "running";
            const line = std.fmt.allocPrint(self.allocator, "{s} #{d} {s}  {s}", .{ marker, job.id, job.task_spec.id, state }) catch job.task_spec.id;
            defer if (line.ptr != job.task_spec.id.ptr) self.allocator.free(line);
            widgets.writeTextClipped(surface, row, rect.x + 2, line, rect.width - 4);
        }
    }

    fn drawHistory(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        const title = std.fmt.allocPrint(self.allocator, "History ({s})", .{self.history_filter.label()}) catch "History";
        defer if (title.ptr != "History".ptr) self.allocator.free(title);
        widgets.drawBox(surface, rect, title);
        if (rect.height <= 2 or rect.width <= 4) return;
        if (self.history_entries.len == 0) {
            widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, "No history yet", rect.width - 4);
            return;
        }

        const max_rows = rect.height - 2;
        self.clampSelectedHistory();
        const first = if (self.selected_history_index >= max_rows)
            self.selected_history_index - max_rows + 1
        else
            0;
        for (self.history_entries[first..], 0..) |entry, offset| {
            if (offset >= max_rows) break;
            const index = first + offset;
            const row: u16 = rect.y + 1 + @as(u16, @intCast(offset));
            const marker = if (index == self.selected_history_index) ">" else " ";
            const exit_text = if (entry.exit_code) |code|
                std.fmt.allocPrint(self.allocator, "exit {d}", .{code}) catch "exit"
            else
                "signal";
            defer if (entry.exit_code != null) self.allocator.free(exit_text);
            const line = std.fmt.allocPrint(
                self.allocator,
                "{s} {s}  {s}  {d}ms",
                .{ marker, entry.task_id, exit_text, entry.elapsed_ms },
            ) catch entry.task_id;
            defer if (line.ptr != entry.task_id.ptr) self.allocator.free(line);
            widgets.writeTextClipped(surface, row, rect.x + 2, line, rect.width - 4);
        }
    }

    fn drawChanges(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        widgets.drawBox(surface, rect, "Git Changes");
        if (rect.height <= 2 or rect.width <= 4) return;
        if (self.changed_files.items.len == 0) {
            widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, "No changes", rect.width - 4);
            return;
        }

        const max_rows = rect.height - 2;
        self.clampSelectedChange();
        const first = if (self.selected_change_index >= max_rows)
            self.selected_change_index - max_rows + 1
        else
            0;
        for (self.changed_files.items[first..], 0..) |item, offset| {
            if (offset >= max_rows) break;
            const index = first + offset;
            const row: u16 = rect.y + 1 + @as(u16, @intCast(offset));
            const marker = if (index == self.selected_change_index) ">" else " ";
            const staged = if (item.staged) "staged" else "work";
            const line = std.fmt.allocPrint(
                self.allocator,
                "{s} {s:<9} {s:<7} {s}",
                .{ marker, item.state.label(), staged, item.path },
            ) catch item.path;
            defer if (line.ptr != item.path.ptr) self.allocator.free(line);
            widgets.writeTextClipped(surface, row, rect.x + 2, line, rect.width - 4);
        }
    }

    fn drawStatus(self: *RootWidget, arena: std.mem.Allocator, surface: vxfw.Surface, rect: layout.Rect) void {
        widgets.drawBox(surface, rect, "Status");
        if (rect.height == 0 or rect.width <= 4) return;

        const status = if (self.state.status_message.len > 0) self.state.status_message else "ready";
        const git_line = formatGitLine(arena, self.git_enabled, self.state.git_summary) catch "git: error";
        const running_count = self.runningJobCount();
        const mode_line = if (self.state.mode == .search)
            std.fmt.allocPrint(arena, "search: {s}  matches: {d}", .{
                self.state.search_query.items,
                self.state.visibleTaskCount(),
            }) catch "search"
        else if (self.state.mode == .log_search)
            std.fmt.allocPrint(arena, "output search: {s}  matches: {d}", .{
                self.state.log_search_query.items,
                self.state.visibleLogCount(),
            }) catch "output search"
        else if (self.state.mode == .palette)
            std.fmt.allocPrint(arena, "palette: {s}  Enter run  Esc close", .{self.palette_query.items}) catch "palette"
        else if (self.state.mode == .help)
            "help: Esc close"
        else if (self.state.mode == .jobs)
            "jobs: j/k select  x cancel  Esc close"
        else if (self.state.mode == .history)
            "history: a all s ok e failed S signal C clear i details Enter rerun Esc close"
        else if (self.state.mode == .changes)
            "changes: j/k select  Space stage  Enter diff  D discard  g refresh  Esc close"
        else if (running_count > 0)
            std.fmt.allocPrint(arena, "running: {d}  {s}", .{ running_count, git_line }) catch "running"
        else if (self.watch_enabled)
            std.fmt.allocPrint(arena, "watch on  {s}", .{git_line}) catch "watch on"
        else
            std.fmt.allocPrint(arena, "focus: {s}  {s}", .{ @tagName(self.state.focused_pane), git_line }) catch git_line;
        const status_line = std.fmt.allocPrint(arena, "{s}  status: {s}", .{ mode_line, status }) catch mode_line;
        widgets.writeTextClippedStyled(surface, rect.y + 1, rect.x + 2, status_line, rect.width - 4, statusStyle(self.settings.theme));
        if (rect.height > 2) {
            widgets.writeTextClipped(surface, rect.y + 2, rect.x + 2, "Enter run / find : cmds i info J jobs h history f files Tab pane ? help w watch t trees r rerun x stop c clear g git q quit", rect.width - 4);
        }
    }
};

const TaskRunState = enum {
    idle,
    running,
    success,
    failed,
    cancelled,
    signal,
};

const TaskStatus = struct {
    state: TaskRunState = .idle,
    exit_code: ?u8 = null,
    elapsed_ms: u64 = 0,
    job_id: ?usize = null,
};

const PaletteCommandId = enum {
    run_selected,
    rerun_last,
    clear_output,
    refresh_git,
    show_changes,
    show_worktrees,
    show_task_details,
    toggle_watch,
    show_jobs,
    show_history,
    search_tasks,
    quit,
};

const PaletteCommand = struct {
    id: PaletteCommandId,
    label: []const u8,
};

const palette_commands = [_]PaletteCommand{
    .{ .id = .run_selected, .label = "Run selected task" },
    .{ .id = .rerun_last, .label = "Rerun last task" },
    .{ .id = .clear_output, .label = "Clear output" },
    .{ .id = .refresh_git, .label = "Refresh Git status" },
    .{ .id = .show_changes, .label = "Show Git changes" },
    .{ .id = .show_worktrees, .label = "Show Git worktrees" },
    .{ .id = .show_task_details, .label = "Show selected task details" },
    .{ .id = .toggle_watch, .label = "Toggle file watch" },
    .{ .id = .show_jobs, .label = "Show running jobs" },
    .{ .id = .show_history, .label = "Show run history" },
    .{ .id = .search_tasks, .label = "Search tasks" },
    .{ .id = .quit, .label = "Quit" },
};

const RunningJob = struct {
    id: usize,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    task_spec: task.TaskSpec,
    task_index: ?usize = null,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Io.Mutex = .init,
    events: std.ArrayList(StreamEvent) = .empty,
    pending_stdout: std.ArrayList(u8) = .empty,
    pending_stderr: std.ArrayList(u8) = .empty,
    result: ?runner.RunResult = null,
    err_name: ?[]const u8 = null,

    fn run(job: *RunningJob) void {
        job.result = runner.runTaskStreaming(
            job.allocator,
            job.io,
            job.task_spec,
            job.env_map,
            &job.cancel_requested,
            job,
            onStreamOutput,
        ) catch |err| {
            job.err_name = @errorName(err);
            job.done.store(true, .release);
            return;
        };
        job.done.store(true, .release);
    }

    fn deinit(job: *RunningJob) void {
        job.mutex.lockUncancelable(job.io);
        defer job.mutex.unlock(job.io);

        for (job.events.items) |event| {
            job.allocator.free(event.bytes);
        }
        job.events.deinit(job.allocator);
        job.pending_stdout.deinit(job.allocator);
        job.pending_stderr.deinit(job.allocator);
        if (job.result) |result| result.deinit(job.allocator);
    }

    fn pushEvent(job: *RunningJob, kind: runner.StreamKind, bytes: []const u8) !void {
        const owned = try job.allocator.dupe(u8, bytes);
        errdefer job.allocator.free(owned);

        job.mutex.lockUncancelable(job.io);
        defer job.mutex.unlock(job.io);
        try job.events.append(job.allocator, .{
            .kind = kind,
            .bytes = owned,
        });
    }
};

const StreamEvent = struct {
    kind: runner.StreamKind,
    bytes: []const u8,
};

fn onStreamOutput(context: *anyopaque, kind: runner.StreamKind, bytes: []const u8) !void {
    const job: *RunningJob = @ptrCast(@alignCast(context));
    try job.pushEvent(kind, bytes);
}

fn formatTaskLine(allocator: std.mem.Allocator, item: task.TaskSpec, status: TaskStatus) ![]const u8 {
    const group = if (item.group.len > 0) item.group else item.source.label();
    return std.fmt.allocPrint(
        allocator,
        "{s:<22} {s:<10} {s:<7} {s}",
        .{ item.label, group, item.source.label(), taskStatusLabel(allocator, status) catch "" },
    );
}

fn taskStatusLabel(allocator: std.mem.Allocator, status: TaskStatus) ![]const u8 {
    return switch (status.state) {
        .idle => "",
        .running => if (status.job_id) |id|
            std.fmt.allocPrint(allocator, "running #{d}", .{id})
        else
            "running",
        .success => std.fmt.allocPrint(allocator, "ok {d}ms", .{status.elapsed_ms}),
        .failed => if (status.exit_code) |code|
            std.fmt.allocPrint(allocator, "failed {d}", .{code})
        else
            "failed",
        .cancelled => "cancelled",
        .signal => "signal",
    };
}

fn formatCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var command: std.ArrayList(u8) = .empty;
    errdefer command.deinit(allocator);

    try command.append(allocator, '$');
    for (argv) |arg| {
        try command.append(allocator, ' ');
        try command.appendSlice(allocator, arg);
    }

    return command.toOwnedSlice(allocator);
}

fn appendStreamBytes(
    log: *log_buffer.LogBuffer,
    kind: log_buffer.LogKind,
    pending: *std.ArrayList(u8),
    bytes: []const u8,
    pending_allocator: std.mem.Allocator,
    log_allocator: std.mem.Allocator,
    prefix: []const u8,
    io: std.Io,
) !void {
    if (bytes.len == 0) return;

    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte != '\n') continue;
        try pending.appendSlice(pending_allocator, bytes[start..index]);
        try flushPendingLine(log, kind, pending, log_allocator, prefix, io);
        start = index + 1;
    }
    if (start < bytes.len) try pending.appendSlice(pending_allocator, bytes[start..]);
}

fn flushPendingLine(
    log: *log_buffer.LogBuffer,
    kind: log_buffer.LogKind,
    pending: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    io: std.Io,
) !void {
    const line = std.mem.trim(u8, pending.items, "\r");
    if (line.len > 0) {
        if (prefix.len == 0) {
            try log.push(kind, line, timestampMs(io));
        } else {
            const prefixed = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, line });
            defer allocator.free(prefixed);
            try log.push(kind, prefixed, timestampMs(io));
        }
    }
    pending.clearRetainingCapacity();
}

fn timestampMs(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
}

fn formatGitLine(allocator: std.mem.Allocator, enabled: bool, summary: git.GitSummary) ![]const u8 {
    if (!enabled) return "git: disabled";
    if (!summary.in_repo) return "git: none";

    return std.fmt.allocPrint(
        allocator,
        "branch: {s}  modified: {d}  added: {d}  deleted: {d}  untracked: {d}  worktrees: {d}",
        .{ summary.branch, summary.modified, summary.added, summary.deleted, summary.untracked, summary.worktrees },
    );
}

fn shortHead(head: []const u8) []const u8 {
    return head[0..@min(head.len, 8)];
}

fn matchesBinding(key: vaxis.Key, binding: []const u8) bool {
    if (binding.len == 0) return false;
    if (std.mem.startsWith(u8, binding, "ctrl+") and binding.len == "ctrl+x".len) {
        return key.matches(binding["ctrl+".len], .{ .ctrl = true });
    }
    if (std.mem.eql(u8, binding, "enter")) return key.matches(vaxis.Key.enter, .{});
    if (std.mem.eql(u8, binding, "escape")) return key.matches(vaxis.Key.escape, .{});
    if (std.mem.eql(u8, binding, "backspace")) return key.matches(vaxis.Key.backspace, .{});
    if (std.mem.eql(u8, binding, "up")) return key.matches(vaxis.Key.up, .{});
    if (std.mem.eql(u8, binding, "down")) return key.matches(vaxis.Key.down, .{});
    if (std.mem.eql(u8, binding, "tab")) return key.matches(vaxis.Key.tab, .{});
    if (binding.len == 1) return key.matches(binding[0], .{});
    return false;
}

fn selectedStyle(theme: config.Theme, selected: bool) vaxis.Style {
    if (!selected) return normalStyle(theme);
    return switch (theme) {
        .default, .dark => .{ .bold = true, .reverse = true },
        .light => .{ .bold = true, .fg = .{ .index = 16 }, .bg = .{ .index = 15 } },
        .high_contrast => .{ .bold = true, .fg = .{ .index = 16 }, .bg = .{ .index = 11 } },
    };
}

fn statusStyle(theme: config.Theme) vaxis.Style {
    return switch (theme) {
        .default => .{},
        .dark => .{ .fg = .{ .index = 14 } },
        .light => .{ .fg = .{ .index = 4 } },
        .high_contrast => .{ .bold = true, .fg = .{ .index = 11 } },
    };
}

fn normalStyle(theme: config.Theme) vaxis.Style {
    return switch (theme) {
        .default, .dark, .light => .{},
        .high_contrast => .{ .fg = .{ .index = 15 } },
    };
}

test "key binding matcher handles named and ctrl keys" {
    try std.testing.expect(matchesBinding(.{ .codepoint = vaxis.Key.enter }, "enter"));
    try std.testing.expect(matchesBinding(.{ .codepoint = 'r', .mods = .{ .ctrl = true } }, "ctrl+r"));
    try std.testing.expect(matchesBinding(.{ .codepoint = ':' }, ":"));
    try std.testing.expect(matchesBinding(.{ .codepoint = vaxis.Key.tab }, "tab"));
    try std.testing.expect(matchesBinding(.{ .codepoint = '?' }, "?"));
    try std.testing.expect(!matchesBinding(.{ .codepoint = 'r' }, "ctrl+r"));
}

test "stream log chunks keep partial lines together" {
    var log = log_buffer.LogBuffer.init(std.testing.allocator, 10);
    defer log.deinit();
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(std.testing.allocator);

    try appendStreamBytes(
        &log,
        .stdout,
        &pending,
        "hel",
        std.testing.allocator,
        std.testing.allocator,
        "",
        std.testing.io,
    );
    try std.testing.expectEqual(@as(usize, 0), log.items().len);

    try appendStreamBytes(
        &log,
        .stdout,
        &pending,
        "lo\nnext",
        std.testing.allocator,
        std.testing.allocator,
        "",
        std.testing.io,
    );
    try std.testing.expectEqual(@as(usize, 1), log.items().len);
    try std.testing.expectEqualStrings("hello", log.items()[0].text);

    try flushPendingLine(&log, .stdout, &pending, std.testing.allocator, "", std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), log.items().len);
    try std.testing.expectEqualStrings("next", log.items()[1].text);
}
