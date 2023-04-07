const std = @import("std");
const LibExeObjStep = std.build.LibExeObjStep;
const ScdocStep = @import("src/build/ScdocStep.zig");

/// DEPRECATED: This is the old std.build.Pkg for older versions of Zig.
/// I won't keep this around too long but there is no harm in exposing it
/// for now since our code works with older versions just fine (for now).
pub const pkg = std.build.Pkg{
    .name = "xev",
    .source = .{ .path = thisDir() ++ "/src/main.zig" },
};

/// Returns the module for libxev. The recommended approach is to depend
/// on libxev in your build.zig.zon file, then use
/// `b.dependency("libxev").module("xev")`. But if you're not using
/// a build.zig.zon yet this will work.
pub fn module(b: *std.Build) *std.Build.Module {
    return b.createModule(.{
        .source_file = .{ .path = (comptime thisDir()) ++ "/src/main.zig" },
    });
}

pub fn build(b: *std.Build) !void {
    // Modules available to downstream dependencies
    _ = b.addModule("xev", .{
        .source_file = .{ .path = (comptime thisDir()) ++ "/src/main.zig" },
    });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const man_pages = b.option(
        bool,
        "man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse if (b.findProgram(&[_][]const u8{"scdoc"}, &[_][]const u8{})) |_|
        true
    else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };

    const bench_name = b.option(
        []const u8,
        "bench-name",
        "Build and install a single benchmark",
    );

    const bench_install = b.option(
        bool,
        "bench",
        "Install the benchmark binaries to zig-out/bench",
    ) orelse (bench_name != null);

    const example_name = b.option(
        []const u8,
        "example-name",
        "Build and install a single example",
    );

    const example_install = b.option(
        bool,
        "example",
        "Install the example binaries to zig-out/example",
    ) orelse (example_name != null);

    const test_install = b.option(
        bool,
        "install-tests",
        "Install the test binaries into zig-out",
    ) orelse false;

    // Our tests require libc on Linux and Mac. Note that libxev itself
    // does NOT require libc.
    const test_libc = switch (target.getOsTag()) {
        .linux, .macos => true,
        else => false,
    };

    // We always build our test exe as part of `zig build` so that
    // we can easily run it manually without digging through the cache.
    const test_exe = b.addTest(.{
        .name = "xev-test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    if (test_libc) test_exe.linkLibC(); // Tests depend on libc, libxev does not
    if (test_install) test_exe.install();

    // zig build test test binary and runner.
    const tests_run = test_exe.run();
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);

    // Static C lib
    const static_c_lib: ?*std.build.LibExeObjStep = if (target.getOsTag() != .wasi) lib: {
        const static_lib = b.addStaticLibrary(.{
            .name = "xev",
            .root_source_file = .{ .path = "src/c_api.zig" },
            .target = target,
            .optimize = optimize,
        });
        static_lib.install();
        static_lib.linkLibC();
        b.default_step.dependOn(&static_lib.step);

        const static_binding_test = b.addExecutable(.{
            .name = "static-binding-test",
            .target = target,
            .optimize = optimize,
        });
        static_binding_test.linkLibC();
        static_binding_test.addIncludePath("include");
        static_binding_test.addCSourceFile("examples/_basic.c", &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99", "-D_POSIX_C_SOURCE=199309L" });
        static_binding_test.linkLibrary(static_lib);
        if (test_install) static_binding_test.install();

        const static_binding_test_run = static_binding_test.run();
        test_step.dependOn(&static_binding_test_run.step);

        break :lib static_lib;
    } else null;

    // Dynamic C lib. We only build this if this is the native target so we
    // can link to libxml2 on our native system.
    if (target.isNative()) {
        const dynamic_lib_name = if (target.isWindows())
            "xev.dll"
        else
            "xev";

        const dynamic_lib = b.addSharedLibrary(.{
            .name = dynamic_lib_name,
            .root_source_file = .{ .path = "src/c_api.zig" },
            .target = target,
            .optimize = optimize,
        });
        dynamic_lib.install();
        b.default_step.dependOn(&dynamic_lib.step);

        const dynamic_binding_test = b.addExecutable(.{
            .name = "dynamic-binding-test",
            .target = target,
            .optimize = optimize,
        });
        dynamic_binding_test.linkLibC();
        dynamic_binding_test.addIncludePath("include");
        dynamic_binding_test.addCSourceFile("examples/_basic.c", &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99" });
        dynamic_binding_test.linkLibrary(dynamic_lib);
        if (test_install) dynamic_binding_test.install();

        const dynamic_binding_test_run = dynamic_binding_test.run();
        test_step.dependOn(&dynamic_binding_test_run.step);
    }

    // C Headers
    const c_header = b.addInstallFileWithDir(
        .{ .path = "include/xev.h" },
        .header,
        "xev.h",
    );
    b.getInstallStep().dependOn(&c_header.step);

    // pkg-config
    {
        const file = try b.cache_root.join(b.allocator, &[_][]const u8{"libxev.pc"});
        const pkgconfig_file = try std.fs.cwd().createFile(file, .{});

        const writer = pkgconfig_file.writer();
        try writer.print(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: libxev
            \\URL: https://github.com/mitchellh/libxev
            \\Description: High-performance, cross-platform event loop
            \\Version: 0.1.0
            \\Cflags: -I${{includedir}}
            \\Libs: -L${{libdir}} -lxev
        , .{b.install_prefix});
        defer pkgconfig_file.close();

        b.installFile(file, "share/pkgconfig/libxev.pc");
    }
    // Benchmarks
    _ = try benchTargets(b, target, optimize, bench_install, bench_name);

    // Examples
    _ = try exampleTargets(b, target, optimize, static_c_lib, example_install, example_name);

    // Man pages
    if (man_pages) {
        const scdoc_step = ScdocStep.create(b);
        try scdoc_step.install();
    }
}

fn benchTargets(
    b: *std.Build,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
    install: bool,
    install_name: ?[]const u8,
) !std.StringHashMap(*LibExeObjStep) {
    _ = mode;

    var map = std.StringHashMap(*LibExeObjStep).init(b.allocator);

    // Open the directory
    const c_dir_path = (comptime thisDir()) ++ "/src/bench";
    var c_dir = try std.fs.openIterableDirAbsolute(c_dir_path, .{});
    defer c_dir.close();

    // Go through and add each as a step
    var c_dir_it = c_dir.iterate();
    while (try c_dir_it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (index == 0) continue;

        // Name of the app and full path to the entrypoint.
        const name = entry.name[0..index];
        const path = try std.fs.path.join(b.allocator, &[_][]const u8{
            c_dir_path,
            entry.name,
        });

        // If we have specified a specific name, only install that one.
        if (install_name) |n| {
            if (!std.mem.eql(u8, n, name)) continue;
        }

        // Executable builder.
        const c_exe = b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = path },
            .target = target,
            .optimize = .ReleaseFast, // benchmarks are always release fast
        });
        c_exe.addModule("xev", module(b));
        c_exe.setOutputDir("zig-out/bench");
        if (install) c_exe.install();

        // Store the mapping
        try map.put(try b.allocator.dupe(u8, name), c_exe);
    }

    return map;
}

fn exampleTargets(
    b: *std.Build,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    c_lib_: ?*std.build.LibExeObjStep,
    install: bool,
    install_name: ?[]const u8,
) !void {
    // Ignore if we're not installing
    if (!install) return;

    // Open the directory
    const c_dir_path = (comptime thisDir()) ++ "/examples";
    var c_dir = try std.fs.openIterableDirAbsolute(c_dir_path, .{});
    defer c_dir.close();

    // Go through and add each as a step
    var c_dir_it = c_dir.iterate();
    while (try c_dir_it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (index == 0) continue;

        // If we have specified a specific name, only install that one.
        if (install_name) |n| {
            if (!std.mem.eql(u8, n, entry.name)) continue;
        }

        // Name of the app and full path to the entrypoint.
        const name = entry.name[0..index];
        const path = try std.fs.path.join(b.allocator, &[_][]const u8{
            c_dir_path,
            entry.name,
        });

        const is_zig = std.mem.eql(u8, entry.name[index + 1 ..], "zig");
        if (is_zig) {
            const c_exe = b.addExecutable(.{
                .name = name,
                .root_source_file = .{ .path = path },
                .target = target,
                .optimize = optimize,
            });
            c_exe.addModule("xev", module(b));
            c_exe.setOutputDir("zig-out/example");
            if (install) c_exe.install();
        } else {
            const c_lib = c_lib_ orelse return error.UnsupportedPlatform;
            const c_exe = b.addExecutable(.{
                .name = name,
                .target = target,
                .optimize = optimize,
            });
            c_exe.linkLibC();
            c_exe.addIncludePath("include");
            c_exe.addCSourceFile(path, &[_][]const u8{
                "-Wall",
                "-Wextra",
                "-pedantic",
                "-std=c99",
                "-D_POSIX_C_SOURCE=199309L",
            });
            c_exe.linkLibrary(c_lib);
            c_exe.setOutputDir("zig-out/example");
            if (install) c_exe.install();
        }
    }
}

/// Path to the directory with the build.zig.
fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}
