/*
** larena.h
** Arena allocator for Lus
** See Copyright Notice in lua.h
*/

#ifndef larena_h
#define larena_h

#include <stddef.h>

#include "llimits.h"
#include "lua.h"

/*
** Arena block - a chunk of memory for bump allocation
*/
typedef struct LuaArenaBlock {
  struct LuaArenaBlock *next; /* next block in chain (for overflow) */
  char *current;              /* current allocation pointer */
  char *end;                  /* end of this block */
  char data[];                /* flexible array member for block data */
} LuaArenaBlock;

/*
** Arena structure
** Provides fast bump allocation with O(1) reset/free
*/
typedef struct LuaArena {
  lua_State *L;        /* lua state for block allocation */
  LuaArenaBlock *head; /* first block (main arena) */
  LuaArenaBlock *cur;  /* current block being allocated from */
  size_t block_size;   /* size of each block */
  size_t total_alloc;  /* total bytes allocated from arena */
  size_t num_allocs;   /* number of individual allocations */
} LuaArena;

/*
** Default arena block size (64KB - good balance for AST nodes)
*/
#define LUAA_DEFAULT_BLOCKSIZE (64 * 1024)

/*
** Minimum alignment for arena allocations (pointer-sized)
*/
#define LUAA_ALIGNMENT sizeof(void *)

/*
** Arena API Functions
*/

/* Create a new arena with specified block size */
LUAI_FUNC LuaArena *luaA_new(lua_State *L, size_t block_size);

/* Create a new arena with default block size */
#define luaA_newdefault(L) luaA_new(L, LUAA_DEFAULT_BLOCKSIZE)

/* Allocate memory from arena (returns aligned pointer) */
LUAI_FUNC void *luaA_alloc(LuaArena *a, size_t size);

/* Reset arena for reuse (keeps allocated blocks, resets pointers) */
LUAI_FUNC void luaA_reset(LuaArena *a);

/* Free arena and all its blocks */
LUAI_FUNC void luaA_free(LuaArena *a);

/*
** Convenience macros
*/

/* Allocate a single object of given type */
#define luaA_new_obj(a, type) ((type *)luaA_alloc(a, sizeof(type)))

/* Allocate an array of objects */
#define luaA_new_array(a, n, type) ((type *)luaA_alloc(a, (n) * sizeof(type)))


/*
** =======================================================
** Standalone Arena (malloc-based, thread-safe ownership transfer)
** =======================================================
** This arena uses malloc/free instead of Lua's allocator, making it
** safe to create in one thread and free in another. Used for cross-thread
** data like serialized messages.
*/

typedef struct StandaloneArenaBlock {
  struct StandaloneArenaBlock *next;
  char *current;
  char *end;
  char data[];
} StandaloneArenaBlock;

typedef struct StandaloneArena {
  StandaloneArenaBlock *head;
  StandaloneArenaBlock *cur;
  size_t block_size;
  size_t total_alloc;
} StandaloneArena;

/* Create a new standalone arena */
LUAI_FUNC StandaloneArena *luaA_newstandalone(size_t block_size);

/* Allocate from standalone arena */
LUAI_FUNC void *luaA_allocstandalone(StandaloneArena *a, size_t size);

/* Reset standalone arena */
LUAI_FUNC void luaA_resetstandalone(StandaloneArena *a);

/* Free standalone arena */
LUAI_FUNC void luaA_freestandalone(StandaloneArena *a);

/* Convenience macros for standalone arena */
#define luaA_standalone_obj(a, type) ((type *)luaA_allocstandalone(a, sizeof(type)))
#define luaA_standalone_array(a, n, type) \
  ((type *)luaA_allocstandalone(a, (n) * sizeof(type)))

#endif
