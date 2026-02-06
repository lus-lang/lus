/*
** lformat.c - Lus source code formatter
** Walks C AST structures (LusAstNode) directly to emit formatted source.
** No Lua stack interaction -- operates purely on C structs.
*/

#include "lprefix.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"

#include "last.h"
#include "ldo.h"
#include "llimits.h"
#include "lmem.h"
#include "lobject.h"
#include "lparser.h"
#include "lstring.h"
#include "lzio.h"
#include "lauxlib.h"
#include "lformat.h"

/* ======================================================================
** Growable output buffer (pure C, no Lua)
** ====================================================================== */

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} FmtBuf;

static void buf_init(FmtBuf *b) {
  b->cap = 4096;
  b->data = (char *)malloc(b->cap);
  b->len = 0;
  if (b->data) b->data[0] = '\0';
}

static void buf_grow(FmtBuf *b, size_t need) {
  if (b->len + need + 1 > b->cap) {
    while (b->len + need + 1 > b->cap)
      b->cap *= 2;
    b->data = (char *)realloc(b->data, b->cap);
  }
}

static void buf_adds(FmtBuf *b, const char *s) {
  size_t slen = strlen(s);
  buf_grow(b, slen);
  memcpy(b->data + b->len, s, slen);
  b->len += slen;
  b->data[b->len] = '\0';
}

static void buf_addlstr(FmtBuf *b, const char *s, size_t slen) {
  buf_grow(b, slen);
  memcpy(b->data + b->len, s, slen);
  b->len += slen;
  b->data[b->len] = '\0';
}

static void buf_addc(FmtBuf *b, char c) {
  buf_grow(b, 1);
  b->data[b->len++] = c;
  b->data[b->len] = '\0';
}

static void buf_addrepeat(FmtBuf *b, char c, int n) {
  if (n <= 0) return;
  buf_grow(b, (size_t)n);
  memset(b->data + b->len, c, (size_t)n);
  b->len += (size_t)n;
  b->data[b->len] = '\0';
}

static void buf_addfmt(FmtBuf *b, const char *fmt, ...) {
  char tmp[256];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  if (n > 0) buf_addlstr(b, tmp, (size_t)n);
}

/* ======================================================================
** Formatter state (pure C)
** ====================================================================== */

typedef struct {
  FmtBuf buf;
  int indent;          /* current indentation level */
  int indent_width;    /* spaces per indent level */
  int max_width;       /* max line width for layout decisions */
  /* Comment tracking */
  LusComment *next_comment;  /* next comment to emit */
} FmtState;

static void emit_indent(FmtState *F) {
  buf_addrepeat(&F->buf, ' ', F->indent * F->indent_width);
}

static void emit_nl(FmtState *F) {
  buf_addc(&F->buf, '\n');
}

/* Forward declarations */
static void emit_expr(FmtState *F, LusAstNode *n);
static void emit_stmt(FmtState *F, LusAstNode *n);
static void emit_block_children(FmtState *F, LusAstNode *parent);
static void emit_exprlist(FmtState *F, LusAstNode *first);

/* ======================================================================
** Comment interleaving
** ====================================================================== */

/* Emit comments before `line`. Returns the endline of the last emitted
** comment, or 0 if no comments were emitted. */
static int emit_comments_before(FmtState *F, int line) {
  int last_endline = 0;
  while (F->next_comment != NULL) {
    LusComment *c = F->next_comment;
    if (line > 0 && c->line >= line) break;
    /* Insert blank line if there's a gap between previous comment/code
    ** and this comment */
    if (last_endline > 0 && c->line > last_endline + 1)
      emit_nl(F);
    if (c->islong) {
      /* Long comments: the stored text starts after the newline following --[[.
      ** Reconstruct: --[[\n<text>]] */
      emit_indent(F);
      buf_adds(&F->buf, "--[[");
      emit_nl(F);
      if (c->text) buf_addlstr(&F->buf, getstr(c->text), tsslen(c->text));
      buf_adds(&F->buf, "]]");
    } else {
      /* Short comment */
      emit_indent(F);
      buf_adds(&F->buf, "--");
      if (c->text) {
        const char *t = getstr(c->text);
        if (t[0] != '\0' && t[0] != ' ' && t[0] != '-')
          buf_addc(&F->buf, ' ');
        buf_addlstr(&F->buf, t, tsslen(c->text));
      }
    }
    emit_nl(F);
    last_endline = c->endline > 0 ? c->endline : c->line;
    F->next_comment = c->next;
  }
  return last_endline;
}

static void emit_remaining_comments(FmtState *F) {
  emit_comments_before(F, -1);
}

/* ======================================================================
** Operator helpers
** ====================================================================== */

static const char *binop_sym(LusAstBinOp op) {
  switch (op) {
    case AST_OP_ADD: return " + ";
    case AST_OP_SUB: return " - ";
    case AST_OP_MUL: return " * ";
    case AST_OP_DIV: return " / ";
    case AST_OP_IDIV: return " // ";
    case AST_OP_MOD: return " % ";
    case AST_OP_POW: return " ^ ";
    case AST_OP_CONCAT: return " .. ";
    case AST_OP_BAND: return " & ";
    case AST_OP_BOR: return " | ";
    case AST_OP_BXOR: return " ~ ";
    case AST_OP_SHL: return " << ";
    case AST_OP_SHR: return " >> ";
    case AST_OP_EQ: return " == ";
    case AST_OP_NE: return " ~= ";
    case AST_OP_LT: return " < ";
    case AST_OP_LE: return " <= ";
    case AST_OP_GT: return " > ";
    case AST_OP_GE: return " >= ";
    case AST_OP_AND: return " and ";
    case AST_OP_OR: return " or ";
    default: return " ?? ";
  }
}

static int binop_prec(LusAstBinOp op) {
  switch (op) {
    case AST_OP_OR: return 1;
    case AST_OP_AND: return 2;
    case AST_OP_LT: case AST_OP_GT: case AST_OP_LE:
    case AST_OP_GE: case AST_OP_EQ: case AST_OP_NE: return 3;
    case AST_OP_BOR: return 4;
    case AST_OP_BXOR: return 5;
    case AST_OP_BAND: return 6;
    case AST_OP_SHL: case AST_OP_SHR: return 7;
    case AST_OP_CONCAT: return 8;
    case AST_OP_ADD: case AST_OP_SUB: return 9;
    case AST_OP_MUL: case AST_OP_DIV:
    case AST_OP_IDIV: case AST_OP_MOD: return 10;
    case AST_OP_POW: return 12;
    default: return 11;
  }
}

static int is_right_assoc(LusAstBinOp op) {
  return op == AST_OP_CONCAT || op == AST_OP_POW;
}

/* Check if child expression needs parentheses */
static int child_needs_parens(LusAstNode *child, int parent_prec, int on_right) {
  if (child == NULL || child->type != AST_BINOP) return 0;
  int cp = binop_prec(child->u.binop.op);
  if (cp < parent_prec) return 1;
  if (cp == parent_prec && on_right && !is_right_assoc(child->u.binop.op))
    return 1;
  return 0;
}

/* ======================================================================
** Expression emitters (operate on LusAstNode*)
** ====================================================================== */

static void emit_string_lit(FmtState *F, LusAstNode *n) {
  TString *ts = n->u.str;
  if (ts == NULL) { buf_adds(&F->buf, "\"\""); return; }
  const char *s = getstr(ts);
  size_t len = tsslen(ts);

  /* Use original quote character if available, otherwise choose */
  char q;
  if (n->quote == '\'' || n->quote == '"')
    q = (char)n->quote;
  else {
    int has_dq = (memchr(s, '"', len) != NULL);
    int has_sq = (memchr(s, '\'', len) != NULL);
    q = (has_dq && !has_sq) ? '\'' : '"';
  }

  buf_addc(&F->buf, q);
  for (size_t i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    switch (c) {
      case '\\': buf_adds(&F->buf, "\\\\"); break;
      case '\n': buf_adds(&F->buf, "\\n"); break;
      case '\r': buf_adds(&F->buf, "\\r"); break;
      case '\t': buf_adds(&F->buf, "\\t"); break;
      case '\0': buf_adds(&F->buf, "\\0"); break;
      default:
        if (c == (unsigned char)q) {
          buf_addc(&F->buf, '\\'); buf_addc(&F->buf, q);
        } else if (c < 32) {
          buf_addfmt(&F->buf, "\\x%02x", c);
        } else {
          buf_addc(&F->buf, (char)c);
        }
    }
  }
  buf_addc(&F->buf, q);
}

static void emit_name(FmtState *F, LusAstNode *n) {
  if (n && n->u.var.name)
    buf_addlstr(&F->buf, getstr(n->u.var.name), tsslen(n->u.var.name));
}

static void emit_binop(FmtState *F, LusAstNode *n) {
  int prec = binop_prec(n->u.binop.op);
  LusAstNode *left = n->u.binop.left;
  LusAstNode *right = n->u.binop.right;

  int lp = child_needs_parens(left, prec, 0);
  if (lp) buf_addc(&F->buf, '(');
  emit_expr(F, left);
  if (lp) buf_addc(&F->buf, ')');

  buf_adds(&F->buf, binop_sym(n->u.binop.op));

  int rp = child_needs_parens(right, prec, 1);
  if (rp) buf_addc(&F->buf, '(');
  emit_expr(F, right);
  if (rp) buf_addc(&F->buf, ')');
}

static void emit_unop(FmtState *F, LusAstNode *n) {
  switch (n->u.unop.op) {
    case AST_OP_MINUS:
      buf_addc(&F->buf, '-');
      /* Prevent --x (which is a comment). Add space if operand
      ** starts with '-' (another unary minus or negative number) */
      if (n->u.unop.operand) {
        if (n->u.unop.operand->type == AST_UNOP &&
            n->u.unop.operand->u.unop.op == AST_OP_MINUS)
          buf_addc(&F->buf, ' ');
        else if (n->u.unop.operand->type == AST_NUMBER &&
                 !n->u.unop.operand->u.num.isint &&
                 n->u.unop.operand->u.num.val.n < 0)
          buf_addc(&F->buf, ' ');
      }
      break;
    case AST_OP_NOT: buf_adds(&F->buf, "not "); break;
    case AST_OP_LEN: buf_addc(&F->buf, '#'); break;
    case AST_OP_BNOT: buf_addc(&F->buf, '~'); break;
  }
  LusAstNode *operand = n->u.unop.operand;
  int need_parens = operand && operand->type == AST_BINOP && !operand->paren;
  if (need_parens) buf_addc(&F->buf, '(');
  emit_expr(F, operand);
  if (need_parens) buf_addc(&F->buf, ')');
}

/* Emit a comma-separated expression list (linked via ->next) */
static void emit_exprlist(FmtState *F, LusAstNode *first) {
  for (LusAstNode *n = first; n != NULL; n = n->next) {
    if (n != first) buf_adds(&F->buf, ", ");
    emit_expr(F, n);
  }
}

/* Check if a string is a valid Lua identifier */
static int is_valid_ident(const char *s, size_t len) {
  if (len == 0) return 0;
  if (!(s[0] == '_' || (s[0] >= 'a' && s[0] <= 'z') ||
        (s[0] >= 'A' && s[0] <= 'Z')))
    return 0;
  for (size_t i = 1; i < len; i++) {
    char c = s[i];
    if (!(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9')))
      return 0;
  }
  return 1;
}

/* Emit a table key: as identifier if valid, or as ["key"] */
static void emit_table_key(FmtState *F, LusAstNode *key) {
  if (key->type == AST_STRING && key->u.str) {
    const char *s = getstr(key->u.str);
    size_t len = tsslen(key->u.str);
    if (is_valid_ident(s, len)) {
      buf_addlstr(&F->buf, s, len);
    } else {
      buf_addc(&F->buf, '[');
      emit_string_lit(F, key);
      buf_addc(&F->buf, ']');
    }
  } else {
    buf_addc(&F->buf, '[');
    emit_expr(F, key);
    buf_addc(&F->buf, ']');
  }
}

/* Count nodes in a linked list */
static int count_list(LusAstNode *first) {
  int count = 0;
  for (LusAstNode *n = first; n != NULL; n = n->next) count++;
  return count;
}

/* Emit a table constructor */
static void emit_table(FmtState *F, LusAstNode *n) {
  LusAstNode *first_child = n->child;
  int nfields = count_list(first_child);

  if (nfields == 0) {
    buf_adds(&F->buf, "{}");
    return;
  }

  int multiline = nfields > 3;

  if (multiline) {
    buf_addc(&F->buf, '{');
    emit_nl(F);
    F->indent++;
    for (LusAstNode *c = first_child; c != NULL; c = c->next) {
      emit_indent(F);
      if (c->type == AST_TABLEFIELD && c->u.field.key != NULL) {
        emit_table_key(F, c->u.field.key);
        buf_adds(&F->buf, " = ");
        emit_expr(F, c->u.field.value);
      } else if (c->type == AST_TABLEFIELD) {
        emit_expr(F, c->u.field.value);
      } else {
        emit_expr(F, c);
      }
      buf_addc(&F->buf, ',');
      emit_nl(F);
    }
    F->indent--;
    emit_indent(F);
    buf_addc(&F->buf, '}');
  } else {
    buf_adds(&F->buf, "{ ");
    int first = 1;
    for (LusAstNode *c = first_child; c != NULL; c = c->next) {
      if (!first) buf_adds(&F->buf, ", ");
      first = 0;
      if (c->type == AST_TABLEFIELD && c->u.field.key != NULL) {
        emit_table_key(F, c->u.field.key);
        buf_adds(&F->buf, " = ");
        emit_expr(F, c->u.field.value);
      } else if (c->type == AST_TABLEFIELD) {
        emit_expr(F, c->u.field.value);
      } else {
        emit_expr(F, c);
      }
    }
    buf_adds(&F->buf, " }");
  }
}

/* Emit function call */
static void emit_call(FmtState *F, LusAstNode *n) {
  emit_expr(F, n->u.call.func);
  switch (n->u.call.callstyle) {
    case 1:  /* string call: f "str" or f 'str' */
      buf_addc(&F->buf, ' ');
      emit_expr(F, n->u.call.args);
      break;
    case 2:  /* table call: f{...} */
      emit_expr(F, n->u.call.args);
      break;
    default: /* parenthesized call: f(x, y) */
      buf_addc(&F->buf, '(');
      emit_exprlist(F, n->u.call.args);
      buf_addc(&F->buf, ')');
      break;
  }
}

/* Emit method call */
static void emit_methodcall(FmtState *F, LusAstNode *n) {
  emit_expr(F, n->u.call.func);
  buf_addc(&F->buf, ':');
  if (n->u.call.method)
    buf_addlstr(&F->buf, getstr(n->u.call.method), tsslen(n->u.call.method));
  buf_addc(&F->buf, '(');
  emit_exprlist(F, n->u.call.args);
  buf_addc(&F->buf, ')');
}

/* Emit function parameters (linked list of AST_NAME) */
static void emit_params(FmtState *F, LusAstNode *params) {
  for (LusAstNode *p = params; p != NULL; p = p->next) {
    if (p != params) buf_adds(&F->buf, ", ");
    if (p->type == AST_NAME && p->u.var.name)
      buf_addlstr(&F->buf, getstr(p->u.var.name), tsslen(p->u.var.name));
    else if (p->type == AST_VARARG)
      buf_adds(&F->buf, "...");
  }
}

/* Emit function body (shared by funcexpr, localfunc, funcstat, globalfunc) */
/* Emit a field expression, but use ':' for the last segment if is_method */
static void emit_field_chain(FmtState *F, LusAstNode *n, int is_method) {
  if (n == NULL) return;
  if (n->type == AST_FIELD) {
    /* Check if this is the last field in the chain (method uses ':') */
    int use_colon = is_method && (n->u.index.key != NULL);
    /* Emit the table part */
    if (n->u.index.table && n->u.index.table->type == AST_FIELD)
      emit_field_chain(F, n->u.index.table, 0); /* inner fields use '.' */
    else
      emit_expr(F, n->u.index.table);
    buf_addc(&F->buf, use_colon ? ':' : '.');
    if (n->u.index.key && n->u.index.key->type == AST_STRING
        && n->u.index.key->u.str)
      buf_addlstr(&F->buf, getstr(n->u.index.key->u.str),
                  tsslen(n->u.index.key->u.str));
  } else {
    emit_expr(F, n);
  }
}

static void emit_funcbody(FmtState *F, LusAstNode *n, const char *prefix) {
  buf_adds(&F->buf, prefix);

  /* Function name */
  if (n->u.func.nameexpr) {
    if (n->u.func.ismethod)
      emit_field_chain(F, n->u.func.nameexpr, 1);
    else
      emit_expr(F, n->u.func.nameexpr);
  } else if (n->u.func.name) {
    buf_addlstr(&F->buf, getstr(n->u.func.name), tsslen(n->u.func.name));
  }

  buf_addc(&F->buf, '(');
  emit_params(F, n->u.func.params);
  buf_addc(&F->buf, ')');
  emit_nl(F);

  /* Body is in children */
  emit_block_children(F, n);

  emit_indent(F);
  buf_adds(&F->buf, "end");
}

/* Emit interpolated string */
static void emit_interp(FmtState *F, LusAstNode *n) {
  buf_addc(&F->buf, '`');
  for (LusAstNode *p = n->u.interp.parts; p != NULL; p = p->next) {
    if (p->type == AST_STRING && p->u.str) {
      /* Literal segment: emit text, escaping special chars for interp strings */
      const char *s = getstr(p->u.str);
      size_t len = tsslen(p->u.str);
      for (size_t k = 0; k < len; k++) {
        if (s[k] == '$') buf_addc(&F->buf, '$');       /* escape $ as $$ */
        else if (s[k] == '`') buf_addc(&F->buf, '\\'); /* escape ` as \` */
        else if (s[k] == '\\') buf_addc(&F->buf, '\\'); /* escape \ as \\ */
        buf_addc(&F->buf, s[k]);
      }
    } else if (p->type == AST_NAME && p->u.var.name) {
      /* Simple variable: $name */
      buf_addc(&F->buf, '$');
      buf_addlstr(&F->buf, getstr(p->u.var.name), tsslen(p->u.var.name));
    } else {
      /* Complex expression: $(expr) */
      buf_adds(&F->buf, "$(");
      emit_expr(F, p);
      buf_addc(&F->buf, ')');
    }
  }
  buf_addc(&F->buf, '`');
}

/* ======================================================================
** Main expression dispatcher
** ====================================================================== */

static void emit_expr(FmtState *F, LusAstNode *n) {
  if (n == NULL) { buf_adds(&F->buf, "nil"); return; }

  /* Emit parentheses if expression was parenthesized in source */
  int has_paren = n->paren;
  if (has_paren) buf_addc(&F->buf, '(');

  switch (n->type) {
    case AST_NIL: buf_adds(&F->buf, "nil"); break;
    case AST_TRUE: buf_adds(&F->buf, "true"); break;
    case AST_FALSE: buf_adds(&F->buf, "false"); break;
    case AST_VARARG: buf_adds(&F->buf, "..."); break;

    case AST_NUMBER:
      if (n->u.num.isint)
        buf_addfmt(&F->buf, "%lld", (long long)n->u.num.val.i);
      else
        buf_addfmt(&F->buf, "%.14g", n->u.num.val.n);
      break;

    case AST_STRING:
      emit_string_lit(F, n);
      break;

    case AST_NAME:
      emit_name(F, n);
      break;

    case AST_BINOP: emit_binop(F, n); break;
    case AST_UNOP: emit_unop(F, n); break;
    case AST_TABLE: emit_table(F, n); break;

    case AST_FIELD:
      emit_expr(F, n->u.index.table);
      buf_addc(&F->buf, '.');
      if (n->u.index.key && n->u.index.key->type == AST_STRING
          && n->u.index.key->u.str)
        buf_addlstr(&F->buf, getstr(n->u.index.key->u.str),
                    tsslen(n->u.index.key->u.str));
      break;

    case AST_INDEX:
      emit_expr(F, n->u.index.table);
      buf_addc(&F->buf, '[');
      emit_expr(F, n->u.index.key);
      buf_addc(&F->buf, ']');
      break;

    case AST_CALLEXPR: emit_call(F, n); break;
    case AST_METHODCALL: emit_methodcall(F, n); break;

    case AST_FUNCEXPR:
      emit_funcbody(F, n, "function");
      break;

    case AST_CATCHEXPR:
      buf_adds(&F->buf, "catch ");
      emit_expr(F, n->u.catchnode.expr);
      break;

    case AST_DOEXPR:
      buf_adds(&F->buf, "do");
      emit_nl(F);
      emit_block_children(F, n);
      emit_indent(F);
      buf_adds(&F->buf, "end");
      break;

    case AST_ENUM: {
      buf_adds(&F->buf, "enum ");
      for (LusAstNode *nm = n->u.enumdef.names; nm != NULL; nm = nm->next) {
        if (nm != n->u.enumdef.names) buf_adds(&F->buf, ", ");
        if (nm->type == AST_NAME && nm->u.var.name)
          buf_addlstr(&F->buf, getstr(nm->u.var.name),
                      tsslen(nm->u.var.name));
      }
      buf_adds(&F->buf, " end");
      break;
    }

    case AST_INTERP: emit_interp(F, n); break;

    case AST_SLICE:
      emit_expr(F, n->u.slice.table);
      buf_addc(&F->buf, '[');
      if (n->u.slice.start) emit_expr(F, n->u.slice.start);
      buf_addc(&F->buf, ',');
      if (n->u.slice.finish) emit_expr(F, n->u.slice.finish);
      buf_addc(&F->buf, ']');
      break;

    case AST_OPTCHAIN:
      emit_expr(F, n->u.optchain.base);
      buf_addc(&F->buf, '?');
      emit_expr(F, n->u.optchain.suffix);
      break;

    default:
      buf_adds(&F->buf, "--[[unknown expr]]");
      break;
  }

  if (has_paren) buf_addc(&F->buf, ')');
}

/* ======================================================================
** Name list emitter (for local/global declarations)
** ====================================================================== */

static void emit_namelist(FmtState *F, LusAstNode *first) {
  for (LusAstNode *n = first; n != NULL; n = n->next) {
    if (n != first) buf_adds(&F->buf, ", ");
    if (n->type == AST_NAME) {
      if (n->u.var.name)
        buf_addlstr(&F->buf, getstr(n->u.var.name), tsslen(n->u.var.name));
      /* Attributes: builtin and runtime combined in one < > block.
      ** attrkind: RDKCONST=1, RDKTOCLOSE=3, RDKGROUP=5 */
      {
        int has_builtin = (n->u.var.attrkind == 1 || n->u.var.attrkind == 3 ||
                           n->u.var.attrkind == 5);
        int has_runtime = (n->u.var.runtimeattrs != NULL);
        if (has_builtin || has_runtime) {
          buf_adds(&F->buf, " <");
          if (n->u.var.attrkind == 1) buf_adds(&F->buf, "const");
          else if (n->u.var.attrkind == 3) buf_adds(&F->buf, "close");
          else if (n->u.var.attrkind == 5) buf_adds(&F->buf, "group");
          if (has_builtin && has_runtime) buf_adds(&F->buf, ", ");
          for (LusAstNode *a = n->u.var.runtimeattrs; a != NULL; a = a->next) {
            if (a != n->u.var.runtimeattrs) buf_adds(&F->buf, ", ");
            emit_expr(F, a);
          }
          buf_addc(&F->buf, '>');
        }
      }
    }
  }
}

/* ======================================================================
** Statement emitters
** ====================================================================== */

static void emit_local(FmtState *F, LusAstNode *n) {
  buf_adds(&F->buf, "local ");
  emit_namelist(F, n->u.decl.names);
  if (n->u.decl.isfrom) {
    buf_adds(&F->buf, " from ");
    emit_exprlist(F, n->u.decl.values);
  } else if (n->u.decl.values) {
    buf_adds(&F->buf, " = ");
    emit_exprlist(F, n->u.decl.values);
  }
}

static void emit_global(FmtState *F, LusAstNode *n) {
  buf_adds(&F->buf, "global ");
  emit_namelist(F, n->u.decl.names);
  if (n->u.decl.isfrom) {
    buf_adds(&F->buf, " from ");
    emit_exprlist(F, n->u.decl.values);
  } else if (n->u.decl.values) {
    buf_adds(&F->buf, " = ");
    emit_exprlist(F, n->u.decl.values);
  }
}

static void emit_assign(FmtState *F, LusAstNode *n) {
  emit_exprlist(F, n->u.assign.lhs);
  if (n->u.assign.isfrom)
    buf_adds(&F->buf, " from ");
  else
    buf_adds(&F->buf, " = ");
  emit_exprlist(F, n->u.assign.rhs);
}

static void emit_return(FmtState *F, LusAstNode *n) {
  buf_adds(&F->buf, "return");
  if (n->u.ret.values) {
    buf_addc(&F->buf, ' ');
    emit_exprlist(F, n->u.ret.values);
  }
}

static void emit_provide(FmtState *F, LusAstNode *n) {
  buf_adds(&F->buf, "provide");
  if (n->u.ret.values) {
    buf_addc(&F->buf, ' ');
    emit_exprlist(F, n->u.ret.values);
  }
}

/* Emit a condition (may be a regular expr or an assignment condition) */
static void emit_cond(FmtState *F, LusAstNode *cond) {
  if (cond && cond->type == AST_ASSIGN) {
    /* Assignment condition: names = values */
    emit_namelist(F, cond->u.assign.lhs);
    if (cond->u.assign.isfrom) {
      buf_adds(&F->buf, " from ");
      emit_exprlist(F, cond->u.assign.rhs);
    } else {
      buf_adds(&F->buf, " = ");
      emit_exprlist(F, cond->u.assign.rhs);
    }
  } else {
    emit_expr(F, cond);
  }
}

static void emit_if(FmtState *F, LusAstNode *n) {
  buf_adds(&F->buf, "if ");
  emit_cond(F, n->u.ifstat.cond);
  buf_adds(&F->buf, " then");
  emit_nl(F);

  /* Children: mix of body statements and elseif/else nodes */
  F->indent++;
  for (LusAstNode *c = n->child; c != NULL; c = c->next) {
    if (c->type == AST_ELSEIF) {
      F->indent--;
      emit_indent(F);
      buf_adds(&F->buf, "elseif ");
      /* elseif has cond in u.ifstat.cond and body in children */
      emit_cond(F, c->u.ifstat.cond);
      buf_adds(&F->buf, " then");
      emit_nl(F);
      F->indent++;
      for (LusAstNode *ec = c->child; ec != NULL; ec = ec->next)
        emit_stmt(F, ec);
    } else if (c->type == AST_ELSE) {
      F->indent--;
      emit_indent(F);
      buf_adds(&F->buf, "else");
      emit_nl(F);
      F->indent++;
      for (LusAstNode *ec = c->child; ec != NULL; ec = ec->next)
        emit_stmt(F, ec);
    } else {
      emit_stmt(F, c);
    }
  }
  F->indent--;

  emit_indent(F);
  buf_adds(&F->buf, "end");
}

static void emit_while(FmtState *F, LusAstNode *n) {
  buf_adds(&F->buf, "while ");
  emit_cond(F, n->u.loop.cond);
  buf_adds(&F->buf, " do");
  emit_nl(F);
  emit_block_children(F, n);
  emit_indent(F);
  buf_adds(&F->buf, "end");
}

static void emit_repeat(FmtState *F, LusAstNode *n) {
  buf_adds(&F->buf, "repeat");
  emit_nl(F);
  emit_block_children(F, n);
  emit_indent(F);
  buf_adds(&F->buf, "until ");
  emit_expr(F, n->u.loop.cond);
}

static void emit_fornum(FmtState *F, LusAstNode *n) {
  buf_adds(&F->buf, "for ");
  if (n->u.fornum.var && n->u.fornum.var->type == AST_NAME
      && n->u.fornum.var->u.var.name)
    buf_addlstr(&F->buf, getstr(n->u.fornum.var->u.var.name),
                tsslen(n->u.fornum.var->u.var.name));
  buf_adds(&F->buf, " = ");
  emit_expr(F, n->u.fornum.init);
  buf_adds(&F->buf, ", ");
  emit_expr(F, n->u.fornum.limit);
  if (n->u.fornum.step) {
    buf_adds(&F->buf, ", ");
    emit_expr(F, n->u.fornum.step);
  }
  buf_adds(&F->buf, " do");
  emit_nl(F);
  emit_block_children(F, n);
  emit_indent(F);
  buf_adds(&F->buf, "end");
}

static void emit_forgen(FmtState *F, LusAstNode *n) {
  buf_adds(&F->buf, "for ");
  emit_namelist(F, n->u.forgen.names);
  buf_adds(&F->buf, " in ");
  emit_exprlist(F, n->u.forgen.explist);
  buf_adds(&F->buf, " do");
  emit_nl(F);
  emit_block_children(F, n);
  emit_indent(F);
  buf_adds(&F->buf, "end");
}

/* ======================================================================
** Block / children emitter
** ====================================================================== */

static void emit_block_children(FmtState *F, LusAstNode *parent) {
  F->indent++;
  for (LusAstNode *c = parent->child; c != NULL; c = c->next)
    emit_stmt(F, c);
  F->indent--;
}

/* ======================================================================
** Statement dispatcher
** ====================================================================== */

static void emit_stmt(FmtState *F, LusAstNode *n) {
  if (n == NULL) return;

  /* Emit comments that precede this statement */
  int comment_endline = emit_comments_before(F, n->line);

  /* Insert blank line between comments and statement if source had a gap */
  if (comment_endline > 0 && n->line > comment_endline + 1)
    emit_nl(F);

  emit_indent(F);

  switch (n->type) {
    case AST_LOCAL: emit_local(F, n); break;
    case AST_GLOBAL: emit_global(F, n); break;
    case AST_ASSIGN: emit_assign(F, n); break;
    case AST_RETURN: emit_return(F, n); break;
    case AST_PROVIDE: emit_provide(F, n); break;
    case AST_IF: emit_if(F, n); break;
    case AST_WHILE: emit_while(F, n); break;
    case AST_REPEAT: emit_repeat(F, n); break;
    case AST_FORNUM: emit_fornum(F, n); break;
    case AST_FORGEN: emit_forgen(F, n); break;

    case AST_DO:
      buf_adds(&F->buf, "do");
      emit_nl(F);
      emit_block_children(F, n);
      emit_indent(F);
      buf_adds(&F->buf, "end");
      break;

    case AST_BREAK: buf_adds(&F->buf, "break"); break;

    case AST_GOTO:
      buf_adds(&F->buf, "goto ");
      if (n->u.str) buf_addlstr(&F->buf, getstr(n->u.str), tsslen(n->u.str));
      break;

    case AST_LABEL:
      buf_adds(&F->buf, "::");
      if (n->u.str) buf_addlstr(&F->buf, getstr(n->u.str), tsslen(n->u.str));
      buf_adds(&F->buf, "::");
      break;

    case AST_CALLSTAT:
      if (n->u.call.method)
        emit_methodcall(F, n);
      else
        emit_call(F, n);
      break;
    case AST_CATCHSTAT:
      buf_adds(&F->buf, "catch ");
      emit_expr(F, n->u.catchnode.expr);
      break;

    case AST_FUNCSTAT:
      emit_funcbody(F, n, "function ");
      break;
    case AST_LOCALFUNC:
      emit_funcbody(F, n, "local function ");
      break;
    case AST_GLOBALFUNC:
      emit_funcbody(F, n, "global function ");
      break;

    case AST_ERROR_STAT:
      buf_adds(&F->buf, "-- [FORMAT ERROR: ");
      if (n->u.error.message)
        buf_addlstr(&F->buf, getstr(n->u.error.message),
                    tsslen(n->u.error.message));
      buf_addc(&F->buf, ']');
      break;

    default:
      buf_adds(&F->buf, "-- [unknown: ");
      buf_adds(&F->buf, lusA_typename(n->type));
      buf_addc(&F->buf, ']');
      break;
  }

  emit_nl(F);
}

/* ======================================================================
** Top-level chunk emitter
** ====================================================================== */

static void emit_chunk(FmtState *F, LusAstNode *root) {
  int prev_endline = 0;
  for (LusAstNode *c = root->child; c != NULL; c = c->next) {
    /* Determine the effective start line: either the first comment before
    ** this statement, or the statement itself */
    int effective_start = c->line;
    if (F->next_comment && F->next_comment->line < c->line)
      effective_start = F->next_comment->line;

    /* Insert blank line if source had a gap */
    if (prev_endline > 0 && effective_start > prev_endline + 1)
      emit_nl(F);

    prev_endline = c->endline > 0 ? c->endline : c->line;
    emit_stmt(F, c);
  }
  emit_remaining_comments(F);
}

/* ======================================================================
** Parser invocation (reuses the parser's C internals directly)
** ====================================================================== */

/* String reader for the parser */
typedef struct {
  const char *s;
  size_t size;
} FmtStringReader;

static const char *fmt_getS(lua_State *L, void *ud, size_t *size) {
  FmtStringReader *r = (FmtStringReader *)ud;
  UNUSED(L);
  if (r->size == 0) return NULL;
  *size = r->size;
  r->size = 0;
  return r->s;
}

/* Protected parse function data */
typedef struct {
  const char *code;
  size_t len;
  const char *chunkname;
  LusAst *ast;
  Mbuffer *buff;
  Dyndata *dyd;
} FmtParseData;

static void fmt_f_parse(lua_State *L, void *ud) {
  FmtParseData *pd = (FmtParseData *)ud;
  FmtStringReader reader;
  ZIO z;
  int c;
  reader.s = pd->code;
  reader.size = pd->len;
  luaZ_init(L, &z, fmt_getS, &reader);
  c = zgetc(&z);
  if (c == LUA_SIGNATURE[0]) {
    luaL_error(L, "cannot format binary chunk");
    return;
  }
  LClosure *cl = luaY_parser(L, &z, pd->buff, pd->dyd, pd->chunkname, c,
                              pd->ast);
  lua_pop(L, 1);
  (void)cl;
}

/* ======================================================================
** Public API
** ====================================================================== */

char *lusF_format(lua_State *L, const char *source, size_t srclen,
                  const char *chunkname, int indent_width,
                  int max_line_width, const char **errmsg) {
  LusAst *ast;
  Mbuffer buff;
  Dyndata dyd;
  FmtParseData pd;
  TStatus status;
  FmtState F;

  /* Initialize AST container */
  ast = lusA_new(L);
  ast->recover = 0;  /* no error recovery for formatter */

  /* Initialize parser structures */
  luaZ_initbuffer(L, &buff);
  luaY_initdyndata(L, &dyd);

  /* Setup parse data */
  pd.code = source;
  pd.len = srclen;
  pd.chunkname = chunkname ? chunkname : "=format";
  pd.ast = ast;
  pd.buff = &buff;
  pd.dyd = &dyd;

  /* Stop GC during parsing */
  lua_gc(L, LUA_GCSTOP, 0);

  /* Parse */
  status = luaD_pcall(L, fmt_f_parse, &pd, savestack(L, L->top.p), 0);

  /* Restart GC */
  lua_gc(L, LUA_GCRESTART, 0);

  /* Clean up parser structures */
  luaZ_freebuffer(L, &buff);
  luaY_freedyndata(&dyd);

  if (status != LUA_OK || ast->root == NULL) {
    if (errmsg) *errmsg = "parse error";
    lusA_free(L, ast);
    return NULL;
  }

  /* Initialize formatter state */
  memset(&F, 0, sizeof(F));
  buf_init(&F.buf);
  F.indent = 0;
  F.indent_width = indent_width > 0 ? indent_width : 4;
  F.max_width = max_line_width > 0 ? max_line_width : 80;
  F.next_comment = ast->comments;

  /* Format */
  emit_chunk(&F, ast->root);

  /* Clean up AST */
  lusA_free(L, ast);

  /* Trim trailing whitespace, ensure single trailing newline */
  while (F.buf.len > 0 && (F.buf.data[F.buf.len - 1] == ' ' ||
         F.buf.data[F.buf.len - 1] == '\n' ||
         F.buf.data[F.buf.len - 1] == '\r'))
    F.buf.len--;
  buf_addc(&F.buf, '\n');

  char *result = F.buf.data;
  F.buf.data = NULL;
  return result;
}
