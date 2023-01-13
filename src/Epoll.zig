pub const Epoll = @This();

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const IntrusiveQueue = @import("queue.zig").IntrusiveQueue;
const xev = @import("main.zig").Epoll;

fd: std.os.fd_t,

/// The number of active completions. This DOES NOT include completions that
/// are queued in the submissions queue.
active: usize = 0,

/// Our queue of submissions that we want to enqueue on the next tick.
submissions: IntrusiveQueue(Completion) = .{},

/// The queue for completions to delete from the epoll fd.
deletions: IntrusiveQueue(Completion) = .{},

pub fn init(entries: u13) !Epoll {
    _ = entries;

    return .{
        .fd = try std.os.epoll_create1(std.os.O.CLOEXEC),
    };
}

pub fn deinit(self: *Epoll) void {
    std.os.close(self.fd);
}

/// Run the event loop. See RunMode documentation for details on modes.
pub fn run(self: *Epoll, mode: xev.RunMode) !void {
    switch (mode) {
        .no_wait => try self.tick(0),
        .once => try self.tick(1),
        .until_done => while (!self.done()) try self.tick(1),
    }
}

fn done(self: *Epoll) bool {
    return self.active == 0 and
        self.submissions.empty();
}

/// Add a completion to the loop.
pub fn add(self: *Epoll, completion: *Completion) void {
    switch (completion.flags.state) {
        // Already adding, forget about it.
        .adding => return,

        // If it is dead we're good. If we're deleting we'll ignore it
        // while we're processing.
        .dead,
        .deleting,
        => {},

        .active => @panic("active completion being re-added"),
    }
    completion.flags.state = .adding;

    // We just add the completion to the queue. Failures can happen
    // at tick time...
    self.submissions.push(completion);
}

/// Delete a completion from the loop.
pub fn delete(self: *Epoll, completion: *Completion) void {
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

/// Tick through the event loop once, waiting for at least "wait" completions
/// to be processed by the loop itself.
pub fn tick(self: *Epoll, wait: u32) !void {
    const timeout: i32 = if (wait == 0) 0 else -1;

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

    // Handle all deletions so we don't wait for them.
    while (self.deletions.pop()) |c| {
        if (c.flags.state != .deleting) continue;
        self.stop(c);
    }

    // Wait and process events. We only do this if we have any active.
    if (self.active > 0) {
        var events: [1024]linux.epoll_event = undefined;
        while (true) {
            const n = std.os.epoll_wait(self.fd, &events, timeout);
            if (n < 0) {
                switch (std.os.errno(n)) {
                    .INTR => continue,
                    else => |err| return std.os.unexpectedErrno(err),
                }
            }

            // Process all our events and invoke their completion handlers
            for (events[0..n]) |ev| {
                const c = @intToPtr(*Completion, @intCast(usize, ev.data.ptr));
                const res = c.perform();
                const action = c.callback(c.userdata, self, c, res);
                switch (action) {
                    .disarm => self.delete(c),

                    // For epoll, epoll remains armed by default so we just
                    // do nothing here...
                    .rearm => {},
                }
            }

            break;
        }
    }
}

fn start(self: *Epoll, completion: *Completion) void {
    const res_: ?Result = switch (completion.op) {
        .read => |*v| read: {
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                .data = .{ .ptr = @ptrToInt(completion) },
            };

            break :read if (std.os.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                v.fd,
                &ev,
            )) null else |err| .{ .read = err };
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

    // Mark the completion as active if we reached this point
    completion.flags.state = .active;

    // Increase our active count
    self.active += 1;
}

fn stop(self: *Epoll, completion: *Completion) void {
    const fd: std.os.fd_t = switch (completion.op) {
        .read => |v| v.fd,
    };

    // Delete. This should never fail.
    std.os.epoll_ctl(
        self.fd,
        linux.EPOLL.CTL_DEL,
        fd,
        null,
    ) catch unreachable;

    // Mark the completion as done
    completion.flags.state = .dead;

    // Decrement the active count so we know how many are running for
    // .until_done run semantics.
    self.active -= 1;
}

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
        dead = 0,
        adding = 1,
        deleting = 2,
        active = 3,
    };

    /// Perform the operation associated with this completion. This will
    /// perform the full blocking operation for the completion.
    fn perform(self: *Completion) Result {
        return switch (self.op) {
            .read => |*op| .{
                .read = if (op.buffer.read(op.fd)) |v|
                    v
                else |_|
                    error.Unknown,
            },
        };
    }
};

pub const OperationType = enum {
    /// Read
    read,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    read: ReadError!usize,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    read: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
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

    fn read(self: *ReadBuffer, fd: std.os.fd_t) !usize {
        _ = fd;
        return switch (self) {
            else => 0,
        };
    }
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

pub const ReadError = std.os.EpollCtlError || error{
    EOF,
    Unexpected,
};

test "Completion size" {
    const testing = std.testing;

    // Just so we are aware when we change the size
    try testing.expectEqual(@as(usize, 80), @sizeOf(Completion));
}

test "epoll: timerfd" {
    const testing = std.testing;

    var loop = try init(0);
    defer loop.deinit();

    // We'll try with a simple timerfd
    const Timerfd = @import("linux/timerfd.zig").Timerfd;
    var t = try Timerfd.init(.monotonic, 0);
    defer t.deinit();
    try t.set(0, &.{ .value = .{ .nanoseconds = 1 } }, null);

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
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = r.read catch unreachable;
                _ = c;
                _ = l;
                const b = @ptrCast(*bool, ud.?);
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
