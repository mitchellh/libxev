xev_completion_state(3) "github.com/mitchellh/libxev" "Library Functions Manual"

# NAME

xev_completion_state - check the state of a completion

# LIBRARY

libxev (_-lxev_)

# SYNOPSIS

```
#include <xev.h>;

xev_completion_state_t state = xev_completion_state(&c);
```

# DESCRIPTION

*xev_completion_state* returns the current state of a completion: dead
if the completion is not currently used or active if the completion is
part of an event loop.

The state is sometimes useful to determine if an operation has already
started or not. For example, the completion state can be used to check if
a timer is running or not.

The completion must be initialized if there is any chance the program author
may call this function prior to the completion being used. To initialize
a completion use xev_completion_zero(3).

This function can only be called from the main thread.

# RETURN VALUES

The return value is always a valid xev_completion_state_t enum value.

# SEE ALSO

xev_completion_state(3), xev(7), xev-c(7)

<https://github.com/mitchellh/libxev>

# AUTHORS

Mitchell Hashimoto (xmitchx@gmail.com) and any open source contributors.
See <https://github.com/mitchellh/libxev>.
