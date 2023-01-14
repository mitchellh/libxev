# libxev

libxev is a cross-platform event loop. libxev provides a unified event loop
abstraction for non-blocking IO, timers, signals, events, and more that
works on macOS, Windows, Linux, and WebAssembly (browser and WASI). It is
written in Zig but exports a C-compatible API (which further makes it
compatible with any language out there that can communicate with C APIs).

The libxev API is built around the [proactor pattern](https://en.wikipedia.org/wiki/Proactor_pattern):
work is submitted to the libxev event loop, and libxev notifies the caller
via callbacks when the work is _completed_.

An appropriate OS API is chosen at compile-time for the desired target
platform. For example, Linux will typically use `io_uring`, macOS will use
`kqueue`, and Windows will use IOCP (and others), browser WebAssembly defers
to the browser event loop, WASI etc.

The libxev API performs zero dynamic allocations. This helps make the
runtime predictable and also makes libxev well-suited for embedded environments.
