xev-zig(7) "github.com/mitchellh/libxev" "Miscellaneous Information Manual"

# NAME

libxev Zig API

# DESCRIPTION

See xev(7) for a general libxev overview. This man page will give a more
specific overview of the Zig API for libxev.

libxev is written in Zig and exports a native Zig API. The Zig API
takes advantage of first-class Zig concepts such as comptime parameters,
error sets, etc. in order to provide an idiomatic Zig experience. Beyond
basic idioms, these Zig features usually result in improved performance
over the C API. For example, all callbacks in the Zig API must be available
at comptime because the callback call is always inlined -- this results in
a noticable performance improvement over equivalent C consumption of libxev.

The primary Zig API is visible in `src/main.zig` in the libxev source. 

# INSTALLATION

libxev has no dependencies, making it easy to install into your Zig project
using any available Zig package manager or Git submodules. The `build.zig`
file exports a `module` constant that you can use with `addAnonymousModule`:

```
// build.zig

const libxev = @import("submodules/libxev/build.zig");

pub fn build(b: *std.build.Builder) !void {
    // Your other build options...

    my_exe.addAnonymousModule("xev", libxev.module);
}
```

The package is then available in your source code as "xev":

```
// Your main.zig

const xev = @import("xev");
```

# QUICK START

## INITIALIZING A LOOP

After importing xev, the first thing you'll need is an event loop:

```
var loop = try xev.Loop.init(.{});
defer loop.deinit(); // or wherever your cleanup is
```

This initializes the resources associated with an event loop. An event loop
_can be copied_ until the first `run` is called. Once `run` is called,
the loop *must be at a stable memory location* (pointer won't change).

## ADDING A COMPLETION

An empty event loop does nothing. You must add one or more _completions_
to request work to be done asynchronously. A completion is represented with
the `xev.Completion` structure. A completion *must have a stable memory
location when it is added to the loop* until the completion is finished.
xev(7) talks more about completion lifetimes and memory allocation requirements.

The example below adds a timer to the previously initialized event loop:

```
var c_timer: xev.Completion = undefined;
const timer = try xev.Timer.init();
timer.run(&loop, &c_timer, 5_000, void, null, timerCallback);
```

This uses the `xev.Timer` _high-level abstraction_. This is an abstraction
that provides a common API on top of multiple operating system async APIs.
You can also use the low-level API to manage completions with the loop directly,
but these are not portable.

**Important concept to notice:** The completion allocation is up to the
program author. It can be stack allocated (such as in this case) or heap
allocated. The pointer must remain stable until it is complete. This gives
program authors substantial power over optimizing the performance of libxev.
In fact, libxev doesn't perform _any_ dynamic memory allocation.

## RUNNING THE LOOP

An added completion is a request for future work. The work does not start
until the completion is submitted. A completion is submitted only during
an event loop tick. To tick the event loop, use the `run` method:

```
try loop.run(.until_done);
```

The enum value is an `xev.RunMode` described in xev(7). This call will run
until the loop has no more active completions (`until_done`). At
some point (in about 5 seconds), this will call the registered `timerCallback`.

# MEMORY ALLOCATIONS

You'll notice that none of the Zig APIs take an allocator as an argument.
libxev does not perform any dynamic memory allocations. All memory must be
provided by the caller. This section will outline specific memory management
rules you should be aware of when using libxev.

*xev.Loop.* This can be copied and moved until `submit`, `tick`, or `run`
is called. Once any of those loop functions are called, the loop memory
must remain at a stable address. It is not safe to copy, move, or reuse the
memory that loop is occupying until `deinit` completes.

*xev.Completion.* This can be copied and moved until the completion is
added to a loop. A completion is often added to a loop with any function
call on a high-level abstraction that takes a completion pointer as a function
argument such as `xev.Timer.run`. The completion memory can be reclaimed
only when the callback associated with it is fired or the loop is deinitialized.

# SUGGEST A TOPIC

There is still a lot of improvement to be made to the documentation. Please
suggest any topics to cover at <https://github.com/mitchellh/libxev>.

# SEE ALSO

xev(7)

<https://github.com/mitchellh/libxev>

# AUTHORS

Mitchell Hashimoto (xmitchx@gmail.com) and any open source contributors.
See <https://github.com/mitchellh/libxev>.
