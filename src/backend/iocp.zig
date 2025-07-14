//! Backend to use win32 IOCP.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const windows = @import("../windows.zig");
const queue = @import("../queue.zig");
const heap = @import("../heap.zig");
const posix = std.posix;

const looppkg = @import("../loop.zig");
const Options = looppkg.Options;
const RunMode = looppkg.RunMode;
const Callback = looppkg.Callback(@This());
const CallbackAction = looppkg.CallbackAction;
const CompletionState = looppkg.CompletionState;
const noopCallback = looppkg.NoopCallback(@This());

const log = std.log.scoped(.libxev_iocp);

/// True if this backend is available on this platform.
pub fn available() bool {
    return switch (builtin.os.tag) {
        .windows => true,
        else => false,
    };
}

pub const Loop = struct {
    const TimerHeap = heap.Intrusive(Timer, void, Timer.less);

    /// The handle to the IO completion port.
    iocp_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE,

    /// The number of active completions. This DOES NOT include completions that are queued in the
    /// submissions queue.
    active: usize = 0,

    /// Our queue of submissions that we want to enqueue on the next tick.
    /// These are NOT started.
    submissions: queue.Intrusive(Completion) = .{},

    /// The queue of cancellation requests. These will point to the completion that we need to
    /// cancel. We don't enqueue the exact completion to cancel because it may be in another queue.
    cancellations: queue.Intrusive(Completion) = .{},

    /// Our queue of completed completions where the callback hasn't been called yet, but the
    /// "result" field should be set on every completion. This is used to delay completion callbacks
    /// until the next tick.
    completions: queue.Intrusive(Completion) = .{},

    /// Our queue of waiting completions
    asyncs: queue.Intrusive(Completion) = .{},

    /// Heap of timers.
    timers: TimerHeap = .{ .context = {} },

    /// Cached time
    cached_now: u64,

    /// Duration of a tick of Windows QueryPerformanceCounter.
    qpc_duration: u64,

    /// Some internal fields we can pack for better space.
    flags: packed struct {
        /// Whether we're in a run of not (to prevent nested runs).
        in_run: bool = false,

        /// Whether our loop is in a stopped state or not.
        stopped: bool = false,
    } = .{},

    /// Initialize a new IOCP-backed event loop. See the Options docs
    /// for what options matter for IOCP.
    pub fn init(options: Options) !Loop {
        _ = options;

        // Get the duration of the QueryPerformanceCounter.
        // We should check if the division is lossless, but it returns 10_000_000 on my machine so
        // we'll handle that later.
        const qpc_duration = 1_000_000_000 / windows.QueryPerformanceFrequency();

        // This creates a new Completion Port
        const handle = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 1);
        var res: Loop = .{
            .iocp_handle = handle,
            .qpc_duration = qpc_duration,
            .cached_now = undefined,
        };

        res.update_now();
        return res;
    }

    /// Deinitialize the loop, this closes the handle to the Completion Port. Any events that were
    /// unprocessed are lost -- their callbacks will never be called.
    pub fn deinit(self: *Loop) void {
        windows.CloseHandle(self.iocp_handle);
    }

    /// Stop the loop. This can only be called from the main thread.
    /// This will stop the loop forever. Future ticks will do nothing.
    ///
    /// This does NOT stop any completions associated to operations that are in-flight.
    pub fn stop(self: *Loop) void {
        self.flags.stopped = true;
    }

    /// Returns true if the loop is stopped. This may mean there
    /// are still pending completions to be processed.
    pub fn stopped(self: *Loop) bool {
        return self.flags.stopped;
    }

    /// Add a completion to the loop. The completion is not started until the loop is run (`run`) or
    /// an explicit submission request is made (`submit`).
    pub fn add(self: *Loop, completion: *Completion) void {
        // If the completion is a cancel operation, we start it immediately as it will be put in the
        // cancellations queue.
        if (completion.op == .cancel) {
            self.start_completion(completion);
            return;
        }

        switch (completion.flags.state) {
            // The completion is in an adding state already, nothing needs to be done.
            .adding => return,

            // The completion is dead, probably because it was canceled.
            .dead => {},

            // If we reach this point, we have a problem...
            .active => unreachable,
        }

        // We just add the completion to the queue. Failures can happen
        // at submission or tick time.
        completion.flags.state = .adding;
        self.submissions.push(completion);
    }

    /// Submit any enqueued completions. This does not fire any callbacks for completed events
    /// (success or error). Callbacks are only fired on the next tick.
    pub fn submit(self: *Loop) !void {
        // Submit all the submissions. We copy the submission queue so that any resubmits don't
        // cause an infinite loop.
        var queued = self.submissions;
        self.submissions = .{};

        // On error, we have to restore the queue because we may be batching.
        errdefer self.submissions = queued;

        while (queued.pop()) |c| {
            switch (c.flags.state) {
                .adding => self.start_completion(c),
                .dead => self.stop_completion(c, null),
                .active => std.log.err(
                    "invalid state in submission queue state={}",
                    .{c.flags.state},
                ),
            }
        }
    }

    /// Process the cancellations queue. This doesn't call any callbacks but can potentially make
    /// system call to cancel active IO.
    fn process_cancellations(self: *Loop) void {
        while (self.cancellations.pop()) |c| {
            const target = c.op.cancel.c;
            var cancel_result: CancelError!void = {};
            switch (target.flags.state) {
                // If the target is dead already we do nothing.
                .dead => {},

                // If it is in the submission queue, mark them as dead so they will never be
                // submitted.
                .adding => target.flags.state = .dead,

                // If it is active we need to schedule the deletion.
                .active => self.stop_completion(target, &cancel_result),
            }

            // We completed the cancellation.
            c.result = .{ .cancel = cancel_result };
            self.completions.push(c);
        }
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

    /// Tick through the event loop once, waiting for at least "wait" completions to be processed by
    /// the loop itself.
    pub fn tick(self: *Loop, wait: u32) !void {
        // If we're stopped then the loop is fully over.
        if (self.flags.stopped) return;

        // We can't nest runs.
        if (self.flags.in_run) return error.NestedRunsNotAllowed;
        self.flags.in_run = true;
        defer self.flags.in_run = false;

        // The list of entry that will be filled with a call to GetQueuedCompletionStatusEx.
        var entries: [128]windows.OVERLAPPED_ENTRY = undefined;

        var wait_rem = @as(usize, @intCast(wait));

        // Handle all of our cancellations first because we may be able to stop submissions from
        // even happening if its still queued. Plus, cancellations sometimes add more to the
        // submission queue.
        self.process_cancellations();

        // Submit pending completions.
        try self.submit();

        // Loop condition is inspired from the kqueue backend. See its documentation for details.
        while (true) {
            // If we're stopped then the loop is fully over.
            if (self.flags.stopped) return;

            // We must update our time no matter what.
            self.update_now();

            const should_continue = (self.active > 0 and (wait == 0 or wait_rem > 0)) or !self.completions.empty();
            if (!should_continue) break;

            // Run our expired timers.
            const now_timer: Timer = .{ .next = self.cached_now };
            while (self.timers.peek()) |t| {
                if (!Timer.less({}, t, &now_timer)) break;

                // Remove the timer
                assert(self.timers.deleteMin().? == t);

                // Mark completion as done
                const c = t.c;
                c.flags.state = .dead;

                // We mark it as inactive here because if we rearm below the start() function will
                // reincrement this.
                self.active -= 1;

                // Lower our remaining count since we have processed something.
                wait_rem -|= 1;

                // Invoke
                const action = c.callback(c.userdata, self, c, .{ .timer = .expiration });
                switch (action) {
                    .disarm => {},
                    .rearm => self.start_completion(c),
                }
            }

            // Process the completions we already have completed.
            while (self.completions.pop()) |c| {
                // We store whether this completion was active so we can decrement the active count
                // later.
                const c_active = c.flags.state == .active;
                c.flags.state = .dead;

                // Decrease our waiters because we are definitely processing one.
                wait_rem -|= 1;

                // Completion queue items MUST have a result set.
                const action = c.callback(c.userdata, self, c, c.result.?);
                switch (action) {
                    .disarm => {
                        // If we were active, decrement the number of active completions.
                        if (c_active) self.active -= 1;
                    },

                    // Only resubmit if we aren't already active
                    .rearm => if (!c_active) self.submissions.push(c),
                }
            }

            // Process asyncs
            if (!self.asyncs.empty()) {
                var asyncs = self.asyncs;
                self.asyncs = .{};

                while (asyncs.pop()) |c| {
                    const c_wakeup = c.op.async_wait.wakeup.swap(false, .seq_cst);

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
                        .disarm => {},
                        .rearm => self.start_completion(c),
                    }
                }
            }

            // If we have processed enough event, we break out of the loop.
            if (wait_rem == 0) break;

            // Determine our next timeout based on the timers.
            const timeout: ?windows.DWORD = timeout: {
                // If we have a timer, we want to set the timeout to our next timer value. If we
                // have no timer, we wait forever.
                const t = self.timers.peek() orelse break :timeout null;

                // Determin the time in milliseconds. If the cast fails, we fallback to the maximum
                // acceptable value.
                const ms_now = self.cached_now / std.time.ns_per_ms;
                const ms_next = t.next / std.time.ns_per_ms;
                const ms = ms_next -| ms_now;
                break :timeout std.math.cast(windows.DWORD, ms) orelse windows.INFINITE - 1;
            };

            // Wait for changes IO completions.
            const count: u32 = windows.GetQueuedCompletionStatusEx(self.iocp_handle, &entries, timeout, false) catch |err| switch (err) {
                // A timeout means that nothing was completed.
                error.Timeout => 0,

                else => return err,
            };

            // Go through the entries and perform completions callbacks.
            for (entries[0..count]) |entry| {
                const completion: *Completion = if (entry.lpCompletionKey == 0) completion: {
                    // We retrieve the Completion from the OVERLAPPED pointer as we know it's a part of
                    // the Completion struct.
                    const overlapped_ptr: ?*windows.OVERLAPPED = @as(?*windows.OVERLAPPED, @ptrCast(entry.lpOverlapped));
                    if (overlapped_ptr == null) {
                        // Probably an async wakeup
                        continue;
                    }

                    break :completion @alignCast(@fieldParentPtr("overlapped", overlapped_ptr.?));
                } else completion: {
                    // JobObjects are a special case where the OVERLAPPED_ENTRY fields are interpreted differently.
                    // When JOBOBJECT_ASSOCIATE_COMPLETION_PORT is used, lpOverlapped actually contains the message
                    // value, and not the address of the overlapped structure. The Completion pointer is passed
                    // as the completion key instead.
                    const completion: *Completion = @ptrFromInt(entry.lpCompletionKey);
                    completion.result = .{ .job_object = .{
                        .message = .{
                            .type = @enumFromInt(entry.dwNumberOfBytesTransferred),
                            .value = @intFromPtr(entry.lpOverlapped),
                        },
                    } };
                    break :completion completion;
                };

                wait_rem -|= 1;

                self.active -= 1;
                completion.flags.state = .dead;

                const result = completion.perform();
                const action = completion.callback(completion.userdata, self, completion, result);
                switch (action) {
                    .disarm => {},
                    .rearm => {
                        completion.reset();
                        self.start_completion(completion);
                    },
                }
            }

            // If we ran through the loop once we break if we don't care.
            if (wait == 0) break;
        }
    }

    /// Returns the "loop" time in milliseconds. The loop time is updated once per loop tick, before
    /// IO polling occurs. It remains constant throughout callback execution.
    ///
    /// You can force an update of the "now" value by calling update_now() at any time from the main
    /// thread.
    ///
    /// QueryPerformanceCounter is used to get the current timestamp.
    pub fn now(self: *Loop) i64 {
        return @as(i64, @intCast(self.cached_now));
    }

    /// Update the cached time.
    pub fn update_now(self: *Loop) void {
        // Compute the current timestamp in ms by multiplying the QueryPerfomanceCounter value in
        // ticks by the duration of a tick.
        self.cached_now = windows.QueryPerformanceCounter() * self.qpc_duration;
    }

    /// Add a timer to the loop. The timer will execute in "next_ms". This is oneshot: the timer
    /// will not repeat. To repeat a timer, either schedule another in your callback or return rearm
    /// from the callback.
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

    /// see io_uring.timer_reset for docs.
    pub fn timer_reset(
        self: *Loop,
        c: *Completion,
        c_cancel: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: Callback,
    ) void {
        switch (c.flags.state) {
            .dead => {
                self.timer(c, next_ms, userdata, cb);
                return;
            },

            // Adding state we can just modify the metadata and return since the timer isn't in the
            // heap yet.
            .adding => {
                c.op.timer.next = self.timer_next(next_ms);
                c.userdata = userdata;
                c.callback = cb;
            },

            .active => {
                // Update the reset time for the timer to the desired time along with all the
                // callbacks.
                c.op.timer.reset = self.timer_next(next_ms);
                c.userdata = userdata;
                c.callback = cb;

                // If the cancellation is active, we assume its for this timer.
                if (c_cancel.state() == .active) return;
                assert(c_cancel.state() == .dead and c.state() == .active);
                c_cancel.* = .{ .op = .{ .cancel = .{ .c = c } } };
                self.add(c_cancel);
            },
        }
    }

    // Get the absolute timestamp corresponding to the given "next_ms".
    pub fn timer_next(self: *Loop, next_ms: u64) u64 {
        return self.cached_now + next_ms * std.time.ns_per_ms;
    }

    pub fn done(self: *Loop) bool {
        return self.flags.stopped or (self.active == 0 and
            self.submissions.empty() and
            self.completions.empty());
    }

    // Start the completion.
    fn start_completion(self: *Loop, completion: *Completion) void {
        const StartAction = union(enum) {
            // We successfully submitted the operation.
            submitted: void,

            // We are a timer.
            timer: void,

            // We are a cancellation.
            cancel: void,

            // We are an async wait
            async_wait: void,

            // We have a result code from making a system call now.
            result: Result,
        };

        const action: StartAction = switch (completion.op) {
            .noop => {
                completion.flags.state = .dead;
                return;
            },

            .accept => |*v| action: {
                if (v.internal_accept_socket == null) {
                    var addr: posix.sockaddr.storage = undefined;
                    var addr_len: i32 = @sizeOf(posix.sockaddr.storage);

                    std.debug.assert(windows.ws2_32.getsockname(asSocket(v.socket), @as(*posix.sockaddr, @ptrCast(&addr)), &addr_len) == 0);

                    var socket_type: i32 = 0;
                    const socket_type_bytes = std.mem.asBytes(&socket_type);
                    var opt_len: i32 = @as(i32, @intCast(socket_type_bytes.len));
                    std.debug.assert(windows.ws2_32.getsockopt(asSocket(v.socket), posix.SOL.SOCKET, posix.SO.TYPE, socket_type_bytes, &opt_len) == 0);

                    v.internal_accept_socket = windows.WSASocketW(addr.family, socket_type, 0, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED) catch |err| {
                        break :action .{ .result = .{ .accept = err } };
                    };
                }

                self.associate_fd(completion.handle().?) catch unreachable;

                var discard: u32 = undefined;
                const result = windows.ws2_32.AcceptEx(
                    asSocket(v.socket),
                    asSocket(v.internal_accept_socket.?),
                    &v.storage,
                    0,
                    0,
                    @as(u32, @intCast(@sizeOf(posix.sockaddr.storage))),
                    &discard,
                    &completion.overlapped,
                );
                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    switch (err) {
                        windows.ws2_32.WinsockError.WSA_IO_PENDING => break :action .{ .submitted = {} },
                        else => {
                            windows.CloseHandle(v.internal_accept_socket.?);
                            break :action .{ .result = .{ .accept = windows.unexpectedWSAError(err) } };
                        },
                    }
                }

                break :action .{ .submitted = {} };
            },

            .close => |v| .{ .result = .{ .close = windows.CloseHandle(v.fd) } },

            .connect => |*v| action: {
                const result = windows.ws2_32.connect(asSocket(v.socket), &v.addr.any, @as(i32, @intCast(v.addr.getOsSockLen())));
                if (result != 0) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :action switch (err) {
                        else => .{ .result = .{ .connect = windows.unexpectedWSAError(err) } },
                    };
                }
                break :action .{ .result = .{ .connect = {} } };
            },

            .read => |*v| action: {
                self.associate_fd(completion.handle().?) catch unreachable;
                const buffer: []u8 = if (v.buffer == .slice) v.buffer.slice else &v.buffer.array;
                break :action if (windows.exp.ReadFile(v.fd, buffer, &completion.overlapped)) |_|
                    .{
                        .submitted = {},
                    }
                else |err|
                    .{
                        .result = .{ .read = err },
                    };
            },

            .pread => |*v| action: {
                self.associate_fd(completion.handle().?) catch unreachable;
                const buffer: []u8 = if (v.buffer == .slice) v.buffer.slice else &v.buffer.array;
                completion.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @intCast(v.offset & 0xFFFF_FFFF_FFFF_FFFF);
                completion.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @intCast(v.offset >> 32);
                break :action if (windows.exp.ReadFile(v.fd, buffer, &completion.overlapped)) |_|
                    .{
                        .submitted = {},
                    }
                else |err|
                    .{
                        .result = .{ .pread = err },
                    };
            },

            .shutdown => |*v| .{ .result = .{ .shutdown = posix.shutdown(asSocket(v.socket), v.how) } },

            .write => |*v| action: {
                self.associate_fd(completion.handle().?) catch unreachable;
                const buffer: []const u8 = if (v.buffer == .slice) v.buffer.slice else v.buffer.array.array[0..v.buffer.array.len];
                break :action if (windows.exp.WriteFile(v.fd, buffer, &completion.overlapped)) |_|
                    .{
                        .submitted = {},
                    }
                else |err|
                    .{
                        .result = .{ .write = err },
                    };
            },

            .pwrite => |*v| action: {
                self.associate_fd(completion.handle().?) catch unreachable;
                const buffer: []const u8 = if (v.buffer == .slice) v.buffer.slice else v.buffer.array.array[0..v.buffer.array.len];
                completion.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @intCast(v.offset & 0xFFFF_FFFF_FFFF_FFFF);
                completion.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @intCast(v.offset >> 32);
                break :action if (windows.exp.WriteFile(v.fd, buffer, &completion.overlapped)) |_|
                    .{
                        .submitted = {},
                    }
                else |err|
                    .{
                        .result = .{ .pwrite = err },
                    };
            },

            .send => |*v| action: {
                self.associate_fd(completion.handle().?) catch unreachable;
                const buffer: []const u8 = if (v.buffer == .slice) v.buffer.slice else v.buffer.array.array[0..v.buffer.array.len];
                v.wsa_buffer = .{ .buf = @constCast(buffer.ptr), .len = @as(u32, @intCast(buffer.len)) };
                const result = windows.ws2_32.WSASend(
                    asSocket(v.fd),
                    @as([*]windows.ws2_32.WSABUF, @ptrCast(&v.wsa_buffer)),
                    1,
                    null,
                    0,
                    &completion.overlapped,
                    null,
                );
                if (result != 0) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :action switch (err) {
                        windows.ws2_32.WinsockError.WSA_IO_PENDING => .{ .submitted = {} },
                        .WSA_OPERATION_ABORTED, .WSAECONNABORTED => .{ .result = .{ .send = error.Canceled } },
                        .WSAECONNRESET, .WSAENETRESET => .{ .result = .{ .send = error.ConnectionResetByPeer } },
                        else => .{ .result = .{ .send = windows.unexpectedWSAError(err) } },
                    };
                }
                break :action .{ .submitted = {} };
            },

            .recv => |*v| action: {
                self.associate_fd(completion.handle().?) catch unreachable;
                const buffer: []u8 = if (v.buffer == .slice) v.buffer.slice else &v.buffer.array;
                v.wsa_buffer = .{ .buf = buffer.ptr, .len = @as(u32, @intCast(buffer.len)) };

                var flags: u32 = 0;

                const result = windows.ws2_32.WSARecv(
                    asSocket(v.fd),
                    @as([*]windows.ws2_32.WSABUF, @ptrCast(&v.wsa_buffer)),
                    1,
                    null,
                    &flags,
                    &completion.overlapped,
                    null,
                );
                if (result != 0) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :action switch (err) {
                        windows.ws2_32.WinsockError.WSA_IO_PENDING => .{ .submitted = {} },
                        .WSA_OPERATION_ABORTED, .WSAECONNABORTED => .{ .result = .{ .recv = error.Canceled } },
                        .WSAECONNRESET, .WSAENETRESET => .{ .result = .{ .recv = error.ConnectionResetByPeer } },
                        else => .{ .result = .{ .recv = windows.unexpectedWSAError(err) } },
                    };
                }
                break :action .{ .submitted = {} };
            },

            .sendto => |*v| action: {
                self.associate_fd(completion.handle().?) catch unreachable;
                const buffer: []const u8 = if (v.buffer == .slice) v.buffer.slice else v.buffer.array.array[0..v.buffer.array.len];
                v.wsa_buffer = .{ .buf = @constCast(buffer.ptr), .len = @as(u32, @intCast(buffer.len)) };
                const result = windows.ws2_32.WSASendTo(
                    asSocket(v.fd),
                    @as([*]windows.ws2_32.WSABUF, @ptrCast(&v.wsa_buffer)),
                    1,
                    null,
                    0,
                    &v.addr.any,
                    @as(i32, @intCast(v.addr.getOsSockLen())),
                    &completion.overlapped,
                    null,
                );
                if (result != 0) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :action switch (err) {
                        windows.ws2_32.WinsockError.WSA_IO_PENDING => .{ .submitted = {} },
                        .WSA_OPERATION_ABORTED, .WSAECONNABORTED => .{ .result = .{ .sendto = error.Canceled } },
                        .WSAECONNRESET, .WSAENETRESET => .{ .result = .{ .sendto = error.ConnectionResetByPeer } },
                        else => .{ .result = .{ .sendto = windows.unexpectedWSAError(err) } },
                    };
                }
                break :action .{ .submitted = {} };
            },

            .recvfrom => |*v| action: {
                self.associate_fd(completion.handle().?) catch unreachable;
                const buffer: []u8 = if (v.buffer == .slice) v.buffer.slice else &v.buffer.array;
                v.wsa_buffer = .{ .buf = buffer.ptr, .len = @as(u32, @intCast(buffer.len)) };

                var flags: u32 = 0;

                const result = windows.ws2_32.WSARecvFrom(
                    asSocket(v.fd),
                    @as([*]windows.ws2_32.WSABUF, @ptrCast(&v.wsa_buffer)),
                    1,
                    null,
                    &flags,
                    &v.addr,
                    @as(*i32, @ptrCast(&v.addr_size)),
                    &completion.overlapped,
                    null,
                );
                if (result != 0) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :action switch (err) {
                        windows.ws2_32.WinsockError.WSA_IO_PENDING => .{ .submitted = {} },
                        .WSA_OPERATION_ABORTED, .WSAECONNABORTED => .{ .result = .{ .recvfrom = error.Canceled } },
                        .WSAECONNRESET, .WSAENETRESET => .{ .result = .{ .recvfrom = error.ConnectionResetByPeer } },
                        else => .{ .result = .{ .recvfrom = windows.unexpectedWSAError(err) } },
                    };
                }
                break :action .{ .submitted = {} };
            },

            .timer => |*v| action: {
                v.c = completion;
                self.timers.insert(v);
                break :action .{ .timer = {} };
            },

            .cancel => action: {
                self.cancellations.push(completion);
                break :action .{ .cancel = {} };
            },

            .async_wait => action: {
                self.asyncs.push(completion);
                break :action .{ .async_wait = {} };
            },

            .job_object => |*v| action: {
                if (!v.associated) {
                    var port = windows.exp.JOBOBJECT_ASSOCIATE_COMPLETION_PORT{
                        .CompletionKey = @intFromPtr(completion),
                        .CompletionPort = self.iocp_handle,
                    };

                    windows.exp.SetInformationJobObject(
                        v.job,
                        .JobObjectAssociateCompletionPortInformation,
                        &port,
                        @sizeOf(windows.exp.JOBOBJECT_ASSOCIATE_COMPLETION_PORT),
                    ) catch |err| break :action .{ .result = .{ .job_object = err } };

                    v.associated = true;
                    const action = completion.callback(completion.userdata, self, completion, .{ .job_object = .{ .associated = {} } });
                    switch (action) {
                        .disarm => {
                            completion.flags.state = .dead;
                            return;
                        },
                        .rearm => break :action .{ .submitted = {} },
                    }
                }

                break :action .{ .submitted = {} };
            },
        };

        switch (action) {
            .timer, .submitted, .cancel => {
                // Increase our active count so we now wait for this. We assume it'll successfully
                // queue. If it doesn't we handle that later (see submit).
                self.active += 1;
                completion.flags.state = .active;
            },

            .async_wait => {
                // We are considered an active completion.
                self.active += 1;
                completion.flags.state = .active;
            },

            // A result is immediately available. Queue the completion to be invoked.
            .result => |r| {
                completion.result = r;
                self.completions.push(completion);
            },
        }
    }

    /// Stop the completion. Fill `cancel_result` if it is non-null.
    fn stop_completion(self: *Loop, completion: *Completion, cancel_result: ?*CancelError!void) void {
        if (completion.flags.state == .active and completion.result != null) return;

        // Inspect other operations. WARNING: the state can be anything here so per op be sure to
        // check the state flag.
        switch (completion.op) {
            .timer => |*v| {
                if (completion.flags.state == .active) {
                    // Remove from the heap so it never fires...
                    self.timers.remove(v);

                    // If we have reset AND we got cancellation result, that means that we were
                    // canceled so that we can update our expiration time.
                    if (v.reset) |r| {
                        v.next = r;
                        v.reset = null;
                        completion.flags.state = .dead;
                        self.active -= 1;
                        self.add(completion);
                        return;
                    }
                }

                // Add to our completion so we trigger the callback.
                completion.result = .{ .timer = .cancel };
                self.completions.push(completion);

                // Note the timers state purposely remains ACTIVE so that
                // when we process the completion we decrement the
                // active count.
            },

            .accept => |*v| {
                if (completion.flags.state == .active) {
                    const result = windows.kernel32.CancelIoEx(asSocket(v.socket), &completion.overlapped);
                    cancel_result.?.* = if (result == windows.FALSE)
                        windows.unexpectedError(windows.kernel32.GetLastError())
                    else {};
                }
            },

            inline .read, .pread, .write, .pwrite, .recv, .send, .sendto, .recvfrom => |*v| {
                if (completion.flags.state == .active) {
                    const result = windows.kernel32.CancelIoEx(asSocket(v.fd), &completion.overlapped);
                    cancel_result.?.* = if (result == windows.FALSE)
                        windows.unexpectedError(windows.kernel32.GetLastError())
                    else {};
                }
            },

            else => @panic("Not implemented"),
        }
    }

    // Sens an empty Completion token so that the loop wakes up if it is waiting for a completion
    // event.
    pub fn async_notify(self: *Loop, completion: *Completion) void {
        // The completion must be in a waiting state.
        assert(completion.op == .async_wait);

        // The completion has been wakeup, this is used to see which completion in the async queue
        // needs to be removed.
        completion.op.async_wait.wakeup.store(true, .seq_cst);

        // NOTE: This call can fail but errors are not documented, so we log the error here.
        windows.PostQueuedCompletionStatus(self.iocp_handle, 0, 0, null) catch |err| {
            log.warn("unexpected async_notify error={}", .{err});
        };
    }

    /// Associate a handler to the internal completion port.
    /// This has to be done only once per handle so we delegate the responsibility to the caller.
    pub fn associate_fd(self: Loop, fd: windows.HANDLE) !void {
        if (fd == windows.INVALID_HANDLE_VALUE or self.iocp_handle == windows.INVALID_HANDLE_VALUE) return error.InvalidParameter;
        // We ignore the error here because multiple call to CreateIoCompletionPort with a HANDLE
        // already registered triggers a INVALID_PARAMETER error and we have no way to see the cause
        // of it.
        _ = windows.kernel32.CreateIoCompletionPort(fd, self.iocp_handle, 0, 0);
    }
};

/// Convenience to convert from windows.HANDLE to windows.ws2_32.SOCKET (which are the same thing).
inline fn asSocket(h: windows.HANDLE) windows.ws2_32.SOCKET {
    return @as(windows.ws2_32.SOCKET, @ptrCast(h));
}

/// A completion is a request to perform some work with the loop.
pub const Completion = struct {
    /// Operation to execute.
    op: Operation = .{ .noop = {} },

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: Callback = noopCallback,

    //---------------------------------------------------------------
    // Internal fields

    /// Intrusive queue field.
    next: ?*Completion = null,

    /// Result code of the syscall. Only used internally in certain scenarios, should not be relied
    /// upon by program authors.
    result: ?Result = null,

    flags: packed struct {
        /// Watch state of this completion. We use this to determine whether we're active, adding or
        /// dead. This lets us add and abd delete multiple times before a loop tick and handle the
        /// state properly.
        state: State = .dead,
    } = .{},

    /// Win32 OVERLAPPED struct used for asynchronous IO. Only used internally in certain scenarios.
    /// It needs to be there as we rely on @fieldParentPtr to get the completion using a pointer to
    /// that field.
    overlapped: windows.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{ .Pointer = null },
        .hEvent = null,
    },

    /// Loop associated with this completion. HANDLE are required to be associated with an I/O
    /// Completion Port to work properly.
    loop: ?*const Loop = null,

    const State = enum(u2) {
        /// completion is not part of any loop
        dead = 0,

        /// completion is in the submission queue
        adding = 1,

        /// completion is submitted successfully
        active = 2,
    };

    /// Returns the state of this completion. There are some things to be cautious about when
    /// calling this function.
    ///
    /// First, this is only safe to call from the main thread. This cannot be called from any other
    /// thread.
    ///
    /// Second, if you are using default "undefined" completions, this will NOT return a valid value
    /// if you access it. You must zero your completion using ".{}". You only need to zero the
    /// completion once. Once the completion is in use, it will always be valid.
    ///
    /// Third, if you stop the loop (loop.stop()), the completions registered with the loop will NOT
    /// be reset to a dead state.
    pub fn state(self: Completion) CompletionState {
        return switch (self.flags.state) {
            .dead => .dead,
            .adding, .active => .active,
        };
    }

    /// Returns a handle for the current operation if it makes sense.
    fn handle(self: Completion) ?windows.HANDLE {
        return switch (self.op) {
            inline .accept => |*v| v.socket,
            inline .read, .pread, .write, .pwrite, .recv, .send, .recvfrom, .sendto => |*v| v.fd,
            else => null,
        };
    }

    /// Perform the operation associated with this completion. This will perform the full blocking
    /// operation for the completion.
    pub fn perform(self: *Completion) Result {
        return switch (self.op) {
            .noop, .close, .connect, .shutdown, .timer, .cancel => {
                std.log.warn("perform op={s}", .{@tagName(self.op)});
                unreachable;
            },

            .accept => |*v| {
                var bytes_transferred: u32 = 0;
                var flags: u32 = 0;
                const result = windows.ws2_32.WSAGetOverlappedResult(asSocket(v.socket), &self.overlapped, &bytes_transferred, windows.FALSE, &flags);

                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    const r: Result = .{
                        .accept = switch (err) {
                            windows.ws2_32.WinsockError.WSA_OPERATION_ABORTED => error.Canceled,
                            else => windows.unexpectedWSAError(err),
                        },
                    };
                    windows.CloseHandle(v.internal_accept_socket.?);
                    return r;
                }

                return .{ .accept = self.op.accept.internal_accept_socket.? };
            },

            .read => |*v| {
                var bytes_transferred: windows.DWORD = 0;
                const result = windows.kernel32.GetOverlappedResult(v.fd, &self.overlapped, &bytes_transferred, windows.FALSE);
                if (result == windows.FALSE) {
                    const err = windows.kernel32.GetLastError();
                    return .{ .read = switch (err) {
                        windows.Win32Error.OPERATION_ABORTED => error.Canceled,
                        else => error.Unexpected,
                    } };
                }
                return .{ .read = @as(usize, @intCast(bytes_transferred)) };
            },

            .pread => |*v| {
                var bytes_transferred: windows.DWORD = 0;
                const result = windows.kernel32.GetOverlappedResult(v.fd, &self.overlapped, &bytes_transferred, windows.FALSE);
                if (result == windows.FALSE) {
                    const err = windows.kernel32.GetLastError();
                    return .{
                        .read = switch (err) {
                            windows.Win32Error.OPERATION_ABORTED => error.Canceled,
                            else => error.Unexpected,
                        },
                    };
                }
                return .{ .pread = @as(usize, @intCast(bytes_transferred)) };
            },

            .write => |*v| {
                var bytes_transferred: windows.DWORD = 0;
                const result = windows.kernel32.GetOverlappedResult(v.fd, &self.overlapped, &bytes_transferred, windows.FALSE);
                if (result == windows.FALSE) {
                    const err = windows.kernel32.GetLastError();
                    return .{
                        .write = switch (err) {
                            windows.Win32Error.OPERATION_ABORTED => error.Canceled,
                            else => error.Unexpected,
                        },
                    };
                }
                return .{ .write = @as(usize, @intCast(bytes_transferred)) };
            },

            .pwrite => |*v| {
                var bytes_transferred: windows.DWORD = 0;
                const result = windows.kernel32.GetOverlappedResult(v.fd, &self.overlapped, &bytes_transferred, windows.FALSE);
                if (result == windows.FALSE) {
                    const err = windows.kernel32.GetLastError();
                    return .{
                        .write = switch (err) {
                            windows.Win32Error.OPERATION_ABORTED => error.Canceled,
                            else => error.Unexpected,
                        },
                    };
                }
                return .{ .pwrite = @as(usize, @intCast(bytes_transferred)) };
            },

            .send => |*v| {
                var bytes_transferred: u32 = 0;
                var flags: u32 = 0;

                const result = windows.ws2_32.WSAGetOverlappedResult(asSocket(v.fd), &self.overlapped, &bytes_transferred, windows.FALSE, &flags);

                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    return .{
                        .send = switch (err) {
                            .WSA_OPERATION_ABORTED, .WSAECONNABORTED => error.Canceled,
                            .WSAECONNRESET, .WSAENETRESET => error.ConnectionResetByPeer,
                            else => windows.unexpectedWSAError(err),
                        },
                    };
                }
                return .{ .send = @as(usize, @intCast(bytes_transferred)) };
            },

            .recv => |*v| {
                var bytes_transferred: u32 = 0;
                var flags: u32 = 0;

                const result = windows.ws2_32.WSAGetOverlappedResult(asSocket(v.fd), &self.overlapped, &bytes_transferred, windows.FALSE, &flags);

                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    return .{
                        .recv = switch (err) {
                            .WSA_OPERATION_ABORTED, .WSAECONNABORTED => error.Canceled,
                            .WSAECONNRESET, .WSAENETRESET => error.ConnectionResetByPeer,
                            else => windows.unexpectedWSAError(err),
                        },
                    };
                }

                // NOTE(Corendos): according to Win32 documentation, EOF has to be detected using the socket type.
                const socket_type = t: {
                    var socket_type: windows.DWORD = 0;
                    const socket_type_bytes = std.mem.asBytes(&socket_type);
                    var opt_len: i32 = @as(i32, @intCast(socket_type_bytes.len));

                    // Here we assume the call will succeed because the socket should be valid.
                    std.debug.assert(windows.ws2_32.getsockopt(asSocket(v.fd), posix.SOL.SOCKET, posix.SO.TYPE, socket_type_bytes, &opt_len) == 0);
                    break :t socket_type;
                };

                if (socket_type == posix.SOCK.STREAM and bytes_transferred == 0) {
                    return .{ .recv = error.EOF };
                }

                return .{ .recv = @as(usize, @intCast(bytes_transferred)) };
            },

            .sendto => |*v| {
                var bytes_transferred: u32 = 0;
                var flags: u32 = 0;

                const result = windows.ws2_32.WSAGetOverlappedResult(asSocket(v.fd), &self.overlapped, &bytes_transferred, windows.FALSE, &flags);

                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    return .{
                        .sendto = switch (err) {
                            .WSA_OPERATION_ABORTED, .WSAECONNABORTED => error.Canceled,
                            .WSAECONNRESET, .WSAENETRESET => error.ConnectionResetByPeer,
                            else => windows.unexpectedWSAError(err),
                        },
                    };
                }
                return .{ .sendto = @as(usize, @intCast(bytes_transferred)) };
            },

            .recvfrom => |*v| {
                var bytes_transferred: u32 = 0;
                var flags: u32 = 0;

                const result = windows.ws2_32.WSAGetOverlappedResult(asSocket(v.fd), &self.overlapped, &bytes_transferred, windows.FALSE, &flags);

                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    return .{
                        .recvfrom = switch (err) {
                            .WSA_OPERATION_ABORTED, .WSAECONNABORTED => error.Canceled,
                            .WSAECONNRESET, .WSAENETRESET => error.ConnectionResetByPeer,
                            else => windows.unexpectedWSAError(err),
                        },
                    };
                }
                return .{ .recvfrom = @as(usize, @intCast(bytes_transferred)) };
            },

            .async_wait => .{ .async_wait = {} },

            .job_object => self.result.?,
        };
    }

    /// Reset the completion so it can be reused (in case of rearming for example).
    pub fn reset(self: *Completion) void {
        self.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .DUMMYUNIONNAME = .{ .Pointer = null },
            .hEvent = null,
        };
        self.result = null;
    }
};

pub const OperationType = enum {
    /// Do nothing. This operation will not be queued and will never
    /// have its callback fired. This is NOT equivalent to the io_uring
    /// "nop" operation.
    noop,

    /// Accept a connection on a socket.
    accept,

    /// Close a file descriptor.
    close,

    /// Initiate a connection on a socket.
    connect,

    /// Read
    read,

    /// Pread
    pread,

    /// Shutdown all or part of a full-duplex connection.
    shutdown,

    /// Write
    write,

    /// Pwrite
    pwrite,

    /// Send
    send,

    /// Recv
    recv,

    /// Sendto
    sendto,

    /// Recvfrom
    recvfrom,

    /// A oneshot or repeating timer. For io_uring, this is implemented
    /// using the timeout mechanism.
    timer,

    /// Cancel an existing operation.
    cancel,

    /// Wait for an async event to be posted.
    async_wait,

    /// Receive a notification from a job object associated with a completion port
    job_object,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    noop: void,

    accept: struct {
        socket: windows.HANDLE,
        storage: [@sizeOf(posix.sockaddr.storage)]u8 = undefined,

        internal_accept_socket: ?windows.HANDLE = null,
    },

    close: struct {
        fd: windows.HANDLE,
    },

    connect: struct {
        socket: windows.HANDLE,
        addr: std.net.Address,
    },

    read: struct {
        fd: windows.HANDLE,
        buffer: ReadBuffer,
    },

    pread: struct {
        fd: windows.HANDLE,
        buffer: ReadBuffer,
        offset: u64,
    },

    shutdown: struct {
        socket: windows.HANDLE,
        how: posix.ShutdownHow = .both,
    },

    write: struct {
        fd: windows.HANDLE,
        buffer: WriteBuffer,
    },

    pwrite: struct {
        fd: windows.HANDLE,
        buffer: WriteBuffer,
        offset: u64,
    },

    send: struct {
        fd: windows.HANDLE,
        buffer: WriteBuffer,
        wsa_buffer: windows.ws2_32.WSABUF = undefined,
    },

    recv: struct {
        fd: windows.HANDLE,
        buffer: ReadBuffer,
        wsa_buffer: windows.ws2_32.WSABUF = undefined,
    },

    sendto: struct {
        fd: windows.HANDLE,
        buffer: WriteBuffer,
        addr: std.net.Address,
        wsa_buffer: windows.ws2_32.WSABUF = undefined,
    },

    recvfrom: struct {
        fd: windows.HANDLE,
        buffer: ReadBuffer,
        addr: posix.sockaddr = undefined,
        addr_size: posix.socklen_t = @sizeOf(posix.sockaddr),
        wsa_buffer: windows.ws2_32.WSABUF = undefined,
    },

    timer: Timer,

    cancel: struct {
        c: *Completion,
    },

    async_wait: struct {
        wakeup: std.atomic.Value(bool) = .{ .raw = false },
    },

    job_object: struct {
        job: windows.HANDLE,
        userdata: ?*anyopaque,

        /// Tracks if the job has been associated with the completion port.
        /// Do not use this, it is used internally.
        associated: bool = false,
    },
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    noop: void,
    accept: AcceptError!windows.HANDLE,
    close: CloseError!void,
    connect: ConnectError!void,
    read: ReadError!usize,
    pread: ReadError!usize,
    shutdown: ShutdownError!void,
    write: WriteError!usize,
    pwrite: WriteError!usize,
    send: WriteError!usize,
    recv: ReadError!usize,
    sendto: WriteError!usize,
    recvfrom: ReadError!usize,
    timer: TimerError!TimerTrigger,
    cancel: CancelError!void,
    async_wait: AsyncError!void,
    job_object: JobObjectError!JobObjectResult,
};

pub const CancelError = error{
    Unexpected,
};

pub const AcceptError = error{
    AddressFamilyNotSupported,
    ProcessFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    Canceled,
    Unexpected,
};

pub const CloseError = error{
    Unexpected,
};

pub const ConnectError = error{
    Canceled,
    Unexpected,
};

pub const ShutdownError = posix.ShutdownError || error{
    Unexpected,
};

pub const WriteError = windows.WriteFileError || error{
    Canceled,
    ConnectionResetByPeer,
    Unexpected,
};

pub const ReadError = windows.ReadFileError || error{
    EOF,
    Canceled,
    ConnectionResetByPeer,
    Unexpected,
};

pub const AsyncError = error{
    Unexpected,
};

pub const TimerError = error{
    Unexpected,
};

pub const TimerTrigger = enum {
    /// Unused with IOCP
    request,

    /// Timer expired.
    expiration,

    /// Timer was canceled.
    cancel,
};

pub const JobObjectError = error{
    Unexpected,
};

pub const JobObjectResult = union(enum) {
    // The job object was associated with the completion port
    associated: void,

    /// A message was recived on the completion port for this job object
    message: struct {
        type: windows.exp.JOB_OBJECT_MSG_TYPE,
        value: usize,
    },
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

/// Timer that is inserted into the heap.
pub const Timer = struct {
    /// The absolute time to fire this timer next.
    next: u64,

    /// Only used internally. If this is non-null and timer is
    /// CANCELLED, then the timer is rearmed automatically with this
    /// as the next time. The callback will not be called on the
    /// cancellation.
    reset: ?u64 = null,

    /// Internal heap field.
    heap: heap.IntrusiveField(Timer) = .{},

    /// We point back to completion for now. When issue[1] is fixed,
    /// we can juse use that from our heap fields.
    /// [1]: https://github.com/ziglang/zig/issues/6611
    c: *Completion = undefined,

    fn less(_: void, a: *const Timer, b: *const Timer) bool {
        return a.next < b.next;
    }
};

test "iocp: loop time" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // should never init zero
    const now = loop.now();
    try testing.expect(now > 0);

    while (now == loop.now()) try loop.run(.no_wait);
}
test "iocp: stop" {
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

test "iocp: timer" {
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

test "iocp: timer reset" {
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

test "iocp: timer reset before tick" {
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

test "iocp: timer reset after trigger" {
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

test "iocp: timer cancellation" {
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
            const ptr: *?TimerTrigger = @ptrCast(@alignCast(ud.?));
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
                const ptr: *bool = @ptrCast(@alignCast(ud.?));
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

test "iocp: canceling a completed operation" {
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
            const ptr: *?TimerTrigger = @ptrCast(@alignCast(ud.?));
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
                const ptr: *bool = @ptrCast(@alignCast(ud.?));
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

test "iocp: noop" {
    var loop = try Loop.init(.{});
    defer loop.deinit();

    var c: Completion = .{};
    loop.add(&c);

    try loop.run(.once);
}

test "iocp: file IO" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const utf16_file_name = (try windows.sliceToPrefixedFileW(null, "test_watcher_file")).span();

    const f_handle = try windows.exp.CreateFile(utf16_file_name, windows.GENERIC_READ | windows.GENERIC_WRITE, 0, null, windows.OPEN_ALWAYS, windows.FILE_FLAG_OVERLAPPED, null);
    defer windows.exp.DeleteFile(utf16_file_name) catch {};
    defer windows.CloseHandle(f_handle);

    // Perform a write and then a read
    var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    var c_write: Completion = .{
        .op = .{
            .write = .{
                .fd = f_handle,
                .buffer = .{ .slice = &write_buf },
            },
        },
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = ud;
                _ = l;
                _ = c;
                _ = r.write catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_write);

    // Wait for the write
    try loop.run(.until_done);

    // Read
    var read_buf: [128]u8 = undefined;
    var read_len: usize = 0;
    var c_read: Completion = .{
        .op = .{
            .read = .{
                .fd = f_handle,
                .buffer = .{ .slice = &read_buf },
            },
        },
        .userdata = &read_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                const ptr: *usize = @ptrCast(@alignCast(ud.?));
                ptr.* = r.read catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_read);

    // Wait for the read
    try loop.run(.until_done);
    try testing.expectEqualSlices(u8, &write_buf, read_buf[0..read_len]);
}

test "iocp: file IO with offset" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const utf16_file_name = (try windows.sliceToPrefixedFileW(null, "test_watcher_file")).span();

    const f_handle = try windows.exp.CreateFile(utf16_file_name, windows.GENERIC_READ | windows.GENERIC_WRITE, 0, null, windows.OPEN_ALWAYS, windows.FILE_FLAG_OVERLAPPED, null);
    defer windows.exp.DeleteFile(utf16_file_name) catch {};
    defer windows.CloseHandle(f_handle);

    // Perform a write and then a read
    var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    var c_write: Completion = .{
        .op = .{
            .pwrite = .{
                .fd = f_handle,
                .buffer = .{ .slice = &write_buf },
                .offset = 1,
            },
        },
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = ud;
                _ = l;
                _ = c;
                _ = r.pwrite catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_write);

    // Wait for the write
    try loop.run(.until_done);

    // Read
    var read_buf: [128]u8 = undefined;
    var read_len: usize = 0;
    var c_read: Completion = .{
        .op = .{
            .pread = .{
                .fd = f_handle,
                .buffer = .{ .slice = &read_buf },
                .offset = 1,
            },
        },
        .userdata = &read_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                const ptr: *usize = @ptrCast(@alignCast(ud.?));
                ptr.* = r.pread catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_read);

    // Wait for the read
    try loop.run(.until_done);
    try testing.expectEqualSlices(u8, &write_buf, read_buf[0..read_len]);
}

test "iocp: socket accept/connect/send/recv/close" {
    const mem = std.mem;
    const net = std.net;
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    const ln = try windows.WSASocketW(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);
    errdefer posix.close(ln);

    try posix.setsockopt(ln, posix.SOL.SOCKET, posix.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try posix.bind(ln, &address.any, address.getOsSockLen());
    try posix.listen(ln, kernel_backlog);

    // Create a TCP client socket
    const client_conn = try windows.WSASocketW(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);
    errdefer posix.close(client_conn);

    var server_conn_result: Result = undefined;
    var c_accept: Completion = .{
        .op = .{
            .accept = .{
                .socket = ln,
            },
        },

        .userdata = &server_conn_result,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                const conn: *Result = @ptrCast(@alignCast(ud.?));
                conn.* = r;
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
    //try testing.expect(server_conn > 0);
    try testing.expect(connected);
    const server_conn = try server_conn_result.accept;

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
                const ptr: *usize = @ptrCast(@alignCast(ud.?));
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
                const ptr: *bool = @ptrCast(@alignCast(ud.?));
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
                const ptr: *?bool = @ptrCast(@alignCast(ud.?));
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
    var client_conn_closed: bool = false;
    var c_client_close: Completion = .{
        .op = .{
            .close = .{
                .fd = client_conn,
            },
        },

        .userdata = &client_conn_closed,
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
                const ptr: *bool = @ptrCast(@alignCast(ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_close);

    var ln_closed: bool = false;
    var c_server_close: Completion = .{
        .op = .{
            .close = .{
                .fd = ln,
            },
        },

        .userdata = &ln_closed,
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
                const ptr: *bool = @ptrCast(@alignCast(ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_server_close);

    // Wait for the sockets to close
    try loop.run(.until_done);
    try testing.expect(ln_closed);
    try testing.expect(client_conn_closed);
}

test "iocp: recv cancellation" {
    const mem = std.mem;
    const net = std.net;
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const socket = try windows.WSASocketW(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);
    errdefer posix.close(socket);

    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try posix.bind(socket, &address.any, address.getOsSockLen());

    var recv_buf: [128]u8 = undefined;
    var recv_result: Result = undefined;
    var c_recv: Completion = .{
        .op = .{
            .recv = .{
                .fd = socket,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &recv_result,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                const ptr: *Result = @ptrCast(@alignCast(ud.?));
                ptr.* = r;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    try loop.submit();

    var c_cancel_recv: Completion = .{
        .op = .{ .cancel = .{ .c = &c_recv } },
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = r.cancel catch unreachable;
                _ = ud;
                _ = l;
                _ = c;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel_recv);

    // Wait for the send/receive
    try loop.run(.until_done);

    try testing.expect(recv_result == .recv);
    try testing.expectError(error.Canceled, recv_result.recv);
}

test "iocp: accept cancellation" {
    const mem = std.mem;
    const net = std.net;
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    const ln = try windows.WSASocketW(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);
    errdefer posix.close(ln);

    try posix.setsockopt(ln, posix.SOL.SOCKET, posix.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try posix.bind(ln, &address.any, address.getOsSockLen());
    try posix.listen(ln, kernel_backlog);

    var server_conn_result: Result = undefined;
    var c_accept: Completion = .{
        .op = .{
            .accept = .{
                .socket = ln,
            },
        },

        .userdata = &server_conn_result,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = l;
                _ = c;
                const conn: *Result = @ptrCast(@alignCast(ud.?));
                conn.* = r;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_accept);

    try loop.submit();

    var c_cancel_accept: Completion = .{
        .op = .{ .cancel = .{ .c = &c_accept } },
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *Loop,
                c: *Completion,
                r: Result,
            ) CallbackAction {
                _ = r.cancel catch unreachable;
                _ = ud;
                _ = l;
                _ = c;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel_accept);

    // Wait for the send/receive
    try loop.run(.until_done);

    try testing.expect(server_conn_result == .accept);
    try testing.expectError(error.Canceled, server_conn_result.accept);
}
