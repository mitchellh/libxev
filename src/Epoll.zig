pub const Epoll = @This();

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const IntrusiveQueue = @import("queue.zig").IntrusiveQueue;
const xev = @import("main.zig");

fd: std.os.fd_t,

/// Our queue of submissions that we want to enqueue on the next tick.
submissions: IntrusiveQueue(Completion) = .{},

pub fn init(entries: u13) !Epoll {
    _ = entries;

    return .{
        .fd = try std.os.epoll_create1(std.os.O.CLOEXEC),
    };
}

pub fn deinit(self: *Epoll) void {
    std.os.close(self.fd);
}

/// Add a completion to the loop.
pub fn add(self: *Epoll, completion: *Completion) void {
    // We just add the completion to the queue. Failures can happen
    // at tick time...
    self.submissions.push(completion);
}

/// Tick through the event loop once, waiting for at least "wait" completions
/// to be processed by the loop itself.
pub fn tick(self: *Epoll, wait: u32) !void {
    _ = wait;

    // Submit all the submissions.
    var queued = self.submissions;
    self.submissions = .{};
    while (queued.pop()) |c| self.start(c);
}

fn start(self: *Epoll, completion: *Completion) void {
    const res: std.os.EpollCtlError!void = switch (completion.op) {
        .read => |*v| read: {
            const ev: linux.epoll_event = .{
                .events = linux.EPOLL.POLLIN | linux.EPOLL.RDHUP,
                .data = .{ .ptr = @ptrToInt(completion) },
            };

            break :read std.os.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                v.fd,
                &ev,
            );
        },
    };

    // If we failed to add the completion then we call the callback
    // immediately and mark the error.
    _ = res catch |err| {
        completion.callback(completion.userdata, self, completion, err);
    };
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

    /// Set to true when this completion is added to the epoll fd or
    /// some other internal state of the loop that needs to be cleaned up.
    active: bool = false,

    /// Intrusive queue field
    next: ?*Completion = null,
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

test Epoll {
    var loop = try init(0);
    defer loop.deinit();
}
