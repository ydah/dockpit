const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const app_state = @import("../core/app_state.zig");
const config = @import("../core/config.zig");
const failures = @import("../core/failures.zig");
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
    };
    defer root.deinit();

    try app.run(root.widget(), .{});
}

const RootWidget = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    git_enabled: bool,
    state: *app_state.AppState,
    settings: config.Settings,
    jobs: std.ArrayList(*RunningJob) = .empty,
    next_job_id: usize = 1,
    palette_index: usize = 0,
    watch_enabled: bool = false,
    watch_snapshot: ?watch.Snapshot = null,
    last_watch_ms: u64 = 0,

    fn deinit(self: *RootWidget) void {
        if (self.watch_snapshot) |*snapshot| snapshot.deinit();
        for (self.jobs.items) |job| {
            if (!job.done.load(.acquire)) job.cancel_requested.store(true, .release);
            job.thread.join();
            self.allocator.destroy(job);
        }
        self.jobs.deinit(self.allocator);
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
                if (self.handleSearchKey(ctx, key)) return;
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
                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                    self.state.dispatch(.select_next);
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                    self.state.dispatch(.select_previous);
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
                if (matchesBinding(key, self.settings.keybindings.worktrees)) {
                    try self.showWorktrees();
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
                    self.state.dispatch(.enter_search);
                    self.state.dispatch(.{ .set_status = "search" });
                    ctx.consumeAndRedraw();
                    return;
                }
                if (matchesBinding(key, self.settings.keybindings.palette)) {
                    self.state.dispatch(.exit_mode);
                    self.state.mode = .palette;
                    self.palette_index = 0;
                    self.state.dispatch(.{ .set_status = "palette" });
                    ctx.consumeAndRedraw();
                }
            },
            .tick => try self.handleTick(ctx),
            else => {},
        }
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

    fn handlePaletteKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
        if (self.state.mode != .palette) return false;

        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            self.state.dispatch(.exit_mode);
            self.state.dispatch(.{ .set_status = "ready" });
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            self.palette_index = (self.palette_index + 1) % palette_commands.len;
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            self.palette_index = if (self.palette_index == 0) palette_commands.len - 1 else self.palette_index - 1;
            ctx.consumeAndRedraw();
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            try self.executePaletteCommand(ctx, palette_commands[self.palette_index].id);
            if (self.state.mode == .palette) self.state.dispatch(.exit_mode);
            ctx.consumeAndRedraw();
            return true;
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
            .show_worktrees => try self.showWorktrees(),
            .toggle_watch => try self.toggleWatch(ctx),
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

    fn startTask(self: *RootWidget, ctx: *vxfw.EventContext, selected: task.TaskSpec) !void {
        try self.finishCompletedJobs();

        self.state.dispatch(.{ .set_last_task = selected.id });
        self.state.dispatch(.{ .set_status = "running" });

        const command_line = try formatCommand(self.allocator, selected.argv);
        defer self.allocator.free(command_line);
        try self.state.log.push(.system, command_line, timestampMs(self.io));

        const job = try self.allocator.create(RunningJob);
        job.* = .{
            .id = self.next_job_id,
            .allocator = self.allocator,
            .io = self.io,
            .env_map = self.env_map,
            .task_spec = selected,
        };
        self.next_job_id += 1;
        job.thread = try std.Thread.spawn(.{}, RunningJob.run, .{job});
        try self.jobs.append(self.allocator, job);
        try ctx.tick(100, self.widget());
    }

    fn handleTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
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

        self.watch_snapshot = try watch.capture(self.allocator, self.io, self.state.project_root);
        self.last_watch_ms = timestampMs(self.io);
        self.watch_enabled = true;
        self.state.dispatch(.{ .set_status = "watch on" });
        try ctx.tick(1000, self.widget());
    }

    fn pollWatch(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        if (!self.watch_enabled) return;

        const now = timestampMs(self.io);
        if (now < self.last_watch_ms + 1000) return;
        self.last_watch_ms = now;

        var current = watch.capture(self.allocator, self.io, self.state.project_root) catch |err| {
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
        self.state.dispatch(.{ .set_status = "watch rerun" });
        try self.startTask(ctx, item);
    }

    fn finishCompletedJobs(self: *RootWidget) !void {
        var index: usize = 0;
        while (index < self.jobs.items.len) {
            const job = self.jobs.items[index];
            if (!job.done.load(.acquire)) {
                index += 1;
                continue;
            }
            _ = self.jobs.orderedRemove(index);
            try self.finishJob(job);
        }
    }

    fn finishJob(self: *RootWidget, job: *RunningJob) !void {
        job.thread.join();
        defer self.allocator.destroy(job);

        if (job.err_name) |err_name| {
            try self.state.log.push(.stderr, err_name, timestampMs(self.io));
            self.state.dispatch(.{ .set_status = "failed to start" });
            return;
        }

        const result = job.result orelse return;
        history.appendRun(self.allocator, self.io, self.state.project_root, job.task_spec, result) catch {
            try self.state.log.push(.stderr, "failed to write history", timestampMs(self.io));
        };
        try appendOutputLines(&self.state.log, .stdout, result.stdout, self.io);
        try appendOutputLines(&self.state.log, .stderr, result.stderr, self.io);
        try self.appendFailureSummary(result);

        const status = if (job.cancel_requested.load(.acquire))
            "cancel requested"
        else if (result.exitCode()) |code|
            try std.fmt.allocPrint(self.allocator, "exit {d}", .{code})
        else
            "signal";
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

    fn lastTask(self: *RootWidget) ?task.TaskSpec {
        const task_id = self.state.last_task_id orelse return null;
        for (self.state.tasks) |item| {
            if (std.mem.eql(u8, item.id, task_id)) return item;
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
        self.drawTasks(surface, panes.tasks);
        self.drawOutput(surface, panes.output);
        self.drawStatus(ctx.arena, surface, panes.status);

        return surface;
    }

    fn drawTasks(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        widgets.drawBox(surface, rect, "Tasks");
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
            widgets.writeTextStyled(surface, row, rect.x + 2, marker, style);
            widgets.writeTextClippedStyled(surface, row, rect.x + 4, item.label, max_width, style);
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

        widgets.drawBox(surface, rect, "Output");
        if (rect.height <= 2 or rect.width <= 4) return;

        const logs = self.state.log.items();
        if (logs.len == 0) {
            widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, "No output yet", rect.width - 4);
            return;
        }

        const max_rows = rect.height - 2;
        const first = if (logs.len > max_rows) logs.len - max_rows else 0;
        for (logs[first..], 0..) |line, index| {
            const row: u16 = rect.y + 1 + @as(u16, @intCast(index));
            widgets.writeTextClipped(surface, row, rect.x + 2, line.text, rect.width - 4);
        }
    }

    fn drawPalette(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        widgets.drawBox(surface, rect, "Command Palette");
        if (rect.height <= 2 or rect.width <= 4) return;

        const max_rows = rect.height - 2;
        for (palette_commands[0..@min(palette_commands.len, max_rows)], 0..) |command, index| {
            const row: u16 = rect.y + 1 + @as(u16, @intCast(index));
            const marker = if (index == self.palette_index) ">" else " ";
            widgets.writeText(surface, row, rect.x + 2, marker);
            widgets.writeTextClipped(surface, row, rect.x + 4, command.label, rect.width - 4);
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
        else if (self.state.mode == .palette)
            "palette: Enter run command  Esc close"
        else if (running_count > 0)
            std.fmt.allocPrint(arena, "running: {d}  {s}", .{ running_count, git_line }) catch "running"
        else if (self.watch_enabled)
            std.fmt.allocPrint(arena, "watch on  {s}", .{git_line}) catch "watch on"
        else
            git_line;
        const status_line = std.fmt.allocPrint(arena, "{s}  status: {s}", .{ mode_line, status }) catch mode_line;
        widgets.writeTextClippedStyled(surface, rect.y + 1, rect.x + 2, status_line, rect.width - 4, statusStyle(self.settings.theme));
        if (rect.height > 2) {
            widgets.writeTextClipped(surface, rect.y + 2, rect.x + 2, "Enter run / find : cmds w watch t trees r rerun x stop c clear g git q quit", rect.width - 4);
        }
    }
};

const PaletteCommandId = enum {
    run_selected,
    rerun_last,
    clear_output,
    refresh_git,
    show_worktrees,
    toggle_watch,
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
    .{ .id = .show_worktrees, .label = "Show Git worktrees" },
    .{ .id = .toggle_watch, .label = "Toggle file watch" },
    .{ .id = .search_tasks, .label = "Search tasks" },
    .{ .id = .quit, .label = "Quit" },
};

const RunningJob = struct {
    id: usize,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    task_spec: task.TaskSpec,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?runner.RunResult = null,
    err_name: ?[]const u8 = null,

    fn run(job: *RunningJob) void {
        job.result = runner.runTask(job.allocator, job.io, job.task_spec, job.env_map) catch |err| {
            job.err_name = @errorName(err);
            job.done.store(true, .release);
            return;
        };
        job.done.store(true, .release);
    }
};

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

fn appendOutputLines(
    log: *log_buffer.LogBuffer,
    kind: log_buffer.LogKind,
    contents: []const u8,
    io: std.Io,
) !void {
    if (contents.len == 0) return;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        try log.push(kind, line, timestampMs(io));
    }
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
    try std.testing.expect(!matchesBinding(.{ .codepoint = 'r' }, "ctrl+r"));
}
