#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <xev.h>

#define UNUSED(v) ((void)v);

xev_cb_action timer_callback(xev_loop* loop, xev_completion* c, int result, void *userdata) {
    UNUSED(loop); UNUSED(c); UNUSED(result);

    // Send the notification to our async which will wake up the loop and
    // call the waiter callback.
    xev_async_notify((xev_watcher *)userdata);
    return XEV_DISARM;
}

xev_cb_action async_callback(xev_loop* loop, xev_completion* c, int result, void *userdata) {
    UNUSED(loop); UNUSED(c); UNUSED(result);

    bool *notified = (bool *)userdata;
    *notified = true;
    return XEV_DISARM;
}

int main(void) {
    xev_loop loop;
    if (xev_loop_init(&loop) != 0) {
        printf("xev_loop_init failure\n");
        return 1;
    }

    // Initialize an async watcher. An async watcher can be used to wake up
    // the event loop from any thread.
    xev_completion async_c;
    xev_watcher async;
    if (xev_async_init(&async) != 0)  {
        printf("xev_async_init failure\n");
        return 1;
    }

    // We start a "waiter" for the async watcher. Only one waiter can
    // ever be set at a time. This callback will be called when the async
    // is notified (via xev_async_notify).
    bool notified = false;
    xev_async_wait(&async, &loop, &async_c, &notified, &async_callback);

    // Initialize a timer. The timer will fire our async.
    xev_completion timer_c;
    xev_watcher timer;
    if (xev_timer_init(&timer) != 0) {
        printf("xev_timer_init failure\n");
        return 1;
    }
    xev_timer_run(&timer, &loop, &timer_c, 1, &async, &timer_callback);

    // Run the loop until there are no more completions. This means
    // that both the async watcher AND the timer have to complete.
    // Notice that if you comment out `xev_async_notify` in the timer
    // callback this blocks forever (because the async watcher is waiting).
    xev_loop_run(&loop, XEV_RUN_UNTIL_DONE);

    if (!notified) {
        printf("FAIL! async should've been notified!");
        return 1;
    }

    xev_timer_deinit(&timer);
    xev_async_deinit(&async);
    xev_loop_deinit(&loop);
    return 0;
}
