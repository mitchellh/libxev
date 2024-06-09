const std = @import("std");
const run = @import("async1.zig").run;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    try run(2);
}
