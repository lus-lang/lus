/*
** lquery.h
** First-class query objects (LUA_TQUERY)
** See Copyright Notice in lua.h
**
** A query value is built by OP_QUERY from two inputs: a plan blob (an
** ordinary string constant, so query-bearing chunks dump and load with
** no bytecode format changes) and a run of registers holding the live
** source values, captured parameters, and host closures. The blob is
** produced by the compiler (lparser.c) and decoded here into a QPlan,
** one owned memory block of validated node and clause arrays.
**
** Nodes form a DAG: every child index is strictly smaller than its
** parent's index, which the decoder enforces, so evaluation can never
** cycle and a single forward pass bounds the tree depth. Dumped chunks
** are untrusted input, so the decoder validates everything before the
** plan is adopted.
*/

#ifndef lquery_h
#define lquery_h

#include "lobject.h"

/* limits enforced by both the compiler and the decoder */
#define LUS_QMAXSOURCES 8
#define LUS_QMAXOPERANDS 200
#define LUS_QMAXNODES 256
#define LUS_QMAXSELECT 32
#define LUS_QMAXGROUP 16
#define LUS_QMAXORDER 16
#define LUS_QMAXDEPTH 64

/* absent child or clause */
#define QNODE_NONE 0xFFFFu

/* node kinds */
enum QNodeKind {
  QN_COLUMN,   /* sub = source index, u.s = column name */
  QN_ROWVAR,   /* sub = source index (a whole-row reference) */
  QN_PARAM,    /* a = operand index (a value captured at build time) */
  QN_CLOSURE,  /* a = operand index (a host closure run per row) */
  QN_NAMEREF,  /* u.s = projection alias (order by resolution) */
  QN_LIT_NIL,
  QN_LIT_TRUE,
  QN_LIT_FALSE,
  QN_LIT_INT, /* u.i */
  QN_LIT_FLT, /* u.n */
  QN_LIT_STR, /* u.s */
  QN_AND,     /* a, b children */
  QN_OR,      /* a, b children */
  QN_NOT,     /* a child */
  QN_CMP,     /* sub = QCmpOp, a, b children */
  QN_ARITH,   /* sub = QArithOp, a, b children (QAR_UNM uses a only) */
  QN_CONCAT,  /* a, b children */
  QN_AGG,     /* sub = QAggOp, a child or QNODE_NONE for count(*) */
  QN_NKINDS
};

enum QCmpOp { QCMP_EQ, QCMP_NE, QCMP_LT, QCMP_LE, QCMP_GT, QCMP_GE };

enum QArithOp {
  QAR_ADD,
  QAR_SUB,
  QAR_MUL,
  QAR_DIV,
  QAR_IDIV,
  QAR_MOD,
  QAR_POW,
  QAR_UNM
};

enum QAggOp { QAGG_COUNT, QAGG_SUM, QAGG_AVG, QAGG_MIN, QAGG_MAX };

/* plan flags */
#define QF_DISTINCT 1

/* a byte range inside the plan's string pool */
typedef struct QStr {
  unsigned int off;
  unsigned int len;
} QStr;

typedef struct QNode {
  lu_byte kind;
  lu_byte sub;
  unsigned short a; /* first child / operand index */
  unsigned short b; /* second child */
  unsigned short pad;
  union {
    lua_Integer i;
    lua_Number n;
    QStr s;
  } u;
} QNode;

typedef struct QSelItem {
  unsigned short node;
  unsigned short rowvar; /* 1 when the item is a bare row variable */
  QStr name;             /* projection field name (empty for rowvar) */
} QSelItem;

typedef struct QOrderItem {
  unsigned short node;
  unsigned short desc;
} QOrderItem;

typedef struct QSource {
  QStr alias; /* the row variable name */
} QSource;

/*
** The fixed-size head of the wire blob. The sections follow it in
** order, each padded to 8-byte alignment: sources, nodes, select
** items, group node indexes, order items, string pool.
*/
typedef struct QPlanHeader {
  lu_byte version;
  lu_byte nsources;
  lu_byte noperands;
  lu_byte flags;
  unsigned short nnodes;
  unsigned short nselect;
  unsigned short ngroup;
  unsigned short norder;
  unsigned short where_root;  /* QNODE_NONE when absent */
  unsigned short having_root; /* QNODE_NONE when absent */
  unsigned short limit_node;  /* QNODE_NONE when absent */
  unsigned short offset_node; /* QNODE_NONE when absent */
  unsigned int poolsize;
} QPlanHeader;

#define LUS_QPLAN_VERSION 1

/* the decoded plan: header plus pointers into one owned block */
typedef struct QPlan {
  QPlanHeader h;
  QSource *sources;
  QNode *nodes;
  QSelItem *sel;
  unsigned short *group;
  QOrderItem *order;
  char *pool;
} QPlan;

#define queryplan(q) cast(QPlan *, (q)->plan)
#define qstrptr(pl, s) ((pl)->pool + (s).off)

/*
** Section offsets of the wire layout for the given header, all
** relative to the start of the blob. Returns the total wire size.
** Shared by the compiler's encoder and the decoder.
*/
typedef struct QWireLayout {
  size_t sources, nodes, sel, group, order, pool;
  size_t total;
} QWireLayout;

LUAI_FUNC void luaQ_wirelayout(const QPlanHeader *h, QWireLayout *w);

LUAI_FUNC void luaQ_build(lua_State *L, StkId ra, TString *blob, StkId base,
                          int nsrc, int nops);
LUAI_FUNC void luaQ_free(lua_State *L, Query *q);
LUAI_FUNC lu_mem luaQ_size(Query *q);

#endif
