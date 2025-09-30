# libxev

libxev is a cross-platform event loop. libxev provides a unified event loop
abstraction for non-blocking IO, timers, signals, events, and more that
works on macOS, Windows, Linux, and WebAssembly (browser and WASI). It is
written in [Zig](https://ziglang.org/) but exports a C-compatible API (which
further makes it compatible with any language out there that can communicate
with C APIs).

**Project Status: Stable for most use cases.** libxev is in daily use by
large projects such as [Ghostty](https://ghostty.org),
[zml](https://github.com/zml/zml), and more. For most use cases, libxev
has been shown to be stable at scale. libxev has a broad featureset and
there are likely less well-used corners of the library, but for most
use cases libxev is already heavily used in production environments.

**Why a new event loop library?** A few reasons. One, I think Zig lacks
a generalized event loop comparable to libuv in features ("generalized"
being a key word here). Two, I wanted to build a library like this around
the design patterns of [io_uring](https://unixism.net/loti/what_is_io_uring.html),
even mimicking its style on top of other OS primitives (
[credit to this awesome blog post](https://tigerbeetle.com/blog/a-friendly-abstraction-over-iouring-and-kqueue/)).
Three, I wanted an event loop library that could build to WebAssembly
(both WASI and freestanding) and that didn't really fit well
into the goals of API style of existing libraries without bringing in
something super heavy like Emscripten. The motivation for this library
primarily though is scratching my own itch!

## Features

**Cross-platform.** Linux (`io_uring` and `epoll`), macOS (`kqueue`),
WebAssembly + WASI (`poll_oneoff`, threaded and non-threaded runtimes).
(Windows support is planned and coming soon)

**[Proactor API](https://en.wikipedia.org/wiki/Proactor_pattern).** Work
is submitted to the libxev event loop and the caller is notified of
work _completion_, as opposed to work _readiness_.

**Zero runtime allocations.** This helps make runtime performance more
predictable and makes libxev well suited for embedded environments.

**Timers, TCP, UDP, Files, Processes.** High-level platform-agnostic APIs for
interacting with timers, TCP/UDP sockets, files, processes, and more. For
platforms that don't support async IO, the file operations are automatically
scheduled to a thread pool.

**Generic Thread Pool (Optional).** You can create a generic thread pool,
configure its resource utilization, and use this to perform custom background
tasks. The thread pool is used by some backends to do non-blocking tasks that
don't have reliable non-blocking APIs (such as local file operations with
`kqueue`). The thread pool can be shared across multiple threads and event
loops to optimize resource utilization.

**Low-level and High-Level API.** The high-level API is platform-agnostic
but has some  opinionated behavior and limited flexibility. The high-level
API is recommended but the low-level API is always an available escape hatch.
The low-level API is platform-specific and provides a mechanism for libxev
users to squeeze out maximum performance. The low-level API is _just enough
abstraction_ above the OS interface to make it easier to use without
sacrificing noticable performance.

**Tree Shaking (Zig).** This is a feature of Zig, but substantially benefits
libraries such as libxev. Zig will only include function calls and features
that you actually use. If you don't use a particular kind of high-level
watcher (such as UDP sockets), then the functionality related to that
abstraction is not compiled into your final binary at all. This lets libxev
support optional "nice-to-have" functionality that may be considered
"bloat" in some cases, but the end user doesn't have to pay for it.

**Dependency-free.** libxev has no dependencies other than the built-in
OS APIs at runtime. The C library depends on libc. This makes it very
easy to cross-compile.

### Roadmap

There are plenty of missing features that I still want to add:

* Pipe high-level API
* Signal handlers
* Filesystem events
* Windows backend
* Freestanding WebAssembly support via an external event loop (i.e. the browser)

And more...

### Performance

There is plenty of room for performance improvements, and I want to be
fully clear that I haven't done a lot of optimization work. Still,
performance is looking good. I've tried to port many of
[libuv benchmarks](https://github.com/libuv/libuv) to use the libxev
API.

I won't post specific benchmark results until I have a better
environment to run them in. As a _very broad generalization_,
you shouldn't notice a slowdown using libxev compared to other
major event loops. This may differ on a feature-by-feature basis, and
if you can show really poor performance in an issue I'm interested
in resolving it!

## Example

The example below shows an identical program written in Zig and in C
that uses libxev to run a single 5s timer. This is almost silly how
simple it is but is meant to just convey the overall feel of the library
rather than a practical use case.

<table>
<tr>
<td> Zig </td> <td> C </td>
</tr>
<tr>
<td>

```zig
const xev = @import("xev");

pub fn main() !void {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const w = try xev.Timer.init();
    defer w.deinit();

    // 5s timer
    var c: xev.Completion = undefined;
    w.run(&loop, &c, 5000, void, null, &timerCallback);

    try loop.run(.until_done);
}

fn timerCallback(
    userdata: ?*void,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
   _ = userdata;
   _ = loop;
   _ = c;
   _ = result catch unreachable;
   return .disarm;
}
```

</td>
<td>

```c
#include <stddef.h>
#include <stdio.h>
#include <xev.h>

xev_cb_action timerCallback(xev_loop* loop, xev_completion* c, int result, void *userdata) {
    return XEV_DISARM;
}

int main(void) {
    xev_loop loop;
    if (xev_loop_init(&loop) != 0) {
        printf("xev_loop_init failure\n");
        return 1;
    }

    xev_watcher w;
    if (xev_timer_init(&w) != 0) {
        printf("xev_timer_init failure\n");
        return 1;
    }

    xev_completion c;
    xev_timer_run(&w, &loop, &c, 5000, NULL, &timerCallback);

    xev_loop_run(&loop, XEV_RUN_UNTIL_DONE);

    xev_timer_deinit(&w);
    xev_loop_deinit(&loop);
    return 0;
}
```

</td>
</tr>
</table>

## Installation (Zig)

**These instructions are for Zig downstream users only.** If you are
using the C API to libxev, see the "Build" section.

This package works with the Zig package manager introduced in Zig 0.11.
Create a `build.zig.zon` file like this:

```zig
.{
    .name = "my-project",
    .version = "0.0.0",
    .dependencies = .{
        .libxev = .{
            .url = "https://github.com/mitchellh/libxev/archive/<git-ref-here>.tar.gz",
            .hash = "12208070233b17de6be05e32af096a6760682b48598323234824def41789e993432c",
        },
    },
}
```

And in your `build.zig`:

```zig
const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });
exe.addModule("xev", xev.module("xev"));
```

## Documentation

🚧 Documentation is a work-in-progress. 🚧

Currently, documentation is available in three forms: **man pages**,
**examples**, and **code comments.** In the future, I plan on writing detailed
guides and API documentation in website form, but that isn't currently
available.

### Man Pages

The man pages are relatively detailed! `xev(7)` will
give you a good overview of the entire library. `xev-zig(7)` and
`xev-c(7)` will provide overviews of the Zig and C API, respectively.
From there, API-specifc man pages such as `xev_loop_init(3)` are
available. This is the best documentation currently.

There are multiple ways to browse the man pages. The most immediately friendly
is to just browse the raw man page sources in the `docs/` directory in
your web browser. The man page source is a _markdown-like_ syntax so it
renders _okay_ in your browser via GitHub.

Another approach is to run `zig build -Dman-pages` and the man pages
will be available in `zig-out`. This requires
[scdoc](https://git.sr.ht/~sircmpwn/scdoc)
to be installed (this is available in most package managers).
Once you've built the man pages, you can render them by path:

```
man zig-out/share/man/man7/xev.7
```

And the final approach is to install libxev via your favorite package
manager (if and when available), which should hopefully put your man pages
into your man path, so you can just do `man 7 xev`.

### Examples

There are examples available in the `examples/` folder. The examples are
available in both C and Zig, and you can tell which one is which using
the file extension.

To build an example, use the following:

```
$ zig build -Dexample-name=_basic.zig
...
$ zig-out/bin/example-basic
...
```

The `-Dexample-name` value should be the filename including the extension.

### Code Comments

The Zig code is well commented. If you're comfortable reading code comments
you can find a lot of insight within them. The source is in the `src/`
directory.

# Build

Build requires the installation of the Zig 0.15.1. libxev follows stable
Zig releases and generally does not support nightly builds. When a stable
release is imminent we may have a branch that supports it.
**libxev has no other build dependencies.**

Once installed, `zig build install` on its own will build the full library and output
a [FHS-compatible](https://en.wikipedia.org/wiki/Filesystem_Hierarchy_Standard)
directory in `zig-out`. You can customize the output directory with the
`--prefix` flag.

## Tests

libxev has a large and growing test suite. To run the tests for the current
platform:

```sh
$ zig build test
...
```

This will run all the tests for all the supported features for the current
host platform. For example, on Linux this will run both the full io_uring
and epoll test suite.

**You can build and run tests for other platforms** by cross-compiling the
 test executable, copying it to a target machine and executing it. For example,
 the below shows how to cross-compile and build the tests for macOS from Linux:

 ```sh
 $ zig build -Dtarget=aarch64-macos -Dinstall-tests
 ...

 $ file zig-out/bin/xev-test
 zig-out/bin/xev-test: Mach-O 64-bit arm64 executable
 ```

 **WASI is a special-case.** You can run tests for WASI if you have
 [wasmtime](https://wasmtime.dev/) installed:

 ```
 $ zig build test -Dtarget=wasm32-wasi -Dwasmtime
 ...
 ```
