xev_threadpool(3) "github.com/mitchellh/libxev" "Library Functions Manual"

# NAME

xev_threadpool - generic thread pool for scheduling work

# LIBRARY

libxev (_-lxev_)

# SYNOPSIS

```
#include <xev.h>;

xev_threadpool pool;
```

# DESCRIPTION

*xev_threadpool* is a generic thread pool that is lock-free, allocation-free
(except spawning threads), supports batch scheduling, dynamically spawns
threads, and handles thread spawn failure. It can be used to queue work that
should be executed on other threads as resources permit.

This man page focuses on the C API for the thread pool. The Zig API
can be discovered by reading the `src/ThreadPool.zig` file. This page will
provide a broad overview of using the thread pool API but won't cover
specific details such as an exhaustive list of error return codes.

There are multiple types that are important when working with thread pools.

- *xev_threadpool* is the pool itself.
- *xev_threadpool_config* is used to configure a new pool.
- *xev_threadpool_task* is a single task to execute.
- *xev_threadpool_batch* is a batch of zero or more tasks.

All the types are expected to be allocated by the program author. They
can be allocated on the stack or heap, but their pointer lifetimes must
remain valid as documented throughout this manual.

# POOL CREATION AND MANAGEMENT

To start, a pool must be initialized. The easiest way to initialize a pool
is with xev_threadpool_init(3) and no configuration. The default configuration
will choose reasonable defaults.

```
xev_threadpool pool;
assert(xev_threadpool_init(&pool, null));
```

The pool is now ready to have task batches scheduled to it. To shutdown
a pool, you must call xev_shutdown(3) and xev_deinit(3).

```
xev_shutdown(&pool);
xev_deinit(&pool);
```

The xev_shutdown(3) call notifies all threads that the pool is in a shutdown
state. They complete their most recent tasks, shut down, and accept no new
work. This function returns _immediately_. The xev_deinit(3) call waits for
all the threads in the pool to exit, then cleans up any additional state.
xev_deinit(3) and xev_shutdown(3) can be called in any order.

The xev_threadpool(3) value must be pointer-stable until after
xev_deinit(3) returns. After this point, no other xev_threadpool API
calls can be called using the pointer. You may reinitialize and reuse the
value.

# TASK SCHEDULING

A task is a single unit of work. A task is inserted into a _batch_.
A batch is scheduled with a _pool_. The first step is to define a task:

```
void do_expensive_work(xev_threadpool_task* t) {}

xev_threadpool_task t;
xev_threadpool_task_init(&t, &do_expensive_work);
```

The task then must be added to a batch. The code below creates a batch
with a single item "t". You can use xev_threadpool_batch_push_batch(3) to merge
multiple batches.

```
xev_threadpool_batch b;
xev_threadpool_batch_init(&b);
xev_threadpool_batch_push_task(&b, &t);
```

Finally, the batch must be scheduled with the pool with
xev_threadpool_schedule(3):

```
xev_threadpool_schedule(&pool, &b);
```

The scheduled work can be picked up immediately. The work is executed
on a separate thread so if resources are available, the work may begin
immediately. Otherwise, it is queued for execution later.

You can call xev_threadpool_schedule(3) from multiple threads against
the same pool to schedule work concurrently. You MUST NOT read or write
batches concurrently; for concurrent scheduling each thread should build
up its own batch.

## MEMORY LIFETIMES

- The task "t" must be pointer-stable until the task has completed execution.

- The task "t" can only be scheduled in one pool exactly one time until
  it has completed execution. You CAN NOT initialize a task and add it to
  multiple batches.

- The batch "b" can be copied and doesn't need to be pointer-stable. The
  batch can be freed at anytime.

## TASK STATE

The callback type only gives access to the `xev_threadpool_task` pointer.
To associate state or userdata with a task, make the task a member of
a struct and use the `container_of` macro (shown below) to access the
parent container.

An example is shown below:

```
typedef struct {
  xev_threadpool_task task;
  bool state;

  // other state can be here, too.
} work_t;


#define container_of(ptr, type, member) \
  ((type *) ((char *) (ptr) - offsetof(type, member)))

void do_expensive_work(xev_threadpool_task* t) {
  work_t *work = container_of(t, work_t, task);
  work->state = true;
}

work_t work;
xev_threadpool_task_init(&work.task, &do_expensive_work);
```

*IMPORTANT:* The `xev_threadpool_task` must be aligned to a power-of-2
memory address. When using it in a struct, be careful that it is properly
aligned.

# SEE ALSO

xev(7), xev-c(7)

<https://zig.news/kprotty/resource-efficient-thread-pools-with-zig-3291>

<https://github.com/mitchellh/libxev>

# AUTHORS

King Protty (https://github.com/kprotty) is the author of the thread pool.
Mitchell Hashimoto (xmitchx@gmail.com) is the author of the C API and
documentation. Plus any open source contributors. See <https://github.com/mitchellh/libxev>.
