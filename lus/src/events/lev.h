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
#define YIELD_NORMAL 0 /* Regular yield (return to caller) */
#define YIELD_IO 1     /* Waiting for I/O */
#define YIELD_SLEEP 2  /* Sleeping for duration */

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

/* Scheduler state (stored in lua_State extra space or registry) */
typedef struct Scheduler Scheduler;

/* Scheduler management */
LUAI_FUNC Scheduler *scheduler_get(lua_State *L);
LUAI_FUNC void scheduler_init(lua_State *L);
LUAI_FUNC void scheduler_cleanup(lua_State *L);

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

#endif
