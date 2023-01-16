// This file contains the C bindings that are exported when building
// the system libraries.
//
// WHERE IS THE DOCUMENTATION? Note that all the documentation for the C
// interface is in the header file xev.h. The implementation for these various
// functions also have some comments but they are tailored to the Zig API.
// Still, the source code documentation can be helpful, too.

const std = @import("std");
const assert = std.debug.assert;
const xev = @import("main.zig");

export fn xev_loop_init(loop: *xev.Loop, entries: u32) c_int {
    // TODO: overflow
    loop.* = xev.Loop.init(@intCast(u13, entries)) catch |err| return errorCode(err);
    return 0;
}

export fn xev_loop_deinit(loop: *xev.Loop) void {
    loop.deinit();
}

/// Returns the unique error code for an error.
fn errorCode(err: anyerror) c_int {
    // TODO(mitchellh): This is a bad idea because its not stable across
    // code changes. For now we just document that error codes are not
    // stable but that is not useful at all!
    return @errorToInt(err);
}
