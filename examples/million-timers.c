// C version of the million-timers benchmark.
#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <xev.h>

#define NUM_TIMERS (10 * 1000 * 1000)

static int timer_cb_called;

xev_cb_action timer_cb(xev_loop* loop, xev_completion* c, int result, void *userdata) {
    timer_cb_called++;
    return XEV_DISARM;
}

uint64_t hrtime(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_nsec + (ts.tv_sec * 1e9);
}

int main(void) {
  xev_watcher* timers;
  xev_completion* completions;
  xev_loop loop;
  uint64_t before_all;
  uint64_t before_run;
  uint64_t after_run;
  uint64_t after_all;
  int timeout;
  int i;

  timers = malloc(NUM_TIMERS * sizeof(timers[0]));
  completions = malloc(NUM_TIMERS * sizeof(completions[0]));
  assert(timers != NULL);

  assert(xev_loop_init(&loop, 4096) == 0);
  timeout = 0;

  before_all = hrtime();
  for (i = 0; i < NUM_TIMERS; i++) {
    if (i % 1000 == 0) timeout++;
    xev_timer_init(timers + i);
    xev_timer_run(timers + i, &loop, completions + i, timeout, NULL, &timer_cb);
  }

  before_run = hrtime();
  //xev_loop_run(&loop, XEV_RUN_UNTIL_DONE);
  after_run = hrtime();
  after_all = hrtime();

  //assert(timer_cb_called == NUM_TIMERS);
  free(timers);
  free(completions);

  fprintf(stderr, "%.2f seconds total\n", (after_all - before_all) / 1e9);
  fprintf(stderr, "%.2f seconds init\n", (before_run - before_all) / 1e9);
  fprintf(stderr, "%.2f seconds dispatch\n", (after_run - before_run) / 1e9);
  fprintf(stderr, "%.2f seconds cleanup\n", (after_all - after_run) / 1e9);
  fflush(stderr);
  return 0;
}
