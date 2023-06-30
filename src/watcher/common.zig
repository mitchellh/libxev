/// Convert the callback value with an opaque pointer into the userdata type
/// that we can pass to our higher level callback types.
pub fn userdataValue(comptime Userdata: type, v: ?*anyopaque) ?*Userdata {
    // Void userdata is always a null pointer.
    if (Userdata == void) return null;
    return @ptrCast(@alignCast(v));
}
