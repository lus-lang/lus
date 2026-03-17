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

typedef struct FastCallEntry {
  TString *module_name;    /* "math", "string", or NULL for base lib */
  TString *func_name;      /* "max", "type", etc. */
  lua_CFunction orig_func; /* original C function pointer (set at lib open) */
  int nargs;               /* expected argument count */
} FastCallEntry;

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

LUAI_FUNC int luaV_dofastcall(lua_State *L, int fc_id, StkId ra);
LUAI_FUNC void luaF_initfastcalls(lua_State *L);
LUAI_FUNC void luaF_registerfastcall(lua_State *L, int id, lua_CFunction func,
                                     int nargs);
LUAI_FUNC void luaF_enablefastcalls(lua_State *L);
LUAI_FUNC int luaF_findfastcall(global_State *g, TString *module, TString *func,
                                int nargs);

#endif
