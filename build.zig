const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("jevlin", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run offline contract and fault tests");
    test_step.dependOn(&run.step);
    const fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("fuzz", "Run bounded parser/encoder mutation campaigns without sockets").dependOn(&b.addRunArtifact(fuzz_tests).step);
    const example = b.addExecutable(.{ .name = "jevlin-triage", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/triage.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jevlin", .module = module }},
    }) });
    b.installArtifact(example);
    const live = b.addRunArtifact(example);
    live.has_side_effects = true;
    b.step("live", "Run one billable API call using TYPESAFE_API_KEY").dependOn(&live.step);
    const fmt = b.addFmt(.{ .paths = &.{ "src", "examples", "build.zig" }, .check = true });
    const check = b.step("check", "Check formatting, tests, and example compilation");
    check.dependOn(&fmt.step);
    check.dependOn(test_step);
    check.dependOn(&example.step);
}
