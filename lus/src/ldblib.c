/*
** $Id: ldblib.c $
** Interface from Lua to its debug API
** See Copyright Notice in lua.h
*/

#define ldblib_c
#define LUA_LIB

#include "lprefix.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"

#include "last.h"
#include "lauxlib.h"
#include "ldo.h"
#include "lformat.h"
#include "llimits.h"
#include "lmem.h"
#include "lparser.h"
#include "lstring.h"
#include "lualib.h"
#include "lzio.h"

/*
** The hook table at registry[HOOKKEY] maps threads to their current
** hook function.
*/
static const char *const HOOKKEY = "_HOOKKEY";

/*
** If L1 != L, L1 can be in any state, and therefore there are no
** guarantees about its stack space; any push in L1 must be
** checked.
*/
static void checkstack(lua_State *L, lua_State *L1, int n) {
  if (l_unlikely(L != L1 && !lua_checkstack(L1, n)))
    luaL_error(L, "stack overflow");
}

static int db_getregistry(lua_State *L) {
  lua_pushvalue(L, LUA_REGISTRYINDEX);
  return 1;
}

static int db_getmetatable(lua_State *L) {
  luaL_checkany(L, 1);
  if (!lua_getmetatable(L, 1)) {
    lua_pushnil(L); /* no metatable */
  }
  return 1;
}

static int db_setmetatable(lua_State *L) {
  int t = lua_type(L, 2);
  luaL_argexpected(L, t == LUA_TNIL || t == LUA_TTABLE, 2, "nil or table");
  lua_settop(L, 2);
  lua_setmetatable(L, 1);
  return 1; /* return 1st argument */
}

static int db_getuservalue(lua_State *L) {
  int n = (int)luaL_optinteger(L, 2, 1);
  if (lua_type(L, 1) != LUA_TUSERDATA)
    luaL_pushfail(L);
  else if (lua_getiuservalue(L, 1, n) != LUA_TNONE) {
    lua_pushboolean(L, 1);
    return 2;
  }
  return 1;
}

static int db_setuservalue(lua_State *L) {
  int n = (int)luaL_optinteger(L, 3, 1);
  luaL_checktype(L, 1, LUA_TUSERDATA);
  luaL_checkany(L, 2);
  lua_settop(L, 2);
  if (!lua_setiuservalue(L, 1, n))
    luaL_pushfail(L);
  return 1;
}

/*
** Auxiliary function used by several library functions: check for
** an optional thread as function's first argument and set 'arg' with
** 1 if this argument is present (so that functions can skip it to
** access their other arguments)
*/
static lua_State *getthread(lua_State *L, int *arg) {
  if (lua_isthread(L, 1)) {
    *arg = 1;
    return lua_tothread(L, 1);
  } else {
    *arg = 0;
    return L; /* function will operate over current thread */
  }
}

/*
** Variations of 'lua_settable', used by 'db_getinfo' to put results
** from 'lua_getinfo' into result table. Key is always a string;
** value can be a string, an int, or a boolean.
*/
static void settabss(lua_State *L, const char *k, const char *v) {
  lua_pushstring(L, v);
  lua_setfield(L, -2, k);
}

static void settabsi(lua_State *L, const char *k, int v) {
  lua_pushinteger(L, v);
  lua_setfield(L, -2, k);
}

static void settabsb(lua_State *L, const char *k, int v) {
  lua_pushboolean(L, v);
  lua_setfield(L, -2, k);
}

/*
** In function 'db_getinfo', the call to 'lua_getinfo' may push
** results on the stack; later it creates the result table to put
** these objects. Function 'treatstackoption' puts the result from
** 'lua_getinfo' on top of the result table so that it can call
** 'lua_setfield'.
*/
static void treatstackoption(lua_State *L, lua_State *L1, const char *fname) {
  if (L == L1)
    lua_rotate(L, -2, 1); /* exchange object and table */
  else
    lua_xmove(L1, L, 1);      /* move object to the "main" stack */
  lua_setfield(L, -2, fname); /* put object into table */
}

/*
** Calls 'lua_getinfo' and collects all results in a new table.
** L1 needs stack space for an optional input (function) plus
** two optional outputs (function and line table) from function
** 'lua_getinfo'.
*/
static int db_getinfo(lua_State *L) {
  lua_Debug ar;
  int arg;
  lua_State *L1 = getthread(L, &arg);
  const char *options = luaL_optstring(L, arg + 2, "flnSrtu");
  checkstack(L, L1, 3);
  luaL_argcheck(L, options[0] != '>', arg + 2, "invalid option '>'");
  if (lua_isfunction(L, arg + 1)) {               /* info about a function? */
    options = lua_pushfstring(L, ">%s", options); /* add '>' to 'options' */
    lua_pushvalue(L, arg + 1); /* move function to 'L1' stack */
    lua_xmove(L, L1, 1);
  } else { /* stack level */
    if (!lua_getstack(L1, (int)luaL_checkinteger(L, arg + 1), &ar)) {
      luaL_pushfail(L); /* level out of range */
      return 1;
    }
  }
  if (!lua_getinfo(L1, options, &ar))
    return luaL_argerror(L, arg + 2, "invalid option");
  lua_newtable(L); /* table to collect results */
  if (strchr(options, 'S')) {
    lua_pushlstring(L, ar.source, ar.srclen);
    lua_setfield(L, -2, "source");
    settabss(L, "short_src", ar.short_src);
    settabsi(L, "linedefined", ar.linedefined);
    settabsi(L, "lastlinedefined", ar.lastlinedefined);
    settabss(L, "what", ar.what);
  }
  if (strchr(options, 'l'))
    settabsi(L, "currentline", ar.currentline);
  if (strchr(options, 'u')) {
    settabsi(L, "nups", ar.nups);
    settabsi(L, "nparams", ar.nparams);
    settabsb(L, "isvararg", ar.isvararg);
  }
  if (strchr(options, 'n')) {
    settabss(L, "name", ar.name);
    settabss(L, "namewhat", ar.namewhat);
  }
  if (strchr(options, 'r')) {
    settabsi(L, "ftransfer", ar.ftransfer);
    settabsi(L, "ntransfer", ar.ntransfer);
  }
  if (strchr(options, 't')) {
    settabsb(L, "istailcall", ar.istailcall);
    settabsi(L, "extraargs", ar.extraargs);
  }
  if (strchr(options, 'L'))
    treatstackoption(L, L1, "activelines");
  if (strchr(options, 'f'))
    treatstackoption(L, L1, "func");
  return 1; /* return table */
}

static int db_getlocal(lua_State *L) {
  int arg;
  lua_State *L1 = getthread(L, &arg);
  int nvar = (int)luaL_checkinteger(L, arg + 2);    /* local-variable index */
  if (lua_isfunction(L, arg + 1)) {                 /* function argument? */
    lua_pushvalue(L, arg + 1);                      /* push function */
    lua_pushstring(L, lua_getlocal(L, NULL, nvar)); /* push local name */
    return 1; /* return only name (there is no value) */
  } else {    /* stack-level argument */
    lua_Debug ar;
    const char *name;
    int level = (int)luaL_checkinteger(L, arg + 1);
    if (l_unlikely(!lua_getstack(L1, level, &ar))) /* out of range? */
      return luaL_argerror(L, arg + 1, "level out of range");
    checkstack(L, L1, 1);
    name = lua_getlocal(L1, &ar, nvar);
    if (name) {
      lua_xmove(L1, L, 1);     /* move local value */
      lua_pushstring(L, name); /* push name */
      lua_rotate(L, -2, 1);    /* re-order */
      return 2;
    } else {
      luaL_pushfail(L); /* no name (nor value) */
      return 1;
    }
  }
}

static int db_setlocal(lua_State *L) {
  int arg;
  const char *name;
  lua_State *L1 = getthread(L, &arg);
  lua_Debug ar;
  int level = (int)luaL_checkinteger(L, arg + 1);
  int nvar = (int)luaL_checkinteger(L, arg + 2);
  if (l_unlikely(!lua_getstack(L1, level, &ar))) /* out of range? */
    return luaL_argerror(L, arg + 1, "level out of range");
  luaL_checkany(L, arg + 3);
  lua_settop(L, arg + 3);
  checkstack(L, L1, 1);
  lua_xmove(L, L1, 1);
  name = lua_setlocal(L1, &ar, nvar);
  if (name == NULL)
    lua_pop(L1, 1); /* pop value (if not popped by 'lua_setlocal') */
  lua_pushstring(L, name);
  return 1;
}

/*
** get (if 'get' is true) or set an upvalue from a closure
*/
static int auxupvalue(lua_State *L, int get) {
  const char *name;
  int n = (int)luaL_checkinteger(L, 2); /* upvalue index */
  luaL_checktype(L, 1, LUA_TFUNCTION);  /* closure */
  name = get ? lua_getupvalue(L, 1, n) : lua_setupvalue(L, 1, n);
  if (name == NULL)
    return 0;
  lua_pushstring(L, name);
  lua_insert(L, -(get + 1)); /* no-op if get is false */
  return get + 1;
}

static int db_getupvalue(lua_State *L) { return auxupvalue(L, 1); }

static int db_setupvalue(lua_State *L) {
  luaL_checkany(L, 3);
  return auxupvalue(L, 0);
}

/*
** Check whether a given upvalue from a given closure exists and
** returns its index
*/
static void *checkupval(lua_State *L, int argf, int argnup, int *pnup) {
  void *id;
  int nup = (int)luaL_checkinteger(L, argnup); /* upvalue index */
  luaL_checktype(L, argf, LUA_TFUNCTION);      /* closure */
  id = lua_upvalueid(L, argf, nup);
  if (pnup) {
    luaL_argcheck(L, id != NULL, argnup, "invalid upvalue index");
    *pnup = nup;
  }
  return id;
}

static int db_upvalueid(lua_State *L) {
  void *id = checkupval(L, 1, 2, NULL);
  if (id != NULL)
    lua_pushlightuserdata(L, id);
  else
    luaL_pushfail(L);
  return 1;
}

static int db_upvaluejoin(lua_State *L) {
  int n1, n2;
  checkupval(L, 1, 2, &n1);
  checkupval(L, 3, 4, &n2);
  luaL_argcheck(L, !lua_iscfunction(L, 1), 1, "Lua function expected");
  luaL_argcheck(L, !lua_iscfunction(L, 3), 3, "Lua function expected");
  lua_upvaluejoin(L, 1, n1, 3, n2);
  return 0;
}

/*
** Call hook function registered at hook table for the current
** thread (if there is one)
*/
static void hookf(lua_State *L, lua_Debug *ar) {
  static const char *const hooknames[] = {"call", "return", "line", "count",
                                          "tail call"};
  lua_getfield(L, LUA_REGISTRYINDEX, HOOKKEY);
  lua_pushthread(L);
  if (lua_rawget(L, -2) == LUA_TFUNCTION) { /* is there a hook function? */
    lua_pushstring(L, hooknames[(int)ar->event]); /* push event name */
    if (ar->currentline >= 0)
      lua_pushinteger(L, ar->currentline); /* push current line */
    else
      lua_pushnil(L);
    lua_assert(lua_getinfo(L, "lS", ar));
    lua_call(L, 2, 0); /* call hook function */
  }
}

/*
** Convert a string mask (for 'sethook') into a bit mask
*/
static int makemask(const char *smask, int count) {
  int mask = 0;
  if (strchr(smask, 'c'))
    mask |= LUA_MASKCALL;
  if (strchr(smask, 'r'))
    mask |= LUA_MASKRET;
  if (strchr(smask, 'l'))
    mask |= LUA_MASKLINE;
  if (count > 0)
    mask |= LUA_MASKCOUNT;
  return mask;
}

/*
** Convert a bit mask (for 'gethook') into a string mask
*/
static char *unmakemask(int mask, char *smask) {
  int i = 0;
  if (mask & LUA_MASKCALL)
    smask[i++] = 'c';
  if (mask & LUA_MASKRET)
    smask[i++] = 'r';
  if (mask & LUA_MASKLINE)
    smask[i++] = 'l';
  smask[i] = '\0';
  return smask;
}

static int db_sethook(lua_State *L) {
  int arg, mask, count;
  lua_Hook func;
  lua_State *L1 = getthread(L, &arg);
  if (lua_isnoneornil(L, arg + 1)) { /* no hook? */
    lua_settop(L, arg + 1);
    func = NULL;
    mask = 0;
    count = 0; /* turn off hooks */
  } else {
    const char *smask = luaL_checkstring(L, arg + 2);
    luaL_checktype(L, arg + 1, LUA_TFUNCTION);
    count = (int)luaL_optinteger(L, arg + 3, 0);
    func = hookf;
    mask = makemask(smask, count);
  }
  if (!luaL_getsubtable(L, LUA_REGISTRYINDEX, HOOKKEY)) {
    /* table just created; initialize it */
    lua_pushliteral(L, "k");
    lua_setfield(L, -2, "__mode"); /** hooktable.__mode = "k" */
    lua_pushvalue(L, -1);
    lua_setmetatable(L, -2); /* metatable(hooktable) = hooktable */
  }
  checkstack(L, L1, 1);
  lua_pushthread(L1);
  lua_xmove(L1, L, 1);       /* key (thread) */
  lua_pushvalue(L, arg + 1); /* value (hook function) */
  lua_rawset(L, -3);         /* hooktable[L1] = new Lua hook */
  lua_sethook(L1, func, mask, count);
  return 0;
}

static int db_gethook(lua_State *L) {
  int arg;
  lua_State *L1 = getthread(L, &arg);
  char buff[5];
  int mask = lua_gethookmask(L1);
  lua_Hook hook = lua_gethook(L1);
  if (hook == NULL) { /* no hook? */
    luaL_pushfail(L);
    return 1;
  } else if (hook != hookf) /* external hook? */
    lua_pushliteral(L, "external hook");
  else { /* hook table must exist */
    lua_getfield(L, LUA_REGISTRYINDEX, HOOKKEY);
    checkstack(L, L1, 1);
    lua_pushthread(L1);
    lua_xmove(L1, L, 1);
    lua_rawget(L, -2); /* 1st result = hooktable[L1] */
    lua_remove(L, -2); /* remove hook table */
  }
  lua_pushstring(L, unmakemask(mask, buff)); /* 2nd result = mask */
  lua_pushinteger(L, lua_gethookcount(L1));  /* 3rd result = count */
  return 3;
}

static int db_debug(lua_State *L) {
  for (;;) {
    char buffer[250];
    lua_writestringerror("%s", "lua_debug> ");
    if (fgets(buffer, sizeof(buffer), stdin) == NULL ||
        strcmp(buffer, "cont\n") == 0)
      return 0;
    if (luaL_loadbuffer(L, buffer, strlen(buffer), "=(debug command)") ||
        lua_pcall(L, 0, 0, 0))
      lua_writestringerror("%s\n", luaL_tolstring(L, -1, NULL));
    lua_settop(L, 0); /* remove eventual returns */
  }
}

static int db_traceback(lua_State *L) {
  int arg;
  lua_State *L1 = getthread(L, &arg);
  const char *msg = lua_tostring(L, arg + 1);
  if (msg == NULL && !lua_isnoneornil(L, arg + 1)) /* non-string 'msg'? */
    lua_pushvalue(L, arg + 1);                     /* return it untouched */
  else {
    int level = (int)luaL_optinteger(L, arg + 2, (L == L1) ? 1 : 0);
    luaL_traceback(L, L1, msg, level);
  }
  return 1;
}

/*
** String reader for debug.parse (same pattern as lauxlib.c)
*/
typedef struct {
  const char *s;
  size_t size;
} ParseStringReader;

static const char *parseGetS(lua_State *L, void *ud, size_t *size) {
  ParseStringReader *ls = (ParseStringReader *)ud;
  UNUSED(L);
  if (ls->size == 0)
    return NULL;
  *size = ls->size;
  ls->size = 0;
  return ls->s;
}

/*
** Parse a string and return its AST as a table.
** debug.parse(code, [chunkname]) -> table, errors | nil, error
** On success: returns AST table and nil (no errors)
** On error: returns nil and error message string
*/

/* Structure for passing parse data through protected call */
typedef struct ParseData {
  const char *code;
  size_t len;
  const char *chunkname;
  LusAst *ast;
  Mbuffer *buff;
  Dyndata *dyd;
} ParseData;

/* Protected parse function */
static void f_parse(lua_State *L, void *ud) {
  ParseData *pd = (ParseData *)ud;
  ParseStringReader reader;
  ZIO z;
  int c;

  reader.s = pd->code;
  reader.size = pd->len;
  luaZ_init(L, &z, parseGetS, &reader);
  c = zgetc(&z);

  /* Check for binary chunk */
  if (c == LUA_SIGNATURE[0]) {
    luaL_error(L, "cannot parse binary chunk");
    return;
  }

  /* Parse with AST generation enabled */
  LClosure *cl = luaY_parser(L, &z, pd->buff, pd->dyd, pd->chunkname, c, pd->ast);

  /* Pop the closure from stack (we don't need it) */
  lua_pop(L, 1);
  (void)cl;
}

static int db_parse(lua_State *L) {
  size_t len;
  const char *code = luaL_checklstring(L, 1, &len);
  const char *chunkname = luaL_optstring(L, 2, "=(parse)");
  LusAst *ast;
  Mbuffer buff;
  Dyndata dyd;
  ParseData pd;
  TStatus status;

  /* Parse options table if provided (third argument) */
  int include_comments = 1;  /* default: include comments */
  int error_recover = 1;     /* default: return partial AST on error */

  if (lua_istable(L, 3)) {
    /* Get 'comments' option */
    lua_getfield(L, 3, "comments");
    if (!lua_isnil(L, -1)) {
      include_comments = lua_toboolean(L, -1);
    }
    lua_pop(L, 1);

    /* Get 'recover' option */
    lua_getfield(L, 3, "recover");
    if (!lua_isnil(L, -1)) {
      error_recover = lua_toboolean(L, -1);
    }
    lua_pop(L, 1);
  }

  /* Initialize AST container */
  ast = lusA_new(L);
  ast->recover = error_recover;

  /* Initialize parser data structures */
  luaZ_initbuffer(L, &buff);
  luaY_initdyndata(L, &dyd);

  /* Setup parse data */
  pd.code = code;
  pd.len = len;
  pd.chunkname = chunkname;
  pd.ast = ast;
  pd.buff = &buff;
  pd.dyd = &dyd;

  /* Stop GC during parsing - AST holds raw TString* pointers that are
     not anchored to the Lua stack, so GC could collect them */
  lua_gc(L, LUA_GCSTOP, 0);

  /* Parse with protected call to catch errors */
  status = luaD_pcall(L, f_parse, &pd, savestack(L, L->top.p), 0);

  /* Restart GC */
  lua_gc(L, LUA_GCRESTART, 0);

  /* Clean up parser data */
  luaZ_freebuffer(L, &buff);
  luaY_freedyndata(&dyd);

  if (status != LUA_OK) {
    /* Parse failed - check if we should return partial AST */
    /* Error message is on the stack */
    const char *errmsg = lua_tostring(L, -1);

    if (error_recover && ast->root != NULL) {
      /* We have a partial AST - add the error to it and return partial AST */
      /* Extract line from error message.
      ** Format: "[string \"...\"]:<line>: <msg>" or "<file>:<line>: <msg>"
      ** or "?:?: <msg>" when source is NULL.
      ** The first colon may be inside the source name (e.g. inside brackets),
      ** so we look for "]:digit" first (string chunks), then fall back to
      ** finding the first colon followed by a digit (file chunks). */
      int errline = 1, errcol = 1;
      if (errmsg) {
        const char *p = strstr(errmsg, "]:");
        if (p) {
          /* String chunk: [string "name"]:LINE: ... */
          errline = atoi(p + 2);
        } else {
          /* File chunk: filename:LINE: ... */
          const char *colon = strchr(errmsg, ':');
          if (colon) errline = atoi(colon + 1);
        }
        if (errline <= 0) errline = 1;
      }

      /* Create a TString for the error message and add to AST errors */
      TString *errmsg_ts = errmsg ? luaS_new(L, errmsg) : NULL;
      lusA_adderror(ast, errline, errcol, errmsg_ts);

      /* Convert partial AST to Lua table (includes errors array) */
      lua_pop(L, 1);  /* remove error message from stack */

      /* Filter out comments if not requested */
      if (!include_comments) {
        ast->comments = NULL;
        ast->lastcomment = NULL;
      }

      lusA_totable(L, ast);
      lusA_free(L, ast);

      /* Return partial AST table and nil */
      lua_pushnil(L);
      return 2;
    }

    /* No partial AST or recover disabled - return nil and error message */
    lusA_free(L, ast);
    lua_pushnil(L);
    lua_insert(L, -2);  /* put nil before error message */
    return 2;
  }

  /* Filter out comments if not requested */
  if (!include_comments) {
    ast->comments = NULL;
    ast->lastcomment = NULL;
  }

  /* Convert AST to Lua table */
  lusA_totable(L, ast);

  /* Free AST (the table is now a copy) */
  lusA_free(L, ast);

  /* Return AST table and nil (no errors) */
  lua_pushnil(L);
  return 2;
}

/*
** debug.format(source [, chunkname [, indent_width]])
** Format Lus source code. Returns formatted string, or nil + error message.
*/
static int db_format(lua_State *L) {
  size_t srclen;
  const char *source = luaL_checklstring(L, 1, &srclen);
  const char *chunkname = luaL_optstring(L, 2, "=format");
  int indent_width = (int)luaL_optinteger(L, 3, 4);
  const char *errmsg = NULL;

  char *result = lusF_format(L, source, srclen, chunkname,
                              indent_width, 80, &errmsg);
  if (result == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, errmsg ? errmsg : "format error");
    return 2;
  }

  lua_pushstring(L, result);
  free(result);
  return 1;
}

static const luaL_Reg dblib[] = {{"debug", db_debug},
                                 {"format", db_format},
                                 {"getuservalue", db_getuservalue},
                                 {"gethook", db_gethook},
                                 {"getinfo", db_getinfo},
                                 {"getlocal", db_getlocal},
                                 {"getregistry", db_getregistry},
                                 {"getmetatable", db_getmetatable},
                                 {"getupvalue", db_getupvalue},
                                 {"parse", db_parse},
                                 {"upvaluejoin", db_upvaluejoin},
                                 {"upvalueid", db_upvalueid},
                                 {"setuservalue", db_setuservalue},
                                 {"sethook", db_sethook},
                                 {"setlocal", db_setlocal},
                                 {"setmetatable", db_setmetatable},
                                 {"setupvalue", db_setupvalue},
                                 {"traceback", db_traceback},
                                 {NULL, NULL}};

LUAMOD_API int luaopen_debug(lua_State *L) {
  luaL_newlib(L, dblib);
  return 1;
}
