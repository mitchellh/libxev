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

libxev does not have an equivalent explicit state, because it is typically
trivial to track this state manually in your program if it is important
to you. The design reasons for this are (1) because it aligns with libxev's
ethos of program author provided memory -- watchers such as TCP, UDP, etc.
are not required to be pointer-stable like they are in libuv or libev
and (2) we don't want the [admittedly trivial] state tracking overhead if
the program author doesn't care about it.

If knowing active state is important to you, we recommend tracking it
manually: when you start an operation with a completion, set some flag
to true to note it is active. When a callback is called, set some flag
to false to note it is no longer active (if the completion is being
disarmed).

# SUGGEST A TOPIC

There is still a lot of improvement to be made to the documentation. Please
suggest any topics to cover at <https://github.com/mitchellh/libxev>.

# SEE ALSO

xev(7)

<https://github.com/mitchellh/libxev>

# AUTHORS

Mitchell Hashimoto (xmitchx@gmail.com) and any open source contributors.
See <https://github.com/mitchellh/libxev>.
