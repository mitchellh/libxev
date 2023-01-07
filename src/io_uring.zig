const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const Loop = struct {
    ring: linux.IO_Uring,

    /// Initialize the event loop. "entries" is the maximum number of
    /// submissions that can be queued at one time. The number of completions
    /// always matches the number of entries so the memory allocated will be
    /// 2x entries (plus the basic loop overhead).
    pub fn init(entries: u13) !Loop {
        return .{
            // TODO(mitchellh): add an init_advanced function or something
            // for people using the io_uring API directly to be able to set
            // the flags for this.
            .ring = try linux.IO_Uring.init(entries, 0),
        };
    }

    pub fn deinit(self: *Loop) void {
        self.ring.deinit();
    }

    pub const Completion = struct {
        next: ?*Completion = null,
        op: Operation,
    };

    /// All the supported operations of this event loop. These are always
    /// backend-specific and therefore the structure and types change depending
    /// on the underlying system in use. The high level operations are
    /// done by initializing the request handles.
    pub const Operation = union(enum) {
        timeout: struct {},
    };
};

test Loop {
    var loop = try Loop.init(16);
    defer loop.deinit();
}
