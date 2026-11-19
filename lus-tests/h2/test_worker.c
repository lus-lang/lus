/*
** H2: opaque worker handles, owned references, and per-state worker domains.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#endif

#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"

static int failures = 0;
static lua_State *expected_one;
static lua_State *expected_two;

#define CHECK(cond, what)                                                      \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "FAIL: %s\n", what);                                     \
      failures++;                                                              \
    }                                                                          \
  } while (0)

static void pause_thread(void) {
#if defined(_WIN32)
  Sleep(1);
#else
  struct timespec delay = {0, 1000000};
  nanosleep(&delay, NULL);
#endif
}

static void setup_owner(lua_State *worker, const char *owner) {
  luaL_openselectedlibs(worker, LUA_GLIBK, 0);
  lua_pushstring(worker, owner);
  lua_setglobal(worker, "owner");
}

static void setup_one(lua_State *parent, lua_State *worker) {
  setup_owner(worker, parent == expected_one ? "one" : "bad-one");
}

static void setup_two(lua_State *parent, lua_State *worker) {
  setup_owner(worker, parent == expected_two ? "two" : "bad-two");
}

static int await_message(lua_State *L, WorkerState *w, const char *expected) {
  for (int attempt = 0; attempt < 5000; attempt++) {
    if (lus_worker_receive(L, w)) {
      const char *actual = lua_tostring(L, -1);
      int match = actual != NULL && strcmp(actual, expected) == 0;
      lua_pop(L, 1);
      return match;
    }
    pause_thread();
  }
  return 0;
}

static int send_string(lua_State *L, WorkerState *w, const char *message) {
  int sent;
  lua_pushstring(L, message);
  sent = lus_worker_send(L, w, -1);
  lua_pop(L, 1);
  return sent;
}

static int await_status(WorkerState *w, int expected) {
  for (int attempt = 0; attempt < 5000; attempt++) {
    if (lus_worker_status(w) == expected)
      return 1;
    pause_thread();
  }
  return 0;
}

static double monotonic_seconds(void) {
#if defined(_WIN32)
  return (double)GetTickCount64() / 1000.0;
#else
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
#endif
}

static void test_queued_state_close(void) {
  lua_State *blocker_state = luaL_newstate();
  lua_State *queued_state = luaL_newstate();
  WorkerState **blockers;
  WorkerState *queued = NULL;
  /* The process pool has at most 32 threads. Placing 32 blocking workers
  ** ahead of the target guarantees that the target remains queued, including
  ** when pool startup produces fewer threads. */
  int count = 32;
  int created = 0;

  CHECK(blocker_state != NULL && queued_state != NULL,
        "saturation states are created");
  if (blocker_state == NULL || queued_state == NULL) {
    if (blocker_state != NULL)
      lua_close(blocker_state);
    if (queued_state != NULL)
      lua_close(queued_state);
    return;
  }

  blockers = (WorkerState **)calloc((size_t)count, sizeof(WorkerState *));
  CHECK(blockers != NULL, "saturation worker handles are allocated");
  if (blockers == NULL) {
    lua_close(blocker_state);
    lua_close(queued_state);
    return;
  }

  expected_one = blocker_state;
  expected_two = queued_state;
  lus_onworker(blocker_state, setup_one);
  lus_onworker(queued_state, setup_two);

  for (int i = 0; i < count; i++) {
    blockers[i] =
        lus_worker_create(blocker_state, "lus-tests/h2/worker_state.lus");
    CHECK(blockers[i] != NULL, "a pool-saturating worker is created");
    if (blockers[i] == NULL)
      break;
    created++;
  }

  if (created == count) {
    double started;
    double elapsed;

    queued = lus_worker_create(queued_state, "lus-tests/h2/worker_state.lus");
    CHECK(queued != NULL, "the saturated pool accepts queued state work");
    started = monotonic_seconds();
    lua_close(queued_state);
    queued_state = NULL;
    elapsed = monotonic_seconds() - started;
    CHECK(elapsed < 5.0,
          "closing a state cancels its queued worker without waiting");
    CHECK(lus_worker_status(queued) == LUS_WORKER_DEAD,
          "the cancelled queued worker is dead");

    CHECK(await_message(blocker_state, blockers[0], "one"),
          "a pool-saturating worker reaches its blocking receive");
    CHECK(send_string(blocker_state, blockers[0], "ping"),
          "queued-state cancellation preserves another state");
    CHECK(await_message(blocker_state, blockers[0], "one:ping"),
          "another state's saturated worker still responds");
  }

  if (queued_state != NULL)
    lua_close(queued_state);
  lua_close(blocker_state);
  for (int i = 0; i < created; i++)
    lus_worker_release(blockers[i]);
  lus_worker_release(queued);
  free(blockers);
}

int main(void) {
  lua_State *L1 = luaL_newstate();
  lua_State *L2 = luaL_newstate();
  WorkerState *w1;
  WorkerState *w2;
  WorkerState *missing;

  printf("Running H2: test_worker\n");
  CHECK(L1 != NULL && L2 != NULL, "two independent states are created");
  if (L1 == NULL || L2 == NULL)
    return 1;

  expected_one = L1;
  expected_two = L2;
  lus_onworker(L1, setup_one);
  lus_onworker(L2, setup_two);

  w1 = lus_worker_create(L1, "lus-tests/h2/worker_state.lus");
  w2 = lus_worker_create(L2, "lus-tests/h2/worker_state.lus");
  CHECK(w1 != NULL && w2 != NULL,
        "each state creates a caller-owned worker handle");
  if (w1 == NULL || w2 == NULL)
    return 1;

  CHECK(await_message(L1, w1, "one"),
        "the first state uses only its own setup callback");
  CHECK(await_message(L2, w2, "two"),
        "the second state uses only its own setup callback");

  missing = lus_worker_create(L1, "lus-tests/h2/missing-worker.lus");
  CHECK(missing != NULL,
        "a failed script open still returns one caller-owned handle");
  if (missing != NULL) {
    CHECK(await_status(missing, LUS_WORKER_ERROR),
          "a failed script open becomes an asynchronous worker error");
    lus_worker_release(missing);
  }

  CHECK(lus_worker_retain(w2) == w2, "retain returns the opaque handle");
  lus_worker_release(w2);
  CHECK(lus_worker_status(w2) == LUS_WORKER_RUNNING,
        "releasing one of two references keeps the handle alive");

  lua_close(L1);
  L1 = NULL;
  CHECK(lus_worker_status(w1) != LUS_WORKER_RUNNING,
        "closing a state drains its worker");

  CHECK(send_string(L2, w2, "ping"),
        "closing the first state leaves the second worker available");
  CHECK(await_message(L2, w2, "two:ping"),
        "the second state receives its worker reply");
  CHECK(!send_string(L2, w1, "late"),
        "a closed state's worker rejects new messages");

  CHECK(send_string(L2, w2, "STOP"), "the remaining worker accepts stop");
  CHECK(await_message(L2, w2, "STOPPED"),
        "the remaining worker exits normally");

  lua_close(L2);
  L2 = NULL;
  CHECK(lus_worker_status(w2) != LUS_WORKER_RUNNING,
        "the caller-owned handle remains valid after state destruction");
  lus_worker_release(w1);
  lus_worker_release(w2);
  CHECK(lus_worker_retain(NULL) == NULL, "retaining NULL is a no-op");
  lus_worker_release(NULL);

  test_queued_state_close();

  /* The process pool remains live until the embedder shuts it down. */
  lus_worker_pool_shutdown();

  if (failures == 0)
    printf("worker C API tests passed\n");
  return failures == 0 ? 0 : 1;
}
