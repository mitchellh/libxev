const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const xev = @import("xev");

pub const log_level: std.log.Level = .info;

pub fn main() !void {
    if (true) return;
    var loop = try xev.Loop.init(std.math.pow(u13, 2, 12));
    defer loop.deinit();

    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa: GPA = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var server_loop = try xev.Loop.init(std.math.pow(u13, 2, 12));
    defer server_loop.deinit();

    var server = try Server.init(alloc, &server_loop);
    defer server.deinit();
    try server.start();

    // Start our echo server
    const server_thr = try std.Thread.spawn(.{}, Server.threadMain, .{&server});

    // Start our client
    var client_loop = try xev.Loop.init(std.math.pow(u13, 2, 12));
    defer client_loop.deinit();

    var client = try Client.init(alloc, &client_loop);
    defer client.deinit();
    try client.start();

    const start_time = try Instant.now();
    try client_loop.run(.until_done);
    server_thr.join();
    const end_time = try Instant.now();

    const elapsed = @intToFloat(f64, end_time.since(start_time));
    std.log.info("{d:.2} roundtrips/s", .{@intToFloat(f64, client.pongs) / (elapsed / 1e9)});
    std.log.info("{d:.2} seconds total", .{elapsed / 1e9});
}

/// Memory pools for things that need stable pointers
const BufferPool = std.heap.MemoryPool([4096]u8);
const CompletionPool = std.heap.MemoryPool(xev.Completion);
const SocketPool = std.heap.MemoryPool(xev.Socket);

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
        const socket = try xev.Socket.init(addr);

        const c = try self.completion_pool.create();
        socket.connect(self.loop, c, self, connectCallback);
    }

    fn connectCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        _ = r.connect catch unreachable;

        const self = @ptrCast(*Client, @alignCast(@alignOf(Client), ud.?));

        // Send message
        const socket = xev.Socket.initFd(c.op.connect.socket);
        socket.write(self.loop, c, .{ .slice = PING[0..PING.len] }, self, writeCallback);

        // Read
        const c_read = self.completion_pool.create() catch unreachable;
        socket.read(self.loop, c_read, .{ .slice = &self.read_buf }, self, readCallback);
    }

    fn writeCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        _ = r;

        // Put back the completion.
        const self = @ptrCast(*Client, @alignCast(@alignOf(Client), ud.?));
        self.completion_pool.destroy(c);
    }

    fn readCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        const self = @ptrCast(*Client, @alignCast(@alignOf(Client), ud.?));

        const socket = xev.Socket.initFd(c.op.recv.fd);
        const buf = c.op.recv.buffer;
        const n = r.recv catch unreachable;
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
                    socket.shutdown(self.loop, c, self, shutdownCallback);
                    return;
                }

                // Send another ping
                const c_ping = self.completion_pool.create() catch unreachable;
                socket.write(self.loop, c_ping, .{ .slice = PING[0..PING.len] }, self, writeCallback);
            }
        }

        // Read again
        socket.read(self.loop, c, .{ .slice = buf.slice }, self, readCallback);
    }

    fn shutdownCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        _ = r.shutdown catch unreachable;

        const self = @ptrCast(*Client, @alignCast(@alignOf(Client), ud.?));
        const socket = xev.Socket.initFd(c.op.shutdown.socket);
        socket.close(self.loop, c, self, closeCallback);
    }

    fn closeCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        _ = r.close catch unreachable;

        const self = @ptrCast(*Client, @alignCast(@alignOf(Client), ud.?));
        self.stop = true;
        self.completion_pool.destroy(c);
    }
};

/// The server state
const Server = struct {
    loop: *xev.Loop,
    buffer_pool: BufferPool,
    completion_pool: CompletionPool,
    socket_pool: SocketPool,
    stop: bool,

    pub fn init(alloc: Allocator, loop: *xev.Loop) !Server {
        return .{
            .loop = loop,
            .buffer_pool = BufferPool.init(alloc),
            .completion_pool = CompletionPool.init(alloc),
            .socket_pool = SocketPool.init(alloc),
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
        const socket = try xev.Socket.init(addr);

        const c = try self.completion_pool.create();
        try socket.bind();
        try socket.listen(std.os.linux.SOMAXCONN);
        socket.accept(self.loop, c, self, acceptCallback);
    }

    pub fn threadMain(self: *Server) !void {
        try self.loop.run(.until_done);
    }

    fn destroyBuf(self: *Server, buf: []const u8) void {
        self.buffer_pool.destroy(
            @alignCast(
                BufferPool.item_alignment,
                @intToPtr(*[4096]u8, @ptrToInt(buf.ptr)),
            ),
        );
    }

    fn acceptCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        const self = @ptrCast(*Server, @alignCast(@alignOf(Server), ud.?));

        // Create our socket
        const socket = self.socket_pool.create() catch unreachable;
        socket.* = xev.Socket.initFd(r.accept catch unreachable);

        // Start reading -- we can reuse c here because its done.
        const buf = self.buffer_pool.create() catch unreachable;
        socket.read(self.loop, c, .{ .slice = buf }, self, readCallback);
    }

    fn readCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        const socket = xev.Socket.initFd(c.op.recv.fd);
        const buf = c.op.recv.buffer;

        const self = @ptrCast(*Server, @alignCast(@alignOf(Server), ud.?));
        const n = r.recv catch |err| switch (err) {
            error.EOF => {
                self.destroyBuf(buf.slice);
                socket.shutdown(self.loop, c, self, shutdownCallback);
                return;
            },

            error.Unexpected => {
                self.destroyBuf(buf.slice);
                self.completion_pool.destroy(c);
                std.log.warn("server read unexpected err={}", .{err});
                return;
            },
        };

        const data = buf.slice[0..n];

        // Echo it back
        const c_echo = self.completion_pool.create() catch unreachable;
        socket.write(self.loop, c_echo, .{ .slice = data }, self, writeCallback);

        // Read again
        const buf_read = self.buffer_pool.create() catch unreachable;
        socket.read(self.loop, c, .{ .slice = buf_read }, self, readCallback);
    }

    fn writeCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        _ = r.send catch unreachable;

        // We do nothing for write, just put back objects into the pool.
        const self = @ptrCast(*Server, @alignCast(@alignOf(Server), ud.?));
        const buf = c.op.send.buffer;
        self.completion_pool.destroy(c);
        self.buffer_pool.destroy(
            @alignCast(
                BufferPool.item_alignment,
                @intToPtr(*[4096]u8, @ptrToInt(buf.slice.ptr)),
            ),
        );
    }

    fn shutdownCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        _ = r.shutdown catch unreachable;

        const self = @ptrCast(*Server, @alignCast(@alignOf(Server), ud.?));
        const socket = xev.Socket.initFd(c.op.shutdown.socket);
        socket.close(self.loop, c, self, closeCallback);
    }

    fn closeCallback(ud: ?*anyopaque, c: *xev.Loop.Completion, r: xev.Loop.Result) void {
        _ = r.close catch unreachable;

        const self = @ptrCast(*Server, @alignCast(@alignOf(Server), ud.?));
        self.stop = true;
        self.completion_pool.destroy(c);
    }
};
