/*
** Tables: creation, field and keyed access with and without metamethods,
** traversal, length, and references that keep values alive.
*/

#include "check.h"

int main(void) {
  lus_State *L = lus_newstate();
  CHECK_OK(L, lus_openlibs(L));

  CHECK_OK(L, lus_newtable(L, 4, 4));
  int t = lus_gettop(L);
  CHECK(lus_type(L, t) == LUS_TTABLE);

  lus_pushinteger(L, 7);
  CHECK_OK(L, lus_setfield(L, t, "x"));
  CHECK(lus_gettop(L) == t);
  CHECK_OK(L, lus_getfield(L, t, "x"));
  CHECK(lus_tointeger(L, -1, NULL) == 7);
  lus_pop(L, 1);

  /* Keyed access with any key type. */
  lus_pushnumber(L, 1.5);
  CHECK_OK(L, lus_pushstring(L, "float key"));
  CHECK_OK(L, lus_settable(L, t));
  lus_pushnumber(L, 1.5);
  CHECK_OK(L, lus_gettable(L, t));
  CHECK_STR(L, -1, "float key");
  lus_pop(L, 1);

  /* Raw array access. */
  for (int i = 1; i <= 3; i++) {
    lus_pushinteger(L, i * 10);
    CHECK_OK(L, lus_rawseti(L, t, i));
  }
  CHECK(lus_rawgeti(L, t, 2) == LUS_TNUMBER);
  CHECK(lus_tointeger(L, -1, NULL) == 20);
  lus_pop(L, 1);
  CHECK(lus_rawlen(L, t) == 3);
  CHECK_OK(L, lus_len(L, t));
  CHECK(lus_tointeger(L, -1, NULL) == 3);
  lus_pop(L, 1);
  CHECK_OK(L, lus_pushstring(L, "x"));
  CHECK(lus_rawget(L, t) == LUS_TNUMBER);
  lus_pop(L, 1);
  CHECK_OK(L, lus_pushstring(L, "y"));
  lus_pushboolean(L, 1);
  CHECK_OK(L, lus_rawset(L, t));

  /* Traversal visits every pair once. */
  int count = 0;
  lus_pushnil(L);
  while (lus_next(L, t) == 1) {
    count++;
    lus_pop(L, 1); /* keep the key for the next step */
  }
  CHECK(count == 6);
  CHECK(lus_gettop(L) == t);

  /* An invalid key reports an error. */
  CHECK_OK(L, lus_pushstring(L, "absent"));
  CHECK(lus_next(L, t) == LUS_ERROR);
  CHECK_HAS(L, -1, "invalid key");
  lus_pop(L, 1);

  /* Metamethods run for non-raw access. */
  CHECK_OK(L, lus_dostring(L,
      "return setmetatable({}, {"
      "  __index = function(_, k) return 'got ' .. k end,"
      "  __len = function() return 99 end,"
      "})"));
  int p = lus_gettop(L);
  CHECK_OK(L, lus_getfield(L, p, "key"));
  CHECK_STR(L, -1, "got key");
  lus_pop(L, 1);
  CHECK_OK(L, lus_len(L, p));
  CHECK(lus_tointeger(L, -1, NULL) == 99);
  lus_pop(L, 1);
  CHECK(lus_getmetatableof(L, p) == 1);
  CHECK(lus_type(L, -1) == LUS_TTABLE);
  lus_pop(L, 1);
  CHECK(lus_getmetatableof(L, t) == 0);
  lus_pop(L, 1);

  /* A table built in C is visible to scripts. */
  lus_pushvalue(L, t);
  CHECK_OK(L, lus_setglobal(L, "data"));
  CHECK_OK(L, lus_dostring(L, "return data.x + data[3] + #data"));
  CHECK(lus_tointeger(L, -1, NULL) == 7 + 30 + 3);
  lus_settop(L, 0);

  /* A reference keeps a value alive across collections. */
  CHECK_OK(L, lus_dostring(L, "return { name = 'kept' }"));
  int ref = lus_ref(L);
  CHECK(ref > 0);
  CHECK(lus_gettop(L) == 0);
  lus_collect(L);
  lus_getref(L, ref);
  CHECK_OK(L, lus_getfield(L, -1, "name"));
  CHECK_STR(L, -1, "kept");
  lus_settop(L, 0);
  lus_pushnil(L);
  CHECK(lus_ref(L) == LUS_NOREF);
  lus_getref(L, LUS_NOREF);
  CHECK(lus_isnil(L, -1));
  lus_pop(L, 1);
  lus_unref(L, ref);
  lus_getref(L, ref);
  CHECK(lus_isnil(L, -1));
  lus_pop(L, 1);
  lus_pushinteger(L, 5);
  CHECK(lus_ref(L) == ref); /* released numbers are reused */

  lus_close(L);
  return check_done("tables");
}
