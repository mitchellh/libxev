const std = @import("std");
const assert = std.debug.assert;
const xev = @import("main.zig");
const heap = @import("heap.zig");

/// Loop is the cross-platform event loop abstraction given a specific
/// system interface backend.
pub fn Loop(comptime Sys: type) type {
    return struct {
        const Self = @This();

        const TimerHeap = heap.IntrusiveHeap(Timer, void, (struct {
            fn less(_: void, a: *Timer, b: *Timer) bool {
                _ = a;
                _ = b;
                return true;
            }
        }).less);

        /// The system interface for IO and other operations
        sys: Sys,

        /// The min-heap for timers
        timers: TimerHeap = .{ .context = {} },

        pub fn init(entries: u13) !Self {
            return .{
                .sys = try xev.Sys.init(entries),
            };
        }

        pub fn deinit(self: *Self) void {
            self.sys.deinit();
        }

        /// Register for an event with the loop. This will immediately register
        /// an event type to run on the next loop tick. The "h" argument will
        /// always match the input spec type.
        pub fn register(
            self: *Self,
            h: *Handle,
            spec: Spec,
        ) !void {
            _ = self;
            _ = h;
            _ = spec;
        }

        /// A handle is a registered item in the event loop. This is a single
        /// union type so that it is easier to create memory pools and other
        /// optimizations for storage and handling. The downside is that callers
        /// must be careful by ensuring they are only accessing the active
        /// element of the union.
        pub const Handle = union(enum) {
            timer: void,
            completion: Sys.Completion,
        };

        /// Spec is the specifications for various event types that can be
        /// registered.
        pub const Spec = union(enum) {
            /// Timer is a oneshot or repeating timer.
            timer: struct {
                /// The initial time in milliseconds _from registration time_
                /// to invoke the timer. If this is zero this will be invoked
                /// as soon as possible.
                initial: u64 = 0,

                /// The interval at which to repeat the timer in millisceonds.
                /// If this is zero the timer never repeats.
                repeat: u64 = 0,
            },
        };

        /// A timer.
        pub const Timer = struct {};
    };
}

test "loop" {
    var loop = try xev.Loop.init(1024);
    defer loop.deinit();

    var h: xev.Loop.Handle = undefined;
    try loop.register(&h, .{
        .timer = .{ .initial = 100 },
    }, (struct {
        fn callback() void {}
    }).callback);
    var t = try xev.Timer.init(100, 0);
    t.start(&loop, &h);
}
