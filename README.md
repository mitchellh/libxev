# libxev

libxev is a cross-platform event loop. libxev provides a unified event loop
abstraction for non-blocking IO, timers, signals, events, and more that
works on macOS, Windows, Linux, and WebAssembly (browser and WASI). It is
written in [Zig](https://ziglang.org/) but exports a C-compatible API (which
further makes it compatible with any language out there that can communicate
with C APIs).

## Features

**Cross-platform.** Linux (`io_uring` and `epoll`), WebAssembly + WASI
(`poll_oneoff`, threaded and non-threaded runtimes).

**[Proactor API](https://en.wikipedia.org/wiki/Proactor_pattern).** Work
is submitted to the libxev event loop and the caller is notified of
work _completion_, as opposed to work _readiness_.

**Zero runtime allocations.** This helps make runtime performance more
predictable and makes libxev well suited for embedded environments.

**Timers, TCP, UDP.** High-level platform-agnostic APIs for interacting
with timers, TCP/UDP sockets, and more.

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
