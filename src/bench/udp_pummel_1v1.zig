const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const xev = @import("xev");
//const xev = @import("xev").Dynamic;

const EXPECTED = "RANG TANG DING DONG I AM THE JAPANESE SANDMAN";

/// This is a global var decremented for the test without any locks. That's
/// how the original is written and that's how we're going to do it.
var packet_counter: usize = 1e6;
var send_cb_called: usize = 0;
var recv_cb_called: usize = 0;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    try run(1, 1);
}

pub fn run(comptime n_senders: comptime_int, comptime n_receivers: comptime_int) !void {
    const base_port = 12345;

    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    if (xev.dynamic) try xev.detect();
    var loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    var receivers: [n_receivers]Receiver = undefined;
    for (&receivers, 0..) |*r, i| {
        const addr = try std.net.Address.parseIp4("127.0.0.1", @as(u16, @intCast(base_port + i)));
        r.* = .{ .udp = try xev.UDP.init(addr) };
        try r.udp.bind(addr);
        r.udp.read(
            &loop,
            &r.c_recv,
            &r.udp_state,
            .{ .slice = &r.recv_buf },
            Receiver,
            r,
            Receiver.readCallback,
        );
    }

    var senders: [n_senders]Sender = undefined;
    for (&senders, 0..) |*s, i| {
        const addr = try std.net.Address.parseIp4(
            "127.0.0.1",
            @as(u16, @intCast(base_port + (i % n_receivers))),
        );
        s.* = .{ .udp = try xev.UDP.init(addr) };
        s.udp.write(
            &loop,
            &s.c_send,
            &s.udp_state,
            addr,
            .{ .slice = EXPECTED },
            Sender,
            s,
            Sender.writeCallback,
        );
    }

    const start_time = try Instant.now();
    try loop.run(.until_done);
    const end_time = try Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("udp_pummel_{d}v{d}: {d:.0}f/s received, {d:.0}f/s sent, {d} received, {d} sent in {d:.1} seconds", .{
        n_senders,
        n_receivers,
        @as(f64, @floatFromInt(recv_cb_called)) / (elapsed / std.time.ns_per_s),
        @as(f64, @floatFromInt(send_cb_called)) / (elapsed / std.time.ns_per_s),
        recv_cb_called,
        send_cb_called,
        elapsed / std.time.ns_per_s,
    });
}

const Sender = struct {
    udp: xev.UDP,
    udp_state: xev.UDP.State = undefined,
    c_send: xev.Completion = undefined,

    fn writeCallback(
        _: ?*Sender,
        l: *xev.Loop,
        _: *xev.Completion,
        _: *xev.UDP.State,
        _: xev.UDP,
        _: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        _ = r catch unreachable;

        if (packet_counter == 0) {
            l.stop();
            return .disarm;
        }

        packet_counter -|= 1;
        send_cb_called += 1;

        return .rearm;
    }
};

const Receiver = struct {
    udp: xev.UDP,
    udp_state: xev.UDP.State = undefined,
    c_recv: xev.Completion = undefined,
    recv_buf: [65536]u8 = undefined,

    fn readCallback(
        _: ?*Receiver,
        _: *xev.Loop,
        _: *xev.Completion,
        _: *xev.UDP.State,
        _: std.net.Address,
        _: xev.UDP,
        b: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const n = r catch |err| {
            switch (err) {
                error.EOF => {},
                else => std.log.warn("err={}", .{err}),
            }

            return .disarm;
        };

        if (!std.mem.eql(u8, b.slice[0..n], EXPECTED)) {
            @panic("Unexpected data.");
        }

        recv_cb_called += 1;
        return .rearm;
    }
};
