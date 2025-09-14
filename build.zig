const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (@hasDecl(std.Build, "CreateModuleOptions")) {
        // Zig 0.11
        _ = b.addModule("regex", .{
            .source_file = .{ .path = "src/regex.zig" },
        });
    } else {
        // Zig 0.12-dev.2159
        _ = b.addModule("regex", .{
            .root_source_file = path(b, "src/regex.zig"),
        });
    }

    // library tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const library_tests = b.addTest(.{
        .name = "library_tests",
        .root_module = test_module,
    });
    const run_library_tests = b.addRunArtifact(library_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_library_tests.step);

    // TODO: Fix library creation for zig 0.15.1
    // C library and example are temporarily disabled due to API changes
    //
    // // C library - create object files that can be linked as libraries
    // const staticLib = b.addObject(.{
    //     .name = "regex",
    //     .root_source_file = path(b, "src/c_regex.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // staticLib.root_module.link_libc = true;
    // b.installArtifact(staticLib);
    //
    // const sharedLib = b.addObject(.{
    //     .name = "regex_shared",
    //     .root_source_file = path(b, "src/c_regex.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // sharedLib.root_module.link_libc = true;
    // b.installArtifact(sharedLib);
    //
    // // C example
    // const c_example = b.addExecutable(.{
    //     .name = "example",
    //     .target = target,
    //     .optimize = optimize,
    // });
    // c_example.addCSourceFile(.{
    //     .file = path(b, "example/example.c"),
    //     .flags = &.{"-Wall"},
    // });
    // c_example.addIncludePath(path(b, "include"));
    // c_example.linkLibC();
    // c_example.linkLibrary(staticLib);
    //
    // const c_example_step = b.step("c-example", "Example using C API");
    // c_example_step.dependOn(&staticLib.step);
    // c_example_step.dependOn(&c_example.step);

    b.default_step.dependOn(test_step);
}

fn path(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    if (@hasDecl(std.Build, "path")) {
        // Zig 0.13-dev.267
        return b.path(sub_path);
    } else {
        return .{ .path = sub_path };
    }
}
