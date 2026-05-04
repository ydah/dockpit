const std = @import("std");

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const Layout = struct {
    tasks: Rect,
    output: Rect,
    status: Rect,
};

pub fn compute(width: u16, height: u16) Layout {
    const status_height: u16 = if (height >= 10) 4 else 1;
    const body_height = height - status_height;
    const tasks_width: u16 = if (width >= 72) 30 else @max(12, width / 3);
    const output_width = width - @min(width, tasks_width);

    return .{
        .tasks = .{
            .x = 0,
            .y = 0,
            .width = @min(width, tasks_width),
            .height = body_height,
        },
        .output = .{
            .x = @min(width, tasks_width),
            .y = 0,
            .width = output_width,
            .height = body_height,
        },
        .status = .{
            .x = 0,
            .y = body_height,
            .width = width,
            .height = status_height,
        },
    };
}

test "layout splits wide screens into task output and status panes" {
    const result = compute(100, 30);

    try std.testing.expectEqual(@as(u16, 30), result.tasks.width);
    try std.testing.expectEqual(@as(u16, 70), result.output.width);
    try std.testing.expectEqual(@as(u16, 4), result.status.height);
    try std.testing.expectEqual(@as(u16, 26), result.status.y);
}

test "layout handles narrow screens without underflow" {
    const result = compute(20, 5);

    try std.testing.expectEqual(@as(u16, 12), result.tasks.width);
    try std.testing.expectEqual(@as(u16, 8), result.output.width);
    try std.testing.expectEqual(@as(u16, 1), result.status.height);
}
