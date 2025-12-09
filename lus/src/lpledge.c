/*
** lpledge.c
** Permission system for Lus
*/

#define lpledge_c
#define LUA_CORE

#include "lprefix.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lmem.h"
#include "lpledge.h"
#include "lstate.h"
#include "lua.h"

/*
** ========================================================
** Data Structures
** ========================================================
*/

/* Maximum number of values per permission */
#define MAX_VALUES_PER_PLEDGE 32

/* Maximum number of registered granters */
#define MAX_GRANTERS 32

/* Maximum permission name length */
#define MAX_PLEDGE_NAME 256

/* Single permission entry */
typedef struct PledgeEntry {
  char *name;                          /* permission name (e.g., "fs:read") */
  char *values[MAX_VALUES_PER_PLEDGE]; /* array of granted values */
  int nvalues;                         /* number of values */
  int rejected;                        /* 1 if permission was rejected */
} PledgeEntry;

/* Granter registration */
typedef struct GranterEntry {
  char *name;             /* permission name prefix */
  lus_PledgeGranter func; /* granter callback */
} GranterEntry;

/* Permission store (per-thread) */
struct PledgeStore {
  PledgeEntry *entries;                /* array of permission entries */
  int nentries;                        /* number of entries */
  int capacity;                        /* allocated capacity */
  int sealed;                          /* 1 if sealed (no more changes) */
  GranterEntry granters[MAX_GRANTERS]; /* registered granters */
  int ngranters;                       /* number of granters */
  char *error_msg;                     /* error message from granter */
};

/*
** ========================================================
** Internal Helpers
** ========================================================
*/

/* Get or create a pledge store for the state */
static PledgeStore *getstore(lua_State *L) {
  if (L->pledges == NULL) {
    L->pledges = luaM_new(L, PledgeStore);
    L->pledges->entries = NULL;
    L->pledges->nentries = 0;
    L->pledges->capacity = 0;
    L->pledges->sealed = 0;
    L->pledges->ngranters = 0;
    L->pledges->error_msg = NULL;
  }
  return L->pledges;
}

/* Find a permission entry by name */
static PledgeEntry *findentry(PledgeStore *store, const char *name) {
  if (store == NULL)
    return NULL;
  for (int i = 0; i < store->nentries; i++) {
    if (strcmp(store->entries[i].name, name) == 0)
      return &store->entries[i];
  }
  return NULL;
}

/* Find a granter by permission name */
static lus_PledgeGranter findgranter(PledgeStore *store, const char *name) {
  if (store == NULL)
    return NULL;

  /* First try exact match */
  for (int i = 0; i < store->ngranters; i++) {
    if (strcmp(store->granters[i].name, name) == 0)
      return store->granters[i].func;
  }

  /* Try base permission (before :) */
  const char *colon = strchr(name, ':');
  if (colon) {
    size_t baselen = colon - name;
    for (int i = 0; i < store->ngranters; i++) {
      if (strlen(store->granters[i].name) == baselen &&
          strncmp(store->granters[i].name, name, baselen) == 0)
        return store->granters[i].func;
    }
  }

  return NULL;
}

/* Add a new entry to the store */
static PledgeEntry *addentry(lua_State *L, PledgeStore *store,
                             const char *name) {
  if (store->nentries >= store->capacity) {
    int newcap = store->capacity == 0 ? 8 : store->capacity * 2;
    store->entries = luaM_reallocvector(L, store->entries, store->capacity,
                                        newcap, PledgeEntry);
    store->capacity = newcap;
  }

  PledgeEntry *e = &store->entries[store->nentries++];
  e->name = luaM_newvector(L, strlen(name) + 1, char);
  strcpy(e->name, name);
  e->nvalues = 0;
  e->rejected = 0;
  return e;
}

/* Add a value to an entry */
static void addvalue(lua_State *L, PledgeEntry *entry, const char *value) {
  if (value == NULL)
    return;
  if (entry->nvalues >= MAX_VALUES_PER_PLEDGE)
    return;

  /* Check if value already exists */
  for (int i = 0; i < entry->nvalues; i++) {
    if (strcmp(entry->values[i], value) == 0)
      return;
  }

  entry->values[entry->nvalues] = luaM_newvector(L, strlen(value) + 1, char);
  strcpy(entry->values[entry->nvalues], value);
  entry->nvalues++;
}

/* Free an entry's resources */
static void freeentry(lua_State *L, PledgeEntry *entry) {
  if (entry->name)
    luaM_freearray(L, entry->name, strlen(entry->name) + 1);
  for (int i = 0; i < entry->nvalues; i++) {
    if (entry->values[i])
      luaM_freearray(L, entry->values[i], strlen(entry->values[i]) + 1);
  }
}

/* Build full permission name from base and sub */
static void buildname(char *buf, size_t bufsize, const char *base,
                      const char *sub) {
  if (sub) {
    snprintf(buf, bufsize, "%s:%s", base, sub);
  } else {
    snprintf(buf, bufsize, "%s", base);
  }
}

/* Parse permission string: [~]name[:subperm]=value */
static void parsepledge(const char *str, int *rejected, const char **name,
                        size_t *namelen, const char **value, size_t *valuelen) {
  const char *p = str;

  /* Check for rejection prefix */
  *rejected = 0;
  if (*p == '~') {
    *rejected = 1;
    p++;
  }

  /* Find name end (at = or end of string) */
  *name = p;
  const char *eq = strchr(p, '=');
  if (eq) {
    *namelen = eq - p;
    *value = eq + 1;
    *valuelen = strlen(*value);
  } else {
    *namelen = strlen(p);
    *value = NULL;
    *valuelen = 0;
  }
}

/*
** ========================================================
** Pledge Iterator API
** ========================================================
*/

LUA_API void lus_initpledge(lua_State *L, lus_PledgeRequest *p,
                            const char *base) {
  PledgeStore *store = getstore(L);
  memset(p, 0, sizeof(*p));
  p->base = base;
  p->sub = NULL;
  p->value = NULL;
  p->current = NULL;
  p->status = LUS_PLEDGE_GRANT;
  p->count = 0;
  p->has_base = 0;
  p->_idx = 0;
  p->_processed = 0;
  p->_entry = NULL;
  p->_store = store;

  /* Check if base permission is already granted */
  PledgeEntry *baseentry = findentry(store, base);
  if (baseentry && !baseentry->rejected) {
    p->has_base = 1;
  }
}

LUA_API int lus_nextpledge(lua_State *L, lus_PledgeRequest *p) {
  (void)L;
  PledgeEntry *entry = (PledgeEntry *)p->_entry;

  if (entry == NULL || p->_idx >= entry->nvalues) {
    p->current = NULL;
    return 0;
  }

  p->current = entry->values[p->_idx];
  p->_idx++;
  return 1;
}

LUA_API void lus_setpledge(lua_State *L, lus_PledgeRequest *p, const char *sub,
                           const char *value) {
  PledgeStore *store = (PledgeStore *)p->_store;
  if (store == NULL)
    store = getstore(L);

  /* Build full permission name */
  char namebuf[MAX_PLEDGE_NAME];
  buildname(namebuf, sizeof(namebuf), p->base, sub);

  /* Find or create entry */
  PledgeEntry *entry = findentry(store, namebuf);
  if (entry == NULL) {
    entry = addentry(L, store, namebuf);
  }

  /* Add value if provided */
  if (value != NULL) {
    addvalue(L, entry, value);
  }

  p->_processed = 1;
}

LUA_API void lus_rejectrequest(lua_State *L, lus_PledgeRequest *p) {
  PledgeStore *store = (PledgeStore *)p->_store;
  if (store == NULL)
    store = getstore(L);

  /* Build full permission name */
  char namebuf[MAX_PLEDGE_NAME];
  buildname(namebuf, sizeof(namebuf), p->base, p->sub);

  /* Find or create entry */
  PledgeEntry *entry = findentry(store, namebuf);
  if (entry == NULL) {
    entry = addentry(L, store, namebuf);
  }

  entry->rejected = 1;
}

LUA_API void lus_pledgeerror(lua_State *L, lus_PledgeRequest *p,
                             const char *msg) {
  PledgeStore *store = (PledgeStore *)p->_store;
  if (store == NULL)
    store = getstore(L);

  /* Free old error message if any */
  if (store->error_msg) {
    luaM_freearray(L, store->error_msg, strlen(store->error_msg) + 1);
  }

  /* Store new error message */
  if (msg) {
    store->error_msg = luaM_newvector(L, strlen(msg) + 1, char);
    strcpy(store->error_msg, msg);
  } else {
    store->error_msg = NULL;
  }
}

/*
** ========================================================
** Public API
** ========================================================
*/

LUA_API void lus_registerpledge(lua_State *L, const char *name,
                                lus_PledgeGranter granter) {
  PledgeStore *store = getstore(L);
  if (store->ngranters >= MAX_GRANTERS)
    return;

  /* Check if already registered */
  for (int i = 0; i < store->ngranters; i++) {
    if (strcmp(store->granters[i].name, name) == 0) {
      store->granters[i].func = granter;
      return;
    }
  }

  GranterEntry *g = &store->granters[store->ngranters++];
  g->name = luaM_newvector(L, strlen(name) + 1, char);
  strcpy(g->name, name);
  g->func = granter;
}

LUA_API int lus_pledge(lua_State *L, const char *name, const char *value) {
  PledgeStore *store = getstore(L);

  /* Check if sealed */
  if (store->sealed)
    return 0;

  /* Find granter - granter MUST be registered for valid permissions */
  lus_PledgeGranter granter = findgranter(store, name);
  if (granter == NULL) {
    return luaL_error(L, "unknown permission: '%s'", name);
  }

  /* Parse name into base and sub */
  const char *colon = strchr(name, ':');
  char basebuf[MAX_PLEDGE_NAME];
  const char *sub = NULL;

  if (colon) {
    size_t baselen = colon - name;
    if (baselen >= sizeof(basebuf))
      baselen = sizeof(basebuf) - 1;
    memcpy(basebuf, name, baselen);
    basebuf[baselen] = '\0';
    sub = colon + 1;
  } else {
    strncpy(basebuf, name, sizeof(basebuf) - 1);
    basebuf[sizeof(basebuf) - 1] = '\0';
  }

  /* Initialize request */
  lus_PledgeRequest req;
  lus_initpledge(L, &req, basebuf);
  req.sub = sub;
  req.value = value;
  req.status = LUS_PLEDGE_GRANT;

  /* Find existing entry to populate count */
  PledgeEntry *entry = findentry(store, name);
  if (entry) {
    req.count = entry->nvalues;
    req._entry = entry;
  }

  /* Clear any previous error */
  if (store->error_msg) {
    luaM_freearray(L, store->error_msg, strlen(store->error_msg) + 1);
    store->error_msg = NULL;
  }

  /* Call granter */
  granter(L, &req);

  /* Check if processed */
  return req._processed;
}

LUA_API int lus_haspledge(lua_State *L, const char *name, const char *value) {
  PledgeStore *store = L->pledges;
  if (store == NULL)
    return 0;

  /* Check for rejection */
  PledgeEntry *entry = findentry(store, name);
  if (entry && entry->rejected)
    return 0;

  /* Parse name */
  const char *colon = strchr(name, ':');
  char basebuf[MAX_PLEDGE_NAME];
  const char *sub = NULL;

  if (colon) {
    size_t baselen = colon - name;
    if (baselen >= sizeof(basebuf))
      baselen = sizeof(basebuf) - 1;
    memcpy(basebuf, name, baselen);
    basebuf[baselen] = '\0';
    sub = colon + 1;
  } else {
    strncpy(basebuf, name, sizeof(basebuf) - 1);
    basebuf[sizeof(basebuf) - 1] = '\0';
  }

  /* Find granter */
  lus_PledgeGranter granter = findgranter(store, name);
  if (granter == NULL)
    return 0;

  /* Initialize request for checking */
  lus_PledgeRequest req;
  lus_initpledge(L, &req, basebuf);
  req.sub = sub;
  req.value = value;
  req.status = LUS_PLEDGE_CHECK;

  /* Check base permission first */
  PledgeEntry *baseentry = findentry(store, basebuf);
  if (baseentry && !baseentry->rejected) {
    req.has_base = 1;
    /* If base has no values, means global access */
    if (baseentry->nvalues == 0 && value == NULL) {
      return 1;
    }
  }

  /* Try specific entry */
  if (entry) {
    req.count = entry->nvalues;
    req._entry = entry;

    /* If entry exists with no values, global access */
    if (entry->nvalues == 0) {
      return 1;
    }
  } else if (baseentry && !baseentry->rejected) {
    /* Use base entry for iteration */
    req.count = baseentry->nvalues;
    req._entry = baseentry;

    /* If base exists with no values, global access */
    if (baseentry->nvalues == 0) {
      return 1;
    }
  } else {
    return 0;
  }

  /* Call granter for value checking */
  granter(L, &req);

  return req._processed;
}

LUA_API int lus_revokepledge(lua_State *L, const char *name) {
  PledgeStore *store = L->pledges;
  if (store == NULL)
    return 0;

  if (store->sealed)
    return 0;

  PledgeEntry *entry = findentry(store, name);
  if (entry == NULL)
    return 0;

  /* Free the entry's values but keep the slot */
  for (int i = 0; i < entry->nvalues; i++) {
    if (entry->values[i]) {
      luaM_freearray(L, entry->values[i], strlen(entry->values[i]) + 1);
      entry->values[i] = NULL;
    }
  }
  entry->nvalues = 0;

  return 1;
}

LUA_API int lus_rejectpledge(lua_State *L, const char *name) {
  PledgeStore *store = getstore(L);

  if (store->sealed)
    return 0;

  PledgeEntry *entry = findentry(store, name);
  if (entry == NULL) {
    entry = addentry(L, store, name);
  }

  entry->rejected = 1;
  return 1;
}

LUA_API int lus_issealed(lua_State *L) {
  PledgeStore *store = L->pledges;
  return store ? store->sealed : 0;
}

LUA_API int lus_checkfsperm(lua_State *L, const char *perm, const char *path) {
  if (!lus_haspledge(L, perm, path)) {
    return luaL_error(L, "permission \"%s\" denied for '%s'", perm, path);
  }
  return 0;
}

/*
** ========================================================
** Internal Functions (for lstate.c)
** ========================================================
*/

void luaP_initpledges(lua_State *L) { L->pledges = NULL; }

PledgeStore *luaP_copypledges(lua_State *L, PledgeStore *parent) {
  if (parent == NULL)
    return NULL;

  PledgeStore *copy = luaM_new(L, PledgeStore);
  copy->capacity = parent->nentries;
  copy->nentries = parent->nentries;
  copy->sealed = parent->sealed;
  copy->ngranters = parent->ngranters;
  copy->error_msg = NULL;

  if (copy->capacity > 0) {
    copy->entries = luaM_newvector(L, copy->capacity, PledgeEntry);
    for (int i = 0; i < parent->nentries; i++) {
      PledgeEntry *src = &parent->entries[i];
      PledgeEntry *dst = &copy->entries[i];

      dst->name = luaM_newvector(L, strlen(src->name) + 1, char);
      strcpy(dst->name, src->name);
      dst->nvalues = src->nvalues;
      dst->rejected = src->rejected;

      for (int j = 0; j < src->nvalues; j++) {
        dst->values[j] = luaM_newvector(L, strlen(src->values[j]) + 1, char);
        strcpy(dst->values[j], src->values[j]);
      }
    }
  } else {
    copy->entries = NULL;
  }

  /* Copy granter registrations */
  for (int i = 0; i < parent->ngranters; i++) {
    copy->granters[i].name =
        luaM_newvector(L, strlen(parent->granters[i].name) + 1, char);
    strcpy(copy->granters[i].name, parent->granters[i].name);
    copy->granters[i].func = parent->granters[i].func;
  }

  return copy;
}

void luaP_freepledges(lua_State *L, PledgeStore *store) {
  if (store == NULL)
    return;

  for (int i = 0; i < store->nentries; i++) {
    freeentry(L, &store->entries[i]);
  }

  if (store->entries) {
    luaM_freearray(L, store->entries, store->capacity);
  }

  for (int i = 0; i < store->ngranters; i++) {
    if (store->granters[i].name) {
      luaM_freearray(L, store->granters[i].name,
                     strlen(store->granters[i].name) + 1);
    }
  }

  if (store->error_msg) {
    luaM_freearray(L, store->error_msg, strlen(store->error_msg) + 1);
  }

  luaM_free(L, store);
}

/*
** ========================================================
** Lua-side pledge() function
** ========================================================
*/

int luaB_pledge(lua_State *L) {
  int n = lua_gettop(L);
  PledgeStore *store = getstore(L);

  for (int i = 1; i <= n; i++) {
    const char *arg = luaL_checkstring(L, i);

    int rejected;
    const char *name;
    size_t namelen;
    const char *value;
    size_t valuelen;

    parsepledge(arg, &rejected, &name, &namelen, &value, &valuelen);

    /* Create null-terminated copies */
    char namebuf[MAX_PLEDGE_NAME];
    if (namelen >= sizeof(namebuf)) {
      return luaL_error(L, "permission name too long: '%s'", arg);
    }
    memcpy(namebuf, name, namelen);
    namebuf[namelen] = '\0';

    char valuebuf[1024];
    char *valueptr = NULL;
    if (value && valuelen > 0) {
      if (valuelen >= sizeof(valuebuf)) {
        return luaL_error(L, "permission value too long");
      }
      memcpy(valuebuf, value, valuelen);
      valuebuf[valuelen] = '\0';
      valueptr = valuebuf;
    }

    /* Handle special permissions */
    if (strcmp(namebuf, "all") == 0) {
      return luaL_error(L,
                        "permission \"all\" cannot be requested from scripts");
    }

    if (strcmp(namebuf, "seal") == 0) {
      store->sealed = 1;
      lua_pushboolean(L, 1);
      continue;
    }

    /* Handle rejection */
    if (rejected) {
      if (store->sealed) {
        lua_pushboolean(L, 0);
        continue;
      }

      PledgeEntry *entry = findentry(store, namebuf);
      if (entry == NULL) {
        entry = addentry(L, store, namebuf);
      }
      entry->rejected = 1;
      lua_pushboolean(L, 1);
      continue;
    }

    /* Check if sealed */
    if (store->sealed) {
      lua_pushboolean(L, 0);
      continue;
    }

    /* Check if permission was rejected */
    PledgeEntry *entry = findentry(store, namebuf);
    if (entry && entry->rejected) {
      return luaL_error(L, "permission \"%s\" was rejected", namebuf);
    }

    /* Try to grant the permission */
    int granted = lus_pledge(L, namebuf, valueptr);
    lua_pushboolean(L, granted);
  }

  return n;
}
