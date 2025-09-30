const std = @import("std");
const Step = std.Build.Step;

/// A note on my build.zig style: I try to create all the artifacts first,
/// unattached to any steps. At the end of the build() function, I create
/// steps or attach unattached artifacts to predefined steps such as
/// install. This means the only thing affecting the `zig build` user
/// interaction is at the end of the build() file and makes it easier
/// to reason about the structure.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("xev", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const emit_man = b.option(
        bool,
        "emit-man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse if (b.findProgram(
        &[_][]const u8{"scdoc"},
        &[_][]const u8{},
    )) |_|
        true
    else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };

    const emit_bench = b.option(
        bool,
        "emit-bench",
        "Install the benchmark binaries to zig-out",
    ) orelse false;

    const emit_examples = b.option(
        bool,
        "emit-example",
        "Install the example binaries to zig-out",
    ) orelse false;

    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static C lib
    const static_lib: ?*Step.Compile = lib: {
        if (target.result.os.tag == .wasi) break :lib null;

        const static_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "xev",
            .root_module = c_api_module,
        });
        static_lib.linkLibC();
        if (target.result.os.tag == .windows) {
            static_lib.linkSystemLibrary("ws2_32");
            static_lib.linkSystemLibrary("mswsock");
        }
        break :lib static_lib;
    };

    // Dynamic C lib
    const dynamic_lib: ?*Step.Compile = lib: {
        // We require native so we can link to libxml2
        if (!target.query.isNative()) break :lib null;

        const dynamic_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "xev",
            .root_module = c_api_module,
        });
        break :lib dynamic_lib;
    };

    // C Headers
    const c_header = b.addInstallFileWithDir(
        b.path("include/xev.h"),
        .header,
        "xev.h",
    );

    // pkg-config
    const pc: *Step.InstallFile = pc: {
        const file = b.addWriteFile("libxev.pc", b.fmt(
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
        , .{b.install_prefix}));
        break :pc b.addInstallFileWithDir(
            file.getDirectory().path(b, "libxev.pc"),
            .prefix,
            "share/pkgconfig/libxev.pc",
        );
    };

    // Man pages
    const man = try manPages(b);

    // Benchmarks and examples
    const benchmarks = try buildBenchmarks(b, target);
    const examples = try buildExamples(b, target, optimize, static_lib);

    // Test Executable
    const test_exe: *Step.Compile = test_exe: {
        const test_filter = b.option(
            []const u8,
            "test-filter",
            "Filter for test",
        );
        const test_exe = b.addTest(.{
            .name = "xev-test",
            .filters = if (test_filter) |filter| &.{filter} else &.{},
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        switch (target.result.os.tag) {
            .linux, .macos => test_exe.linkLibC(),
            else => {},
        }
        break :test_exe test_exe;
    };

    // "test" Step
    {
        const tests_run = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);
    }

    if (static_lib) |v| b.installArtifact(v);
    if (dynamic_lib) |v| b.installArtifact(v);
    b.getInstallStep().dependOn(&c_header.step);
    b.getInstallStep().dependOn(&pc.step);
    b.installArtifact(test_exe);
    if (emit_man) {
        for (man) |step| b.getInstallStep().dependOn(step);
    }
    if (emit_bench) for (benchmarks) |exe| {
        b.getInstallStep().dependOn(&b.addInstallArtifact(
            exe,
            .{ .dest_dir = .{ .override = .{
                .custom = "bin/bench",
            } } },
        ).step);
    };
    if (emit_examples) for (examples) |exe| {
        b.getInstallStep().dependOn(&b.addInstallArtifact(
            exe,
            .{ .dest_dir = .{ .override = .{
                .custom = "bin/example",
            } } },
        ).step);
    };
}

fn buildBenchmarks(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ![]const *Step.Compile {
    const alloc = b.allocator;
    var steps: std.ArrayList(*Step.Compile) = .empty;
    defer steps.deinit(alloc);

    var dir = try std.fs.cwd().openDir(try b.build_root.join(
        b.allocator,
        &.{ "src", "bench" },
    ), .{ .iterate = true });
    defer dir.close();

    // Go through and add each as a step
    var it = dir.iterate();
    while (try it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(
            u8,
            entry.name,
            '.',
        ) orelse continue;
        if (index == 0) continue;

        // Name of the app and full path to the entrypoint.
        const name = entry.name[0..index];

        // Executable builder.
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt(
                    "src/bench/{s}",
                    .{entry.name},
                )),
                .target = target,
                .optimize = .ReleaseFast, // benchmarks are always release fast
            }),
        });
        exe.root_module.addImport("xev", b.modules.get("xev").?);

        // Store the mapping
        try steps.append(alloc, exe);
    }

    return try steps.toOwnedSlice(alloc);
}

fn buildExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_lib_: ?*Step.Compile,
) ![]const *Step.Compile {
    const alloc = b.allocator;
    var steps: std.ArrayList(*Step.Compile) = .empty;
    defer steps.deinit(alloc);

    var dir = try std.fs.cwd().openDir(try b.build_root.join(
        b.allocator,
        &.{"examples"},
    ), .{ .iterate = true });
    defer dir.close();

    // Go through and add each as a step
    var it = dir.iterate();
    while (try it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(
            u8,
            entry.name,
            '.',
        ) orelse continue;
        if (index == 0) continue;

        // Name of the app and full path to the entrypoint.
        const name = entry.name[0..index];

        const is_zig = std.mem.eql(u8, entry.name[index + 1 ..], "zig");
        const exe: *Step.Compile = if (is_zig) exe: {
            const exe = b.addExecutable(.{
                .name = name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt(
                        "examples/{s}",
                        .{entry.name},
                    )),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            exe.root_module.addImport("xev", b.modules.get("xev").?);
            break :exe exe;
        } else exe: {
            const c_lib = c_lib_ orelse return error.UnsupportedPlatform;
            const exe = b.addExecutable(.{
                .name = name,
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                }),
            });
            exe.linkLibC();
            exe.addIncludePath(b.path("include"));
            exe.addCSourceFile(.{
                .file = b.path(b.fmt(
                    "examples/{s}",
                    .{entry.name},
                )),
                .flags = &[_][]const u8{
                    "-Wall",
                    "-Wextra",
                    "-pedantic",
                    "-std=c99",
                    "-D_POSIX_C_SOURCE=199309L",
                },
            });
            exe.linkLibrary(c_lib);
            break :exe exe;
        };

        // Store the mapping
        try steps.append(alloc, exe);
    }

    return try steps.toOwnedSlice(alloc);
}

fn manPages(b: *std.Build) ![]const *Step {
    const alloc = b.allocator;
    var steps: std.ArrayList(*Step) = .empty;
    defer steps.deinit(alloc);

    var dir = try std.fs.cwd().openDir(try b.build_root.join(
        b.allocator,
        &.{"docs"},
    ), .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |*entry| {
        // Filenames must end in "{section}.scd" and sections are
        // single numerals.
        const base = entry.name[0 .. entry.name.len - 4];
        const section = base[base.len - 1 ..];

        const cmd = b.addSystemCommand(&.{"scdoc"});
        cmd.setStdIn(.{ .lazy_path = b.path(
            b.fmt("docs/{s}", .{entry.name}),
        ) });

        try steps.append(alloc, &b.addInstallFile(
            cmd.captureStdOut(),
            b.fmt("share/man/man{s}/{s}", .{ section, base }),
        ).step);
    }

    return try steps.toOwnedSlice(alloc);
}
