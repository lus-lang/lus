/*
** $Id: lvectorlib.c $
** Vector library
** See Copyright Notice in lua.h
*/

#define lvectorlib_c
#define LUA_LIB

#include "lprefix.h"

#include <limits.h>
#include <math.h>
#include <string.h>

#include "lua.h"

#include "lauxlib.h"
#include "lgc.h"
#include "lmem.h"
#include "lobject.h"
#include "lstate.h"
#include "lualib.h"
#include "lvector.h"
#include "lpack.h"


/* ===================================================================
** PACK/UNPACK helpers - use shared lpack utilities
** =================================================================== */

/* Use shared pack definitions from lpack.h */
#define MAXINTSIZE LPACK_MAXINTSIZE
#define NB LPACK_NB
#define MC LPACK_MC
#define SZINT LPACK_SZINT
#define LUAL_PACKPADBYTE LPACK_PADBYTE

/* Alias shared types for local compatibility */
typedef lpack_Header Header;
typedef lpack_KOption KOption;

/* Alias enum values */
#define Kint       Lpack_Kint
#define Kuint      Lpack_Kuint
#define Kfloat     Lpack_Kfloat
#define Knumber    Lpack_Knumber
#define Kdouble    Lpack_Kdouble
#define Kchar      Lpack_Kchar
#define Kstring    Lpack_Kstring
#define Kzstr      Lpack_Kzstr
#define Kpadding   Lpack_Kpadding
#define Kpaddalign Lpack_Kpaddalign
#define Knop       Lpack_Knop

/* Alias shared functions */
#define initheader     lpack_initheader
#define getoption      lpack_getoption
#define getdetails     lpack_getdetails
#define copywithendian lpack_copywithendian
#define packint        lpack_packint
#define unpackint      lpack_unpackint


/* ===================================================================
** Vector Library Functions
** =================================================================== */


/*
** Check that argument is a vector.
*/
static Vector *checkvector(lua_State *L, int arg) {
  luaL_checkany(L, arg);
  if (!lua_isvector(L, arg))
    luaL_typeerror(L, arg, "vector");
  /* Get the vector directly from the stack */
  StkId o = L->ci->func.p + arg;
  return vecvalue(s2v(o));
}


/*
** vector.create(capacity [, fast])
*/
static int vec_create(lua_State *L) {
  lua_Integer cap = luaL_checkinteger(L, 1);
  int fast = lua_toboolean(L, 2);
  luaL_argcheck(L, cap >= 0, 1, "capacity must be non-negative");
  Vector *v = luaV_newvec(L, (size_t)cap, fast);
  setvecvalue(L, s2v(L->top.p), v);
  L->top.p++;
  return 1;
}


/*
** vector.pack(v, offset, fmt, ...)
*/
static int vec_pack(lua_State *L) {
  Vector *v = checkvector(L, 1);
  lua_Integer offset = luaL_checkinteger(L, 2);
  const char *fmt = luaL_checkstring(L, 3);
  Header h;
  int arg = 3;
  size_t pos = (size_t)offset;
  
  luaL_argcheck(L, offset >= 0 && (size_t)offset <= v->len, 2, "offset out of bounds");
  
  initheader(L, &h);
  while (*fmt != '\0') {
    unsigned ntoalign;
    size_t size;
    KOption opt = getdetails(&h, pos, &fmt, &size, &ntoalign);
    luaL_argcheck(L, pos + ntoalign + size <= v->len, 2, "pack would exceed vector bounds");
    
    /* Fill alignment padding */
    while (ntoalign-- > 0)
      v->data[pos++] = LUAL_PACKPADBYTE;
    
    arg++;
    switch (opt) {
      case Kint: {
        lua_Integer n = luaL_checkinteger(L, arg);
        if (size < SZINT) {
          lua_Integer lim = (lua_Integer)1 << ((size * NB) - 1);
          luaL_argcheck(L, -lim <= n && n < lim, arg, "integer overflow");
        }
        packint(v->data + pos, (lua_Unsigned)n, h.islittle, (unsigned)size, (n < 0));
        break;
      }
      case Kuint: {
        lua_Integer n = luaL_checkinteger(L, arg);
        if (size < SZINT)
          luaL_argcheck(L, (lua_Unsigned)n < ((lua_Unsigned)1 << (size * NB)),
                        arg, "unsigned overflow");
        packint(v->data + pos, (lua_Unsigned)n, h.islittle, (unsigned)size, 0);
        break;
      }
      case Kfloat: {
        float f = (float)luaL_checknumber(L, arg);
        copywithendian(v->data + pos, (char *)&f, sizeof(f), h.islittle);
        break;
      }
      case Knumber: {
        lua_Number f = luaL_checknumber(L, arg);
        copywithendian(v->data + pos, (char *)&f, sizeof(f), h.islittle);
        break;
      }
      case Kdouble: {
        double f = (double)luaL_checknumber(L, arg);
        copywithendian(v->data + pos, (char *)&f, sizeof(f), h.islittle);
        break;
      }
      case Kchar: {
        size_t len;
        const char *s = luaL_checklstring(L, arg, &len);
        luaL_argcheck(L, len <= size, arg, "string longer than given size");
        memcpy(v->data + pos, s, len);
        if (len < size)
          memset(v->data + pos + len, LUAL_PACKPADBYTE, size - len);
        break;
      }
      case Kstring: {
        size_t len;
        const char *s = luaL_checklstring(L, arg, &len);
        luaL_argcheck(L, size >= sizeof(lua_Unsigned) ||
                      len < ((lua_Unsigned)1 << (size * NB)),
                      arg, "string length does not fit in given size");
        packint(v->data + pos, (lua_Unsigned)len, h.islittle, (unsigned)size, 0);
        luaL_argcheck(L, pos + size + len <= v->len, 2, "string would exceed vector bounds");
        memcpy(v->data + pos + size, s, len);
        pos += len;
        break;
      }
      case Kzstr: {
        size_t len;
        const char *s = luaL_checklstring(L, arg, &len);
        luaL_argcheck(L, strlen(s) == len, arg, "string contains zeros");
        luaL_argcheck(L, pos + len + 1 <= v->len, 2, "string would exceed vector bounds");
        memcpy(v->data + pos, s, len);
        v->data[pos + len] = '\0';
        pos += len + 1;
        size = 0;  /* already handled */
        break;
      }
      case Kpadding:
        v->data[pos] = LUAL_PACKPADBYTE;
        /* FALLTHROUGH */
      case Kpaddalign:
      case Knop:
        arg--;
        break;
    }
    pos += size;
  }
  return 0;
}


/*
** vector.unpack(v, offset, fmt)
*/
static int vec_unpack(lua_State *L) {
  Vector *v = checkvector(L, 1);
  lua_Integer offset = luaL_checkinteger(L, 2);
  const char *fmt = luaL_checkstring(L, 3);
  Header h;
  size_t pos = (size_t)offset;
  int n = 0;
  
  luaL_argcheck(L, offset >= 0 && (size_t)offset <= v->len, 2, "offset out of bounds");
  
  initheader(L, &h);
  while (*fmt != '\0') {
    unsigned ntoalign;
    size_t size;
    KOption opt = getdetails(&h, pos, &fmt, &size, &ntoalign);
    luaL_argcheck(L, pos + ntoalign + size <= v->len, 2, "data too short");
    pos += ntoalign;
    luaL_checkstack(L, 2, "too many results");
    n++;
    switch (opt) {
      case Kint:
      case Kuint: {
        lua_Integer res = unpackint(L, v->data + pos, h.islittle,
                                    (int)size, (opt == Kint));
        lua_pushinteger(L, res);
        break;
      }
      case Kfloat: {
        float f;
        copywithendian((char *)&f, v->data + pos, sizeof(f), h.islittle);
        lua_pushnumber(L, (lua_Number)f);
        break;
      }
      case Knumber: {
        lua_Number f;
        copywithendian((char *)&f, v->data + pos, sizeof(f), h.islittle);
        lua_pushnumber(L, f);
        break;
      }
      case Kdouble: {
        double f;
        copywithendian((char *)&f, v->data + pos, sizeof(f), h.islittle);
        lua_pushnumber(L, (lua_Number)f);
        break;
      }
      case Kchar: {
        lua_pushlstring(L, v->data + pos, size);
        break;
      }
      case Kstring: {
        lua_Unsigned len = (lua_Unsigned)unpackint(L, v->data + pos, h.islittle,
                                                   (int)size, 0);
        luaL_argcheck(L, len <= v->len - pos - size, 2, "data too short");
        lua_pushlstring(L, v->data + pos + size, (size_t)len);
        pos += (size_t)len;
        break;
      }
      case Kzstr: {
        size_t len = strlen(v->data + pos);
        luaL_argcheck(L, pos + len < v->len, 2, "unfinished string in vector");
        lua_pushlstring(L, v->data + pos, len);
        pos += len + 1;
        size = 0;
        break;
      }
      case Kpaddalign:
      case Kpadding:
      case Knop:
        n--;
        break;
    }
    pos += size;
  }
  lua_pushinteger(L, (lua_Integer)pos);  /* next position */
  return n + 1;
}


/*
** vector.clone(v)
*/
static int vec_clone(lua_State *L) {
  Vector *v = checkvector(L, 1);
  Vector *clone = luaV_clone(L, v);
  setvecvalue(L, s2v(L->top.p), clone);
  L->top.p++;
  return 1;
}


/*
** vector.size(v)
*/
static int vec_size(lua_State *L) {
  Vector *v = checkvector(L, 1);
  lua_pushinteger(L, (lua_Integer)v->len);
  return 1;
}


/*
** vector.resize(v, newsize)
*/
static int vec_resize(lua_State *L) {
  Vector *v = checkvector(L, 1);
  lua_Integer newsize = luaL_checkinteger(L, 2);
  luaL_argcheck(L, newsize >= 0, 2, "size must be non-negative");
  luaV_resize(L, v, (size_t)newsize);
  return 0;
}


/*
** Iterator state for vector.unpackmany
*/
typedef struct UnpackManyState {
  int offset;
  int count;
  int maxcount;
} UnpackManyState;


/*
** Iterator function for vector.unpackmany
*/
static int unpackmany_iter(lua_State *L) {
  /* Get vector from upvalue - need to use API since upvalue index doesn't work with checkvector */
  if (!lua_isvector(L, lua_upvalueindex(1)))
    return luaL_error(L, "expected vector in upvalue");
  StkId uvslot = L->ci->func.p;  /* closure is at function slot */
  /* For upvalue access, we need to get the TValue from the upvalue */
  TValue *uv = NULL;
  {
    CClosure *cl = clCvalue(s2v(uvslot));
    uv = &cl->upvalue[0];  /* first upvalue is vector */
  }
  if (!ttisvector(uv))
    return luaL_error(L, "expected vector in upvalue");
  Vector *v = vecvalue(uv);
  
  const char *fmt = lua_tostring(L, lua_upvalueindex(2));
  lua_Integer pos = lua_tointeger(L, lua_upvalueindex(3));
  lua_Integer count = lua_tointeger(L, lua_upvalueindex(4));
  lua_Integer maxcount = lua_tointeger(L, lua_upvalueindex(5));
  
  /* Check if we've reached the limit */
  if (maxcount > 0 && count >= maxcount)
    return 0;
  
  /* Check if we're at the end of the vector */
  if ((size_t)pos >= v->len)
    return 0;
  
  /* Temporarily set up for unpack */
  Header h;
  const char *fmtcopy = fmt;
  size_t fmtpos = (size_t)pos;
  int n = 0;
  
  initheader(L, &h);
  while (*fmtcopy != '\0') {
    unsigned ntoalign;
    size_t size;
    KOption opt = getdetails(&h, fmtpos, &fmtcopy, &size, &ntoalign);
    
    if (fmtpos + ntoalign + size > v->len)
      return luaL_error(L, "unpack falls out of bounds");
    
    fmtpos += ntoalign;
    luaL_checkstack(L, 2, "too many results");
    
    switch (opt) {
      case Kint:
      case Kuint: {
        lua_Integer res = unpackint(L, v->data + fmtpos, h.islittle,
                                    (int)size, (opt == Kint));
        lua_pushinteger(L, res);
        n++;
        break;
      }
      case Kfloat: {
        float f;
        copywithendian((char *)&f, v->data + fmtpos, sizeof(f), h.islittle);
        lua_pushnumber(L, (lua_Number)f);
        n++;
        break;
      }
      case Knumber: {
        lua_Number f;
        copywithendian((char *)&f, v->data + fmtpos, sizeof(f), h.islittle);
        lua_pushnumber(L, f);
        n++;
        break;
      }
      case Kdouble: {
        double f;
        copywithendian((char *)&f, v->data + fmtpos, sizeof(f), h.islittle);
        lua_pushnumber(L, (lua_Number)f);
        n++;
        break;
      }
      case Kchar: {
        lua_pushlstring(L, v->data + fmtpos, size);
        n++;
        break;
      }
      case Kstring: {
        lua_Unsigned len = (lua_Unsigned)unpackint(L, v->data + fmtpos, h.islittle,
                                                   (int)size, 0);
        if (len > v->len - fmtpos - size)
          return luaL_error(L, "data too short");
        lua_pushlstring(L, v->data + fmtpos + size, (size_t)len);
        fmtpos += (size_t)len;
        n++;
        break;
      }
      case Kzstr: {
        size_t len = strlen(v->data + fmtpos);
        if (fmtpos + len >= v->len)
          return luaL_error(L, "unfinished string in vector");
        lua_pushlstring(L, v->data + fmtpos, len);
        fmtpos += len + 1;
        size = 0;
        n++;
        break;
      }
      case Kpaddalign:
      case Kpadding:
      case Knop:
        break;
    }
    fmtpos += size;
  }
  
  /* Update position and count in upvalues */
  lua_pushinteger(L, (lua_Integer)fmtpos);
  lua_replace(L, lua_upvalueindex(3));
  lua_pushinteger(L, count + 1);
  lua_replace(L, lua_upvalueindex(4));
  
  return n;
}


/*
** vector.unpackmany(v, offset, fmt [, count])
*/
static int vec_unpackmany(lua_State *L) {
  checkvector(L, 1);  /* just validate */
  luaL_checkinteger(L, 2);  /* offset */
  luaL_checkstring(L, 3);   /* format */
  lua_Integer maxcount = luaL_optinteger(L, 4, 0);
  
  /* Push the iterator function with upvalues:
   * 1: vector, 2: format, 3: current position, 4: count, 5: maxcount */
  lua_pushvalue(L, 1);  /* vector */
  lua_pushvalue(L, 3);  /* format */
  lua_pushvalue(L, 2);  /* initial position */
  lua_pushinteger(L, 0);  /* count = 0 */
  lua_pushinteger(L, maxcount);
  lua_pushcclosure(L, unpackmany_iter, 5);
  
  return 1;
}


static const luaL_Reg veclib[] = {
  {"create", vec_create},
  {"pack", vec_pack},
  {"unpack", vec_unpack},
  {"clone", vec_clone},
  {"size", vec_size},
  {"resize", vec_resize},
  {"unpackmany", vec_unpackmany},
  {NULL, NULL}
};


LUAMOD_API int luaopen_vector(lua_State *L) {
  luaL_newlib(L, veclib);
  return 1;
}
