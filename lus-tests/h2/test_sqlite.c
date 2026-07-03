/*
** H2: lus_tosqlite and embedding behavior of the SQLite binding.
**
** Verifies that lus_tosqlite hands back the live sqlite3 connection
** (proven by writing through it directly and reading the row back from
** the Lus side), returns NULL for every non-database value including
** the nearest-miss statement userdata, respects closed handles, that
** pledge gating applies to io.sqlite from an embedded state, and that
** lua_close with live handles shuts down cleanly.
*/

#include <stdio.h>
#include <string.h>

#include "sqlite3.h"

#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"

static int fail(const char *what, const char *detail) {
    fprintf(stderr, "FAIL: %s%s%s\n", what, detail ? ": " : "",
            detail ? detail : "");
    return 1;
}

int main(void) {
    printf("Running H2: test_sqlite\n");

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* 1: open a database and seed it from the Lus side */
    if (luaL_dostring(L,
            "db = io.sqlite(':memory:')\n"
            "db:exec('CREATE TABLE t (n INTEGER)')\n"
            "db:run('INSERT INTO t VALUES (?)', 1)\n"
            "return db") != LUA_OK)
        return fail("setup", lua_tostring(L, -1));

    /* 2: lus_tosqlite returns the live connection */
    sqlite3 *conn = (sqlite3 *)lus_tosqlite(L, -1);
    if (conn == NULL)
        return fail("lus_tosqlite returned NULL for an open db", NULL);
    if (sqlite3_exec(conn, "INSERT INTO t VALUES (2)", NULL, NULL, NULL) !=
        SQLITE_OK)
        return fail("direct sqlite3_exec on the returned connection",
                    sqlite3_errmsg(conn));
    if (luaL_dostring(L,
            "local n\n"
            "for row in db:query('SELECT count(*) AS n FROM t') do\n"
            "    n = row.n\n"
            "end\n"
            "assert(n == 2, 'the C-side insert is visible')") != LUA_OK)
        return fail("C-side insert visibility", lua_tostring(L, -1));

    /* 3: NULL for non-database values, including the nearest misses */
    lua_pushinteger(L, 42);
    if (lus_tosqlite(L, -1) != NULL)
        return fail("lus_tosqlite on a number", NULL);
    lua_pop(L, 1);
    lua_pushstring(L, "db");
    if (lus_tosqlite(L, -1) != NULL)
        return fail("lus_tosqlite on a string", NULL);
    lua_pop(L, 1);
    lua_getglobal(L, "io");
    lua_getfield(L, -1, "stdout");
    if (lus_tosqlite(L, -1) != NULL)
        return fail("lus_tosqlite on a file userdata", NULL);
    lua_pop(L, 2);
    if (luaL_dostring(L, "return db:prepare('SELECT 1')") != LUA_OK)
        return fail("prepare", lua_tostring(L, -1));
    if (lus_tosqlite(L, -1) != NULL)
        return fail("lus_tosqlite on a statement userdata", NULL);
    lua_pop(L, 1);

    /* 4: NULL after close */
    if (luaL_dostring(L, "db:close()\nreturn db") != LUA_OK)
        return fail("close", lua_tostring(L, -1));
    if (lus_tosqlite(L, -1) != NULL)
        return fail("lus_tosqlite on a closed db", NULL);
    lua_settop(L, 0);

    /* 5: pledge gating applies to embedded states too */
    if (luaL_dostring(L, "return catch io.sqlite('./h2_denied.db')") == LUA_OK) {
        int ok = lua_toboolean(L, 1);
        if (ok)
            return fail("unpledged file open succeeded", NULL);
    }
    else {
        return fail("pledge probe errored", lua_tostring(L, -1));
    }
    lua_settop(L, 0);
    if (luaL_dostring(L,
            "pledge('fs:read=./h2_sqlite_*',"
            "       'fs:write=./h2_sqlite_*')\n"
            "local db <close> = io.sqlite('./h2_sqlite_ok.db')\n"
            "db:exec('CREATE TABLE t (n INTEGER)')\n"
            "db:run('INSERT INTO t VALUES (1)')") != LUA_OK)
        return fail("pledged file open", lua_tostring(L, -1));
    remove("./h2_sqlite_ok.db");
    remove("./h2_sqlite_ok.db-wal");
    remove("./h2_sqlite_ok.db-shm");
    remove("./h2_sqlite_ok.db-journal");

    /* 6: lua_close with an open db and an open statement is clean */
    if (luaL_dostring(L,
            "leak_db = io.sqlite(':memory:')\n"
            "leak_db:exec('CREATE TABLE t (n INTEGER)')\n"
            "leak_stmt = leak_db:prepare('SELECT * FROM t')") != LUA_OK)
        return fail("leak setup", lua_tostring(L, -1));
    lua_close(L); /* the sanitizer job turns UAF here into a hard failure */

    printf("sqlite test passed\n");
    return 0;
}
