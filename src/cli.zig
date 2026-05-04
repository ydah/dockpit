const std = @import("std");

pub const CliError = error{
    MissingValue,
    UnknownOption,
};

pub const Options = struct {
    project_dir: ?[]const u8 = null,
    config_path: []const u8 = ".dockpit.json",
    print_tasks: bool = false,
    run_task_id: ?[]const u8 = null,
    no_git: bool = false,
    strict_config: bool = false,
    help: bool = false,
    version: bool = false,
};

pub fn parse(args: []const []const u8) CliError!Options {
    var options: Options = .{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            options.version = true;
        } else if (std.mem.eql(u8, arg, "--print-tasks")) {
            options.print_tasks = true;
        } else if (std.mem.eql(u8, arg, "--no-git")) {
            options.no_git = true;
        } else if (std.mem.eql(u8, arg, "--strict-config")) {
            options.strict_config = true;
        } else if (std.mem.eql(u8, arg, "--project-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.project_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--run")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.run_task_id = args[i];
        } else {
            return error.UnknownOption;
        }
    }

    return options;
}

test "parse default options" {
    const args = [_][]const u8{"dockpit"};
    const options = try parse(&args);

    try std.testing.expectEqual(@as(?[]const u8, null), options.project_dir);
    try std.testing.expectEqualStrings(".dockpit.json", options.config_path);
    try std.testing.expect(!options.print_tasks);
    try std.testing.expect(!options.no_git);
    try std.testing.expect(!options.strict_config);
}

test "parse supported flags and values" {
    const args = [_][]const u8{
        "dockpit",
        "--project-dir",
        "sample",
        "--config",
        "tasks.json",
        "--print-tasks",
        "--run",
        "zig-build",
        "--no-git",
        "--strict-config",
    };
    const options = try parse(&args);

    try std.testing.expectEqualStrings("sample", options.project_dir.?);
    try std.testing.expectEqualStrings("tasks.json", options.config_path);
    try std.testing.expect(options.print_tasks);
    try std.testing.expectEqualStrings("zig-build", options.run_task_id.?);
    try std.testing.expect(options.no_git);
    try std.testing.expect(options.strict_config);
}

test "parse help and version" {
    const args = [_][]const u8{ "dockpit", "--help", "--version" };
    const options = try parse(&args);

    try std.testing.expect(options.help);
    try std.testing.expect(options.version);
}

test "parse rejects unknown option" {
    const args = [_][]const u8{ "dockpit", "--wat" };

    try std.testing.expectError(error.UnknownOption, parse(&args));
}

test "parse rejects missing value" {
    const args = [_][]const u8{ "dockpit", "--run" };

    try std.testing.expectError(error.MissingValue, parse(&args));
}
