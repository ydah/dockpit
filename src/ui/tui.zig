const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const app_state = @import("../core/app_state.zig");
const failures = @import("../core/failures.zig");
const git = @import("../core/git.zig");
const history = @import("../core/history.zig");
const log_buffer = @import("../core/log_buffer.zig");
const runner = @import("../core/runner.zig");
const task = @import("../core/task.zig");
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
    };

    try app.run(root.widget(), .{});
}

const RootWidget = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    git_enabled: bool,
    state: *app_state.AppState,
    running: ?*RunningJob = null,
    palette_index: usize = 0,

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
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
                    if (self.running) |job| {
                        if (!job.done.load(.acquire)) {
                            self.state.dispatch(.{ .set_status = "task running" });
                            ctx.consumeAndRedraw();
                            return;
                        }
                        try self.finishJob(job);
                        self.running = null;
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
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.state.selectedTask()) |selected| {
                        try self.startTask(ctx, selected);
                    }
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches('r', .{})) {
                    if (self.lastTask()) |last| {
                        try self.startTask(ctx, last);
                    }
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches('x', .{})) {
                    self.requestCancel();
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches('g', .{})) {
                    self.refreshGit();
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches('c', .{})) {
                    self.state.dispatch(.clear_log);
                    self.state.dispatch(.{ .set_status = "log cleared" });
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches('/', .{})) {
                    self.state.dispatch(.enter_search);
                    self.state.dispatch(.{ .set_status = "search" });
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches(':', .{})) {
                    self.state.dispatch(.exit_mode);
                    self.state.mode = .palette;
                    self.palette_index = 0;
                    self.state.dispatch(.{ .set_status = "palette" });
                    ctx.consumeAndRedraw();
                }
            },
            .tick => try self.pollRunning(ctx),
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
            .search_tasks => {
                self.state.dispatch(.enter_search);
                self.state.dispatch(.{ .set_status = "search" });
            },
            .quit => {
                if (self.running) |job| {
                    if (!job.done.load(.acquire)) {
                        self.state.dispatch(.{ .set_status = "task running" });
                        return;
                    }
                    try self.finishJob(job);
                    self.running = null;
                }
                ctx.quit = true;
            },
        }
    }

    fn startTask(self: *RootWidget, ctx: *vxfw.EventContext, selected: task.TaskSpec) !void {
        if (self.running) |job| {
            if (!job.done.load(.acquire)) {
                self.state.dispatch(.{ .set_status = "task already running" });
                return;
            }
            try self.finishJob(job);
            self.running = null;
        }

        self.state.dispatch(.{ .set_last_task = selected.id });
        self.state.dispatch(.{ .set_status = "running" });

        const command_line = try formatCommand(self.allocator, selected.argv);
        try self.state.log.push(.system, command_line, timestampMs(self.io));

        const job = try self.allocator.create(RunningJob);
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .env_map = self.env_map,
            .task_spec = selected,
        };
        job.thread = try std.Thread.spawn(.{}, RunningJob.run, .{job});
        self.running = job;
        try ctx.tick(100, self.widget());
    }

    fn pollRunning(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        const job = self.running orelse return;
        if (!job.done.load(.acquire)) {
            try ctx.tick(100, self.widget());
            return;
        }

        try self.finishJob(job);
        self.running = null;
        ctx.redraw = true;
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
        const job = self.running orelse {
            self.state.dispatch(.{ .set_status = "no running task" });
            return;
        };
        if (job.done.load(.acquire)) {
            self.state.dispatch(.{ .set_status = "task finished" });
            return;
        }
        job.cancel_requested.store(true, .release);
        self.state.dispatch(.{ .set_status = "cancel requested" });
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

    fn lastTask(self: *RootWidget) ?task.TaskSpec {
        const task_id = self.state.last_task_id orelse return null;
        for (self.state.tasks) |item| {
            if (std.mem.eql(u8, item.id, task_id)) return item;
        }
        return null;
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
        self.drawStatus(surface, panes.status);

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
            widgets.writeText(surface, row, rect.x + 2, marker);
            widgets.writeTextClipped(surface, row, rect.x + 4, item.label, max_width);
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

    fn drawStatus(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        widgets.drawBox(surface, rect, "Status");
        if (rect.height == 0 or rect.width <= 4) return;

        const status = if (self.state.status_message.len > 0) self.state.status_message else "ready";
        var line_buffer: [512]u8 = undefined;
        const git_line = formatGitLine(&line_buffer, self.git_enabled, self.state.git_summary);
        const mode_line = if (self.state.mode == .search)
            std.fmt.bufPrint(&line_buffer, "search: {s}  matches: {d}", .{
                self.state.search_query.items,
                self.state.visibleTaskCount(),
            }) catch "search"
        else if (self.state.mode == .palette)
            "palette: Enter run command  Esc close"
        else
            git_line;
        widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, mode_line, rect.width - 4);
        if (rect.height > 2) {
            widgets.writeTextClipped(surface, rect.y + 2, rect.x + 2, "Enter run  / search  : palette  r rerun  x cancel  c clear  g git  q quit", rect.width - 4);
            widgets.writeTextClipped(surface, rect.y + 2, rect.x + 68, status, rect.width - 4);
        }
    }
};

const PaletteCommandId = enum {
    run_selected,
    rerun_last,
    clear_output,
    refresh_git,
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
    .{ .id = .search_tasks, .label = "Search tasks" },
    .{ .id = .quit, .label = "Quit" },
};

const RunningJob = struct {
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

fn formatGitLine(buffer: []u8, enabled: bool, summary: git.GitSummary) []const u8 {
    if (!enabled) return "git: disabled";
    if (!summary.in_repo) return "git: none";

    return std.fmt.bufPrint(
        buffer,
        "branch: {s}  modified: {d}  added: {d}  deleted: {d}  untracked: {d}",
        .{ summary.branch, summary.modified, summary.added, summary.deleted, summary.untracked },
    ) catch "git: error";
}
