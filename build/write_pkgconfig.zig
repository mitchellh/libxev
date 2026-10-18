const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args_iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer args_iter.deinit();
    if (!args_iter.skip()) @panic("Called without argv0");
    const deployed_prefix = args_iter.next() orelse @panic("Did not get prefix");

    var stdout_file = std.Io.File.stdout();
    defer stdout_file.close(init.io);
    var out_buf: [1024]u8 = undefined;
    var stdout = stdout_file.writer(init.io, &out_buf);

    try stdout.interface.print(
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
    , .{deployed_prefix});
    try stdout.interface.flush();
}
