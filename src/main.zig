const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll("dockpit\n");
    try stdout.flush();
}
