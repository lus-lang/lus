/*
** $Id: lfastcall.h $
** VM-intrinsified standard library functions
** See Copyright Notice in lua.h
*/

#ifndef lfastcall_h
#define lfastcall_h

#include "lobject.h"

/* Forward declaration (defined in lstate.h) */
typedef struct global_State global_State;

/*
** Static description of a fastcall entry: function name, module, and
** expected argument count. This data is identical in every state, so
** it lives in one process-wide read-only table ('luaF_fc_defs');
** states only carry the interned name strings (the parser matches by
** pointer identity) and a per-entry readiness flag (see lstate.h).
*/
typedef struct FCDef {
  const char *func;   /* function name */
  lu_byte module_idx; /* index into global_State.fc_modules */
  lu_byte nargs;      /* expected argument count */
} FCDef;

/* number of named modules with fastcall entries (index 0 = base lib) */
#define FC_NMODULES 5

enum FastCallId {
  FC_TYPE,
  FC_RAWLEN,
  FC_RAWGET,
  FC_RAWSET,
  FC_RAWEQUAL,
  FC_ASSERT,
  FC_GETMETATABLE,
  FC_SETMETATABLE,
  FC_TONUMBER,
  FC_TOSTRING,
  FC_MATH_ABS,
  FC_MATH_MAX,
  FC_MATH_MIN,
  FC_MATH_CEIL,
  FC_MATH_FLOOR,
  FC_MATH_SQRT,
  FC_MATH_SIN,
  FC_MATH_COS,
  FC_MATH_TAN,
  FC_MATH_ASIN,
  FC_MATH_ACOS,
  FC_MATH_ATAN,
  FC_MATH_EXP,
  FC_MATH_LOG,
  FC_MATH_DEG,
  FC_MATH_RAD,
  FC_MATH_FMOD,
  FC_MATH_ULT,
  FC_MATH_TOINTEGER,
  FC_MATH_TYPE,
  FC_MATH_LDEXP,
  FC_STRING_LEN,
  FC_STRING_TRIM,
  FC_STRING_LTRIM,
  FC_STRING_RTRIM,
  FC_STRING_SPLIT,
  FC_STRING_JOIN,
  FC_STRING_SUB,
  FC_STRING_BYTE,
  FC_STRING_CHAR,
  FC_STRING_LOWER,
  FC_STRING_UPPER,
  FC_STRING_REVERSE,
  FC_TABLE_SUM,
  FC_TABLE_MEAN,
  FC_TABLE_MEDIAN,
  FC_TABLE_STDEV,
  FC_TABLE_TRANSPOSE,
  FC_TABLE_RESHAPE,
  FC_VECTOR_CREATE,
  FC_VECTOR_CLONE,
  FC_VECTOR_SIZE,
  FC_VECTOR_RESIZE,
  FC_UTF8_LEN,
  FC_UTF8_CODEPOINT,
  FC_UTF8_CHAR,
  FC_UTF8_OFFSET,
  FC_COUNT
};

/* process-wide read-only fastcall definitions (one per FastCallId) */
LUAI_DDEC(const FCDef luaF_fc_defs[];)

/*
** Original C function for each entry. Written once at library open and
** identical in every state of the process (library functions have fixed
** addresses), so it is shared rather than stored per state. The VM
** re-validates the actually-called function against this pointer on
** every fastcall, so a host that registers a different function in some
** state simply falls back to a regular call there.
*/
LUAI_DDEC(lua_CFunction luaF_fc_origs[];)

LUAI_FUNC int luaV_dofastcall(lua_State *L, int fc_id, StkId ra);
LUAI_FUNC void luaF_initfastcalls(lua_State *L);
LUAI_FUNC void luaF_registerfastcall(lua_State *L, int id, lua_CFunction func,
                                     int nargs);
LUAI_FUNC void luaF_enablefastcalls(lua_State *L);
LUAI_FUNC int luaF_findfastcall(global_State *g, TString *module, TString *func,
                                int nargs);

#endif
