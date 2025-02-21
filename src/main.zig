const std = @import("std");
const builtin = @import("builtin");

/// The low-level IO interfaces using the recommended compile-time
/// interface for the target system.
const xev = Backend.default().Api();
pub usingnamespace xev;
//pub usingnamespace Epoll;

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
        return switch (builtin.os.tag) {
            .linux => .io_uring,
            .ios, .macos => .kqueue,
            .wasi => .wasi_poll,
            .windows => .iocp,
            else => {
                @compileLog(builtin.os);
                @compileError("no default backend for this target");
            },
        };
    }

    /// Candidate backends for this platform in priority order.
    pub fn candidates() []const Backend {
        return switch (builtin.os.tag) {
            .linux => &.{ .io_uring, .epoll },
            .ios, .macos => &.{.kqueue},
            .wasi => &.{.wasi_poll},
            .windows => &.{.iocp},
            else => {
                @compileLog(builtin.os);
                @compileError("no candidate backends for this target");
            },
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

/// Creates the Xev API based on a backend type.
///
/// For the default backend type for your system (i.e. io_uring on Linux),
/// this is the main API you interact with. It is `usingnamespaced` into
/// the "xev" package so you'd use types such as `xev.Loop`, `xev.Completion`,
/// etc.
///
/// Unless you're using a custom or specific backend type, you do NOT ever
/// need to call the Xev function itself.
pub fn Xev(comptime be: Backend, comptime T: type) type {
    return struct {
        const Self = @This();
        const loop = @import("loop.zig");

        /// This is used to detect a static vs dynamic API at comptime.
        pub const dynamic = false;

        /// The backend that this is. This is supplied at comptime so
        /// it is up to the caller to say the right thing. This lets custom
        /// implementations also "quack" like an implementation.
        pub const backend = be;

        /// A function to test if this API is available on the
        /// current system.
        pub const available = T.available;

        /// The core loop APIs.
        pub const Loop = T.Loop;
        pub const Completion = T.Completion;
        pub const Result = T.Result;
        pub const ReadBuffer = T.ReadBuffer;
        pub const WriteBuffer = T.WriteBuffer;
        pub const Options = loop.Options;
        pub const RunMode = loop.RunMode;
        pub const CallbackAction = loop.CallbackAction;
        pub const CompletionState = loop.CompletionState;

        /// Error types
        pub const AcceptError = T.AcceptError;
        pub const CancelError = T.CancelError;
        pub const CloseError = T.CloseError;
        pub const ConnectError = T.ConnectError;
        pub const ShutdownError = T.ShutdownError;
        pub const WriteError = T.WriteError;
        pub const ReadError = T.ReadError;

        /// Shared stream types
        const SharedStream = stream.Shared(Self);
        pub const PollError = SharedStream.PollError;
        pub const PollEvent = SharedStream.PollEvent;
        pub const WriteQueue = SharedStream.WriteQueue;
        pub const WriteRequest = SharedStream.WriteRequest;

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

        /// A way to access the raw type.
        pub const Sys = T;

        /// A callback that does nothing and immediately disarms. This
        /// implements xev.Callback and is the default value for completions.
        pub fn noopCallback(
            _: ?*anyopaque,
            _: *Loop,
            _: *Completion,
            _: Result,
        ) CallbackAction {
            return .disarm;
        }

        test {
            @import("std").testing.refAllDecls(@This());
        }

        test "completion is zero-able" {
            const c: Completion = .{};
            _ = c;
        }
    };
}

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
