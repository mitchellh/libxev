#include <stddef.h>
#include <stdio.h>
#include <xev.h>

xev_cb_action timerCallback(xev_loop* loop, xev_completion* c, int result, void *userdata) {
    return XEV_DISARM;
}

int main(void) {
    // Initialize the loop state. Notice we can use a stack-allocated
    // value here. We can even pass around the loop by value! The loop
    // will contain all of our "completions" (watches).
    xev_loop loop;
    if (xev_loop_init(&loop) != 0) {
        printf("xev_loop_init failure\n");
        return 1;
    }

    // Initialize a completion and a watcher. A completion is the actual
    // thing a loop does for us, and a watcher is a high-level structure
    // to help make it easier to use completions.
    xev_completion c;
    xev_watcher w;

    // In this case, we initialize a timer watcher.
    if (xev_timer_init(&w) != 0) {
        printf("xev_timer_init failure\n");
        return 1;
    }

    // Configure the timer to run in 1ms. This requires the completion that
    // we actually configure to become a timer, and the loop that the
    // completion should be registered with.
    xev_timer_run(&w, &loop, &c, 1, NULL, &timerCallback);

    // Run the loop until there are no more completions.
    xev_loop_run(&loop, XEV_RUN_UNTIL_DONE);

    xev_timer_deinit(&w);
    xev_loop_deinit(&loop);
    return 0;
}
