/*
** lev_threadpool.h
** Cross-platform thread pool for async work delegation
**
** This thread pool allows Lus to perform blocking operations (file I/O, etc.)
** asynchronously by delegating work to worker threads. Since Lus is GIL'ed
** (global interpreter lock), worker threads must NOT access lua_State.
**
** Usage:
**   1. Create a ThreadPoolTask with your work function
**   2. Submit with threadpool_submit()
**   3. Yield the coroutine with YIELD_THREADPOOL
**   4. scheduler_poll() will resume when task completes
*/

#ifndef lev_threadpool_h
#define lev_threadpool_h

#include "../llimits.h"

/* Forward declaration */
typedef struct ThreadPoolTask ThreadPoolTask;

/*
** Work function executed in worker thread.
** IMPORTANT: Must not access lua_State or any Lua API.
** Only perform I/O operations and set result/error.
*/
typedef void (*ThreadPoolWorkFn)(ThreadPoolTask *task);

/*
** Thread pool task structure.
** Allocated by caller, freed after completion callback.
*/
struct ThreadPoolTask {
  ThreadPoolWorkFn work;       /* Function to execute in worker thread */
  void *userdata;              /* Task-specific input data */
  void *result;                /* Result data (set by work function) */
  char *error;                 /* Error message if failed (malloc'd) */
  volatile int done;           /* Set to 1 when work completes */
  struct ThreadPoolTask *next; /* Internal: linked list */
};

/* Thread pool instance (opaque) */
typedef struct ThreadPool ThreadPool;

/*
** Initialize thread pool with specified number of worker threads.
** Returns NULL on failure.
*/
LUAI_FUNC ThreadPool *threadpool_create(int num_threads);

/*
** Shutdown thread pool, waiting for pending tasks to complete.
*/
LUAI_FUNC void threadpool_destroy(ThreadPool *pool);

/*
** Submit a task to the thread pool.
** Task must remain valid until completed.
*/
LUAI_FUNC void threadpool_submit(ThreadPool *pool, ThreadPoolTask *task);

/*
** Poll for completed tasks (non-blocking).
** Returns number of completed tasks filled into 'completed' array.
*/
LUAI_FUNC int threadpool_poll(ThreadPool *pool, ThreadPoolTask **completed,
                              int max);

/*
** Get a file descriptor that becomes readable when tasks complete.
** Used to integrate with event loop (epoll/kqueue/select).
** Returns -1 if not supported on this platform.
*/
LUAI_FUNC int threadpool_get_notify_fd(ThreadPool *pool);

#endif /* lev_threadpool_h */
