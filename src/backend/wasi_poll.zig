const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const wasi = std.os.wasi;
const posix = std.posix;
const queue = @import("../queue.zig");
const heap = @import("../heap.zig");
const xev = @import("../main.zig").WasiPoll;

/// True if this backend is available on this platform.
pub fn available() bool {
    return builtin.os.tag == .wasi;
}

pub const Loop = struct {
    pub const threaded = std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);
    const TimerHeap = heap.Intrusive(Timer, void, Timer.less);
    const WakeupType = if (threaded) std.atomic.Atomic(bool) else bool;
    const wakeup_init = if (threaded) .{ .value = false } else false;

    /// The number of active completions. This DOES NOT include completions that
    /// are queued in the submissions queue.
    active: usize = 0,

    /// Our queue of submissions that we want to enqueue on the next tick.
    submissions: queue.Intrusive(Completion) = .{},

    /// Our list of async waiters.
    asyncs: queue.Intrusive(Completion) = .{},

    /// Batch of subscriptions to send to poll.
    batch: Batch = .{},

    /// Heap of timers.
    timers: TimerHeap = .{ .context = {} },

    /// The wakeup signal variable for Async. If we have Wasm threads
    /// enabled then we use an atomic for this, otherwise we just use a plain
    /// bool because we know we're single threaded.
    wakeup: WakeupType = wakeup_init,

    /// Cached time
    cached_now: wasi.timestamp_t,

    /// Some internal fields we can pack for better space.
    flags: packed struct {
        /// Whether we're in a run or not (to prevent nested runs).
        in_run: bool = false,

        /// Whether our loop is in a stopped state or not.
        stopped: bool = false,
    } = .{},

    pub fn init(options: xev.Options) !Loop {
        _ = options;
        return .{ .cached_now = try get_now() };
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

    /// Stop the loop. This can only be called from the main thread.
    /// This will stop the loop forever. Future ticks will do nothing.
    ///
    /// This does NOT stop any completions that are queued to be executed
    /// in the thread pool. If you are using a thread pool, completions
    /// are not safe to recover until the thread pool is shut down. If
    /// you're not using a thread pool, all completions are safe to
    /// read/write once any outstanding `run` or `tick` calls are returned.
    pub fn stop(self: *Loop) void {
        self.flags.stopped = true;
    }

    /// Returns true if the loop is stopped. This may mean there
    /// are still pending completions to be processed.
    pub fn stopped(self: *Loop) bool {
        return self.flags.stopped;
    }

    /// Add a completion to the loop. This doesn't DO anything except queue
    /// the completion. Any configuration errors will be exposed via the
    /// callback on the next loop tick.
    pub fn add(self: *Loop, c: *Completion) void {
        c.flags.state = .adding;
        self.submissions.push(c);
    }

    fn done(self: *Loop) bool {
        return self.flags.stopped or (self.active == 0 and
            self.submissions.empty());
    }

    /// Wake up the event loop and force a tick. This only works if there
    /// is a corresponding async_wait completion _already registered_ with
    /// the event loop. If there isn't already a completion, it will still
    /// work, but the async_wait will be triggered on the next loop tick
    /// it is added, and the loop won't wake up until then. This is usually
    /// pointless since completions can only be added from the main thread.
    ///
    /// The completion c doesn't yet have to be registered as a waiter, but
    ///
    ///
    /// This function can be called from any thread.
    pub fn async_notify(self: *Loop, c: *Completion) void {
        assert(c.op == .async_wait);

        if (threaded) {
            self.wakeup.store(true, .SeqCst);
            c.op.async_wait.wakeup.store(true, .SeqCst);
        } else {
            self.wakeup = true;
            c.op.async_wait.wakeup = true;
        }
    }

    /// Tick through the event loop once, waiting for at least "wait" completions
    /// to be processed by the loop itself.
    pub fn tick(self: *Loop, wait: u32) !void {
        // If we're stopped then the loop is fully over.
        if (self.flags.stopped) return;

        // We can't nest runs.
        if (self.flags.in_run) return error.NestedRunsNotAllowed;
        self.flags.in_run = true;
        defer self.flags.in_run = false;

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
        var wait_rem = @as(usize, @intCast(wait));
        while (true) {
            // If we're stopped then the loop is fully over.
            if (self.flags.stopped) return;

            // We must always update the loop time even if we have no
            // active completions.
            self.update_now();

            if (!(self.active > 0 and (wait == 0 or wait_rem > 0))) break;

            // Run our expired timers
            const now_timer: Timer = .{ .next = self.cached_now };
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

            // Run our async waiters
            if (!self.asyncs.empty()) {
                const wakeup = if (threaded) self.wakeup.load(.SeqCst) else self.wakeup;
                if (wakeup) {
                    // Reset to false, we've "woken up" now.
                    if (threaded)
                        self.wakeup.store(false, .SeqCst)
                    else
                        self.wakeup = false;

                    // There is at least one pending async. This isn't efficient
                    // AT ALL. We should improve this in the short term by
                    // using a queue here of asyncs we know should wake up
                    // (we know because we have access to it in async_notify).
                    // I didn't do that right away because we need a Wasm
                    // compatibile std.Thread.Mutex.
                    var asyncs = self.asyncs;
                    self.asyncs = .{};
                    while (asyncs.pop()) |c| {
                        const c_wakeup = if (threaded)
                            c.op.async_wait.wakeup.load(.SeqCst)
                        else
                            c.op.async_wait.wakeup;

                        // If we aren't waking this one up, requeue
                        if (!c_wakeup) {
                            self.asyncs.push(c);
                            continue;
                        }

                        // We are waking up, mark this as dead and call it.
                        c.flags.state = .dead;
                        self.active -= 1;

                        // Lower our waiters
                        wait_rem -|= 1;

                        const action = c.callback(c.userdata, self, c, .{ .async_wait = {} });
                        switch (action) {
                            // We disarm by default
                            .disarm => {},

                            // Rearm we just restart it. We use start instead of
                            // add because then it'll become immediately available
                            // if we loop again.
                            .rearm => self.start(c),
                        }
                    }
                }
            }

            // Setup our timeout. If we have nothing to wait for then
            // we just set an expiring timer so that we still poll but it
            // will return ASAP.
            const timeout: wasi.timestamp_t = if (wait_rem == 0) self.cached_now else timeout: {
                // If we have a timer use that value, otherwise we can afford
                // to sleep for awhile since we're waiting for something to
                // happen. We set this sleep to 60 seconds arbitrarily. On
                // other backends we wait indefinitely.
                const t: *const Timer = self.timers.peek() orelse
                    break :timeout self.cached_now + (60 * std.time.ns_per_s);
                break :timeout t.next;
            };
            self.batch.array[0] = .{
                .userdata = 0,
                .u = .{
                    .tag = wasi.EVENTTYPE_CLOCK,
                    .u = .{
                        .clock = .{
                            .id = @as(u32, @bitCast(posix.CLOCK.MONOTONIC)),
                            .timeout = timeout,
                            .precision = 1 * std.time.ns_per_ms,
                            .flags = wasi.SUBSCRIPTION_CLOCK_ABSTIME,
                        },
                    },
                },
            };

            // Build our batch of subscriptions and poll
            var events: [Batch.capacity]wasi.event_t = undefined;
            const subs = self.batch.array[0..self.batch.len];
            assert(events.len >= subs.len);
            var n: usize = 0;
            switch (wasi.poll_oneoff(&subs[0], &events[0], subs.len, &n)) {
                .SUCCESS => {},
                else => |err| return posix.unexpectedErrno(err),
            }

            // Poll!
            for (events[0..n]) |ev| {
                // A system event
                if (ev.userdata == 0) continue;

                const c = @as(*Completion, @ptrFromInt(@as(usize, @intCast(ev.userdata))));

                // We assume disarm since this is the safest time to access
                // the completion. It makes rearms slightly more expensive
                // but not by very much.
                c.flags.state = .dead;
                self.batch.put(c);
                self.active -= 1;

                const res = c.perform();
                const action = c.callback(c.userdata, self, c, res);
                switch (action) {
                    // We disarm by default
                    .disarm => {},

                    // Rearm we just restart it. We use start instead of
                    // add because then it'll become immediately available
                    // if we loop again.
                    .rearm => self.start(c),
                }
            }

            if (wait == 0) break;
            wait_rem -|= n;
        }
    }

    fn start(self: *Loop, completion: *Completion) void {
        const res_: ?Result = switch (completion.op) {
            .noop => {
                completion.flags.state = .dead;
                return;
            },

            .cancel => |v| res: {
                // We stop immediately. We only stop if we are in the
                // "adding" state because cancellation or any other action
                // means we're complete already.
                //
                // For example, if we're in the deleting state, it means
                // someone is cancelling the cancel. So we do nothing. If
                // we're in the dead state it means we ran already.
                if (completion.flags.state == .adding) {
                    if (v.c.op == .cancel) break :res .{ .cancel = CancelError.InvalidOp };
                    self.stop_completion(v.c);
                }

                // We always run timers
                break :res .{ .cancel = {} };
            },

            .read => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .read = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .pread => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .pread = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .write => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .write = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .pwrite => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .pwrite = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .recv => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .recv = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .send => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .send = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .accept => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .accept = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .shutdown => |v| res: {
                const how: wasi.sdflags_t = switch (v.how) {
                    .both => wasi.SHUT.WR | wasi.SHUT.RD,
                    .recv => wasi.SHUT.RD,
                    .send => wasi.SHUT.WR,
                };

                break :res .{
                    .shutdown = switch (wasi.sock_shutdown(v.socket, how)) {
                        .SUCCESS => {},
                        else => |err| posix.unexpectedErrno(err),
                    },
                };
            },

            .close => |v| res: {
                posix.close(v.fd);
                break :res .{ .close = {} };
            },

            .async_wait => res: {
                // Add our async to the list of asyncs
                self.asyncs.push(completion);
                break :res null;
            },

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
            completion.flags.state = .dead;
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

    fn stop_completion(self: *Loop, c: *Completion) void {
        // We may modify the state below so we need to know now if this
        // completion was active.
        const active = c.flags.state == .active;

        const rearm: bool = switch (c.op) {
            .timer => |*v| timer: {
                assert(v.c == c);

                // Timers needs to be removed from the timer heap only if
                // it has been inserted.
                if (c.flags.state == .active) {
                    self.timers.remove(v);
                }

                // If the timer was never fired, we need to fire it with
                // the cancellation notice.
                if (c.flags.state != .dead) {
                    // If we have reset set AND we got a cancellation result,
                    // that means that we were canceled so that we can update
                    // our expiration time.
                    if (v.reset) |r| {
                        v.next = r;
                        v.reset = null;
                        break :timer true;
                    }

                    // We have to set the completion as dead here because
                    // it isn't safe to modify completions after a callback.
                    c.flags.state = .dead;

                    const action = c.callback(c.userdata, self, c, .{ .timer = .cancel });
                    switch (action) {
                        .disarm => {},
                        .rearm => break :timer true,
                    }
                }

                break :timer false;
            },

            else => unreachable,
        };

        // Decrement the active count so we know how many are running for
        // .until_done run semantics.
        if (active) self.active -= 1;

        // If we're rearming, add it again immediately
        if (rearm) self.start(c);
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
        c.* = .{
            .op = .{
                .timer = .{
                    .next = timer_next(next_ms),
                },
            },
            .userdata = userdata,
            .callback = cb,
        };

        self.add(c);
    }

    /// See io_uring.timer_reset for docs.
    pub fn timer_reset(
        self: *Loop,
        c: *Completion,
        c_cancel: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: xev.Callback,
    ) void {
        switch (c.flags.state) {
            .dead, .deleting => {
                self.timer(c, next_ms, userdata, cb);
                return;
            },

            // Adding state we can just modify the metadata and return
            // since the timer isn't in the heap yet.
            .adding => {
                c.op.timer.next = timer_next(next_ms);
                c.userdata = userdata;
                c.callback = cb;
                return;
            },

            .active => {
                // Update the reset time for the timer to the desired time
                // along with all the callbacks.
                c.op.timer.reset = timer_next(next_ms);
                c.userdata = userdata;
                c.callback = cb;

                // If the cancellation is active, we assume its for this timer
                // and do nothing.
                if (c_cancel.state() == .active) return;
                assert(c_cancel.state() == .dead and c.state() == .active);
                c_cancel.* = .{ .op = .{ .cancel = .{ .c = c } } };
                self.add(c_cancel);
            },
        }
    }

    /// Returns the "loop" time in milliseconds. The loop time is updated
    /// once per loop tick, before IO polling occurs. It remains constant
    /// throughout callback execution.
    ///
    /// You can force an update of the "now" value by calling update_now()
    /// at any time from the main thread.
    ///
    /// The clock that is used is not guaranteed. In general, a monotonic
    /// clock source is always used if available. This value should typically
    /// just be used for relative time calculations within the loop, such as
    /// answering the question "did this happen <x> ms ago?".
    pub fn now(self: *Loop) i64 {
        return std.math.lossyCast(i64, @divFloor(self.cached_now, std.time.ns_per_ms));
    }

    /// Update the cached time.
    pub fn update_now(self: *Loop) void {
        if (get_now()) |t| self.cached_now = t else |_| {}
    }

    fn timer_next(next_ms: u64) wasi.timestamp_t {
        // Get the absolute time we'll execute this timer next.
        var now_ts: wasi.timestamp_t = undefined;
        switch (wasi.clock_time_get(@as(u32, @bitCast(posix.CLOCK.MONOTONIC)), 1, &now_ts)) {
            .SUCCESS => {},
            .INVAL => unreachable,
            else => unreachable,
        }

        // TODO: overflow
        now_ts += next_ms * std.time.ns_per_ms;
        return now_ts;
    }

    fn get_now() !wasi.timestamp_t {
        var ts: wasi.timestamp_t = undefined;
        return switch (wasi.clock_time_get(posix.CLOCK.MONOTONIC, 1, &ts)) {
            .SUCCESS => ts,
            .INVAL => error.UnsupportedClock,
            else => |err| posix.unexpectedErrno(err),
        };
    }
};

pub const Completion = struct {
    /// Operation to execute. This is only safe to read BEFORE the completion
    /// is queued. After being queued (with "add"), the operation may change.
    op: Operation = .{ .noop = {} },

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: xev.Callback = xev.noopCallback,

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

    /// Index in the batch array.
    batch_idx: usize = 0,

    const State = enum(u3) {
        /// completion is not part of any loop
        dead = 0,

        /// completion is in the submission queue
        adding = 1,

        /// completion is in the deletion queue
        deleting = 2,

        /// completion is actively being sent to poll
        active = 3,
    };

    /// Returns the state of this completion. There are some things to
    /// be caution about when calling this function.
    ///
    /// First, this is only safe to call from the main thread. This cannot
    /// be called from any other thread.
    ///
    /// Second, if you are using default "undefined" completions, this will
    /// NOT return a valid value if you access it. You must zero your
    /// completion using ".{}". You only need to zero the completion once.
    /// Once the completion is in use, it will always be valid.
    ///
    /// Third, if you stop the loop (loop.stop()), the completions registered
    /// with the loop will NOT be reset to a dead state.
    pub fn state(self: Completion) xev.CompletionState {
        return switch (self.flags.state) {
            .dead => .dead,
            .adding, .deleting, .active => .active,
        };
    }

    fn subscription(self: *Completion) wasi.subscription_t {
        return switch (self.op) {
            .read => |v| .{
                .userdata = @intFromPtr(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_READ,
                    .u = .{
                        .fd_read = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .pread => |v| .{
                .userdata = @intFromPtr(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_READ,
                    .u = .{
                        .fd_read = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .write => |v| .{
                .userdata = @intFromPtr(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_WRITE,
                    .u = .{
                        .fd_write = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .pwrite => |v| .{
                .userdata = @intFromPtr(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_WRITE,
                    .u = .{
                        .fd_write = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .accept => |v| .{
                .userdata = @intFromPtr(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_READ,
                    .u = .{
                        .fd_read = .{
                            .fd = v.socket,
                        },
                    },
                },
            },

            .recv => |v| .{
                .userdata = @intFromPtr(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_READ,
                    .u = .{
                        .fd_read = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .send => |v| .{
                .userdata = @intFromPtr(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_WRITE,
                    .u = .{
                        .fd_write = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .close,
            .async_wait,
            .noop,
            .shutdown,
            .cancel,
            .timer,
            => unreachable,
        };
    }

    /// Perform the operation associated with this completion. This will
    /// perform the full blocking operation for the completion.
    fn perform(self: *Completion) Result {
        return switch (self.op) {
            // This should never happen because we always do these synchronously
            // or in another location.
            .close,
            .async_wait,
            .noop,
            .shutdown,
            .cancel,
            .timer,
            => unreachable,

            .accept => |*op| res: {
                var out_fd: posix.fd_t = undefined;
                break :res .{
                    .accept = switch (wasi.sock_accept(op.socket, 0, &out_fd)) {
                        .SUCCESS => out_fd,
                        else => |err| posix.unexpectedErrno(err),
                    },
                };
            },

            .read => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| posix.read(op.fd, v),
                    .array => |*v| posix.read(op.fd, v),
                };

                break :res .{
                    .read = if (n_) |n|
                        if (n == 0) error.EOF else n
                    else |err|
                        err,
                };
            },

            .pread => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| posix.pread(op.fd, v, op.offset),
                    .array => |*v| posix.pread(op.fd, v, op.offset),
                };

                break :res .{
                    .pread = if (n_) |n|
                        if (n == 0) error.EOF else n
                    else |err|
                        err,
                };
            },

            .write => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| posix.write(op.fd, v),
                    .array => |*v| posix.write(op.fd, v.array[0..v.len]),
                };

                break :res .{
                    .write = if (n_) |n| n else |err| err,
                };
            },

            .pwrite => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| posix.pwrite(op.fd, v, op.offset),
                    .array => |*v| posix.pwrite(op.fd, v.array[0..v.len], op.offset),
                };

                break :res .{
                    .pwrite = if (n_) |n| n else |err| err,
                };
            },

            .recv => |*op| res: {
                var n: usize = undefined;
                var roflags: wasi.roflags_t = undefined;
                const errno = switch (op.buffer) {
                    .slice => |v| slice: {
                        var iovs = [1]posix.iovec{posix.iovec{
                            .base = v.ptr,
                            .len = v.len,
                        }};

                        break :slice wasi.sock_recv(
                            op.fd,
                            @ptrCast(&iovs[0]),
                            iovs.len,
                            0,
                            &n,
                            &roflags,
                        );
                    },

                    .array => |*v| array: {
                        var iovs = [1]posix.iovec{posix.iovec{
                            .base = v,
                            .len = v.len,
                        }};

                        break :array wasi.sock_recv(
                            op.fd,
                            @ptrCast(&iovs[0]),
                            iovs.len,
                            0,
                            &n,
                            &roflags,
                        );
                    },
                };

                break :res .{
                    .recv = switch (errno) {
                        .SUCCESS => n,
                        else => |err| posix.unexpectedErrno(err),
                    },
                };
            },

            .send => |*op| res: {
                var n: usize = undefined;
                const errno = switch (op.buffer) {
                    .slice => |v| slice: {
                        var iovs = [1]posix.iovec_const{posix.iovec_const{
                            .base = v.ptr,
                            .len = v.len,
                        }};

                        break :slice wasi.sock_send(
                            op.fd,
                            @ptrCast(&iovs[0]),
                            iovs.len,
                            0,
                            &n,
                        );
                    },

                    .array => |*v| array: {
                        var iovs = [1]posix.iovec_const{posix.iovec_const{
                            .base = &v.array,
                            .len = v.len,
                        }};

                        break :array wasi.sock_send(
                            op.fd,
                            @ptrCast(&iovs[0]),
                            iovs.len,
                            0,
                            &n,
                        );
                    },
                };

                break :res .{
                    .send = switch (errno) {
                        .SUCCESS => n,
                        else => |err| posix.unexpectedErrno(err),
                    },
                };
            },
        };
    }
};

pub const OperationType = enum {
    noop,
    cancel,
    accept,
    read,
    pread,
    write,
    pwrite,
    send,
    recv,
    shutdown,
    close,
    timer,
    async_wait,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    noop: void,
    cancel: CancelError!void,
    accept: AcceptError!posix.fd_t,
    read: ReadError!usize,
    pread: ReadError!usize,
    write: WriteError!usize,
    pwrite: WriteError!usize,
    send: WriteError!usize,
    recv: ReadError!usize,
    shutdown: ShutdownError!void,
    close: CloseError!void,
    timer: TimerError!TimerTrigger,
    async_wait: AsyncError!void,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    noop: void,

    cancel: struct {
        c: *Completion,
    },

    accept: struct {
        socket: posix.socket_t,
    },

    read: struct {
        fd: posix.fd_t,
        buffer: ReadBuffer,
    },

    pread: struct {
        fd: posix.fd_t,
        buffer: ReadBuffer,
        offset: u64,
    },

    write: struct {
        fd: posix.fd_t,
        buffer: WriteBuffer,
    },

    pwrite: struct {
        fd: posix.fd_t,
        buffer: WriteBuffer,
        offset: u64,
    },

    send: struct {
        fd: posix.fd_t,
        buffer: WriteBuffer,
    },

    recv: struct {
        fd: posix.fd_t,
        buffer: ReadBuffer,
    },

    shutdown: struct {
        socket: posix.socket_t,
        how: posix.ShutdownHow = .both,
    },

    close: struct {
        fd: posix.fd_t,
    },

    timer: Timer,

    async_wait: struct {
        wakeup: Loop.WakeupType = Loop.wakeup_init,
    },
};

const Timer = struct {
    /// The absolute time to fire this timer next.
    next: wasi.timestamp_t,

    /// Only used internally. If this is non-null and timer is
    /// CANCELLED, then the timer is rearmed automatically with this
    /// as the next time. The callback will not be called on the
    /// cancellation.
    reset: ?wasi.timestamp_t = null,

    /// Internal heap fields.
    heap: heap.IntrusiveField(Timer) = .{},

    /// We point back to completion for now. When issue[1] is fixed,
    /// we can juse use that from our heap fields.
    /// [1]: https://github.com/ziglang/zig/issues/6611
    c: *Completion = undefined,

    fn less(_: void, a: *const Timer, b: *const Timer) bool {
        return a.next < b.next;
    }
};

pub const CancelError = error{
    /// Invalid operation to cancel. You cannot cancel a cancel operation.
    InvalidOp,
};

pub const CloseError = error{
    Unknown,
};

pub const AcceptError = Batch.Error || error{
    Unexpected,
};

pub const ConnectError = error{};

pub const ShutdownError = error{
    Unexpected,
};

pub const ReadError = Batch.Error || posix.ReadError || posix.PReadError ||
    error{
        EOF,
        Unknown,
    };

pub const WriteError = Batch.Error || posix.WriteError || posix.PWriteError ||
    error{
        Unknown,
    };

pub const AsyncError = error{
    Unknown,
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

/// ReadBuffer are the various options for reading.
pub const ReadBuffer = union(enum) {
    /// Read into this slice.
    slice: []u8,

    /// Read into this array, just set this to undefined and it will
    /// be populated up to the size of the array. This is an option because
    /// the other union members force a specific size anyways so this lets us
    /// use the other size in the union to support small reads without worrying
    /// about buffer allocation.
    ///
    /// To know the size read you have to use the return value of the
    /// read operations (i.e. recv).
    ///
    /// Note that the union at the time of this writing could accomodate a
    /// much larger fixed size array here but we want to retain flexiblity
    /// for future fields.
    array: [32]u8,

    // TODO: future will have vectors
};

/// WriteBuffer are the various options for writing.
pub const WriteBuffer = union(enum) {
    /// Write from this buffer.
    slice: []const u8,

    /// Write from this array. See ReadBuffer.array for why we support this.
    array: struct {
        array: [32]u8,
        len: usize,
    },

    // TODO: future will have vectors
};

/// A batch of subscriptions to send to poll_oneoff.
const Batch = struct {
    pub const capacity = 1024;

    /// The array of subscriptions. Sub zero is ALWAYS our loop timeout
    /// so the actual capacity of this for user completions is (len - 1).
    array: [capacity]wasi.subscription_t = undefined,

    /// The length of the used slots in the array including our reserved slot.
    len: usize = 1,

    pub const Error = error{BatchFull};

    /// Initialize a batch entry for the given completion. This will
    /// store the batch index on the completion.
    pub fn get(self: *Batch, c: *Completion) Error!*wasi.subscription_t {
        if (self.len >= self.array.len) return error.BatchFull;
        c.batch_idx = self.len;
        self.len += 1;
        return &self.array[c.batch_idx];
    }

    /// Put an entry back.
    pub fn put(self: *Batch, c: *Completion) void {
        assert(c.batch_idx > 0);
        assert(self.len > 1);

        const old_idx = c.batch_idx;
        c.batch_idx = 0;
        self.len -= 1;

        // If we're empty then we don't worry about swapping.
        if (self.len == 0) return;

        // We're not empty so swap the value we just removed with the
        // last one so our empty slot is always at the end.
        self.array[old_idx] = self.array[self.len];
        const swapped = @as(*Completion, @ptrFromInt(@as(usize, @intCast(self.array[old_idx].userdata))));
        swapped.batch_idx = old_idx;
    }

    test {
        const testing = std.testing;

        var b: Batch = .{};
        var cs: [capacity - 1]Completion = undefined;
        for (&cs, 0..) |*c, i| {
            c.* = .{ .op = undefined, .callback = undefined };
            const sub = try b.get(c);
            sub.* = .{ .userdata = @intFromPtr(c), .u = undefined };
            try testing.expectEqual(@as(usize, i + 1), c.batch_idx);
        }

        var bad: Completion = .{ .op = undefined, .callback = undefined };
        try testing.expectError(error.BatchFull, b.get(&bad));

        // Put one back
        const old = cs[4].batch_idx;
        const replace = &cs[cs.len - 1];
        b.put(&cs[4]);
        try testing.expect(b.len == capacity - 1);
        try testing.expect(b.array[old].userdata == @intFromPtr(replace));
        try testing.expect(replace.batch_idx == old);

        // Put it back in
        const sub = try b.get(&cs[4]);
        sub.* = .{ .userdata = @intFromPtr(&cs[4]), .u = undefined };
        try testing.expect(cs[4].batch_idx == capacity - 1);
    }
};

test "wasi: loop time" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // should never init zero
    const now = loop.now();
    try testing.expect(now > 0);

    // should update on a loop tick
    while (now == loop.now()) try loop.run(.no_wait);
}

test "wasi: timer" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
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
            const b = @as(*bool, @ptrCast(ud.?));
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
            const b = @as(*bool, @ptrCast(ud.?));
            b.* = true;
            return .disarm;
        }
    }).callback);

    // State checking
    try testing.expect(c1.state() == .active);
    try testing.expect(c2.state() == .active);

    // Tick
    while (!called) try loop.run(.no_wait);
    try testing.expect(called);
    try testing.expect(!called2);

    // State checking
    try testing.expect(c1.state() == .dead);
    try testing.expect(c2.state() == .active);
}

test "wasi: timer reset" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const cb: xev.Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const v = @as(*?TimerTrigger, @ptrCast(ud.?));
            v.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback;

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, cb);

    // We know timer won't be called from the timer test previously.
    try loop.run(.no_wait);
    try testing.expect(trigger == null);

    // Reset the timer
    var c_cancel: Completion = .{};
    loop.timer_reset(&c1, &c_cancel, 1, &trigger, cb);
    try testing.expect(c1.state() == .active);
    try testing.expect(c_cancel.state() == .active);

    // Run
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);
    try testing.expect(c1.state() == .dead);
    try testing.expect(c_cancel.state() == .dead);
}

test "wasi: timer reset before tick" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const cb: xev.Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const v = @as(*?TimerTrigger, @ptrCast(ud.?));
            v.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback;

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, cb);

    // Reset the timer
    var c_cancel: Completion = .{};
    loop.timer_reset(&c1, &c_cancel, 1, &trigger, cb);
    try testing.expect(c1.state() == .active);
    try testing.expect(c_cancel.state() == .dead);

    // Run
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);
    try testing.expect(c1.state() == .dead);
    try testing.expect(c_cancel.state() == .dead);
}

test "wasi: timer reset after trigger" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const cb: xev.Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const v = @as(*?TimerTrigger, @ptrCast(ud.?));
            v.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback;

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: Completion = undefined;
    loop.timer(&c1, 1, &trigger, cb);

    // Run the timer
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);
    try testing.expect(c1.state() == .dead);
    trigger = null;

    // Reset the timer
    var c_cancel: Completion = .{};
    loop.timer_reset(&c1, &c_cancel, 1, &trigger, cb);
    try testing.expect(c1.state() == .active);
    try testing.expect(c_cancel.state() == .dead);

    // Run
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);
    try testing.expect(c1.state() == .dead);
    try testing.expect(c_cancel.state() == .dead);
}

test "wasi: timer cancellation" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @as(*?TimerTrigger, @ptrCast(@alignCast(ud.?)));
            ptr.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback);

    // Tick and verify we're not called.
    try loop.run(.no_wait);
    try testing.expect(trigger == null);

    // Cancel the timer
    var called = false;
    var c_cancel: xev.Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.cancel catch unreachable;
                const ptr = @as(*bool, @ptrCast(@alignCast(ud.?)));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
    try testing.expect(trigger.? == .cancel);
}

test "wasi: canceling a completed operation" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 1, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @as(*?TimerTrigger, @ptrCast(@alignCast(ud.?)));
            ptr.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback);

    // Tick and verify we're not called.
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);

    // Cancel the timer
    var called = false;
    var c_cancel: xev.Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.cancel catch unreachable;
                const ptr = @as(*bool, @ptrCast(@alignCast(ud.?)));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
    try testing.expect(trigger.? == .expiration);
}

test "wasi: file" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Create a file
    const path = "zig-cache/wasi-test-file.txt";
    const dir = std.fs.cwd();
    // We can't use dir.createFile yet: https://github.com/ziglang/zig/issues/14324
    const f = f: {
        const w = wasi;
        const oflags = w.O.CREAT | w.O.TRUNC;
        const base: w.rights_t = w.RIGHT.FD_WRITE |
            w.RIGHT.FD_READ |
            w.RIGHT.FD_DATASYNC |
            w.RIGHT.FD_SEEK |
            w.RIGHT.FD_TELL |
            w.RIGHT.FD_FDSTAT_SET_FLAGS |
            w.RIGHT.FD_SYNC |
            w.RIGHT.FD_ALLOCATE |
            w.RIGHT.FD_ADVISE |
            w.RIGHT.FD_FILESTAT_SET_TIMES |
            w.RIGHT.FD_FILESTAT_SET_SIZE |
            w.RIGHT.FD_FILESTAT_GET |
            w.RIGHT.POLL_FD_READWRITE;
        const fdflags: w.fdflags_t = w.FDFLAG.SYNC | w.FDFLAG.RSYNC | w.FDFLAG.DSYNC;
        const fd = try posix.openatWasi(dir.fd, path, 0x0, oflags, 0x0, base, fdflags);
        break :f std.fs.File{ .handle = fd };
    };
    defer dir.deleteFile(path) catch unreachable;
    defer f.close();

    // Start a reader
    var read_buf: [128]u8 = undefined;
    var read_len: ?usize = null;
    var c_read: xev.Completion = .{
        .op = .{
            .read = .{
                .fd = f.handle,
                .buffer = .{ .slice = &read_buf },
            },
        },

        .userdata = &read_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @as(*?usize, @ptrCast(@alignCast(ud.?)));
                ptr.* = r.read catch |err| switch (err) {
                    error.EOF => 0,
                    else => unreachable,
                };
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_read);

    // Tick. The reader should NOT read because we are blocked with no data.
    try loop.run(.until_done);
    try testing.expect(read_len.? == 0);

    // Start a writer
    const write_buf = "hello!";
    var write_len: ?usize = null;
    var c_write: xev.Completion = .{
        .op = .{
            .write = .{
                .fd = f.handle,
                .buffer = .{ .slice = write_buf },
            },
        },

        .userdata = &write_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @as(*?usize, @ptrCast(@alignCast(ud.?)));
                ptr.* = r.write catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_write);

    try loop.run(.until_done);
    try testing.expect(write_len.? == write_buf.len);

    // Close
    var c_close: xev.Completion = .{
        .op = .{
            .close = .{
                .fd = f.handle,
            },
        },

        .userdata = null,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = ud;
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_close);
    try loop.run(.until_done);

    // Read and verify we've written
    const f_verify = try dir.openFile(path, .{});
    defer f_verify.close();
    read_len = try f_verify.readAll(&read_buf);
    try testing.expectEqualStrings(write_buf, read_buf[0..read_len.?]);
}
