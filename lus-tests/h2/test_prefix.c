#include <stdio.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int fail(lua_State *L, const char *message) {
  fprintf(stderr, "%s\n", message);
  lua_close(L);
  return 1;
}

int main(void) {
  const char *compat;
  const char *lus;
  const char *path;
  lua_State *L = luaL_newstate();
  if (L == NULL)
    return 1;

  lua_pushboolean(L, 1);
  lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
  luaL_openlibs(L);

  lua_getglobal(L, "package");
  lua_getfield(L, -1, "path");
  path = lua_tostring(L, -1);
  if (path == NULL)
    return fail(L, "package.path is not a string");
  lus = strstr(path, LUS_INSTALL_PREFIX "share/lus/" LUA_VDIR "/");
  compat = strstr(path, LUS_INSTALL_PREFIX "share/lua/" LUA_VDIR "/");
  if (lus == NULL || compat == NULL || lus >= compat)
    return fail(L, "package.path does not prefer the configured Lus prefix");
  lua_pop(L, 1);

  lua_getfield(L, -1, "cpath");
  path = lua_tostring(L, -1);
  if (path == NULL)
    return fail(L, "package.cpath is not a string");
  lus = strstr(path, LUS_INSTALL_PREFIX "lib/lus/" LUA_VDIR "/");
  compat = strstr(path, LUS_INSTALL_PREFIX "lib/lua/" LUA_VDIR "/");
  if (lus == NULL || compat == NULL || lus >= compat)
    return fail(L, "package.cpath does not prefer the configured Lus prefix");

  lua_close(L);
  return 0;
}
