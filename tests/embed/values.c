/*
** Pushing and reading every value type: nil, booleans, integers, floats,
** strings, vector bytes, light values, and type names.
*/

#include "check.h"

int main(void) {
  lus_State *L = lus_newstate();
  CHECK_OK(L, lus_openlibs(L));

  lus_pushnil(L);
  CHECK(lus_type(L, -1) == LUS_TNIL);
  CHECK(lus_isnil(L, -1));
  CHECK(!lus_toboolean(L, -1));

  lus_pushboolean(L, 1);
  CHECK(lus_type(L, -1) == LUS_TBOOLEAN);
  CHECK(lus_toboolean(L, -1) == 1);
  lus_pushboolean(L, 0);
  CHECK(lus_toboolean(L, -1) == 0);

  lus_pushinteger(L, INT64_MAX);
  CHECK(lus_type(L, -1) == LUS_TNUMBER);
  CHECK(lus_isinteger(L, -1));
  CHECK(lus_tointeger(L, -1, NULL) == INT64_MAX);

  int isnum = -1;
  lus_pushnumber(L, 2.5);
  CHECK(!lus_isinteger(L, -1));
  CHECK(lus_tonumber(L, -1, &isnum) == 2.5 && isnum == 1);
  lus_tointeger(L, -1, &isnum);
  CHECK(isnum == 0);
  lus_pushnumber(L, 4.0);
  CHECK(lus_tointeger(L, -1, &isnum) == 4 && isnum == 1);
  lus_settop(L, 0);

  /* Strings carry their length and a terminating zero byte. */
  size_t len = 0;
  CHECK_OK(L, lus_pushstring(L, "h\xc3\xa9llo"));
  CHECK(lus_type(L, -1) == LUS_TSTRING);
  CHECK(strcmp(lus_tostring(L, -1, &len), "h\xc3\xa9llo") == 0);
  CHECK(len == 6);
  CHECK(lus_rawlen(L, -1) == 6);
  CHECK_OK(L, lus_pushlstring(L, "abcdef", 3));
  CHECK_STR(L, -1, "abc");
  CHECK_OK(L, lus_pushstring(L, "42"));
  CHECK(lus_tointeger(L, -1, &isnum) == 42 && isnum == 1);
  CHECK(lus_tostring(L, -4, NULL) == NULL); /* nothing below is a string */
  CHECK_OK(L, lus_pushfstring(L, "%s=%d", "x", 7));
  CHECK_STR(L, -1, "x=7");
  /* Invalid UTF-8 fails and pushes the error message instead. */
  int top = lus_gettop(L);
  CHECK(lus_pushstring(L, "\xff\xfe") == LUS_ERRRUN);
  CHECK(lus_gettop(L) == top + 1);
  CHECK_HAS(L, -1, "invalid UTF-8");
  lus_pushstring(L, NULL);
  CHECK(lus_isnil(L, -1));
  lus_settop(L, 0);

  /* Vectors hold raw bytes, zero bytes included. */
  const unsigned char raw[4] = {0x00, 0xff, 0x10, 0x00};
  CHECK_OK(L, lus_pushbytes(L, raw, sizeof raw));
  CHECK(lus_type(L, -1) == LUS_TVECTOR);
  unsigned char *bytes = lus_tobytes(L, -1, &len);
  CHECK(bytes != NULL && len == 4 && memcmp(bytes, raw, 4) == 0);
  bytes[2] = 0x20; /* vectors are mutable in place */
  CHECK_OK(L, lus_setglobal(L, "v"));
  CHECK_OK(L, lus_dostring(L, "return v:get(2), #v"));
  CHECK(lus_tointeger(L, 1, NULL) == 0x20);
  CHECK(lus_tointeger(L, 2, NULL) == 4);
  lus_settop(L, 0);
  CHECK_OK(L, lus_pushbytes(L, NULL, 3));
  bytes = lus_tobytes(L, -1, &len);
  CHECK(len == 3 && bytes[0] == 0 && bytes[2] == 0);
  CHECK_OK(L, lus_dostring(L, "return vector.create(0)"));
  CHECK(lus_tobytes(L, -1, &len) != NULL && len == 0);
  lus_settop(L, 0);

  /* Light values carry host pointers and compare by address. */
  int anchor = 0;
  lus_pushlight(L, &anchor);
  CHECK(lus_type(L, -1) == LUS_TLIGHT);
  CHECK(lus_tolight(L, -1) == &anchor);
  CHECK(lus_touserdata(L, -1) == &anchor);
  lus_pushlight(L, &anchor);
  CHECK(lus_rawequal(L, -1, -2));
  CHECK(strcmp(lus_typename(lus_type(L, -1)), "userdata") == 0);
  lus_settop(L, 0);

  CHECK(strcmp(lus_typename(LUS_TNUMBER), "number") == 0);
  CHECK(strcmp(lus_typename(LUS_TVECTOR), "vector") == 0);
  CHECK(strcmp(lus_typename(LUS_TNONE), "no value") == 0);

  /* Script values come back with their types. */
  CHECK_OK(L, lus_dostring(L, "return {}, print, coroutine.create(print)"));
  CHECK(lus_type(L, 1) == LUS_TTABLE);
  CHECK(lus_type(L, 2) == LUS_TFUNCTION);
  CHECK(lus_type(L, 3) == LUS_TTHREAD);
  lus_settop(L, 0);

  /* tostring with metamethods. */
  CHECK_OK(L, lus_dostring(L,
      "return setmetatable({}, {__tostring = function() return 'custom' end})"));
  CHECK_OK(L, lus_stringify(L, -1));
  CHECK_STR(L, -1, "custom");
  lus_pushinteger(L, 12);
  CHECK_OK(L, lus_stringify(L, -1));
  CHECK_STR(L, -1, "12");
  lus_settop(L, 0);

  lus_close(L);
  return check_done("values");
}
