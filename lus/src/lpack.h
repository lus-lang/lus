/*
** $Id: lpack.h $
** Shared pack/unpack utilities for string and vector libraries
** See Copyright Notice in lua.h
*/

#ifndef lpack_h
#define lpack_h

#include <limits.h>

#include "lua.h"
#include "lauxlib.h"
#include "llimits.h"


/* value used for padding */
#if !defined(LPACK_PADBYTE)
#define LPACK_PADBYTE 0x00
#endif

/* maximum size for the binary representation of an integer */
#define LPACK_MAXINTSIZE 16

/* number of bits in a character */
#define LPACK_NB CHAR_BIT

/* mask for one character (LPACK_NB 1's) */
#define LPACK_MC ((1 << LPACK_NB) - 1)

/* size of a lua_Integer */
#define LPACK_SZINT ((int)sizeof(lua_Integer))


/*
** Information to pack/unpack stuff
*/
typedef struct lpack_Header {
  lua_State *L;
  int islittle;
  unsigned maxalign;
} lpack_Header;


/*
** Options for pack/unpack
*/
typedef enum lpack_KOption {
  Lpack_Kint,       /* signed integers */
  Lpack_Kuint,      /* unsigned integers */
  Lpack_Kfloat,     /* single-precision floating-point numbers */
  Lpack_Knumber,    /* Lua "native" floating-point numbers */
  Lpack_Kdouble,    /* double-precision floating-point numbers */
  Lpack_Kchar,      /* fixed-length strings */
  Lpack_Kstring,    /* strings with prefixed length */
  Lpack_Kzstr,      /* zero-terminated strings */
  Lpack_Kpadding,   /* padding */
  Lpack_Kpaddalign, /* padding for alignment */
  Lpack_Knop        /* no-op (configuration or spaces) */
} lpack_KOption;


/* Returns 1 if machine is little-endian */
LUAI_FUNC int lpack_nativeislittle(void);

/* Initialize header with native endianness */
LUAI_FUNC void lpack_initheader(lua_State *L, lpack_Header *h);

/* Read and classify next option from format string */
LUAI_FUNC lpack_KOption lpack_getoption(lpack_Header *h, const char **fmt,
                                         size_t *size);

/* Get details including alignment requirements */
LUAI_FUNC lpack_KOption lpack_getdetails(lpack_Header *h, size_t totalsize,
                                          const char **fmt, size_t *psize,
                                          unsigned *ntoalign);

/* Pack integer into buffer (raw, no luaL_Buffer) */
LUAI_FUNC void lpack_packint(char *buff, lua_Unsigned n, int islittle,
                              unsigned size, int neg);

/* Unpack integer from buffer */
LUAI_FUNC lua_Integer lpack_unpackint(lua_State *L, const char *str,
                                       int islittle, int size, int issigned);

/* Copy with endianness correction */
LUAI_FUNC void lpack_copywithendian(char *dest, const char *src,
                                     unsigned size, int islittle);


#endif
