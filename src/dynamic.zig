const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const AllBackend = @import("main.zig").Backend;
const looppkg = @import("loop.zig");

/// Creates the Xev API based on a set of backend types that allows
/// for dynamic choice between the various candidate backends (assuming
/// they're available). For example, on Linux, this allows a consumer to
/// choose between io_uring and epoll, or for automatic fallback to epoll
/// to occur.
///
/// If only one backend is given, the returned type is equivalent to
/// the static API with no runtime conditional logic, so there is no downside
/// to always using the dynamic choice variant if you wish to support
/// dynamic choice.
///
/// The goal of this API is to match the static Xev() (in main.zig)
/// API as closely as possible. It can't be exact since this is an abstraction
/// and therefore must be limited to the least common denominator of all
/// backends.
///
/// Since the static Xev API exposes types that can be initialized on their
/// own (i.e. xev.Async.init()), this API does the same. Since we need to
/// know the backend to use, this uses a global variable. The backend to use
/// defaults to the first candidate backend and DOES NOT test that it is
/// available. The API user should call `detect()` to set the backend to
/// the first available backend.
///
/// Additionally, a caller can manually set the backend to use, but this
/// must be done before initializing any other types.
pub fn Xev(comptime bes: []const AllBackend) type {
    if (bes.len == 0) @compileError("no backends provided");

    // Ensure that if we only have one candidate that we have no
    // overhead to use the dynamic API.
    if (bes.len == 1) return bes[0].Api();

    return struct {
        const Dynamic = @This();

        pub const candidates = bes;

        /// Backend becomes the subset of the full xev.Backend that
        /// is available to this dynamic API.
        pub const Backend = EnumSubset(AllBackend, bes);

        /// The shared structures
        pub const Options = looppkg.Options;
        pub const RunMode = looppkg.RunMode;
        pub const CallbackAction = looppkg.CallbackAction;
        pub const CompletionState = looppkg.CompletionState;
        pub const Completion = DynamicCompletion(Dynamic);

        /// Error types
        pub const AcceptError = ErrorSet(bes, &.{"AcceptError"});
        pub const CancelError = ErrorSet(bes, &.{"CancelError"});
        pub const CloseError = ErrorSet(bes, &.{"CloseError"});
        pub const ConnectError = ErrorSet(bes, &.{"ConnectError"});
        pub const ShutdownError = ErrorSet(bes, &.{"ShutdownError"});
        pub const WriteError = ErrorSet(bes, &.{"WriteError"});
        pub const ReadError = ErrorSet(bes, &.{"ReadError"});

        /// Core types
        pub const Async = DynamicAsync(Dynamic);
        pub const Process = DynamicProcess(Dynamic);
        pub const Timer = DynamicTimer(Dynamic);

        /// The backend that is in use.
        var backend: Backend = subset(bes[bes.len - 1]);

        /// Detect the preferred backend based on the system and set it
        /// for use. "Preferred" is the first available (API exists) candidate
        /// backend in the list.
        pub fn detect() error{NoAvailableBackends}!void {
            inline for (bes) |be| {
                if (be.Api().available()) {
                    backend = subset(be);
                    return;
                }
            }

            return error.NoAvailableBackends;
        }

        const LoopUnion = Union(bes, "Loop", false);
        pub const Loop = struct {
            backend: LoopUnion,

            pub fn init(opts: Options) !Loop {
                return .{ .backend = switch (backend) {
                    inline else => |tag| backend: {
                        const api = (comptime superset(tag)).Api();
                        break :backend @unionInit(
                            LoopUnion,
                            @tagName(tag),
                            try api.Loop.init(opts),
                        );
                    },
                } };
            }

            pub fn deinit(self: *Loop) void {
                switch (backend) {
                    inline else => |tag| @field(
                        self.backend,
                        @tagName(tag),
                    ).deinit(),
                }
            }

            pub fn stop(self: *Loop) void {
                switch (backend) {
                    inline else => |tag| @field(
                        self.backend,
                        @tagName(tag),
                    ).stop(),
                }
            }

            pub fn run(self: *Loop, mode: RunMode) !void {
                switch (backend) {
                    inline else => |tag| try @field(
                        self.backend,
                        @tagName(tag),
                    ).run(mode),
                }
            }
        };

        /// Helpers to convert between the subset/superset of backends.
        fn subset(comptime be: AllBackend) Backend {
            return @enumFromInt(@intFromEnum(be));
        }

        fn superset(comptime be: Backend) AllBackend {
            return @enumFromInt(@intFromEnum(be));
        }

        test {
            _ = Async;
            _ = Process;
            _ = Timer;
        }

        test "detect" {
            const testing = std.testing;
            try detect();
            inline for (bes) |be| {
                if (@intFromEnum(be) == @intFromEnum(backend)) {
                    try testing.expect(be.Api().available());
                    break;
                }
            } else try testing.expect(false);
        }

        test "loop basics" {
            try detect();
            var l = try Loop.init(.{});
            defer l.deinit();
            try l.run(.until_done);
            l.stop();
        }
    };
}

fn DynamicCompletion(comptime dynamic: type) type {
    return struct {
        const Self = @This();

        // Completions, unlike almost any other dynamic type in this
        // file, are tagged unions. This adds a minimal overhead to
        // the completion but is necessary to ensure that we have
        // zero-initialized the correct type for where it matters
        // (timers).
        const CompletionUnion = Union(
            dynamic.candidates,
            "Completion",
            true,
        );

        value: CompletionUnion = @unionInit(
            CompletionUnion,
            @tagName(dynamic.candidates[dynamic.candidates.len - 1]),
            .{},
        ),

        pub fn init() Self {
            return .{ .value = switch (dynamic.backend) {
                inline else => |tag| value: {
                    const api = (comptime dynamic.superset(tag)).Api();
                    break :value @unionInit(
                        CompletionUnion,
                        @tagName(tag),
                        api.Completion.init(),
                    );
                },
            } };
        }

        pub fn state(self: *Self) dynamic.CompletionState {
            return switch (self.value) {
                inline else => |*v| v.state(),
            };
        }

        /// This ensures that the tag is currently set for this
        /// completion. If it is not, it will be set to the given
        /// tag with a zero-initialized value.
        ///
        /// This lets users zero-intialize the completion and then
        /// call any watcher API on it without having to worry about
        /// the correct detected backend tag being set.
        fn ensureTag(self: *Self, comptime tag: dynamic.Backend) void {
            if (self.value == tag) return;
            self.value = @unionInit(
                CompletionUnion,
                @tagName(tag),
                .{},
            );
        }
    };
}

fn DynamicAsync(comptime dynamic: type) type {
    return struct {
        const Self = @This();

        backend: AsyncUnion,

        const AsyncUnion = Union(dynamic.candidates, "Async", false);

        pub const WaitError = ErrorSet(
            dynamic.candidates,
            &.{ "Async", "WaitError" },
        );

        pub fn init() !Self {
            return .{ .backend = switch (dynamic.backend) {
                inline else => |tag| backend: {
                    const api = (comptime dynamic.superset(tag)).Api();
                    break :backend @unionInit(
                        AsyncUnion,
                        @tagName(tag),
                        try api.Async.init(),
                    );
                },
            } };
        }

        pub fn deinit(self: *Self) void {
            switch (dynamic.backend) {
                inline else => |tag| @field(
                    self.backend,
                    @tagName(tag),
                ).deinit(),
            }
        }

        pub fn notify(self: *Self) !void {
            switch (dynamic.backend) {
                inline else => |tag| try @field(
                    self.backend,
                    @tagName(tag),
                ).notify(),
            }
        }

        pub fn wait(
            self: Self,
            loop: *dynamic.Loop,
            c: *dynamic.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *dynamic.Loop,
                c: *dynamic.Completion,
                r: WaitError!void,
            ) dynamic.CallbackAction,
        ) void {
            switch (dynamic.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime dynamic.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.Async.WaitError!void,
                        ) dynamic.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *dynamic.LoopUnion,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *dynamic.Completion.CompletionUnion,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).wait(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = @import("watcher/async.zig").AsyncTests(
                dynamic,
                Self,
            );
        }
    };
}

fn DynamicProcess(comptime dynamic: type) type {
    return struct {
        const Self = @This();

        backend: ProcessUnion,

        const ProcessUnion = Union(dynamic.candidates, "Process", false);

        pub const WaitError = ErrorSet(
            dynamic.candidates,
            &.{ "Process", "WaitError" },
        );

        pub fn init(fd: posix.pid_t) !Self {
            return .{ .backend = switch (dynamic.backend) {
                inline else => |tag| backend: {
                    const api = (comptime dynamic.superset(tag)).Api();
                    break :backend @unionInit(
                        ProcessUnion,
                        @tagName(tag),
                        try api.Process.init(fd),
                    );
                },
            } };
        }

        pub fn deinit(self: *Self) void {
            switch (dynamic.backend) {
                inline else => |tag| @field(
                    self.backend,
                    @tagName(tag),
                ).deinit(),
            }
        }

        pub fn wait(
            self: Self,
            loop: *dynamic.Loop,
            c: *dynamic.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *dynamic.Loop,
                c: *dynamic.Completion,
                r: WaitError!u32,
            ) dynamic.CallbackAction,
        ) void {
            switch (dynamic.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime dynamic.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.Process.WaitError!u32,
                        ) dynamic.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *dynamic.LoopUnion,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *dynamic.Completion.CompletionUnion,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).wait(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = @import("watcher/process.zig").ProcessTests(
                dynamic,
                Self,
                &.{ "sh", "-c", "exit 0" },
                &.{ "sh", "-c", "exit 42" },
            );
        }
    };
}

fn DynamicTimer(comptime dynamic: type) type {
    return struct {
        const Self = @This();

        backend: TimerUnion,

        const TimerUnion = Union(dynamic.candidates, "Timer", false);

        pub const RunError = ErrorSet(dynamic.candidates, &.{ "Timer", "RunError" });
        pub const CancelError = ErrorSet(dynamic.candidates, &.{ "Timer", "CancelError" });

        pub fn init() !Self {
            return .{ .backend = switch (dynamic.backend) {
                inline else => |tag| backend: {
                    const api = (comptime dynamic.superset(tag)).Api();
                    break :backend @unionInit(
                        TimerUnion,
                        @tagName(tag),
                        try api.Timer.init(),
                    );
                },
            } };
        }

        pub fn deinit(self: *Self) void {
            switch (dynamic.backend) {
                inline else => |tag| @field(
                    self.backend,
                    @tagName(tag),
                ).deinit(),
            }
        }

        pub fn run(
            self: Self,
            loop: *dynamic.Loop,
            c: *dynamic.Completion,
            next_ms: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *dynamic.Loop,
                c: *dynamic.Completion,
                r: RunError!void,
            ) dynamic.CallbackAction,
        ) void {
            switch (dynamic.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime dynamic.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.Timer.RunError!void,
                        ) dynamic.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *dynamic.LoopUnion,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *dynamic.Completion.CompletionUnion,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).run(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        next_ms,
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        pub fn reset(
            self: Self,
            loop: *dynamic.Loop,
            c: *dynamic.Completion,
            c_cancel: *dynamic.Completion,
            next_ms: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *dynamic.Loop,
                c: *dynamic.Completion,
                r: RunError!void,
            ) dynamic.CallbackAction,
        ) void {
            switch (dynamic.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);
                    c_cancel.ensureTag(tag);

                    const api = (comptime dynamic.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.Timer.RunError!void,
                        ) dynamic.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *dynamic.LoopUnion,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *dynamic.Completion.CompletionUnion,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).reset(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        &@field(c_cancel.value, @tagName(tag)),
                        next_ms,
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        pub fn cancel(
            self: Self,
            loop: *dynamic.Loop,
            c_timer: *dynamic.Completion,
            c_cancel: *dynamic.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *dynamic.Loop,
                c: *dynamic.Completion,
                r: CancelError!void,
            ) dynamic.CallbackAction,
        ) void {
            switch (dynamic.backend) {
                inline else => |tag| {
                    c_timer.ensureTag(tag);
                    c_cancel.ensureTag(tag);

                    const api = (comptime dynamic.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.Timer.CancelError!void,
                        ) dynamic.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *dynamic.LoopUnion,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *dynamic.Completion.CompletionUnion,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).cancel(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c_timer.value, @tagName(tag)),
                        &@field(c_cancel.value, @tagName(tag)),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = @import("watcher/timer.zig").TimerTests(
                dynamic,
                Self,
            );
        }
    };
}

/// Create an exhaustive enum that is a subset of another enum.
/// Preserves the same backing type and integer values for the
/// subset making it easy to convert between the two.
fn EnumSubset(comptime T: type, comptime values: []const T) type {
    var fields: [values.len]std.builtin.Type.EnumField = undefined;
    for (values, 0..) |value, i| fields[i] = .{
        .name = @tagName(value),
        .value = @intFromEnum(value),
    };

    return @Type(.{ .Enum = .{
        .tag_type = @typeInfo(T).Enum.tag_type,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
}

/// Creates a union type that can hold the implementation of a given
/// backend by common field name. Example, for Async: Union(bes, "Async")
/// produces:
///
///   union {
///     io_uring: IO_Uring.Async,
///     epoll: Epoll.Async,
///     ...
///   }
///
/// The union is untagged to save an extra bit of memory per
/// instance since we have the active backend from the outer struct.
fn Union(
    comptime bes: []const AllBackend,
    comptime field: []const u8,
    comptime tagged: bool,
) type {
    var fields: [bes.len]std.builtin.Type.UnionField = undefined;
    for (bes, 0..) |be, i| {
        const T = @field(be.Api(), field);
        fields[i] = .{
            .name = @tagName(be),
            .type = T,
            .alignment = @alignOf(T),
        };
    }

    return @Type(.{
        .Union = .{
            .layout = .auto,
            .tag_type = if (tagged) EnumSubset(
                AllBackend,
                bes,
            ) else null,
            .fields = &fields,
            .decls = &.{},
        },
    });
}

/// Create a new error set from a list of error sets within
/// the given backends at the given field name. For example,
/// to merge all xev.Async.WaitErrors:
///
///   ErrorSet(bes, &.{"Async", "WaitError"});
///
fn ErrorSet(
    comptime bes: []const AllBackend,
    comptime field: []const []const u8,
) type {
    var Set: type = error{};
    for (bes) |be| {
        var NextSet: type = be.Api();
        for (field) |f| NextSet = @field(NextSet, f);
        Set = Set || NextSet;
    }

    return Set;
}
