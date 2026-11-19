/*
** $Id: lvector.c $
** Vector handling
** See Copyright Notice in lua.h
*/

#define lvector_c
#define LUA_CORE

#include "lprefix.h"

#include <string.h>

#include "lua.h"

#include "lgc.h"
#include "lmem.h"
#include "lobject.h"
#include "lstate.h"
#include "lvector.h"


/*
** Create a new vector with given length.
** If 'fast' is true, buffer is not zero-initialized.
*/
Vector *luaV_newvec(lua_State *L, size_t len, int fast) {
  GCObject *o = luaC_newobj(L, LUA_VVECTOR, sizeof(Vector));
  Vector *v = gco2vec(o);
  v->data = NULL;
  v->len = 0;
  v->alloc = 0;
  if (len > 0) {
    char *data;
    /* anchor v on the stack: an emergency collection triggered by the
       data allocation would otherwise sweep the still-unreachable
       vector, leaving 'v' dangling */
    setvecvalue2s(L, L->top.p, v);
    L->top.p++;
    data = luaM_newblock(L, len);
    L->top.p--;
    if (!fast)
      memset(data, 0, len);
    v->data = data;
    v->len = len;
    v->alloc = len;
  }
  return v;
}


/*
** Clone a vector.
*/
Vector *luaV_clone(lua_State *L, Vector *src) {
  Vector *v = luaV_newvec(L, src->len, 1);
  if (src->len > 0)
    memcpy(v->data, src->data, src->len);
  return v;
}


/*
** Resize a vector. New bytes are zero-initialized.
*/
void luaV_resize(lua_State *L, Vector *v, size_t newlen) {
  if (newlen > v->alloc) {
    /* Grow geometrically (1.5x) so grow-by-one resize loops are O(n)
       amortized instead of O(n^2); large jumps get their exact size */
    size_t newalloc = v->alloc + (v->alloc >> 1);
    if (newalloc < newlen || newalloc < v->alloc) /* too small or wrapped? */
      newalloc = newlen;
    v->data = luaM_reallocvchar(L, v->data, v->alloc, newalloc);
    v->alloc = newalloc;
  }
  if (newlen > v->len) {
    /* Zero-initialize new bytes */
    memset(v->data + v->len, 0, newlen - v->len);
  }
  v->len = newlen;
}


/*
** Free a vector.
*/
void luaV_freevec(lua_State *L, Vector *v) {
  if (v->alloc > 0)
    luaM_freemem(L, v->data, v->alloc);
  luaM_freemem(L, v, sizeof(Vector));
}


/*
** Get total memory size of a vector.
*/
lu_mem luaV_vecsize(Vector *v) {
  return cast(lu_mem, sizeof(Vector) + v->alloc);
}
