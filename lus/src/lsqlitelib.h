/*
** lsqlitelib.h
** Internal SQLite binding hooks
*/

#ifndef lsqlitelib_h
#define lsqlitelib_h

#include "llimits.h"

typedef void (*LusSQLitePathHook)(const char *phase, const char *path,
                                  void *context);

/* Deterministic synchronization seam for H2 path-race regressions. */
LUAI_FUNC void luaS_setsqlitepathhook(LusSQLitePathHook hook, void *context);

#endif
