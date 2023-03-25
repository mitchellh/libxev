#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <xev.h>

// We create a job struct that can contain additional state that we use
// for our threadpool tasks. In this case, we only have a boolean to note
// we're done but you can imagine any sort of user data here!
typedef struct {
    xev_threadpool_task pool_task;

    bool done;
} job_t;

// We use the container_of trick to access our job_t from a threadpool task.
// See task_callback.
#define container_of(ptr, type, member) \
  ((type *) ((char *) (ptr) - offsetof(type, member)))

// This is the callback that is invoked when the task is being worked on.
void task_callback(xev_threadpool_task* t) {
    job_t *job = container_of(t, job_t, pool_task);
    job->done = true;
}

int main(void) {
    xev_threadpool pool;
    if (xev_threadpool_init(&pool, NULL) != 0) {
        printf("xev_threadpool_init failure\n");
        return 1;
    }

    // A "batch" is used to group together multiple tasks that we schedule
    // atomically into the thread pool. We initialize an empty batch that
    // we'll add our tasks to.
    xev_threadpool_batch batch;
    xev_threadpool_batch_init(&batch);

    // Create all our tasks we want to submit. The number here can be changed
    // to anything!
    const int TASK_COUNT = 128;
    job_t jobs[TASK_COUNT];
    for (int i = 0; i < TASK_COUNT; i++) {
        jobs[i].done = false;
        xev_threadpool_task_init(&jobs[i].pool_task, &task_callback);
        xev_threadpool_batch_push_task(&batch, &jobs[i].pool_task);
    }

    // Schedule our batch. This will immediately queue and start the tasks
    // if there are available threads. This will also automatically start
    // threads as needed. After this, you can reclaim the memory associated
    // with "batch".
    xev_threadpool_schedule(&pool, &batch);

    // We need a way to detect that our work is done. Normally here you'd
    // use some sort of waitgroup or signal the libxev loop or something.
    // Since this example is showing ONLY the threadpool, we just do a
    // somewhat unsafe thing and just race on done booleans...
    while (true) {
        bool done = true;
        for (int i = 0; i < TASK_COUNT; i++) {
            if (!jobs[i].done) {
                done = false;
                break;
            }
        }
        if (done) break;
    }

    // Shutdown notifies the threadpool to notify the threads it has launched
    // to start shutting down. This MUST be called.
    xev_threadpool_shutdown(&pool);

    // Deinit reclaims memory.
    xev_threadpool_deinit(&pool);

    printf("%d tasks completed!\n", TASK_COUNT);
    return 0;
}
