const std = @import("std");
const builtin = @import("builtin");

/// The low-level IO interfaces using the recommended compile-time
/// interface for the target system. We forward these as the default
/// API of this package.
const xev = Backend.default().Api();
pub const dynamic = xev.dynamic;
pub const backend = xev.backend;
pub const available = xev.available;
pub const noopCallback = xev.noopCallback;
pub const Sys = xev.Sys;
pub const Loop = xev.Loop;
pub const Completion = xev.Completion;
pub const Result = xev.Result;
pub const ReadBuffer = xev.ReadBuffer;
pub const WriteBuffer = xev.WriteBuffer;
pub const Options = xev.Options;
pub const RunMode = xev.RunMode;
pub const Callback = xev.Callback;
pub const CallbackAction = xev.CallbackAction;
pub const CompletionState = xev.CompletionState;
pub const AcceptError = xev.AcceptError;
pub const CancelError = xev.CancelError;
pub const CloseError = xev.CloseError;
pub const ConnectError = xev.ConnectError;
pub const ShutdownError = xev.ShutdownError;
pub const WriteError = xev.WriteError;
pub const ReadError = xev.ReadError;
pub const PollError = xev.PollError;
pub const PollEvent = xev.PollEvent;
pub const WriteQueue = xev.WriteQueue;
pub const WriteRequest = xev.WriteRequest;
pub const Async = xev.Async;
pub const File = xev.File;
pub const Process = xev.Process;
pub const Stream = stream.GenericStream;
pub const Timer = xev.Timer;
pub const TCP = xev.TCP;
pub const UDP = xev.UDP;

comptime {
    // This ensures that all the public decls from the API are forwarded
    // from the main struct.
    const main = @This();
    const default = Backend.default().Api();
    for (@typeInfo(default).@"struct".decls) |decl| {
        const Decl = @TypeOf(@field(default, decl.name));
        if (Decl == void) continue;
        if (!@hasDecl(main, decl.name)) {
            @compileError("missing decl: " ++ decl.name);
        }
    }
}

/// The dynamic interface that allows for runtime selection of the
/// backend to use. This is useful if you want to support multiple
/// backends and have a fallback mechanism.
///
/// There is a very small overhead to using this API compared to the
/// static API, but it is generally negligible.
///
/// The API for this isn't _exactly_ the same as the static API
/// since it requires initialization of the main struct to detect
/// a backend and then this needs to be passed to every high-level
/// type such as Async, File, etc. so that they can use the correct
/// backend that is coherent with the loop.
pub const Dynamic = DynamicXev(Backend.candidates());
pub const DynamicXev = @import("dynamic.zig").Xev;

/// System-specific interfaces. Note that they are always pub for
/// all systems but if you reference them and force them to be analyzed
/// the proper system APIs must exist. Due to Zig's lazy analysis, if you
/// don't use any interface it will NOT be compiled (yay!).
const Xev = @import("api.zig").Xev;
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
pub const Backend = @import("backend.zig").Backend;

test {
    // Tested on all platforms
    _ = @import("heap.zig");
    _ = @import("queue.zig");
    _ = @import("queue_mpsc.zig");
    _ = ThreadPool;
    _ = Dynamic;

    // Test the C API
    if (builtin.os.tag != .wasi) _ = @import("c_api.zig");

    // OS-specific tests
    switch (builtin.os.tag) {
        .linux => {
            _ = Epoll;
            _ = IO_Uring;
            _ = @import("linux/timerfd.zig");
        },

        .freebsd => {
            _ = Kqueue;
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
