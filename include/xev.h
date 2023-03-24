#ifndef XEV_H
#define XEV_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stddef.h>

/* TODO(mitchellh): we should use platform detection to set the correct
 * byte sizes here. We choose some overly large values for now so that
 * we can retain ABI compatibility. */
const size_t XEV_SIZEOF_LOOP = 512;
const size_t XEV_SIZEOF_COMPLETION = 320;
const size_t XEV_SIZEOF_WATCHER = 256;
const size_t XEV_SIZEOF_THREADPOOL = 64;
const size_t XEV_SIZEOF_THREADPOOL_BATCH = 24;
const size_t XEV_SIZEOF_THREADPOOL_TASK = 24;
const size_t XEV_SIZEOF_THREADPOOL_CONFIG = 64;

#if __STDC_VERSION__ >= 201112L || __cplusplus >= 201103L
typedef max_align_t XEV_ALIGN_T;
#else
// max_align_t is usually synonymous with the largest scalar type, which is long double on most platforms, and its alignment requirement is either 8 or 16. 
typedef long double XEV_ALIGN_T;
#endif

/* There's a ton of preprocessor directives missing here for real cross-platform
 * compatibility. I'm going to defer to the community or future issues to help
 * plug those holes. For now, we get some stuff working we can test! */

/* Opaque types. These types have a size defined so that they can be
 * statically allocated but they are not to be accessed. */
// todo: give struct individual alignment, instead of max alignment
typedef struct { XEV_ALIGN_T _pad; uint8_t data[XEV_SIZEOF_LOOP - sizeof(XEV_ALIGN_T)]; } xev_loop;
typedef struct { XEV_ALIGN_T _pad; uint8_t data[XEV_SIZEOF_COMPLETION - sizeof(XEV_ALIGN_T)]; } xev_completion;
typedef struct { XEV_ALIGN_T _pad; uint8_t data[XEV_SIZEOF_WATCHER - sizeof(XEV_ALIGN_T)]; } xev_watcher;
typedef struct { XEV_ALIGN_T _pad; uint8_t data[XEV_SIZEOF_THREADPOOL - sizeof(XEV_ALIGN_T)]; } xev_threadpool;
typedef struct { XEV_ALIGN_T _pad; uint8_t data[XEV_SIZEOF_THREADPOOL_BATCH - sizeof(XEV_ALIGN_T)]; } xev_threadpool_batch;
typedef struct { XEV_ALIGN_T _pad; uint8_t data[XEV_SIZEOF_THREADPOOL_TASK - sizeof(XEV_ALIGN_T)]; } xev_threadpool_task;
typedef struct { XEV_ALIGN_T _pad; uint8_t data[XEV_SIZEOF_THREADPOOL_CONFIG - sizeof(XEV_ALIGN_T)]; } xev_threadpool_config;

/* Callback types. */
typedef enum { XEV_DISARM = 0, XEV_REARM = 1 } xev_cb_action;
typedef void (*xev_task_cb)(xev_threadpool_task* t);
typedef xev_cb_action (*xev_timer_cb)(xev_loop* l, xev_completion* c, int result, void* userdata);
typedef xev_cb_action (*xev_async_cb)(xev_loop* l, xev_completion* c, int result, void* userdata);

typedef enum {
    XEV_RUN_NO_WAIT = 0,
    XEV_RUN_ONCE = 1,
    XEV_RUN_UNTIL_DONE = 2,
} xev_run_mode_t;

typedef enum {
    XEV_COMPLETION_DEAD = 0,
    XEV_COMPLETION_ACTIVE = 1,
} xev_completion_state_t;


/* Documentation for functions can be found in man pages or online. I
 * purposely do not add docs to the header so that you can quickly scan
 * all exported functions. */
int xev_loop_init(xev_loop* loop);
void xev_loop_deinit(xev_loop* loop);
int xev_loop_run(xev_loop* loop, xev_run_mode_t mode);
int64_t xev_loop_now(xev_loop* loop);
void xev_loop_update_now(xev_loop* loop);

void xev_completion_zero(xev_completion* c);
xev_completion_state_t xev_completion_state(xev_completion* c);

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
void xev_timer_reset(xev_watcher *w, xev_loop* loop, xev_completion* c, xev_completion *c_cancel, uint64_t next_ms, void* userdata, xev_timer_cb cb);
void xev_timer_cancel(xev_watcher *w, xev_loop* loop, xev_completion* c, xev_completion* c_cancel, void* userdata, xev_timer_cb cb);

int xev_async_init(xev_watcher *w);
void xev_async_deinit(xev_watcher *w);
int xev_async_notify(xev_watcher *w);
void xev_async_wait(xev_watcher *w, xev_loop* loop, xev_completion* c, void* userdata, xev_async_cb cb);

#ifdef __cplusplus
}
#endif

#endif /* XEV_H */
