/*
** $Id: lfastcall.c $
** VM-intrinsified standard library functions
** See Copyright Notice in lua.h
*/

#define lfastcall_c
#define LUA_CORE

#include "lprefix.h"

#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"

#include "lfastcall.h"
#include "lgc.h"
#include "llimits.h"
#include "lmem.h"
#include "lobject.h"
#include "lstate.h"
#include "lstring.h"
#include "ltable.h"
#include "ltm.h"
#include "lvm.h"
#include "lvector.h"


/*
** Pre-interned strings are stored per-state in global_State to avoid
** cross-state pointer issues when workers create separate lua_States.
** Access macros for convenience:
*/
#define fc_str_integer (G(L)->fc_str_integer)
#define fc_str_float (G(L)->fc_str_float)
#define fc_str_nil (G(L)->fc_str_nil)
#define fc_str_true (G(L)->fc_str_true)
#define fc_str_false (G(L)->fc_str_false)
#define fc_str___metatable (G(L)->fc_str___metatable)
#define fc_typenames (G(L)->fc_typenames)


/*
** UTF-8 decode helper (replicates lutf8lib's static utf8_decode).
*/
#define FC_MAXUTF 0x7FFFFFFFu

static const char *fc_utf8_decode(const char *s, l_uint32 *val, int strict) {
  static const l_uint32 limits[] = {~(l_uint32)0, 0x80,      0x800,
                                    0x10000u,     0x200000u, 0x4000000u};
  unsigned int c = (unsigned char)s[0];
  l_uint32 res = 0;
  if (c < 0x80)
    res = c;
  else {
    int count = 0;
    for (; c & 0x40; c <<= 1) {
      unsigned int cc = (unsigned char)s[++count];
      if ((cc & 0xC0) != 0x80)
        return NULL;
      res = (res << 6) | (cc & 0x3F);
    }
    res |= ((l_uint32)(c & 0x7F) << (count * 5));
    if (count > 5 || res > FC_MAXUTF || res < limits[count])
      return NULL;
    s += count;
  }
  if (strict) {
    if (res > 0x10FFFFu || (0xD800u <= res && res <= 0xDFFFu))
      return NULL;
  }
  if (val)
    *val = res;
  return s + 1;
}


/*
** Safe wrapper: create and fix a string, skipping luaC_fix if
** the string is already fixed (i.e. not on the allgc list).
*/
static TString *fc_newfix(lua_State *L, const char *str) {
  global_State *g = G(L);
  TString *s = luaS_new(L, str);
  if (g->allgc == obj2gco(s))
    luaC_fix(L, obj2gco(s));
  /* else: string already interned/fixed (e.g. reserved word) — skip */
  return s;
}


/*
** Memory-find helper (replicates lstrlib's static lmemfind).
*/
static const char *fc_memfind(const char *s1, size_t l1, const char *s2,
                              size_t l2) {
  if (l2 == 0)
    return s1;
  else if (l2 > l1)
    return NULL;
  else {
    const char *init;
    l2--;
    l1 -= l2;
    while (l1 > 0 && (init = (const char *)memchr(s1, *s2, l1)) != NULL) {
      init++;
      if (memcmp(init, s2 + 1, l2) == 0)
        return init - 1;
      else {
        l1 -= (size_t)(init - s1);
        s1 = init;
      }
    }
    return NULL;
  }
}


/*
** Comparator for qsort in FC_TABLE_MEDIAN.
*/
static int fc_numcmp(const void *a, const void *b) {
  lua_Number x = *(const lua_Number *)a;
  lua_Number y = *(const lua_Number *)b;
  if (x < y)
    return -1;
  if (x > y)
    return 1;
  return 0;
}


/* Helper: check default whitespace */
#define fc_isspace(c) ((c) == ' ' || (c) == '\t' || (c) == '\n' || (c) == '\r')


/*
** Execute a fastcall inline. Returns 1 on success (result written
** to s2v(ra)), 0 to fall back to normal call.
** Caller must have called savestate(L, ci) before invoking.
*/
int luaV_dofastcall(lua_State *L, int fc_id, StkId ra) {
  switch (fc_id) {
    case FC_TYPE: {
      setsvalue2s(L, ra, fc_typenames[ttype(s2v(ra + 1)) + 1]);
      break;
    }
    case FC_RAWLEN: {
      TValue *arg = s2v(ra + 1);
      if (ttistable(arg)) {
        setivalue(s2v(ra), cast_int(luaH_getn(L, hvalue(arg))));
      }
      else if (ttisstring(arg)) {
        setivalue(s2v(ra), cast_int(tsslen(tsvalue(arg))));
      }
      else
        return 0;
      break;
    }
    case FC_RAWGET: {
      TValue *t = s2v(ra + 1), *k = s2v(ra + 2);
      if (l_likely(ttistable(t))) {
        lu_byte tag = luaH_get(hvalue(t), k, s2v(ra));
        if (tagisempty(tag))
          setnilvalue(s2v(ra));
      }
      else
        return 0;
      break;
    }
    case FC_RAWSET: {
      TValue *t = s2v(ra + 1), *k = s2v(ra + 2), *v = s2v(ra + 3);
      if (l_likely(ttistable(t))) {
        luaH_set(L, hvalue(t), k, v);
        luaC_barrierback(L, obj2gco(hvalue(s2v(ra + 1))), v);
        setobj2s(L, ra, s2v(ra + 1));
      }
      else
        return 0;
      break;
    }
    case FC_RAWEQUAL: {
      int eq = luaV_rawequalobj(s2v(ra + 1), s2v(ra + 2));
      if (eq)
        setbtvalue(s2v(ra));
      else
        setbfvalue(s2v(ra));
      break;
    }
    case FC_ASSERT: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(!l_isfalse(arg))) {
        setobj2s(L, ra, arg);
      }
      else
        return 0; /* fall back for error message */
      break;
    }
    case FC_GETMETATABLE: {
      TValue *arg = s2v(ra + 1);
      Table *mt;
      if (ttistable(arg))
        mt = hvalue(arg)->metatable;
      else
        mt = G(L)->mt[ttype(arg)];
      if (mt == NULL) {
        setnilvalue(s2v(ra));
      }
      else {
        TValue mmval;
        lu_byte tag = luaH_getshortstr(mt, fc_str___metatable, &mmval);
        if (!tagisempty(tag)) {
          setobj2s(L, ra, &mmval);
        }
        else {
          sethvalue2s(L, ra, mt);
        }
      }
      break;
    }
    case FC_SETMETATABLE: {
      TValue *arg1 = s2v(ra + 1), *arg2 = s2v(ra + 2);
      if (!ttistable(arg1))
        return 0;
      if (!ttisnil(arg2) && !ttistable(arg2))
        return 0;
      Table *t = hvalue(arg1);
      /* Readonly tables cannot have their metatable changed */
      if (l_unlikely(isreadonly(t)))
        return 0;
      /* If existing metatable has __metatable, fall back for error */
      if (t->metatable != NULL) {
        TValue mmval;
        lu_byte tag =
            luaH_getshortstr(t->metatable, fc_str___metatable, &mmval);
        if (!tagisempty(tag))
          return 0;
      }
      t->metatable = ttisnil(arg2) ? NULL : hvalue(arg2);
      if (t->metatable != NULL) {
        luaC_objbarrier(L, t, t->metatable);
        luaC_checkfinalizer(L, obj2gco(t), t->metatable);
      }
      setobj2s(L, ra, arg1); /* return the table */
      break;
    }
    case FC_TONUMBER: {
      TValue *arg = s2v(ra + 1);
      if (ttisinteger(arg)) {
        setivalue(s2v(ra), ivalue(arg));
      }
      else if (ttisfloat(arg)) {
        setfltvalue(s2v(ra), fltvalue(arg));
      }
      else if (ttisstring(arg)) {
        TString *ts = tsvalue(arg);
        TValue temp;
        if (luaO_str2num(getstr(ts), &temp) == tsslen(ts) + 1) {
          setobj2s(L, ra, &temp);
        }
        else {
          setnilvalue(s2v(ra));
        }
      }
      else if (ttisenum(arg)) {
        setivalue(s2v(ra), enumvalue(arg)->idx);
      }
      else {
        setnilvalue(s2v(ra));
      }
      break;
    }
    case FC_TOSTRING: {
      TValue *arg = s2v(ra + 1);
      if (ttisstring(arg)) {
        setsvalue2s(L, ra, tsvalue(arg));
      }
      else if (ttisnil(arg)) {
        setsvalue2s(L, ra, fc_str_nil);
      }
      else if (ttisboolean(arg)) {
        setsvalue2s(L, ra, l_isfalse(arg) ? fc_str_false : fc_str_true);
      }
      else if (ttisnumber(arg)) {
        TValue temp;
        setobj(L, &temp, arg);
        luaO_tostring(L, &temp);
        setobj2s(L, ra, &temp);
      }
      else
        return 0; /* table/func/userdata may have __tostring */
      break;
    }
    case FC_MATH_ABS: {
      TValue *arg = s2v(ra + 1);
      if (ttisinteger(arg)) {
        lua_Integer n = ivalue(arg);
        if (n < 0)
          n = l_castU2S(0u - l_castS2U(n));
        setivalue(s2v(ra), n);
      }
      else if (ttisfloat(arg)) {
        setfltvalue(s2v(ra), l_mathop(fabs)(fltvalue(arg)));
      }
      else
        return 0;
      break;
    }
    case FC_MATH_MAX: {
      TValue *v1 = s2v(ra + 1), *v2 = s2v(ra + 2);
      if (ttisinteger(v1) && ttisinteger(v2)) {
        lua_Integer i1 = ivalue(v1), i2 = ivalue(v2);
        setivalue(s2v(ra), (i1 > i2) ? i1 : i2);
      }
      else if (ttisnumber(v1) && ttisnumber(v2)) {
        lua_Number n1 = ttisinteger(v1) ? cast_num(ivalue(v1)) : fltvalue(v1);
        lua_Number n2 = ttisinteger(v2) ? cast_num(ivalue(v2)) : fltvalue(v2);
        setfltvalue(s2v(ra), (n1 > n2) ? n1 : n2);
      }
      else {
        return 0;
      }
      break;
    }
    case FC_MATH_MIN: {
      TValue *v1 = s2v(ra + 1), *v2 = s2v(ra + 2);
      if (ttisinteger(v1) && ttisinteger(v2)) {
        lua_Integer i1 = ivalue(v1), i2 = ivalue(v2);
        setivalue(s2v(ra), (i1 < i2) ? i1 : i2);
      }
      else if (ttisnumber(v1) && ttisnumber(v2)) {
        lua_Number n1 = ttisinteger(v1) ? cast_num(ivalue(v1)) : fltvalue(v1);
        lua_Number n2 = ttisinteger(v2) ? cast_num(ivalue(v2)) : fltvalue(v2);
        setfltvalue(s2v(ra), (n1 < n2) ? n1 : n2);
      }
      else {
        return 0;
      }
      break;
    }

/* Macro for simple unary math fastcalls (always return float) */
#define FC_MATH_UNARY(op)                                                      \
  {                                                                            \
    TValue *arg = s2v(ra + 1);                                                 \
    if (!ttisnumber(arg))                                                      \
      return 0;                                                                \
    lua_Number n = (ttisinteger(arg)) ? cast_num(ivalue(arg)) : fltvalue(arg); \
    setfltvalue(s2v(ra), l_mathop(op)(n));                                     \
    break;                                                                     \
  }

    case FC_MATH_CEIL: {
      TValue *arg = s2v(ra + 1);
      if (ttisinteger(arg)) {
        setivalue(s2v(ra), ivalue(arg));
      }
      else if (ttisfloat(arg)) {
        lua_Number n = l_mathop(ceil)(fltvalue(arg));
        lua_Integer i;
        if (lua_numbertointeger(n, &i)) {
          setivalue(s2v(ra), i);
        }
        else {
          setfltvalue(s2v(ra), n);
        }
      }
      else
        return 0;
      break;
    }
    case FC_MATH_FLOOR: {
      TValue *arg = s2v(ra + 1);
      if (ttisinteger(arg)) {
        setivalue(s2v(ra), ivalue(arg));
      }
      else if (ttisfloat(arg)) {
        lua_Number n = l_mathop(floor)(fltvalue(arg));
        lua_Integer i;
        if (lua_numbertointeger(n, &i)) {
          setivalue(s2v(ra), i);
        }
        else {
          setfltvalue(s2v(ra), n);
        }
      }
      else
        return 0;
      break;
    }
    case FC_MATH_SQRT: FC_MATH_UNARY(sqrt)
    case FC_MATH_SIN: FC_MATH_UNARY(sin)
    case FC_MATH_COS: FC_MATH_UNARY(cos)
    case FC_MATH_TAN: FC_MATH_UNARY(tan)
    case FC_MATH_ASIN: FC_MATH_UNARY(asin)
    case FC_MATH_ACOS: FC_MATH_UNARY(acos)
    case FC_MATH_ATAN: {
      TValue *arg = s2v(ra + 1);
      if (!ttisnumber(arg))
        return 0;
      lua_Number y = (ttisinteger(arg)) ? cast_num(ivalue(arg)) : fltvalue(arg);
      setfltvalue(s2v(ra), l_mathop(atan2)(y, l_mathop(1.0)));
      break;
    }
    case FC_MATH_EXP: FC_MATH_UNARY(exp)
    case FC_MATH_LOG: {
      TValue *arg = s2v(ra + 1);
      if (!ttisnumber(arg))
        return 0;
      lua_Number n = (ttisinteger(arg)) ? cast_num(ivalue(arg)) : fltvalue(arg);
      setfltvalue(s2v(ra), l_mathop(log)(n));
      break;
    }
    case FC_MATH_DEG: {
      TValue *arg = s2v(ra + 1);
      if (!ttisnumber(arg))
        return 0;
      lua_Number n = (ttisinteger(arg)) ? cast_num(ivalue(arg)) : fltvalue(arg);
      setfltvalue(s2v(ra), n * (l_mathop(180.0) / l_mathop(3.141592653589793)));
      break;
    }
    case FC_MATH_RAD: {
      TValue *arg = s2v(ra + 1);
      if (!ttisnumber(arg))
        return 0;
      lua_Number n = (ttisinteger(arg)) ? cast_num(ivalue(arg)) : fltvalue(arg);
      setfltvalue(s2v(ra), n * (l_mathop(3.141592653589793) / l_mathop(180.0)));
      break;
    }
    case FC_MATH_FMOD: {
      TValue *v1 = s2v(ra + 1), *v2 = s2v(ra + 2);
      if (ttisinteger(v1) && ttisinteger(v2)) {
        lua_Integer d = ivalue(v2);
        if (d == 0)
          return 0;                    /* fall back for error */
        if (l_castS2U(d) + 1u <= 1u) { /* d is -1 or 0 */
          setivalue(s2v(ra), 0);
        }
        else {
          setivalue(s2v(ra), ivalue(v1) % d);
        }
      }
      else if (ttisnumber(v1) && ttisnumber(v2)) {
        lua_Number n1 = ttisinteger(v1) ? cast_num(ivalue(v1)) : fltvalue(v1);
        lua_Number n2 = ttisinteger(v2) ? cast_num(ivalue(v2)) : fltvalue(v2);
        setfltvalue(s2v(ra), l_mathop(fmod)(n1, n2));
      }
      else
        return 0;
      break;
    }
    case FC_MATH_ULT: {
      TValue *v1 = s2v(ra + 1), *v2 = s2v(ra + 2);
      if (ttisinteger(v1) && ttisinteger(v2)) {
        if (l_castS2U(ivalue(v1)) < l_castS2U(ivalue(v2)))
          setbtvalue(s2v(ra));
        else
          setbfvalue(s2v(ra));
      }
      else
        return 0;
      break;
    }
    case FC_MATH_TOINTEGER: {
      TValue *arg = s2v(ra + 1);
      if (ttisinteger(arg)) {
        setivalue(s2v(ra), ivalue(arg));
      }
      else if (ttisfloat(arg)) {
        lua_Integer i;
        if (luaV_flttointeger(fltvalue(arg), &i, F2Ieq)) {
          setivalue(s2v(ra), i);
        }
        else {
          setnilvalue(s2v(ra)); /* fail */
        }
      }
      else {
        setnilvalue(s2v(ra)); /* fail */
      }
      break;
    }
    case FC_MATH_TYPE: {
      TValue *arg = s2v(ra + 1);
      if (ttisinteger(arg)) {
        setsvalue2s(L, ra, fc_str_integer);
      }
      else if (ttisfloat(arg)) {
        setsvalue2s(L, ra, fc_str_float);
      }
      else
        setnilvalue(s2v(ra));
      break;
    }
    case FC_MATH_LDEXP: {
      TValue *v1 = s2v(ra + 1), *v2 = s2v(ra + 2);
      if (!ttisnumber(v1) || !ttisinteger(v2))
        return 0;
      lua_Number x = (ttisinteger(v1)) ? cast_num(ivalue(v1)) : fltvalue(v1);
      setfltvalue(s2v(ra), l_mathop(ldexp)(x, (int)ivalue(v2)));
      break;
    }
    case FC_STRING_LEN: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttisstring(arg))) {
        setivalue(s2v(ra), cast_int(tsslen(tsvalue(arg))));
      }
      else
        return 0;
      break;
    }
    /* ---- New string fastcalls ---- */
    case FC_STRING_TRIM: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttisstring(arg))) {
        TString *ts = tsvalue(arg);
        const char *s = getstr(ts);
        size_t len = tsslen(ts);
        size_t start = 0, end = len;
        while (start < end && fc_isspace((unsigned char)s[start]))
          start++;
        while (end > start && fc_isspace((unsigned char)s[end - 1]))
          end--;
        if (start == 0 && end == len) {
          setsvalue2s(L, ra, ts);
        }
        else {
          setsvalue2s(L, ra, luaS_newlstr(L, s + start, end - start));
        }
      }
      else
        return 0;
      break;
    }
    case FC_STRING_LTRIM: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttisstring(arg))) {
        TString *ts = tsvalue(arg);
        const char *s = getstr(ts);
        size_t len = tsslen(ts);
        size_t start = 0;
        while (start < len && fc_isspace((unsigned char)s[start]))
          start++;
        if (start == 0) {
          setsvalue2s(L, ra, ts);
        }
        else {
          setsvalue2s(L, ra, luaS_newlstr(L, s + start, len - start));
        }
      }
      else
        return 0;
      break;
    }
    case FC_STRING_RTRIM: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttisstring(arg))) {
        TString *ts = tsvalue(arg);
        const char *s = getstr(ts);
        size_t len = tsslen(ts);
        size_t end = len;
        while (end > 0 && fc_isspace((unsigned char)s[end - 1]))
          end--;
        if (end == len) {
          setsvalue2s(L, ra, ts);
        }
        else {
          setsvalue2s(L, ra, luaS_newlstr(L, s, end));
        }
      }
      else
        return 0;
      break;
    }
    case FC_STRING_SPLIT: {
      TValue *arg1 = s2v(ra + 1), *arg2 = s2v(ra + 2);
      if (l_likely(ttisstring(arg1) && ttisstring(arg2))) {
        TString *ts = tsvalue(arg1), *td = tsvalue(arg2);
        const char *s = getstr(ts), *delim = getstr(td);
        size_t ls = tsslen(ts), ld = tsslen(td);
        Table *result = luaH_new(L);
        sethvalue2s(L, ra, result); /* root table immediately */
        lua_Integer idx = 1;
        if (ld == 0) {
          /* Empty delimiter: split into individual characters */
          for (size_t i = 0; i < ls; i++) {
            TString *ch = luaS_newlstr(L, s + i, 1);
            setsvalue2s(L, L->top.p, ch); /* root on stack */
            L->top.p++;
            TValue val;
            setsvalue(L, &val, ch);
            luaH_setint(L, result, idx++, &val);
            luaC_barrierback(L, obj2gco(result), &val);
            L->top.p--;
          }
        }
        else {
          const char *pos = s;
          const char *end = s + ls;
          while (pos <= end) {
            const char *found = fc_memfind(pos, (size_t)(end - pos), delim, ld);
            size_t seglen = found ? (size_t)(found - pos) : (size_t)(end - pos);
            TString *sub = luaS_newlstr(L, pos, seglen);
            setsvalue2s(L, L->top.p, sub); /* root on stack */
            L->top.p++;
            TValue val;
            setsvalue(L, &val, sub);
            luaH_setint(L, result, idx++, &val);
            luaC_barrierback(L, obj2gco(result), &val);
            L->top.p--;
            if (found)
              pos = found + ld;
            else
              break;
          }
        }
      }
      else
        return 0;
      break;
    }
    case FC_STRING_JOIN: {
      TValue *arg1 = s2v(ra + 1), *arg2 = s2v(ra + 2);
      if (l_likely(ttistable(arg1) && ttisstring(arg2))) {
        Table *t = hvalue(arg1);
        TString *sep = tsvalue(arg2);
        size_t lsep = tsslen(sep);
        lua_Unsigned len = luaH_getn(L, t);
        if (len == 0) {
          setsvalue2s(L, ra, luaS_newlstr(L, "", 0));
          break;
        }
        /* Pre-validate: all elements must be strings */
        size_t total = 0;
        for (lua_Unsigned i = 1; i <= len; i++) {
          TValue val;
          lu_byte tag = luaH_getint(t, (lua_Integer)i, &val);
          if (tagisempty(tag) || !ttisstring(&val))
            return 0; /* fall back to normal call */
          total += tsslen(tsvalue(&val));
        }
        if (len > 1)
          total += lsep * (size_t)(len - 1);
        /* Build result */
        if (total <= LUAI_MAXSHORTLEN) {
          /* Short string: use stack buffer */
          char buf[LUAI_MAXSHORTLEN + 1];
          size_t pos = 0;
          const char *sepstr = getstr(sep);
          for (lua_Unsigned i = 1; i <= len; i++) {
            if (i > 1) {
              memcpy(buf + pos, sepstr, lsep);
              pos += lsep;
            }
            TValue val;
            luaH_getint(t, (lua_Integer)i, &val);
            TString *elem = tsvalue(&val);
            memcpy(buf + pos, getstr(elem), tsslen(elem));
            pos += tsslen(elem);
          }
          setsvalue2s(L, ra, luaS_newlstr(L, buf, total));
        }
        else {
          /* Long string: write directly to string contents */
          TString *rs = luaS_createlngstrobj(L, total);
          setsvalue2s(L, ra, rs); /* root immediately */
          char *buf = getlngstr(rs);
          size_t pos = 0;
          const char *sepstr = getstr(sep);
          for (lua_Unsigned i = 1; i <= len; i++) {
            if (i > 1) {
              memcpy(buf + pos, sepstr, lsep);
              pos += lsep;
            }
            TValue val;
            luaH_getint(t, (lua_Integer)i, &val);
            TString *elem = tsvalue(&val);
            memcpy(buf + pos, getstr(elem), tsslen(elem));
            pos += tsslen(elem);
          }
          buf[total] = '\0';
        }
      }
      else
        return 0;
      break;
    }
    case FC_STRING_SUB: {
      TValue *arg1 = s2v(ra + 1), *arg2 = s2v(ra + 2), *arg3 = s2v(ra + 3);
      if (l_likely(ttisstring(arg1) && ttisinteger(arg2) &&
                   ttisinteger(arg3))) {
        TString *ts = tsvalue(arg1);
        const char *s = getstr(ts);
        size_t len = tsslen(ts);
        lua_Integer pi = ivalue(arg2);
        lua_Integer pj = ivalue(arg3);
        /* posrelatI for start (0 maps to 1) */
        size_t start = (pi > 0) ? (size_t)pi
                       : (pi == 0 || pi < -(lua_Integer)len)
                           ? 1
                           : len + (size_t)pi + 1;
        /* getendpos for end */
        size_t end = (pj > (lua_Integer)len)    ? len
                     : (pj >= 0)                ? (size_t)pj
                     : (pj < -(lua_Integer)len) ? 0
                                                : len + (size_t)pj + 1;
        if (start <= end) {
          setsvalue2s(L, ra, luaS_newlstr(L, s + start - 1, (end - start) + 1));
        }
        else {
          setsvalue2s(L, ra, luaS_newlstr(L, "", 0));
        }
      }
      else
        return 0;
      break;
    }
    case FC_STRING_BYTE: {
      TValue *arg1 = s2v(ra + 1), *arg2 = s2v(ra + 2);
      if (l_likely(ttisstring(arg1) && ttisinteger(arg2))) {
        TString *ts = tsvalue(arg1);
        size_t len = tsslen(ts);
        lua_Integer pi = ivalue(arg2);
        /* posrelatI (0 maps to 1) */
        size_t pos = (pi > 0) ? (size_t)pi
                     : (pi == 0 || pi < -(lua_Integer)len)
                         ? 1
                         : len + (size_t)pi + 1;
        if (pos >= 1 && pos <= len) {
          setivalue(s2v(ra), cast_uchar(getstr(ts)[pos - 1]));
        }
        else {
          setnilvalue(s2v(ra));
        }
      }
      else
        return 0;
      break;
    }
    case FC_STRING_CHAR: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttisinteger(arg))) {
        lua_Integer c = ivalue(arg);
        if (c >= 0 && c <= UCHAR_MAX) {
          char buf[1];
          buf[0] = cast_char(cast_uchar(c));
          setsvalue2s(L, ra, luaS_newlstr(L, buf, 1));
        }
        else
          return 0; /* out of range, fall back for error */
      }
      else
        return 0;
      break;
    }
    case FC_STRING_LOWER: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttisstring(arg))) {
        TString *ts = tsvalue(arg);
        const char *s = getstr(ts);
        size_t len = tsslen(ts);
        if (len <= LUAI_MAXSHORTLEN) {
          char buf[LUAI_MAXSHORTLEN + 1];
          for (size_t i = 0; i < len; i++)
            buf[i] = cast_char(tolower(cast_uchar(s[i])));
          setsvalue2s(L, ra, luaS_newlstr(L, buf, len));
        }
        else {
          TString *rs = luaS_createlngstrobj(L, len);
          setsvalue2s(L, ra, rs);
          char *buf = getlngstr(rs);
          for (size_t i = 0; i < len; i++)
            buf[i] = cast_char(tolower(cast_uchar(s[i])));
          buf[len] = '\0';
        }
      }
      else
        return 0;
      break;
    }
    case FC_STRING_UPPER: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttisstring(arg))) {
        TString *ts = tsvalue(arg);
        const char *s = getstr(ts);
        size_t len = tsslen(ts);
        if (len <= LUAI_MAXSHORTLEN) {
          char buf[LUAI_MAXSHORTLEN + 1];
          for (size_t i = 0; i < len; i++)
            buf[i] = cast_char(toupper(cast_uchar(s[i])));
          setsvalue2s(L, ra, luaS_newlstr(L, buf, len));
        }
        else {
          TString *rs = luaS_createlngstrobj(L, len);
          setsvalue2s(L, ra, rs);
          char *buf = getlngstr(rs);
          for (size_t i = 0; i < len; i++)
            buf[i] = cast_char(toupper(cast_uchar(s[i])));
          buf[len] = '\0';
        }
      }
      else
        return 0;
      break;
    }
    case FC_STRING_REVERSE: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttisstring(arg))) {
        TString *ts = tsvalue(arg);
        const char *s = getstr(ts);
        size_t len = tsslen(ts);
        if (len <= LUAI_MAXSHORTLEN) {
          char buf[LUAI_MAXSHORTLEN + 1];
          for (size_t i = 0; i < len; i++)
            buf[i] = s[len - 1 - i];
          setsvalue2s(L, ra, luaS_newlstr(L, buf, len));
        }
        else {
          TString *rs = luaS_createlngstrobj(L, len);
          setsvalue2s(L, ra, rs);
          char *buf = getlngstr(rs);
          for (size_t i = 0; i < len; i++)
            buf[i] = s[len - 1 - i];
          buf[len] = '\0';
        }
      }
      else
        return 0;
      break;
    }
    /* ---- New table fastcalls ---- */
    case FC_TABLE_SUM: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttistable(arg))) {
        Table *t = hvalue(arg);
        lua_Unsigned len = luaH_getn(L, t);
        lua_Number sum = 0;
        for (lua_Unsigned i = 1; i <= len; i++) {
          TValue val;
          lu_byte tag = luaH_getint(t, (lua_Integer)i, &val);
          if (!tagisempty(tag)) {
            if (ttisinteger(&val))
              sum += cast_num(ivalue(&val));
            else if (ttisfloat(&val))
              sum += fltvalue(&val);
          }
        }
        setfltvalue(s2v(ra), sum);
      }
      else
        return 0;
      break;
    }
    case FC_TABLE_MEAN: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttistable(arg))) {
        Table *t = hvalue(arg);
        lua_Unsigned len = luaH_getn(L, t);
        lua_Number sum = 0;
        lua_Integer count = 0;
        for (lua_Unsigned i = 1; i <= len; i++) {
          TValue val;
          lu_byte tag = luaH_getint(t, (lua_Integer)i, &val);
          if (!tagisempty(tag)) {
            if (ttisinteger(&val)) {
              sum += cast_num(ivalue(&val));
              count++;
            }
            else if (ttisfloat(&val)) {
              sum += fltvalue(&val);
              count++;
            }
          }
        }
        if (count == 0) {
          setfltvalue(s2v(ra), (lua_Number)NAN);
        }
        else {
          setfltvalue(s2v(ra), sum / (lua_Number)count);
        }
      }
      else
        return 0;
      break;
    }
    case FC_TABLE_MEDIAN: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttistable(arg))) {
        Table *t = hvalue(arg);
        lua_Unsigned len = luaH_getn(L, t);
        /* First pass: count numeric values */
        lua_Integer count = 0;
        for (lua_Unsigned i = 1; i <= len; i++) {
          TValue val;
          lu_byte tag = luaH_getint(t, (lua_Integer)i, &val);
          if (!tagisempty(tag) && (ttisinteger(&val) || ttisfloat(&val)))
            count++;
        }
        if (count == 0) {
          setfltvalue(s2v(ra), (lua_Number)NAN);
          break;
        }
        /* Collect numeric values into temp array */
        lua_Number *vals = luaM_newvector(L, count, lua_Number);
        lua_Integer j = 0;
        for (lua_Unsigned i = 1; i <= len; i++) {
          TValue val;
          lu_byte tag = luaH_getint(t, (lua_Integer)i, &val);
          if (!tagisempty(tag)) {
            if (ttisinteger(&val))
              vals[j++] = cast_num(ivalue(&val));
            else if (ttisfloat(&val))
              vals[j++] = fltvalue(&val);
          }
        }
        qsort(vals, (size_t)count, sizeof(lua_Number), fc_numcmp);
        lua_Number med;
        if (count % 2 == 1)
          med = vals[count / 2];
        else
          med = (vals[count / 2 - 1] + vals[count / 2]) / 2.0;
        luaM_freearray(L, vals, count);
        setfltvalue(s2v(ra), med);
      }
      else
        return 0;
      break;
    }
    case FC_TABLE_STDEV: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttistable(arg))) {
        Table *t = hvalue(arg);
        lua_Unsigned len = luaH_getn(L, t);
        /* Welford's online algorithm: single pass */
        lua_Number mean = 0, M2 = 0;
        lua_Integer count = 0;
        for (lua_Unsigned i = 1; i <= len; i++) {
          TValue val;
          lu_byte tag = luaH_getint(t, (lua_Integer)i, &val);
          if (!tagisempty(tag)) {
            lua_Number x;
            if (ttisinteger(&val))
              x = cast_num(ivalue(&val));
            else if (ttisfloat(&val))
              x = fltvalue(&val);
            else
              continue;
            count++;
            lua_Number delta = x - mean;
            mean += delta / (lua_Number)count;
            lua_Number delta2 = x - mean;
            M2 += delta * delta2;
          }
        }
        if (count == 0) {
          setfltvalue(s2v(ra), (lua_Number)NAN);
          break;
        }
        setfltvalue(s2v(ra), l_mathop(sqrt)(M2 / (lua_Number)count));
      }
      else
        return 0;
      break;
    }
    case FC_TABLE_TRANSPOSE: {
      TValue *arg = s2v(ra + 1);
      if (l_likely(ttistable(arg))) {
        Table *outer = hvalue(arg);
        lua_Unsigned rows = luaH_getn(L, outer);
        if (rows == 0) {
          Table *res = luaH_new(L);
          sethvalue2s(L, ra, res);
          break;
        }
        /* Get first row, verify it's a table */
        TValue firstrow;
        lu_byte tag = luaH_getint(outer, 1, &firstrow);
        if (tagisempty(tag) || !ttistable(&firstrow))
          return 0;
        lua_Unsigned cols = luaH_getn(L, hvalue(&firstrow));
        /* Validate all rows have same column count */
        for (lua_Unsigned i = 2; i <= rows; i++) {
          TValue row;
          tag = luaH_getint(outer, (lua_Integer)i, &row);
          if (tagisempty(tag) || !ttistable(&row))
            return 0;
          if (luaH_getn(L, hvalue(&row)) != cols)
            return 0;
        }
        /* Build transposed result */
        Table *result = luaH_new(L);
        sethvalue2s(L, ra, result); /* root result table */
        for (lua_Unsigned j = 1; j <= cols; j++) {
          Table *newrow = luaH_new(L);
          sethvalue2s(L, L->top.p, newrow); /* root temporarily */
          L->top.p++;
          TValue rowval;
          sethvalue(L, &rowval, newrow);
          luaH_setint(L, result, (lua_Integer)j, &rowval);
          luaC_barrierback(L, obj2gco(result), &rowval);
          L->top.p--;
          /* Populate newrow (now reachable from result) */
          for (lua_Unsigned i = 1; i <= rows; i++) {
            TValue oldrow;
            luaH_getint(outer, (lua_Integer)i, &oldrow);
            TValue elem;
            lu_byte etag = luaH_getint(hvalue(&oldrow), (lua_Integer)j, &elem);
            if (tagisempty(etag))
              setnilvalue(&elem);
            luaH_setint(L, newrow, (lua_Integer)i, &elem);
            luaC_barrierback(L, obj2gco(newrow), &elem);
          }
        }
      }
      else
        return 0;
      break;
    }
    case FC_TABLE_RESHAPE: {
      TValue *arg1 = s2v(ra + 1), *arg2 = s2v(ra + 2), *arg3 = s2v(ra + 3);
      if (l_likely(ttistable(arg1) && ttisinteger(arg2) && ttisinteger(arg3))) {
        Table *t = hvalue(arg1);
        lua_Integer nrows = ivalue(arg2), ncols = ivalue(arg3);
        if (nrows <= 0 || ncols <= 0)
          return 0;
        lua_Unsigned len = luaH_getn(L, t);
        if ((lua_Unsigned)nrows > len / (lua_Unsigned)ncols)
          return 0;
        if ((lua_Unsigned)nrows * (lua_Unsigned)ncols != len)
          return 0;
        Table *result = luaH_new(L);
        sethvalue2s(L, ra, result); /* root result table */
        for (lua_Integer r = 1; r <= nrows; r++) {
          Table *row = luaH_new(L);
          sethvalue2s(L, L->top.p, row); /* root temporarily */
          L->top.p++;
          TValue rowval;
          sethvalue(L, &rowval, row);
          luaH_setint(L, result, r, &rowval);
          luaC_barrierback(L, obj2gco(result), &rowval);
          L->top.p--;
          /* Populate row (now reachable from result) */
          for (lua_Integer c = 1; c <= ncols; c++) {
            TValue elem;
            lu_byte etag = luaH_getint(t, (r - 1) * ncols + c, &elem);
            if (tagisempty(etag))
              setnilvalue(&elem);
            luaH_setint(L, row, c, &elem);
            luaC_barrierback(L, obj2gco(row), &elem);
          }
        }
      }
      else
        return 0;
      break;
    }
    case FC_VECTOR_CREATE: {
      TValue *arg = s2v(ra + 1);
      if (!ttisinteger(arg))
        return 0;
      lua_Integer cap = ivalue(arg);
      if (cap < 0)
        return 0;
      Vector *v = luaV_newvec(L, (size_t)cap, 0);
      setvecvalue2s(L, ra, v);
      break;
    }
    case FC_VECTOR_CLONE: {
      TValue *arg = s2v(ra + 1);
      if (!ttisvector(arg))
        return 0;
      Vector *clone = luaV_clone(L, vecvalue(arg));
      setvecvalue2s(L, ra, clone);
      break;
    }
    case FC_VECTOR_SIZE: {
      TValue *arg = s2v(ra + 1);
      if (!ttisvector(arg))
        return 0;
      setivalue(s2v(ra), (lua_Integer)vecvalue(arg)->len);
      break;
    }
    case FC_VECTOR_RESIZE: {
      TValue *arg1 = s2v(ra + 1), *arg2 = s2v(ra + 2);
      if (!ttisvector(arg1) || !ttisinteger(arg2))
        return 0;
      lua_Integer newsize = ivalue(arg2);
      if (newsize < 0)
        return 0;
      luaV_resize(L, vecvalue(arg1), (size_t)newsize);
      setnilvalue(s2v(ra));
      break;
    }
    case FC_UTF8_LEN: {
      TValue *arg = s2v(ra + 1);
      if (!ttisstring(arg))
        return 0;
      TString *ts = tsvalue(arg);
      const char *s = getstr(ts);
      size_t len = tsslen(ts);
      lua_Integer n = 0;
      size_t pos = 0;
      while (pos < len) {
        const char *next = fc_utf8_decode(s + pos, NULL, 1);
        if (next == NULL)
          return 0; /* invalid: fall back for nil + position */
        pos = (size_t)(next - s);
        n++;
      }
      setivalue(s2v(ra), n);
      break;
    }
    case FC_UTF8_CODEPOINT: {
      TValue *arg = s2v(ra + 1);
      if (!ttisstring(arg))
        return 0;
      TString *ts = tsvalue(arg);
      const char *s = getstr(ts);
      size_t len = tsslen(ts);
      if (len == 0)
        return 0;
      l_uint32 code;
      if (fc_utf8_decode(s, &code, 1) == NULL)
        return 0;
      setivalue(s2v(ra), (lua_Integer)code);
      break;
    }
    case FC_UTF8_CHAR: {
      TValue *arg = s2v(ra + 1);
      if (!ttisinteger(arg))
        return 0;
      lua_Integer code = ivalue(arg);
      if (code < 0 || (lua_Unsigned)code > FC_MAXUTF)
        return 0;
      /* Encode to buffer using lua_pushfstring's %U format */
      char buf[8];
      int len;
      l_uint32 x = (l_uint32)code;
      if (x < 0x80) {
        buf[0] = (char)x;
        len = 1;
      }
      else if (x < 0x800) {
        buf[0] = (char)(0xC0 | (x >> 6));
        buf[1] = (char)(0x80 | (x & 0x3F));
        len = 2;
      }
      else if (x < 0x10000) {
        buf[0] = (char)(0xE0 | (x >> 12));
        buf[1] = (char)(0x80 | ((x >> 6) & 0x3F));
        buf[2] = (char)(0x80 | (x & 0x3F));
        len = 3;
      }
      else if (x < 0x200000) {
        buf[0] = (char)(0xF0 | (x >> 18));
        buf[1] = (char)(0x80 | ((x >> 12) & 0x3F));
        buf[2] = (char)(0x80 | ((x >> 6) & 0x3F));
        buf[3] = (char)(0x80 | (x & 0x3F));
        len = 4;
      }
      else if (x < 0x4000000) {
        buf[0] = (char)(0xF8 | (x >> 24));
        buf[1] = (char)(0x80 | ((x >> 18) & 0x3F));
        buf[2] = (char)(0x80 | ((x >> 12) & 0x3F));
        buf[3] = (char)(0x80 | ((x >> 6) & 0x3F));
        buf[4] = (char)(0x80 | (x & 0x3F));
        len = 5;
      }
      else {
        buf[0] = (char)(0xFC | (x >> 30));
        buf[1] = (char)(0x80 | ((x >> 24) & 0x3F));
        buf[2] = (char)(0x80 | ((x >> 18) & 0x3F));
        buf[3] = (char)(0x80 | ((x >> 12) & 0x3F));
        buf[4] = (char)(0x80 | ((x >> 6) & 0x3F));
        buf[5] = (char)(0x80 | (x & 0x3F));
        len = 6;
      }
      setsvalue2s(L, ra, luaS_newlstr(L, buf, (size_t)len));
      break;
    }
    case FC_UTF8_OFFSET: {
      TValue *arg1 = s2v(ra + 1), *arg2 = s2v(ra + 2);
      if (!ttisstring(arg1) || !ttisinteger(arg2))
        return 0;
      TString *ts = tsvalue(arg1);
      const char *s = getstr(ts);
      size_t len = tsslen(ts);
      lua_Integer n = ivalue(arg2);
      /* Only handle simple 2-arg case (no 3rd arg) */
      lua_Integer posi;
      if (n >= 0)
        posi = 0; /* 1-based → 0-based: start at 0 */
      else
        posi = (lua_Integer)len;
      /* Check posi is not on a continuation byte */
      if (posi > 0 && posi < (lua_Integer)len &&
          ((unsigned char)s[posi] & 0xC0) == 0x80)
        return 0; /* fall back */
      if (n == 0) {
        /* Find beginning of current byte sequence */
        while (posi > 0 && ((unsigned char)s[posi] & 0xC0) == 0x80)
          posi--;
      }
      else if (n > 0) {
        n--; /* do not move for 1st character */
        while (n > 0 && posi < (lua_Integer)len) {
          do {
            posi++;
          } while (posi < (lua_Integer)len &&
                   ((unsigned char)s[posi] & 0xC0) == 0x80);
          n--;
        }
      }
      else { /* n < 0 */
        while (n < 0 && posi > 0) {
          do {
            posi--;
          } while (posi > 0 && ((unsigned char)s[posi] & 0xC0) == 0x80);
          n++;
        }
      }
      if (n != 0)
        return 0;                   /* did not find given character */
      setivalue(s2v(ra), posi + 1); /* 1-based */
      break;
    }
    default: return 0;
  }
  return 1;
}


/*
** Pre-register module/function name strings for all fastcall entries.
** Called from f_luaopen after luaS_init.
*/
void luaF_initfastcalls(lua_State *L) {
  global_State *g = G(L);
  int i;
  /* Zero out the table */
  for (i = 0; i < FC_COUNT; i++) {
    g->fastcall_table[i].module_name = NULL;
    g->fastcall_table[i].func_name = NULL;
    g->fastcall_table[i].orig_func = NULL;
    g->fastcall_table[i].nargs = 0;
  }
  /*
  ** Pre-intern result strings. Use fc_newfix which safely skips
  ** luaC_fix for strings already on fixedgc (e.g., reserved words
  ** "nil"/"true"/"false" will be fixed later by luaX_init; GC is
  ** stopped during init so unfixed strings are safe until then).
  */
  fc_str_integer = fc_newfix(L, "integer");
  fc_str_float = fc_newfix(L, "float");
  fc_str_nil = fc_newfix(L, "nil");
  fc_str_true = fc_newfix(L, "true");
  fc_str_false = fc_newfix(L, "false");
  fc_str___metatable = fc_newfix(L, "__metatable");
  /* Pre-intern type name strings for FC_TYPE */
  for (i = 0; i < LUA_TOTALTYPES; i++) {
    if (luaT_typenames_[i] != NULL)
      fc_typenames[i] = fc_newfix(L, luaT_typenames_[i]);
    else
      fc_typenames[i] = NULL;
  }

/* Helper macro to register one fastcall name entry */
#define FC_INIT(id, mod, name)               \
  g->fastcall_table[id].module_name = (mod); \
  g->fastcall_table[id].func_name = fc_newfix(L, name)

  /* Base library functions (no module) */
  FC_INIT(FC_TYPE, NULL, "type");
  FC_INIT(FC_RAWLEN, NULL, "rawlen");
  FC_INIT(FC_RAWGET, NULL, "rawget");
  FC_INIT(FC_RAWSET, NULL, "rawset");
  FC_INIT(FC_RAWEQUAL, NULL, "rawequal");
  FC_INIT(FC_ASSERT, NULL, "assert");
  FC_INIT(FC_GETMETATABLE, NULL, "getmetatable");
  FC_INIT(FC_SETMETATABLE, NULL, "setmetatable");
  FC_INIT(FC_TONUMBER, NULL, "tonumber");
  FC_INIT(FC_TOSTRING, NULL, "tostring");
  /* Math library functions */
  {
    TString *mod = fc_newfix(L, "math");
    FC_INIT(FC_MATH_ABS, mod, "abs");
    FC_INIT(FC_MATH_MAX, mod, "max");
    FC_INIT(FC_MATH_MIN, mod, "min");
    FC_INIT(FC_MATH_CEIL, mod, "ceil");
    FC_INIT(FC_MATH_FLOOR, mod, "floor");
    FC_INIT(FC_MATH_SQRT, mod, "sqrt");
    FC_INIT(FC_MATH_SIN, mod, "sin");
    FC_INIT(FC_MATH_COS, mod, "cos");
    FC_INIT(FC_MATH_TAN, mod, "tan");
    FC_INIT(FC_MATH_ASIN, mod, "asin");
    FC_INIT(FC_MATH_ACOS, mod, "acos");
    FC_INIT(FC_MATH_ATAN, mod, "atan");
    FC_INIT(FC_MATH_EXP, mod, "exp");
    FC_INIT(FC_MATH_LOG, mod, "log");
    FC_INIT(FC_MATH_DEG, mod, "deg");
    FC_INIT(FC_MATH_RAD, mod, "rad");
    FC_INIT(FC_MATH_FMOD, mod, "fmod");
    FC_INIT(FC_MATH_ULT, mod, "ult");
    FC_INIT(FC_MATH_TOINTEGER, mod, "tointeger");
    FC_INIT(FC_MATH_TYPE, mod, "type");
    FC_INIT(FC_MATH_LDEXP, mod, "ldexp");
  }
  /* String library functions */
  {
    TString *mod = fc_newfix(L, "string");
    FC_INIT(FC_STRING_LEN, mod, "len");
    FC_INIT(FC_STRING_TRIM, mod, "trim");
    FC_INIT(FC_STRING_LTRIM, mod, "ltrim");
    FC_INIT(FC_STRING_RTRIM, mod, "rtrim");
    FC_INIT(FC_STRING_SPLIT, mod, "split");
    FC_INIT(FC_STRING_JOIN, mod, "join");
    FC_INIT(FC_STRING_SUB, mod, "sub");
    FC_INIT(FC_STRING_BYTE, mod, "byte");
    FC_INIT(FC_STRING_CHAR, mod, "char");
    FC_INIT(FC_STRING_LOWER, mod, "lower");
    FC_INIT(FC_STRING_UPPER, mod, "upper");
    FC_INIT(FC_STRING_REVERSE, mod, "reverse");
  }
  /* Table library functions */
  {
    TString *mod = fc_newfix(L, "table");
    FC_INIT(FC_TABLE_SUM, mod, "sum");
    FC_INIT(FC_TABLE_MEAN, mod, "mean");
    FC_INIT(FC_TABLE_MEDIAN, mod, "median");
    FC_INIT(FC_TABLE_STDEV, mod, "stdev");
    FC_INIT(FC_TABLE_TRANSPOSE, mod, "transpose");
    FC_INIT(FC_TABLE_RESHAPE, mod, "reshape");
  }
  /* Vector library functions */
  {
    TString *mod = fc_newfix(L, "vector");
    FC_INIT(FC_VECTOR_CREATE, mod, "create");
    FC_INIT(FC_VECTOR_CLONE, mod, "clone");
    FC_INIT(FC_VECTOR_SIZE, mod, "size");
    FC_INIT(FC_VECTOR_RESIZE, mod, "resize");
  }
  /* UTF-8 library functions */
  {
    TString *mod = fc_newfix(L, "utf8");
    FC_INIT(FC_UTF8_LEN, mod, "len");
    FC_INIT(FC_UTF8_CODEPOINT, mod, "codepoint");
    FC_INIT(FC_UTF8_CHAR, mod, "char");
    FC_INIT(FC_UTF8_OFFSET, mod, "offset");
  }
#undef FC_INIT
}


/*
** Register the original C function for a fastcall entry.
** Called from luaopen_* functions.
*/
void luaF_registerfastcall(lua_State *L, int id, lua_CFunction func,
                           int nargs) {
  global_State *g = G(L);
  lua_assert(id >= 0 && id < FC_COUNT);
  g->fastcall_table[id].orig_func = func;
  g->fastcall_table[id].nargs = nargs;
}


/*
** Enable fastcall detection for compile-only mode (e.g., lusc -f).
** Sets nargs so the compiler can detect patterns, without needing
** the actual C function pointers (those are only needed at runtime).
*/
void luaF_enablefastcalls(lua_State *L) {
  global_State *g = G(L);
  g->fastcall_table[FC_TYPE].nargs = 1;
  g->fastcall_table[FC_RAWLEN].nargs = 1;
  g->fastcall_table[FC_RAWGET].nargs = 2;
  g->fastcall_table[FC_RAWSET].nargs = 3;
  g->fastcall_table[FC_RAWEQUAL].nargs = 2;
  g->fastcall_table[FC_ASSERT].nargs = 1;
  g->fastcall_table[FC_GETMETATABLE].nargs = 1;
  g->fastcall_table[FC_SETMETATABLE].nargs = 2;
  g->fastcall_table[FC_TONUMBER].nargs = 1;
  g->fastcall_table[FC_TOSTRING].nargs = 1;
  g->fastcall_table[FC_MATH_ABS].nargs = 1;
  g->fastcall_table[FC_MATH_MAX].nargs = 2;
  g->fastcall_table[FC_MATH_MIN].nargs = 2;
  g->fastcall_table[FC_MATH_CEIL].nargs = 1;
  g->fastcall_table[FC_MATH_FLOOR].nargs = 1;
  g->fastcall_table[FC_MATH_SQRT].nargs = 1;
  g->fastcall_table[FC_MATH_SIN].nargs = 1;
  g->fastcall_table[FC_MATH_COS].nargs = 1;
  g->fastcall_table[FC_MATH_TAN].nargs = 1;
  g->fastcall_table[FC_MATH_ASIN].nargs = 1;
  g->fastcall_table[FC_MATH_ACOS].nargs = 1;
  g->fastcall_table[FC_MATH_ATAN].nargs = 1;
  g->fastcall_table[FC_MATH_EXP].nargs = 1;
  g->fastcall_table[FC_MATH_LOG].nargs = 1;
  g->fastcall_table[FC_MATH_DEG].nargs = 1;
  g->fastcall_table[FC_MATH_RAD].nargs = 1;
  g->fastcall_table[FC_MATH_FMOD].nargs = 2;
  g->fastcall_table[FC_MATH_ULT].nargs = 2;
  g->fastcall_table[FC_MATH_TOINTEGER].nargs = 1;
  g->fastcall_table[FC_MATH_TYPE].nargs = 1;
  g->fastcall_table[FC_MATH_LDEXP].nargs = 2;
  g->fastcall_table[FC_STRING_LEN].nargs = 1;
  g->fastcall_table[FC_STRING_TRIM].nargs = 1;
  g->fastcall_table[FC_STRING_LTRIM].nargs = 1;
  g->fastcall_table[FC_STRING_RTRIM].nargs = 1;
  g->fastcall_table[FC_STRING_SPLIT].nargs = 2;
  g->fastcall_table[FC_STRING_JOIN].nargs = 2;
  g->fastcall_table[FC_STRING_SUB].nargs = 3;
  g->fastcall_table[FC_STRING_BYTE].nargs = 2;
  g->fastcall_table[FC_STRING_CHAR].nargs = 1;
  g->fastcall_table[FC_STRING_LOWER].nargs = 1;
  g->fastcall_table[FC_STRING_UPPER].nargs = 1;
  g->fastcall_table[FC_STRING_REVERSE].nargs = 1;
  g->fastcall_table[FC_TABLE_SUM].nargs = 1;
  g->fastcall_table[FC_TABLE_MEAN].nargs = 1;
  g->fastcall_table[FC_TABLE_MEDIAN].nargs = 1;
  g->fastcall_table[FC_TABLE_STDEV].nargs = 1;
  g->fastcall_table[FC_TABLE_TRANSPOSE].nargs = 1;
  g->fastcall_table[FC_TABLE_RESHAPE].nargs = 3;
  g->fastcall_table[FC_VECTOR_CREATE].nargs = 1;
  g->fastcall_table[FC_VECTOR_CLONE].nargs = 1;
  g->fastcall_table[FC_VECTOR_SIZE].nargs = 1;
  g->fastcall_table[FC_VECTOR_RESIZE].nargs = 2;
  g->fastcall_table[FC_UTF8_LEN].nargs = 1;
  g->fastcall_table[FC_UTF8_CODEPOINT].nargs = 1;
  g->fastcall_table[FC_UTF8_CHAR].nargs = 1;
  g->fastcall_table[FC_UTF8_OFFSET].nargs = 2;
}


/*
** Look up a fastcall by interned string pointers and argument count.
** Returns the fastcall ID, or -1 if not found.
** Uses pointer equality (interned strings).
*/
int luaF_findfastcall(global_State *g, TString *module, TString *func,
                      int nargs) {
  int i;
  for (i = 0; i < FC_COUNT; i++) {
    FastCallEntry *fc = &g->fastcall_table[i];
    if (fc->func_name == NULL)
      continue;
    /* Module must match (both NULL for base, or same pointer) */
    if (fc->module_name != module)
      continue;
    /* Function name must match (pointer equality for interned strings) */
    if (fc->func_name != func)
      continue;
    /* Argument count must match */
    if (fc->nargs != nargs)
      continue;
    return i;
  }
  return -1;
}
