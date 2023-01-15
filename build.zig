const std = @import("std");
const LibExeObjStep = std.build.LibExeObjStep;

/// Use this with addPackage in your project.
pub const pkg = std.build.Pkg{
    .name = "xev",
    .source = .{ .path = thisDir() ++ "/src/main.zig" },
};

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const bench_install = b.option(
        bool,
        "bench",
        "Install the benchmark binaries to zig-out/bench",
    ) orelse (mode == .Debug);

    const bench_name = b.option(
        []const u8,
        "bench-name",
        "Build and install a single benchmark",
    );

    // We always build our test exe as part of `zig build` so that
    // we can easily run it manually without digging through the cache.
    const test_exe = b.addTestExe("xev-test", "src/main.zig");
    test_exe.setBuildMode(mode);
    test_exe.setTarget(target);
    test_exe.install();

    // zig build test test binary and runner.
    const tests_run = b.addTestSource(pkg.source);
    tests_run.setBuildMode(mode);
    tests_run.setTarget(target);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);

    _ = try benchTargets(b, target, mode, bench_install, bench_name);
}

fn benchTargets(
    b: *std.build.Builder,
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
        const c_exe = b.addExecutable(name, path);
        c_exe.setTarget(target);
        c_exe.setBuildMode(.ReleaseFast); // benchmarks are always release fast
        c_exe.addPackage(pkg);
        c_exe.setOutputDir("zig-out/bench");
        if (install) c_exe.install();

        // Store the mapping
        try map.put(name, c_exe);
    }

    return map;
}

/// Path to the directory with the build.zig.
fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}
