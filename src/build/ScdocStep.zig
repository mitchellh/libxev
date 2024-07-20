const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Step = std.Build.Step;
const Build = std.Build;

/// ScdocStep generates man pages using scdoc(1).
///
/// It reads all the raw pages from src_path and writes them to out_path.
/// src_path is typically "docs/" relative to the build root and out_path is
/// the build cache.
///
/// The man pages can be installed by calling install() on the step.
const ScdocStep = @This();

step: Step,
builder: *Build,

/// path to read man page sources from, defaults to the "doc/" subdirectory
/// from the build.zig file. This must be an absolute path.
src_path: []const u8,

/// path where the generated man pages will be written (NOT installed). This
/// defaults to build cache root.
out_path: []const u8,

pub fn create(builder: *Build) *ScdocStep {
    const self = builder.allocator.create(ScdocStep) catch unreachable;
    self.* = init(builder);
    return self;
}

pub fn init(builder: *Build) ScdocStep {
    return ScdocStep{
        .builder = builder,
        .step = Step.init(.{
            .id = .custom,
            .name = "generate man pages",
            .owner = builder,
            .makeFn = make,
        }),
        .src_path = builder.pathFromRoot("docs/"),
        .out_path = builder.cache_root.join(builder.allocator, &[_][]const u8{
            "man",
        }) catch unreachable,
    };
}

fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
    const self: *ScdocStep = @fieldParentPtr("step", step);

    // Create our cache path
    // TODO(mitchellh): ideally this would be pure zig
    {
        const command = try std.fmt.allocPrint(
            self.builder.allocator,
            "rm -f {[path]s}/* && mkdir -p {[path]s}",
            .{ .path = self.out_path },
        );
        _ = self.builder.run(&[_][]const u8{ "sh", "-c", command });
    }

    // Find all our man pages which are in our src path ending with ".scd".
    var dir = try fs.openDirAbsolute(self.src_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |*entry| {
        // We only want "scd" files to generate.
        if (!mem.eql(u8, fs.path.extension(entry.name), ".scd")) {
            continue;
        }

        const src = try fs.path.join(
            self.builder.allocator,
            &[_][]const u8{ self.src_path, entry.name },
        );

        const dst = try fs.path.join(
            self.builder.allocator,
            &[_][]const u8{ self.out_path, entry.name[0..(entry.name.len - 4)] },
        );

        const command = try std.fmt.allocPrint(
            self.builder.allocator,
            "scdoc < {s} > {s}",
            .{ src, dst },
        );
        _ = self.builder.run(&[_][]const u8{ "sh", "-c", command });
    }
}

pub fn install(self: *ScdocStep) !void {
    // Ensure that `zig build install` depends on our generation step first.
    self.builder.getInstallStep().dependOn(&self.step);

    // Then run our install step which looks at what we made out of our
    // generation and moves it to the install prefix.
    const install_step = InstallStep.create(self.builder, self);
    self.builder.getInstallStep().dependOn(&install_step.step);
}

/// Install man pages, create using install() on ScdocStep.
const InstallStep = struct {
    step: Step,
    builder: *Build,
    scdoc: *ScdocStep,

    pub fn create(builder: *Build, scdoc: *ScdocStep) *InstallStep {
        const self = builder.allocator.create(InstallStep) catch unreachable;
        self.* = InstallStep.init(builder, scdoc);
        self.step.dependOn(&scdoc.step);
        return self;
    }

    fn init(builder: *Build, scdoc: *ScdocStep) InstallStep {
        return InstallStep{
            .builder = builder,
            .step = Step.init(.{
                .id = .custom,
                .name = "install man pages",
                .owner = builder,
                .makeFn = InstallStep.make,
            }),
            .scdoc = scdoc,
        };
    }

    fn make(step: *Step, options: std.Build.Step.MakeOptions) !void {
        const self: *InstallStep = @fieldParentPtr("step", step);

        // Get our absolute output path
        var path = self.scdoc.out_path;
        if (!fs.path.isAbsolute(path)) {
            path = self.builder.pathFromRoot(path);
        }

        // Find all our man pages which are in our src path ending with ".scd".
        var dir = try fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |*entry| {
            // We expect filenames to be "foo.3" and this gets us "3"
            const section = entry.name[(entry.name.len - 1)..];

            const src = try fs.path.join(
                self.builder.allocator,
                &[_][]const u8{ path, entry.name },
            );
            const output = try std.fmt.allocPrint(
                self.builder.allocator,
                "share/man/man{s}/{s}",
                .{ section, entry.name },
            );

            const fileStep = self.builder.addInstallFile(
                .{ .cwd_relative = src },
                output,
            );
            try fileStep.step.make(options);
        }
    }
};
