/*
** Error handling: syntax errors, runtime errors with messages and
** tracebacks, error values of any type, errors raised from C, and the
** stack discipline after a failure.
*/

#include "check.h"

static int fail_plain(lus_State *L) {
  return lus_errorf(L, "plain failure %d", 7);
}

static int fail_value(lus_State *L) {
  CHECK_OK(L, lus_newtable(L, 0, 1));
  lus_pushinteger(L, 404);
  CHECK_OK(L, lus_setfield(L, -2, "code"));
  return lus_error(L);
}

int main(void) {
  lus_State *L = lus_newstate();
  CHECK_OK(L, lus_openlibs(L));

  /* Syntax errors name the chunk and the line. */
  const char *bad = "local x = \n x +";
  CHECK(lus_load(L, bad, strlen(bad), "=broken") == LUS_ERRSYNTAX);
  CHECK(lus_gettop(L) == 1);
  CHECK_HAS(L, -1, "broken:");
  lus_settop(L, 0);
  CHECK(lus_dostring(L, "return +") == LUS_ERRSYNTAX);
  lus_settop(L, 0);

  /* Runtime errors carry a message and a traceback. */
  CHECK(lus_dostring(L, "local function deep() error('boom') end\n"
                        "local function mid() deep() end\n"
                        "mid()") == LUS_ERRRUN);
  CHECK(lus_gettop(L) == 1);
  CHECK_HAS(L, -1, "(dostring):1: boom");
  const char *tb = lus_traceback(L);
  CHECK(tb != NULL && strstr(tb, "stack traceback") != NULL);
  CHECK(tb != NULL && strstr(tb, "mid") != NULL);
  lus_settop(L, 0);

  /* The stack keeps the values below the call. */
  lus_pushinteger(L, 111);
  CHECK_OK(L, lus_dostring(L, "return function() error('x') end"));
  lus_pushinteger(L, 1);
  CHECK(lus_pcall(L, 1, 3) == LUS_ERRRUN);
  CHECK(lus_gettop(L) == 2);
  CHECK(lus_tointeger(L, 1, NULL) == 111);
  lus_settop(L, 0);

  /* Error values of any type survive. */
  CHECK(lus_dostring(L, "error({ code = 1 })") == LUS_ERRRUN);
  CHECK(lus_type(L, -1) == LUS_TTABLE);
  lus_settop(L, 0);

  /* Errors raised from C, with a position prefix and as plain values. */
  CHECK_OK(L, lus_pushcfunction(L, fail_plain));
  CHECK_OK(L, lus_setglobal(L, "fail_plain"));
  CHECK_OK(L, lus_pushcfunction(L, fail_value));
  CHECK_OK(L, lus_setglobal(L, "fail_value"));
  CHECK(lus_dostring(L, "\n fail_plain()") == LUS_ERRRUN);
  CHECK_STR(L, -1, "(dostring):2: plain failure 7");
  lus_settop(L, 0);
  CHECK(lus_dostring(L, "fail_value()") == LUS_ERRRUN);
  CHECK_OK(L, lus_getfield(L, -1, "code"));
  CHECK(lus_tointeger(L, -1, NULL) == 404);
  lus_settop(L, 0);

  /* Scripts catch errors raised from C. */
  CHECK_OK(L, lus_dostring(L,
      "local ok, e = catch fail_value() return ok, e.code"));
  CHECK(lus_toboolean(L, 1) == 0);
  CHECK(lus_tointeger(L, 2, NULL) == 404);
  lus_settop(L, 0);

  /* Calling a value that is not a function. */
  lus_pushinteger(L, 3);
  CHECK(lus_pcall(L, 0, 0) == LUS_ERRRUN);
  CHECK_HAS(L, -1, "attempt to call a number value");
  lus_settop(L, 0);

  /* Metamethod failures from non-raw access come back as statuses. */
  CHECK_OK(L, lus_dostring(L,
      "return setmetatable({}, {__index = function() error('no field') end})"));
  CHECK(lus_getfield(L, 1, "k") == LUS_ERRRUN);
  CHECK(lus_gettop(L) == 2);
  CHECK_HAS(L, -1, "no field");
  lus_settop(L, 0);
  lus_pushinteger(L, 1);
  CHECK(lus_getfield(L, 1, "k") == LUS_ERRRUN);
  CHECK_HAS(L, -1, "attempt to index a number value");
  lus_settop(L, 0);

  /* The state stays usable after many errors. */
  for (int i = 0; i < 1000; i++) {
    CHECK(lus_dostring(L, "error('again')") == LUS_ERRRUN);
    lus_settop(L, 0);
  }
  CHECK_OK(L, lus_dostring(L, "return 'fine'"));
  CHECK_STR(L, -1, "fine");

  lus_close(L);
  return check_done("errors");
}
