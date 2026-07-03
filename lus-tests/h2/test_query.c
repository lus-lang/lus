/*
** H2: the query C API. Verifies lus_toquery and lus_isquery, the
** source and clause visitors, node walking down to captured values,
** native provider registration with real push-down (accepted conjuncts
** never run in memory), and a bytecode round trip through lua_dump.
*/

#include <stdio.h>
#include <string.h>

#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"

static int failures = 0;

#define CHECK(cond, what)                                                    \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL: %s\n", what);                             \
            failures++;                                                      \
        }                                                                    \
    } while (0)

/* ------------------------------------------------------------------ */
/* a canned native provider: three rows, counting accept/open calls   */

static int accepts_offered = 0;
static int open_called = 0;
static int open_npushed = -1;

static int canned_accepts(lua_State *L, const lus_Query *q,
                          const lus_QueryNode *n) {
    (void)L;
    (void)q;
    accepts_offered++;
    /* accept only comparisons */
    return lus_qnodekind(n) == LUS_QN_CMP;
}

static int canned_iter(lua_State *L) {
    lua_Integer i = lua_tointeger(L, lua_upvalueindex(1)) + 1;
    lua_pushinteger(L, i);
    lua_replace(L, lua_upvalueindex(1));
    if (i > 3) {
        lua_pushnil(L);
        return 1;
    }
    lua_createtable(L, 0, 1);
    lua_pushinteger(L, i * 10);
    lua_setfield(L, -2, "v");
    return 1;
}

static void canned_open(lua_State *L, const lus_Query *q, int srcindex,
                        const lus_QueryNode *const *pushed, int npushed) {
    (void)q;
    (void)pushed;
    open_called = srcindex;
    open_npushed = npushed;
    lua_pushinteger(L, 0);
    lua_pushcclosure(L, canned_iter, 1);
}

static const lus_QueryProvider canned_provider = {canned_accepts,
                                                  canned_open};

int main(void) {
    lua_State *L = luaL_newstate();
    size_t len;
    const char *s;
    lus_Query *q;
    const lus_QueryNode *node;
    printf("Running H2: test_query\n");
    luaL_openlibs(L);

    /* build a query with a where, a select, and an order clause */
    if (luaL_dostring(L,
            "t = { { age = 20, name = 'a' }, { age = 10, name = 'b' } }\n"
            "lim = 15\n"
            "return @t as p where p.age > lim select p.name, p.age as years "
            "order by p.age desc") != LUA_OK) {
        fprintf(stderr, "setup: %s\n", lua_tostring(L, -1));
        return 1;
    }

    /* 1: type checks */
    CHECK(lua_type(L, -1) == LUA_TQUERY, "lua_type is LUA_TQUERY");
    CHECK(lus_isquery(L, -1), "lus_isquery");
    CHECK(strcmp(lua_typename(L, LUA_TQUERY), "query") == 0,
          "lua_typename(LUA_TQUERY)");
    q = lus_toquery(L, -1);
    CHECK(q != NULL, "lus_toquery on a query");
    lua_pushinteger(L, 42);
    CHECK(lus_toquery(L, -1) == NULL, "lus_toquery on a number");
    lua_pushstring(L, "q");
    CHECK(lus_toquery(L, -1) == NULL, "lus_toquery on a string");
    lua_pop(L, 2);

    /* 2: sources */
    CHECK(lus_querysourcecount(q) == 1, "one source");
    s = lus_querysourcealias(q, 0, &len);
    CHECK(s != NULL && len == 1 && s[0] == 'p', "alias is 'p'");
    lus_querysource(L, q, 0);
    lua_getglobal(L, "t");
    CHECK(lua_rawequal(L, -1, -2), "lus_querysource pushes the table");
    lua_pop(L, 2);

    /* 3: the where clause is a > comparison of a column and a param */
    CHECK(lus_queryclausecount(q, LUS_QWHERE) == 1, "one where root");
    node = lus_queryclause(q, LUS_QWHERE, 0);
    CHECK(node != NULL, "where root exists");
    CHECK(lus_qnodekind(node) == LUS_QN_CMP, "where root is a comparison");
    CHECK(lus_qnodeop(node) == LUS_QCMP_GT, "the comparison is >");
    {
        const lus_QueryNode *col = lus_qnodechild(q, node, 0);
        const lus_QueryNode *param = lus_qnodechild(q, node, 1);
        CHECK(col != NULL && lus_qnodekind(col) == LUS_QN_COLUMN,
              "child 0 is a column");
        s = lus_qnodename(q, col, &len);
        CHECK(s != NULL && len == 3 && memcmp(s, "age", 3) == 0,
              "the column is 'age'");
        CHECK(lus_qnodeop(col) == 0, "the column belongs to source 0");
        CHECK(param != NULL && lus_qnodekind(param) == LUS_QN_PARAM,
              "child 1 is a bound parameter");
        lus_qnodevalue(L, q, param);
        CHECK(lua_tointeger(L, -1) == 15, "the captured value is 15");
        lua_pop(L, 1);
        CHECK(lus_qnodechild(q, node, 2) == NULL, "no third child");
    }

    /* 4: select items and their names */
    CHECK(lus_queryclausecount(q, LUS_QSELECT) == 2, "two select items");
    s = lus_queryselectname(q, 0, &len);
    CHECK(s != NULL && len == 4 && memcmp(s, "name", 4) == 0,
          "item 0 auto-names from the column");
    s = lus_queryselectname(q, 1, &len);
    CHECK(s != NULL && len == 5 && memcmp(s, "years", 5) == 0,
          "item 1 carries its 'as' name");
    CHECK(!lus_querydistinct(q), "not distinct");

    /* 5: order clause */
    CHECK(lus_queryclausecount(q, LUS_QORDER) == 1, "one order item");
    CHECK(lus_queryorderdesc(q, 0) == 1, "the order is descending");
    CHECK(lus_queryclause(q, LUS_QGROUP, 0) == NULL, "no group clause");
    CHECK(lus_queryclausecount(q, LUS_QLIMIT) == 0, "no limit");
    lua_settop(L, 0);

    /* 6: a native provider with real push-down */
    lua_newtable(L); /* the source userdata's stand-in table */
    lua_newtable(L); /* its metatable */
    lus_setqueryprovider(L, -1, &canned_provider);
    lua_setmetatable(L, -2);
    lua_setglobal(L, "src");
    if (luaL_dostring(L,
            "local probe_calls = 0\n"
            "local function probe(r)\n"
            "    probe_calls = probe_calls + 1\n"
            "    return r.v < 25\n"
            "end\n"
            "local out = {}\n"
            "for r in query(@src as s where s.v > 5 and probe(s) "
            "select s.v) do\n"
            "    out[#out + 1] = r.v\n"
            "end\n"
            "return #out, out[1], probe_calls") != LUA_OK) {
        fprintf(stderr, "provider run: %s\n", lua_tostring(L, -1));
        return 1;
    }
    CHECK(lua_tointeger(L, -3) == 2, "two rows pass probe");
    CHECK(lua_tointeger(L, -2) == 10, "the first row is v=10");
    CHECK(lua_tointeger(L, -1) == 3, "probe ran once per fetched row");
    CHECK(open_called == 1, "open received the 1-based source index");
    CHECK(open_npushed == 1, "the comparison conjunct was pushed");
    CHECK(accepts_offered >= 1, "accepts was consulted");
    lua_settop(L, 0);

    /* 7: bytecode round trip through lua_dump/load from C */
    if (luaL_dostring(L,
            "pledge('load')\n"
            "local t = { { v = 1 }, { v = 2 } }\n"
            "local f = function(src)\n"
            "    return @src as r where r.v > 1 select r.v\n"
            "end\n"
            "local d = string.dump(f)\n"
            "local g = load(d, 'd', 'b')\n"
            "local rows = 0\n"
            "for _ in query(g(t)) do rows = rows + 1 end\n"
            "return rows") != LUA_OK) {
        fprintf(stderr, "dump round trip: %s\n", lua_tostring(L, -1));
        return 1;
    }
    CHECK(lua_tointeger(L, -1) == 1, "the loaded query still runs");
    lua_settop(L, 0);

    /* 8: GC with a registry-anchored query keeps the walkers valid */
    if (luaL_dostring(L, "return @({{a=1}}) as x where x.a == 1 select x.a") !=
        LUA_OK) {
        fprintf(stderr, "gc setup: %s\n", lua_tostring(L, -1));
        return 1;
    }
    q = lus_toquery(L, -1);
    lua_setfield(L, LUA_REGISTRYINDEX, "h2query");
    lua_gc(L, LUA_GCCOLLECT);
    lua_gc(L, LUA_GCCOLLECT);
    node = lus_queryclause(q, LUS_QWHERE, 0);
    CHECK(node != NULL && lus_qnodekind(node) == LUS_QN_CMP,
          "the plan survives collection");
    CHECK(lus_queryclausecount(q, LUS_QSELECT) == 1, "select intact");

    lua_close(L);
    if (failures > 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("query test passed\n");
    return 0;
}
