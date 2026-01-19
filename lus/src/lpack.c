/*
** $Id: lpack.c $
** Shared pack/unpack utilities for string and vector libraries
** See Copyright Notice in lua.h
*/

#define lpack_c
#define LUA_LIB

#include "lprefix.h"

#include <limits.h>
#include <stddef.h>
#include <string.h>

#include "lua.h"

#include "lauxlib.h"
#include "lpack.h"
#include "llimits.h"


/* dummy union to get native endianness */
static const union {
  int dummy;
  char little; /* true iff machine is little endian */
} nativeendian = {1};


int lpack_nativeislittle(void) {
  return nativeendian.little;
}


void lpack_initheader(lua_State *L, lpack_Header *h) {
  h->L = L;
  h->islittle = nativeendian.little;
  h->maxalign = 1;
}


/* Check if character is a digit */
static int lpack_digit(int c) {
  return '0' <= c && c <= '9';
}


/*
** Read an integer numeral from string 'fmt' or return 'df' if
** there is no numeral
*/
static size_t lpack_getnum(const char **fmt, size_t df) {
  if (!lpack_digit(**fmt)) /* no number? */
    return df;             /* return default value */
  else {
    size_t a = 0;
    do {
      a = a * 10 + cast_uint(*((*fmt)++) - '0');
    } while (lpack_digit(**fmt) && a <= (MAX_SIZE - 9) / 10);
    return a;
  }
}


/*
** Read an integer numeral and raises an error if it is larger
** than the maximum size of integers.
*/
static unsigned lpack_getnumlimit(lpack_Header *h, const char **fmt,
                                   size_t df) {
  size_t sz = lpack_getnum(fmt, df);
  if (l_unlikely((sz - 1u) >= LPACK_MAXINTSIZE))
    return cast_uint(
        luaL_error(h->L, "integral size (%d) out of limits [1,%d]", sz,
                   LPACK_MAXINTSIZE));
  return cast_uint(sz);
}


lpack_KOption lpack_getoption(lpack_Header *h, const char **fmt, size_t *size) {
  /* dummy structure to get native alignment requirements */
  struct cD {
    char c;
    union {
      LUAI_MAXALIGN;
    } u;
  };
  int opt = *((*fmt)++);
  *size = 0; /* default */
  switch (opt) {
    case 'b': *size = sizeof(char); return Lpack_Kint;
    case 'B': *size = sizeof(char); return Lpack_Kuint;
    case 'h': *size = sizeof(short); return Lpack_Kint;
    case 'H': *size = sizeof(short); return Lpack_Kuint;
    case 'l': *size = sizeof(long); return Lpack_Kint;
    case 'L': *size = sizeof(long); return Lpack_Kuint;
    case 'j': *size = sizeof(lua_Integer); return Lpack_Kint;
    case 'J': *size = sizeof(lua_Integer); return Lpack_Kuint;
    case 'T': *size = sizeof(size_t); return Lpack_Kuint;
    case 'f': *size = sizeof(float); return Lpack_Kfloat;
    case 'n': *size = sizeof(lua_Number); return Lpack_Knumber;
    case 'd': *size = sizeof(double); return Lpack_Kdouble;
    case 'i': *size = lpack_getnumlimit(h, fmt, sizeof(int)); return Lpack_Kint;
    case 'I': *size = lpack_getnumlimit(h, fmt, sizeof(int)); return Lpack_Kuint;
    case 's':
      *size = lpack_getnumlimit(h, fmt, sizeof(size_t));
      return Lpack_Kstring;
    case 'c':
      *size = lpack_getnum(fmt, cast_sizet(-1));
      if (l_unlikely(*size == cast_sizet(-1)))
        luaL_error(h->L, "missing size for format option 'c'");
      return Lpack_Kchar;
    case 'z': return Lpack_Kzstr;
    case 'x': *size = 1; return Lpack_Kpadding;
    case 'X': return Lpack_Kpaddalign;
    case ' ': break;
    case '<': h->islittle = 1; break;
    case '>': h->islittle = 0; break;
    case '=': h->islittle = nativeendian.little; break;
    case '!': {
      const size_t maxalign = offsetof(struct cD, u);
      h->maxalign = lpack_getnumlimit(h, fmt, maxalign);
      break;
    }
    default: luaL_error(h->L, "invalid format option '%c'", opt);
  }
  return Lpack_Knop;
}


lpack_KOption lpack_getdetails(lpack_Header *h, size_t totalsize,
                                const char **fmt, size_t *psize,
                                unsigned *ntoalign) {
  lpack_KOption opt = lpack_getoption(h, fmt, psize);
  size_t align = *psize; /* usually, alignment follows size */
  if (opt == Lpack_Kpaddalign) { /* 'X' gets alignment from following option */
    if (**fmt == '\0' || lpack_getoption(h, fmt, &align) == Lpack_Kchar ||
        align == 0)
      luaL_argerror(h->L, 1, "invalid next option for option 'X'");
  }
  if (align <= 1 || opt == Lpack_Kchar) /* need no alignment? */
    *ntoalign = 0;
  else {
    if (align > h->maxalign) /* enforce maximum alignment */
      align = h->maxalign;
    if (l_unlikely(!ispow2(align))) { /* not a power of 2? */
      *ntoalign = 0;                  /* to avoid warnings */
      luaL_argerror(h->L, 1, "format asks for alignment not power of 2");
    } else {
      /* 'szmoda' = totalsize % align */
      unsigned szmoda = cast_uint(totalsize & (align - 1));
      *ntoalign = cast_uint((align - szmoda) & (align - 1));
    }
  }
  return opt;
}


void lpack_packint(char *buff, lua_Unsigned n, int islittle, unsigned size,
                    int neg) {
  unsigned i;
  buff[islittle ? 0 : size - 1] = (char)(n & LPACK_MC); /* first byte */
  for (i = 1; i < size; i++) {
    n >>= LPACK_NB;
    buff[islittle ? i : size - 1 - i] = (char)(n & LPACK_MC);
  }
  if (neg && size > LPACK_SZINT) { /* negative number need sign extension? */
    for (i = LPACK_SZINT; i < size; i++) /* correct extra bytes */
      buff[islittle ? i : size - 1 - i] = (char)LPACK_MC;
  }
}


void lpack_copywithendian(char *dest, const char *src, unsigned size,
                           int islittle) {
  if (islittle == nativeendian.little)
    memcpy(dest, src, size);
  else {
    dest += size - 1;
    while (size-- != 0)
      *(dest--) = *(src++);
  }
}


lua_Integer lpack_unpackint(lua_State *L, const char *str, int islittle,
                             int size, int issigned) {
  lua_Unsigned res = 0;
  int i;
  int limit = (size <= LPACK_SZINT) ? size : LPACK_SZINT;
  for (i = limit - 1; i >= 0; i--) {
    res <<= LPACK_NB;
    res |= (lua_Unsigned)(unsigned char)str[islittle ? i : size - 1 - i];
  }
  if (size < LPACK_SZINT) { /* real size smaller than lua_Integer? */
    if (issigned) {         /* needs sign extension? */
      lua_Unsigned mask = (lua_Unsigned)1 << (size * LPACK_NB - 1);
      res = ((res ^ mask) - mask); /* do sign extension */
    }
  } else if (size > LPACK_SZINT) { /* must check unread bytes */
    int mask = (!issigned || (lua_Integer)res >= 0) ? 0 : LPACK_MC;
    for (i = limit; i < size; i++) {
      if (l_unlikely((unsigned char)str[islittle ? i : size - 1 - i] != mask))
        luaL_error(L, "%d-byte integer does not fit into Lua Integer", size);
    }
  }
  return (lua_Integer)res;
}
