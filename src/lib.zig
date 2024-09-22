const std = @import("std");
const builtin = @import("builtin");

pub const Xev = @import("xev.zig").Xev;

/// System-specific interfaces. Note that they are always pub for
/// all systems but if you reference them and force them to be analyzed
/// the proper system APIs must exist. Due to Zig's lazy analysis, if you
/// don't use any interface it will NOT be compiled (yay!).
pub const IO_Uring = Xev(.io_uring, @import("backend/io_uring.zig"));
pub const Epoll = Xev(.epoll, @import("backend/epoll.zig"));
pub const Kqueue = Xev(.kqueue, @import("backend/kqueue.zig"));
pub const WasiPoll = Xev(.wasi_poll, @import("backend/wasi_poll.zig"));
pub const IOCP = Xev(.iocp, @import("backend/iocp.zig"));

/// Generic thread pool implementation.
pub const ThreadPool = @import("ThreadPool.zig");

/// This stream (lowercase s) can be used as a namespace to access
/// Closeable, Writeable, Readable, etc. so that custom streams
/// can be constructed.
pub const stream = @import("watcher/stream.zig");

/// The backend types.
pub const Backend = enum {
    io_uring,
    epoll,
    kqueue,
    wasi_poll,
    iocp,

    /// Returns a recommend default backend from inspecting the system.
    pub fn default() Backend {
        return @as(?Backend, switch (builtin.os.tag) {
            .linux => .io_uring,
            .ios, .macos => .kqueue,
            .wasi => .wasi_poll,
            .windows => .iocp,
            else => null,
        }) orelse {
            @compileLog(builtin.os);
            @compileError("no default backend for this target");
        };
    }

    /// Returns the Api (return value of Xev) for the given backend type.
    pub fn Api(comptime self: Backend) type {
        return switch (self) {
            .io_uring => IO_Uring,
            .epoll => Epoll,
            .kqueue => Kqueue,
            .wasi_poll => WasiPoll,
            .iocp => IOCP,
        };
    }
};

pub const backend = Backend.default();

const T = backend.Api();
pub const Sys = T.Sys;

const loop = @import("loop.zig");

/// The core loop APIs.
pub const Loop = Sys.Loop;
pub const Completion = Sys.Completion;
pub const Result = Sys.Result;
pub const ReadBuffer = Sys.ReadBuffer;
pub const WriteBuffer = Sys.WriteBuffer;
pub const Options = loop.Options;
pub const RunMode = loop.RunMode;
pub const CallbackAction = loop.CallbackAction;
pub const CompletionState = loop.CompletionState;

/// Error types
pub const AcceptError = Sys.AcceptError;
pub const CancelError = Sys.CancelError;
pub const CloseError = Sys.CloseError;
pub const ConnectError = Sys.ConnectError;
pub const ShutdownError = Sys.ShutdownError;
pub const WriteError = Sys.WriteError;
pub const ReadError = Sys.ReadError;

const Self = @This();

/// The high-level helper interfaces that make it easier to perform
/// common tasks. These may not work with all possible Loop implementations.
pub const Async = @import("watcher/async.zig").Async(Self);
pub const File = @import("watcher/file.zig").File(Self);
pub const Process = @import("watcher/process.zig").Process(Self);
pub const Stream = stream.GenericStream(Self);
pub const Timer = @import("watcher/timer.zig").Timer(Self);
pub const TCP = @import("watcher/tcp.zig").TCP(Self);
pub const UDP = @import("watcher/udp.zig").UDP(Self);

/// The callback of the main Loop operations. Higher level interfaces may
/// use a different callback mechanism.
pub const Callback = *const fn (
    userdata: ?*anyopaque,
    loop: *Loop,
    completion: *Completion,
    result: Result,
) CallbackAction;

pub const noopCallback = T.noopCallback;

test {
    // Tested on all platforms
    _ = @import("heap.zig");
    _ = @import("queue.zig");
    _ = @import("queue_mpsc.zig");
    _ = ThreadPool;

    // Test the C API
    if (builtin.os.tag != .wasi) _ = @import("c_api.zig");

    // OS-specific tests
    switch (builtin.os.tag) {
        .linux => {
            _ = Epoll;
            _ = IO_Uring;
            _ = @import("linux/timerfd.zig");
        },

        .wasi => {
            //_ = WasiPoll;
            _ = @import("backend/wasi_poll.zig");
        },

        .windows => {
            _ = @import("backend/iocp.zig");
        },

        else => {},
    }
}
