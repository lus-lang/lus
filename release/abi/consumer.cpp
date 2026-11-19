#include <iostream>

#include "lua.hpp"
#include "lworkerlib.h"

int main() {
  lua_State *state = luaL_newstate();
  if (state == nullptr)
    return 1;
  luaL_openlibs(state);
  lua_createtable(state, 0, 1);
  lua_pushliteral(state, "value");
  lua_setfield(state, -2, "name");
  if (lua_getfield(state, -1, "name") != LUA_TSTRING) {
    lua_close(state);
    return 2;
  }
  lua_close(state);
  lus_worker_pool_shutdown();
  std::cout << "cpp-consumer-ok\n";
  return 0;
}
