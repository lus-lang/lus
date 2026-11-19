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

static int build_bad_unary(lua_State *L) {
  QPlanHeader h;
  QWireLayout w;
  char *wire;
  QSource src;
  QNode *nodes;
  TString *blob;
  StkId base, ra;
  memset(&h, 0, sizeof(h));
  h.version = LUS_QPLAN_VERSION;
  h.nsources = 1;
  h.nnodes = 3;
  h.where_root = 2;
  h.having_root = QNODE_NONE;
  h.limit_node = QNODE_NONE;
  h.offset_node = QNODE_NONE;
  h.poolsize = 2;
  luaQ_wirelayout(&h, &w);
  wire = calloc(1, w.total);
  memcpy(wire, &h, sizeof(h));
  memset(&src, 0, sizeof(src));
  src.alias.len = 1;
  memcpy(wire + w.sources, &src, sizeof(src));
  nodes = (QNode *)(wire + w.nodes);
  nodes[0].kind = QN_LIT_INT;
  nodes[0].u.i = 1;
  nodes[1].kind = QN_LIT_INT;
  nodes[1].u.i = 2;
  nodes[2].kind = QN_ARITH;
  nodes[2].sub = QAR_UNM;
  nodes[2].a = 0;
  nodes[2].b = 1; /* unary plans must not carry a second operand */
  wire[w.pool] = 's';
  blob = luaS_newlstr(L, wire, w.total);
  free(wire);
  lua_newtable(L);
  base = L->top.p - 1;
  ra = L->top.p;
  L->top.p++;
  luaQ_build(L, ra, blob, base, 1, 0);
  return 0;
}

static int build_row_limit(lua_State *L) {
  QPlanHeader h;
  QWireLayout w;
  char *wire;
  QSource src;
  QNode *nodes;
  TString *blob;
  StkId base, ra;
  memset(&h, 0, sizeof(h));
  h.version = LUS_QPLAN_VERSION;
  h.nsources = 1;
  h.nnodes = 1;
  h.where_root = QNODE_NONE;
  h.having_root = QNODE_NONE;
  h.limit_node = 0;
  h.offset_node = QNODE_NONE;
  h.poolsize = 2;
  luaQ_wirelayout(&h, &w);
  wire = calloc(1, w.total);
  memcpy(wire, &h, sizeof(h));
  memset(&src, 0, sizeof(src));
  src.alias.len = 1;
  memcpy(wire + w.sources, &src, sizeof(src));
  nodes = (QNode *)(wire + w.nodes);
  nodes[0].kind = QN_ROWVAR;
  nodes[0].sub = 0;
  wire[w.pool] = 's';
  blob = luaS_newlstr(L, wire, w.total);
  free(wire);
  lua_newtable(L);
  base = L->top.p - 1;
  ra = L->top.p;
  L->top.p++;
  luaQ_build(L, ra, blob, base, 1, 0);
  return 0;
}

static int expect_rejected(lua_State *L, lua_CFunction build,
                           const char *label) {
  int st;
  lua_settop(L, 0);
  lua_pushcfunction(L, build);
  st = lua_pcall(L, 0, 0, 0);
  if (st == LUA_OK) {
    fprintf(stderr, "ACCEPTED %s (FIX FAILED)\n", label);
    return 0;
  }
  if (strstr(lua_tostring(L, -1), "corrupt query plan in bytecode") == NULL) {
    fprintf(stderr, "WRONG ERROR for %s: %s\n", label,
            lua_tostring(L, -1));
    return 0;
  }
  printf("REJECTED %s\n", label);
  return 1;
}

int main(void) {
  lua_State *L = luaL_newstate();
  int ok;
  luaL_openlibs(L);
  ok = expect_rejected(L, build_exploit, "the doubling DAG");
  ok &= expect_rejected(L, build_bad_unary, "a two-operand unary node");
  ok &= expect_rejected(L, build_row_limit, "a row-dependent limit");
  lua_close(L);
  return ok ? 0 : 1;
}
