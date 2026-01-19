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
  v->len = len;
  v->alloc = len;
  if (len > 0) {
    v->data = luaM_newblock(L, len);
    if (!fast)
      memset(v->data, 0, len);
  } else {
    v->data = NULL;
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
    /* Need to grow allocation */
    v->data = luaM_reallocvchar(L, v->data, v->alloc, newlen);
    v->alloc = newlen;
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
