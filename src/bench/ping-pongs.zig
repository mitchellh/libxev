const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const xev = @import("xev");
//const xev = @import("xev").Dynamic;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    if (xev.dynamic) try xev.detect();
    var loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa: GPA = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var server_loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer server_loop.deinit();

    var server = try Server.init(alloc, &server_loop);
    defer server.deinit();
    try server.start();

    // Start our echo server
    const server_thr = try std.Thread.spawn(.{}, Server.threadMain, .{&server});

    // Start our client
    var client_loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer client_loop.deinit();

    var client = try Client.init(alloc, &client_loop);
    defer client.deinit();
    try client.start();

    const start_time = try Instant.now();
    try client_loop.run(.until_done);
    server_thr.join();
    const end_time = try Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("{d:.2} roundtrips/s", .{@as(f64, @floatFromInt(client.pongs)) / (elapsed / 1e9)});
    std.log.info("{d:.2} seconds total", .{elapsed / 1e9});
}

/// Memory pools for things that need stable pointers
const BufferPool = std.heap.MemoryPool([4096]u8);
const CompletionPool = std.heap.MemoryPool(xev.Completion);
const TCPPool = std.heap.MemoryPool(xev.TCP);

/// The client state
const Client = struct {
    loop: *xev.Loop,
    completion_pool: CompletionPool,
    read_buf: [1024]u8,
    pongs: u64,
    state: usize = 0,
    stop: bool = false,

    pub const PING = "PING\n";

    pub fn init(alloc: Allocator, loop: *xev.Loop) !Client {
        return .{
            .loop = loop,
            .completion_pool = CompletionPool.init(alloc),
            .read_buf = undefined,
            .pongs = 0,
            .state = 0,
            .stop = false,
        };
    }

    pub fn deinit(self: *Client) void {
        self.completion_pool.deinit();
    }

    /// Must be called with stable self pointer.
    pub fn start(self: *Client) !void {
        const addr = try std.net.Address.parseIp4("127.0.0.1", 3131);
        const socket = try xev.TCP.init(addr);

        const c = try self.completion_pool.create();
        socket.connect(self.loop, c, addr, Client, self, connectCallback);
    }

    fn connectCallback(
        self_: ?*Client,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: xev.TCP,
        r: xev.ConnectError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;

        const self = self_.?;

        // Send message
        socket.write(l, c, .{ .slice = PING[0..PING.len] }, Client, self, writeCallback);

        // Read
        const c_read = self.completion_pool.create() catch unreachable;
        socket.read(l, c_read, .{ .slice = &self.read_buf }, Client, self, readCallback);
        return .disarm;
    }

    fn writeCallback(
        self_: ?*Client,
        l: *xev.Loop,
        c: *xev.Completion,
        s: xev.TCP,
        b: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        _ = r catch unreachable;
        _ = l;
        _ = s;
        _ = b;

        // Put back the completion.
        self_.?.completion_pool.destroy(c);
        return .disarm;
    }

    fn readCallback(
        self_: ?*Client,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: xev.TCP,
        buf: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = self_.?;
        const n = r catch unreachable;
        const data = buf.slice[0..n];

        // Count the number of pings in our message
        var i: usize = 0;
        while (i < n) : (i += 1) {
            assert(data[i] == PING[self.state]);
            self.state = (self.state + 1) % (PING.len);
            if (self.state == 0) {
                self.pongs += 1;

                // If we're done then exit
                if (self.pongs > 500_000) {
                    socket.shutdown(l, c, Client, self, shutdownCallback);
                    return .disarm;
                }

                // Send another ping
                const c_ping = self.completion_pool.create() catch unreachable;
                socket.write(l, c_ping, .{ .slice = PING[0..PING.len] }, Client, self, writeCallback);
            }
        }

        // Read again
        return .rearm;
    }

    fn shutdownCallback(
        self_: ?*Client,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: xev.TCP,
        r: xev.ShutdownError!void,
    ) xev.CallbackAction {
        _ = r catch {};

        const self = self_.?;
        socket.close(l, c, Client, self, closeCallback);
        return .disarm;
    }

    fn closeCallback(
        self_: ?*Client,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: xev.TCP,
        r: xev.CloseError!void,
    ) xev.CallbackAction {
        _ = l;
        _ = socket;
        _ = r catch unreachable;

        const self = self_.?;
        self.stop = true;
        self.completion_pool.destroy(c);
        return .disarm;
    }
};

/// The server state
const Server = struct {
    loop: *xev.Loop,
    buffer_pool: BufferPool,
    completion_pool: CompletionPool,
    socket_pool: TCPPool,
    stop: bool,

    pub fn init(alloc: Allocator, loop: *xev.Loop) !Server {
        return .{
            .loop = loop,
            .buffer_pool = BufferPool.init(alloc),
            .completion_pool = CompletionPool.init(alloc),
            .socket_pool = TCPPool.init(alloc),
            .stop = false,
        };
    }

    pub fn deinit(self: *Server) void {
        self.buffer_pool.deinit();
        self.completion_pool.deinit();
        self.socket_pool.deinit();
    }

    /// Must be called with stable self pointer.
    pub fn start(self: *Server) !void {
        const addr = try std.net.Address.parseIp4("127.0.0.1", 3131);
        var socket = try xev.TCP.init(addr);

        const c = try self.completion_pool.create();
        try socket.bind(addr);
        try socket.listen(std.os.linux.SOMAXCONN);
        socket.accept(self.loop, c, Server, self, acceptCallback);
    }

    pub fn threadMain(self: *Server) !void {
        try self.loop.run(.until_done);
    }

    fn destroyBuf(self: *Server, buf: []const u8) void {
        self.buffer_pool.destroy(
            @alignCast(
                @as(*[4096]u8, @ptrFromInt(@intFromPtr(buf.ptr))),
            ),
        );
    }

    fn acceptCallback(
        self_: ?*Server,
        l: *xev.Loop,
        c: *xev.Completion,
        r: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        const self = self_.?;

        // Create our socket
        const socket = self.socket_pool.create() catch unreachable;
        socket.* = r catch unreachable;

        // Start reading -- we can reuse c here because its done.
        const buf = self.buffer_pool.create() catch unreachable;
        socket.read(l, c, .{ .slice = buf }, Server, self, readCallback);
        return .disarm;
    }

    fn readCallback(
        self_: ?*Server,
        loop: *xev.Loop,
        c: *xev.Completion,
        socket: xev.TCP,
        buf: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = self_.?;
        const n = r catch |err| switch (err) {
            error.EOF => {
                self.destroyBuf(buf.slice);
                socket.shutdown(loop, c, Server, self, shutdownCallback);
                return .disarm;
            },

            else => {
                self.destroyBuf(buf.slice);
                self.completion_pool.destroy(c);
                std.log.warn("server read unexpected err={}", .{err});
                return .disarm;
            },
        };

        // Echo it back
        const c_echo = self.completion_pool.create() catch unreachable;
        const buf_write = self.buffer_pool.create() catch unreachable;
        @memcpy(buf_write, buf.slice[0..n]);
        socket.write(loop, c_echo, .{ .slice = buf_write[0..n] }, Server, self, writeCallback);

        // Read again
        return .rearm;
    }

    fn writeCallback(
        self_: ?*Server,
        l: *xev.Loop,
        c: *xev.Completion,
        s: xev.TCP,
        buf: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        _ = l;
        _ = s;
        _ = r catch unreachable;

        // We do nothing for write, just put back objects into the pool.
        const self = self_.?;
        self.completion_pool.destroy(c);
        self.buffer_pool.destroy(
            @alignCast(
                @as(*[4096]u8, @ptrFromInt(@intFromPtr(buf.slice.ptr))),
            ),
        );
        return .disarm;
    }

    fn shutdownCallback(
        self_: ?*Server,
        l: *xev.Loop,
        c: *xev.Completion,
        s: xev.TCP,
        r: xev.ShutdownError!void,
    ) xev.CallbackAction {
        _ = r catch {};

        const self = self_.?;
        s.close(l, c, Server, self, closeCallback);
        return .disarm;
    }

    fn closeCallback(
        self_: ?*Server,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: xev.TCP,
        r: xev.CloseError!void,
    ) xev.CallbackAction {
        _ = l;
        _ = r catch unreachable;
        _ = socket;

        const self = self_.?;
        self.stop = true;
        self.completion_pool.destroy(c);
        return .disarm;
    }
};
