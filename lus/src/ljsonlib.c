/*
** ljsonlib.c
** JSON library for Lus
** Implements tojson() and fromjson() global functions
*/

#define ljsonlib_c
#define LUA_LIB

#include <ctype.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"

#include "lauxlib.h"
#include "lgc.h"
#include "llimits.h"
#include "lobject.h"
#include "lstate.h"
#include "lstring.h"
#include "ltable.h"

/* Maximum depth for nested structures (memory limit) */
#define JSON_MAX_DEPTH 1000

/* ============================================================
** JSON Parser (fromjson) - Iterative State Machine
** ============================================================ */

typedef struct {
  lua_State *L;
  const char *json;  /* current position in JSON string */
  const char *start; /* start of JSON string (for error reporting) */
  const char *end;   /* end of JSON string */
} JsonParser;

static void json_error(JsonParser *p, const char *msg) {
  long pos = (long)(p->json - p->start) + 1;
  lua_pushfstring(p->L, "JSON parse error at position %d: %s", (int)pos, msg);
  lua_error(p->L);
}

static void skip_whitespace(JsonParser *p) {
  while (p->json < p->end) {
    char c = *p->json;
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
      p->json++;
    else
      break;
  }
}

static int peek(JsonParser *p) {
  skip_whitespace(p);
  if (p->json >= p->end)
    return -1;
  return (unsigned char)*p->json;
}

static int accept(JsonParser *p, char c) {
  skip_whitespace(p);
  if (p->json < p->end && *p->json == c) {
    p->json++;
    return 1;
  }
  return 0;
}

static void expect(JsonParser *p, char c, const char *context) {
  if (!accept(p, c)) {
    char msg[64];
    snprintf(msg, sizeof(msg), "expected '%c' %s", c, context);
    json_error(p, msg);
  }
}

static void parse_literal(JsonParser *p, const char *lit, int len) {
  if (p->json + len > p->end || memcmp(p->json, lit, (size_t)len) != 0) {
    char msg[32];
    snprintf(msg, sizeof(msg), "expected '%s'", lit);
    json_error(p, msg);
  }
  p->json += len;
}

/* Container frame for iterative parsing with direct object manipulation */
typedef struct {
  Table *table;    /* Container table (direct pointer) */
  int is_array;    /* 1 = array, 0 = object */
  lua_Integer idx; /* For arrays: next index */
  TString *key;    /* For objects: current key (NULL if none) */
} ContainerFrame;

/* Parse JSON value iteratively using direct object manipulation */
static void parse_value_iterative(JsonParser *p) {
  lua_State *L = p->L;

  /* Use malloc for container stack to avoid Lua stack entirely */
  size_t stack_cap = 32;
  ContainerFrame *stack = luaM_newvector(L, stack_cap, ContainerFrame);
  size_t stack_size = 0;
  int depth = 0;

  /* Current parsed value */
  TValue value;
  setnilvalue(&value);

  /* Main parsing loop */
  for (;;) {
    int c = peek(p);

    /* Parse a value into 'value' */
    switch (c) {
    case '"': {
      /* Parse string directly */
      size_t capacity = 256;
      size_t len = 0;
      char *buf = luaM_newvector(L, capacity, char);

      p->json++; /* skip opening quote */
      while (p->json < p->end && *p->json != '"') {
        /* Ensure capacity */
        if (len + 8 > capacity) {
          size_t newcap = capacity * 2;
          buf = luaM_reallocvector(L, buf, capacity, newcap, char);
          capacity = newcap;
        }

        if ((unsigned char)*p->json < 0x20) {
          luaM_freearray(L, buf, capacity);
          luaM_freearray(L, stack, stack_cap);
          json_error(p, "control character in string");
        }

        if (*p->json == '\\') {
          p->json++;
          if (p->json >= p->end) {
            luaM_freearray(L, buf, capacity);
            luaM_freearray(L, stack, stack_cap);
            json_error(p, "unexpected end after backslash");
          }
          switch (*p->json) {
          case '"':
            buf[len++] = '"';
            break;
          case '\\':
            buf[len++] = '\\';
            break;
          case '/':
            buf[len++] = '/';
            break;
          case 'b':
            buf[len++] = '\b';
            break;
          case 'f':
            buf[len++] = '\f';
            break;
          case 'n':
            buf[len++] = '\n';
            break;
          case 'r':
            buf[len++] = '\r';
            break;
          case 't':
            buf[len++] = '\t';
            break;
          case 'u': {
            unsigned int codepoint = 0;
            p->json++;
            for (int i = 0; i < 4; i++) {
              if (p->json >= p->end) {
                luaM_freearray(L, buf, capacity);
                luaM_freearray(L, stack, stack_cap);
                json_error(p, "incomplete \\uXXXX escape");
              }
              char uc = *p->json;
              codepoint <<= 4;
              if (uc >= '0' && uc <= '9')
                codepoint |= (unsigned)(uc - '0');
              else if (uc >= 'a' && uc <= 'f')
                codepoint |= (unsigned)(uc - 'a' + 10);
              else if (uc >= 'A' && uc <= 'F')
                codepoint |= (unsigned)(uc - 'A' + 10);
              else {
                luaM_freearray(L, buf, capacity);
                luaM_freearray(L, stack, stack_cap);
                json_error(p, "invalid hex digit");
              }
              p->json++;
            }
            p->json--; /* will be incremented at end */

            /* Handle surrogate pairs */
            if (codepoint >= 0xD800 && codepoint <= 0xDBFF) {
              if (p->json + 1 < p->end && p->json[1] == '\\' &&
                  p->json + 2 < p->end && p->json[2] == 'u') {
                unsigned int low = 0;
                p->json += 3;
                for (int i = 0; i < 4; i++) {
                  if (p->json >= p->end)
                    break;
                  char lc = *p->json;
                  low <<= 4;
                  if (lc >= '0' && lc <= '9')
                    low |= (unsigned)(lc - '0');
                  else if (lc >= 'a' && lc <= 'f')
                    low |= (unsigned)(lc - 'a' + 10);
                  else if (lc >= 'A' && lc <= 'F')
                    low |= (unsigned)(lc - 'A' + 10);
                  p->json++;
                }
                p->json--;
                if (low >= 0xDC00 && low <= 0xDFFF) {
                  codepoint =
                      0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
                }
              }
            }

            /* Encode as UTF-8 */
            char utf8buf[UTF8BUFFSZ];
            int utf8len = luaO_utf8esc(utf8buf, codepoint);
            if (len + (size_t)utf8len > capacity) {
              size_t newcap = capacity * 2;
              buf = luaM_reallocvector(L, buf, capacity, newcap, char);
              capacity = newcap;
            }
            memcpy(buf + len, utf8buf + UTF8BUFFSZ - utf8len, (size_t)utf8len);
            len += (size_t)utf8len;
            break;
          }
          default:
            luaM_freearray(L, buf, capacity);
            luaM_freearray(L, stack, stack_cap);
            json_error(p, "invalid escape sequence");
          }
          p->json++;
        } else {
          buf[len++] = *p->json;
          p->json++;
        }
      }
      if (p->json >= p->end || *p->json != '"') {
        luaM_freearray(L, buf, capacity);
        luaM_freearray(L, stack, stack_cap);
        json_error(p, "unterminated string");
      }
      p->json++; /* skip closing quote */

      TString *str = luaS_newlstr(L, buf, len);
      setsvalue(L, &value, str);
      luaM_freearray(L, buf, capacity);
      break;
    }
    case 't':
      parse_literal(p, "true", 4);
      setbtvalue(&value);
      break;
    case 'f':
      parse_literal(p, "false", 5);
      setbfvalue(&value);
      break;
    case 'n':
      parse_literal(p, "null", 4);
      setnilvalue(&value);
      break;
    case '-':
    case '0':
    case '1':
    case '2':
    case '3':
    case '4':
    case '5':
    case '6':
    case '7':
    case '8':
    case '9': {
      const char *start = p->json;
      if (*p->json == '-')
        p->json++;
      if (p->json >= p->end || !isdigit((unsigned char)*p->json)) {
        luaM_freearray(L, stack, stack_cap);
        json_error(p, "invalid number");
      }
      if (*p->json == '0') {
        p->json++;
        if (p->json < p->end && isdigit((unsigned char)*p->json)) {
          luaM_freearray(L, stack, stack_cap);
          json_error(p, "leading zeros not allowed");
        }
      } else {
        while (p->json < p->end && isdigit((unsigned char)*p->json))
          p->json++;
      }
      int is_float = 0;
      if (p->json < p->end && *p->json == '.') {
        is_float = 1;
        p->json++;
        if (p->json >= p->end || !isdigit((unsigned char)*p->json)) {
          luaM_freearray(L, stack, stack_cap);
          json_error(p, "digit expected after decimal");
        }
        while (p->json < p->end && isdigit((unsigned char)*p->json))
          p->json++;
      }
      if (p->json < p->end && (*p->json == 'e' || *p->json == 'E')) {
        is_float = 1;
        p->json++;
        if (p->json < p->end && (*p->json == '+' || *p->json == '-'))
          p->json++;
        if (p->json >= p->end || !isdigit((unsigned char)*p->json)) {
          luaM_freearray(L, stack, stack_cap);
          json_error(p, "digit expected in exponent");
        }
        while (p->json < p->end && isdigit((unsigned char)*p->json))
          p->json++;
      }
      size_t numlen = (size_t)(p->json - start);
      char *numbuf = luaM_newvector(L, numlen + 1, char);
      memcpy(numbuf, start, numlen);
      numbuf[numlen] = '\0';
      if (is_float) {
        lua_Number n = (lua_Number)strtod(numbuf, NULL);
        setfltvalue(&value, n);
      } else {
        lua_Integer n = (lua_Integer)strtoll(numbuf, NULL, 10);
        setivalue(&value, n);
      }
      luaM_freearray(L, numbuf, numlen + 1);
      (void)is_float;
      break;
    }
    case '[':
      if (++depth > JSON_MAX_DEPTH) {
        luaM_freearray(L, stack, stack_cap);
        json_error(p, "maximum nesting depth exceeded");
      }
      p->json++;
      skip_whitespace(p);
      {
        Table *t = luaH_new(L);
        if (peek(p) == ']') {
          p->json++; /* empty array */
          depth--;
          sethvalue(L, &value, t);
        } else {
          /* Push container frame */
          if (stack_size >= stack_cap) {
            size_t newcap = stack_cap * 2;
            stack =
                luaM_reallocvector(L, stack, stack_cap, newcap, ContainerFrame);
            stack_cap = newcap;
          }
          stack[stack_size].table = t;
          stack[stack_size].is_array = 1;
          stack[stack_size].idx = 1;
          stack[stack_size].key = NULL;
          stack_size++;
          continue; /* Parse first element */
        }
      }
      break;
    case '{':
      if (++depth > JSON_MAX_DEPTH) {
        luaM_freearray(L, stack, stack_cap);
        json_error(p, "maximum nesting depth exceeded");
      }
      p->json++;
      skip_whitespace(p);
      {
        Table *t = luaH_new(L);
        if (peek(p) == '}') {
          p->json++; /* empty object */
          depth--;
          sethvalue(L, &value, t);
        } else {
          /* Parse key */
          if (peek(p) != '"') {
            luaM_freearray(L, stack, stack_cap);
            json_error(p, "expected string key in object");
          }
          /* Parse key string inline */
          size_t kcap = 64, klen = 0;
          char *kbuf = luaM_newvector(L, kcap, char);
          p->json++; /* skip quote */
          while (p->json < p->end && *p->json != '"') {
            if (klen + 1 >= kcap) {
              size_t newcap = kcap * 2;
              kbuf = luaM_reallocvector(L, kbuf, kcap, newcap, char);
              kcap = newcap;
            }
            if (*p->json == '\\') {
              p->json++;
              if (p->json >= p->end)
                break;
              switch (*p->json) {
              case '"':
                kbuf[klen++] = '"';
                break;
              case '\\':
                kbuf[klen++] = '\\';
                break;
              case 'n':
                kbuf[klen++] = '\n';
                break;
              case 't':
                kbuf[klen++] = '\t';
                break;
              case 'r':
                kbuf[klen++] = '\r';
                break;
              default:
                kbuf[klen++] = *p->json;
                break;
              }
            } else {
              kbuf[klen++] = *p->json;
            }
            p->json++;
          }
          if (p->json < p->end)
            p->json++; /* skip closing quote */
          expect(p, ':', "after object key");
          TString *keystr = luaS_newlstr(L, kbuf, klen);
          luaM_freearray(L, kbuf, kcap);

          /* Push container frame */
          if (stack_size >= stack_cap) {
            size_t newcap = stack_cap * 2;
            stack =
                luaM_reallocvector(L, stack, stack_cap, newcap, ContainerFrame);
            stack_cap = newcap;
          }
          stack[stack_size].table = t;
          stack[stack_size].is_array = 0;
          stack[stack_size].idx = 0;
          stack[stack_size].key = keystr;
          stack_size++;
          continue; /* Parse value */
        }
      }
      break;
    case -1:
      luaM_freearray(L, stack, stack_cap);
      json_error(p, "unexpected end of input");
      break;
    default:
      luaM_freearray(L, stack, stack_cap);
      json_error(p, "unexpected character");
    }

    /* Integrate value into parent container */
    while (stack_size > 0) {
      ContainerFrame *parent = &stack[stack_size - 1];

      if (parent->is_array) {
        /* Set array element directly */
        luaH_setint(L, parent->table, parent->idx, &value);
        parent->idx++;

        if (accept(p, ',')) {
          break; /* Parse next element */
        } else {
          expect(p, ']', "after array element");
          depth--;
          sethvalue(L, &value, parent->table);
          stack_size--;
        }
      } else {
        /* Set object key-value directly */
        TValue keyval;
        setsvalue(L, &keyval, parent->key);
        luaH_set(L, parent->table, &keyval, &value);

        if (accept(p, ',')) {
          /* Parse next key */
          if (peek(p) != '"') {
            luaM_freearray(L, stack, stack_cap);
            json_error(p, "expected string key");
          }
          /* Parse key inline */
          size_t kcap = 64, klen = 0;
          char *kbuf = luaM_newvector(L, kcap, char);
          p->json++; /* skip quote */
          while (p->json < p->end && *p->json != '"') {
            if (klen + 1 >= kcap) {
              size_t newcap = kcap * 2;
              kbuf = luaM_reallocvector(L, kbuf, kcap, newcap, char);
              kcap = newcap;
            }
            if (*p->json == '\\') {
              p->json++;
              if (p->json >= p->end)
                break;
              switch (*p->json) {
              case '"':
                kbuf[klen++] = '"';
                break;
              case '\\':
                kbuf[klen++] = '\\';
                break;
              case 'n':
                kbuf[klen++] = '\n';
                break;
              default:
                kbuf[klen++] = *p->json;
                break;
              }
            } else {
              kbuf[klen++] = *p->json;
            }
            p->json++;
          }
          if (p->json < p->end)
            p->json++;
          expect(p, ':', "after object key");
          parent->key = luaS_newlstr(L, kbuf, klen);
          luaM_freearray(L, kbuf, kcap);
          break; /* Parse value */
        } else {
          expect(p, '}', "after object value");
          depth--;
          sethvalue(L, &value, parent->table);
          stack_size--;
        }
      }
    }

    if (stack_size == 0)
      break;
  }

  luaM_freearray(L, stack, stack_cap);

  /* Push final result onto Lua stack */
  setobj2s(L, L->top.p, &value);
  L->top.p++;
}

static int json_fromjson(lua_State *L) {
  size_t len;
  const char *json = luaL_checklstring(L, 1, &len);

  JsonParser p;
  p.L = L;
  p.json = json;
  p.start = json;
  p.end = json + len;

  parse_value_iterative(&p);

  /* Check for trailing content (only whitespace allowed) */
  skip_whitespace(&p);
  if (p.json < p.end)
    json_error(&p, "unexpected content after JSON value");

  return 1;
}

/* ============================================================
** JSON Serializer (tojson)
** ============================================================ */

typedef struct {
  lua_State *L;
  luaL_Buffer b;
  int filter_idx;  /* stack index of filter function (0 if none) */
  int depth;       /* current nesting depth */
  int visited_idx; /* stack index of visited table (for cycle detection) */
} JsonWriter;

static void write_value(JsonWriter *w, int idx);

static void write_char(JsonWriter *w, char c) { luaL_addchar(&w->b, c); }

static void write_string_raw(JsonWriter *w, const char *s, size_t len) {
  luaL_addlstring(&w->b, s, len);
}

static void write_literal(JsonWriter *w, const char *s) {
  luaL_addstring(&w->b, s);
}

/* Write a JSON string (with escaping) */
static void write_json_string(JsonWriter *w, const char *s, size_t len) {
  size_t i;
  write_char(w, '"');

  for (i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    switch (c) {
    case '"':
      write_string_raw(w, "\\\"", 2);
      break;
    case '\\':
      write_string_raw(w, "\\\\", 2);
      break;
    case '\b':
      write_string_raw(w, "\\b", 2);
      break;
    case '\f':
      write_string_raw(w, "\\f", 2);
      break;
    case '\n':
      write_string_raw(w, "\\n", 2);
      break;
    case '\r':
      write_string_raw(w, "\\r", 2);
      break;
    case '\t':
      write_string_raw(w, "\\t", 2);
      break;
    default:
      if (c < 0x20) {
        /* Control character - use \u00XX escape */
        char buf[8];
        snprintf(buf, sizeof(buf), "\\u%04x", c);
        write_string_raw(w, buf, 6);
      } else {
        write_char(w, (char)c);
      }
    }
  }

  write_char(w, '"');
}

/* Check if a value type can be serialized to JSON */
static int is_json_serializable(lua_State *L, int idx) {
  int t = lua_type(L, idx);
  switch (t) {
  case LUA_TNIL:
  case LUA_TBOOLEAN:
  case LUA_TNUMBER:
  case LUA_TSTRING:
  case LUA_TTABLE:
    return 1;
  case LUA_TUSERDATA:
    /* Userdata is serializable if it has __json metamethod */
    if (luaL_getmetafield(L, idx, "__json") != LUA_TNIL) {
      lua_pop(L, 1);
      return 1;
    }
    return 0;
  default:
    /* Function, thread, lightuserdata, enum are not serializable */
    return 0;
  }
}

/* Check if a table is array-like (contiguous integer keys 1..n) */
static int is_array(lua_State *L, int idx) {
  lua_Integer max = 0;
  lua_Integer count = 0;

  idx = lua_absindex(L, idx);

  lua_pushnil(L);
  while (lua_next(L, idx)) {
    lua_pop(L, 1); /* pop value, keep key */

    if (lua_type(L, -1) != LUA_TNUMBER) {
      lua_pop(L, 1); /* pop key before returning */
      return 0;
    }

    if (!lua_isinteger(L, -1)) {
      lua_pop(L, 1); /* pop key before returning */
      return 0;
    }

    lua_Integer k = lua_tointeger(L, -1);
    if (k <= 0) {
      lua_pop(L, 1); /* pop key before returning */
      return 0;
    }

    count++;
    if (k > max)
      max = k;
  }

  /* It's an array if keys are exactly 1..max with no gaps */
  return (max == count);
}

/* Write a number as JSON */
static void write_number(JsonWriter *w, lua_State *L, int idx) {
  if (lua_isinteger(L, idx)) {
    lua_Integer n = lua_tointeger(L, idx);
    char buf[32];
    int len = snprintf(buf, sizeof(buf), LUA_INTEGER_FMT, (LUAI_UACINT)n);
    write_string_raw(w, buf, (size_t)len);
  } else {
    lua_Number n = lua_tonumber(L, idx);

    /* Handle special float values */
    if (isinf(n) || isnan(n)) {
      write_literal(w, "null");
      return;
    }

    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%.17g", n);
    write_string_raw(w, buf, (size_t)len);
  }
}

/* Apply filter function if present, returns 1 if value should be included */
static int apply_filter(JsonWriter *w, int key_idx, int val_idx) {
  if (w->filter_idx == 0)
    return 1; /* no filter, include everything */

  lua_State *L = w->L;

  /* Call filter(key, value) */
  lua_pushvalue(L, w->filter_idx);
  lua_pushvalue(L, key_idx);
  lua_pushvalue(L, val_idx);
  lua_call(L, 2, 1);

  /* If filter returns nil, skip this value */
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    return 0;
  }

  /* Replace the value at val_idx with the filtered value */
  lua_replace(L, val_idx);
  return 1;
}

/* Check for __json metamethod */
static int has_json_metamethod(lua_State *L, int idx) {
  if (luaL_getmetafield(L, idx, "__json") != LUA_TNIL) {
    lua_pop(L, 1);
    return 1;
  }
  return 0;
}

/* Call __json metamethod, returns transformed value on stack */
static void call_json_metamethod(JsonWriter *w, int idx) {
  lua_State *L = w->L;

  if (luaL_getmetafield(L, idx, "__json") == LUA_TNIL) {
    lua_pushnil(L);
    return;
  }

  lua_pushvalue(L, idx); /* self */
  lua_call(L, 1, 1);
}

/* Check if table is already being visited (cycle detection) */
static int is_visited(JsonWriter *w, int tbl_idx) {
  lua_State *L = w->L;
  tbl_idx = lua_absindex(L, tbl_idx);

  lua_pushvalue(L, tbl_idx);
  lua_rawget(L, w->visited_idx);
  int visited = !lua_isnil(L, -1);
  lua_pop(L, 1);

  return visited;
}

static void mark_visited(JsonWriter *w, int tbl_idx) {
  lua_State *L = w->L;
  tbl_idx = lua_absindex(L, tbl_idx);

  lua_pushvalue(L, tbl_idx);
  lua_pushboolean(L, 1);
  lua_rawset(L, w->visited_idx);
}

static void unmark_visited(JsonWriter *w, int tbl_idx) {
  lua_State *L = w->L;
  tbl_idx = lua_absindex(L, tbl_idx);

  lua_pushvalue(L, tbl_idx);
  lua_pushnil(L);
  lua_rawset(L, w->visited_idx);
}

static void write_array(JsonWriter *w, int idx) {
  lua_State *L = w->L;
  idx = lua_absindex(L, idx);

  write_char(w, '[');

  lua_Integer len = luaL_len(L, idx);
  int first = 1;

  for (lua_Integer i = 1; i <= len; i++) {
    lua_geti(L, idx, i); /* push value at index i */
    int val_idx = lua_gettop(L);

    /* Apply filter with numeric key if present */
    if (w->filter_idx != 0) {
      lua_pushinteger(L, i);     /* push key */
      lua_pushvalue(L, val_idx); /* push copy of value */
      int filtered_val_idx = lua_gettop(L);
      int key_idx = filtered_val_idx - 1;

      if (!apply_filter(w, key_idx, filtered_val_idx)) {
        lua_pop(L, 3); /* pop key, filtered value, original value */
        continue;
      }

      if (!first)
        write_char(w, ',');
      first = 0;

      write_value(w, filtered_val_idx);
      lua_pop(L, 3); /* pop key, filtered value, original value */
    } else {
      if (!first)
        write_char(w, ',');
      first = 0;

      write_value(w, val_idx);
      lua_pop(L, 1); /* pop value */
    }
  }

  write_char(w, ']');
}

static void write_object(JsonWriter *w, int idx) {
  lua_State *L = w->L;
  idx = lua_absindex(L, idx);

  write_char(w, '{');

  int first = 1;
  lua_pushnil(L);

  while (lua_next(L, idx)) {
    int val_idx = lua_gettop(L);
    int key_idx = val_idx - 1;

    /* Object keys must be strings */
    if (lua_type(L, key_idx) != LUA_TSTRING) {
      lua_pop(L, 1); /* pop value, keep key for next iteration */
      continue;
    }

    /* Skip values that cannot be serialized to JSON */
    if (!is_json_serializable(L, val_idx)) {
      lua_pop(L, 1); /* pop value, keep key for next iteration */
      continue;
    }

    /* Apply filter if present */
    if (w->filter_idx != 0) {
      lua_pushvalue(L, val_idx); /* copy value since filter may replace it */
      int filtered_val_idx = lua_gettop(L);

      if (!apply_filter(w, key_idx, filtered_val_idx)) {
        lua_pop(L, 2); /* pop copied value and original value */
        continue;
      }

      if (!first)
        write_char(w, ',');
      first = 0;

      /* Write key */
      size_t klen;
      const char *key = lua_tolstring(L, key_idx, &klen);
      write_json_string(w, key, klen);
      write_char(w, ':');

      /* Write filtered value */
      write_value(w, filtered_val_idx);
      lua_pop(L, 2); /* pop filtered value and original value */
    } else {
      if (!first)
        write_char(w, ',');
      first = 0;

      /* Write key */
      size_t klen;
      const char *key = lua_tolstring(L, key_idx, &klen);
      write_json_string(w, key, klen);
      write_char(w, ':');

      /* Write value */
      write_value(w, val_idx);
      lua_pop(L, 1); /* pop value, keep key for next iteration */
    }
  }

  write_char(w, '}');
}

static void write_table(JsonWriter *w, int idx) {
  lua_State *L = w->L;
  idx = lua_absindex(L, idx);

  /* Check for cycles */
  if (is_visited(w, idx)) {
    luaL_error(L, "circular reference detected in table");
    return;
  }

  if (++w->depth > JSON_MAX_DEPTH)
    luaL_error(L, "maximum nesting depth exceeded");

  mark_visited(w, idx);

  /* Check for __json metamethod */
  if (has_json_metamethod(L, idx)) {
    call_json_metamethod(w, idx);
    write_value(w, lua_gettop(L));
    lua_pop(L, 1);
  } else if (is_array(L, idx)) {
    write_array(w, idx);
  } else {
    write_object(w, idx);
  }

  unmark_visited(w, idx);
  w->depth--;
}

static void write_value(JsonWriter *w, int idx) {
  lua_State *L = w->L;
  idx = lua_absindex(L, idx);

  int t = lua_type(L, idx);

  switch (t) {
  case LUA_TNIL:
    write_literal(w, "null");
    break;

  case LUA_TBOOLEAN:
    write_literal(w, lua_toboolean(L, idx) ? "true" : "false");
    break;

  case LUA_TNUMBER:
    write_number(w, L, idx);
    break;

  case LUA_TSTRING: {
    size_t len;
    const char *s = lua_tolstring(L, idx, &len);
    write_json_string(w, s, len);
    break;
  }

  case LUA_TTABLE:
    write_table(w, idx);
    break;

  case LUA_TUSERDATA:
    /* Check for __json metamethod on userdata */
    if (has_json_metamethod(L, idx)) {
      call_json_metamethod(w, idx);
      write_value(w, lua_gettop(L));
      lua_pop(L, 1);
    } else {
      /* Skip userdata without __json */
      write_literal(w, "null");
    }
    break;

  default:
    /* Skip unsupported types (function, thread, enum, lightuserdata) */
    /* When called from object/array context, these are skipped */
    /* When called as top-level, output null */
    write_literal(w, "null");
    break;
  }
}

static int json_tojson(lua_State *L) {
  luaL_checkany(L, 1);

  JsonWriter w;
  w.L = L;
  w.filter_idx = lua_isfunction(L, 2) ? 2 : 0;
  w.depth = 0;

  /* Create visited table for cycle detection */
  lua_newtable(L);
  w.visited_idx = lua_gettop(L);

  luaL_buffinit(L, &w.b);

  /* If filter is provided and top-level value needs filtering */
  if (w.filter_idx != 0) {
    lua_pushnil(L);      /* key for top-level is nil */
    lua_pushvalue(L, 1); /* copy value */
    int val_idx = lua_gettop(L);
    int key_idx = val_idx - 1;

    if (!apply_filter(&w, key_idx, val_idx)) {
      lua_pop(L, 2);
      lua_pushliteral(L, "null");
      return 1;
    }

    write_value(&w, val_idx);
    lua_pop(L, 2);
  } else {
    write_value(&w, 1);
  }

  luaL_pushresult(&w.b);
  return 1;
}

/* ============================================================
** Registration
** ============================================================ */

static const luaL_Reg json_funcs[] = {
    {"tojson", json_tojson}, {"fromjson", json_fromjson}, {NULL, NULL}};

LUAMOD_API int luaopen_json(lua_State *L) {
  /* Register functions in the global table */
  lua_pushglobaltable(L);
  luaL_setfuncs(L, json_funcs, 0);
  lua_pop(L, 1);
  return 0;
}
