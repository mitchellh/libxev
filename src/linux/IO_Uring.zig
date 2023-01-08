pub const IO_Uring = @This();

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const IntrusiveQueue = @import("../queue.zig").IntrusiveQueue;

ring: linux.IO_Uring,

/// Our queue of completed completions where the callback hasn't been called.
completions: IntrusiveQueue(Completion) = .{},

/// Initialize the event loop. "entries" is the maximum number of
/// submissions that can be queued at one time. The number of completions
/// always matches the number of entries so the memory allocated will be
/// 2x entries (plus the basic loop overhead).
pub fn init(entries: u13) !IO_Uring {
    return .{
        // TODO(mitchellh): add an init_advanced function or something
        // for people using the io_uring API directly to be able to set
        // the flags for this.
        .ring = try linux.IO_Uring.init(entries, 0),
    };
}

pub fn deinit(self: *IO_Uring) void {
    self.ring.deinit();
}

/// Add a completion to the loop. This does NOT start the operation!
/// You must call "submit" at some point to submit all of the queued
/// work.
pub fn add(self: *IO_Uring, completion: *Completion) !void {
    const sqe = self.ring.get_sqe() catch |err| switch (err) {
        error.SubmissionQueueFull => @panic("TODO"),
    };

    // Setup the submission depending on the operation
    switch (completion.op) {
        .timerfd_read => |*v| linux.io_uring_prep_read(
            sqe,
            v.fd,
            &v.buffer,
            0,
        ),
    }

    // Our sqe user data always points back to the completion.
    // The prep functions above reset the user data so we have to do this
    // here.
    sqe.user_data = @ptrToInt(completion);
}

/// Submit all queued operations, run the loop once.
pub fn tick(self: *IO_Uring) !void {
    // Submit and then run completions
    try self.submit();
    try self.complete();
}

/// Submit all queued operations.
fn submit(self: *IO_Uring) !void {
    _ = try self.ring.submit();
}

/// Handle all of the completions.
fn complete(self: *IO_Uring) !void {
    // Sync
    try self.sync_completions();

    // Run our callbacks
    self.invoke_completions();
}

/// Sync the completions that are done. This appends to self.completions.
fn sync_completions(self: *IO_Uring) !void {
    // We load cqes in two phases. We first load all the CQEs into our
    // queue, and then we process all CQEs. We do this in two phases so
    // that any callbacks that call into the loop don't cause unbounded
    // stack growth.
    var cqes: [128]linux.io_uring_cqe = undefined;
    while (true) {
        // Guard against waiting indefinitely (if there are too few requests inflight),
        // especially if this is not the first time round the loop:
        const count = self.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
            else => return err,
        };

        for (cqes[0..count]) |cqe| {
            const c = @intToPtr(*Completion, @intCast(usize, cqe.user_data));
            c.res = cqe.res;
            self.completions.push(c);
        }

        // If copy_cqes didn't fill our buffer we have to be done.
        if (count < cqes.len) break;
    }
}

/// Call all of our completion callbacks for any queued completions.
fn invoke_completions(self: *IO_Uring) void {
    while (self.completions.pop()) |c| c.invoke();
}

/// A completion represents a single queued request in the ring.
/// Completions must have stable pointers.
///
/// For the lowest overhead, these can be created manually and queued
/// directly. The API over the individual fields isn't the most user-friendly
/// since it is tune for performance. For user-friendly operations,
/// use the higher-level functions on this structure or the even
/// higher-level abstractions like the Timer struct.
pub const Completion = struct {
    op: Operation,
    userdata: ?*anyopaque = null,
    callback: *const fn (userdata: ?*anyopaque, completion: *Completion, result: Result) void,

    /// Internally set
    next: ?*Completion = null,
    res: i32 = 0,

    /// Invokes the callback for this completion after properly constructing
    /// the Result based on the res code.
    fn invoke(self: *Completion) void {
        const res = switch (self.op) {
            .timerfd_read => .{
                .timerfd_read = if (self.res >= 0)
                    @intCast(usize, self.res)
                else switch (@intToEnum(std.os.E, -self.res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },
        };

        self.callback(self.userdata, self, res);
    }
};

pub const OperationType = enum {
    /// Read from a timerfd. This is special-cased over read to have
    /// a static buffer so the caller doesn't have to worry about buffer
    /// memory management.
    timerfd_read,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    timerfd_read: ReadError!usize,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    timerfd_read: struct {
        fd: std.os.fd_t,
        buffer: [8]u8 = undefined,
    },
};

pub const ReadError = error{
    Unexpected,
};

test IO_Uring {
    var loop = try IO_Uring.init(16);
    defer loop.deinit();

    // We'll try with a simple timerfd
    const Timerfd = @import("timerfd.zig").Timerfd;
    var t = try Timerfd.init(.monotonic, 0);
    defer t.deinit();
    try t.set(0, &.{ .value = .{ .nanoseconds = 1 } }, null);

    // Add the timer
    var called = false;
    var c: IO_Uring.Completion = .{
        .op = .{
            .timerfd_read = .{
                .fd = t.fd,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                _ = r;
                const b = @ptrCast(*bool, ud.?);
                b.* = true;
            }
        }).callback,
    };
    try loop.add(&c);

    // Tick
    while (!called) try loop.tick();
}
