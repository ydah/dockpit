const std = @import("std");

pub const TaskSource = enum {
    config,
    zig,
    make,
    just,
    npm,
    pnpm,
    yarn,
    bun,
    deno,
    cargo,
    go,
    python,
    ruby,
    nix,
    mise,
    taskfile,
    docker,

    pub fn label(source: TaskSource) []const u8 {
        return switch (source) {
            .config => "config",
            .zig => "zig",
            .make => "make",
            .just => "just",
            .npm => "npm",
            .pnpm => "pnpm",
            .yarn => "yarn",
            .bun => "bun",
            .deno => "deno",
            .cargo => "cargo",
            .go => "go",
            .python => "python",
            .ruby => "ruby",
            .nix => "nix",
            .mise => "mise",
            .taskfile => "taskfile",
            .docker => "docker",
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
    description: []const u8 = "",
    group: []const u8 = "",
    default_task: bool = false,
    watch: bool = true,
    inherit_env: bool = true,
    timeout_ms: ?u64 = null,
    max_output_bytes: ?usize = null,

    pub fn commandEquals(a: TaskSpec, b: TaskSpec) bool {
        if (!std.mem.eql(u8, a.cwd, b.cwd)) return false;
        if (a.argv.len != b.argv.len) return false;

        for (a.argv, b.argv) |a_arg, b_arg| {
            if (!std.mem.eql(u8, a_arg, b_arg)) return false;
        }

        return true;
    }

    pub fn deinit(self: TaskSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        allocator.free(self.cwd);
        for (self.env) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        allocator.free(self.env);
        allocator.free(self.description);
        allocator.free(self.group);
    }
};

test "task source labels are stable" {
    try std.testing.expectEqualStrings("config", TaskSource.config.label());
    try std.testing.expectEqualStrings("zig", TaskSource.zig.label());
    try std.testing.expectEqualStrings("pnpm", TaskSource.pnpm.label());
    try std.testing.expectEqualStrings("docker", TaskSource.docker.label());
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
