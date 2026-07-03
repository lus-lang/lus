/*
** $Id: lenum.c $
** Enum handling
** See Copyright Notice in lua.h
*/

#define lenum_c
#define LUA_CORE

#include "lprefix.h"

#include <string.h>

#include "lua.h"

#include "ldebug.h"
#include "lenum.h"
#include "lgc.h"
#include "lmem.h"
#include "lobject.h"
#include "lstate.h"
#include "lstring.h"


/*
** Create a new EnumRoot with 'size' names.
** The names array is uninitialized and should be filled by the caller.
*/
EnumRoot *luaE_newroot(lua_State *L, int size) {
  size_t sz;
  if (size < 1) /* real check: api_check vanishes in release builds, and a
                   zero-size root would make luaE_new's value cache a
                   zero-length (NULL) vector that luaE_new writes into */
    luaG_runerror(L, "enum must have at least one member");
  if ((size_t)size >
      (MAX_SIZE - offsetof(EnumRoot, names)) / sizeof(TString *))
    luaM_toobig(L); /* sizeenumroot would overflow */
  sz = sizeenumroot(size);
  GCObject *o = luaC_newobjdt(L, LUA_VENUMROOT, sz, 0);
  EnumRoot *root = gco2enumroot(o);
  root->size = size;
  root->gclist = NULL;
  root->cache = NULL; /* created lazily on first value access */
  /* Initialize names to NULL (caller will fill them in) */
  for (int i = 0; i < size; i++)
    root->names[i] = NULL;
  return root;
}


/*
** Get the Enum value for (root, idx), creating and interning it on first
** access. Enums are immutable and compare by (root, idx), so one object
** per index is enough; interning removes an allocation from every enum
** access in the VM. Callers must have 'root' reachable by the GC (all do:
** it is anchored on the stack or referenced by the value being indexed),
** so the allocations below cannot collect it.
*/
Enum *luaE_new(lua_State *L, EnumRoot *root, int idx) {
  GCObject *o;
  Enum *e;
  if (root->cache == NULL) {
    int i;
    Enum **cache = luaM_newvector(L, root->size, Enum *);
    for (i = 0; i < root->size; i++)
      cache[i] = NULL;
    root->cache = cache;
  }
  else if ((e = root->cache[idx - 1]) != NULL)
    return e; /* already interned */
  o = luaC_newobj(L, LUA_VENUM, sizeenum);
  e = gco2enum(o);
  e->root = root;
  e->idx = idx;
  root->cache[idx - 1] = e;
  /* 'root' may be black and 'e' is white: keep the invariant */
  luaC_objbarrier(L, obj2gco(root), o);
  return e;
}


/*
** Look up an enum value by name string.
** Returns the 1-based index if found, 0 if not found.
*/
int luaE_findname(EnumRoot *root, TString *name) {
  int i;
  for (i = 0; i < root->size; i++) {
    if (root->names[i] == name) /* short strings are interned */
      return i + 1;             /* 1-based index */
  }
  return 0; /* not found */
}


/*
** Get an enum value from the root by string key.
** Creates and returns a new Enum value, or returns NULL if key not found.
*/
Enum *luaE_getbyname(lua_State *L, EnumRoot *root, TString *key) {
  int idx = luaE_findname(root, key);
  if (idx == 0)
    return NULL; /* not found */
  return luaE_new(L, root, idx);
}


/*
** Get an enum value from the root by integer index.
** Creates and returns a new Enum value, or returns NULL if index out of bounds.
*/
Enum *luaE_getbyidx(lua_State *L, EnumRoot *root, int idx) {
  if (idx < 1 || idx > root->size)
    return NULL; /* out of bounds */
  return luaE_new(L, root, idx);
}


/*
** Free an EnumRoot.
*/
void luaE_freeroot(lua_State *L, EnumRoot *root) {
  if (root->cache != NULL)
    luaM_freearray(L, root->cache, root->size);
  luaM_freemem(L, root, sizeenumroot(root->size));
}


/*
** Free an Enum value.
*/
void luaE_free(lua_State *L, Enum *e) {
  luaM_freemem(L, e, sizeenum);
}


/*
** Get the size (in bytes) of an EnumRoot.
*/
lu_mem luaE_rootsize(EnumRoot *root) {
  lu_mem sz = cast(lu_mem, sizeenumroot(root->size));
  if (root->cache != NULL) /* must match what luaE_freeroot releases */
    sz += cast(lu_mem, root->size * sizeof(Enum *));
  return sz;
}
