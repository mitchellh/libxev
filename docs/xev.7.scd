xev(7) "github.com/mitchellh/libxev" "Miscellaneous Information Manual"

# NAME

libxev - high-performance, cross-platform event loop

# DESCRIPTION

*libxev* is a high-performance, cross-platform event loop. libxev provides a
unified event loop abstraction for non-blocking IO, timers, signals, events,
and more that works on macOS, Windows, Linux, and WebAssembly (browser and WASI).
It is written in Zig but exports a C-compatible API (which makes it compatible
with any language out there that can communicate with C APIs).

This manual will focus on general libxev concepts. For details specific
to the C API see xev-c(7) and for details specific to the Zig API see
xev-zig(7).

# FEATURES

*Cross-platform.* Linux (io_uring(7) and epoll(7)), macOS (kqueue(2)),
WebAssembly + WASI (poll_oneoff(2), threaded and non-threaded runtimes).
(Windows support is planned and coming soon)

*Proactor API.* Work is submitted to the libxev event loop and the caller
is notified of work _completion_, as opposed to work _readiness_.

*Zero runtime allocations.* This helps make runtime performance more
predictable and makes libxev well suited for embedded environments.

*Timers, TCP, UDP.* High-level platform-agnostic APIs for interacting
with timers, TCP/UDP sockets, and more.

*Generic Thread Pool (Optional).* You can create a generic thread pool,
configure its resource utilization, and use this to perform custom background
tasks. The thread pool is used by some backends to do non-blocking tasks that
don't have reliable non-blocking APIs (such as local file operations with
kqueue(7)). The thread pool can be shared across multiple threads and event
loops to optimize resource utilization.

*Low-level and High-Level API.* The high-level API is platform-agnostic
but has some  opinionated behavior and limited flexibility. The high-level
API is recommended but the low-level API is always an available escape hatch.
The low-level API is platform-specific and provides a mechanism for libxev
users to squeeze out maximum performance. The low-level API is _just enough
abstraction_ above the OS interface to make it easier to use without
sacrificing noticable performance.

*Tree Shaking (Zig).* This is a feature of Zig, but substantially benefits
libraries such as libxev. Zig will only include function calls and features
that you actually use. If you don't use a particular kind of high-level
watcher (such as UDP sockets), then the functionality related to that
abstraction is not compiled into your final binary at all. This lets libxev
support optional "nice-to-have" functionality that may be considered
"bloat" in some cases, but the end user doesn't have to pay for it.

*Dependency-free.* libxev has no dependencies other than the built-in
OS APIs at runtime. The C library depends on libc. This makes it very
easy to cross-compile.

# EVENT LOOP PROGRAMMING

Event loop programming is a programming design pattern where a program
registers multiple events and is notified when those events occur.
Concretely, event loop programming is typically used as a foundational
component of asynchronous programs. It is the core mechanism used to
for asynchronous network IO, disk IO, timers, signals, and more.

There are two popular event loop styles: _proactor_ and _reactor_.
The reactor pattern notifies the event loop user of task _readiness_,
whereas the proactor pattern notifies the event loop user of task _completion_.
Examples of reactor APIs: POSIX poll(2), BSD kqueue(2). Examples of proactor
APIs: Linux io_uring(7), Windows IOCP, and JavaScript IO callbacks.
*libxev is a proactor event loop.*

# LIBXEV GENERAL CONCEPTS

## TERMINOLOGY

- *Loop*: An instance of an event loop.

- *Completion*: A request to perform some work. A completion is _queued_
  in an event loop, and an associated callback is invoked when the work
  is completed.

- *Watcher*: A slightly higher level abstraction to make it easier to
  work with common capabilities in a cross-platform way. For example,
  files, sockets, async/notify patterns, etc. These are just opinionated
  logic and sugar on top of completions.

- *Disarm/Rearm*: A completion that is actively being worked on by the
  event loop is considered _armed_. When a completion is complete, the
  program can choose to _disarm_ or _rearm_ the completion. If a completion
  is disarmed, it is no longer in use. If a completion is rearmed, it will
  repeat its work and fire the associated callback again.

## MEMORY ALLOCATION

libxev doesn't do any runtime memory allocation. The caller is expected
to allocate memory and provide libxev with pointers. The caller is then
free to allocate on the stack or heap in the way that is best suited for
their program and lifecycle.

The lifecycles of various resources in libxev are documented in their
resource-specific documentation sections. libxev _never_ takes ownership
of a programmer-provided memory location.

## LOOPS

The `xev.Loop` (Zig) and `xev_loop` (C) types represent a single event
loop. A program may have multiple event loops, but most typically there
is at most one per thread. If you are just getting started, just use a
single event loop per thread until you're more comfortable with the API.

Completions are _added_ to the event loop. Completions are explained
in more detail in the next section but at a high level represent a request
to perform some work. The event loop does NOT begin performing any work
until the loop is run. This is important, so to repeat it in another way:
an _added_ completion does nothing until the next time a loop is run.

An event loop is _run_ with `loop.run` (Zig) or xev_loop_run(3) (C).
The first thing the event loop does is _submit_ any _added_ completions.
Submitted completions begin their requested work in the background. If a
completion doesn't complete and the loop run returns (such as with a "no wait"
run mode -- covered later), the work will continue in the background and
may be checked for completion with another loop tick.

A loop can be run in multiple _run modes_:

- *No Wait.* This runs through the loop without blocking on any completions.
  If a completion is ready, the callbacks will be fired, but otherwise
  the loop will return.

- *Once.* This runs the loop and waits for at least one completion to become
  ready before returning.

- *Until Done.* This runs the loop and waits until there are no more
  completions in the event loop. This can potentially run forever as
  completion callbacks rearm or register new completions. This is the
  most common run mode and is usually used to start up the "main" loop
  of a program. The loop can be stopped from the main thread using the
  `stop` API call.

An event loop has to be allocated to a stable memory address (stable
pointer) _once you have called `run`_ once. Prior to calling run, you
can copy the loop value. However, once the loop has run any times
(even a no wait run once), the loop pointer must remain stable.

## COMPLETIONS

The `xev.Completion` (Zig) and `xev_completion` (C) types represent a
single request to do some work, such as read or write a file, accept
a network connection, sleep on a timer, etc.

Completions do nothing until they are _added_ to an event loop (and
even then, do nothing until the next event loop tick). Completions must
only be added to one event loop at a time. After a completion is dead
(see states below), it can be used with another event loop or the memory
can be reclaimed.

Completions have multiple states that are managed by libxev:

- *Dead.* The completion can be configured for new work and added to
  an event loop. The completion is not actively being used by the loop
  so you can also free memory associated with it. This is its initial state.

- *Added.* The completion is queued to be submitted to an event loop.
  The completion must no longer be modified.

- *Active.* The completion is submitted as part of an event loop and actively
  performing some work. The completion must no longer be modified.

The memory associated with a completion is always owned by the program
author. libxev never takes ownership of memory and never dynamically
allocates or free memory on its own. The memory associated with a completion
cannot be freed unless the the completion is dead.

A completion is dead only in the following scenarios:

- The completion has never been added to an event loop.

- The completion callback has been fired and the callback return action
  was "disarm." The completion memory is safe to free _during the callback_,
  in this case, too.

- The event loop that a completion was added to has been deinitialized.
  Even if the completion never fired, all system resources registered by
  libxev for the completion are no longer in use.

## CALLBACKS

When the work associated with a completion has been completed, libxev
will invoke the registered callback. At a low-level, all callbacks have
the same function signature. The Zig signature is shown below.

```
pub const xev.Callback = *const fn (
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction;
```

*NOTE:* The "low-level" word above is important. In general, program authors
will be using the _high-level_ APIs which have varied and more
programmer-friendly callback signatures depending on the feature. For example,
TCP connection accept will provide the new connection in the callback.
Underneath these abstractions, however, this regular completion callback
signature is used.

Every callback gets access to some optional programmer-provided userdata,
the loop where the completion was added, the completion itself, and a
result union.
The result of the callback is the action to take and is either "disarm"
or "rearm" (covered in TERMINOLOGY above).

Some callback tips for common behaviors:

- You can reuse the completion for a different operation now as long as
  you return the disarm action. For example, after a TCP connection callback,
  you can reuse the same completion now to begin writing data. The "loop"
  parameter is specifically provided to make this easy.

- You can free the memory associated with a completion from the callback
  if you no longer intend to use it. In fact, its unsafe to free memory
  for an active completion except after the callback is fired (or the
  event loop is deinitialized).

# EXAMPLE (C)

The example below shows how the C API can be used to initialize an event
loop and run a 5 second timer. To learn more about the C API, see
xev-c(7).

```
#include <stddef.h>
#include <stdio.h>
#include <xev.h>

xev_cb_action timerCallback(xev_loop* loop, xev_completion* c, int result, void *userdata) {
    return XEV_DISARM;
}

int main(void) {
    // Initialize the loop state. Notice we can use a stack-allocated
    // value here. We can even pass around the loop by value! The loop
    // will contain all of our "completions" (watches).
    xev_loop loop;
    if (xev_loop_init(&loop, 128) != 0) {
        printf("xev_loop_init failure\n");
        return 1;
    }

    // Initialize a completion and a watcher. A completion is the actual
    // thing a loop does for us, and a watcher is a high-level structure
    // to help make it easier to use completions.
    xev_completion c;
    xev_watcher w;

    // In this case, we initialize a timer watcher.
    if (xev_timer_init(&w) != 0) {
        printf("xev_timer_init failure\n");
        return 1;
    }

    // Configure the timer to run in 5s. This requires the completion that
    // we actually configure to become a timer, and the loop that the
    // completion should be registered with.
    xev_timer_run(&w, &loop, &c, 5000, NULL, &timerCallback);

    // Run the loop until there are no more completions.
    xev_loop_run(&loop, XEV_RUN_UNTIL_DONE);

    xev_timer_deinit(&w);
    xev_loop_deinit(&loop);
    return 0;
}
```

# EXAMPLE (ZIG)

The example below shows how the Zig API can be used to initialize an event
loop and run a 5 second timer. To learn more about the Zig API, see
xev-zig(7).

```
const xev = @import("xev");

pub fn main() !void {
    // Initialize the loop state. Notice we can use a stack-allocated
    // value here. We can even pass around the loop by value! The loop
    // will contain all of our "completions" (watches).
    var loop = try xev.Loop.init(.{ .entries = 128 });
    defer loop.deinit();

    // Initialize a completion and a watcher. A completion is the actual
    // thing a loop does for us, and a watcher is a high-level structure
    // to help make it easier to use completions.
    var c: xev.Completion = undefined;

    // In this case, we initialize a timer watcher.
    const w = try xev.Timer.init();
    defer w.deinit();

    // Configure the timer to run in 5s. This requires the completion that
    // we actually configure to become a timer, and the loop that the
    // completion should be registered with.
    w.run(&loop, &c, 5000, void, null, &timerCallback);

    // Run the loop until there are no more completions.
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

# SEE ALSO

xev-c(7), xev-zig(7)

<https://github.com/mitchellh/libxev>

# AUTHORS

Mitchell Hashimoto (xmitchx@gmail.com) and any open source contributors.
See <https://github.com/mitchellh/libxev>.
