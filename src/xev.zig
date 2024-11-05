const Backend = @import("lib.zig").Backend;

pub fn Xev(comptime be: Backend, comptime T: type) type {
    return struct {
        const Self = @This();
        const loop = @import("loop.zig");

        /// The backend that this is. This is supplied at comptime so
        /// it is up to the caller to say the right thing. This lets custom
        /// implementations also "quack" like an implementation.
        pub const backend = be;

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

        /// The high-level helper interfaces that make it easier to perform
        /// common tasks. These may not work with all possible Loop implementations.
        pub const Async = @import("watcher/async.zig").Async(Self);
        pub const File = @import("watcher/file.zig").File(Self);
        pub const Process = @import("watcher/process.zig").Process(Self);
        pub const Stream = @import("watcher/stream.zig").GenericStream(Self);
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
