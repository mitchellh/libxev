const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const xev = @import("xev");
//const xev = @import("xev").Dynamic;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    try run(1);
}

pub fn run(comptime count: comptime_int) !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    if (xev.dynamic) try xev.detect();
    var loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const addr = try std.net.Address.parseIp4("127.0.0.1", 3131);

    var pingers: [count]Pinger = undefined;
    for (&pingers) |*p| {
        p.* = try Pinger.init(addr);
        try p.start(&loop);
    }

    const start_time = try Instant.now();
    try loop.run(.until_done);
    const end_time = try Instant.now();

    const total: usize = total: {
        var total: usize = 0;
        for (&pingers) |p| total += p.pongs;
        break :total total;
    };

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("ping_pongs: {d} pingers, ~{d:.0} roundtrips/s", .{
        count,
        @as(f64, @floatFromInt(total)) / (elapsed / 1e9),
    });
}

const Pinger = struct {
    udp: xev.UDP,
    addr: std.net.Address,
    state: usize = 0,
    pongs: u64 = 0,
    read_buf: [1024]u8 = undefined,
    c_read: xev.Completion = undefined,
    c_write: xev.Completion = undefined,
    state_read: xev.UDP.State = undefined,
    state_write: xev.UDP.State = undefined,
    op_count: u8 = 0,

    pub const PING = "PING\n";

    pub fn init(addr: std.net.Address) !Pinger {
        return .{
            .udp = try xev.UDP.init(addr),
            .state = 0,
            .pongs = 0,
            .addr = addr,
        };
    }

    pub fn start(self: *Pinger, loop: *xev.Loop) !void {
        try self.udp.bind(self.addr);

        self.udp.read(
            loop,
            &self.c_read,
            &self.state_read,
            .{ .slice = &self.read_buf },
            Pinger,
            self,
            Pinger.readCallback,
        );

        self.write(loop);
    }

    pub fn write(self: *Pinger, loop: *xev.Loop) void {
        self.udp.write(
            loop,
            &self.c_write,
            &self.state_write,
            self.addr,
            .{ .slice = PING[0..PING.len] },
            Pinger,
            self,
            writeCallback,
        );
    }

    pub fn readCallback(
        self_: ?*Pinger,
        loop: *xev.Loop,
        c: *xev.Completion,
        _: *xev.UDP.State,
        _: std.net.Address,
        socket: xev.UDP,
        buf: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        _ = c;
        _ = socket;
        const self = self_.?;
        const n = r catch unreachable;
        const data = buf.slice[0..n];

        var i: usize = 0;
        while (i < n) : (i += 1) {
            assert(data[i] == PING[self.state]);
            self.state = (self.state + 1) % (PING.len);
            if (self.state == 0) {
                self.pongs += 1;

                // If we're done then exit
                if (self.pongs > 500_000) {
                    self.udp.close(loop, &self.c_read, Pinger, self, closeCallback);
                    return .disarm;
                }

                self.op_count += 1;
                if (self.op_count == 2) {
                    self.op_count = 0;
                    // Send another ping
                    self.write(loop);
                }
            }
        }

        return .rearm;
    }

    pub fn writeCallback(
        self_: ?*Pinger,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: *xev.UDP.State,
        _: xev.UDP,
        _: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = self_.?;

        self.op_count += 1;
        if (self.op_count == 2) {
            self.op_count = 0;
            // Send another ping
            self.write(loop);
        }

        _ = r catch unreachable;
        return .disarm;
    }

    pub fn closeCallback(
        _: ?*Pinger,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.UDP,
        r: xev.CloseError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;
        return .disarm;
    }
};
