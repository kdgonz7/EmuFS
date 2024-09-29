const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const targetOptions = b.standardTargetOptions(.{});
    const optimizingOptions = b.standardOptimizeOption(.{});

    const unitTests = b.addTest(.{
        .root_source_file = b.path("Source/filesystem.zig"),
        .target = targetOptions,
        .optimize = optimizingOptions,
    });

    const unitTestRunner = b.addRunArtifact(unitTests);

    const testStep = b.step("test", "Run unit tests");
    testStep.dependOn(&unitTestRunner.step);
}
