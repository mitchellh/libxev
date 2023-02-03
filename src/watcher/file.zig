const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;
const main = @import("../main.zig");
const stream = @import("stream.zig");

/// File operations.
///
/// These operations typically run on the event loop thread pool, rather
/// than the core async OS APIs, because most core async OS APIs don't support
/// async operations on regular files (with many caveats attached to that
/// statement). This high-level abstraction will attempt to make the right
/// decision about what to do but this should generally be used by
/// operations that need to run on a thread pool. For operations that you're
/// sure are better supported by core async OS APIs (such as sockets, pipes,
/// TTYs, etc.), use a specific high-level abstraction like xev.TCP or
/// the generic xev.Stream.
///
/// This is a "higher-level abstraction" in libxev. The goal of higher-level
/// abstractions in libxev are to make it easier to use specific functionality
/// with the event loop, but does not promise perfect flexibility or optimal
/// performance. In almost all cases, the abstraction is good enough. But,
/// if you have specific needs or want to push for the most optimal performance,
/// use the platform-specific Loop directly.
pub fn File(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The underlying file
        fd: std.os.fd_t,

        pub usingnamespace stream.Stream(xev, Self, .{
            .close = true,
            .read = .read,
            .write = .write,
            .threadpool = true,
        });

        /// Initialize a new TCP with the family from the given address. Only
        /// the family is used, the actual address has no impact on the created
        /// resource.
        pub fn init(file: std.fs.File) !Self {
            return .{
                .fd = file.handle,
            };
        }

        /// Initialize a File from a file descriptor.
        pub fn initFd(fd: std.fs.File.Handle) Self {
            return .{
                .fd = fd,
            };
        }

        /// Clean up any watcher resources. This does NOT close the file.
        /// If you want to close the file you must call close or do so
        /// synchronously.
        pub fn deinit(self: *const File) void {
            _ = self;
        }

        test {
            // wasi: local files don't work with poll (always ready)
            if (builtin.os.tag == .wasi) return error.SkipZigTest;

            const testing = std.testing;

            var tpool = main.ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Create our file
            const path = "test_watcher_file";
            const f = try std.fs.cwd().createFile(path, .{
                .read = true,
                .truncate = true,
            });
            defer f.close();
            defer std.fs.cwd().deleteFile(path) catch {};

            const file = try init(f);

            // Perform a write and then a read
            var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
            var c_write: xev.Completion = undefined;
            file.write(&loop, &c_write, .{ .slice = &write_buf }, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    _: xev.WriteBuffer,
                    r: Self.WriteError!usize,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for the write
            try loop.run(.until_done);

            // Make sure the data is on disk
            try f.sync();

            const f2 = try std.fs.cwd().openFile(path, .{});
            defer f2.close();
            const file2 = try init(f2);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: usize = 0;
            file2.read(&loop, &c_write, .{ .slice = &read_buf }, usize, &read_len, (struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    _: xev.ReadBuffer,
                    r: Self.ReadError!usize,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
            try testing.expectEqualSlices(u8, &write_buf, read_buf[0..read_len]);
        }
    };
}
