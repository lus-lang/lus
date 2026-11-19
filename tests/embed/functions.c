/*
** C functions: registration, arguments and results, closures with
** upvalues, calling Lus functions from C, and callbacks kept by reference.
*/

#include "check.h"

/* add(a, b) returns a + b and a - b. */
static int add(lus_State *L) {
  lus_Integer a = lus_tointeger(L, 1, NULL);
  lus_Integer b = lus_tointeger(L, 2, NULL);
  lus_pushinteger(L, a + b);
  lus_pushinteger(L, a - b);
  return 2;
}

/* count(...) returns the number of arguments. */
static int count(lus_State *L) {
  lus_pushinteger(L, lus_gettop(L));
  return 1;
}

/* A counter closure: each call increments upvalue 1 through a table. */
static int counter(lus_State *L) {
  lus_getupvalue(L, 1);
  CHECK_OK(L, lus_getfield(L, -1, "n"));
  lus_Integer n = lus_tointeger(L, -1, NULL) + 1;
  lus_pop(L, 1);
  lus_pushinteger(L, n);
  CHECK_OK(L, lus_setfield(L, -2, "n"));
  lus_getupvalue(L, 2);
  CHECK_STR(L, -1, "label");
  lus_getupvalue(L, 3);
  CHECK(lus_isnil(L, -1));
  lus_pushinteger(L, n);
  return 1;
}

/* map(t, f) calls f on each array item in place. */
static int map(lus_State *L) {
  size_t n = lus_rawlen(L, 1);
  for (size_t i = 1; i <= n; i++) {
    lus_pushvalue(L, 2);
    lus_rawgeti(L, 1, (lus_Integer)i);
    int st = lus_pcall(L, 1, 1);
    if (st != LUS_OK)
      return lus_error(L);
    if (lus_rawseti(L, 1, (lus_Integer)i) != LUS_OK)
      return lus_error(L);
  }
  return 0;
}

static int callback_ref = LUS_NOREF;

/* on(f) stores a callback. */
static int on(lus_State *L) {
  lus_settop(L, 1);
  callback_ref = lus_ref(L);
  return 0;
}

int main(void) {
  lus_State *L = lus_newstate();
  CHECK_OK(L, lus_openlibs(L));

  CHECK_OK(L, lus_pushcfunction(L, add));
  CHECK_OK(L, lus_setglobal(L, "add"));
  CHECK_OK(L, lus_pushcfunction(L, count));
  CHECK_OK(L, lus_setglobal(L, "count"));
  CHECK_OK(L, lus_pushcfunction(L, map));
  CHECK_OK(L, lus_setglobal(L, "map"));
  CHECK_OK(L, lus_pushcfunction(L, on));
  CHECK_OK(L, lus_setglobal(L, "on"));

  CHECK_OK(L, lus_dostring(L, "local s, d = add(10, 3) return s, d"));
  CHECK(lus_tointeger(L, 1, NULL) == 13);
  CHECK(lus_tointeger(L, 2, NULL) == 7);
  lus_settop(L, 0);

  CHECK_OK(L, lus_dostring(L, "return count(), count(1, nil, 3)"));
  CHECK(lus_tointeger(L, 1, NULL) == 0);
  CHECK(lus_tointeger(L, 2, NULL) == 3);
  lus_settop(L, 0);

  /* C functions called directly from C. */
  CHECK_OK(L, lus_pushcfunction(L, add));
  lus_pushinteger(L, 2);
  lus_pushinteger(L, 5);
  CHECK_OK(L, lus_pcall(L, 2, LUS_MULTRET));
  CHECK(lus_gettop(L) == 2);
  CHECK(lus_tointeger(L, 2, NULL) == -3);
  lus_settop(L, 0);

  /* Closures carry upvalues. */
  CHECK_OK(L, lus_newtable(L, 0, 1));
  CHECK_OK(L, lus_pushstring(L, "label"));
  CHECK_OK(L, lus_pushcclosure(L, counter, 2));
  CHECK(lus_gettop(L) == 1);
  CHECK_OK(L, lus_setglobal(L, "tick"));
  CHECK_OK(L, lus_dostring(L, "tick() tick() return tick()"));
  CHECK(lus_tointeger(L, -1, NULL) == 3);
  lus_settop(L, 0);

  /* C calling back into Lus. */
  CHECK_OK(L, lus_dostring(L,
      "local t = {1, 2, 3} map(t, function(x) return x * x end)"
      " return t[1] + t[2] + t[3]"));
  CHECK(lus_tointeger(L, -1, NULL) == 14);
  lus_settop(L, 0);

  /* An error inside the callback crosses the C function intact. */
  CHECK(lus_dostring(L, "map({1}, function() error('inner') end)") == LUS_ERRRUN);
  CHECK_HAS(L, -1, "inner");
  lus_settop(L, 0);

  /* A Lus function kept by reference and called later. */
  CHECK_OK(L, lus_dostring(L, "on(function(a, b) return a .. b end)"));
  CHECK(callback_ref != LUS_NOREF);
  lus_collect(L);
  lus_getref(L, callback_ref);
  CHECK_OK(L, lus_pushstring(L, "left"));
  CHECK_OK(L, lus_pushstring(L, "right"));
  CHECK_OK(L, lus_pcall(L, 2, 1));
  CHECK_STR(L, -1, "leftright");
  lus_settop(L, 0);
  lus_unref(L, callback_ref);

  /* Lus functions fetched from globals. */
  CHECK_OK(L, lus_dostring(L, "function greet(n) return `hi $n` end"));
  CHECK_OK(L, lus_getglobal(L, "greet"));
  CHECK_OK(L, lus_pushstring(L, "there"));
  CHECK_OK(L, lus_pcall(L, 1, 1));
  CHECK_STR(L, -1, "hi there");
  lus_settop(L, 0);

  lus_close(L);
  return check_done("functions");
}
