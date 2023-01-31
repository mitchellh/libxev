xev_completion_zero(3) "github.com/mitchellh/libxev" "Library Functions Manual"

# NAME

xev_completion_zero - set a completion to the zero value

# LIBRARY

libxev (_-lxev_)

# SYNOPSIS

```
#include <xev.h>;

xev_completion_zero(&c);
```

# DESCRIPTION

*xev_completion_zero* sets default values for the given completion, rather
than uninitialized memory state. This is particularly useful if you're using
xev_completion_state(3). Otherwise, it isn't necessary.

_You typically do NOT need to call this!_ You are allowed to pass uninitialized
completions to almost all functions that start an operation. However, you
_do need to call this_ if you are inspecting completion state (i.e.
xev_completion_state(3)) before the completion is started.

You do NOT need to call this after you are done using a completion. Once
a completion has been used, the value of the completion is always initialized.
The ONLY time you need to call this is if you're inspecting completion state
prior to the completion ever being used.

# SEE ALSO

xev_completion_state(3), xev(7), xev-c(7)

<https://github.com/mitchellh/libxev>

# AUTHORS

Mitchell Hashimoto (xmitchx@gmail.com) and any open source contributors.
See <https://github.com/mitchellh/libxev>.
