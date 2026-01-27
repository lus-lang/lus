/*
** $Id: lzio.h $
** Buffered streams
** See Copyright Notice in lua.h
*/


#ifndef lzio_h
#define lzio_h

#include "larena.h"
#include "lua.h"


#define EOZ (-1) /* end of stream */

typedef struct Zio ZIO;

#define zgetc(z) (((z)->n--) > 0 ? cast_uchar(*(z)->p++) : luaZ_fill(z))


/*
** Mbuffer: Arena-backed resizable buffer for lexer tokens
** Uses arena allocation for fast reset and cleanup.
*/
typedef struct Mbuffer {
  char *buffer;      /* current buffer pointer */
  size_t n;          /* bytes used in buffer */
  size_t buffsize;   /* current buffer capacity */
  LuaArena *arena;   /* arena for buffer allocation */
} Mbuffer;

/* Initialize buffer with arena */
LUAI_FUNC void luaZ_initbuffer(lua_State *L, Mbuffer *buff);

/* Free buffer and its arena */
LUAI_FUNC void luaZ_freebuffer(lua_State *L, Mbuffer *buff);

/* Resize buffer (allocates from arena) */
LUAI_FUNC void luaZ_resizebuffer(lua_State *L, Mbuffer *buff, size_t size);

#define luaZ_buffer(buff) ((buff)->buffer)
#define luaZ_sizebuffer(buff) ((buff)->buffsize)
#define luaZ_bufflen(buff) ((buff)->n)

#define luaZ_buffremove(buff, i) ((buff)->n -= cast_sizet(i))
#define luaZ_resetbuffer(buff) ((buff)->n = 0)


LUAI_FUNC void luaZ_init(lua_State *L, ZIO *z, lua_Reader reader, void *data);
LUAI_FUNC size_t luaZ_read(ZIO *z, void *b, size_t n); /* read next n bytes */

LUAI_FUNC const void *luaZ_getaddr(ZIO *z, size_t n);


/* --------- Private Part ------------------ */

struct Zio {
  size_t n;          /* bytes still unread */
  const char *p;     /* current position in buffer */
  lua_Reader reader; /* reader function */
  void *data;        /* additional data */
  lua_State *L;      /* Lua state (for reader) */
};


LUAI_FUNC int luaZ_fill(ZIO *z);

#endif
