//! Backend to use win32 IOCP.
const std = @import("std");
const assert = std.debug.assert;
const windows = @import("../windows.zig");
const queue = @import("../queue.zig");
const heap = @import("../heap.zig");
const xev = @import("../main.zig").IOCP;

const log = std.log.scoped(.libxev_iocp);

pub const Loop = struct {
    const TimerHeap = heap.Intrusive(Timer, void, Timer.less);

    /// The handle to the IO completion port.
    iocp_handle: windows.HANDLE,

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
    pub fn init(options: xev.Options) !Loop {
        _ = options;

        // Get the duration of the QueryPerformanceCounter.
        // We should check if the division is lossless, but it returns 10_000_000 on my machine so
        // we'll handle that later.
        var qpc_duration: u64 = 1_000_000_000 / windows.QueryPerformanceFrequency();

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

    /// Add a completion to the loop. The completion is not started until the loop is run (`run`) or
    /// an explicit submission request is made (`submit`).
    pub fn add(self: *Loop, completion: *Completion) void {
        if (completion.op == .cancel) {
            self.start_completion(completion);
            return;
        }

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

    /// Process the cancellations queue. This doesn't call any callbacks or perform any syscalls.
    /// This just shuffles state around and sets things up for cancellation to occur.
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
    pub fn run(self: *Loop, mode: xev.RunMode) !void {
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

        var wait_rem = @intCast(usize, wait);

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
                // We retrieve the Completion from the OVERLAPPED pointer as we know it's a part of
                // the Completion struct.
                const overlapped_ptr: *windows.OVERLAPPED = entry.lpOverlapped;
                var completion = @fieldParentPtr(Completion, "overlapped", overlapped_ptr);

                wait_rem -|= 1;

                self.active -= 1;
                completion.flags.state = .dead;

                const result = completion.perform();
                const action = completion.callback(completion.userdata, self, completion, result);
                switch (action) {
                    .disarm => {},
                    .rearm => @panic("Uh oh"),
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
    pub fn now(self: *Loop) u64 {
        return self.cached_now;
    }

    /// Update the cached time.
    pub fn update_now(self: *Loop) void {
        // Compute the current timestamp in ms by multiplying the QueryPerfomanceCounter value in
        // ticks by the duration of a tick.
        self.cached_now = windows.QueryPerformanceCounter() * self.qpc_duration;
    }

    /// Add a timer to the loop. The timer will execute in "next_ms". This is oneshot: the timer
    /// will not repeat. To repeat a timer, either shcedule another in your callback or return rearm
    /// from the callback.
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
        comptime cb: xev.Callback,
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

            // We have a result code from making a system call now.
            result: Result,
        };

        const action: StartAction = switch (completion.op) {
            .noop => {
                completion.flags.state = .dead;
                return;
            },

            .accept => |*v| action: {
                var discard: u32 = undefined;
                const result = windows.ws2_32.AcceptEx(
                    v.listen_socket,
                    v.accept_socket,
                    &v.storage,
                    0,
                    @intCast(u32, @sizeOf(std.os.sockaddr.storage) + 16),
                    @intCast(u32, @sizeOf(std.os.sockaddr.storage) + 16),
                    &discard,
                    &completion.overlapped,
                );
                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :action switch (err) {
                        windows.ws2_32.WinsockError.WSA_IO_PENDING => .{ .submitted = {} },
                        else => .{ .result = .{ .accept = windows.unexpectedWSAError(err) } },
                    };
                }

                break :action .{ .submitted = {} };
            },

            .close => |v| switch (v) {
                .socket => |s| .{ .result = .{ .close = windows.closesocket(s) catch error.Unexpected } },
                .handle => |h| .{ .result = .{ .close = windows.CloseHandle(h) } },
            },

            .connect => |*v| action: {
                const result = windows.ws2_32.connect(v.socket, &v.addr.any, @intCast(i32, v.addr.getOsSockLen()));
                if (result != 0) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :action switch (err) {
                        else => .{ .result = .{ .connect = windows.unexpectedWSAError(err) } },
                    };
                }
                break :action .{ .result = .{ .connect = {} } };
            },

            .read => |*v| action: {
                var buffer: []u8 = if (v.buffer == .slice) v.buffer.slice else &v.buffer.array;
                break :action if (windows.ReadFileW(v.handle, buffer, &completion.overlapped)) |_|
                    .{
                        .submitted = {},
                    }
                else |err|
                    .{
                        .result = .{ .read = err },
                    };
            },

            .shutdown => |*v| .{ .result = .{ .shutdown = std.os.shutdown(v.socket, v.how) } },

            .write => |*v| action: {
                var buffer: []const u8 = if (v.buffer == .slice) v.buffer.slice else v.buffer.array.array[0..v.buffer.array.len];
                break :action if (windows.WriteFileW(v.handle, buffer, &completion.overlapped)) |_|
                    .{
                        .submitted = {},
                    }
                else |err|
                    .{
                        .result = .{ .write = err },
                    };
            },

            .send => |*v| action: {
                var buffer: []const u8 = if (v.buffer == .slice) v.buffer.slice else v.buffer.array.array[0..v.buffer.array.len];
                v.wsa_buffer = .{ .buf = @constCast(buffer.ptr), .len = @intCast(u32, buffer.len) };
                const result = windows.ws2_32.WSASend(
                    v.socket,
                    @ptrCast([*]windows.ws2_32.WSABUF, &v.wsa_buffer),
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
                        else => .{ .result = .{ .accept = windows.unexpectedWSAError(err) } },
                    };
                }
                break :action .{ .submitted = {} };
            },

            .recv => |*v| action: {
                var buffer: []u8 = if (v.buffer == .slice) v.buffer.slice else &v.buffer.array;
                v.wsa_buffer = .{ .buf = buffer.ptr, .len = @intCast(u32, buffer.len) };

                var flags: u32 = 0;

                const result = windows.ws2_32.WSARecv(
                    v.socket,
                    @ptrCast([*]windows.ws2_32.WSABUF, &v.wsa_buffer),
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
                        else => .{ .result = .{ .accept = windows.unexpectedWSAError(err) } },
                    };
                }
                break :action .{ .submitted = {} };
            },

            .timer => |*v| action: {
                v.c = completion;
                self.timers.insert(v);
                break :action .{ .timer = {} };
            },

            .cancel => .{ .cancel = {} },
        };

        switch (action) {
            .timer, .submitted => {
                // Increase our active count so we now wait for this. We assume it'll successfully
                // queue. If it doesn't we handle that later (see submit).
                self.active += 1;
                completion.flags.state = .active;
            },

            .cancel => {
                // We are considered an active completion.
                self.active += 1;
                completion.flags.state = .active;

                self.cancellations.push(completion);
            },

            // A result is immediately available. Queue the completion to be invoked.
            .result => |r| {
                completion.result = r;
                self.completions.push(completion);
            },
        }
    }

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
            inline .accept, .recv, .send => {
                if (completion.flags.state == .active) {
                    const handle: windows.HANDLE = switch (completion.op) {
                        .accept => |*v2| v2.listen_socket,
                        inline .recv, .send => |*v2| v2.socket,
                        inline .read, .write => |*v2| v2.handle,
                        else => unreachable,
                    };
                    const result = windows.kernel32.CancelIoEx(handle, &completion.overlapped);
                    cancel_result.?.* = if (result == windows.FALSE)
                        windows.unexpectedError(windows.kernel32.GetLastError())
                    else {};
                }
            },

            else => @panic("Not implemented"),
        }
    }

    /// Associate a handler to the internal completion port.
    /// This has to be done only once per handle so we delegate the responsibility to the caller.
    pub fn associate_handle(self: *Loop, handle: windows.HANDLE) !void {
        _ = try windows.CreateIoCompletionPort(handle, self.iocp_handle, 0, 0);
    }
};

/// A completion is a request to perform some work with the loop.
pub const Completion = struct {
    /// Operation to execute.
    op: Operation = .{ .noop = {} },

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: xev.Callback = xev.noopCallback,

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

    const State = enum(u3) {
        /// completion is not part of any loop
        dead = 0,

        /// completion is in the submission queue
        adding = 1,

        /// completion is submitted successfully
        active = 3,
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
    pub fn state(self: Completion) xev.CompletionState {
        return switch (self.flags.state) {
            .dead => .dead,
            .adding, .active => .active,
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

            .accept => |*v| r: {
                var bytes_transferred: u32 = 0;
                var flags: u32 = 0;
                const result = windows.ws2_32.WSAGetOverlappedResult(v.listen_socket, &self.overlapped, &bytes_transferred, windows.FALSE, &flags);

                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :r .{
                        .accept = switch (err) {
                            windows.ws2_32.WinsockError.WSA_OPERATION_ABORTED => error.Canceled,
                            else => windows.unexpectedWSAError(err),
                        },
                    };
                }

                var local_address_ptr: *std.os.sockaddr = undefined;
                var local_address_len: i32 = @sizeOf(std.os.sockaddr.storage);
                var remote_address_ptr: *std.os.sockaddr = undefined;
                var remote_address_len: i32 = @sizeOf(std.os.sockaddr.storage);

                windows.ws2_32.GetAcceptExSockaddrs(
                    &v.storage,
                    0,
                    @intCast(u32, @sizeOf(std.os.sockaddr.storage) + 16),
                    @intCast(u32, @sizeOf(std.os.sockaddr.storage) + 16),
                    &local_address_ptr,
                    &local_address_len,
                    &remote_address_ptr,
                    &remote_address_len,
                );

                break :r .{ .accept = .{
                    .accept_socket = self.op.accept.accept_socket,
                    .local_address = std.net.Address.initPosix(@alignCast(4, local_address_ptr)),
                    .remote_address = std.net.Address.initPosix(@alignCast(4, remote_address_ptr)),
                } };
            },

            .read => |*v| r: {
                var bytes_transferred: windows.DWORD = 0;
                const result = windows.kernel32.GetOverlappedResult(v.handle, &self.overlapped, &bytes_transferred, windows.FALSE);
                if (result == windows.FALSE) {
                    const err = windows.kernel32.GetLastError();
                    break :r .{ .read = switch (err) {
                        windows.Win32Error.OPERATION_ABORTED => error.Canceled,
                        else => error.Unexpected,
                    } };
                }
                break :r .{ .read = @intCast(usize, bytes_transferred) };
            },

            .write => |*v| r: {
                var bytes_transferred: windows.DWORD = 0;
                const result = windows.kernel32.GetOverlappedResult(v.handle, &self.overlapped, &bytes_transferred, windows.FALSE);
                if (result == windows.FALSE) {
                    const err = windows.kernel32.GetLastError();
                    break :r .{ .write = switch (err) {
                        windows.Win32Error.OPERATION_ABORTED => error.Canceled,
                        else => error.Unexpected,
                    } };
                }
                break :r .{ .write = @intCast(usize, bytes_transferred) };
            },

            .send => |*v| r: {
                var bytes_transferred: u32 = 0;
                var flags: u32 = 0;

                const result = windows.ws2_32.WSAGetOverlappedResult(v.socket, &self.overlapped, &bytes_transferred, windows.FALSE, &flags);

                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :r .{
                        .send = switch (err) {
                            windows.ws2_32.WinsockError.WSA_OPERATION_ABORTED => error.Canceled,
                            else => windows.unexpectedWSAError(err),
                        },
                    };
                }
                break :r .{ .send = @intCast(usize, bytes_transferred) };
            },

            .recv => |*v| r: {
                var bytes_transferred: u32 = 0;
                var flags: u32 = 0;

                const result = windows.ws2_32.WSAGetOverlappedResult(v.socket, &self.overlapped, &bytes_transferred, windows.FALSE, &flags);

                if (result != windows.TRUE) {
                    const err = windows.ws2_32.WSAGetLastError();
                    break :r .{
                        .recv = switch (err) {
                            windows.ws2_32.WinsockError.WSA_OPERATION_ABORTED => error.Canceled,
                            else => windows.unexpectedWSAError(err),
                        },
                    };
                }

                // NOTE(Corentin): according to Win32 documentation, EOF has to be detected using
                // the socket type.
                const socket_type = t: {
                    var socket_type: windows.DWORD = 0;
                    var socket_type_bytes = std.mem.asBytes(&socket_type);
                    var opt_len: i32 = @intCast(i32, socket_type_bytes.len);

                    // Here we assume the call will succeed because the socket should be valid.
                    std.debug.assert(windows.ws2_32.getsockopt(v.socket, std.os.SOL.SOCKET, std.os.SO.TYPE, socket_type_bytes, &opt_len) == 0);
                    break :t socket_type;
                };

                if (socket_type == std.os.SOCK.STREAM and bytes_transferred == 0) {
                    break :r .{ .recv = error.EOF };
                }

                break :r .{ .recv = @intCast(usize, bytes_transferred) };
            },
        };
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

    /// Shutdown all or part of a full-duplex connection.
    shutdown,

    /// Write
    write,

    /// Send
    send,

    /// Recv
    recv,

    /// A oneshot or repeating timer. For io_uring, this is implemented
    /// using the timeout mechanism.
    timer,

    /// Cancel an existing operation.
    cancel,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    noop: void,

    accept: struct {
        listen_socket: windows.ws2_32.SOCKET,
        accept_socket: windows.ws2_32.SOCKET,
        storage: [256]u8 = undefined,
    },

    connect: struct {
        socket: windows.ws2_32.SOCKET,
        addr: std.net.Address,
    },

    close: union(enum) {
        socket: windows.ws2_32.SOCKET,
        handle: windows.HANDLE,
    },

    read: struct {
        handle: windows.HANDLE,
        buffer: ReadBuffer,
    },

    shutdown: struct {
        socket: windows.ws2_32.SOCKET,
        how: std.os.ShutdownHow = .both,
    },

    timer: Timer,

    write: struct {
        handle: windows.HANDLE,
        buffer: WriteBuffer,
    },

    send: struct {
        socket: windows.ws2_32.SOCKET,
        buffer: WriteBuffer,
        wsa_buffer: windows.ws2_32.WSABUF = undefined,
    },

    recv: struct {
        socket: windows.ws2_32.SOCKET,
        buffer: ReadBuffer,
        wsa_buffer: windows.ws2_32.WSABUF = undefined,
    },

    cancel: struct {
        c: *Completion,
    },
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    noop: void,
    accept: AcceptError!struct {
        accept_socket: windows.ws2_32.SOCKET,
        local_address: std.net.Address,
        remote_address: std.net.Address,
    },
    connect: ConnectError!void,
    close: CloseError!void,
    read: ReadError!usize,
    shutdown: ShutdownError!void,
    timer: TimerError!TimerTrigger,
    write: WriteError!usize,
    send: WriteError!usize,
    recv: ReadError!usize,
    cancel: CancelError!void,
};

pub const CancelError = error{
    Unexpected,
};

pub const AcceptError = error{
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

pub const ShutdownError = std.os.ShutdownError || error{
    Unexpected,
};

pub const WriteError = windows.WriteFileError || error{
    Canceled,
    Unexpected,
};

pub const ReadError = windows.ReadFileError || error{
    EOF,
    Canceled,
    Unexpected,
};

pub const AsyncError = error{
    Unexpected,
};

pub const TimerError = error{
    Unexpected,
};

pub const TimerRemoveError = error{
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
    var now = loop.now();
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
        fn callback(ud: ?*anyopaque, l: *xev.Loop, _: *xev.Completion, r: xev.Result) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
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

    const cb: xev.Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const v = @ptrCast(*?TimerTrigger, ud.?);
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

    const cb: xev.Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const v = @ptrCast(*?TimerTrigger, ud.?);
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

    const cb: xev.Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const v = @ptrCast(*?TimerTrigger, ud.?);
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
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @ptrCast(*?TimerTrigger, @alignCast(@alignOf(?TimerTrigger), ud.?));
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
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
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
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 1, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @ptrCast(*?TimerTrigger, @alignCast(@alignOf(?TimerTrigger), ud.?));
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
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
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

fn openTempFile(name: [:0]const u16) !windows.HANDLE {
    const result = windows.CreateFile(name, windows.GENERIC_READ | windows.GENERIC_WRITE, 0, null, windows.OPEN_ALWAYS, windows.FILE_FLAG_OVERLAPPED, null);

    return result;
}

test "iocp: file IO" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const utf16_file_name = (try windows.sliceToPrefixedFileW("test_watcher_file")).span();

    const f_handle = try windows.CreateFile(utf16_file_name, windows.GENERIC_READ | windows.GENERIC_WRITE, 0, null, windows.OPEN_ALWAYS, windows.FILE_FLAG_OVERLAPPED, null);
    defer windows.DeleteFileW(utf16_file_name) catch {};
    defer windows.CloseHandle(f_handle);

    try loop.associate_handle(f_handle);

    // Perform a write and then a read
    var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    var c_write: xev.Completion = .{
        .op = .{
            .write = .{
                .handle = f_handle,
                .buffer = .{ .slice = &write_buf },
            },
        },
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
    var c_read: xev.Completion = .{
        .op = .{
            .read = .{
                .handle = f_handle,
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
                const ptr = @ptrCast(*usize, @alignCast(@alignOf(usize), ud.?));
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

test "iocp: socket accept/connect/send/recv/close" {
    const mem = std.mem;
    const net = std.net;
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    var ln = try windows.WSASocketW(std.os.AF.INET, std.os.SOCK.STREAM, std.os.IPPROTO.TCP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);
    errdefer std.os.closeSocket(ln);

    try std.os.setsockopt(ln, std.os.SOL.SOCKET, std.os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try std.os.bind(ln, &address.any, address.getOsSockLen());
    try std.os.listen(ln, kernel_backlog);

    // Create a TCP client socket
    var client_conn = try windows.WSASocketW(std.os.AF.INET, std.os.SOCK.STREAM, std.os.IPPROTO.TCP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);
    errdefer std.os.closeSocket(client_conn);

    // Accept
    var server_conn = try windows.WSASocketW(std.os.AF.INET, std.os.SOCK.STREAM, std.os.IPPROTO.TCP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);

    try loop.associate_handle(@ptrCast(windows.HANDLE, ln));
    try loop.associate_handle(@ptrCast(windows.HANDLE, client_conn));
    try loop.associate_handle(@ptrCast(windows.HANDLE, server_conn));

    var server_conn_result: Result = undefined;
    var c_accept: Completion = .{
        .op = .{
            .accept = .{
                .listen_socket = ln,
                .accept_socket = server_conn,
            },
        },

        .userdata = &server_conn_result,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const conn = @ptrCast(*Result, @alignCast(@alignOf(Result), ud.?));
                conn.* = r;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_accept);

    // Connect
    var connected = false;
    var c_connect: xev.Completion = .{
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
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.connect catch unreachable;
                const b = @ptrCast(*bool, ud.?);
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

    // Send
    var c_send: xev.Completion = .{
        .op = .{
            .send = .{
                .socket = client_conn,
                .buffer = .{ .slice = &[_]u8{ 1, 1, 2, 3, 5, 8, 13 } },
            },
        },

        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
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
    var c_recv: xev.Completion = .{
        .op = .{
            .recv = .{
                .socket = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &recv_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*usize, @alignCast(@alignOf(usize), ud.?));
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
    var c_client_shutdown: xev.Completion = .{
        .op = .{
            .shutdown = .{
                .socket = client_conn,
            },
        },

        .userdata = &shutdown,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.shutdown catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
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
                .socket = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &eof,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*?bool, @alignCast(@alignOf(?bool), ud.?));
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
    var c_client_close: xev.Completion = .{
        .op = .{
            .close = .{
                .socket = client_conn,
            },
        },

        .userdata = &client_conn_closed,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_close);

    var ln_closed: bool = false;
    var c_server_close: xev.Completion = .{
        .op = .{
            .close = .{
                .socket = ln,
            },
        },

        .userdata = &ln_closed,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
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
    var socket = try windows.WSASocketW(std.os.AF.INET, std.os.SOCK.DGRAM, std.os.IPPROTO.UDP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);
    errdefer std.os.closeSocket(socket);

    try std.os.setsockopt(socket, std.os.SOL.SOCKET, std.os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try std.os.bind(socket, &address.any, address.getOsSockLen());

    try loop.associate_handle(@ptrCast(windows.HANDLE, socket));

    var recv_buf: [128]u8 = undefined;
    var recv_result: Result = undefined;
    var c_recv: xev.Completion = .{
        .op = .{
            .recv = .{
                .socket = socket,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &recv_result,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*Result, @alignCast(@alignOf(Result), ud.?));
                ptr.* = r;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    try loop.submit();

    var c_cancel_recv: xev.Completion = .{
        .op = .{ .cancel = .{ .c = &c_recv } },
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
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
    var ln = try windows.WSASocketW(std.os.AF.INET, std.os.SOCK.STREAM, std.os.IPPROTO.TCP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);
    errdefer std.os.closeSocket(ln);

    try std.os.setsockopt(ln, std.os.SOL.SOCKET, std.os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try std.os.bind(ln, &address.any, address.getOsSockLen());
    try std.os.listen(ln, kernel_backlog);

    // Accept
    var server_conn = try windows.WSASocketW(std.os.AF.INET, std.os.SOCK.STREAM, std.os.IPPROTO.TCP, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);

    try loop.associate_handle(@ptrCast(windows.HANDLE, ln));
    try loop.associate_handle(@ptrCast(windows.HANDLE, server_conn));

    var server_conn_result: Result = undefined;
    var c_accept: Completion = .{
        .op = .{
            .accept = .{
                .listen_socket = ln,
                .accept_socket = server_conn,
            },
        },

        .userdata = &server_conn_result,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const conn = @ptrCast(*Result, @alignCast(@alignOf(Result), ud.?));
                conn.* = r;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_accept);

    try loop.submit();

    var c_cancel_accept: xev.Completion = .{
        .op = .{ .cancel = .{ .c = &c_accept } },
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
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
