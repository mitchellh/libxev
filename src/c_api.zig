// This file contains the C bindings that are exported when building
// the system libraries.
//
// WHERE IS THE DOCUMENTATION? Note that all the documentation for the C
// interface is in the header file xev.h. The implementation for these various
// functions also have some comments but they are tailored to the Zig API.
// Still, the source code documentation can be helpful, too.

const std = @import("std");
const builtin = @import("builtin");
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

export fn xev_loop_run(loop: *xev.Loop, mode: xev.RunMode) c_int {
    loop.run(mode) catch |err| return errorCode(err);
    return 0;
}

//-------------------------------------------------------------------
// Timers

export fn xev_timer_init(v: *xev.Timer) c_int {
    v.* = xev.Timer.init() catch |err| return errorCode(err);
    return 0;
}

export fn xev_timer_deinit(v: *xev.Timer) void {
    v.deinit();
}

export fn xev_timer_run(
    v: *xev.Timer,
    loop: *xev.Loop,
    c: *xev.Completion,
    next_ms: u64,
    userdata: ?*anyopaque,
    cb: *const fn (
        *xev.Loop,
        *xev.Completion,
        c_int,
        ?*anyopaque,
    ) callconv(.C) xev.CallbackAction,
) void {
    const Callback = @TypeOf(cb);
    const extern_c = @ptrCast(*Completion, @alignCast(@alignOf(Completion), c));
    extern_c.c_callback = @ptrCast(?*const anyopaque, cb);

    v.run(loop, c, next_ms, anyopaque, userdata, (struct {
        fn callback(
            ud: ?*anyopaque,
            cb_loop: *xev.Loop,
            cb_c: *xev.Completion,
            r: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            const cb_extern_c = @ptrCast(*Completion, cb_c);
            const cb_c_callback = @ptrCast(Callback, @alignCast(@alignOf(Callback), cb_extern_c.c_callback));
            return @call(.auto, cb_c_callback, .{
                cb_loop,
                cb_c,
                if (r) |_| 0 else |err| errorCode(err),
                ud,
            });
        }
    }).callback);
}

//-------------------------------------------------------------------
// Sync with xev.h
const Completion = extern struct {
    data: [@sizeOf(xev.Completion)]u8,
    c_callback: ?*const anyopaque,
};

/// Returns the unique error code for an error.
fn errorCode(err: anyerror) c_int {
    // TODO(mitchellh): This is a bad idea because its not stable across
    // code changes. For now we just document that error codes are not
    // stable but that is not useful at all!
    return @errorToInt(err);
}

test "c-api sizes" {
    // This tests the sizes that are defined in the C API. We must ensure
    // that our main structure sizes never exceed these so that the C ABI
    // is maintained.
    //
    // THE MAGIC NUMBERS ARE KEPT IN SYNC WITH "include/xev.h"
    const testing = std.testing;
    try testing.expect(@sizeOf(xev.Loop) <= 256);
    try testing.expect(@sizeOf(xev.Completion) <= 256);
    try testing.expect(@sizeOf(xev.Timer) <= 256);
}
