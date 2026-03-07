/*
** lcsvlib.c
** CSV library (tocsv, fromcsv)
*/

#define lcsvlib_c
#define LUA_LIB

#include "lprefix.h"

#include <string.h>

#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"


/* ===== Parser (fromcsv) ===== */


typedef struct {
  lua_State *L;
  const char *csv;   /* current position */
  const char *start; /* start of input (for error reporting) */
  const char *end;   /* end of input */
  char delim;        /* field delimiter */
} CsvParser;


static void csv_error(CsvParser *p, const char *msg) {
  long pos = (long)(p->csv - p->start) + 1;
  lua_pushfstring(p->L, "CSV parse error at position %d: %s", (int)pos, msg);
  lua_error(p->L);
}


/*
** Parse a quoted field (RFC 4180).
** Entry: p->csv points at the opening '"'.
** Exit: pushes the unescaped field string; p->csv points after the closing '"'.
*/
static void parse_quoted_field(CsvParser *p) {
  luaL_Buffer b;
  luaL_buffinit(p->L, &b);
  p->csv++; /* skip opening quote */
  while (p->csv < p->end) {
    if (*p->csv == '"') {
      p->csv++;
      if (p->csv < p->end && *p->csv == '"') {
        /* escaped quote */
        luaL_addchar(&b, '"');
        p->csv++;
      }
      else {
        /* end of quoted field */
        luaL_pushresult(&b);
        return;
      }
    }
    else {
      luaL_addchar(&b, *p->csv);
      p->csv++;
    }
  }
  csv_error(p, "unterminated quoted field");
}


/*
** Parse an unquoted field.
** Scans until delimiter, '\n', '\r', or end of input.
*/
static void parse_unquoted_field(CsvParser *p) {
  const char *fieldstart = p->csv;
  while (p->csv < p->end && *p->csv != p->delim &&
         *p->csv != '\n' && *p->csv != '\r') {
    p->csv++;
  }
  lua_pushlstring(p->L, fieldstart, (size_t)(p->csv - fieldstart));
}


/*
** Parse a single row and push it as a table at the given result index.
** Returns 1 if more rows follow, 0 if at end.
*/
static int parse_row(CsvParser *p, int result_idx, lua_Integer rownum) {
  lua_State *L = p->L;
  lua_Integer fieldnum = 1;
  lua_newtable(L);
  int row_idx = lua_gettop(L);
  for (;;) {
    /* parse one field */
    if (p->csv < p->end && *p->csv == '"')
      parse_quoted_field(p);
    else
      parse_unquoted_field(p);
    /* field string is now on top of stack; store in row table */
    lua_rawseti(L, row_idx, fieldnum++);
    /* check what follows */
    if (p->csv >= p->end)
      break;
    if (*p->csv == p->delim) {
      p->csv++; /* consume delimiter, continue to next field */
      continue;
    }
    /* must be line ending */
    if (*p->csv == '\r')
      p->csv++;
    if (p->csv < p->end && *p->csv == '\n')
      p->csv++;
    break;
  }
  /* store row in result table */
  lua_rawseti(L, result_idx, rownum);
  return (p->csv < p->end);
}


static int csv_fromcsv(lua_State *L) {
  size_t len;
  const char *input = luaL_checklstring(L, 1, &len);
  int use_headers = lua_toboolean(L, 2);
  char delim = ',';

  if (!lua_isnoneornil(L, 3)) {
    size_t dlen;
    const char *ds = luaL_checklstring(L, 3, &dlen);
    if (dlen != 1)
      return luaL_argerror(L, 3, "delimiter must be a single character");
    delim = ds[0];
  }

  CsvParser p;
  p.L = L;
  p.csv = input;
  p.start = input;
  p.end = input + len;
  p.delim = delim;

  /* result table (array of rows) */
  lua_newtable(L);
  int result_idx = lua_gettop(L);
  lua_Integer rownum = 1;

  /* parse all rows */
  if (len > 0) {
    while (parse_row(&p, result_idx, rownum))
      rownum++;
    rownum++; /* count includes the last row */
  }

  if (!use_headers)
    return 1; /* result table is on top */

  /* headers mode: first row becomes keys for subsequent rows */
  lua_Integer nrows = luaL_len(L, result_idx);
  if (nrows == 0)
    return 1;

  /* get header row */
  lua_geti(L, result_idx, 1);
  int header_idx = lua_gettop(L);
  lua_Integer ncols = luaL_len(L, header_idx);

  /* build new result table */
  lua_newtable(L);
  int new_result_idx = lua_gettop(L);

  for (lua_Integer i = 2; i <= nrows; i++) {
    lua_geti(L, result_idx, i); /* push data row */
    int datarow_idx = lua_gettop(L);
    lua_newtable(L); /* new keyed row */
    int keyed_idx = lua_gettop(L);
    for (lua_Integer j = 1; j <= ncols; j++) {
      lua_geti(L, header_idx, j);  /* push header name */
      lua_geti(L, datarow_idx, j); /* push field value */
      lua_settable(L, keyed_idx);  /* keyed[header] = value */
    }
    lua_rawseti(L, new_result_idx, i - 1); /* store keyed row */
    lua_pop(L, 1); /* pop data row */
  }

  return 1; /* new_result_idx is on top */
}


/* ===== Writer (tocsv) ===== */


/*
** Check whether a field string needs quoting.
** Returns 1 if it contains the delimiter, '"', '\n', or '\r'.
*/
static int needs_quoting(const char *s, size_t len, char delim) {
  for (size_t i = 0; i < len; i++) {
    if (s[i] == delim || s[i] == '"' || s[i] == '\n' || s[i] == '\r')
      return 1;
  }
  return 0;
}


/*
** Push a field string onto the stack, quoting if necessary.
** Uses luaL_Buffer locally (no interleaved stack operations).
*/
static void push_field(lua_State *L, const char *s, size_t len, char delim) {
  if (needs_quoting(s, len, delim)) {
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    luaL_addchar(&b, '"');
    for (size_t i = 0; i < len; i++) {
      if (s[i] == '"')
        luaL_addchar(&b, '"'); /* double the quote */
      luaL_addchar(&b, s[i]);
    }
    luaL_addchar(&b, '"');
    luaL_pushresult(&b);
  }
  else {
    lua_pushlstring(L, s, len);
  }
}


/*
** Append a string to the parts table.
*/
static void parts_add(lua_State *L, int parts_idx) {
  lua_rawseti(L, parts_idx, (lua_Integer)luaL_len(L, parts_idx) + 1);
}


static int csv_tocsv(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  char delim = ',';
  char delim_str[2] = {',', '\0'};

  if (!lua_isnoneornil(L, 2)) {
    size_t dlen;
    const char *ds = luaL_checklstring(L, 2, &dlen);
    if (dlen != 1)
      return luaL_argerror(L, 2, "delimiter must be a single character");
    delim = ds[0];
    delim_str[0] = delim;
  }

  /* parts table to collect string pieces */
  lua_newtable(L);
  int parts_idx = lua_gettop(L);

  lua_Integer nrows = luaL_len(L, 1);
  for (lua_Integer i = 1; i <= nrows; i++) {
    lua_geti(L, 1, i); /* push row */
    int row_idx = lua_gettop(L);
    if (!lua_istable(L, row_idx)) {
      return luaL_error(L, "row %d is not a table", (int)i);
    }
    lua_Integer ncols = luaL_len(L, row_idx);
    for (lua_Integer j = 1; j <= ncols; j++) {
      if (j > 1) {
        lua_pushlstring(L, delim_str, 1);
        parts_add(L, parts_idx);
      }
      lua_geti(L, row_idx, j);
      if (lua_isnil(L, -1)) {
        /* nil → empty field */
        lua_pop(L, 1);
      }
      else {
        size_t flen;
        luaL_tolstring(L, -1, &flen); /* stack: orig strep */
        lua_remove(L, -2);            /* stack: strep (remove orig) */
        /* strep is now on top; get pointer from it */
        const char *field = lua_tolstring(L, -1, &flen);
        push_field(L, field, flen, delim); /* stack: strep quoted */
        lua_remove(L, -2);                /* stack: quoted */
        parts_add(L, parts_idx);
      }
    }
    lua_pushliteral(L, "\n");
    parts_add(L, parts_idx);
    lua_pop(L, 1); /* pop row table */
  }

  /* concatenate all parts */
  lua_getglobal(L, "table");
  lua_getfield(L, -1, "concat");
  lua_pushvalue(L, parts_idx);
  lua_call(L, 1, 1);
  return 1;
}


/* ===== Registration ===== */


static const luaL_Reg csv_funcs[] = {
    {"tocsv", csv_tocsv},
    {"fromcsv", csv_fromcsv},
    {NULL, NULL}
};


LUAMOD_API int luaopen_csv(lua_State *L) {
  /* Register functions in the global table */
  lua_pushglobaltable(L);
  luaL_setfuncs(L, csv_funcs, 0);
  lua_pop(L, 1);
  return 0;
}
