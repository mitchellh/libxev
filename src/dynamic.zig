const std = @import("std");
const builtin = @import("builtin");
const AllBackend = @import("main.zig").Backend;
const looppkg = @import("loop.zig");
const AsyncTests = @import("watcher/async.zig").AsyncTests;

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

        /// Backend becomes the subset of the full xev.Backend that
        /// is available to this dynamic API.
        pub const Backend = EnumSubset(AllBackend, bes);

        /// The shared structures
        pub const Options = looppkg.Options;
        pub const RunMode = looppkg.RunMode;
        pub const CallbackAction = looppkg.CallbackAction;
        pub const CompletionState = looppkg.CompletionState;
        pub const Completion = Union(bes, "Completion");

        /// Error types
        pub const AcceptError = ErrorSet(bes, &.{"AcceptError"});
        pub const CancelError = ErrorSet(bes, &.{"CancelError"});
        pub const CloseError = ErrorSet(bes, &.{"CloseError"});
        pub const ConnectError = ErrorSet(bes, &.{"ConnectError"});
        pub const ShutdownError = ErrorSet(bes, &.{"ShutdownError"});
        pub const WriteError = ErrorSet(bes, &.{"WriteError"});
        pub const ReadError = ErrorSet(bes, &.{"ReadError"});

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

        const LoopUnion = Union(bes, "Loop");
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

        const AsyncUnion = Union(bes, "Async");
        pub const Async = struct {
            backend: AsyncUnion,

            pub const WaitError = ErrorSet(
                bes,
                &.{ "Async", "WaitError" },
            );

            pub fn init() !Async {
                return .{ .backend = switch (backend) {
                    inline else => |tag| backend: {
                        const api = (comptime superset(tag)).Api();
                        break :backend @unionInit(
                            AsyncUnion,
                            @tagName(tag),
                            try api.Async.init(),
                        );
                    },
                } };
            }

            pub fn deinit(self: *Async) void {
                switch (backend) {
                    inline else => |tag| @field(
                        self.backend,
                        @tagName(tag),
                    ).deinit(),
                }
            }

            pub fn notify(self: *Async) !void {
                switch (backend) {
                    inline else => |tag| try @field(
                        self.backend,
                        @tagName(tag),
                    ).notify(),
                }
            }

            pub fn wait(
                self: Async,
                loop: *Loop,
                c: *Completion,
                comptime Userdata: type,
                userdata: ?*Userdata,
                comptime cb: *const fn (
                    ud: ?*Userdata,
                    l: *Loop,
                    c: *Completion,
                    r: WaitError!void,
                ) CallbackAction,
            ) void {
                switch (backend) {
                    inline else => |tag| {
                        const api = (comptime superset(tag)).Api();
                        const api_cb = (struct {
                            fn callback(
                                ud_inner: ?*Userdata,
                                l_inner: *api.Loop,
                                c_inner: *api.Completion,
                                r_inner: api.Async.WaitError!void,
                            ) CallbackAction {
                                return cb(
                                    ud_inner,
                                    @fieldParentPtr("backend", @as(
                                        *LoopUnion,
                                        @fieldParentPtr(@tagName(tag), l_inner),
                                    )),
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                    r_inner,
                                );
                            }
                        }).callback;

                        @field(
                            self.backend,
                            @tagName(tag),
                        ).wait(
                            &@field(loop.backend, @tagName(tag)),
                            &@field(c, @tagName(tag)),
                            Userdata,
                            userdata,
                            api_cb,
                        );
                    },
                }
            }

            test {
                _ = AsyncTests(Dynamic, Async);
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
            .tag_type = null,
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
