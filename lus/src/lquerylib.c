/*
** lquerylib.c
** Query execution: the query() iterator, the in-memory provider, the
** __query dispatch, and debug.queryplan
** See Copyright Notice in lua.h
**
** query(q) evaluates the query and returns a fresh iterator over the
** result records, so a stored query runs again on every loop. The
** logical pipeline is fixed: fetch each source, join, where, group,
** having, select and distinct, order, then limit and offset. Both
** providers follow SQL-flavored semantics so the same query text
** returns the same rows whether it runs here or pushes down: a
** comparison with a nil operand is false, nil orders first ascending,
** aggregates over zero rows yield an absent field except count, and a
** nil value never becomes a record field.
*/

#define lquerylib_c
#define LUA_LIB

#include "lprefix.h"

#include <math.h>
#include <string.h>

#include "lua.h"

#include "lauxlib.h"
#include "lobject.h"
#include "lquery.h"
#include "lstate.h"
#include "lualib.h"

/* stand-in table key for nil (and NaN) group and distinct keys */
static const char nilkey_sentinel = 0;

static Query *checkquery(lua_State *L, int arg) {
  luaL_checkany(L, arg);
  if (!lus_isquery(L, arg))
    luaL_typeerror(L, arg, "query");
  return queryvalue(s2v(L->ci->func.p + arg));
}

static void pushqval(lua_State *L, Query *q, int i) {
  setobj2s(L, L->top.p, &q->vals[i]);
  L->top.p++;
}

/* ===================================================================
** Plan analysis: conjuncts and their shapes
** =================================================================== */

typedef struct QConjuncts {
  int nodes[LUS_QMAXNODES];  /* conjunct root node indexes */
  unsigned int mask[LUS_QMAXNODES]; /* sources referenced by each */
  lu_byte opaque[LUS_QMAXNODES];    /* 1 when it holds a host closure */
  lu_byte pushed[LUS_QMAXNODES];    /* 1 once a provider accepted it */
  int n;
} QConjuncts;

/* which sources does the subtree at 'node' reference, and is any part
   of it a host closure? */
static void nodeshape(const QPlan *pl, int node, unsigned int *mask,
                      int *opaque) {
  const QNode *n = &pl->nodes[node];
  switch (n->kind) {
    case QN_COLUMN:
    case QN_ROWVAR:
      *mask |= 1u << n->sub;
      break;
    case QN_CLOSURE:
      *opaque = 1;
      *mask |= ~0u; /* a closure sees every row */
      break;
    case QN_AND:
    case QN_OR:
    case QN_CONCAT:
    case QN_CMP:
      nodeshape(pl, n->a, mask, opaque);
      nodeshape(pl, n->b, mask, opaque);
      break;
    case QN_ARITH:
      nodeshape(pl, n->a, mask, opaque);
      if (n->b != QNODE_NONE)
        nodeshape(pl, n->b, mask, opaque);
      break;
    case QN_NOT:
      nodeshape(pl, n->a, mask, opaque);
      break;
    case QN_AGG:
      if (n->a != QNODE_NONE)
        nodeshape(pl, n->a, mask, opaque);
      break;
    default: /* literals, params, namerefs reference no source */
      break;
  }
}

/* split the where tree at top-level 'and' into conjuncts */
static void splitconjuncts(const QPlan *pl, int node, QConjuncts *c) {
  const QNode *n;
  if (node == (int)QNODE_NONE)
    return;
  n = &pl->nodes[node];
  if (n->kind == QN_AND) {
    splitconjuncts(pl, n->a, c);
    splitconjuncts(pl, n->b, c);
  }
  else {
    unsigned int mask = 0;
    int opaque = 0;
    if (c->n >= LUS_QMAXNODES) /* a validated forest cannot reach this */
      return;
    nodeshape(pl, node, &mask, &opaque);
    c->nodes[c->n] = node;
    c->mask[c->n] = mask;
    c->opaque[c->n] = cast_byte(opaque);
    c->pushed[c->n] = 0;
    c->n++;
  }
}

/* structural node equality, for matching projections to group keys */
static int nodeequal(const QPlan *pl, int a, int b) {
  const QNode *na, *nb;
  if (a == b)
    return 1;
  na = &pl->nodes[a];
  nb = &pl->nodes[b];
  if (na->kind != nb->kind || na->sub != nb->sub)
    return 0;
  switch (na->kind) {
    case QN_COLUMN:
    case QN_NAMEREF:
    case QN_LIT_STR:
      return na->u.s.len == nb->u.s.len &&
             memcmp(pl->pool + na->u.s.off, pl->pool + nb->u.s.off,
                    na->u.s.len) == 0;
    case QN_ROWVAR:
      return 1; /* kind and sub already matched */
    case QN_PARAM:
    case QN_CLOSURE:
      return na->a == nb->a;
    case QN_LIT_NIL:
    case QN_LIT_TRUE:
    case QN_LIT_FALSE:
      return 1;
    case QN_LIT_INT:
      return na->u.i == nb->u.i;
    case QN_LIT_FLT:
      return na->u.n == nb->u.n;
    case QN_AND:
    case QN_OR:
    case QN_CONCAT:
    case QN_CMP:
      return nodeequal(pl, na->a, nb->a) && nodeequal(pl, na->b, nb->b);
    case QN_NOT:
      return nodeequal(pl, na->a, nb->a);
    case QN_ARITH:
      if ((na->b == QNODE_NONE) != (nb->b == QNODE_NONE))
        return 0;
      return nodeequal(pl, na->a, nb->a) &&
             (na->b == QNODE_NONE || nodeequal(pl, na->b, nb->b));
    case QN_AGG:
      if ((na->a == QNODE_NONE) != (nb->a == QNODE_NONE))
        return 0;
      return na->a == QNODE_NONE || nodeequal(pl, na->a, nb->a);
    default:
      return 0;
  }
}

/* does the subtree contain an aggregate node? */
static int hasagg(const QPlan *pl, int node) {
  const QNode *n;
  if (node == (int)QNODE_NONE)
    return 0;
  n = &pl->nodes[node];
  switch (n->kind) {
    case QN_AGG:
      return 1;
    case QN_AND:
    case QN_OR:
    case QN_CONCAT:
    case QN_CMP:
      return hasagg(pl, n->a) || hasagg(pl, n->b);
    case QN_ARITH:
      return hasagg(pl, n->a) ||
             (n->b != QNODE_NONE && hasagg(pl, n->b));
    case QN_NOT:
      return hasagg(pl, n->a);
    default:
      return 0;
  }
}

/*
** In a grouped query, an expression is valid when every row reference
** in it sits inside an aggregate or the whole expression matches a
** group key.
*/
static int groupvalid(const QPlan *pl, int node) {
  const QNode *n = &pl->nodes[node];
  int i;
  for (i = 0; i < pl->h.ngroup; i++) {
    if (nodeequal(pl, node, pl->group[i]))
      return 1;
  }
  switch (n->kind) {
    case QN_AGG:
    case QN_LIT_NIL:
    case QN_LIT_TRUE:
    case QN_LIT_FALSE:
    case QN_LIT_INT:
    case QN_LIT_FLT:
    case QN_LIT_STR:
    case QN_PARAM:
    case QN_NAMEREF:
      return 1;
    case QN_COLUMN:
    case QN_ROWVAR:
    case QN_CLOSURE:
      return 0;
    case QN_AND:
    case QN_OR:
    case QN_CONCAT:
    case QN_CMP:
      return groupvalid(pl, n->a) && groupvalid(pl, n->b);
    case QN_ARITH:
      return groupvalid(pl, n->a) &&
             (n->b == QNODE_NONE || groupvalid(pl, n->b));
    case QN_NOT:
      return groupvalid(pl, n->a);
    default:
      return 0;
  }
}

/* ===================================================================
** Node evaluation
** =================================================================== */

typedef struct QExec {
  lua_State *L;
  Query *q;
  QPlan *pl;
  int tuple;       /* stack index of the current row tuple (0 = none) */
  int grouptuples; /* stack index of the current group's tuples (0 = none) */
  int record;      /* stack index of the output record (0 = none) */
} QExec;

static void eval(QExec *e, int node);

/* push pool string 'name' */
static void pushqstr(lua_State *L, const QPlan *pl, QStr s) {
  lua_pushlstring(L, pl->pool + s.off, s.len);
}

static void evalagg(QExec *e, const QNode *n) {
  lua_State *L = e->L;
  int ntuples;
  int i;
  int savedtuple = e->tuple;
  if (e->grouptuples == 0)
    luaL_error(L, "aggregate evaluated outside a grouped query");
  ntuples = (int)lua_rawlen(L, e->grouptuples);
  if (n->sub == QAGG_COUNT && n->a == QNODE_NONE) { /* count(*) */
    lua_pushinteger(L, ntuples);
    return;
  }
  if (n->sub == QAGG_COUNT) { /* count(expr) counts non-nil values */
    lua_Integer count = 0;
    for (i = 1; i <= ntuples; i++) {
      lua_rawgeti(L, e->grouptuples, i);
      e->tuple = lua_gettop(L);
      eval(e, n->a);
      if (!lua_isnil(L, -1))
        count++;
      lua_pop(L, 2);
    }
    e->tuple = savedtuple;
    lua_pushinteger(L, count);
    return;
  }
  if (n->sub == QAGG_SUM || n->sub == QAGG_AVG) {
    lua_Integer isum = 0;
    lua_Number fsum = 0;
    lua_Integer count = 0;
    int isfloat = 0;
    for (i = 1; i <= ntuples; i++) {
      lua_rawgeti(L, e->grouptuples, i);
      e->tuple = lua_gettop(L);
      eval(e, n->a);
      if (lua_isnil(L, -1)) { /* nil values never aggregate */
        lua_pop(L, 2);
        continue;
      }
      if (lua_type(L, -1) != LUA_TNUMBER)
        luaL_error(L, "cannot aggregate a %s value", luaL_typename(L, -1));
      if (lua_isinteger(L, -1) && !isfloat) {
        lua_Integer v = lua_tointeger(L, -1);
        lua_Integer r = (lua_Integer)((lua_Unsigned)isum + (lua_Unsigned)v);
        if ((isum > 0 && v > 0 && r <= 0) || (isum < 0 && v < 0 && r >= 0))
          luaL_error(L, "integer overflow in sum");
        isum = r;
      }
      else {
        if (!isfloat) {
          fsum = (lua_Number)isum;
          isfloat = 1;
        }
        fsum += lua_tonumber(L, -1);
      }
      count++;
      lua_pop(L, 2);
    }
    e->tuple = savedtuple;
    if (count == 0)
      lua_pushnil(L); /* an empty aggregate has no value */
    else if (n->sub == QAGG_AVG)
      lua_pushnumber(L, (isfloat ? fsum : (lua_Number)isum) /
                            (lua_Number)count);
    else if (isfloat)
      lua_pushnumber(L, fsum);
    else
      lua_pushinteger(L, isum);
    return;
  }
  else { /* min or max: keep the best value in a dedicated slot */
    int best;
    int seen = 0;
    lua_pushnil(L);
    best = lua_gettop(L);
    for (i = 1; i <= ntuples; i++) {
      int take;
      lua_rawgeti(L, e->grouptuples, i);
      e->tuple = lua_gettop(L);
      eval(e, n->a);
      if (lua_isnil(L, -1)) {
        lua_pop(L, 2);
        continue;
      }
      if (!seen)
        take = 1;
      else {
        int ta = lua_type(L, -1);
        int tb = lua_type(L, best);
        if (ta != tb || (ta != LUA_TNUMBER && ta != LUA_TSTRING))
          luaL_error(L, "cannot aggregate a %s value", luaL_typename(L, -1));
        take = (n->sub == QAGG_MIN) ? lua_compare(L, -1, best, LUA_OPLT)
                                    : lua_compare(L, best, -1, LUA_OPLT);
      }
      if (take)
        lua_copy(L, -1, best);
      seen = 1;
      lua_pop(L, 2);
    }
    e->tuple = savedtuple;
    /* the best slot (nil when the group was empty) is the result */
    return;
  }
}

static void eval(QExec *e, int node) {
  lua_State *L = e->L;
  const QPlan *pl = e->pl;
  const QNode *n = &pl->nodes[node];
  switch (n->kind) {
    case QN_LIT_NIL:
      lua_pushnil(L);
      break;
    case QN_LIT_TRUE:
      lua_pushboolean(L, 1);
      break;
    case QN_LIT_FALSE:
      lua_pushboolean(L, 0);
      break;
    case QN_LIT_INT:
      lua_pushinteger(L, n->u.i);
      break;
    case QN_LIT_FLT:
      lua_pushnumber(L, n->u.n);
      break;
    case QN_LIT_STR:
      pushqstr(L, pl, n->u.s);
      break;
    case QN_PARAM:
      pushqval(L, e->q, e->q->nsources + n->a);
      break;
    case QN_ROWVAR:
      if (e->tuple == 0)
        luaL_error(L, "row reference outside rows");
      lua_rawgeti(L, e->tuple, n->sub + 1);
      break;
    case QN_COLUMN: {
      if (e->tuple == 0)
        luaL_error(L, "row reference outside rows");
      lua_rawgeti(L, e->tuple, n->sub + 1);
      if (!lua_istable(L, -1))
        luaL_error(L, "query source row is not a record");
      pushqstr(L, pl, n->u.s);
      lua_gettable(L, -2);
      lua_remove(L, -2);
      break;
    }
    case QN_CLOSURE: {
      int i;
      if (e->tuple == 0)
        luaL_error(L, "row reference outside rows");
      pushqval(L, e->q, e->q->nsources + n->a);
      for (i = 0; i < e->q->nsources; i++)
        lua_rawgeti(L, e->tuple, i + 1);
      lua_call(L, e->q->nsources, 1);
      break;
    }
    case QN_NAMEREF: {
      if (e->record == 0)
        luaL_error(L, "unknown order key '%s'",
                   lua_pushlstring(L, pl->pool + n->u.s.off, n->u.s.len));
      pushqstr(L, pl, n->u.s);
      lua_gettable(L, e->record);
      break;
    }
    case QN_AND:
      eval(e, n->a);
      if (lua_toboolean(L, -1)) {
        lua_pop(L, 1);
        eval(e, n->b);
      }
      break;
    case QN_OR:
      eval(e, n->a);
      if (!lua_toboolean(L, -1)) {
        lua_pop(L, 1);
        eval(e, n->b);
      }
      break;
    case QN_NOT:
      eval(e, n->a);
      lua_pushboolean(L, !lua_toboolean(L, -1));
      lua_remove(L, -2);
      break;
    case QN_CMP: {
      int res;
      eval(e, n->a);
      eval(e, n->b);
      if (lua_isnil(L, -1) || lua_isnil(L, -2)) {
        /* SQL-flavored: a comparison with nil is false */
        res = 0;
      }
      else {
        switch (n->sub) {
          case QCMP_EQ: res = lua_compare(L, -2, -1, LUA_OPEQ); break;
          case QCMP_NE: res = !lua_compare(L, -2, -1, LUA_OPEQ); break;
          case QCMP_LT: res = lua_compare(L, -2, -1, LUA_OPLT); break;
          case QCMP_LE: res = lua_compare(L, -2, -1, LUA_OPLE); break;
          case QCMP_GT: res = lua_compare(L, -1, -2, LUA_OPLT); break;
          default: res = lua_compare(L, -1, -2, LUA_OPLE); break;
        }
      }
      lua_pop(L, 2);
      lua_pushboolean(L, res);
      break;
    }
    case QN_ARITH: {
      static const int ops[] = {LUA_OPADD, LUA_OPSUB,  LUA_OPMUL, LUA_OPDIV,
                                LUA_OPIDIV, LUA_OPMOD, LUA_OPPOW, LUA_OPUNM};
      eval(e, n->a);
      if (n->b != QNODE_NONE)
        eval(e, n->b);
      lua_arith(L, ops[n->sub]);
      break;
    }
    case QN_CONCAT:
      eval(e, n->a);
      eval(e, n->b);
      lua_concat(L, 2);
      break;
    case QN_AGG:
      evalagg(e, n);
      break;
    default:
      luaL_error(L, "corrupt query plan");
  }
}

/* ===================================================================
** Source fetching
** =================================================================== */

/* provider classification for one source value at 'srcidx' */
#define QP_MEMORY 0
#define QP_METAMETHOD 1
#define QP_NATIVE 2

static int classify_source(lua_State *L, int srcidx,
                           const lus_QueryProvider **pp) {
  if (luaL_getmetafield(L, srcidx, "__queryprovider") != LUA_TNIL) {
    if (pp != NULL)
      *pp = (const lus_QueryProvider *)lua_touserdata(L, -1);
    lua_pop(L, 1);
    return QP_NATIVE;
  }
  if (luaL_getmetafield(L, srcidx, "__query") != LUA_TNIL) {
    lua_pop(L, 1);
    return QP_METAMETHOD;
  }
  return QP_MEMORY;
}

/*
** Fetch every row of source 'i' into an array pushed on the stack.
** A plain table is an array of records. Any value whose metatable
** carries __query supplies its own iterator: __query(source, q, i)
** must return a function yielding one row per call.
*/
static void fetch_source(lua_State *L, Query *q, int i, int qidx,
                         QConjuncts *conj) {
  int srcidx, rowsidx;
  int kind;
  const lus_QueryProvider *provider = NULL;
  lua_Integer k;
  pushqval(L, q, i);
  srcidx = lua_gettop(L);
  kind = classify_source(L, srcidx, &provider);
  if (kind == QP_NATIVE) {
    /* offer this source's own conjuncts; accepted ones push down and
       never run again in memory */
    const lus_QueryNode *pushed[LUS_QMAXNODES];
    int npushed = 0;
    int c;
    QPlan *pl = queryplan(q);
    for (c = 0; c < conj->n; c++) {
      if (conj->mask[c] == (1u << i) && !conj->opaque[c]) {
        const lus_QueryNode *node = &pl->nodes[conj->nodes[c]];
        if (provider->accepts(L, q, node)) {
          pushed[npushed++] = node;
          conj->pushed[c] = 1;
        }
      }
    }
    provider->open(L, q, i + 1, pushed, npushed);
    if (!lua_isfunction(L, -1))
      luaL_error(L, "the query provider must push a row iterator");
    lua_newtable(L);
    rowsidx = lua_gettop(L);
    for (k = 1;; k++) {
      lua_pushvalue(L, rowsidx - 1); /* the iterator */
      lua_call(L, 0, 1);
      if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        break;
      }
      lua_rawseti(L, rowsidx, k);
    }
    lua_remove(L, srcidx + 1); /* the iterator */
    lua_remove(L, srcidx);     /* the source */
    return;
  }
  if (kind == QP_METAMETHOD) {
    luaL_getmetafield(L, srcidx, "__query");
    lua_pushvalue(L, srcidx);
    lua_pushvalue(L, qidx);
    lua_pushinteger(L, i + 1);
    lua_call(L, 3, 1);
    if (!lua_isfunction(L, -1))
      luaL_error(L, "'__query' must return a function");
    lua_newtable(L);
    rowsidx = lua_gettop(L);
    for (k = 1;; k++) {
      lua_pushvalue(L, rowsidx - 1); /* the iterator */
      lua_call(L, 0, 1);
      if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        break;
      }
      lua_rawseti(L, rowsidx, k);
    }
    lua_remove(L, srcidx + 1); /* the iterator */
    lua_remove(L, srcidx);     /* the source */
    return;
  }
  if (!lua_istable(L, srcidx))
    luaL_error(L, "value of type '%s' is not queryable",
               luaL_typename(L, srcidx));
  lua_newtable(L);
  rowsidx = lua_gettop(L);
  for (k = 1;; k++) {
    lua_geti(L, srcidx, k);
    if (lua_isnil(L, -1)) {
      lua_pop(L, 1);
      break;
    }
    if (!lua_istable(L, -1))
      luaL_error(L, "query source row %d is not a record", (int)k);
    lua_rawseti(L, rowsidx, k);
  }
  lua_remove(L, srcidx);
}

/* ===================================================================
** Execution pipeline
** =================================================================== */

/* normalize a value for use as a group or distinct key: nil and NaN
   become the sentinel, so grouping never indexes a table with them */
static void normalizekey(lua_State *L, int strict) {
  int t = lua_type(L, -1);
  if (t == LUA_TNIL) {
    lua_pop(L, 1);
    lua_pushlightuserdata(L, (void *)&nilkey_sentinel);
    return;
  }
  if (t == LUA_TNUMBER && !lua_isinteger(L, -1)) {
    lua_Number v = lua_tonumber(L, -1);
    if (v != v) { /* NaN groups with nil, matching SQLite's storage */
      lua_pop(L, 1);
      lua_pushlightuserdata(L, (void *)&nilkey_sentinel);
      return;
    }
  }
  if (strict && t != LUA_TBOOLEAN && t != LUA_TNUMBER && t != LUA_TSTRING &&
      t != LUA_TENUM)
    luaL_error(L, "query group key must be a primitive value, got %s",
               lua_typename(L, t));
}

/*
** Deduplicate through a nested key map at 'mapidx' over the 'nkeys'
** values on top of the stack (consumed). Returns 1 when the key
** combination is new.
*/
static int dedup(lua_State *L, int mapidx, int nkeys) {
  int level = mapidx;
  int base = lua_gettop(L) - nkeys + 1;
  int k;
  int fresh = 0;
  for (k = 0; k < nkeys; k++) {
    lua_pushvalue(L, base + k);
    lua_rawget(L, level);
    if (lua_isnil(L, -1)) {
      lua_pop(L, 1);
      lua_newtable(L);
      lua_pushvalue(L, base + k);
      lua_pushvalue(L, -2);
      lua_rawset(L, level);
      fresh = 1;
    }
    level = lua_gettop(L);
  }
  /* mark the leaf so an exact repeat is recognized even when every
     level already existed */
  lua_pushboolean(L, 1);
  lua_rawget(L, level);
  if (lua_isnil(L, -1)) {
    fresh = 1;
    lua_pop(L, 1);
    lua_pushboolean(L, 1);
    lua_pushboolean(L, 1);
    lua_rawset(L, level);
  }
  else
    lua_pop(L, 1);
  lua_settop(L, base - 1);
  return fresh;
}

/* evaluate limit or offset from its plan node */
static lua_Integer evalcount(QExec *e, int node, const char *what) {
  lua_State *L = e->L;
  lua_Integer v;
  int isint;
  if (node == (int)QNODE_NONE)
    return -1;
  eval(e, node);
  v = lua_tointegerx(L, -1, &isint);
  if (!isint)
    luaL_error(L, "query %s must be a number", what);
  if (v < 0)
    luaL_error(L, "query %s must be a nonnegative number", what);
  lua_pop(L, 1);
  return v;
}

/*
** Compare records ia and ib (1-based) through their precomputed order
** keys at 'keysidx'. nil orders first ascending, numbers and strings
** compare naturally, false sorts before true, and anything else (or a
** type mismatch) raises.
*/
static int ordercompare(lua_State *L, const QPlan *pl, int keysidx,
                        lua_Integer ia, lua_Integer ib) {
  int k;
  int res = 0;
  lua_rawgeti(L, keysidx, ia);
  lua_rawgeti(L, keysidx, ib);
  for (k = 0; k < pl->h.norder && res == 0; k++) {
    int ta, tb;
    lua_rawgeti(L, -2, k + 1);
    lua_rawgeti(L, -2, k + 1);
    ta = lua_type(L, -2);
    tb = lua_type(L, -1);
    if (ta == LUA_TNIL || tb == LUA_TNIL)
      res = (ta == tb) ? 0 : (ta == LUA_TNIL ? -1 : 1);
    else if (ta != tb)
      luaL_error(L, "cannot order rows on a %s value", lua_typename(L, tb));
    else if (ta == LUA_TNUMBER || ta == LUA_TSTRING)
      res = lua_compare(L, -2, -1, LUA_OPLT)
                ? -1
                : (lua_compare(L, -1, -2, LUA_OPLT) ? 1 : 0);
    else if (ta == LUA_TBOOLEAN) {
      int ba = lua_toboolean(L, -2), bb = lua_toboolean(L, -1);
      res = (ba == bb) ? 0 : (ba ? 1 : -1);
    }
    else
      luaL_error(L, "cannot order rows on a %s value", lua_typename(L, ta));
    if (pl->order[k].desc)
      res = -res;
    lua_pop(L, 2);
  }
  lua_pop(L, 2);
  return res;
}

/* stable merge sort over a 0-based permutation array of record ids */
static void mergesort(lua_State *L, const QPlan *pl, int keysidx,
                      lua_Integer *perm, lua_Integer *tmp, lua_Integer lo,
                      lua_Integer hi) {
  lua_Integer mid, i, a, b;
  if (hi - lo < 1)
    return;
  mid = lo + (hi - lo) / 2;
  mergesort(L, pl, keysidx, perm, tmp, lo, mid);
  mergesort(L, pl, keysidx, perm, tmp, mid + 1, hi);
  a = lo;
  b = mid + 1;
  for (i = lo; i <= hi; i++) {
    if (a <= mid &&
        (b > hi || ordercompare(L, pl, keysidx, perm[a], perm[b]) <= 0))
      tmp[i] = perm[a++];
    else
      tmp[i] = perm[b++];
  }
  memcpy(perm + lo, tmp + lo, (size_t)(hi - lo + 1) * sizeof(lua_Integer));
}

/* build the output record for the current context */
static void buildrecord(QExec *e) {
  lua_State *L = e->L;
  const QPlan *pl = e->pl;
  int i;
  if (pl->h.nselect == 0) { /* single source: pass the row through */
    lua_rawgeti(L, e->tuple, 1);
    return;
  }
  if (pl->h.nselect == 1 && pl->sel[0].rowvar && pl->sel[0].name.len == 0) {
    eval(e, pl->sel[0].node); /* the source record itself */
    return;
  }
  lua_createtable(L, 0, pl->h.nselect);
  for (i = 0; i < pl->h.nselect; i++) {
    const QSelItem *it = &pl->sel[i];
    if (it->name.len == 0)
      luaL_error(L, "a whole-row projection needs an 'as' name");
    eval(e, it->node);
    if (lua_isnil(L, -1)) { /* nil never becomes a record field */
      lua_pop(L, 1);
      continue;
    }
    pushqstr(L, pl, it->name);
    lua_insert(L, -2);
    lua_settable(L, -3);
  }
}

/*
** Run the full pipeline for the query at stack index 'qidx' and leave
** the array of result records on the stack top.
*/
static void execquery(lua_State *L, Query *q, int qidx) {
  QPlan *pl = queryplan(q);
  QConjuncts conj;
  QExec e;
  int nsrc = q->nsources;
  int grouped;
  int i;
  int srcrows; /* stack: array of per-source row arrays */
  int tuples;  /* stack: array of passing tuples */
  int records; /* stack: array of output records */
  int ctxs;    /* stack: per-record context tuple, for order keys */
  int done = 0;
  lua_Integer ntuples = 0, nrecords = 0;
  lua_Integer counters[LUS_QMAXSOURCES];
  lua_Integer sizes[LUS_QMAXSOURCES];
  /* eval recurses to LUS_QMAXDEPTH, and the grouping and distinct
     phases hold one live table per group key and per projection */
  luaL_checkstack(L,
                  3 * LUS_QMAXDEPTH + 2 * (pl->h.ngroup + pl->h.nselect) + 40,
                  "query too complex");
  memset(&e, 0, sizeof(e));
  e.L = L;
  e.q = q;
  e.pl = pl;
  conj.n = 0;
  splitconjuncts(pl, pl->h.where_root, &conj);
  grouped = pl->h.ngroup > 0 || hasagg(pl, pl->h.having_root) ? 1 : 0;
  for (i = 0; i < pl->h.nselect && !grouped; i++)
    grouped = hasagg(pl, pl->sel[i].node);
  if (grouped) { /* validate projections against the group keys */
    for (i = 0; i < pl->h.nselect; i++) {
      if (!groupvalid(pl, pl->sel[i].node))
        luaL_error(L, "a grouped projection must be an aggregate or a "
                      "group key");
    }
    if (pl->h.having_root != QNODE_NONE && !groupvalid(pl, pl->h.having_root))
      luaL_error(L, "'having' must use aggregates or group keys");
    if (pl->h.nselect == 0)
      luaL_error(L, "a grouped query needs a 'select' clause");
  }
  /* fetch every source */
  lua_newtable(L);
  srcrows = lua_gettop(L);
  for (i = 0; i < nsrc; i++) {
    fetch_source(L, q, i, qidx, &conj);
    sizes[i] = (lua_Integer)lua_rawlen(L, -1);
    lua_rawseti(L, srcrows, i + 1);
    counters[i] = 1;
    if (sizes[i] == 0)
      done = 1; /* an empty source: the cross product is empty */
  }
  /* join loop: walk the cross product, filter with the conjuncts */
  lua_newtable(L);
  tuples = lua_gettop(L);
  while (!done) {
    int c;
    int pass = 1;
    lua_createtable(L, nsrc, 0);
    for (i = 0; i < nsrc; i++) {
      lua_rawgeti(L, srcrows, i + 1);
      lua_rawgeti(L, -1, counters[i]);
      lua_remove(L, -2);
      lua_rawseti(L, -2, i + 1);
    }
    e.tuple = lua_gettop(L);
    for (c = 0; c < conj.n && pass; c++) {
      if (conj.pushed[c])
        continue; /* a provider already applied it */
      eval(&e, conj.nodes[c]);
      pass = lua_toboolean(L, -1);
      lua_pop(L, 1);
    }
    e.tuple = 0;
    if (pass)
      lua_rawseti(L, tuples, ++ntuples);
    else
      lua_pop(L, 1);
    /* advance the odometer */
    for (i = nsrc - 1; i >= 0; i--) {
      counters[i]++;
      if (counters[i] <= sizes[i])
        break;
      counters[i] = 1;
      if (i == 0)
        done = 1;
    }
  }
  lua_newtable(L);
  records = lua_gettop(L);
  lua_newtable(L);
  ctxs = lua_gettop(L);
  if (!grouped) {
    lua_Integer t;
    for (t = 1; t <= ntuples; t++) {
      lua_rawgeti(L, tuples, t);
      e.tuple = lua_gettop(L);
      buildrecord(&e);
      lua_rawseti(L, records, ++nrecords);
      lua_pushvalue(L, e.tuple);
      lua_rawseti(L, ctxs, nrecords);
      lua_pop(L, 1);
      e.tuple = 0;
    }
  }
  else {
    /* group the tuples: a nested key map locates each group's array */
    int gmap, garr;
    lua_Integer ngroups = 0, t, g;
    lua_newtable(L);
    gmap = lua_gettop(L);
    lua_newtable(L);
    garr = lua_gettop(L);
    for (t = 1; t <= ntuples; t++) {
      int level = gmap;
      int k;
      lua_rawgeti(L, tuples, t);
      e.tuple = lua_gettop(L);
      for (k = 0; k < pl->h.ngroup; k++) {
        eval(&e, pl->group[k]);
        normalizekey(L, 1);
        lua_pushvalue(L, -1);
        lua_rawget(L, level);
        if (lua_isnil(L, -1)) {
          lua_pop(L, 1);
          lua_newtable(L);
          lua_pushvalue(L, -2);
          lua_pushvalue(L, -2);
          lua_rawset(L, level);
        }
        lua_remove(L, -2); /* drop the key, keep the next level */
        level = lua_gettop(L);
      }
      /* the leaf level keeps the group's tuple array under 'true' */
      lua_pushboolean(L, 1);
      lua_rawget(L, level);
      if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushboolean(L, 1);
        lua_pushvalue(L, -2);
        lua_rawset(L, level);
        lua_pushvalue(L, -1);
        lua_rawseti(L, garr, ++ngroups);
      }
      lua_pushvalue(L, e.tuple);
      lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
      lua_settop(L, e.tuple - 1);
      e.tuple = 0;
    }
    if (ngroups == 0 && pl->h.ngroup == 0) {
      /* aggregates over an empty input still yield one record */
      lua_newtable(L);
      lua_rawseti(L, garr, ++ngroups);
    }
    for (g = 1; g <= ngroups; g++) {
      int keep = 1;
      lua_rawgeti(L, garr, g);
      e.grouptuples = lua_gettop(L);
      lua_rawgeti(L, e.grouptuples, 1); /* first tuple (nil when empty) */
      e.tuple = lua_istable(L, -1) ? lua_gettop(L) : 0;
      if (pl->h.having_root != QNODE_NONE) {
        eval(&e, pl->h.having_root);
        keep = lua_toboolean(L, -1);
        lua_pop(L, 1);
      }
      if (keep) {
        buildrecord(&e);
        lua_rawseti(L, records, ++nrecords);
        if (e.tuple != 0)
          lua_pushvalue(L, e.tuple);
        else
          lua_pushboolean(L, 0);
        lua_rawseti(L, ctxs, nrecords);
      }
      lua_settop(L, e.grouptuples - 1);
      e.tuple = 0;
      e.grouptuples = 0;
    }
    lua_remove(L, garr);
    lua_remove(L, gmap);
  }
  /* distinct: dedupe the projected records by their field values */
  if (pl->h.flags & QF_DISTINCT) {
    int dmap, newrec, newctx;
    lua_Integer kept = 0, r;
    lua_newtable(L);
    dmap = lua_gettop(L);
    lua_newtable(L);
    newrec = lua_gettop(L);
    lua_newtable(L);
    newctx = lua_gettop(L);
    for (r = 1; r <= nrecords; r++) {
      int fresh;
      lua_rawgeti(L, records, r);
      e.record = lua_gettop(L);
      if (pl->h.nselect > 0) {
        for (i = 0; i < pl->h.nselect; i++) {
          if (pl->sel[i].name.len > 0) {
            pushqstr(L, pl, pl->sel[i].name);
            lua_gettable(L, e.record);
          }
          else /* a lone whole-row projection dedupes by identity */
            lua_pushvalue(L, e.record);
          normalizekey(L, 0);
        }
        fresh = dedup(L, dmap, pl->h.nselect);
      }
      else {
        lua_pushvalue(L, e.record);
        fresh = dedup(L, dmap, 1);
      }
      if (fresh) {
        lua_pushvalue(L, e.record);
        lua_rawseti(L, newrec, ++kept);
        lua_rawgeti(L, ctxs, r);
        lua_rawseti(L, newctx, kept);
      }
      lua_settop(L, newctx);
      e.record = 0;
    }
    lua_pushvalue(L, newrec);
    lua_replace(L, records);
    lua_pushvalue(L, newctx);
    lua_replace(L, ctxs);
    lua_pop(L, 3); /* dmap, newrec, newctx */
    nrecords = kept;
  }
  /* order */
  if (pl->h.norder > 0 && nrecords > 1) {
    int keysidx;
    lua_Integer *perm, *tmp;
    lua_Integer r;
    lua_newtable(L);
    keysidx = lua_gettop(L);
    for (r = 1; r <= nrecords; r++) {
      int k;
      int pertab;
      lua_createtable(L, pl->h.norder, 0);
      pertab = lua_gettop(L);
      lua_rawgeti(L, records, r);
      e.record = lua_gettop(L);
      lua_rawgeti(L, ctxs, r);
      e.tuple = lua_istable(L, -1) ? lua_gettop(L) : 0;
      for (k = 0; k < pl->h.norder; k++) {
        eval(&e, pl->order[k].node);
        if (lua_type(L, -1) == LUA_TNUMBER && !lua_isinteger(L, -1) &&
            lua_tonumber(L, -1) != lua_tonumber(L, -1)) {
          lua_pop(L, 1); /* NaN orders with nil */
          lua_pushnil(L);
        }
        lua_rawseti(L, pertab, k + 1);
      }
      lua_settop(L, pertab);
      e.record = 0;
      e.tuple = 0;
      lua_rawseti(L, keysidx, r);
    }
    perm = (lua_Integer *)lua_newuserdatauv(
        L, (size_t)nrecords * 2 * sizeof(lua_Integer), 0);
    tmp = perm + nrecords;
    for (r = 0; r < nrecords; r++)
      perm[r] = r + 1; /* record ids stay 1-based */
    mergesort(L, pl, keysidx, perm, tmp, 0, nrecords - 1);
    lua_newtable(L); /* the sorted records */
    for (r = 1; r <= nrecords; r++) {
      lua_rawgeti(L, records, perm[r - 1]);
      lua_rawseti(L, -2, r);
    }
    lua_replace(L, records);
    lua_pop(L, 2); /* the permutation block and the keys */
  }
  /* limit and offset */
  {
    lua_Integer limit = evalcount(&e, pl->h.limit_node, "limit");
    lua_Integer offset = evalcount(&e, pl->h.offset_node, "offset");
    if (limit >= 0 || offset > 0) {
      lua_Integer from = (offset > 0) ? offset + 1 : 1;
      lua_Integer to = (limit >= 0) ? from + limit - 1 : nrecords;
      lua_Integer r, out = 0;
      if (to > nrecords)
        to = nrecords;
      lua_newtable(L);
      for (r = from; r <= to; r++) {
        lua_rawgeti(L, records, r);
        lua_rawseti(L, -2, ++out);
      }
      lua_replace(L, records);
    }
  }
  lua_pushvalue(L, records);
}

/* ===================================================================
** The query iterator and debug.queryplan
** =================================================================== */

static int query_next(lua_State *L) {
  lua_Integer i = lua_tointeger(L, lua_upvalueindex(2)) + 1;
  lua_pushinteger(L, i);
  lua_replace(L, lua_upvalueindex(2));
  lua_rawgeti(L, lua_upvalueindex(1), i);
  return 1;
}

static int lusQ_query(lua_State *L) {
  Query *q = checkquery(L, 1);
  lua_settop(L, 1);
  execquery(L, q, 1);
  lua_pushinteger(L, 0);
  lua_pushcclosure(L, query_next, 2);
  return 1;
}

static int lusQ_queryplan(lua_State *L) {
  Query *q = checkquery(L, 1);
  QPlan *pl = queryplan(q);
  QConjuncts conj;
  luaL_Buffer b;
  int i, c;
  lua_settop(L, 1);
  conj.n = 0;
  splitconjuncts(pl, pl->h.where_root, &conj);
  luaL_buffinit(L, &b);
  lua_pushfstring(L, "query: %d source(s), %d conjunct(s)\n",
                  (int)pl->h.nsources, conj.n);
  luaL_addvalue(&b);
  for (i = 0; i < pl->h.nsources; i++) {
    int kind;
    int pushed = 0;
    const lus_QueryProvider *provider = NULL;
    const char *kindname;
    pushqval(L, q, i);
    kind = classify_source(L, -1, &provider);
    lua_pop(L, 1);
    for (c = 0; c < conj.n; c++) {
      if (conj.mask[c] == (1u << i) && !conj.opaque[c]) {
        if (kind == QP_NATIVE &&
            provider->accepts(L, q, &pl->nodes[conj.nodes[c]])) {
          pushed++;
          conj.pushed[c] = 1;
        }
      }
    }
    kindname = (kind == QP_NATIVE)       ? "native"
               : (kind == QP_METAMETHOD) ? "__query"
                                         : "memory";
    lua_pushlstring(L, pl->pool + pl->sources[i].alias.off,
                    pl->sources[i].alias.len);
    lua_pushfstring(L, "  %s: %s, %d pushed conjunct(s)\n",
                    lua_tostring(L, -1), kindname, pushed);
    lua_remove(L, -2);
    luaL_addvalue(&b);
  }
  for (c = 0; c < conj.n; c++) {
    lua_pushfstring(L, "  conjunct %d: %s\n", c + 1,
                    conj.pushed[c]   ? "pushed down"
                    : conj.opaque[c] ? "in memory (host closure)"
                                     : "in memory (translatable)");
    luaL_addvalue(&b);
  }
  luaL_pushresult(&b);
  return 1;
}

LUAMOD_API int luaopen_query(lua_State *L) {
  /* debug.queryplan, when the debug library is open */
  if (lua_getglobal(L, "debug") == LUA_TTABLE) {
    lua_pushcfunction(L, lusQ_queryplan);
    lua_setfield(L, -2, "queryplan");
  }
  lua_pop(L, 1);
  lua_pushcfunction(L, lusQ_query);
  return 1;
}
