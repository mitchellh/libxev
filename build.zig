const std = @import("std");
const CompileStep = std.build.Step.Compile;
const ScdocStep = @import("src/build/ScdocStep.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("xev", .{ .root_source_file = b.path("src/main.zig") });

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
    const test_libc = switch (target.result.os.tag) {
        .linux, .macos => true,
        else => false,
    };

    // We always build our test exe as part of `zig build` so that
    // we can easily run it manually without digging through the cache.
    const test_exe = b.addTest(.{
        .name = "xev-test",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (test_libc) test_exe.linkLibC(); // Tests depend on libc, libxev does not
    if (test_install) b.installArtifact(test_exe);

    // zig build test test binary and runner.
    const tests_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);

    // Static C lib
    const static_c_lib: ?*std.Build.Step.Compile = if (target.result.os.tag != .wasi) lib: {
        const static_lib = b.addStaticLibrary(.{
            .name = "xev",
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
        });

        static_lib.linkLibC();

        // Link required libraries if targeting Windows
        if (target.result.os.tag == .windows) {
            static_lib.linkSystemLibrary("ws2_32");
            static_lib.linkSystemLibrary("mswsock");
        }

        b.installArtifact(static_lib);
        b.default_step.dependOn(&static_lib.step);

        const static_binding_test = b.addExecutable(.{
            .name = "static-binding-test",
            .target = target,
            .optimize = optimize,
        });
        static_binding_test.linkLibC();
        static_binding_test.addIncludePath(b.path("include"));
        static_binding_test.addCSourceFile(.{
            .file = b.path("examples/_basic.c"),
            .flags = &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99", "-D_POSIX_C_SOURCE=199309L" },
        });
        static_binding_test.linkLibrary(static_lib);
        if (test_install) b.installArtifact(static_binding_test);

        const static_binding_test_run = b.addRunArtifact(static_binding_test);
        test_step.dependOn(&static_binding_test_run.step);

        break :lib static_lib;
    } else null;

    // Dynamic C lib. We only build this if this is the native target so we
    // can link to libxml2 on our native system.
    if (target.query.isNative()) {
        const dynamic_lib_name = "xev";

        const dynamic_lib = b.addSharedLibrary(.{
            .name = dynamic_lib_name,
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(dynamic_lib);
        b.default_step.dependOn(&dynamic_lib.step);

        const dynamic_binding_test = b.addExecutable(.{
            .name = "dynamic-binding-test",
            .target = target,
            .optimize = optimize,
        });
        dynamic_binding_test.linkLibC();
        dynamic_binding_test.addIncludePath(b.path("include"));
        dynamic_binding_test.addCSourceFile(.{
            .file = b.path("examples/_basic.c"),
            .flags = &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99" },
        });
        dynamic_binding_test.linkLibrary(dynamic_lib);
        if (test_install) b.installArtifact(dynamic_binding_test);

        const dynamic_binding_test_run = b.addRunArtifact(dynamic_binding_test);
        test_step.dependOn(&dynamic_binding_test_run.step);
    }

    // C Headers
    const c_header = b.addInstallFileWithDir(
        b.path("include/xev.h"),
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

        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            .{ .cwd_relative = file },
            .prefix,
            "share/pkgconfig/libxev.pc",
        ).step);
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
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
    install: bool,
    install_name: ?[]const u8,
) !std.StringHashMap(*std.Build.Step.Compile) {
    _ = mode;

    var map = std.StringHashMap(*std.Build.Step.Compile).init(b.allocator);

    // Open the directory
    const c_dir_path = "src/bench";
    var c_dir = try std.fs.cwd().openDir(comptime thisDir() ++ "/" ++ c_dir_path, .{ .iterate = true });
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
            .root_source_file = b.path(path),
            .target = target,
            .optimize = .ReleaseFast, // benchmarks are always release fast
        });
        c_exe.root_module.addImport("xev", b.modules.get("xev").?);
        if (install) {
            const install_step = b.addInstallArtifact(c_exe, .{
                .dest_dir = .{ .override = .{ .custom = "bench" } },
            });
            b.getInstallStep().dependOn(&install_step.step);
        }

        // Store the mapping
        try map.put(try b.allocator.dupe(u8, name), c_exe);
    }

    return map;
}

fn exampleTargets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_lib_: ?*std.Build.Step.Compile,
    install: bool,
    install_name: ?[]const u8,
) !void {
    // Ignore if we're not installing
    if (!install) return;

    // Open the directory
    const c_dir_path = (comptime thisDir()) ++ "/examples";
    var c_dir = try std.fs.cwd().openDir(c_dir_path, .{ .iterate = true });
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
                .root_source_file = .{ .cwd_relative = path },
                .target = target,
                .optimize = optimize,
            });
            c_exe.root_module.addImport("xev", b.modules.get("xev").?);
            if (install) {
                const install_step = b.addInstallArtifact(c_exe, .{
                    .dest_dir = .{ .override = .{ .custom = "example" } },
                });
                b.getInstallStep().dependOn(&install_step.step);
            }
        } else {
            const c_lib = c_lib_ orelse return error.UnsupportedPlatform;
            const c_exe = b.addExecutable(.{
                .name = name,
                .target = target,
                .optimize = optimize,
            });
            c_exe.linkLibC();
            c_exe.addIncludePath(b.path("include"));
            c_exe.addCSourceFile(.{
                .file = .{ .cwd_relative = path },
                .flags = &[_][]const u8{
                    "-Wall",
                    "-Wextra",
                    "-pedantic",
                    "-std=c99",
                    "-D_POSIX_C_SOURCE=199309L",
                },
            });
            c_exe.linkLibrary(c_lib);
            if (install) {
                const install_step = b.addInstallArtifact(c_exe, .{
                    .dest_dir = .{ .override = .{ .custom = "example" } },
                });
                b.getInstallStep().dependOn(&install_step.step);
            }
        }

        // If we have specified a specific name, only install that one.
        if (install_name) |_| break;
    } else {
        if (install_name) |n| {
            std.debug.print("No example file named: {s}\n", .{n});
            std.debug.print("Choices:\n", .{});
            var c_dir_it2 = c_dir.iterate();
            while (try c_dir_it2.next()) |entry| {
                std.debug.print("\t{s}\n", .{entry.name});
            }
            return error.InvalidExampleName;
        }
    }
}

/// Path to the directory with the build.zig.
fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}
