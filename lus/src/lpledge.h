/*
** lpledge.h
** Permission system for Lus
*/

#ifndef lpledge_h
#define lpledge_h

#include "llimits.h"
#include "lua.h"

/*
** ========================================================
** Pledge Request Status Constants
** ========================================================
*/

#define LUS_PLEDGE_GRANT 0  /* New permission request */
#define LUS_PLEDGE_UPDATE 1 /* Updating existing permission */
#define LUS_PLEDGE_CHECK 2  /* Read-only permission check */

/*
** ========================================================
** Pledge Request Structure
** ========================================================
**
** Used by granters to inspect and process permission requests.
** Granters iterate stored values using lus_nextpledge() and
** confirm grants using lus_setpledge().
*/
typedef struct lus_PledgeRequest {
  const char *base;    /* base permission: "fs", "network", etc. */
  const char *sub;     /* subpermission: "read", "tcp", or NULL */
  const char *value;   /* requested value, or NULL */
  const char *current; /* current stored value during iteration */
  int status;          /* LUS_PLEDGE_GRANT, UPDATE, or CHECK */
  int count;           /* number of stored values for this permission */
  int has_base;        /* 1 if base permission already granted */
  /* internal state - do not modify */
  int _idx;       /* iteration index */
  int _processed; /* set by lus_setpledge */
  void *_entry;   /* pointer to entry */
  void *_store;   /* pointer to store */
} lus_PledgeRequest;

/*
** ========================================================
** Granter Callback
** ========================================================
**
** Called when a permission is being granted, updated, or checked.
** The granter should iterate stored values with lus_nextpledge()
** and confirm grants with lus_setpledge().
**
** Return: void - unprocessed pledges are automatically denied.
*/
typedef void (*lus_PledgeGranter)(lua_State *L, lus_PledgeRequest *p);

/*
** ========================================================
** Pledge Iterator Functions
** ========================================================
*/

/*
** Initialize a pledge request for C-side grants.
** This bypasses granters - use for direct permission grants from C.
**
** Parameters:
**   p: pledge request to initialize
**   base: base permission name (e.g., "fs", "network")
*/
LUA_API void lus_initpledge(lua_State *L, lus_PledgeRequest *p,
                            const char *base);

/*
** Iterate through stored values for a permission.
** Sets p->current to the next stored value.
**
** Returns: 1 if there are more values, 0 when done
*/
LUA_API int lus_nextpledge(lua_State *L, lus_PledgeRequest *p);

/*
** Confirm/set a pledge value.
** Marks the request as processed (prevents denial).
**
** Parameters:
**   sub: subpermission (e.g., "read") or NULL for base
**   value: value to store (e.g., path) or NULL for unrestricted
*/
LUA_API void lus_setpledge(lua_State *L, lus_PledgeRequest *p, const char *sub,
                           const char *value);

/*
** Reject using request struct (for granters).
** Future attempts to grant this permission will fail.
*/
LUA_API void lus_rejectrequest(lua_State *L, lus_PledgeRequest *p);

/*
** Set denial error message (for granters to explain why denied).
** This message is shown to the user when the pledge fails.
*/
LUA_API void lus_pledgeerror(lua_State *L, lus_PledgeRequest *p,
                             const char *msg);

/*
** ========================================================
** Public Permission API
** ========================================================
*/

/*
** Grant a permission to the state.
** Triggers the granter callback for validation.
**
** Parameters:
**   name: permission name (e.g., "fs:read" or "network:http")
**   value: permission value (e.g., path glob) or NULL
**
** Returns: 1 on success, 0 on failure (denied or rejected)
**
** Errors if the permission name is not recognized.
*/
LUA_API int lus_pledge(lua_State *L, const char *name, const char *value);

/*
** Check if a permission is granted.
** Triggers the granter callback for dynamic checking.
**
** Parameters:
**   name: permission name to check
**   value: specific value to check against (e.g., a path) or NULL
**
** Returns: 1 if permission is granted, 0 if denied
*/
LUA_API int lus_haspledge(lua_State *L, const char *name, const char *value);

/*
** Revoke a permission from the state (string-based).
** Will fail if the state is sealed.
**
** Returns: 1 on success, 0 on failure (sealed or not found)
*/
LUA_API int lus_revokepledge(lua_State *L, const char *name);

/*
** Reject a permission permanently (string-based).
** Future attempts to grant this permission will fail.
**
** Returns: 1 on success, 0 on failure (sealed)
*/
LUA_API int lus_rejectpledge(lua_State *L, const char *name);

/*
** Register a permission granter.
** The granter will be called when permissions matching `name` are
** granted or checked.
**
** Parameters:
**   name: base permission name (e.g., "fs", "network")
**   granter: callback function
*/
LUA_API void lus_registerpledge(lua_State *L, const char *name,
                                lus_PledgeGranter granter);

/*
** Check if the state is sealed (no more permission changes allowed).
*/
LUA_API int lus_issealed(lua_State *L);

/*
** Check filesystem permission and raise error if denied.
** Shared helper for fs:read/fs:write checks across all file operations.
**
** Parameters:
**   perm: permission name (e.g., "fs:read" or "fs:write")
**   path: the filesystem path being accessed
**
** Returns: 0 on success (permission granted), raises error if denied
*/
LUA_API int lus_checkfsperm(lua_State *L, const char *perm, const char *path);

/*
** ========================================================
** Internal Functions (for lstate.c)
** ========================================================
*/

/* Forward declaration of internal structure */
typedef struct PledgeStore PledgeStore;

/* Initialize pledges for main thread (from CLI or empty) */
LUAI_FUNC void luaP_initpledges(lua_State *L);

/* Copy pledges from parent to child thread */
LUAI_FUNC PledgeStore *luaP_copypledges(lua_State *L, PledgeStore *parent);

/* Free pledges when thread is closed */
LUAI_FUNC void luaP_freepledges(lua_State *L, PledgeStore *store);

/* Lua-side pledge() function */
LUAI_FUNC int luaB_pledge(lua_State *L);

#endif
