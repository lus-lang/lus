/*
** larena.c
** Arena allocator for Lus
** See Copyright Notice in lua.h
*/

#define larena_c
#define LUA_CORE

#include "lprefix.h"

#include <string.h>

#include "larena.h"
#include "lmem.h"

/*
** Align size up to LUAA_ALIGNMENT boundary
*/
#define ALIGN_UP(size) (((size) + LUAA_ALIGNMENT - 1) & ~(LUAA_ALIGNMENT - 1))

/*
** Create a new arena block of the given data size
*/
static LuaArenaBlock *newblock(lua_State *L, size_t data_size) {
  size_t total_size = sizeof(LuaArenaBlock) + data_size;
  LuaArenaBlock *block = (LuaArenaBlock *)luaM_malloc_(L, total_size, 0);
  block->next = NULL;
  block->current = block->data;
  block->end = block->data + data_size;
  return block;
}

/*
** Free a single block
*/
static void freeblock(lua_State *L, LuaArenaBlock *block, size_t data_size) {
  size_t total_size = sizeof(LuaArenaBlock) + data_size;
  luaM_freemem(L, block, total_size);
}

/*
** Create a new arena with specified block size
*/
LuaArena *luaA_new(lua_State *L, size_t block_size) {
  LuaArena *a;
  LuaArenaBlock *block;

  /* Ensure reasonable minimum block size */
  if (block_size < 1024)
    block_size = 1024;

  /* Allocate arena structure */
  a = luaM_new(L, LuaArena);
  a->L = L;
  a->block_size = block_size;
  a->total_alloc = 0;
  a->num_allocs = 0;

  /* Allocate initial block */
  block = newblock(L, block_size);
  a->head = block;
  a->cur = block;

  return a;
}

/*
** Allocate memory from arena
** Returns aligned pointer, or adds new block if current is exhausted
*/
void *luaA_alloc(LuaArena *a, size_t size) {
  LuaArenaBlock *block;
  size_t aligned_size;
  char *ptr;

  /* Align the allocation size */
  aligned_size = ALIGN_UP(size);

  /* Try to allocate from current block */
  block = a->cur;
  if (block->current + aligned_size <= block->end) {
    ptr = block->current;
    block->current += aligned_size;
    a->total_alloc += aligned_size;
    a->num_allocs++;
    return ptr;
  }

  /* Current block is full - try next block in chain (if reset was called) */
  if (block->next != NULL) {
    a->cur = block->next;
    return luaA_alloc(a, size);
  }

  /* Need to allocate a new block */
  {
    size_t new_block_size = a->block_size;

    /* If requested size is larger than block size, allocate a bigger block */
    if (aligned_size > new_block_size)
      new_block_size = aligned_size;

    block = newblock(a->L, new_block_size);
    a->cur->next = block;
    a->cur = block;

    /* Allocate from new block */
    ptr = block->current;
    block->current += aligned_size;
    a->total_alloc += aligned_size;
    a->num_allocs++;
    return ptr;
  }
}

/*
** Reset arena for reuse
** Keeps allocated blocks but resets allocation pointers
*/
void luaA_reset(LuaArena *a) {
  LuaArenaBlock *block;

  /* Reset all blocks */
  for (block = a->head; block != NULL; block = block->next) {
    block->current = block->data;
  }

  /* Reset to first block */
  a->cur = a->head;
  a->total_alloc = 0;
  a->num_allocs = 0;
}

/*
** Free arena and all its blocks
*/
void luaA_free(LuaArena *a) {
  lua_State *L;
  LuaArenaBlock *block;
  LuaArenaBlock *next;

  if (a == NULL)
    return;

  L = a->L;

  /* Free all blocks */
  block = a->head;
  while (block != NULL) {
    next = block->next;
    /* Calculate actual data size for this block */
    size_t data_size = (size_t)(block->end - block->data);
    freeblock(L, block, data_size);
    block = next;
  }

  /* Free arena structure */
  luaM_free(L, a);
}


/*
** =======================================================
** Standalone Arena Implementation (malloc-based)
** =======================================================
*/

#include <stdlib.h>

/*
** Create a new standalone arena block
*/
static StandaloneArenaBlock *newstandaloneblock(size_t data_size) {
  size_t total_size = sizeof(StandaloneArenaBlock) + data_size;
  StandaloneArenaBlock *block = (StandaloneArenaBlock *)malloc(total_size);
  if (block == NULL)
    return NULL;
  block->next = NULL;
  block->current = block->data;
  block->end = block->data + data_size;
  return block;
}

/*
** Create a new standalone arena
*/
StandaloneArena *luaA_newstandalone(size_t block_size) {
  StandaloneArena *a;
  StandaloneArenaBlock *block;

  /* Ensure reasonable minimum block size */
  if (block_size < 256)
    block_size = 256;

  /* Allocate arena structure */
  a = (StandaloneArena *)malloc(sizeof(StandaloneArena));
  if (a == NULL)
    return NULL;

  a->block_size = block_size;
  a->total_alloc = 0;

  /* Allocate initial block */
  block = newstandaloneblock(block_size);
  if (block == NULL) {
    free(a);
    return NULL;
  }
  a->head = block;
  a->cur = block;

  return a;
}

/*
** Allocate from standalone arena
*/
void *luaA_allocstandalone(StandaloneArena *a, size_t size) {
  StandaloneArenaBlock *block;
  size_t aligned_size;
  char *ptr;

  /* Align the allocation size */
  aligned_size = ALIGN_UP(size);

  /* Try to allocate from current block */
  block = a->cur;
  if (block->current + aligned_size <= block->end) {
    ptr = block->current;
    block->current += aligned_size;
    a->total_alloc += aligned_size;
    return ptr;
  }

  /* Current block is full - try next block in chain */
  if (block->next != NULL) {
    a->cur = block->next;
    return luaA_allocstandalone(a, size);
  }

  /* Need to allocate a new block */
  {
    size_t new_block_size = a->block_size;

    /* If requested size is larger than block size, allocate a bigger block */
    if (aligned_size > new_block_size)
      new_block_size = aligned_size;

    block = newstandaloneblock(new_block_size);
    if (block == NULL)
      return NULL; /* allocation failed */

    a->cur->next = block;
    a->cur = block;

    /* Allocate from new block */
    ptr = block->current;
    block->current += aligned_size;
    a->total_alloc += aligned_size;
    return ptr;
  }
}

/*
** Reset standalone arena for reuse
*/
void luaA_resetstandalone(StandaloneArena *a) {
  StandaloneArenaBlock *block;

  if (a == NULL)
    return;

  /* Reset all blocks */
  for (block = a->head; block != NULL; block = block->next) {
    block->current = block->data;
  }

  /* Reset to first block */
  a->cur = a->head;
  a->total_alloc = 0;
}

/*
** Free standalone arena and all its blocks
*/
void luaA_freestandalone(StandaloneArena *a) {
  StandaloneArenaBlock *block;
  StandaloneArenaBlock *next;

  if (a == NULL)
    return;

  /* Free all blocks */
  block = a->head;
  while (block != NULL) {
    next = block->next;
    free(block);
    block = next;
  }

  /* Free arena structure */
  free(a);
}
