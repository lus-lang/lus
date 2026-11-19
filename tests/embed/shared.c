/*
** The shared library: the same interface works when the host links
** liblus dynamically.
*/

#include "check.h"

static int twice(lus_State *L) {
  lus_pushinteger(L, 2 * lus_tointeger(L, 1, NULL));
  return 1;
}

int main(void) {
  lus_State *L = lus_newstate();
  CHECK(L != NULL);
  CHECK_OK(L, lus_openlibs(L));
  CHECK_OK(L, lus_pushcfunction(L, twice));
  CHECK_OK(L, lus_setglobal(L, "twice"));
  CHECK_OK(L, lus_dostring(L,
      "local t = {} for i = 1, 3 do t[i] = twice(i) end"
      " return table.concat(t, ','), tojson({ a = 1 })"));
  CHECK_STR(L, 1, "2,4,6");
  CHECK_STR(L, 2, "{\"a\":1}");
  lus_close(L);
  return check_done("shared");
}
