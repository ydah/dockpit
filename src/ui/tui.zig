const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const app_state = @import("../core/app_state.zig");
const task = @import("../core/task.zig");
const layout = @import("layout.zig");
const widgets = @import("widgets.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    project_root: []const u8,
    tasks: []const task.TaskSpec,
) !void {
    var tty_buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(io, allocator, env_map, &tty_buffer);
    defer app.deinit();

    var state = app_state.AppState.init(allocator, project_root, tasks, .{});
    defer state.deinit();

    var root = RootWidget{
        .state = &state,
    };

    try app.run(root.widget(), .{});
}

const RootWidget = struct {
    state: *app_state.AppState,

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
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
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
                        self.state.dispatch(.{ .set_status = selected.id });
                    }
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
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
        for (self.state.tasks[0..@min(self.state.tasks.len, max_rows)], 0..) |item, index| {
            const row: u16 = rect.y + 1 + @as(u16, @intCast(index));
            const marker = if (index == self.state.selected_task) ">" else " ";
            widgets.writeText(surface, row, rect.x + 2, marker);
            widgets.writeTextClipped(surface, row, rect.x + 4, item.label, max_width);
        }
    }

    fn drawOutput(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
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

    fn drawStatus(self: *RootWidget, surface: vxfw.Surface, rect: layout.Rect) void {
        widgets.drawBox(surface, rect, "Status");
        if (rect.height == 0 or rect.width <= 4) return;

        const status = if (self.state.status_message.len > 0) self.state.status_message else "ready";
        widgets.writeTextClipped(surface, rect.y + 1, rect.x + 2, self.state.project_root, rect.width - 4);
        if (rect.height > 2) {
            widgets.writeTextClipped(surface, rect.y + 2, rect.x + 2, "Enter select  j/k move  q quit  status: ", rect.width - 4);
            widgets.writeTextClipped(surface, rect.y + 2, rect.x + 43, status, rect.width - 4);
        }
    }
};
