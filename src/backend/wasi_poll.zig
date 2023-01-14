const std = @import("std");
const assert = std.debug.assert;
const wasi = std.os.wasi;
const IntrusiveQueue = @import("../queue.zig").IntrusiveQueue;
const heap = @import("../heap.zig");
const xev = @import("../main.zig").WasiPoll;

pub const Loop = struct {
    const TimerHeap = heap.IntrusiveHeap(Timer, void, Timer.less);

    /// The number of active completions. This DOES NOT include completions that
    /// are queued in the submissions queue.
    active: usize = 0,

    /// Our queue of submissions that we want to enqueue on the next tick.
    submissions: IntrusiveQueue(Completion) = .{},

    /// Batch of subscriptions to send to poll.
    batch: [1024]wasi.subscription_t = undefined,

    /// Heap of timers.
    timers: TimerHeap = .{ .context = {} },

    pub fn init(entries: u13) !Loop {
        _ = entries;

        return .{};
    }

    pub fn deinit(self: *Loop) void {
        _ = self;
    }

    /// Run the event loop. See RunMode documentation for details on modes.
    pub fn run(self: *Loop, mode: xev.RunMode) !void {
        switch (mode) {
            .no_wait => try self.tick(0),
            .once => try self.tick(1),
            .until_done => while (!self.done()) try self.tick(1),
        }
    }

    /// Add a completion to the loop. This doesn't DO anything except queue
    /// the completion. Any configuration errors will be exposed via the
    /// callback on the next loop tick.
    pub fn add(self: *Loop, c: *Completion) void {
        c.flags.state = .adding;
        self.submissions.push(c);
    }

    fn done(self: *Loop) bool {
        return self.active == 0 and
            self.submissions.empty();
    }

    /// Tick through the event loop once, waiting for at least "wait" completions
    /// to be processed by the loop itself.
    pub fn tick(self: *Loop, wait: u32) !void {
        // Submit all the submissions. We copy the submission queue so that
        // any resubmits don't cause an infinite loop.
        var queued = self.submissions;
        self.submissions = .{};
        while (queued.pop()) |c| {
            // We ignore any completions that aren't in the adding state.
            // This usually means that we switched them to be deleted or
            // something.
            if (c.flags.state != .adding) continue;
            self.start(c);
        }

        // Wait and process events. We only do this if we have any active.
        if (self.active > 0) {
            var wait_rem = @intCast(usize, wait);
            while (self.active > 0 and (wait == 0 or wait_rem > 0)) {
                const now = try get_now();
                const now_timer: Timer = .{ .next = now };

                // Run our expired timers
                while (self.timers.peek()) |t| {
                    if (!Timer.less({}, t, &now_timer)) break;

                    // Remove the timer
                    assert(self.timers.deleteMin().? == t);

                    // Completion is now dead because it has been processed.
                    // Users can reuse it (unless they specify rearm in
                    // which case we readd it).
                    const c = t.c;
                    c.flags.state = .dead;
                    self.active -= 1;

                    // Lower our remaining count
                    wait_rem -|= 1;

                    // Invoke
                    const action = c.callback(c.userdata, self, c, .{
                        .timer = .expiration,
                    });
                    switch (action) {
                        .disarm => {},
                        .rearm => self.start(c),
                    }
                }

                // Determine our next timeout based on the timers
                if (wait_rem > 0) timeout: {
                    // If we have a timer, we want to set the timeout to our next
                    // timer value. If we have no timer, we wait forever.
                    const t = self.timers.peek() orelse break :timeout;

                    // Determine the time in milliseconds.
                    const timeout = t.next -| now;
                    _ = timeout;
                }

                const n = 0;

                if (wait == 0) break;
                wait_rem -|= n;
            }
        }
    }

    fn start(self: *Loop, completion: *Completion) void {
        const res_: ?Result = switch (completion.op) {
            .timer => |*v| res: {
                // Point back to completion since we need this. In the future
                // we want to use @fieldParentPtr but https://github.com/ziglang/zig/issues/6611
                v.c = completion;

                // Insert the timer into our heap.
                self.timers.insert(v);

                // We always run timers
                break :res null;
            },
        };

        // If we failed to add the completion then we call the callback
        // immediately and mark the error.
        if (res_) |res| {
            switch (completion.callback(
                completion.userdata,
                self,
                completion,
                res,
            )) {
                .disarm => {},

                // If we rearm then we requeue this. Due to the way that tick works,
                // this won't try to re-add immediately it won't happen until the
                // next tick.
                .rearm => self.add(completion),
            }

            return;
        }

        // The completion is now active since it is in our poll set.
        completion.flags.state = .active;

        // Increase our active count
        self.active += 1;
    }

    /// Add a timer to the loop. The timer will initially execute in "next_ms"
    /// from now and will repeat every "repeat_ms" thereafter. If "repeat_ms" is
    /// zero then the timer is oneshot. If "next_ms" is zero then the timer will
    /// invoke immediately (the callback will be called immediately -- as part
    /// of this function call -- to avoid any additional system calls).
    pub fn timer(
        self: *Loop,
        c: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: xev.Callback,
    ) void {
        // Get the absolute time we'll execute this timer next.
        var next_ts: wasi.timestamp_t = ts: {
            var now_ts: wasi.timestamp_t = undefined;
            switch (wasi.clock_time_get(@bitCast(u32, std.os.CLOCK.MONOTONIC), 1, &now_ts)) {
                .SUCCESS => {},
                .INVAL => unreachable,
                else => unreachable,
            }

            // TODO: overflow
            now_ts += next_ms * std.time.ns_per_ms;
            break :ts now_ts;
        };

        c.* = .{
            .op = .{
                .timer = .{
                    .next = next_ts,
                },
            },
            .userdata = userdata,
            .callback = cb,
        };

        self.add(c);
    }

    fn get_now() !wasi.timestamp_t {
        var ts: wasi.timestamp_t = undefined;
        return switch (wasi.clock_time_get(@bitCast(u32, std.os.CLOCK.MONOTONIC), 1, &ts)) {
            .SUCCESS => ts,
            .INVAL => error.UnsupportedClock,
            else => |err| std.os.unexpectedErrno(err),
        };
    }
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

    flags: packed struct {
        /// Watch state of this completion. We use this to determine whether
        /// we're active, adding, deleting, etc. This lets us add and delete
        /// multiple times before a loop tick and handle the state properly.
        state: State = .dead,
    } = .{},

    /// Intrusive queue field
    next: ?*Completion = null,

    const State = enum(u3) {
        /// completion is not part of any loop
        dead = 0,

        /// completion is in the submission queue
        adding = 1,

        /// completion is in the deletion queue
        deleting = 2,

        /// completion is actively being sent to poll
        active = 3,

        /// completion is being performed and callback invoked
        in_progress = 4,
    };
};

pub const OperationType = enum {
    timer,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    timer: TimerError!TimerTrigger,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    timer: Timer,
};

const Timer = struct {
    /// The absolute time to fire this timer next.
    next: std.os.wasi.timestamp_t,

    /// Internal heap fields.
    heap: heap.IntrusiveHeapField(Timer) = .{},

    /// We point back to completion for now. When issue[1] is fixed,
    /// we can juse use that from our heap fields.
    /// [1]: https://github.com/ziglang/zig/issues/6611
    c: *Completion = undefined,

    fn less(_: void, a: *const Timer, b: *const Timer) bool {
        return a.next < b.next;
    }
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

test "wasi: timer" {
    const testing = std.testing;

    var loop = try Loop.init(16);
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 1, &called, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Add another timer
    var called2 = false;
    var c2: xev.Completion = undefined;
    loop.timer(&c2, 100_000, &called2, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Tick
    while (!called) try loop.run(.no_wait);
    try testing.expect(called);
    try testing.expect(!called2);
}
