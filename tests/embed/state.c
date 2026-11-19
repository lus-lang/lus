/*
** State lifecycle: create, open libraries, run source and files, read
** results, manipulate the stack, and close.
*/

#include "check.h"

int main(void) {
  lus_State *L = lus_newstate();
  CHECK(L != NULL);
  CHECK(lus_gettop(L) == 0);
  CHECK_OK(L, lus_openlibs(L));
  CHECK(lus_gettop(L) == 0);

  /* A chunk returns its values on the stack. */
  CHECK_OK(L, lus_dostring(L, "return 1 + 2, `sum $(1 + 2)`"));
  CHECK(lus_gettop(L) == 2);
  CHECK(lus_tointeger(L, 1, NULL) == 3);
  CHECK_STR(L, 2, "sum 3");
  lus_settop(L, 0);

  /* Loading without running pushes a function. */
  const char *mul = "local a, b = ... return a * b";
  CHECK_OK(L, lus_load(L, mul, strlen(mul), "=mul"));
  CHECK(lus_isfunction(L, -1));
  lus_pushinteger(L, 6);
  lus_pushinteger(L, 7);
  CHECK_OK(L, lus_pcall(L, 2, 1));
  CHECK(lus_gettop(L) == 1);
  CHECK(lus_tointeger(L, -1, NULL) == 42);
  lus_pop(L, 1);

  /* Files load with their path as the chunk name. */
  CHECK_OK(L, lus_dofile(L, "scripts/answer.lus"));
  CHECK(lus_tointeger(L, -1, NULL) == 42);
  lus_pop(L, 1);
  CHECK(lus_dofile(L, "scripts/missing.lus") == LUS_ERRFILE);
  CHECK_HAS(L, -1, "scripts/missing.lus");
  lus_pop(L, 1);

  /* Globals are shared between chunks. */
  lus_pushinteger(L, 10);
  CHECK_OK(L, lus_setglobal(L, "ten"));
  CHECK_OK(L, lus_dostring(L, "return ten * 2"));
  CHECK(lus_tointeger(L, -1, NULL) == 20);
  lus_pop(L, 1);
  CHECK_OK(L, lus_getglobal(L, "ten"));
  CHECK(lus_tointeger(L, -1, NULL) == 10);
  lus_pop(L, 1);

  /* Stack manipulation. */
  lus_pushinteger(L, 1);
  lus_pushinteger(L, 2);
  lus_pushinteger(L, 3);
  lus_insert(L, 1); /* 3 1 2 */
  CHECK(lus_tointeger(L, 1, NULL) == 3);
  lus_remove(L, 2); /* 3 2 */
  CHECK(lus_tointeger(L, 2, NULL) == 2);
  lus_pushvalue(L, 1); /* 3 2 3 */
  lus_replace(L, 2);   /* 3 3 */
  CHECK(lus_gettop(L) == 2);
  CHECK(lus_tointeger(L, -1, NULL) == 3);
  CHECK(lus_absindex(L, -1) == 2);
  lus_settop(L, 4);
  CHECK(lus_type(L, 4) == LUS_TNIL);
  CHECK(lus_type(L, 5) == LUS_TNONE);
  CHECK(lus_checkstack(L, 1000));
  lus_settop(L, 0);
  CHECK(lus_gettop(L) == 0);

  /* Many states can live side by side. */
  lus_State *L2 = lus_newstate();
  CHECK(L2 != NULL);
  CHECK_OK(L2, lus_dostring(L2, "return 5"));
  CHECK(lus_tointeger(L2, -1, NULL) == 5);
  lus_close(L2);

  lus_collect(L);
  lus_close(L);
  return check_done("state");
}
