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
      h->nselect > h->nnodes || h->ngroup > h->nnodes ||
      h->norder > h->nnodes)
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
