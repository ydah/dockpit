const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.step("fmt", "Format sources");
    _ = b.step("test", "Run tests");
    _ = b.step("release-safe", "Build with ReleaseSafe");
    // _ = b.step("ignored", "Commented step");
}
