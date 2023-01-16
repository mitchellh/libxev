#include <stddef.h>
#include <stdio.h>
#include <xev.h>

int main(void) {
    xev_loop loop;
    if (xev_loop_init(&loop, 128) != 0) {
        printf("xev_loop_init failure\n");
        return 1;
    }

    xev_loop_deinit(&loop);
    return 0;
}
