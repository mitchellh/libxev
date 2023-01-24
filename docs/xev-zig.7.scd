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
The main file uses a somewhat convoluted `usingnamespace` to setup the
API so it isn't immediately obvious, but the API is provided by the `Xev`
function. For example, available consts are: `xev.Loop`, `xev.Completion`,
etc.

# INSTALLATION

libxev has no dependencies, making it easy to install into your Zig project
using any available Zig package manager or Git submodules. The `build.zig`
file exports a `pkg` constant that you can use with `addPackage`:

```
// build.zig

const libxev = @import("submodules/libxev/build.zig");

pub fn build(b: *std.build.Builder) !void {
    // Your other build options...

    my_exe.addPackage(libxev.pkg);
}
```

The package is then available in your source code as "xev":

```
// Your main.zig

const xev = @import("xev");
```
