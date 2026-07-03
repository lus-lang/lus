/*
** lsqlitelib.c
** Embedded SQLite binding for Lus
** See Copyright Notice in lua.h
**
** Exposes io.sqlite(path [, mode]), which opens a database handle whose
** methods run statements (exec/run/query/prepare/transaction). Three
** userdata types cooperate here:
**
**   sqlite.db     : the connection. Uservalue 1 is a weak-valued registry
**                   of every live statement, so closing the database can
**                   finalize them first (SQLite requires it).
**   sqlite.stmt   : a prepared statement. Uservalue 1 is the db userdata,
**                   which keeps the connection alive. The stmt pointer is
**                   the single owner of the sqlite3_stmt: every finalize
**                   routes through finalize_stmt so a pointer can never be
**                   finalized twice.
**   sqlite.cursor : one live iteration. Uservalue 1 is the stmt userdata.
**                   A generation counter detects statements reset while an
**                   iterator is live. db:query and stmt:query return the
**                   cursor as the generic for's closing value, so breaking
**                   out of a loop still releases the statement.
**
** Security: file-backed opens pledge-check the path plus the -journal,
** -wal, and -shm sidecars. ATTACH and VACUUM INTO are denied through an
** authorizer, URI filenames are rejected, and SQLITE_TEMP_STORE=3 keeps
** temp structures in memory, so SQLite never touches an unpledged path.
** ":memory:" opens with no pledge at all.
*/

#define lsqlitelib_c
#define LUA_LIB

#include "lprefix.h"

#include <string.h>

#include "sqlite3.h"

#include "lua.h"

#include "lauxlib.h"
#include "lobject.h"
#include "lpledge.h"
#include "lstate.h"
#include "lvector.h"

#define SQLITE_DB_METATABLE "sqlite.db"
#define SQLITE_STMT_METATABLE "sqlite.stmt"
#define SQLITE_CURSOR_METATABLE "sqlite.cursor"

typedef struct LSqliteDB {
  sqlite3 *db; /* NULL means closed, io-style */
  int readonly;
} LSqliteDB;

typedef struct LSqliteStmt {
  sqlite3_stmt *stmt; /* NULL means closed or finalized */
  LSqliteDB *db;      /* backing struct, kept valid by uservalue 1 */
  int generation;     /* bumped on every reset and finalize */
} LSqliteStmt;

typedef struct LSqliteCursor {
  LSqliteStmt *stmt; /* NULL once spent or closed */
  int generation;    /* snapshot taken when the iteration began */
  int owns;          /* 1: finalize on completion, 0: reset */
} LSqliteCursor;

/* ===================================================================
** Handle checking
** =================================================================== */

/*
** Paths and SQL must be actual strings. The usual number-to-string
** coercion would turn io.sqlite(42) into a database named "42".
*/
static const char *checkstring_strict(lua_State *L, int idx) {
  luaL_checktype(L, idx, LUA_TSTRING);
  return lua_tostring(L, idx);
}

static LSqliteDB *checkdb(lua_State *L) {
  LSqliteDB *d = (LSqliteDB *)luaL_checkudata(L, 1, SQLITE_DB_METATABLE);
  if (l_unlikely(d->db == NULL))
    luaL_error(L, "attempt to use a closed database");
  return d;
}

static LSqliteStmt *checkstmt(lua_State *L) {
  LSqliteStmt *s = (LSqliteStmt *)luaL_checkudata(L, 1, SQLITE_STMT_METATABLE);
  if (l_unlikely(s->stmt == NULL))
    luaL_error(L, "attempt to use a closed statement");
  if (l_unlikely(s->db->db == NULL))
    luaL_error(L, "attempt to use a closed database");
  return s;
}

/*
** The single owner of every sqlite3_stmt. Nulling the pointer and bumping
** the generation here is what makes the close/GC/cursor interleavings
** safe: any other holder checks the NULL sentinel before touching it.
*/
static void finalize_stmt(LSqliteStmt *s) {
  if (s->stmt != NULL) {
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
    s->generation++;
  }
}

/* ===================================================================
** Opening and closing
** =================================================================== */

/*
** Deny ATTACH with a filename, which also covers the VACUUM INTO target.
** Both would open files the pledge sweep never saw. A nameless attach is
** how plain VACUUM builds its temp database, which SQLITE_TEMP_STORE=3
** keeps in memory, so it stays allowed. The callback only returns a
** code, so it can never longjmp across SQLite frames.
*/
static int sqlite_auth(void *ud, int action, const char *a3, const char *a4,
                       const char *a5, const char *a6) {
  (void)ud;
  (void)a4;
  (void)a5;
  (void)a6;
  if (action == SQLITE_ATTACH && a3 != NULL && a3[0] != '\0')
    return SQLITE_DENY;
  return SQLITE_OK;
}

/*
** Pledge-check a database path together with SQLite's sidecar files.
** WAL mode touches -wal and -shm, rollback journals touch -journal, so
** all four paths must be granted up front: denial happens at open time
** with the standard permission message instead of mid-transaction.
*/
static void sqlite_checkfsperm(lua_State *L, const char *path, int readonly) {
  static const char *const suffixes[] = {"", "-journal", "-wal", "-shm"};
  int i;
  for (i = 0; i < 4; i++) {
    lua_pushfstring(L, "%s%s", path, suffixes[i]);
    lus_checkfsperm(L, "fs:read", lua_tostring(L, -1));
    if (!readonly)
      lus_checkfsperm(L, "fs:write", lua_tostring(L, -1));
    lua_pop(L, 1);
  }
}

/*
** Drain the weak statement registry (uservalue 1 of the db userdata at
** 'idx'), finalize every live statement, then close the connection.
*/
static void close_db(lua_State *L, LSqliteDB *d, int idx) {
  if (lua_getiuservalue(L, idx, 1) == LUA_TTABLE) {
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
      LSqliteStmt *s = (LSqliteStmt *)lua_touserdata(L, -1);
      if (s != NULL)
        finalize_stmt(s);
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  sqlite3_close_v2(d->db);
  d->db = NULL;
}

static int db_close(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  close_db(L, d, 1);
  lua_pushboolean(L, 1);
  return 1;
}

/* Tolerant variant bound to both __gc and __close */
static int db_gc(lua_State *L) {
  LSqliteDB *d = (LSqliteDB *)luaL_checkudata(L, 1, SQLITE_DB_METATABLE);
  if (d->db != NULL)
    close_db(L, d, 1);
  return 0;
}

static int db_tostring(lua_State *L) {
  LSqliteDB *d = (LSqliteDB *)luaL_checkudata(L, 1, SQLITE_DB_METATABLE);
  if (d->db == NULL)
    lua_pushliteral(L, "database (closed)");
  else
    lua_pushfstring(L, "database (%p)", (void *)d->db);
  return 1;
}

static int io_sqlite(lua_State *L) {
  const char *path = checkstring_strict(L, 1);
  const char *mode = luaL_optstring(L, 2, "rw");
  LSqliteDB *d;
  sqlite3 *db = NULL;
  int readonly, in_memory, rc;
  int flags;
  if (strcmp(mode, "r") == 0)
    readonly = 1;
  else {
    luaL_argcheck(L, strcmp(mode, "rw") == 0, 2, "invalid mode");
    readonly = 0;
  }
  flags = readonly ? SQLITE_OPEN_READONLY
                   : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
  luaL_argcheck(L, *path != '\0', 1, "empty database path");
  luaL_argcheck(L, strncmp(path, "file:", 5) != 0, 1,
                "URI filenames are not supported");
  in_memory = (strcmp(path, ":memory:") == 0);
  if (!in_memory)
    sqlite_checkfsperm(L, path, readonly);
  /* create a closed handle first, so a raise leaves a consistent state */
  d = (LSqliteDB *)lua_newuserdatauv(L, sizeof(LSqliteDB), 1);
  d->db = NULL;
  d->readonly = readonly;
  luaL_setmetatable(L, SQLITE_DB_METATABLE);
  lua_createtable(L, 0, 0); /* the statement registry, weak-valued */
  lua_createtable(L, 0, 1);
  lua_pushliteral(L, "v");
  lua_setfield(L, -2, "__mode");
  lua_setmetatable(L, -2);
  lua_setiuservalue(L, -2, 1);
  rc = sqlite3_open_v2(path, &db, flags, NULL);
  if (rc != SQLITE_OK) {
    lua_pushfstring(L, "cannot open database '%s' (%s)", path,
                    db != NULL ? sqlite3_errmsg(db) : sqlite3_errstr(rc));
    sqlite3_close(db);
    return lua_error(L);
  }
  d->db = db;
  sqlite3_set_authorizer(db, sqlite_auth, NULL);
  sqlite3_busy_timeout(db, 5000);
  if (!in_memory && !readonly) {
    /* the acquis promises WAL reader/writer concurrency for file-backed
       databases; a corrupt or non-SQLite file also surfaces here */
    char *errmsg = NULL;
    if (sqlite3_exec(db, "PRAGMA journal_mode=WAL", NULL, NULL, &errmsg) !=
        SQLITE_OK) {
      lua_pushfstring(L, "cannot open database '%s' (%s)", path,
                      errmsg != NULL ? errmsg : sqlite3_errmsg(db));
      sqlite3_free(errmsg);
      close_db(L, d, -1);
      return lua_error(L);
    }
  }
  return 1;
}

/* ===================================================================
** Statement preparation and binding
** =================================================================== */

/*
** Wrap a raw sqlite3_stmt in a statement userdata anchored to the db
** userdata at 'dbidx', and register it in the db's weak registry so
** db:close can finalize it. Pushes the userdata and returns its struct.
*/
static LSqliteStmt *new_stmt(lua_State *L, int dbidx, sqlite3_stmt *stmt) {
  LSqliteStmt *s;
  dbidx = lua_absindex(L, dbidx);
  s = (LSqliteStmt *)lua_newuserdatauv(L, sizeof(LSqliteStmt), 1);
  s->db = (LSqliteDB *)lua_touserdata(L, dbidx);
  s->generation = 0;
  s->stmt = stmt;
  luaL_setmetatable(L, SQLITE_STMT_METATABLE);
  lua_pushvalue(L, dbidx);
  lua_setiuservalue(L, -2, 1);
  lua_getiuservalue(L, dbidx, 1); /* the weak statement registry */
  lua_pushlightuserdata(L, (void *)s);
  lua_pushvalue(L, -3);
  lua_rawset(L, -3);
  lua_pop(L, 1);
  return s;
}

/*
** Prepare exactly one statement from 'sql', wrap it, push the userdata,
** and return its struct. The tail after the first statement may hold
** only whitespace and SQL comments, which is checked by preparing it:
** a tail that yields another statement (or fails to parse) raises.
*/
static LSqliteStmt *prepare_single(lua_State *L, LSqliteDB *d,
                                   const char *sql, int dbidx) {
  sqlite3_stmt *stmt = NULL;
  const char *tail = NULL;
  if (sqlite3_prepare_v2(d->db, sql, -1, &stmt, &tail) != SQLITE_OK)
    luaL_error(L, "%s", sqlite3_errmsg(d->db));
  if (stmt == NULL) /* comment- or whitespace-only sql */
    luaL_error(L, "sql contains no statement");
  if (tail != NULL && *tail != '\0') {
    sqlite3_stmt *rest = NULL;
    int rc = sqlite3_prepare_v2(d->db, tail, -1, &rest, NULL);
    if (rest != NULL || rc != SQLITE_OK) {
      sqlite3_finalize(rest);
      sqlite3_finalize(stmt);
      luaL_error(L, "sql contains more than one statement");
    }
  }
  return new_stmt(L, dbidx, stmt);
}

/*
** Bind the value at 'argidx' to parameter 'pidx'. The statement is
** already owned by a userdata, so raising here leaks nothing.
*/
static void bind_one(lua_State *L, LSqliteStmt *s, int pidx, int argidx) {
  int rc;
  switch (lua_type(L, argidx)) {
    case LUA_TNIL:
      rc = sqlite3_bind_null(s->stmt, pidx);
      break;
    case LUA_TBOOLEAN:
      rc = sqlite3_bind_int64(s->stmt, pidx, lua_toboolean(L, argidx));
      break;
    case LUA_TNUMBER:
      if (lua_isinteger(L, argidx))
        rc = sqlite3_bind_int64(s->stmt, pidx,
                                (sqlite3_int64)lua_tointeger(L, argidx));
      else
        rc = sqlite3_bind_double(s->stmt, pidx, lua_tonumber(L, argidx));
      break;
    case LUA_TSTRING: {
      size_t len;
      const char *v = lua_tolstring(L, argidx, &len);
      rc = sqlite3_bind_text64(s->stmt, pidx, v, (sqlite3_uint64)len,
                               SQLITE_TRANSIENT, SQLITE_UTF8);
      break;
    }
    case LUA_TVECTOR: {
      /* a NULL data pointer would bind NULL, so a zero-length blob
         binds through a non-NULL dummy pointer instead */
      Vector *v = vecvalue(s2v(L->ci->func.p + argidx));
      const void *data = (v->len > 0) ? (const void *)v->data : (const void *)"";
      rc = sqlite3_bind_blob64(s->stmt, pidx, data, (sqlite3_uint64)v->len,
                               SQLITE_TRANSIENT);
      break;
    }
    default:
      rc = 0;
      luaL_error(L, "cannot bind %s value to parameter %d",
                 luaL_typename(L, argidx), pidx);
  }
  if (rc != SQLITE_OK)
    luaL_error(L, "%s", sqlite3_errmsg(s->db->db));
}

/*
** Bind every parameter of the statement from the stack slice
** [firstarg, lastarg]. Named parameters (:name, @name, $name) bind from
** a single table argument, positional '?' parameters bind from the
** values in order, and the two styles never mix.
*/
static void bind_values(lua_State *L, LSqliteStmt *s, int firstarg,
                        int lastarg) {
  int np = sqlite3_bind_parameter_count(s->stmt);
  int named = 0, positional = 0;
  int i;
  int nvals = lastarg - firstarg + 1;
  if (nvals < 0)
    nvals = 0;
  for (i = 1; i <= np; i++) {
    const char *name = sqlite3_bind_parameter_name(s->stmt, i);
    if (name == NULL)
      positional = 1;
    else if (name[0] == '?')
      luaL_error(L, "numbered parameters are not supported");
    else
      named = 1;
  }
  if (named && positional)
    luaL_error(L, "statement mixes named and positional parameters");
  if (named) {
    if (nvals != 1 || !lua_istable(L, firstarg))
      luaL_error(L, "statement uses named parameters, but no table was given");
    for (i = 1; i <= np; i++) {
      const char *name = sqlite3_bind_parameter_name(s->stmt, i);
      lua_getfield(L, firstarg, name + 1); /* skip the sigil */
      if (lua_isnil(L, -1))
        luaL_error(L, "no value for parameter '%s'", name);
      bind_one(L, s, i, lua_gettop(L));
      lua_pop(L, 1);
    }
  }
  else {
    if (np > 0 && nvals == 1 && lua_istable(L, firstarg))
      luaL_error(L, "statement uses positional parameters, but a table "
                    "was given");
    if (nvals != np)
      luaL_error(L, "statement has %d parameters, but %d values were given",
                 np, nvals);
    for (i = 1; i <= np; i++)
      bind_one(L, s, i, firstarg + i - 1);
  }
}

/* Step a statement to completion, discarding any rows */
static void run_to_completion(lua_State *L, LSqliteStmt *s) {
  int rc;
  while ((rc = sqlite3_step(s->stmt)) == SQLITE_ROW) {
  }
  if (rc != SQLITE_DONE) {
    lua_pushfstring(L, "%s", sqlite3_errmsg(s->db->db));
    sqlite3_reset(s->stmt);
    lua_error(L);
  }
}

/* ===================================================================
** Query iteration
** =================================================================== */

/* Push the current row as a table keyed by column name */
static void push_row(lua_State *L, LSqliteStmt *s) {
  sqlite3_stmt *stmt = s->stmt;
  int ncols = sqlite3_column_count(stmt);
  int i;
  luaL_checkstack(L, 4, "sqlite row");
  lua_createtable(L, 0, ncols);
  for (i = 0; i < ncols; i++) {
    switch (sqlite3_column_type(stmt, i)) {
      case SQLITE_INTEGER:
        lua_pushinteger(L, (lua_Integer)sqlite3_column_int64(stmt, i));
        break;
      case SQLITE_FLOAT:
        lua_pushnumber(L, (lua_Number)sqlite3_column_double(stmt, i));
        break;
      case SQLITE_TEXT:
        lua_pushlstring(L, (const char *)sqlite3_column_text(stmt, i),
                        (size_t)sqlite3_column_bytes(stmt, i));
        break;
      case SQLITE_BLOB: {
        size_t len = (size_t)sqlite3_column_bytes(stmt, i);
        const void *data = sqlite3_column_blob(stmt, i);
        Vector *v = luaV_newvec(L, len, 1);
        if (len > 0) /* no allocation between the vector's creation and here */
          memcpy(v->data, data, len);
        setvecvalue(L, s2v(L->top.p), v);
        L->top.p++;
        break;
      }
      default: /* SQLITE_NULL: the key is simply absent */
        continue;
    }
    lua_setfield(L, -2, sqlite3_column_name(stmt, i));
  }
}

static int query_iter(lua_State *L) {
  LSqliteCursor *cur =
      (LSqliteCursor *)lua_touserdata(L, lua_upvalueindex(1));
  LSqliteStmt *s = cur->stmt;
  int rc;
  if (s == NULL) { /* spent cursor keeps returning nil */
    lua_pushnil(L);
    return 1;
  }
  if (s->stmt == NULL)
    return luaL_error(L, "attempt to use a closed statement");
  if (s->db->db == NULL)
    return luaL_error(L, "attempt to use a closed database");
  if (cur->generation != s->generation)
    return luaL_error(L, "statement was reset during iteration");
  rc = sqlite3_step(s->stmt);
  if (rc == SQLITE_ROW) {
    push_row(L, s);
    return 1;
  }
  cur->stmt = NULL;
  if (rc == SQLITE_DONE) {
    if (cur->owns)
      finalize_stmt(s);
    else
      sqlite3_reset(s->stmt);
    lua_pushnil(L);
    return 1;
  }
  lua_pushfstring(L, "%s", sqlite3_errmsg(s->db->db));
  if (cur->owns)
    finalize_stmt(s);
  else
    sqlite3_reset(s->stmt);
  return lua_error(L);
}

/*
** Build the iteration quadruple (iter, nil, nil, cursor) over the
** statement userdata at 'stmtidx'. The cursor doubles as the generic
** for's closing value, so early exits release the statement.
*/
static int make_query(lua_State *L, int stmtidx, int owns) {
  LSqliteStmt *s;
  LSqliteCursor *cur;
  stmtidx = lua_absindex(L, stmtidx);
  s = (LSqliteStmt *)lua_touserdata(L, stmtidx);
  cur = (LSqliteCursor *)lua_newuserdatauv(L, sizeof(LSqliteCursor), 1);
  cur->stmt = NULL;
  cur->generation = 0;
  cur->owns = owns;
  luaL_setmetatable(L, SQLITE_CURSOR_METATABLE);
  lua_pushvalue(L, stmtidx);
  lua_setiuservalue(L, -2, 1);
  cur->stmt = s;
  cur->generation = s->generation;
  lua_pushvalue(L, -1);
  lua_pushcclosure(L, query_iter, 1);
  lua_pushnil(L);
  lua_pushnil(L);
  lua_pushvalue(L, -4);
  return 4;
}

/*
** Close a cursor: finalize (db:query) or reset (stmt:query) the
** underlying statement, unless it was already finalized or reused.
** Tolerant by design, since this backs __close and __gc.
*/
static int cursor_close(lua_State *L) {
  LSqliteCursor *cur =
      (LSqliteCursor *)luaL_checkudata(L, 1, SQLITE_CURSOR_METATABLE);
  LSqliteStmt *s = cur->stmt;
  if (s != NULL) {
    cur->stmt = NULL;
    if (s->stmt != NULL && cur->generation == s->generation) {
      if (cur->owns)
        finalize_stmt(s);
      else
        sqlite3_reset(s->stmt);
    }
  }
  return 0;
}

/* ===================================================================
** Database methods
** =================================================================== */

static int db_exec(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  const char *sql = checkstring_strict(L, 2);
  char *errmsg = NULL;
  if (sqlite3_exec(d->db, sql, NULL, NULL, &errmsg) != SQLITE_OK) {
    lua_pushstring(L, errmsg != NULL ? errmsg : sqlite3_errmsg(d->db));
    sqlite3_free(errmsg);
    return lua_error(L);
  }
  return 0;
}

static int db_run(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  const char *sql = checkstring_strict(L, 2);
  int lastarg = lua_gettop(L);
  LSqliteStmt *s = prepare_single(L, d, sql, 1);
  bind_values(L, s, 3, lastarg);
  run_to_completion(L, s);
  finalize_stmt(s);
  lua_pushinteger(L, (lua_Integer)sqlite3_changes64(d->db));
  lua_pushinteger(L, (lua_Integer)sqlite3_last_insert_rowid(d->db));
  return 2;
}

static int db_query(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  const char *sql = checkstring_strict(L, 2);
  int lastarg = lua_gettop(L);
  LSqliteStmt *s = prepare_single(L, d, sql, 1);
  bind_values(L, s, 3, lastarg);
  return make_query(L, lua_gettop(L), 1);
}

static int db_prepare(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  const char *sql = checkstring_strict(L, 2);
  prepare_single(L, d, sql, 1);
  return 1;
}

static int db_transaction(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  char *errmsg = NULL;
  int status;
  luaL_checktype(L, 2, LUA_TFUNCTION);
  lua_settop(L, 2);
  if (sqlite3_exec(d->db, "BEGIN", NULL, NULL, &errmsg) != SQLITE_OK) {
    lua_pushstring(L, errmsg != NULL ? errmsg : sqlite3_errmsg(d->db));
    sqlite3_free(errmsg);
    return lua_error(L);
  }
  lua_pushvalue(L, 2);
  status = lua_pcall(L, 0, LUA_MULTRET, 0);
  if (d->db == NULL)
    return luaL_error(L, "database closed during transaction");
  if (status == LUA_OK) {
    if (sqlite3_exec(d->db, "COMMIT", NULL, NULL, &errmsg) != SQLITE_OK) {
      lua_pushstring(L, errmsg != NULL ? errmsg : sqlite3_errmsg(d->db));
      sqlite3_free(errmsg);
      sqlite3_exec(d->db, "ROLLBACK", NULL, NULL, NULL);
      return lua_error(L);
    }
    return lua_gettop(L) - 2; /* everything fn returned */
  }
  else {
    sqlite3_exec(d->db, "ROLLBACK", NULL, NULL, NULL);
    return lua_error(L); /* rethrow fn's error value, already on top */
  }
}

/* ===================================================================
** Statement methods
** =================================================================== */

/* Reset for re-execution, invalidating any live iterator */
static void stmt_rearm(LSqliteStmt *s) {
  sqlite3_reset(s->stmt);
  sqlite3_clear_bindings(s->stmt);
  s->generation++;
}

static int stmt_run(lua_State *L) {
  LSqliteStmt *s = checkstmt(L);
  stmt_rearm(s);
  bind_values(L, s, 2, lua_gettop(L));
  run_to_completion(L, s);
  sqlite3_reset(s->stmt);
  lua_pushinteger(L, (lua_Integer)sqlite3_changes64(s->db->db));
  lua_pushinteger(L, (lua_Integer)sqlite3_last_insert_rowid(s->db->db));
  return 2;
}

static int stmt_query(lua_State *L) {
  LSqliteStmt *s = checkstmt(L);
  stmt_rearm(s);
  bind_values(L, s, 2, lua_gettop(L));
  return make_query(L, 1, 0);
}

static int stmt_close(lua_State *L) {
  LSqliteStmt *s = checkstmt(L);
  finalize_stmt(s);
  lua_pushboolean(L, 1);
  return 1;
}

/* Tolerant variant bound to both __gc and __close */
static int stmt_gc(lua_State *L) {
  LSqliteStmt *s = (LSqliteStmt *)luaL_checkudata(L, 1, SQLITE_STMT_METATABLE);
  finalize_stmt(s);
  return 0;
}

static int stmt_tostring(lua_State *L) {
  LSqliteStmt *s = (LSqliteStmt *)luaL_checkudata(L, 1, SQLITE_STMT_METATABLE);
  if (s->stmt == NULL)
    lua_pushliteral(L, "statement (closed)");
  else
    lua_pushfstring(L, "statement (%p)", (void *)s->stmt);
  return 1;
}

/* ===================================================================
** Registration
** =================================================================== */

LUA_API void *lus_tosqlite(lua_State *L, int idx) {
  LSqliteDB *d = (LSqliteDB *)luaL_testudata(L, idx, SQLITE_DB_METATABLE);
  return d != NULL ? (void *)d->db : NULL;
}

static const luaL_Reg db_meth[] = {{"exec", db_exec},
                                   {"run", db_run},
                                   {"query", db_query},
                                   {"prepare", db_prepare},
                                   {"transaction", db_transaction},
                                   {"close", db_close},
                                   {NULL, NULL}};

static const luaL_Reg db_metameth[] = {{"__gc", db_gc},
                                       {"__close", db_gc},
                                       {"__tostring", db_tostring},
                                       {NULL, NULL}};

static const luaL_Reg stmt_meth[] = {{"run", stmt_run},
                                     {"query", stmt_query},
                                     {"close", stmt_close},
                                     {NULL, NULL}};

static const luaL_Reg stmt_metameth[] = {{"__gc", stmt_gc},
                                         {"__close", stmt_gc},
                                         {"__tostring", stmt_tostring},
                                         {NULL, NULL}};

static const luaL_Reg cursor_metameth[] = {{"__gc", cursor_close},
                                           {"__close", cursor_close},
                                           {NULL, NULL}};

static void make_meta(lua_State *L, const char *name, const luaL_Reg *methods,
                      const luaL_Reg *meta) {
  luaL_newmetatable(L, name);
  luaL_setfuncs(L, meta, 0);
  if (methods != NULL) {
    lua_newtable(L);
    luaL_setfuncs(L, methods, 0);
    lua_setfield(L, -2, "__index");
  }
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable"); /* hide the metatable */
  lua_pop(L, 1);
}

/*
** Called from luaopen_io with the io table on the stack top. SQLite has
** a single entry point, so it lives alongside io.open instead of owning
** a module table of its own.
*/
void lus_sqlite_register(lua_State *L) {
  if (sqlite3_initialize() != SQLITE_OK) /* required by SQLITE_OMIT_AUTOINIT */
    luaL_error(L, "cannot initialize sqlite");
  make_meta(L, SQLITE_DB_METATABLE, db_meth, db_metameth);
  make_meta(L, SQLITE_STMT_METATABLE, stmt_meth, stmt_metameth);
  make_meta(L, SQLITE_CURSOR_METATABLE, NULL, cursor_metameth);
  lua_pushcfunction(L, io_sqlite);
  lua_setfield(L, -2, "sqlite");
}
