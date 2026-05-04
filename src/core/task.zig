const std = @import("std");

pub const TaskSource = enum {
    config,
    zig,
    make,
    just,
    npm,
    cargo,
    go,

    pub fn label(source: TaskSource) []const u8 {
        return switch (source) {
            .config => "config",
            .zig => "zig",
            .make => "make",
            .just => "just",
            .npm => "npm",
            .cargo => "cargo",
            .go => "go",
        };
    }
};

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const TaskSpec = struct {
    id: []const u8,
    label: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    source: TaskSource,
    env: []const EnvVar = &.{},

    pub fn commandEquals(a: TaskSpec, b: TaskSpec) bool {
        if (a.argv.len != b.argv.len) return false;

        for (a.argv, b.argv) |a_arg, b_arg| {
            if (!std.mem.eql(u8, a_arg, b_arg)) return false;
        }

        return true;
    }
};

test "task source labels are stable" {
    try std.testing.expectEqualStrings("config", TaskSource.config.label());
    try std.testing.expectEqualStrings("zig", TaskSource.zig.label());
}

test "task command equality compares argv exactly" {
    const build_a = TaskSpec{
        .id = "zig-build",
        .label = "zig build",
        .argv = &.{ "zig", "build" },
        .cwd = ".",
        .source = .zig,
    };
    const build_b = TaskSpec{
        .id = "build",
        .label = "build",
        .argv = &.{ "zig", "build" },
        .cwd = ".",
        .source = .config,
    };
    const test_task = TaskSpec{
        .id = "zig-test",
        .label = "zig build test",
        .argv = &.{ "zig", "build", "test" },
        .cwd = ".",
        .source = .zig,
    };

    try std.testing.expect(build_a.commandEquals(build_b));
    try std.testing.expect(!build_a.commandEquals(test_task));
}
