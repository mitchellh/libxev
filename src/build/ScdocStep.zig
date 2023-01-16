const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Step = std.build.Step;
const Builder = std.build.Builder;

/// ScdocStep generates man pages using scdoc(1).
///
/// It reads all the raw pages from src_path and writes them to out_path.
/// src_path is typically "docs/" relative to the build root and out_path is
/// the build cache.
///
/// The man pages can be installed by calling install() on the step.
const ScdocStep = @This();

step: Step,
builder: *Builder,

/// path to read man page sources from, defaults to the "doc/" subdirectory
/// from the build.zig file. This must be an absolute path.
src_path: []const u8,

/// path where the generated man pages will be written (NOT installed). This
/// defaults to build cache root.
out_path: []const u8,

pub fn create(builder: *Builder) *ScdocStep {
    const self = builder.allocator.create(ScdocStep) catch unreachable;
    self.* = init(builder);
    return self;
}

pub fn init(builder: *Builder) ScdocStep {
    return ScdocStep{
        .builder = builder,
        .step = Step.init(.custom, "generate man pages", builder.allocator, make),
        .src_path = builder.pathFromRoot("docs/"),
        .out_path = fs.path.join(builder.allocator, &[_][]const u8{
            builder.cache_root,
            "man",
        }) catch unreachable,
    };
}

fn make(step: *std.build.Step) !void {
    const self = @fieldParentPtr(ScdocStep, "step", step);

    // Create our cache path
    // TODO(mitchellh): ideally this would be pure zig
    {
        const command = try std.fmt.allocPrint(
            self.builder.allocator,
            "rm -f {[path]s}/* && mkdir -p {[path]s}",
            .{ .path = self.out_path },
        );
        _ = try self.builder.exec(&[_][]const u8{ "sh", "-c", command });
    }

    // Find all our man pages which are in our src path ending with ".scd".
    var dir = try fs.openIterableDirAbsolute(self.src_path, .{});
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
        _ = try self.builder.exec(&[_][]const u8{ "sh", "-c", command });
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
    builder: *Builder,
    scdoc: *ScdocStep,

    pub fn create(builder: *Builder, scdoc: *ScdocStep) *InstallStep {
        const self = builder.allocator.create(InstallStep) catch unreachable;
        self.* = InstallStep.init(builder, scdoc);
        return self;
    }

    pub fn init(builder: *Builder, scdoc: *ScdocStep) InstallStep {
        return InstallStep{
            .builder = builder,
            .step = Step.init(.custom, "generate man pages", builder.allocator, InstallStep.make),
            .scdoc = scdoc,
        };
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(InstallStep, "step", step);

        // Get our absolute output path
        var path = self.scdoc.out_path;
        if (!fs.path.isAbsolute(path)) {
            path = self.builder.pathFromRoot(path);
        }

        // Find all our man pages which are in our src path ending with ".scd".
        var dir = try fs.openIterableDirAbsolute(path, .{});
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
                .{ .path = src },
                output,
            );
            try fileStep.step.make();
        }
    }
};
