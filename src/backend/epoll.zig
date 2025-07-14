const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const posix = std.posix;
const queue = @import("../queue.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const heap = @import("../heap.zig");
const ThreadPool = @import("../ThreadPool.zig");
const Async = @import("../main.zig").Epoll.Async;

const looppkg = @import("../loop.zig");
const Options = looppkg.Options;
const RunMode = looppkg.RunMode;
const Callback = looppkg.Callback(@This());
const CallbackAction = looppkg.CallbackAction;
const CompletionState = looppkg.CompletionState;
const noopCallback = looppkg.NoopCallback(@This());

/// True if epoll is available on this platform.
pub fn available() bool {
    return builtin.os.tag == .linux;
}

/// Epoll backend.
///
/// WARNING: this backend is a bit of a mess. It is missing features and in
/// general is in much poorer quality than all of the other backends. It
/// isn't meant to really be used yet. We should remodel this in the style of
/// the kqueue backend.
pub const Loop = struct {
    const TimerHeap = heap.Intrusive(Operation.Timer, void, Operation.Timer.less);
    const TaskCompletionQueue = queue_mpsc.Intrusive(Completion);

    fd: posix.fd_t,

    /// The eventfd that this epoll queue always has a filter for. Writing
    /// an empty message to this eventfd can be used to wake up the loop
    /// at any time. Waking up the loop via this eventfd won't trigger any
    /// particular completion, it just forces tick to cycle.
    eventfd: Async,

    /// The number of active completions. This DOES NOT include completions that
    /// are queued in the submissions queue.
    active: usize = 0,

    /// Our queue of submissions that we want to enqueue on the next tick.
    submissions: queue.Intrusive(Completion) = .{},

    /// The queue for completions to delete from the epoll fd.
    deletions: queue.Intrusive(Completion) = .{},

    /// Heap of timers.
    timers: TimerHeap = .{ .context = {} },

    /// The thread pool to use for blocking operations that epoll can't do.
    thread_pool: ?*ThreadPool,

    /// The MPSC queue for completed completions from the thread pool.
    thread_pool_completions: TaskCompletionQueue,

    /// Cached time
    cached_now: posix.timespec,

    /// Some internal fields we can pack for better space.
    flags: packed struct {
        /// True once it is initialized.
        init: bool = false,

        /// Whether we're in a run or not (to prevent nested runs).
        in_run: bool = false,

        /// Whether our loop is in a stopped state or not.
        stopped: bool = false,
    } = .{},

    pub fn init(options: Options) !Loop {
        var eventfd = try Async.init();
        errdefer eventfd.deinit();

        var res: Loop = .{
            .fd = try posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC),
            .eventfd = eventfd,
            .thread_pool = options.thread_pool,
            .thread_pool_completions = undefined,
            .cached_now = undefined,
        };
        res.update_now();
        return res;
    }

    pub fn deinit(self: *Loop) void {
        posix.close(self.fd);
        self.eventfd.deinit();
    }

    /// Run the event loop. See RunMode documentation for details on modes.
    /// Once the loop is run, the pointer MUST remain stable.
    pub fn run(self: *Loop, mode: RunMode) !void {
        switch (mode) {
            .no_wait => try self.tick(0),
            .once => try self.tick(1),
            .until_done => while (!self.done()) try self.tick(1),
        }
    }

    fn done(self: *Loop) bool {
        return self.flags.stopped or (self.active == 0 and
            self.submissions.empty());
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

    /// Add a completion to the loop.
    pub fn add(self: *Loop, completion: *Completion) void {
        switch (completion.flags.state) {
            // Already adding, forget about it.
            .adding => return,

            // If it is dead we're good. If we're deleting we'll ignore it
            // while we're processing.
            .dead,
            .deleting,
            => {},

            .active => unreachable,
        }
        completion.flags.state = .adding;

        // We just add the completion to the queue. Failures can happen
        // at tick time...
        self.submissions.push(completion);
    }

    /// Delete a completion from the loop.
    pub fn delete(self: *Loop, completion: *Completion) void {
        switch (completion.flags.state) {
            // Already deleted
            .deleting => return,

            // If we're active then we will stop it and remove from epoll.
            // If we're adding then we'll ignore it when adding.
            .dead, .active, .adding => {},
        }
        completion.flags.state = .deleting;

        self.deletions.push(completion);
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
        // If anything overflows we just return the max value.
        const max = std.math.maxInt(i64);

        // Calculate all the values, being careful about overflows in order
        // to just return the maximum value.
        const sec = std.math.mul(isize, self.cached_now.sec, std.time.ms_per_s) catch return max;
        const nsec = @divFloor(self.cached_now.nsec, std.time.ns_per_ms);
        return std.math.lossyCast(i64, sec +| nsec);
    }

    /// Update the cached time.
    pub fn update_now(self: *Loop) void {
        if (posix.clock_gettime(posix.CLOCK.MONOTONIC)) |new_time| {
            self.cached_now = new_time;
        } else |_| {
            // Errors are ignored.
        }
    }

    /// Add a timer to the loop. The timer will execute in "next_ms". This
    /// is oneshot: the timer will not repeat. To repeat a timer, either
    /// schedule another in your callback or return rearm from the callback.
    pub fn timer(
        self: *Loop,
        c: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: Callback,
    ) void {
        c.* = .{
            .op = .{
                .timer = .{
                    .next = self.timer_next(next_ms),
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
        comptime cb: Callback,
    ) void {
        switch (c.flags.state) {
            .dead, .deleting => {
                self.timer(c, next_ms, userdata, cb);
                return;
            },

            // Adding state we can just modify the metadata and return
            // since the timer isn't in the heap yet.
            .adding => {
                c.op.timer.next = self.timer_next(next_ms);
                c.userdata = userdata;
                c.callback = cb;
                return;
            },

            .active => {
                // Update the reset time for the timer to the desired time
                // along with all the callbacks.
                c.op.timer.reset = self.timer_next(next_ms);
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

    fn timer_next(self: *Loop, next_ms: u64) posix.timespec {
        // Get the timestamp of the absolute time that we'll execute this timer.
        // There are lots of failure scenarios here in math. If we see any
        // of them we just use the maximum value.
        const max: posix.timespec = .{
            .sec = std.math.maxInt(isize),
            .nsec = std.math.maxInt(isize),
        };

        const next_s = std.math.cast(isize, next_ms / std.time.ms_per_s) orelse
            return max;
        const next_ns = std.math.cast(
            isize,
            (next_ms % std.time.ms_per_s) * std.time.ns_per_ms,
        ) orelse return max;

        return .{
            .sec = std.math.add(isize, self.cached_now.sec, next_s) catch
                return max,
            .nsec = std.math.add(isize, self.cached_now.nsec, next_ns) catch
                return max,
        };
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

        // Initialize
        if (!self.flags.init) {
            self.flags.init = true;

            if (self.thread_pool != null) {
                self.thread_pool_completions.init();
            }

            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                .data = .{ .fd = self.eventfd.fd },
            };
            posix.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                self.eventfd.fd,
                &ev,
            ) catch |err| {
                // We reset initialization because we can't do anything
                // safely unless we get this mach port registered!
                self.flags.init = false;
                return err;
            };
        }

        // Submit all the submissions. We copy the submission queue so that
        // any resubmits don't cause an infinite loop.
        var wait_rem: usize = @intCast(wait);
        var queued = self.submissions;
        self.submissions = .{};
        while (queued.pop()) |c| {
            // We ignore any completions that aren't in the adding state.
            // This usually means that we switched them to be deleted or
            // something.
            if (c.flags.state != .adding) continue;

            // These operations happen synchronously. Ensure they are
            // decremented from wait_rem.
            switch (c.op) {
                .cancel,
                // should noop be counted?
                // .noop,
                .shutdown,
                .timer,
                => wait_rem -|= 1,
                else => {},
            }

            self.start(c);
        }

        // Handle all deletions so we don't wait for them.
        while (self.deletions.pop()) |c| {
            if (c.flags.state != .deleting) continue;
            self.stop_completion(c);
        }

        // If we have no active handles then we return no matter what.
        if (self.active == 0) {
            // We still have to update our concept of "now".
            self.update_now();
            return;
        }

        // Wait and process events. We only do this if we have any active.
        var events: [1024]linux.epoll_event = undefined;
        while (self.active > 0 and (wait == 0 or wait_rem > 0)) {
            self.update_now();
            const now_timer: Operation.Timer = .{ .next = self.cached_now };

            // Run our expired timers
            while (self.timers.peek()) |t| {
                if (!Operation.Timer.less({}, t, &now_timer)) break;

                // Remove the timer
                assert(self.timers.deleteMin().? == t);

                // Mark completion as done
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

            // Run our completed thread pool work
            if (self.thread_pool != null) {
                while (self.thread_pool_completions.pop()) |c| {
                    // Mark completion as done
                    c.flags.state = .dead;
                    self.active -= 1;

                    // Lower our remaining count
                    wait_rem -|= 1;

                    // Invoke
                    const action = c.callback(c.userdata, self, c, c.task_result);
                    switch (action) {
                        .disarm => {},
                        .rearm => self.start(c),
                    }
                }
            }

            // Determine our next timeout based on the timers
            const timeout: i32 = if (wait_rem == 0) 0 else timeout: {
                // If we have a timer, we want to set the timeout to our next
                // timer value. If we have no timer, we wait forever.
                const t = self.timers.peek() orelse break :timeout -1;

                // Determine the time in milliseconds.
                const ms_now = @as(u64, @intCast(self.cached_now.sec)) * std.time.ms_per_s +
                    @as(u64, @intCast(self.cached_now.nsec)) / std.time.ns_per_ms;
                const ms_next = @as(u64, @intCast(t.next.sec)) * std.time.ms_per_s +
                    @as(u64, @intCast(t.next.nsec)) / std.time.ns_per_ms;
                break :timeout @as(i32, @intCast(ms_next -| ms_now));
            };

            const n = posix.epoll_wait(self.fd, &events, timeout);
            if (n < 0) {
                switch (posix.errno(n)) {
                    .INTR => continue,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }

            // Process all our events and invoke their completion handlers
            for (events[0..n]) |ev| {
                // Handle wakeup eventfd
                if (ev.data.fd == self.eventfd.fd) {
                    var buffer: u64 = undefined;
                    _ = posix.read(self.eventfd.fd, std.mem.asBytes(&buffer)) catch {};
                    continue;
                }

                const c: *Completion = @ptrFromInt(@as(usize, @intCast(ev.data.ptr)));

                // We get the fd and mark this as in progress we can properly
                // clean this up late.r
                const fd = if (c.flags.dup) c.flags.dup_fd else c.fd();
                const close_dup = c.flags.dup;
                c.flags.state = .dead;

                const res = c.perform();
                const action = c.callback(c.userdata, self, c, res);
                switch (action) {
                    .disarm => {
                        // We can't use self.stop because we can't trust
                        // that c is still a valid pointer.
                        if (fd) |v| {
                            posix.epoll_ctl(
                                self.fd,
                                linux.EPOLL.CTL_DEL,
                                v,
                                null,
                            ) catch unreachable;

                            if (close_dup) {
                                posix.close(v);
                            }
                        }

                        self.active -= 1;
                    },

                    // For epoll, epoll remains armed by default. We have to
                    // reset the state, that is all.
                    .rearm => c.flags.state = .active,
                }
            }

            if (wait == 0) break;
            wait_rem -|= n;
        }
    }

    /// Shedule a completion to run on a thread.
    fn thread_schedule(self: *Loop, c: *Completion) !void {
        const pool = self.thread_pool orelse return error.ThreadPoolRequired;

        // Setup our completion state so that thread_perform can do stuff
        c.task_loop = self;
        c.task_completions = &self.thread_pool_completions;
        c.task = .{ .callback = Loop.thread_perform };

        // We need to mark this completion as active before we schedule.
        c.flags.state = .active;
        self.active += 1;

        // Schedule it, from this point forward its not safe to touch c.
        pool.schedule(ThreadPool.Batch.from(&c.task));
    }

    /// This is the main callback for the threadpool to perform work
    /// on completions for the loop.
    fn thread_perform(t: *ThreadPool.Task) void {
        const c: *Completion = @fieldParentPtr("task", t);

        // Do our task
        c.task_result = c.perform();

        // Add to our completion queue
        c.task_completions.push(c);

        // Wake up our main loop
        c.task_loop.wakeup() catch {};
    }

    /// Sends an empty message to this loop's eventfd so that it wakes up.
    fn wakeup(self: *Loop) !void {
        try self.eventfd.notify();
    }

    fn start(self: *Loop, completion: *Completion) void {
        const res_: ?Result = switch (completion.op) {
            .noop => {
                completion.flags.state = .dead;
                return;
            },

            .cancel => |v| res: {
                if (completion.flags.threadpool) {
                    break :res .{ .cancel = error.ThreadPoolUnsupported };
                }

                // We stop immediately. We only stop if we are in the
                // "adding" state because cancellation or any other action
                // means we're complete already.
                if (completion.flags.state == .adding) {
                    if (v.c.op == .cancel) @panic("cannot cancel a cancellation");
                    self.stop_completion(v.c);
                }

                // We always run timers
                break :res .{ .cancel = {} };
            },

            .accept => res: {
                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.IN,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .accept = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .accept = err };
            },

            .connect => |*v| res: {
                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .connect = err };

                if (posix.connect(fd, &v.addr.any, v.addr.getOsSockLen())) {
                    break :res .{ .connect = {} };
                } else |err| switch (err) {
                    // If we would block then we register with epoll
                    error.WouldBlock => {},

                    // Any other error we just return immediately
                    else => break :res .{ .connect = err },
                }

                // If connect returns WouldBlock then we register for OUT events
                // and are notified of connection completion that way.
                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.OUT,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .connect = err };
            },

            .read => res: {
                if (completion.flags.threadpool) {
                    if (self.thread_schedule(completion)) |_|
                        return
                    else |err|
                        break :res .{ .read = err };
                }

                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .read = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .read = err };
            },

            .pread => res: {
                if (completion.flags.threadpool) {
                    if (self.thread_schedule(completion)) |_|
                        return
                    else |err|
                        break :res .{ .read = err };
                }

                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .read = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .read = err };
            },

            .write => res: {
                if (completion.flags.threadpool) {
                    if (self.thread_schedule(completion)) |_|
                        return
                    else |err|
                        break :res .{ .write = err };
                }

                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.OUT,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .write = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .write = err };
            },

            .pwrite => res: {
                if (completion.flags.threadpool) {
                    if (self.thread_schedule(completion)) |_|
                        return
                    else |err|
                        break :res .{ .write = err };
                }

                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.OUT,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .write = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .write = err };
            },

            .send => res: {
                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.OUT,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .send = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .send = err };
            },

            .recv => res: {
                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .recv = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .recv = err };
            },

            .sendmsg => |*v| res: {
                if (v.buffer) |_| {
                    @panic("TODO: sendmsg with buffer");
                }

                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.OUT,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .sendmsg = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .sendmsg = err };
            },

            .recvmsg => res: {
                var ev: linux.epoll_event = .{
                    .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .recvmsg = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .recvmsg = err };
            },

            .close => |v| res: {
                if (completion.flags.threadpool) {
                    if (self.thread_schedule(completion)) |_|
                        return
                    else |err|
                        break :res .{ .close = err };
                }

                posix.close(v.fd);
                break :res .{ .close = {} };
            },

            .shutdown => |v| res: {
                break :res .{ .shutdown = posix.shutdown(v.socket, v.how) };
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

            .poll => |v| res: {
                var ev: linux.epoll_event = .{
                    .events = v.events,
                    .data = .{ .ptr = @intFromPtr(completion) },
                };

                const fd = completion.fd_maybe_dup() catch |err| break :res .{ .poll = err };
                break :res if (posix.epoll_ctl(
                    self.fd,
                    linux.EPOLL.CTL_ADD,
                    fd,
                    &ev,
                )) null else |err| .{ .poll = err };
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

        // If the completion was requested on a threadpool we should
        // never reach her.
        assert(!completion.flags.threadpool);

        // Mark the completion as active if we reached this point
        completion.flags.state = .active;

        // Increase our active count
        self.active += 1;
    }

    fn stop_completion(self: *Loop, completion: *Completion) void {
        // Delete. This should never fail.
        const maybe_fd = if (completion.flags.dup) completion.flags.dup_fd else completion.fd();
        if (maybe_fd) |fd| {
            posix.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_DEL,
                fd,
                null,
            ) catch unreachable;
        } else switch (completion.op) {
            .timer => |*v| {
                const c = v.c;

                if (c.flags.state == .active) {
                    // Timers needs to be removed from the timer heap.
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
                        self.active -= 1;
                        self.start(c);
                        return;
                    }

                    const action = c.callback(c.userdata, self, c, .{ .timer = .cancel });
                    switch (action) {
                        .disarm => {},
                        .rearm => {
                            self.active -= 1;
                            self.start(c);
                            return;
                        },
                    }
                }
            },

            else => unreachable,
        }

        // Decrement the active count so we know how many are running for
        // .until_done run semantics.
        if (completion.flags.state == .active) self.active -= 1;

        // Mark the completion as done
        completion.flags.state = .dead;
    }
};

pub const Completion = struct {
    /// Operation to execute. This is only safe to read BEFORE the completion
    /// is queued. After being queued (with "add"), the operation may change.
    op: Operation = .{ .noop = {} },

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: Callback = noopCallback,

    //---------------------------------------------------------------
    // Internal fields

    /// If scheduled on a thread pool, this will be set. This is NOT a
    /// reliable way to get access to the loop and shouldn't be used
    /// except internally.
    task: ThreadPool.Task = undefined,
    task_loop: *Loop = undefined,
    task_completions: *Loop.TaskCompletionQueue = undefined,
    task_result: Result = undefined,

    flags: packed struct {
        /// Watch state of this completion. We use this to determine whether
        /// we're active, adding, deleting, etc. This lets us add and delete
        /// multiple times before a loop tick and handle the state properly.
        state: State = .dead,

        /// Schedule this onto the threadpool rather than epoll. Not all
        /// operations support this.
        threadpool: bool = false,

        /// Set to true to dup the file descriptor for the operation prior
        /// to setting it up with epoll. This is a hack to make it so that
        /// a completion can represent a single op per fd, since epoll requires
        /// a single fd for multiple ops. We don't want to track that esp
        /// since epoll isn't the primary Linux interface.
        dup: bool = false,
        dup_fd: posix.fd_t = 0,
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

        /// completion is registered with epoll
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
    pub fn state(self: Completion) CompletionState {
        return switch (self.flags.state) {
            .dead => .dead,
            .adding, .deleting, .active => .active,
        };
    }

    /// Perform the operation associated with this completion. This will
    /// perform the full blocking operation for the completion.
    fn perform(self: *Completion) Result {
        return switch (self.op) {
            // This should never happen because we always do these synchronously
            // or in another location.
            .cancel,
            .noop,
            .shutdown,
            .timer,
            => unreachable,

            .accept => |*op| .{
                .accept = if (posix.accept(
                    op.socket,
                    &op.addr,
                    &op.addr_size,
                    op.flags,
                )) |v|
                    v
                else |_|
                    error.Unknown,
            },

            .connect => |*op| .{
                .connect = if (posix.getsockoptError(op.socket)) {} else |err| err,
            },

            .poll => .{ .poll = {} },

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

            .write => |*op| .{
                .write = switch (op.buffer) {
                    .slice => |v| posix.write(op.fd, v),
                    .array => |*v| posix.write(op.fd, v.array[0..v.len]),
                },
            },

            .pwrite => |*op| .{
                .pwrite = switch (op.buffer) {
                    .slice => |v| posix.pwrite(op.fd, v, op.offset),
                    .array => |*v| posix.pwrite(op.fd, v.array[0..v.len], op.offset),
                },
            },

            .send => |*op| .{
                .send = switch (op.buffer) {
                    .slice => |v| posix.send(op.fd, v, 0),
                    .array => |*v| posix.send(op.fd, v.array[0..v.len], 0),
                },
            },

            .sendmsg => |*op| .{
                .sendmsg = if (posix.sendmsg(op.fd, op.msghdr, 0)) |v|
                    v
                else |err|
                    err,
            },

            .recvmsg => |*op| res: {
                const res = std.os.linux.recvmsg(op.fd, op.msghdr, 0);
                break :res .{
                    .recvmsg = if (res == 0)
                        error.EOF
                    else if (res > 0)
                        res
                    else switch (posix.errno(res)) {
                        else => |err| posix.unexpectedErrno(err),
                    },
                };
            },

            .recv => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| posix.recv(op.fd, v, 0),
                    .array => |*v| posix.recv(op.fd, v, 0),
                };

                break :res .{
                    .recv = if (n_) |n|
                        if (n == 0) error.EOF else n
                    else |err|
                        err,
                };
            },

            .close => |*op| res: {
                posix.close(op.fd);
                break :res .{ .close = {} };
            },
        };
    }

    /// Return the fd for the completion. This will perform a dup(2) if
    /// requested.
    fn fd_maybe_dup(self: *Completion) error{DupFailed}!posix.fd_t {
        const old_fd = self.fd().?;
        if (!self.flags.dup) return old_fd;
        if (self.flags.dup_fd > 0) return self.flags.dup_fd;

        self.flags.dup_fd = posix.dup(old_fd) catch return error.DupFailed;
        return self.flags.dup_fd;
    }

    /// Returns the fd associated with the completion (if any).
    fn fd(self: *Completion) ?posix.fd_t {
        return switch (self.op) {
            .accept => |v| v.socket,
            .connect => |v| v.socket,
            .poll => |v| v.fd,
            .read => |v| v.fd,
            .pread => |v| v.fd,
            .recv => |v| v.fd,
            .write => |v| v.fd,
            .pwrite => |v| v.fd,
            .send => |v| v.fd,
            .sendmsg => |v| v.fd,
            .recvmsg => |v| v.fd,
            .close => |v| v.fd,
            .shutdown => |v| v.socket,

            .cancel,
            .timer,
            => null,

            .noop => unreachable,
        };
    }
};

pub const OperationType = enum {
    noop,
    cancel,
    accept,
    connect,
    poll,
    read,
    pread,
    write,
    pwrite,
    send,
    recv,
    sendmsg,
    recvmsg,
    close,
    shutdown,
    timer,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    noop: void,
    cancel: CancelError!void,
    accept: AcceptError!posix.socket_t,
    connect: ConnectError!void,
    poll: PollError!void,
    read: ReadError!usize,
    pread: ReadError!usize,
    write: WriteError!usize,
    pwrite: WriteError!usize,
    send: WriteError!usize,
    recv: ReadError!usize,
    sendmsg: WriteError!usize,
    recvmsg: ReadError!usize,
    close: CloseError!void,
    shutdown: ShutdownError!void,
    timer: TimerError!TimerTrigger,
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
        addr: posix.sockaddr = undefined,
        addr_size: posix.socklen_t = @sizeOf(posix.sockaddr),
        flags: u32 = posix.SOCK.CLOEXEC,
    },

    connect: struct {
        socket: posix.socket_t,
        addr: std.net.Address,
    },

    /// Poll for events but do not perform any operations on them being
    /// ready. The "events" field are a OR-ed list of EPOLL events.
    poll: struct {
        fd: posix.fd_t,
        events: u32,
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

    sendmsg: struct {
        fd: posix.fd_t,
        msghdr: *posix.msghdr_const,

        /// Optionally, a write buffer can be specified and the given
        /// msghdr will be populated with information about this buffer.
        buffer: ?WriteBuffer = null,

        /// Do not use this, it is only used internally.
        iov: [1]posix.iovec_const = undefined,
    },

    recvmsg: struct {
        fd: posix.fd_t,
        msghdr: *posix.msghdr,
    },

    close: struct {
        fd: posix.fd_t,
    },

    shutdown: struct {
        socket: posix.socket_t,
        how: posix.ShutdownHow = .both,
    },

    timer: Timer,

    const Timer = struct {
        /// The absolute time to fire this timer next.
        next: std.os.linux.timespec,

        /// Only used internally. If this is non-null and timer is
        /// CANCELLED, then the timer is rearmed automatically with this
        /// as the next time. The callback will not be called on the
        /// cancellation.
        reset: ?std.os.linux.timespec = null,

        /// Internal heap fields.
        heap: heap.IntrusiveField(Timer) = .{},

        /// We point back to completion for now. When issue[1] is fixed,
        /// we can juse use that from our heap fields.
        /// [1]: https://github.com/ziglang/zig/issues/6611
        c: *Completion = undefined,

        fn less(_: void, a: *const Timer, b: *const Timer) bool {
            return a.ns() < b.ns();
        }

        /// Returns the nanoseconds of this timer. Note that maxInt(u64) ns is
        /// 584 years so if we get any overflows we just use maxInt(u64). If
        /// any software is running in 584 years waiting on this timer...
        /// shame on me I guess... but I'll be dead.
        fn ns(self: *const Timer) u64 {
            assert(self.next.sec >= 0);
            assert(self.next.nsec >= 0);

            const max = std.math.maxInt(u64);
            const s_ns = std.math.mul(
                u64,
                @as(u64, @intCast(self.next.sec)),
                std.time.ns_per_s,
            ) catch return max;
            return std.math.add(u64, s_ns, @as(u64, @intCast(self.next.nsec))) catch
                return max;
        }
    };
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

const ThreadPoolError = error{
    ThreadPoolRequired,
    ThreadPoolUnsupported,
};

pub const CancelError = ThreadPoolError || error{
    NotFound,
};

pub const AcceptError = posix.EpollCtlError || error{
    DupFailed,
    Unknown,
};

pub const CloseError = posix.EpollCtlError || ThreadPoolError || error{
    Unknown,
};

pub const PollError = posix.EpollCtlError || error{
    DupFailed,
    Unknown,
};

pub const ShutdownError = posix.EpollCtlError || posix.ShutdownError || error{
    Unknown,
};

pub const ConnectError = posix.EpollCtlError || posix.ConnectError || error{
    DupFailed,
    Unknown,
};

pub const ReadError = ThreadPoolError || posix.EpollCtlError ||
    posix.ReadError ||
    posix.PReadError ||
    posix.RecvFromError ||
    error{
        DupFailed,
        EOF,
        Unknown,
    };

pub const WriteError = ThreadPoolError || posix.EpollCtlError ||
    posix.WriteError ||
    posix.PWriteError ||
    posix.SendError ||
    posix.SendMsgError ||
    error{
        DupFailed,
        Unknown,
    };

pub const TimerError = error{
    Unexpected,
};

pub const TimerTrigger = enum {
    /// Unused with epoll
    request,

    /// Timer expired.
    expiration,

    /// Timer was canceled.
    cancel,
};

test "Completion size" {
    const testing = std.testing;

    // Just so we are aware when we change the size
    try testing.expectEqual(@as(usize, 208), @sizeOf(Completion));
}

test "epoll: default completion" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    var c: Completion = .{};
    loop.add(&c);

    // Tick
    try loop.run(.until_done);

    // Completion should be dead.
    try testing.expect(c.state() == .dead);
}

test "epoll: loop time" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // should never init zero
    const now = loop.now();
    try testing.expect(now > 0);

    // should update on a loop tick
    while (now == loop.now()) try loop.run(.no_wait);
}

test "epoll: stop" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: Completion = undefined;
    loop.timer(&c1, 1_000_000, &called, (struct {
        fn callback(ud: ?*anyopaque, l: *Loop, _: *Completion, r: Result) CallbackAction {
            _ = l;
            _ = r;
            const b = @as(*bool, @ptrCast(ud.?));
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Tick
    try loop.run(.no_wait);
    try testing.expect(!called);

    // Stop
    loop.stop();
    try loop.run(.until_done);
    try testing.expect(!called);
}

test "epoll: timer" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: Completion = undefined;
    loop.timer(&c1, 1, &called, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *Loop,
            _: *Completion,
            r: Result,
        ) CallbackAction {
            _ = l;
            _ = r;
            const b = @as(*bool, @ptrCast(ud.?));
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Add another timer
    var called2 = false;
    var c2: Completion = undefined;
    loop.timer(&c2, 100_000, &called2, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *Loop,
            _: *Completion,
            r: Result,
        ) CallbackAction {
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

test "epoll: timer reset" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const cb: Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *Loop,
            _: *Completion,
            r: Result,
        ) CallbackAction {
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

test "epoll: timer reset before tick" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const cb: Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *Loop,
            _: *Completion,
            r: Result,
        ) CallbackAction {
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

test "epoll: timer reset after trigger" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const cb: Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *Loop,
            _: *Completion,
            r: Result,
        ) CallbackAction {
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

test "epoll: timerfd" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // We'll try with a simple timerfd
    const Timerfd = @import("../linux/timerfd.zig").Timerfd;
    var t = try Timerfd.init(.MONOTONIC, .{});
    defer t.deinit();
    try t.set(.{}, &.{ .value = .{ .nanoseconds = 1 } }, null);

    // Add the timer
    var called = false;
    var c: Completion = .{
        .op = .{
            .read = .{
                .fd = t.fd,
                .buffer = .{ .array = undefined },
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = r.read catch unreachable;
                _ = c;
                _ = l;
                const b = @as(*bool, @ptrCast(ud.?));
                b.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
}

test "epoll: socket accept/connect/send/recv/close" {
    const mem = std.mem;
    const net = std.net;
    const os = posix;
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    var ln = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    errdefer os.close(ln);
    try os.setsockopt(ln, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(ln, &address.any, address.getOsSockLen());
    try os.listen(ln, kernel_backlog);

    // Create a TCP client socket
    var client_conn = try os.socket(
        address.any.family,
        os.SOCK.NONBLOCK | os.SOCK.STREAM | os.SOCK.CLOEXEC,
        0,
    );
    errdefer os.close(client_conn);

    // Accept
    var server_conn: os.socket_t = 0;
    var c_accept: Completion = .{
        .op = .{
            .accept = .{
                .socket = ln,
            },
        },

        .userdata = &server_conn,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                const conn = @as(*os.socket_t, @ptrCast(@alignCast(ud.?)));
                conn.* = r.accept catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_accept);

    // Connect
    var connected = false;
    var c_connect: Completion = .{
        .op = .{
            .connect = .{
                .socket = client_conn,
                .addr = address,
            },
        },

        .userdata = &connected,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                _ = r.connect catch unreachable;
                const b = @as(*bool, @ptrCast(ud.?));
                b.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_connect);

    // Wait for the connection to be established
    try loop.run(.until_done);
    try testing.expect(server_conn > 0);
    try testing.expect(connected);

    // Send
    var c_send: Completion = .{
        .op = .{
            .send = .{
                .fd = client_conn,
                .buffer = .{ .slice = &[_]u8{ 1, 1, 2, 3, 5, 8, 13 } },
            },
        },

        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                _ = r.send catch unreachable;
                _ = ud;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_send);

    // Receive
    var recv_buf: [128]u8 = undefined;
    var recv_len: usize = 0;
    var c_recv: Completion = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &recv_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                const ptr = @as(*usize, @ptrCast(@alignCast(ud.?)));
                ptr.* = r.recv catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    // Wait for the send/receive
    try loop.run(.until_done);
    try testing.expectEqualSlices(u8, c_send.op.send.buffer.slice, recv_buf[0..recv_len]);

    // Shutdown
    var shutdown = false;
    var c_client_shutdown: Completion = .{
        .op = .{
            .shutdown = .{
                .socket = client_conn,
            },
        },

        .userdata = &shutdown,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                _ = r.shutdown catch unreachable;
                const ptr = @as(*bool, @ptrCast(@alignCast(ud.?)));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_shutdown);
    try loop.run(.until_done);
    try testing.expect(shutdown);

    // Read should be EOF
    var eof: ?bool = null;
    c_recv = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &eof,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                const ptr = @as(*?bool, @ptrCast(@alignCast(ud.?)));
                ptr.* = if (r.recv) |_| false else |err| switch (err) {
                    error.EOF => true,
                    else => false,
                };
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    try loop.run(.until_done);
    try testing.expect(eof.? == true);

    // Close
    var c_client_close: Completion = .{
        .op = .{
            .close = .{
                .fd = client_conn,
            },
        },

        .userdata = &client_conn,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @as(*os.socket_t, @ptrCast(@alignCast(ud.?)));
                ptr.* = 0;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_close);

    var c_server_close: Completion = .{
        .op = .{
            .close = .{
                .fd = ln,
            },
        },

        .userdata = &ln,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @as(*os.socket_t, @ptrCast(@alignCast(ud.?)));
                ptr.* = 0;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_server_close);

    // Wait for the sockets to close
    try loop.run(.until_done);
    try testing.expect(ln == 0);
    try testing.expect(client_conn == 0);
}

test "epoll: timer cancellation" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *Loop,
            _: *Completion,
            r: Result,
        ) CallbackAction {
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
    var c_cancel: Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
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

test "epoll: canceling a completed operation" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: Completion = undefined;
    loop.timer(&c1, 1, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *Loop,
            _: *Completion,
            r: Result,
        ) CallbackAction {
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
    var c_cancel: Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
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
