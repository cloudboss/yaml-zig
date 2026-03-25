const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const yaml_mod = b.addModule("yaml", .{
        .root_source_file = b.path("src/yaml.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "yaml",
        .root_module = yaml_mod,
    });
    b.installArtifact(lib);

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = yaml_mod,
    });

    if (b.lazyDependency("zest", .{})) |zest_dep| {
        tests.root_module.addImport(
            "zest",
            zest_dep.module("zest"),
        );
        tests.test_runner = .{
            .path = zest_dep.module("zest")
                .root_source_file.?,
            .mode = .simple,
        };
    }

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const docs_step = b.step("docs", "Generate documentation");
    const docs = b.addObject(.{
        .name = "yaml",
        .root_module = yaml_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);
}
