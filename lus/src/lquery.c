/*
** lquery.c
** First-class query objects (LUA_TQUERY)
** See Copyright Notice in lua.h
*/

#define lquery_c
#define LUA_CORE

#include "lprefix.h"

#include <string.h>

#include "lua.h"

#include "ldebug.h"
#include "ldo.h"
#include "lgc.h"
#include "lmem.h"
#include "lobject.h"
#include "lquery.h"
#include "lstate.h"
#include "lstring.h"

#define align8(x) (((x) + 7u) & ~cast(size_t, 7u))

void luaQ_wirelayout(const QPlanHeader *h, QWireLayout *w) {
  size_t pos = align8(sizeof(QPlanHeader));
  w->sources = pos;
  pos = align8(pos + h->nsources * sizeof(QSource));
  w->nodes = pos;
  pos = align8(pos + h->nnodes * sizeof(QNode));
  w->sel = pos;
  pos = align8(pos + h->nselect * sizeof(QSelItem));
  w->group = pos;
  pos = align8(pos + h->ngroup * sizeof(unsigned short));
  w->order = pos;
  pos = align8(pos + h->norder * sizeof(QOrderItem));
  w->pool = pos;
  pos += h->poolsize;
  w->total = pos;
}

/* a string range must sit inside the pool */
static int okstr(const QPlanHeader *h, QStr s) {
  return s.off <= h->poolsize && s.len <= h->poolsize - s.off;
}

/* a child reference must point at an earlier node (or be absent) */
static int okchild(unsigned short child, int parent, int allownone) {
  if (child == QNODE_NONE)
    return allownone;
  return child < parent;
}

static int oknoderef(unsigned short node, const QPlanHeader *h,
                     int allownone) {
  if (node == QNODE_NONE)
    return allownone;
  return node < h->nnodes;
}

/*
** Validate a decoded plan. Dumped chunks are untrusted input, so
** every index, range, and count is checked before the plan is used.
** Children strictly precede parents, so the node array is a DAG and
** one forward pass computes exact depths.
*/
static int validateplan(lua_State *L, QPlan *pl) {
  const QPlanHeader *h = &pl->h;
  int i;
  lu_byte *depth;
  if (h->version != LUS_QPLAN_VERSION)
    return 0;
  if (h->nsources < 1 || h->nsources > LUS_QMAXSOURCES ||
      h->noperands > LUS_QMAXOPERANDS || h->nnodes > LUS_QMAXNODES ||
      h->nselect > LUS_QMAXSELECT || h->ngroup > LUS_QMAXGROUP ||
      h->norder > LUS_QMAXORDER)
    return 0;
  for (i = 0; i < h->nsources; i++) {
    if (!okstr(h, pl->sources[i].alias))
      return 0;
  }
  if (!oknoderef(h->where_root, h, 1) || !oknoderef(h->having_root, h, 1) ||
      !oknoderef(h->limit_node, h, 1) || !oknoderef(h->offset_node, h, 1))
    return 0;
  for (i = 0; i < h->nselect; i++) {
    if (!oknoderef(pl->sel[i].node, h, 0) || !okstr(h, pl->sel[i].name))
      return 0;
  }
  for (i = 0; i < h->ngroup; i++) {
    if (!oknoderef(pl->group[i], h, 0))
      return 0;
  }
  for (i = 0; i < h->norder; i++) {
    if (!oknoderef(pl->order[i].node, h, 0))
      return 0;
  }
  depth = luaM_newvector(L, h->nnodes ? h->nnodes : 1, lu_byte);
  for (i = 0; i < h->nnodes; i++) {
    const QNode *n = &pl->nodes[i];
    int da = 0, db = 0;
    int ok = 1;
    switch (n->kind) {
      case QN_COLUMN:
      case QN_ROWVAR:
        ok = (n->sub < h->nsources) &&
             (n->kind == QN_ROWVAR || okstr(h, n->u.s));
        break;
      case QN_PARAM:
      case QN_CLOSURE:
        ok = (n->a < h->noperands);
        break;
      case QN_NAMEREF:
      case QN_LIT_STR:
        ok = okstr(h, n->u.s);
        break;
      case QN_LIT_NIL:
      case QN_LIT_TRUE:
      case QN_LIT_FALSE:
      case QN_LIT_INT:
      case QN_LIT_FLT:
        break;
      case QN_AND:
      case QN_OR:
      case QN_CONCAT:
        ok = okchild(n->a, i, 0) && okchild(n->b, i, 0);
        break;
      case QN_NOT:
        ok = okchild(n->a, i, 0);
        break;
      case QN_CMP:
        ok = (n->sub <= QCMP_GE) && okchild(n->a, i, 0) && okchild(n->b, i, 0);
        break;
      case QN_ARITH:
        ok = (n->sub <= QAR_UNM) && okchild(n->a, i, 0) &&
             okchild(n->b, i, n->sub == QAR_UNM);
        break;
      case QN_AGG:
        ok = (n->sub <= QAGG_MAX) &&
             okchild(n->a, i, n->sub == QAGG_COUNT);
        break;
      default:
        ok = 0;
        break;
    }
    if (ok) { /* depth of this node, from its (already computed) children */
      switch (n->kind) {
        case QN_AND:
        case QN_OR:
        case QN_CONCAT:
        case QN_CMP:
          da = depth[n->a];
          db = depth[n->b];
          break;
        case QN_ARITH:
          da = depth[n->a];
          db = (n->b != QNODE_NONE) ? depth[n->b] : 0;
          break;
        case QN_NOT:
          da = depth[n->a];
          break;
        case QN_AGG:
          da = (n->a != QNODE_NONE) ? depth[n->a] : 0;
          break;
        default:
          break;
      }
      if (da >= LUS_QMAXDEPTH || db >= LUS_QMAXDEPTH)
        ok = 0;
      else
        depth[i] = cast_byte(1 + (da > db ? da : db));
    }
    if (!ok) {
      luaM_freearray(L, depth, h->nnodes ? h->nnodes : 1);
      return 0;
    }
  }
  /*
  ** The node array must be a forest: every node is referenced at most
  ** once, by one parent's child edge or one clause root. The compiler
  ** only ever produces this shape, since each node is built once and
  ** referenced once. Rejecting shared children is what keeps a plan
  ** from a dumped chunk from expanding exponentially during the
  ** conjunct split and the recursive plan walkers, where the traversal
  ** count is the number of root-to-leaf paths rather than the node
  ** count. Reuse the 'depth' buffer as a reference counter.
  */
  memset(depth, 0, cast_sizet(h->nnodes ? h->nnodes : 1));
  {
    int j;
#define QREF(idx)                                       \
  do {                                                  \
    unsigned short qref_ = (idx);                       \
    if (qref_ != QNODE_NONE) {                          \
      if (++depth[qref_] > 1) {                         \
        luaM_freearray(L, depth, h->nnodes ? h->nnodes : 1); \
        return 0;                                       \
      }                                                 \
    }                                                   \
  } while (0)
    QREF(h->where_root);
    QREF(h->having_root);
    QREF(h->limit_node);
    QREF(h->offset_node);
    for (j = 0; j < h->nselect; j++)
      QREF(pl->sel[j].node);
    for (j = 0; j < h->ngroup; j++)
      QREF(pl->group[j]);
    for (j = 0; j < h->norder; j++)
      QREF(pl->order[j].node);
    for (j = 0; j < h->nnodes; j++) {
      const QNode *n = &pl->nodes[j];
      switch (n->kind) {
        case QN_AND:
        case QN_OR:
        case QN_CONCAT:
        case QN_CMP:
          QREF(n->a);
          QREF(n->b);
          break;
        case QN_ARITH:
          QREF(n->a);
          if (n->b != QNODE_NONE)
            QREF(n->b);
          break;
        case QN_NOT:
          QREF(n->a);
          break;
        case QN_AGG:
          if (n->a != QNODE_NONE)
            QREF(n->a);
          break;
        default:
          break;
      }
    }
#undef QREF
  }
  luaM_freearray(L, depth, h->nnodes ? h->nnodes : 1);
  return 1;
}

/*
** Decode a wire blob into an owned QPlan block: one allocation holding
** the QPlan struct followed by a copy of the whole wire image, with
** the section pointers set from the shared layout.
*/
static QPlan *decodeplan(lua_State *L, const char *wire, size_t wirelen,
                         size_t *psize) {
  QPlanHeader h;
  QWireLayout w;
  QPlan *pl;
  char *img;
  size_t headoff = align8(sizeof(QPlan));
  if (wirelen < sizeof(QPlanHeader))
    return NULL;
  memcpy(&h, wire, sizeof(QPlanHeader));
  if (h.nsources > LUS_QMAXSOURCES || h.nnodes > LUS_QMAXNODES ||
      h.poolsize > wirelen)
    return NULL; /* cheap caps before computing the layout */
  luaQ_wirelayout(&h, &w);
  if (w.total != wirelen)
    return NULL;
  pl = cast(QPlan *, luaM_malloc_(L, headoff + wirelen, LUA_TQUERY));
  img = cast_charp(pl) + headoff;
  memcpy(img, wire, wirelen);
  pl->h = h;
  pl->sources = cast(QSource *, img + w.sources);
  pl->nodes = cast(QNode *, img + w.nodes);
  pl->sel = cast(QSelItem *, img + w.sel);
  pl->group = cast(unsigned short *, img + w.group);
  pl->order = cast(QOrderItem *, img + w.order);
  pl->pool = img + w.pool;
  *psize = headoff + wirelen;
  if (!validateplan(L, pl)) {
    luaM_freemem(L, pl, headoff + wirelen);
    return NULL;
  }
  return pl;
}

/*
** Build a query object at 'ra' from the plan blob and the run of
** values starting at 'base' (nsrc sources, then nops operands). The
** object is fully initialized (all value slots nil) before any
** further allocation, and anchored on the stack while the plan block
** is allocated, so an emergency collection can never see a garbage
** slot or sweep the object.
*/
void luaQ_build(lua_State *L, StkId ra, TString *blob, StkId base, int nsrc,
                int nops) {
  int n = nsrc + nops;
  int i;
  size_t plansize = 0;
  QPlan *pl;
  GCObject *o = luaC_newobj(L, LUA_VQUERY, sizequery(n));
  Query *q = gco2query(o);
  q->nsources = cast_byte(nsrc);
  q->noperands = cast_byte(nops);
  q->gclist = NULL;
  q->plan = NULL;
  q->plansize = 0;
  for (i = 0; i < n; i++) /* nil-fill before anything can collect */
    setnilvalue(&q->vals[i]);
  setqueryvalue2s(L, L->top.p, q); /* anchor during the plan allocation */
  L->top.p++;
  pl = decodeplan(L, getstr(blob), tsslen(blob), &plansize);
  if (pl == NULL) {
    L->top.p--;
    luaG_runerror(L, "corrupt query plan in bytecode");
  }
  q->plan = pl;
  q->plansize = plansize;
  if (pl->h.nsources != nsrc || pl->h.noperands != nops) {
    L->top.p--;
    luaG_runerror(L, "corrupt query plan in bytecode");
  }
  for (i = 0; i < n; i++)
    setobj2n(L, &q->vals[i], s2v(base + i));
  L->top.p--;
  setqueryvalue2s(L, ra, q);
}

lu_mem luaQ_size(Query *q) {
  return sizequery(q->nsources + q->noperands) + q->plansize;
}

void luaQ_free(lua_State *L, Query *q) {
  if (q->plan != NULL)
    luaM_freemem(L, q->plan, q->plansize);
  luaM_freemem(L, q, sizequery(q->nsources + q->noperands));
}


/*
** {==================================================================
** The public C API: a read-only visitor over sources, clauses, and
** nodes, plus native provider registration (see lua.h)
** ===================================================================
*/

/* the public node kinds collapse the literal variants into one */
static int publickind(const QNode *n) {
  switch (n->kind) {
    case QN_COLUMN: return LUS_QN_COLUMN;
    case QN_ROWVAR: return LUS_QN_ROWVAR;
    case QN_PARAM: return LUS_QN_PARAM;
    case QN_CLOSURE: return LUS_QN_CLOSURE;
    case QN_NAMEREF: return LUS_QN_NAMEREF;
    case QN_LIT_NIL:
    case QN_LIT_TRUE:
    case QN_LIT_FALSE:
    case QN_LIT_INT:
    case QN_LIT_FLT:
    case QN_LIT_STR: return LUS_QN_LIT;
    case QN_AND: return LUS_QN_AND;
    case QN_OR: return LUS_QN_OR;
    case QN_NOT: return LUS_QN_NOT;
    case QN_CMP: return LUS_QN_CMP;
    case QN_ARITH: return LUS_QN_ARITH;
    case QN_CONCAT: return LUS_QN_CONCAT;
    default: return LUS_QN_AGG;
  }
}

LUA_API lus_Query *lus_toquery(lua_State *L, int idx) {
  const TValue *o;
  if (idx > 0)
    o = s2v(L->ci->func.p + idx);
  else if (idx < 0 && idx > LUA_REGISTRYINDEX)
    o = s2v(L->top.p + idx);
  else
    return NULL;
  return ttisquery(o) ? queryvalue(o) : NULL;
}

LUA_API int lus_querysourcecount(const lus_Query *q) { return q->nsources; }

LUA_API const char *lus_querysourcealias(const lus_Query *q, int i,
                                         size_t *len) {
  const QPlan *pl = queryplan(q);
  if (i < 0 || i >= q->nsources)
    return NULL;
  if (len != NULL)
    *len = pl->sources[i].alias.len;
  return pl->pool + pl->sources[i].alias.off;
}

LUA_API void lus_querysource(lua_State *L, const lus_Query *q, int i) {
  if (i < 0 || i >= q->nsources)
    setnilvalue(s2v(L->top.p));
  else
    setobj2s(L, L->top.p, &q->vals[i]);
  L->top.p++;
}

LUA_API int lus_querydistinct(const lus_Query *q) {
  return (queryplan(q)->h.flags & QF_DISTINCT) != 0;
}

LUA_API int lus_queryclausecount(const lus_Query *q, int clause) {
  const QPlan *pl = queryplan(q);
  switch (clause) {
    case LUS_QWHERE: return pl->h.where_root != QNODE_NONE;
    case LUS_QSELECT: return pl->h.nselect;
    case LUS_QGROUP: return pl->h.ngroup;
    case LUS_QHAVING: return pl->h.having_root != QNODE_NONE;
    case LUS_QORDER: return pl->h.norder;
    case LUS_QLIMIT: return pl->h.limit_node != QNODE_NONE;
    case LUS_QOFFSET: return pl->h.offset_node != QNODE_NONE;
    default: return 0;
  }
}

LUA_API const lus_QueryNode *lus_queryclause(const lus_Query *q, int clause,
                                             int item) {
  const QPlan *pl = queryplan(q);
  unsigned short node = QNODE_NONE;
  switch (clause) {
    case LUS_QWHERE:
      if (item == 0)
        node = pl->h.where_root;
      break;
    case LUS_QSELECT:
      if (item >= 0 && item < pl->h.nselect)
        node = pl->sel[item].node;
      break;
    case LUS_QGROUP:
      if (item >= 0 && item < pl->h.ngroup)
        node = pl->group[item];
      break;
    case LUS_QHAVING:
      if (item == 0)
        node = pl->h.having_root;
      break;
    case LUS_QORDER:
      if (item >= 0 && item < pl->h.norder)
        node = pl->order[item].node;
      break;
    case LUS_QLIMIT:
      if (item == 0)
        node = pl->h.limit_node;
      break;
    case LUS_QOFFSET:
      if (item == 0)
        node = pl->h.offset_node;
      break;
    default:
      break;
  }
  return (node == QNODE_NONE) ? NULL : &pl->nodes[node];
}

LUA_API const char *lus_queryselectname(const lus_Query *q, int item,
                                        size_t *len) {
  const QPlan *pl = queryplan(q);
  if (item < 0 || item >= pl->h.nselect || pl->sel[item].name.len == 0)
    return NULL;
  if (len != NULL)
    *len = pl->sel[item].name.len;
  return pl->pool + pl->sel[item].name.off;
}

LUA_API int lus_queryorderdesc(const lus_Query *q, int item) {
  const QPlan *pl = queryplan(q);
  if (item < 0 || item >= pl->h.norder)
    return 0;
  return pl->order[item].desc;
}

LUA_API int lus_qnodekind(const lus_QueryNode *n) { return publickind(n); }

LUA_API int lus_qnodeop(const lus_QueryNode *n) { return n->sub; }

LUA_API const lus_QueryNode *lus_qnodechild(const lus_Query *q,
                                            const lus_QueryNode *n, int i) {
  const QPlan *pl = queryplan(q);
  unsigned short child = QNODE_NONE;
  switch (n->kind) {
    case QN_AND:
    case QN_OR:
    case QN_CMP:
    case QN_CONCAT:
    case QN_ARITH:
      child = (i == 0) ? n->a : (i == 1) ? n->b : QNODE_NONE;
      break;
    case QN_NOT:
    case QN_AGG:
      child = (i == 0) ? n->a : QNODE_NONE;
      break;
    default:
      break;
  }
  return (child == QNODE_NONE) ? NULL : &pl->nodes[child];
}

LUA_API const char *lus_qnodename(const lus_Query *q, const lus_QueryNode *n,
                                  size_t *len) {
  const QPlan *pl = queryplan(q);
  switch (n->kind) {
    case QN_COLUMN:
    case QN_NAMEREF:
      if (len != NULL)
        *len = n->u.s.len;
      return pl->pool + n->u.s.off;
    default:
      return NULL;
  }
}

LUA_API void lus_qnodevalue(lua_State *L, const lus_Query *q,
                            const lus_QueryNode *n) {
  switch (n->kind) {
    case QN_LIT_NIL:
      setnilvalue(s2v(L->top.p));
      L->top.p++;
      break;
    case QN_LIT_TRUE:
      setbtvalue(s2v(L->top.p));
      L->top.p++;
      break;
    case QN_LIT_FALSE:
      setbfvalue(s2v(L->top.p));
      L->top.p++;
      break;
    case QN_LIT_INT:
      setivalue(s2v(L->top.p), n->u.i);
      L->top.p++;
      break;
    case QN_LIT_FLT:
      setfltvalue(s2v(L->top.p), n->u.n);
      L->top.p++;
      break;
    case QN_LIT_STR: {
      const QPlan *pl = queryplan(q);
      TString *s = luaS_newlstr(L, pl->pool + n->u.s.off, n->u.s.len);
      setsvalue2s(L, L->top.p, s);
      L->top.p++;
      break;
    }
    case QN_PARAM:
    case QN_CLOSURE:
      setobj2s(L, L->top.p, &q->vals[q->nsources + n->a]);
      L->top.p++;
      break;
    default:
      setnilvalue(s2v(L->top.p));
      L->top.p++;
      break;
  }
}

LUA_API void lus_setqueryprovider(lua_State *L, int mt_idx,
                                  const lus_QueryProvider *p) {
  mt_idx = lua_absindex(L, mt_idx);
  lua_pushlightuserdata(L, (void *)p);
  lua_setfield(L, mt_idx, "__queryprovider");
}

/* }================================================================== */
