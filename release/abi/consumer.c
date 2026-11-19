#include <stdio.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
#include "lworkerlib.h"

static int host_double(lua_State *L) {
  lua_Integer value = luaL_checkinteger(L, 1);
  lua_pushinteger(L, value * 2);
  return 1;
}

static void configure_worker(lua_State *parent, lua_State *worker) {
  (void)parent;
  lua_pushliteral(worker, "configured");
  lua_setglobal(worker, "embedding_state");
}

int main(void) {
  lua_State *L = luaL_newstate();
  if (L == NULL)
    return 1;
  luaL_openlibs(L);
  lua_pushcfunction(L, host_double);
  lua_setglobal(L, "host_double");
  if (luaL_dostring(L, "return host_double(21)") != LUA_OK) {
    lua_close(L);
    return 2;
  }
  if (!lua_isinteger(L, -1) || lua_tointeger(L, -1) != 42) {
    lua_close(L);
    return 3;
  }
  lua_pop(L, 1);
  lus_onworker(L, configure_worker);
  if (strncmp(LUA_VERSION, "Lus 1.", 6) != 0) {
    lua_close(L);
    return 4;
  }
  lua_close(L);
  lus_worker_pool_shutdown();
  puts("c-consumer-ok");
  return 0;
}
