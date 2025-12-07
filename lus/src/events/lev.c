/*
** lev.c
** Event loop scheduler for detached coroutines
*/

#define lev_c
#define LUA_LIB

#include "../lprefix.h"

#include <stdlib.h>
#include <string.h>

#include "../lauxlib.h"
#include "../lua.h"
#include "lev.h"

#if defined(LUS_PLATFORM_WINDOWS)
#include <windows.h>
#else
#include <sys/time.h>
#include <time.h>
#endif

/*
** {======================================================
** Time Utilities
** =======================================================
*/

lua_Number eventloop_now(void) {
#if defined(LUS_PLATFORM_WINDOWS)
  LARGE_INTEGER freq, count;
  QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&count);
  return (lua_Number)count.QuadPart / (lua_Number)freq.QuadPart;
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (lua_Number)ts.tv_sec + (lua_Number)ts.tv_nsec / 1e9;
#endif
}

/* }====================================================== */

/*
** {======================================================
** Scheduler State
** =======================================================
*/

#define SCHEDULER_KEY "lus.scheduler"

struct Scheduler {
  EventBackend *backend;
  const BackendOps *ops;
};

Scheduler *scheduler_get(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, SCHEDULER_KEY);
  Scheduler *sched = (Scheduler *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  return sched;
}

void scheduler_init(lua_State *L) {
  /* Check if already initialized */
  lua_getfield(L, LUA_REGISTRYINDEX, SCHEDULER_KEY);
  if (!lua_isnil(L, -1)) {
    lua_pop(L, 1);
    return;
  }
  lua_pop(L, 1);

  /* Create scheduler */
  Scheduler *sched = (Scheduler *)lua_newuserdata(L, sizeof(Scheduler));
  sched->ops = eventloop_get_backend();
  sched->backend = sched->ops->create();

  if (!sched->backend) {
    luaL_error(L, "failed to create event loop backend");
  }

  lua_setfield(L, LUA_REGISTRYINDEX, SCHEDULER_KEY);
}

void scheduler_cleanup(lua_State *L) {
  Scheduler *sched = scheduler_get(L);
  if (sched && sched->backend) {
    sched->ops->destroy(sched->backend);
    sched->backend = NULL;
  }
  lua_pushnil(L);
  lua_setfield(L, LUA_REGISTRYINDEX, SCHEDULER_KEY);
}

/* }====================================================== */

/*
** {======================================================
** Detached Coroutine State
** =======================================================
** We store per-coroutine state in the registry keyed by the coroutine thread.
*/

typedef struct {
  int detached;
  int yield_reason;
  int yield_fd;
  int yield_events;
  lua_Number yield_deadline;
} CoroutineState;

#define COROSTATE_KEY "lus.corostate"

static CoroutineState *get_corostate(lua_State *co, int create) {
  lua_getfield(co, LUA_REGISTRYINDEX, COROSTATE_KEY);
  if (lua_isnil(co, -1)) {
    lua_pop(co, 1);
    if (create) {
      lua_newtable(co);
      lua_setfield(co, LUA_REGISTRYINDEX, COROSTATE_KEY);
      lua_getfield(co, LUA_REGISTRYINDEX, COROSTATE_KEY);
    } else {
      return NULL;
    }
  }

  /* Get state for this specific coroutine */
  lua_pushlightuserdata(co, (void *)co);
  lua_rawget(co, -2);

  if (lua_isnil(co, -1)) {
    lua_pop(co, 1);
    if (create) {
      CoroutineState *cs =
          (CoroutineState *)lua_newuserdata(co, sizeof(CoroutineState));
      memset(cs, 0, sizeof(CoroutineState));
      lua_pushlightuserdata(co, (void *)co);
      lua_pushvalue(co, -2);
      lua_rawset(co, -4);
      lua_pop(co, 2); /* Pop userdata and COROSTATE_KEY table */
      return cs;
    } else {
      lua_pop(co, 1); /* Remove COROSTATE_KEY table */
      return NULL;
    }
  }

  CoroutineState *cs = (CoroutineState *)lua_touserdata(co, -1);
  lua_pop(co, 2); /* Pop state and COROSTATE_KEY table */
  return cs;
}

int is_detached(lua_State *co) {
  CoroutineState *cs = get_corostate(co, 0);
  return cs && cs->detached;
}

void mark_detached(lua_State *co) {
  CoroutineState *cs = get_corostate(co, 1);
  if (cs)
    cs->detached = 1;
}

void unmark_detached(lua_State *co) {
  CoroutineState *cs = get_corostate(co, 0);
  if (cs)
    cs->detached = 0;
}

void set_yield_reason(lua_State *co, int reason) {
  CoroutineState *cs = get_corostate(co, 1);
  if (cs)
    cs->yield_reason = reason;
}

int get_yield_reason(lua_State *co) {
  CoroutineState *cs = get_corostate(co, 0);
  return cs ? cs->yield_reason : YIELD_NORMAL;
}

void set_yield_fd(lua_State *co, int fd) {
  CoroutineState *cs = get_corostate(co, 1);
  if (cs)
    cs->yield_fd = fd;
}

int get_yield_fd(lua_State *co) {
  CoroutineState *cs = get_corostate(co, 0);
  return cs ? cs->yield_fd : -1;
}

void set_yield_events(lua_State *co, int events) {
  CoroutineState *cs = get_corostate(co, 1);
  if (cs)
    cs->yield_events = events;
}

int get_yield_events(lua_State *co) {
  CoroutineState *cs = get_corostate(co, 0);
  return cs ? cs->yield_events : 0;
}

void set_yield_deadline(lua_State *co, lua_Number deadline) {
  CoroutineState *cs = get_corostate(co, 1);
  if (cs)
    cs->yield_deadline = deadline;
}

lua_Number get_yield_deadline(lua_State *co) {
  CoroutineState *cs = get_corostate(co, 0);
  return cs ? cs->yield_deadline : 0;
}

/* }====================================================== */

/*
** {======================================================
** Event-Driven Resume
** =======================================================
*/

int detached_resume(lua_State *L, lua_State *co, int nargs) {
  Scheduler *sched = scheduler_get(L);
  if (!sched || !sched->backend) {
    scheduler_init(L);
    sched = scheduler_get(L);
  }

  int resume_nargs = nargs;

  for (;;) {
    int nres;
    int status = lua_resume(co, L, resume_nargs, &nres);

    if (status == LUA_YIELD) {
      int reason = get_yield_reason(co);

      if (reason == YIELD_IO) {
        /* Wait for I/O event */
        int fd = get_yield_fd(co);
        int events = get_yield_events(co);

        /* Register fd with backend */
        sched->ops->add(sched->backend, fd, events, NULL);

        /* Wait for event */
        EventResult result;
        int ready = sched->ops->wait(sched->backend, &result, 1, -1);

        /* Remove fd from backend */
        sched->ops->remove(sched->backend, fd);

        if (ready < 0) {
          /* Error during wait */
          lua_pushstring(L, "I/O wait error");
          return lua_error(L);
        }

        /* Clear yield reason and continue */
        set_yield_reason(co, YIELD_NORMAL);
        resume_nargs = 0;
        continue;
      } else if (reason == YIELD_SLEEP) {
        /* Wait for timer */
        lua_Number deadline = get_yield_deadline(co);
        lua_Number now = eventloop_now();

        if (deadline > now) {
          int wait_ms = (int)((deadline - now) * 1000);
          if (wait_ms > 0) {
            /* Just wait (no fd) */
            EventResult result;
            sched->ops->wait(sched->backend, &result, 0, wait_ms);
          }
        }

        /* Clear yield reason and continue */
        set_yield_reason(co, YIELD_NORMAL);
        resume_nargs = 0;
        continue;
      } else {
        /* Normal yield - return to caller */
        /* Transfer results from co to L */
        lua_xmove(co, L, nres);
        return nres;
      }
    } else if (status == LUA_OK) {
      /* Coroutine completed - transfer results */
      lua_xmove(co, L, nres);
      unmark_detached(co);
      return nres;
    } else {
      /* Error - propagate to caller */
      lua_xmove(co, L, 1); /* Move error message */
      unmark_detached(co);
      return lua_error(L);
    }
  }
}

/* }====================================================== */
