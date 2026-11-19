/*
** H2: an idle worker is awakened and joined during state teardown.
*/

#include <stdio.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#endif

#include "lua.h"

#include "lauxlib.h"
#include "lworkerlib.h"

static int failures = 0;

#define CHECK(cond, what)                                                      \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "FAIL: %s\n", what);                                     \
      failures++;                                                              \
    }                                                                          \
  } while (0)

static void pause_thread(void) {
#if defined(_WIN32)
  Sleep(25);
#else
  struct timespec delay = {0, 25000000};
  nanosleep(&delay, NULL);
#endif
}

int main(void) {
  lua_State *L = luaL_newstate();
  WorkerState *worker;

  printf("Running H2: test_worker_idle\n");
  CHECK(L != NULL, "the owner state is created");
  if (L == NULL)
    return 1;

  worker = lus_worker_create(L, "lus-tests/h4/worker_idle.lus");
  CHECK(worker != NULL, "the idle-worker fixture starts");
  if (worker == NULL) {
    lua_close(L);
    lus_worker_pool_shutdown();
    return 1;
  }

  pause_thread();
  CHECK(lus_worker_status(worker) == LUS_WORKER_RUNNING,
        "the fixture remains blocked while its inbox is empty");

  lua_close(L);
  L = NULL;
  CHECK(lus_worker_status(worker) != LUS_WORKER_RUNNING,
        "state teardown wakes and joins the idle worker");

  lus_worker_release(worker);
  lus_worker_pool_shutdown();

  if (failures == 0)
    printf("idle worker teardown tests passed\n");
  return failures == 0 ? 0 : 1;
}
