const dynamicpkg = @This();
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const main = @import("main.zig");
const AllBackend = main.Backend;
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

        /// This is a flag that can be used to detect that you're using
        /// a dynamic API and not the static API via `hasDecl`.
        pub const dynamic = true;

        pub const candidates = bes;

        /// Backend becomes the subset of the full xev.Backend that
        /// is available to this dynamic API.
        pub const Backend = EnumSubset(AllBackend, bes);

        /// Forward some global types so that users can replace
        /// @import("xev") with the dynamic package and everything
        /// works.
        pub const ThreadPool = main.ThreadPool;

        /// The shared structures
        pub const Options = looppkg.Options;
        pub const RunMode = looppkg.RunMode;
        pub const CallbackAction = looppkg.CallbackAction;
        pub const CompletionState = looppkg.CompletionState;
        pub const Completion = DynamicCompletion(Dynamic);
        pub const PollEvent = DynamicPollEvent(Dynamic);
        pub const ReadBuffer = DynamicReadBuffer(Dynamic);
        pub const WriteBuffer = DynamicWriteBuffer(Dynamic);
        pub const WriteQueue = DynamicWriteQueue(Dynamic);
        pub const WriteRequest = Dynamic.Union(&.{"WriteRequest"});

        /// Error types
        pub const AcceptError = Dynamic.ErrorSet(&.{"AcceptError"});
        pub const CancelError = Dynamic.ErrorSet(&.{"CancelError"});
        pub const CloseError = Dynamic.ErrorSet(&.{"CloseError"});
        pub const ConnectError = Dynamic.ErrorSet(&.{"ConnectError"});
        pub const PollError = Dynamic.ErrorSet(&.{"PollError"});
        pub const ShutdownError = Dynamic.ErrorSet(&.{"ShutdownError"});
        pub const WriteError = Dynamic.ErrorSet(&.{"WriteError"});
        pub const ReadError = Dynamic.ErrorSet(&.{"ReadError"});

        /// Core types
        pub const Async = @import("watcher/async.zig").Async(Dynamic);
        pub const File = @import("watcher/file.zig").File(Dynamic);
        pub const Process = @import("watcher/process.zig").Process(Dynamic);
        pub const Stream = @import("watcher/stream.zig").GenericStream(Dynamic);
        pub const Timer = @import("watcher/timer.zig").Timer(Dynamic);
        pub const TCP = @import("watcher/tcp.zig").TCP(Dynamic);
        pub const UDP = @import("watcher/udp.zig").UDP(Dynamic);

        /// The backend that is in use.
        pub var backend: Backend = subset(bes[bes.len - 1]);

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

        /// Manually set the backend to use, but if the backend is not
        /// available, this will not change the backend in use.
        pub fn prefer(be: AllBackend) bool {
            inline for (bes) |candidate| {
                if (candidate == be) {
                    const api = candidate.Api();
                    if (!api.available()) return false;
                    backend = subset(candidate);
                    return true;
                }
            }

            return false;
        }

        pub const Loop = struct {
            backend: Loop.Union,

            pub const Union = Dynamic.Union(&.{"Loop"});

            pub fn init(opts: Options) !Loop {
                return .{ .backend = switch (backend) {
                    inline else => |tag| backend: {
                        const api = (comptime superset(tag)).Api();
                        break :backend @unionInit(
                            Loop.Union,
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

            pub fn stopped(self: *Loop) bool {
                return switch (backend) {
                    inline else => |tag| @field(
                        self.backend,
                        @tagName(tag),
                    ).stopped(),
                };
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
        pub fn subset(comptime be: AllBackend) Backend {
            return @enumFromInt(@intFromEnum(be));
        }

        pub fn superset(comptime be: Backend) AllBackend {
            return @enumFromInt(@intFromEnum(be));
        }

        pub fn Union(comptime field: []const []const u8) type {
            return dynamicpkg.Union(bes, field, false);
        }

        pub fn TaggedUnion(comptime field: []const []const u8) type {
            return dynamicpkg.Union(bes, field, true);
        }

        pub fn ErrorSet(comptime field: []const []const u8) type {
            return dynamicpkg.ErrorSet(bes, field);
        }

        test {
            @import("std").testing.refAllDecls(@This());
        }

        test "completion is zero-able" {
            const c: Completion = .{};
            _ = c;
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

        test "prefer" {
            const testing = std.testing;
            try testing.expect(prefer(bes[0]));
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
            try std.testing.expect(l.stopped());
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
        pub const Union = dynamic.TaggedUnion(&.{"Completion"});

        value: Self.Union = @unionInit(
            Self.Union,
            @tagName(dynamic.candidates[dynamic.candidates.len - 1]),
            .{},
        ),

        pub fn init() Self {
            return .{ .value = switch (dynamic.backend) {
                inline else => |tag| value: {
                    const api = (comptime dynamic.superset(tag)).Api();
                    break :value @unionInit(
                        Self.Union,
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
        pub fn ensureTag(self: *Self, comptime tag: dynamic.Backend) void {
            if (self.value == tag) return;
            self.value = @unionInit(
                Self.Union,
                @tagName(tag),
                .{},
            );
        }
    };
}

fn DynamicReadBuffer(comptime dynamic: type) type {
    // Our read buffer supports a least common denominator of
    // read targets available by all backends. The direct backend
    // may support more read targets but if you need that you should
    // use the backend directly and not through the dynamic API.
    return union(enum) {
        const Self = @This();

        slice: []u8,
        array: [32]u8,

        /// Convert a backend-specific read buffer to this.
        pub fn fromBackend(
            comptime be: dynamic.Backend,
            buf: dynamic.superset(be).Api().ReadBuffer,
        ) Self {
            return switch (buf) {
                inline else => |data, tag| @unionInit(
                    Self,
                    @tagName(tag),
                    data,
                ),
            };
        }

        /// Convert this read buffer to the backend-specific
        /// buffer.
        pub fn toBackend(
            self: Self,
            comptime be: dynamic.Backend,
        ) dynamic.superset(be).Api().ReadBuffer {
            return switch (self) {
                inline else => |data, tag| @unionInit(
                    dynamic.superset(be).Api().ReadBuffer,
                    @tagName(tag),
                    data,
                ),
            };
        }
    };
}

fn DynamicWriteBuffer(comptime dynamic: type) type {
    // Our write buffer supports a least common denominator of
    // write targets available by all backends. The direct backend
    // may support more write targets but if you need that you should
    // use the backend directly and not through the dynamic API.
    return union(enum) {
        const Self = @This();

        slice: []const u8,
        array: struct { array: [32]u8, len: usize },

        /// Convert a backend-specific write buffer to this.
        pub fn fromBackend(
            comptime be: dynamic.Backend,
            buf: dynamic.superset(be).Api().WriteBuffer,
        ) Self {
            return switch (buf) {
                .slice => |v| .{ .slice = v },
                .array => |v| .{ .array = .{ .array = v.array, .len = v.len } },
            };
        }

        /// Convert this write buffer to the backend-specific
        /// buffer.
        pub fn toBackend(
            self: Self,
            comptime be: dynamic.Backend,
        ) dynamic.superset(be).Api().WriteBuffer {
            return switch (self) {
                .slice => |v| .{ .slice = v },
                .array => |v| .{ .array = .{ .array = v.array, .len = v.len } },
            };
        }
    };
}

fn DynamicWriteQueue(comptime xev: type) type {
    return struct {
        const Self = @This();
        pub const Union = xev.TaggedUnion(&.{"WriteQueue"});

        value: Self.Union = @unionInit(
            Self.Union,
            @tagName(xev.candidates[xev.candidates.len - 1]),
            .{},
        ),

        pub fn ensureTag(self: *Self, comptime tag: xev.Backend) void {
            if (self.value == tag) return;
            self.value = @unionInit(
                Self.Union,
                @tagName(tag),
                .{},
            );
        }
    };
}

fn DynamicPollEvent(comptime xev: type) type {
    return enum {
        const Self = @This();

        read,

        pub fn fromBackend(
            comptime tag: xev.Backend,
            event: xev.superset(tag).Api().PollEvent,
        ) Self {
            return switch (event) {
                inline else => |event_tag| @field(
                    Self,
                    @tagName(event_tag),
                ),
            };
        }

        pub fn toBackend(
            self: Self,
            comptime tag: xev.Backend,
        ) xev.superset(tag).Api().PollEvent {
            return switch (self) {
                inline else => |event_tag| @field(
                    (comptime xev.superset(tag)).Api().PollEvent,
                    @tagName(event_tag),
                ),
            };
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

    return @Type(.{ .@"enum" = .{
        .tag_type = @typeInfo(T).@"enum".tag_type,
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
    comptime field: []const []const u8,
    comptime tagged: bool,
) type {
    // Keep track of the largest field size, see the conditional
    // below using this variable for more info.
    var largest: usize = 0;

    var fields: [bes.len + 1]std.builtin.Type.UnionField = undefined;
    for (bes, 0..) |be, i| {
        var T: type = be.Api();
        for (field) |f| T = @field(T, f);
        largest = @max(largest, @sizeOf(T));
        fields[i] = .{
            .name = @tagName(be),
            .type = T,
            .alignment = @alignOf(T),
        };
    }

    // If our union only has zero-sized types, we need to add some
    // non-zero sized padding entry. This avoids a Zig 0.13 compiler
    // crash when trying to create a zero-sized union using @unionInit
    // from a switch of a comptime-generated enum. I wasn't able to
    // minimize this. In future Zig versions we can remove this and if
    // our examples can build with Dynamic then we're good.
    var count: usize = bes.len;
    if (largest == 0) {
        fields[count] = .{
            .name = "_zig_bug_padding",
            .type = u8,
            .alignment = @alignOf(u8),
        };
        count += 1;
    }

    return @Type(.{
        .@"union" = .{
            .layout = .auto,
            .tag_type = if (tagged) EnumSubset(
                AllBackend,
                bes,
            ) else null,
            .fields = fields[0..count],
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
