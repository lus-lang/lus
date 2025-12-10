/*
** ltask.h
** Unified async task abstraction for Lus
*/

#ifndef ltask_h
#define ltask_h

#include "lua.h"

/*
** ========================================================
** Task Types
** Negative IDs reserved for Lus internal task types.
** Positive IDs available for embedders.
** ========================================================
*/

#define LUS_TASK_SLEEP -1          /* coroutine.sleep */
#define LUS_TASK_IO -2             /* Generic socket I/O (legacy) */
#define LUS_TASK_SOCKET_SEND -3    /* socket:send */
#define LUS_TASK_SOCKET_RECV -4    /* socket:recv (bytes, line, all) */
#define LUS_TASK_SOCKET_ACCEPT -5  /* server:accept */
#define LUS_TASK_SOCKET_CONNECT -6 /* tcp.connect */

/*
** ========================================================
** Task Status
** Passed to handler to indicate current phase.
** ========================================================
*/

#define LUS_TASK_INIT 0     /* Task is being created */
#define LUS_TASK_RESUME 1   /* Task is being started/resumed */
#define LUS_TASK_COMPLETE 2 /* Task is being fulfilled */
#define LUS_TASK_CLOSE 3    /* Task is being closed */

/*
** ========================================================
** Handler Return Actions
** Returned by handler to control task lifecycle.
** ========================================================
*/

#define LUS_TASK_ACT_CLOSE 0   /* Close task */
#define LUS_TASK_ACT_ENQUEUE 1 /* Add to poll queue */
#define LUS_TASK_ACT_DEQUEUE 2 /* Remove from queue (waiting on kernel) */
#define LUS_TASK_ACT_ERROR 3   /* Error (message pushed to stack) */

/*
** ========================================================
** Task Structure
** ========================================================
*/

typedef struct lus_Task lus_Task;

struct lus_Task {
  int type;         /* Task type ID */
  int status;       /* Current status (INIT/RESUME/COMPLETE/CLOSE) */
  lua_State *co;    /* Owning coroutine */
  void *data;       /* User data (malloc'd, copied) */
  size_t data_size; /* Size of user data */
  lus_Task *next;   /* Next in queue */
};

/*
** ========================================================
** Task Handler Type
** ========================================================
*/

typedef int (*lus_TaskHandler)(lua_State *L, lus_Task *t);

/*
** ========================================================
** Public API
** ========================================================
*/

/*
** Register a task type handler.
** Call this during library initialization (e.g., luaopen_*).
**
** Parameters:
**   L: lua_State (uses registry for storage)
**   type: Task type ID (negative = internal, positive = embedder)
**   handler: Callback function for task lifecycle
*/
LUA_API void lus_task_register(lua_State *L, int type, lus_TaskHandler handler);

/*
** Create a new task.
** Invokes the handler with LUS_TASK_INIT status.
** Returns the task, or NULL on error.
**
** Parameters:
**   L: lua_State
**   type: Registered task type ID
*/
LUA_API lus_Task *lus_task(lua_State *L, int type);

/*
** Set task data (copied, persists across yields).
**
** Parameters:
**   t: Task
**   data: Pointer to data to copy
**   size: Size of data
*/
LUA_API void lus_task_setdata(lus_Task *t, const void *data, size_t size);

/*
** Get task data (copies to output buffer).
**
** Parameters:
**   t: Task
**   out: Buffer to copy data into (must be at least t->data_size)
*/
LUA_API void lus_task_getdata(lus_Task *t, void *out);

/*
** Mark task as complete.
** Called from kernel callbacks or when operation finishes.
** Triggers handler with LUS_TASK_COMPLETE status on next poll.
*/
LUA_API void lus_task_complete(lus_Task *t);

/*
** Yield the current coroutine with a task.
** Call this after lus_task() to suspend execution.
** Returns the appropriate value for the C function to return.
**
** Parameters:
**   L: lua_State
**   t: Task created with lus_task()
*/
LUA_API int lus_task_yield(lua_State *L, lus_Task *t);

/*
** Check if running in async context (detached coroutine).
** Returns 1 if async, 0 if synchronous.
*/
LUA_API int lus_isasync(lua_State *L);

/*
** Get the current task for a coroutine (if any).
** Returns NULL if no active task.
*/
LUA_API lus_Task *lus_task_current(lua_State *L);

/*
** Run the event loop until all pending tasks complete.
** Blocks efficiently, does not spin CPU.
*/
LUA_API void lus_task_run(lua_State *L);

/*
** Poll for task events with timeout.
** Returns number of tasks processed.
**
** Parameters:
**   L: lua_State
**   timeout_ms: Timeout in milliseconds (-1 = block forever)
*/
LUA_API int lus_task_poll(lua_State *L, int timeout_ms);

/*
** Get count of pending tasks.
*/
LUA_API int lus_task_pending(lua_State *L);

/*
** ========================================================
** Built-in Handlers (defined in their respective libraries)
** ========================================================
*/

/* Sleep handler - defined in lcorolib.c */
LUA_API int lus_sleep_handler(lua_State *L, lus_Task *t);

/* Socket handlers - defined in lnetlib.c */
LUA_API int lus_socket_send_handler(lua_State *L, lus_Task *t);
LUA_API int lus_socket_recv_handler(lua_State *L, lus_Task *t);

/*
** Register all built-in task handlers.
** Call this from scheduler_init after scheduler is created.
*/
LUA_API void lus_task_register_builtins(lua_State *L);

#endif
