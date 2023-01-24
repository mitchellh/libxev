const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const wasi = std.os.wasi;
const queue = @import("../queue.zig");
const heap = @import("../heap.zig");
const xev = @import("../main.zig").WasmExtern;

// The API that must be provided by the Wasm host environment.
extern "xev" fn timer_start(loop: *Loop, c: *Completion, ms: u64) u64;

pub const Loop = struct {
    /// Our queue of submissions that we want to enqueue on the next tick.
    submissions: queue.Intrusive(Completion) = .{},

    pub fn init(options: xev.Options) !Loop {
        _ = options;
        return .{};
    }

    pub fn deinit(self: *Loop) void {
        _ = self;
    }

    /// Add a completion to the loop. This doesn't DO anything except
    /// the completion. Any configuration errors will be exposed via the
    /// callback on the next loop tick.
    pub fn add(self: *Loop, c: *Completion) void {
        self.submissions.push(c);
    }

    /// Submit any enqueue completions. This does not fire any callbacks
    /// for completed events (success or error). Callbacks are only fired
    /// on the next tick.
    ///
    /// If an error is returned, some events might be lost. Errors are
    /// exceptional and should generally not happen. Per-completion errors
    /// are stored on the completion and trigger a callback on the next
    /// tick.
    pub fn submit(self: *Loop) !void {
        var queued = self.submissions;
        self.submissions = .{};
        while (queued.pop()) |c| {
            self.start(c);
        }
    }

    fn start(self: *Loop, c: *Completion) !void {
        switch (c.op) {
            .timer => |op| {
                c.id = timer_start(self, c, op.next_ms);
            },
        }
    }
};

pub const OperationType = enum {
    timer,
};

pub const Completion = struct {
    /// Operation to execute. This is only safe to read BEFORE the completion
    /// is queued. After being queued (with "add"), the operation may change.
    op: Operation,

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: xev.Callback,

    //---------------------------------------------------------------
    // Internal fields

    /// ID for canceling.
    id: u64 = 0,

    /// Intrusive queue field
    next: ?*Completion = null,
};

pub const Result = union(OperationType) {
    timer: TimerError!TimerTrigger,
};

pub const Operation = union(OperationType) {
    timer: struct {
        next_ms: u64,
    },
};

pub const TimerError = error{
    Unexpected,
};

pub const TimerTrigger = enum {
    /// Timer expired.
    expiration,

    /// Timer was canceled.
    cancel,

    /// Unused
    request,
};

// Unused values that must exist for the Xev API
pub const ReadBuffer = struct {};
pub const WriteBuffer = struct {};
pub const AcceptError = error{Unexpected};
pub const CancelError = error{Unexpected};
pub const CloseError = error{Unexpected};
pub const ConnectError = error{Unexpected};
pub const ShutdownError = error{Unexpected};
pub const WriteError = error{Unexpected};
pub const ReadError = error{Unexpected};

// test "wasi: timer" {
//     const testing = std.testing;
//
//     var loop = try Loop.init(.{});
//     defer loop.deinit();
//
//     // Add the timer
//     var called = false;
//     var c1: xev.Completion = undefined;
//     loop.timer(&c1, 1, &called, (struct {
//         fn callback(
//             ud: ?*anyopaque,
//             l: *xev.Loop,
//             _: *xev.Completion,
//             r: xev.Result,
//         ) xev.CallbackAction {
//             _ = l;
//             _ = r;
//             const b = @ptrCast(*bool, ud.?);
//             b.* = true;
//             return .disarm;
//         }
//     }).callback);
//
//     // Add another timer
//     var called2 = false;
//     var c2: xev.Completion = undefined;
//     loop.timer(&c2, 100_000, &called2, (struct {
//         fn callback(
//             ud: ?*anyopaque,
//             l: *xev.Loop,
//             _: *xev.Completion,
//             r: xev.Result,
//         ) xev.CallbackAction {
//             _ = l;
//             _ = r;
//             const b = @ptrCast(*bool, ud.?);
//             b.* = true;
//             return .disarm;
//         }
//     }).callback);
//
//     // Tick
//     while (!called) try loop.run(.no_wait);
//     try testing.expect(called);
//     try testing.expect(!called2);
// }
