/*
** H2: a hostile query plan blob. A dumped chunk can carry any string
** constant, so an attacker can hand luaQ_build a crafted plan without
** disturbing the surrounding bytecode. This builds the doubling-AND DAG
** the plan review identified, where node k is AND(k-1, k-1): every child
** index is smaller than its parent and the depth stays under the limit,
** yet the shared children make a later conjunct split expand
** exponentially and overrun a fixed C-stack buffer. The plan decoder's
** forest check must reject it at build time. Runs under the sanitizer
** job, so a regression would surface as a hard failure rather than a
** quiet acceptance.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lobject.h"
#include "lquery.h"
#include "lstate.h"
#include "lstring.h"

static int build_exploit(lua_State *L) {
  QPlanHeader h;
  QWireLayout w;
  char *wire;
  QSource src;
  QNode *nodes;
  TString *blob;
  StkId base, ra;
  int k;
  memset(&h, 0, sizeof(h));
  h.version = LUS_QPLAN_VERSION;
  h.nsources = 1;
  h.nnodes = 13;
  h.where_root = 12;
  h.having_root = QNODE_NONE;
  h.limit_node = QNODE_NONE;
  h.offset_node = QNODE_NONE;
  h.poolsize = 2;
  luaQ_wirelayout(&h, &w);
  wire = calloc(1, w.total);
  memcpy(wire, &h, sizeof(h));
  memset(&src, 0, sizeof(src));
  src.alias.off = 0;
  src.alias.len = 1;
  memcpy(wire + w.sources, &src, sizeof(src));
  nodes = (QNode *)(wire + w.nodes);
  memset(nodes, 0, 13 * sizeof(QNode));
  nodes[0].kind = QN_LIT_TRUE;
  for (k = 1; k <= 12; k++) {
    nodes[k].kind = QN_AND;
    nodes[k].a = (unsigned short)(k - 1);
    nodes[k].b = (unsigned short)(k - 1); /* shared child = the exploit */
  }
  wire[w.pool] = 's';
  blob = luaS_newlstr(L, wire, w.total);
  free(wire);
  lua_newtable(L); /* the source value */
  base = L->top.p - 1;
  ra = L->top.p;
  L->top.p++;
  luaQ_build(L, ra, blob, base, 1, 0); /* must raise on the bad plan */
  return 0;
}

int main(void) {
  lua_State *L = luaL_newstate();
  int st;
  luaL_openlibs(L);
  lua_pushcfunction(L, build_exploit);
  st = lua_pcall(L, 0, 0, 0);
  if (st != LUA_OK) {
    printf("REJECTED: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 0;
  }
  printf("ACCEPTED the doubling DAG (FIX FAILED)\n");
  lua_close(L);
  return 1;
}
