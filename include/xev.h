#ifndef XEV_H
#define XEV_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/* TODO(mitchellh): we should use platform detection to set the correct
 * byte sizes here. We choose some overly large values for now so that
 * we can retain ABI compatibility. */
#define XEV_SIZEOF_LOOP 512
#define XEV_SIZEOF_COMPLETION 320
#define XEV_SIZEOF_WATCHER 256
#define XEV_SIZEOF_THREADPOOL 64
#define XEV_SIZEOF_THREADPOOL_BATCH 24
#define XEV_SIZEOF_THREADPOOL_TASK 24
#define XEV_SIZEOF_THREADPOOL_CONFIG 64

/* There's a ton of preprocessor directives missing here for real cross-platform
 * compatibility. I'm going to defer to the community or future issues to help
 * plug those holes. For now, we get some stuff working we can test! */

/* Opaque types. These types have a size defined so that they can be
 * statically allocated but they are not to be accessed. */
typedef struct { uint8_t data[XEV_SIZEOF_LOOP]; } xev_loop;
typedef struct { uint8_t data[XEV_SIZEOF_COMPLETION]; } xev_completion;
typedef struct { uint8_t data[XEV_SIZEOF_WATCHER]; } xev_watcher;
typedef struct { uint8_t data[XEV_SIZEOF_THREADPOOL]; } xev_threadpool;
typedef struct { uint8_t data[XEV_SIZEOF_THREADPOOL_BATCH]; } xev_threadpool_batch;
typedef struct { uint8_t data[XEV_SIZEOF_THREADPOOL_TASK]; } xev_threadpool_task;
typedef struct { uint8_t data[XEV_SIZEOF_THREADPOOL_CONFIG]; } xev_threadpool_config;

/* Callback types. */
typedef enum { XEV_DISARM = 0, XEV_REARM = 1 } xev_cb_action;
typedef void (*xev_task_cb)(xev_threadpool_task* t);
typedef xev_cb_action (*xev_timer_cb)(xev_loop* l, xev_completion* c, int result, void* userdata);
typedef xev_cb_action (*xev_async_cb)(xev_loop* l, xev_completion* c, int result, void* userdata);

typedef enum {
    XEV_RUN_NO_WAIT = 0,
    XEV_RUN_ONCE = 1,
    XEV_RUN_UNTIL_DONE = 2,
} xev_run_mode;

/* Documentation for functions can be found in man pages or online. I
 * purposely do not add docs to the header so that you can quickly scan
 * all exported functions. */
int xev_loop_init(xev_loop* loop);
void xev_loop_deinit(xev_loop* loop);
int xev_loop_run(xev_loop* loop, xev_run_mode mode);

void xev_threadpool_config_init(xev_threadpool_config* config);
void xev_threadpool_config_set_stack_size(xev_threadpool_config* config, uint32_t v);
void xev_threadpool_config_set_max_threads(xev_threadpool_config* config, uint32_t v);

int xev_threadpool_init(xev_threadpool* pool, xev_threadpool_config* config);
void xev_threadpool_deinit(xev_threadpool* pool);
void xev_threadpool_shutdown(xev_threadpool* pool);
void xev_threadpool_schedule(xev_threadpool* pool, xev_threadpool_batch *batch);

void xev_threadpool_task_init(xev_threadpool_task* t, xev_task_cb cb);
void xev_threadpool_batch_init(xev_threadpool_batch* b);
void xev_threadpool_batch_push_task(xev_threadpool_batch* b, xev_threadpool_task *t);
void xev_threadpool_batch_push_batch(xev_threadpool_batch* b, xev_threadpool_batch *other);

int xev_timer_init(xev_watcher *w);
void xev_timer_deinit(xev_watcher *w);
void xev_timer_run(xev_watcher *w, xev_loop* loop, xev_completion* c, uint64_t next_ms, void* userdata, xev_timer_cb cb);
void xev_timer_cancel(xev_watcher *w, xev_loop* loop, xev_completion* c, xev_completion* c_cancel, void* userdata, xev_timer_cb cb);

int xev_async_init(xev_watcher *w);
void xev_async_deinit(xev_watcher *w);
int xev_async_notify(xev_watcher *w);
void xev_async_wait(xev_watcher *w, xev_loop* loop, xev_completion* c, void* userdata, xev_async_cb cb);

#ifdef __cplusplus
}
#endif

#endif /* XEV_H */
