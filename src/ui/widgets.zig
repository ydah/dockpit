const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const layout = @import("layout.zig");

pub fn drawBox(surface: vxfw.Surface, rect: layout.Rect, title: []const u8) void {
    if (rect.width < 2 or rect.height < 2) return;

    const right = rect.x + rect.width - 1;
    const bottom = rect.y + rect.height - 1;

    writeText(surface, rect.y, rect.x, "+");
    writeText(surface, rect.y, right, "+");
    writeText(surface, bottom, rect.x, "+");
    writeText(surface, bottom, right, "+");

    var x = rect.x + 1;
    while (x < right) : (x += 1) {
        writeText(surface, rect.y, x, "-");
        writeText(surface, bottom, x, "-");
    }

    var y = rect.y + 1;
    while (y < bottom) : (y += 1) {
        writeText(surface, y, rect.x, "|");
        writeText(surface, y, right, "|");
    }

    if (title.len > 0 and rect.width > 4) {
        writeTextClipped(surface, rect.y, rect.x + 2, title, rect.width - 4);
    }
}

pub fn writeText(surface: vxfw.Surface, row: u16, col: u16, text: []const u8) void {
    writeTextClipped(surface, row, col, text, surface.size.width);
}

pub fn writeTextClipped(surface: vxfw.Surface, row: u16, col: u16, text: []const u8, max_width: u16) void {
    if (row >= surface.size.height or col >= surface.size.width) return;

    var current_col = col;
    var written: u16 = 0;
    for (text, 0..) |_, index| {
        if (written >= max_width or current_col >= surface.size.width) return;
        surface.writeCell(current_col, row, .{
            .char = .{
                .grapheme = text[index .. index + 1],
                .width = 1,
            },
        });
        current_col += 1;
        written += 1;
    }
}
