const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const task = @import("../core/task.zig");

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

    var root = RootWidget{
        .project_root = project_root,
        .task_count = try std.fmt.allocPrint(allocator, "{d}", .{tasks.len}),
    };

    try app.run(root.widget(), .{});
}

const RootWidget = struct {
    project_root: []const u8,
    task_count: []const u8,

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
        _ = self;
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    ctx.consume_event = true;
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

        writeLine(surface, 1, 2, "dockpit");
        writeLine(surface, 3, 2, "project: ");
        writeLine(surface, 3, 11, self.project_root);
        writeLine(surface, 4, 2, "detected tasks: ");
        writeLine(surface, 4, 18, self.task_count);
        writeLine(surface, 6, 2, "q quit");

        return surface;
    }
};

fn writeLine(surface: vxfw.Surface, row: u16, col: u16, text: []const u8) void {
    var current_col = col;
    for (text, 0..) |_, index| {
        if (current_col >= surface.size.width) return;
        surface.writeCell(current_col, row, .{
            .char = .{
                .grapheme = text[index .. index + 1],
                .width = 1,
            },
        });
        current_col += 1;
    }
}
