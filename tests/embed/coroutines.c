/*
** Detached coroutines from a host: lus_pending counts them,
** lus_runpending runs them one pass at a time or to their end and
** reports an error that nothing collected, and lus_close closes the ones
** that remain.
*/

#include "check.h"

static int closed_count = 0;

/* closed() counts the to-be-closed variables that ran. */
static int closed(lus_State *L) {
  (void)L;
  closed_count++;
  return 0;
}

static const char *spawn_two =
    "log = {}\n"
    "local function body(name, n)\n"
    "  for i = 1, n do\n"
    "    log[#log + 1] = name .. i\n"
    "    coroutine.yield()\n"
    "  end\n"
    "end\n"
    "coroutine.detach(coroutine.create(body), 'a', 3)\n"
    "coroutine.detach(coroutine.create(body), 'b', 2)\n";

int main(void) {
  lus_State *L = lus_newstate();
  CHECK_OK(L, lus_openlibs(L));
  CHECK(lus_pending(L) == 0);
  CHECK_OK(L, lus_runpending(L, 1));
  CHECK_OK(L, lus_runpending(L, 0));

  /* A chunk that detaches coroutines returns before they start. */
  CHECK_OK(L, lus_dostring(L, spawn_two));
  CHECK(lus_pending(L) == 2);
  CHECK_OK(L, lus_dostring(L, "return #log"));
  CHECK(lus_tointeger(L, -1, NULL) == 0);
  lus_settop(L, 0);

  /* One pass gives every ready coroutine one turn. */
  CHECK_OK(L, lus_runpending(L, 0));
  CHECK(lus_gettop(L) == 0);
  CHECK(lus_pending(L) == 2);
  CHECK_OK(L, lus_dostring(L, "return table.concat(log, ' ')"));
  CHECK_STR(L, -1, "a1 b1");
  lus_settop(L, 0);
  CHECK_OK(L, lus_runpending(L, 0));
  CHECK_OK(L, lus_dostring(L, "return table.concat(log, ' ')"));
  CHECK_STR(L, -1, "a1 b1 a2 b2");
  lus_settop(L, 0);

  /* Waiting runs them to their end. */
  CHECK_OK(L, lus_runpending(L, 1));
  CHECK(lus_pending(L) == 0);
  CHECK(lus_gettop(L) == 0);
  CHECK_OK(L, lus_dostring(L, "return table.concat(log, ' ')"));
  CHECK_STR(L, -1, "a1 b1 a2 b2 a3");
  lus_settop(L, 0);

  /* A script collects results with resume, which runs the coroutines. */
  CHECK_OK(L, lus_dostring(L,
      "local co = coroutine.detach(coroutine.create(function(x)\n"
      "  coroutine.yield()\n"
      "  return x * 2\n"
      "end), 21)\n"
      "return coroutine.resume(co)"));
  CHECK(lus_gettop(L) == 2);
  CHECK(lus_toboolean(L, 1) == 1);
  CHECK(lus_tointeger(L, 2, NULL) == 42);
  lus_settop(L, 0);
  CHECK(lus_pending(L) == 0);

  /* An error that nothing collected is reported once the coroutines
     have ended, with the traceback of the coroutine that failed. */
  CHECK_OK(L, lus_dostring(L,
      "local function broken() error('nobody asked') end\n"
      "coroutine.detach(coroutine.create(function()\n"
      "  coroutine.yield()\n"
      "  broken()\n"
      "end))\n"
      "coroutine.detach(coroutine.create(function()\n"
      "  for i = 1, 3 do coroutine.yield() end\n"
      "  finished = true\n"
      "end))\n"));
  CHECK(lus_runpending(L, 1) == LUS_ERRRUN);
  CHECK(lus_gettop(L) == 1);
  CHECK_HAS(L, -1, "(dostring):1: nobody asked");
  const char *tb = lus_traceback(L);
  CHECK(tb != NULL && strstr(tb, "stack traceback") != NULL);
  CHECK(tb != NULL && strstr(tb, "broken") != NULL);
  lus_settop(L, 0);
  CHECK(lus_pending(L) == 0);
  CHECK_OK(L, lus_dostring(L, "return finished"));
  CHECK(lus_toboolean(L, -1) == 1);
  lus_settop(L, 0);
  /* The error is reported once. */
  CHECK_OK(L, lus_runpending(L, 1));

  /* An error that a script collected is no error of the host. */
  CHECK_OK(L, lus_dostring(L,
      "local co = coroutine.detach(coroutine.create(function() error('seen', 0) end))\n"
      "return coroutine.resume(co)"));
  CHECK(lus_toboolean(L, 1) == 0);
  CHECK_STR(L, 2, "seen");
  lus_settop(L, 0);
  CHECK_OK(L, lus_runpending(L, 1));

  /* Coroutines that only wait for each other are a deadlock. */
  CHECK_OK(L, lus_dostring(L,
      "local a, b\n"
      "a = coroutine.detach(coroutine.create(function() return coroutine.resume(b) end))\n"
      "b = coroutine.detach(coroutine.create(function() return coroutine.resume(a) end))\n"
      "stuck = { a, b }"));
  CHECK(lus_runpending(L, 1) == LUS_ERRRUN);
  CHECK_HAS(L, -1, "deadlock");
  lus_settop(L, 0);
  CHECK(lus_pending(L) == 2);
  CHECK_OK(L, lus_dostring(L, "coroutine.close(stuck[1]) coroutine.close(stuck[2])"));
  CHECK(lus_pending(L) == 0);

  /* Closing the state closes the coroutines that remain, which runs
     their pending to-be-closed variables. */
  CHECK_OK(L, lus_pushcfunction(L, closed));
  CHECK_OK(L, lus_setglobal(L, "closed"));
  CHECK_OK(L, lus_dostring(L,
      "for i = 1, 3 do\n"
      "  coroutine.detach(coroutine.create(function()\n"
      "    local mark <close> = setmetatable({}, { __close = closed })\n"
      "    while true do coroutine.yield() end\n"
      "  end))\n"
      "end\n"
      "coroutine.detach(coroutine.create(function() closed() end))"));
  CHECK_OK(L, lus_runpending(L, 0));
  CHECK(closed_count == 1);
  CHECK(lus_pending(L) == 3);
  lus_close(L);
  CHECK(closed_count == 4);

  return check_done("coroutines");
}
