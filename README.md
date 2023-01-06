# xev

xev is a cross-platform event loop. xev provides a unified event loop
abstraction for non-blocking IO, timers, signals, events, and more that
works on macOS, Windows, Linux, and WebAssembly (browser and WASI).

The xev API is built around the [proactor pattern](https://en.wikipedia.org/wiki/Proactor_pattern).
An appropriate OS API is chosen at compile-time for the desired target
platform. For example, Linux will typically use `io_uring`, macOS will use
`kqueue`, and Windows will use IOCP (and others), browser WebAssembly defers
to the browser event loop, etc.
