const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("jevlin", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run offline contract and fault tests");
    test_step.dependOn(&run.step);
    const fuzz_target = b.option(enum { all, parser, encoder }, "fuzz-target", "Select a standalone fuzz oracle") orelse .all;
    const fuzz_tests = b.addTest(.{
        .filters = switch (fuzz_target) {
            .all => &.{},
            .parser => &.{"fuzz parser and typed decoder"},
            .encoder => &.{"fuzz request encoder"},
        },
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            // Zig 0.16.0's fuzz runner uses the wrong error-return trace type.
            // Disable only return tracing; safety checks and fuzz instrumentation stay on.
            .error_tracing = b.option(bool, "fuzz-error-tracing", "Enable error-return traces in the standalone fuzz target") orelse false,
        }),
        // The default x86 backend produced an empty PC table with -ffuzz on 0.16.0.
        .use_llvm = true,
    });
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
    const examples = b.step("examples", "Run offline public API examples and compatibility contract");
    for ([_][]const u8{ "structured", "errors_and_buffers", "parallel", "api_contract" }) |name| {
        const offline = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "jevlin", .module = module }},
        }) });
        examples.dependOn(&b.addRunArtifact(offline).step);
    }
    check.dependOn(examples);
}
