const builtin = @import("builtin");
const stream = @import("watcher/stream.zig");
const Backend = @import("backend.zig").Backend;

/// Creates the Xev API based on a backend type.
///
/// For the default backend type for your system (i.e. io_uring on Linux),
/// this is the main API you interact with. It is forwarded into the main
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
        pub const Callback = loop.Callback(T);

        /// A callback that does nothing and immediately disarms. This
        /// implements xev.Callback and is the default value for completions.
        pub const noopCallback = loop.NoopCallback(T);

        /// A way to access the raw type.
        pub const Sys = T;

        test {
            @import("std").testing.refAllDecls(@This());
        }

        test "completion is zero-able" {
            const c: Self.Completion = .{};
            _ = c;
        }
    };
}
