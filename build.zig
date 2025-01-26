const std = @import("std");
const CompileStep = std.build.Step.Compile;

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
    _ = bench(b, target, "src/bench/async1.zig");
    _ = bench(b, target, "src/bench/async2.zig");
    _ = bench(b, target, "src/bench/async4.zig");
    _ = bench(b, target, "src/bench/async8.zig");
    _ = bench(b, target, "src/bench/async_pummel_1.zig");
    _ = bench(b, target, "src/bench/async_pummel_2.zig");
    _ = bench(b, target, "src/bench/async_pummel_4.zig");
    _ = bench(b, target, "src/bench/async_pummel_8.zig");
    _ = bench(b, target, "src/bench/million-timers.zig");
    _ = bench(b, target, "src/bench/ping-pongs.zig");
    _ = bench(b, target, "src/bench/ping-udp1.zig");
    _ = bench(b, target, "src/bench/udp_pummel_1v1.zig");

    // Examples
    example(b, target, optimize, "examples/_basic.zig");

    if (static_c_lib) |c_lib| {
        c_example(b, target, optimize, c_lib, "examples/_basic.c");
        c_example(b, target, optimize, c_lib, "examples/async.c");
        c_example(b, target, optimize, c_lib, "examples/million-timers.c");
        c_example(b, target, optimize, c_lib, "examples/threadpool.c");
    }

    const install_docs_step = b.step("docs", "Generate and install docs");
    install_docs_step.dependOn(&scdoc(b, "docs/xev.7.scd").step);
    install_docs_step.dependOn(&scdoc(b, "docs/xev-c.7.scd").step);
    install_docs_step.dependOn(&scdoc(b, "docs/xev-faq.7.scd").step);
    install_docs_step.dependOn(&scdoc(b, "docs/xev-zig.7.scd").step);
    install_docs_step.dependOn(&scdoc(b, "docs/xev_completion_state.3.scd").step);
    install_docs_step.dependOn(&scdoc(b, "docs/xev_completion_zero.3.scd").step);
    install_docs_step.dependOn(&scdoc(b, "docs/xev_threadpool.3.scd").step);

    // Man pages
    if (man_pages) {
        b.default_step.dependOn(install_docs_step);
    }
}

fn bench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    sub_path: []const u8,
) *std.Build.Step.Compile {
    // Name of the app
    const name = std.fs.path.stem(sub_path);

    // Executable builder.
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(sub_path),
        .target = target,
        .optimize = .ReleaseFast, // benchmarks are always release fast
    });
    exe.root_module.addImport("xev", b.modules.get("xev").?);

    const install_artifact = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "bench" } },
    });
    const install_step = b.step(name, b.fmt("install {s} benchmark", .{name}));
    install_step.dependOn(&install_artifact.step);
    b.getInstallStep().dependOn(install_step);

    return exe;
}

fn example(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sub_path: []const u8,
) void {
    // Name of the app
    const name = std.fs.path.basename(sub_path);

    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(sub_path),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("xev", b.modules.get("xev").?);

    const install_artifact = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "example" } },
    });
    const install_step = b.step(name, b.fmt("install {s} example", .{name}));
    install_step.dependOn(&install_artifact.step);
    b.getInstallStep().dependOn(install_step);
}

fn c_example(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_lib: *std.Build.Step.Compile,
    sub_path: []const u8,
) void {
    // Name of the app
    const name = std.fs.path.basename(sub_path);

    const c_exe = b.addExecutable(.{
        .name = name,
        .target = target,
        .optimize = optimize,
    });
    c_exe.linkLibC();
    c_exe.addIncludePath(b.path("include"));
    c_exe.addCSourceFile(.{
        .file = b.path(sub_path),
        .flags = &[_][]const u8{
            "-Wall",
            "-Wextra",
            "-pedantic",
            "-std=c99",
            "-D_POSIX_C_SOURCE=199309L",
        },
    });
    c_exe.linkLibrary(c_lib);

    const install_artifact = b.addInstallArtifact(c_exe, .{
        .dest_dir = .{ .override = .{ .custom = "example" } },
    });
    const install_step = b.step(name, b.fmt("install {s} example", .{name}));
    install_step.dependOn(&install_artifact.step);
    b.getInstallStep().dependOn(install_step);
}

fn scdoc(
    b: *std.Build,
    src_path: []const u8,
) *std.Build.Step.InstallFile {
    // We expect filenames to be "foo.3.scd" and this gets us "foo.3"
    const src_filename = std.fs.path.basename(src_path);
    const src_stem = std.fs.path.stem(src_filename);
    const src_extension = std.fs.path.extension(src_stem); // this gets ".3"

    const section = src_extension[1..];

    const output_path = b.fmt(
        "share/man/man{s}/{s}",
        .{ section, src_filename },
    );

    const run_scdoc = b.addSystemCommand(&.{"scdoc"});
    run_scdoc.setStdIn(.{ .lazy_path = b.path(src_path) });

    return b.addInstallFile(run_scdoc.captureStdOut(), output_path);
}
