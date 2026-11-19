/*
** lus.h: the C embedding interface of the Lus runtime.
**
** A host program creates a state, opens the standard libraries, sets the
** permission policy, loads and runs code, and exchanges values with it
** through a stack. Every value a C function or a host sees lives in a stack
** slot. Positive indices count from the bottom of the current frame, so
** index 1 is the first argument of a C function. Negative indices count
** from the top, so index -1 is the value pushed last.
**
** Lus reports errors through return values and never jumps across C
** frames. A function that can fail returns a status code. On failure it
** leaves the error value on top of the stack in place of its result, so the
** stack always changes by the documented amount. A C function propagates an
** error to its Lus caller with `return lus_error(L);`.
**
** Values stored outside the stack are kept alive with references, which
** are stable integer handles into the state's registry (see lus_ref).
*/

#ifndef LUS_H
#define LUS_H

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LUS_VERSION_MAJOR 2
#define LUS_VERSION_MINOR 0
#define LUS_VERSION_PATCH 0
#define LUS_VERSION "Lus 2.0.0-dev"

/* An interpreter state, or one of its coroutines. */
typedef struct lus_State lus_State;

typedef int64_t lus_Integer;
typedef double lus_Number;

/*
** A function written in C. It receives its arguments at stack indices 1
** through lus_gettop(L), pushes its results, and returns how many it
** pushed. Returning LUS_ERROR raises the error set by lus_error.
*/
typedef int (*lus_CFunction)(lus_State *L);

/* Status codes. */
#define LUS_OK 0        /* success */
#define LUS_ERRRUN 1    /* a runtime error */
#define LUS_ERRSYNTAX 2 /* a syntax error while compiling */
#define LUS_ERRMEM 3    /* the allocator failed */
#define LUS_ERRFILE 4   /* a file could not be opened or read */

/* What a C function returns to raise the pending error. */
#define LUS_ERROR (-1)

/* Pass as a result count to keep every result of a call. */
#define LUS_MULTRET (-1)

/* Value types, as returned by lus_type. */
#define LUS_TNONE (-1) /* an index with no value */
#define LUS_TNIL 0
#define LUS_TBOOLEAN 1
#define LUS_TLIGHT 2 /* a raw host pointer */
#define LUS_TNUMBER 3
#define LUS_TSTRING 4
#define LUS_TTABLE 5
#define LUS_TFUNCTION 6
#define LUS_TUSERDATA 7
#define LUS_TTHREAD 8
#define LUS_TVECTOR 9
#define LUS_TENUM 10
#define LUS_TQUERY 11

/* The reference that lus_ref returns for nil. It never names a value. */
#define LUS_NOREF 0

/*
** State
*/

/*
** Creates a state with no libraries and no permissions. Returns NULL when
** memory runs out. A state is used by one thread at a time.
*/
lus_State *lus_newstate(void);

/*
** Runs the finalizers of every object that still has one, stops the
** workers the state started, and frees the state. L must be the state
** returned by lus_newstate.
*/
void lus_close(lus_State *L);

/* Opens every standard library into the global table. */
int lus_openlibs(lus_State *L);

/* Runs a full garbage collection cycle and any finalizers it makes due. */
void lus_collect(lus_State *L);

/*
** Stack
*/

/* Returns the index of the top value, which is also the number of values
   in the current frame. */
int lus_gettop(lus_State *L);

/* Sets the top to idx. New slots are filled with nil. lus_settop(L, 0)
   empties the frame. A negative idx counts from the top. */
void lus_settop(lus_State *L, int idx);

/* Pops n values. */
#define lus_pop(L, n) lus_settop(L, -(n)-1)

/* Converts idx into the equivalent positive index. */
int lus_absindex(lus_State *L, int idx);

/* Pushes a copy of the value at idx. */
void lus_pushvalue(lus_State *L, int idx);

/* Removes the value at idx, shifting the values above it down. */
void lus_remove(lus_State *L, int idx);

/* Moves the top value into idx, shifting the values above it up. */
void lus_insert(lus_State *L, int idx);

/* Pops the top value and stores it at idx. */
void lus_replace(lus_State *L, int idx);

/* Makes room for n more values. Returns 0 when the stack cannot grow. */
int lus_checkstack(lus_State *L, int n);

/*
** Reading values
*/

/* Returns the type of the value at idx, or LUS_TNONE for an index above
   the top. */
int lus_type(lus_State *L, int idx);

/* Returns the name of a type code, such as "number". */
const char *lus_typename(int type);

int lus_isnil(lus_State *L, int idx);
int lus_isinteger(lus_State *L, int idx);
int lus_isfunction(lus_State *L, int idx);

/* Returns 0 for nil and false and 1 for every other value. */
int lus_toboolean(lus_State *L, int idx);

/*
** Returns the value at idx as an integer. Integers, floats with an exact
** integer value, and strings holding such numerals convert. When isnum is
** not NULL, it receives whether the conversion succeeded.
*/
lus_Integer lus_tointeger(lus_State *L, int idx, int *isnum);

/* Returns the value at idx as a float, converting integers and numeric
   strings. When isnum is not NULL, it receives whether that succeeded. */
lus_Number lus_tonumber(lus_State *L, int idx, int *isnum);

/*
** Returns the bytes of the string at idx and stores its byte length in
** len when len is not NULL. Returns NULL for any other type. The bytes
** are well formed WTF-8 and followed by a zero byte. The pointer stays
** valid while the string remains on the stack.
*/
const char *lus_tostring(lus_State *L, int idx, size_t *len);

/*
** Returns the contents of the vector at idx and stores its length in len
** when len is not NULL. Returns NULL for any other type. The bytes may be
** changed in place. The pointer stays valid until the vector is resized
** or collected.
*/
unsigned char *lus_tobytes(lus_State *L, int idx, size_t *len);

/* Returns the pointer of a light value, the data block of a userdata, or
   NULL for any other type. */
void *lus_touserdata(lus_State *L, int idx);

/* Returns the pointer of a light value, or NULL for any other type. */
void *lus_tolight(lus_State *L, int idx);

/* Returns 1 when the values at the two indices are primitively equal,
   without metamethods. */
int lus_rawequal(lus_State *L, int idx1, int idx2);

/* Returns the byte length of a string, the length of a vector, or the
   border of a table, without metamethods. Other types give 0. */
size_t lus_rawlen(lus_State *L, int idx);

/*
** Pushing values
**
** A push that allocates returns a status. It pushes exactly one value in
** every case: the new value on success, the error value on failure.
*/

void lus_pushnil(lus_State *L);
void lus_pushboolean(lus_State *L, int b);
void lus_pushinteger(lus_State *L, lus_Integer n);
void lus_pushnumber(lus_State *L, lus_Number n);

/* Pushes a light value holding a raw host pointer. */
void lus_pushlight(lus_State *L, void *p);

/* Pushes a copy of the zero terminated string s, or nil when s is NULL.
   Fails when s is not well formed UTF-8. */
int lus_pushstring(lus_State *L, const char *s);

/* Pushes a copy of the first len bytes of s as a string. */
int lus_pushlstring(lus_State *L, const char *s, size_t len);

/* Pushes a formatted string built with the C printf rules. */
static inline int lus_pushvfstring(lus_State *L, const char *fmt, va_list ap) {
  char small[256];
  char *big;
  int n, status;
  va_list cp;
  va_copy(cp, ap);
  n = vsnprintf(small, sizeof small, fmt, cp);
  va_end(cp);
  if (n < 0)
    return lus_pushlstring(L, "", 0);
  if ((size_t)n < sizeof small)
    return lus_pushlstring(L, small, (size_t)n);
  big = (char *)malloc((size_t)n + 1);
  if (big == NULL)
    return lus_pushlstring(L, small, sizeof small - 1);
  vsnprintf(big, (size_t)n + 1, fmt, ap);
  status = lus_pushlstring(L, big, (size_t)n);
  free(big);
  return status;
}

static inline int lus_pushfstring(lus_State *L, const char *fmt, ...) {
  va_list ap;
  int status;
  va_start(ap, fmt);
  status = lus_pushvfstring(L, fmt, ap);
  va_end(ap);
  return status;
}

/* Pushes a new vector holding a copy of len bytes from p. A NULL p gives
   len zero bytes. */
int lus_pushbytes(lus_State *L, const void *p, size_t len);

/* Pushes a new empty table with room for narr array items and nrec other
   fields. */
int lus_newtable(lus_State *L, int narr, int nrec);

/* Pushes a C function. */
int lus_pushcfunction(lus_State *L, lus_CFunction f);

/*
** Pops n values and pushes a C function that holds them as upvalues. The
** function reads them with lus_getupvalue.
*/
int lus_pushcclosure(lus_State *L, lus_CFunction f, int n);

/* Inside a C closure, pushes its upvalue i (from 1). Pushes nil when the
   running function has no such upvalue. */
void lus_getupvalue(lus_State *L, int i);

/*
** Pushes the result of tostring on the value at idx, honoring __tostring
** and __name. The result is a string. Fails when a metamethod fails.
*/
int lus_stringify(lus_State *L, int idx);

/*
** Tables and globals
**
** The non-raw functions honor metamethods, so they can fail.
*/

/* Pushes t[k] where t is the value at idx. */
int lus_getfield(lus_State *L, int idx, const char *k);

/* Does t[k] = v where t is the value at idx and v the top value, which is
   popped. */
int lus_setfield(lus_State *L, int idx, const char *k);

/* Pops a key and pushes t[key] where t is the value at idx. */
int lus_gettable(lus_State *L, int idx);

/* Pops a value and then a key and does t[key] = value. */
int lus_settable(lus_State *L, int idx);

/* Pushes the global name. */
int lus_getglobal(lus_State *L, const char *name);

/* Pops a value into the global name. */
int lus_setglobal(lus_State *L, const char *name);

/* Pops a key and pushes the raw value of t[key]. Returns its type. */
int lus_rawget(lus_State *L, int idx);

/* Pushes the raw value of t[n]. Returns its type. */
int lus_rawgeti(lus_State *L, int idx, lus_Integer n);

/* Pops a value and then a key and stores them without metamethods. */
int lus_rawset(lus_State *L, int idx);

/* Pops a value and stores it at t[n] without metamethods. */
int lus_rawseti(lus_State *L, int idx, lus_Integer n);

/*
** Pops a key and pushes the next key and value of the table at idx.
** Returns 1 when it pushed a pair and 0, pushing nothing, after the last
** pair. Start a traversal with a nil key. Returns LUS_ERROR with the error
** pushed when the key is not in the table.
*/
int lus_next(lus_State *L, int idx);

/* Pushes the length of the value at idx, honoring __len. */
int lus_len(lus_State *L, int idx);

/*
** Metatables and userdata
*/

/*
** Pushes a new block of size bytes of userdata and returns its address.
** The block is aligned to 8 bytes and lives until it is collected.
** Returns NULL, with the error pushed, when memory runs out.
*/
void *lus_newuserdata(lus_State *L, size_t size);

/*
** Pushes the metatable registered under tname, creating it when needed.
** A new metatable gets the field __name = tname. Returns 1 when the table
** was created by this call, 0 when it already existed, and LUS_ERROR with
** the error pushed when memory runs out.
*/
int lus_newmetatable(lus_State *L, const char *tname);

/* Pushes the metatable registered under tname, or nil. */
void lus_getmetatable(lus_State *L, const char *tname);

/*
** Pops a table or nil and makes it the metatable of the table or userdata
** at idx. A metatable with a __gc field turns its function into the
** finalizer of the object. The finalizer receives the object as its only
** argument and runs at most once, after the object becomes unreachable or
** when the state closes.
*/
int lus_setmetatable(lus_State *L, int idx);

/* Pushes the metatable of the value at idx and returns 1, or pushes
   nothing and returns 0 when it has none. */
int lus_getmetatableof(lus_State *L, int idx);

/* Returns the data block of the userdata at idx when its metatable is the
   one registered under tname, or NULL otherwise. */
void *lus_toudata(lus_State *L, int idx, const char *tname);

/*
** References
**
** A reference is a stable handle to a value that lives outside the stack,
** for example a callback a host keeps between calls.
*/

/* Pops the top value and returns a reference to it. Nil gives LUS_NOREF.
   Returns LUS_ERROR, with the error pushed, when memory runs out. */
int lus_ref(lus_State *L);

/* Pushes the value of a reference, or nil for LUS_NOREF. */
void lus_getref(lus_State *L, int ref);

/* Releases a reference. Its number may be reused. */
void lus_unref(lus_State *L, int ref);

/*
** Loading and calling
*/

/*
** Compiles a chunk and pushes it as a function. The buffer holds source
** text or a binary chunk. chunkname names the chunk in messages: "@path"
** for a file, "=name" for anything else. NULL means "=(load)". On a
** syntax error, pushes the message and returns LUS_ERRSYNTAX.
*/
int lus_load(lus_State *L, const char *buf, size_t len, const char *chunkname);

/* Loads the file at path with the chunk name "@path". The host reads the
   file under its own authority, without a permission check. */
int lus_loadfile(lus_State *L, const char *path);

/*
** Calls a function with protection. Push the function, then nargs
** arguments, then call. On success, the function and its arguments are
** replaced by nresults results (all of them with LUS_MULTRET). On failure,
** they are replaced by the error value and the status is returned.
*/
int lus_pcall(lus_State *L, int nargs, int nresults);

/*
** Returns the stack traceback of the last error caught by lus_pcall, or
** NULL when that error had none. The text stays valid until the next call
** of lus_pcall on L.
*/
const char *lus_traceback(lus_State *L);

/* Loads and runs a string. Results stay on the stack. */
int lus_dostring(lus_State *L, const char *src);

/* Loads and runs a file. Results stay on the stack. */
int lus_dofile(lus_State *L, const char *path);

/*
** Errors raised from C
*/

/*
** Pops the top value and makes it the pending error. Returns LUS_ERROR so
** a C function can write `return lus_error(L);`.
*/
int lus_error(lus_State *L);

/*
** Makes msg the pending error, prefixed with the position of the Lus code
** that called the running C function. Returns LUS_ERROR.
*/
int lus_errorstr(lus_State *L, const char *msg);

static inline int lus_errorf(lus_State *L, const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  return lus_errorstr(L, buf);
}

/*
** Permissions
**
** A state starts with no permissions. The host grants and rejects
** capabilities before scripts run. Once the host grants anything, scripts
** can only pledge what those grants cover.
*/

/* Grants a capability with the pledge syntax, such as
   "fs:read=/srv/data", "network", or "~exec" to reject. */
int lus_grant(lus_State *L, const char *spec);

/* Rejects a capability permanently. Later grants of it fail. */
int lus_reject(lus_State *L, const char *name);

/* Seals the permission set so that nothing can change it any more. */
int lus_seal(lus_State *L);

/*
** Checks that the running code holds capability, such as "network:http",
** for value (NULL for none). Returns LUS_OK when it does. Otherwise pushes
** the standard permission error and returns LUS_ERRRUN, so a C function
** writes `if (lus_require(L, cap, v) != LUS_OK) return lus_error(L);`.
*/
int lus_require(lus_State *L, const char *capability, const char *value);

/* Returns 1 when the running code holds capability for value, 0 otherwise.
   It never raises. */
int lus_allowed(lus_State *L, const char *capability, const char *value);

/* How a granted value matches a requested one. */
#define LUS_CAP_NONE 0    /* the capability takes no value */
#define LUS_CAP_PATH 1    /* canonical file system path globs */
#define LUS_CAP_HOST 2    /* host[:port][/path-glob] */
#define LUS_CAP_PATTERN 3 /* a glob over an opaque string */
#define LUS_CAP_CUSTOM 4  /* the match function decides */

/*
** Decides whether the granted value of a LUS_CAP_CUSTOM capability covers
** the requested value. ud is the value given at registration.
*/
typedef int (*lus_CapMatch)(void *ud, const char *granted,
                            const char *requested);

/* A capability declaration for lus_defcapability. */
typedef struct lus_Capability {
  /* The base name, such as "myext". */
  const char *name;
  /* The subcapability names, ending with NULL, or NULL for none. */
  const char *const *subcapabilities;
  /* One of the LUS_CAP_ kinds. */
  int kind;
  /* The matcher of a LUS_CAP_CUSTOM capability. */
  lus_CapMatch match;
  /* Passed to match. */
  void *ud;
} lus_Capability;

/*
** Declares a capability, so scripts can pledge it and C code can check it.
** The strings are copied. Fails when the name is already declared or the
** declaration is incomplete.
*/
int lus_defcapability(lus_State *L, const lus_Capability *cap);

/*
** Decides a script pledge that the host has neither granted nor rejected.
** It receives the capability (such as "fs:read") and the requested value
** (NULL when there is none), and returns 1 to allow the grant.
*/
typedef int (*lus_RequestHook)(void *ud, lus_State *L, const char *capability,
                               const char *value);

/* Installs the request hook, or removes it when hook is NULL. */
void lus_onrequest(lus_State *L, lus_RequestHook hook, void *ud);

#ifdef __cplusplus
}
#endif

#endif
