/*
** lev.h
** Event loop and scheduler for detached coroutines
*/

#ifndef lev_h
#define lev_h

#include "../llimits.h"
#include "../lua.h"

/* Event flags - prefixed to avoid conflicts with system headers */
#define EVLOOP_READ 1
#define EVLOOP_WRITE 2
#define EVLOOP_ERROR 4

/* Yield reasons for detached coroutines */
#define YIELD_NORMAL 0     /* Regular yield (return to caller) */
#define YIELD_IO 1         /* Waiting for I/O */
#define YIELD_SLEEP 2      /* Sleeping for duration */
#define YIELD_THREADPOOL 3 /* Waiting for thread pool task */

/* Event result (normalized across all backends) */
typedef struct {
  int fd;
  int events; /* EV_READ | EV_WRITE | EV_ERROR */
  void *data;
} EventResult;

/* Platform backend (opaque) */
typedef struct EventBackend EventBackend;

/* Backend operations interface */
typedef struct {
  EventBackend *(*create)(void);
  void (*destroy)(EventBackend *be);
  int (*add)(EventBackend *be, int fd, int events, void *data);
  int (*modify)(EventBackend *be, int fd, int events);
  int (*remove)(EventBackend *be, int fd);
  int (*wait)(EventBackend *be, EventResult *results, int max, int timeout_ms);
} BackendOps;

/* Get the platform-specific backend operations */
LUAI_FUNC const BackendOps *eventloop_get_backend(void);

/* Pending coroutine - waiting on I/O or timer */
typedef struct PendingCoroutine {
  lua_State *co;       /* The coroutine */
  int fd;              /* File descriptor (-1 for timers) */
  int events;          /* Events to wait for */
  lua_Number deadline; /* When to wake up (0 = no timeout) */
  struct PendingCoroutine *next;
} PendingCoroutine;

/* Maximum number of registered task handlers */
#define LUS_MAX_TASK_HANDLERS 32

/* Scheduler state (stored in global_State) */
typedef struct lus_Scheduler {
  EventBackend *backend;
  const BackendOps *ops;
  struct ThreadPool *threadpool; /* Thread pool for async work */
  PendingCoroutine *pending;     /* Linked list of pending coroutines */
  int pending_count;             /* Number of pending coroutines */
  char *pending_error;           /* Error to throw on next poll() */
  /* Task system */
  struct lus_TaskHandler_entry {
    int type;
    void *handler;
  } task_handlers[LUS_MAX_TASK_HANDLERS]; /* Registered task handlers */
  int task_handler_count;
  struct lus_Task *task_queue_head;
  struct lus_Task *task_queue_tail;
  int task_queue_count;
} lus_Scheduler;

/* Forward declaration for task system */
struct lus_Task;

/* Scheduler management */
LUAI_FUNC lus_Scheduler *scheduler_get(lua_State *L);
LUAI_FUNC void scheduler_init(lua_State *L);
LUAI_FUNC void scheduler_cleanup(lua_State *L);

/* Pending coroutine management */
LUAI_FUNC void scheduler_add_pending(lua_State *L, lua_State *co, int fd,
                                     int events, lua_Number deadline);
LUAI_FUNC int scheduler_poll(lua_State *L, int timeout_ms);
LUAI_FUNC int scheduler_pending_count(lua_State *L);

/* Detached coroutine management */
LUAI_FUNC int is_detached(lua_State *co);
LUAI_FUNC void mark_detached(lua_State *co);
LUAI_FUNC void unmark_detached(lua_State *co);

/* Yield reason tracking (stored in coroutine state) */
LUAI_FUNC void set_yield_reason(lua_State *co, int reason);
LUAI_FUNC int get_yield_reason(lua_State *co);
LUAI_FUNC void set_yield_fd(lua_State *co, int fd);
LUAI_FUNC int get_yield_fd(lua_State *co);
LUAI_FUNC void set_yield_events(lua_State *co, int events);
LUAI_FUNC int get_yield_events(lua_State *co);
LUAI_FUNC void set_yield_deadline(lua_State *co, lua_Number deadline);
LUAI_FUNC lua_Number get_yield_deadline(lua_State *co);

/* Event-driven resume for detached coroutines */
LUAI_FUNC int detached_resume(lua_State *L, lua_State *co, int nargs);

/* Timer utilities */
LUAI_FUNC lua_Number eventloop_now(void); /* Current time in seconds */

/* Thread pool integration */
struct ThreadPoolTask; /* Forward declaration */
struct ThreadPool;     /* Forward declaration */
LUAI_FUNC void set_yield_task(lua_State *co, struct ThreadPoolTask *task);
LUAI_FUNC struct ThreadPoolTask *get_yield_task(lua_State *co);
LUAI_FUNC struct ThreadPool *scheduler_get_threadpool(lua_State *L);

#endif
