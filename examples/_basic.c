#include <stddef.h>
#include <stdio.h>
#include <xev.h>

xev_cb_action timerCallback(
    xev_loop* loop,
    xev_completion* c,
    int result,
    void *userdata
) {
    return XEV_DISARM;
}

int main(void) {
    xev_loop loop;
    if (xev_loop_init(&loop, 128) != 0) {
        printf("xev_loop_init failure\n");
        return 1;
    }

    xev_completion c;
    xev_watcher w;
    if (xev_timer_init(&w) != 0) {
        printf("xev_timer_init failure\n");
        return 1;
    }

    xev_timer_run(&w, &loop, &c, 1, NULL, &timerCallback);
    xev_loop_run(&loop, XEV_RUN_UNTIL_DONE);

    xev_timer_deinit(&w);
    xev_loop_deinit(&loop);
    return 0;
}
