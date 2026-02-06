/*
** lformat.h - Lus source code formatter
** Operates directly on C AST structures (LusAst/LusAstNode).
*/

#ifndef lformat_h
#define lformat_h

#include "lua.h"
#include "last.h"

/*
** Format Lus source code.
** Parses `source` into a C AST, walks the nodes directly, and emits
** idiomatically formatted code. No Lua stack interaction in the formatter.
** Returns a malloc'd string (caller must free), or NULL on parse error.
** On error, `*errmsg` is set to a static error description.
*/
char *lusF_format(lua_State *L, const char *source, size_t srclen,
                  const char *chunkname, int indent_width,
                  int max_line_width, const char **errmsg);

#endif
