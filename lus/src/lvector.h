/*
** $Id: lvector.h $
** Vector handling
** See Copyright Notice in lua.h
*/

#ifndef lvector_h
#define lvector_h

#include "lobject.h"


/*
** Vector struct is defined in lobject.h
*/


/*
** Create a new vector with given length.
** If 'fast' is true, buffer is not zero-initialized.
*/
LUAI_FUNC Vector *luaV_newvec(lua_State *L, size_t len, int fast);

/*
** Clone a vector.
*/
LUAI_FUNC Vector *luaV_clone(lua_State *L, Vector *v);

/*
** Resize a vector. New bytes are zero-initialized.
*/
LUAI_FUNC void luaV_resize(lua_State *L, Vector *v, size_t newlen);

/*
** Free a vector.
*/
LUAI_FUNC void luaV_freevec(lua_State *L, Vector *v);

/*
** Get total memory size of a vector.
*/
LUAI_FUNC lu_mem luaV_vecsize(Vector *v);


#endif
