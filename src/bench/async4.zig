const std = @import("std");
const run = @import("async1.zig").run;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    try run(4, init.io);
}
