xev-faq(7) "github.com/mitchellh/libxev" "Miscellaneous Information Manual"

# NAME

libxev Frequently Asked Questions (FAQ)

# DESCRIPTION

This manual page contains frequently asked questions around the design
and usage of libxev. The goal of this page is to collect various tips or
varios common challenges people run into. The information in this page
may duplicate documentation that is available for a specific API or
concept.

# FAQ

## HOW CAN I CHECK IF A COMPLETION, TIMER, SOCKET, ETC. IS ACTIVE?

Some other event loops (libuv, libev) have a function that can check if
a given _thing_ (timer, socket, etc.) is "active." "Active" means that the
thing in question is part of an event loop and _running_ (the definition of
running is dependent on the type of the watcher).

For libxev, the correct question to ask is: is this _completion_ active?
A completion represents a single operation and can be used to determine
if a corresponding watcher is active if the complation was used with
the watcher.

Completion state can be checked using the `c.state()` function (Zig) or
the xev_completion_state(3) function (C). This will return an enum value
of "dead" or "alive". More enum values may be added in the future if
it is determined that finer grained state is useful.

# SUGGEST A TOPIC

There is still a lot of improvement to be made to the documentation. Please
suggest any topics to cover at <https://github.com/mitchellh/libxev>.

# SEE ALSO

xev(7)

<https://github.com/mitchellh/libxev>

# AUTHORS

Mitchell Hashimoto (xmitchx@gmail.com) and any open source contributors.
See <https://github.com/mitchellh/libxev>.
