/*
** $Id: ltablib.c $
** Library for Table Manipulation
** See Copyright Notice in lua.h
*/

#define ltablib_c
#define LUA_LIB

#include "lprefix.h"


#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"
#include "llimits.h"


/*
** Operations that an object must define to mimic a table
** (some functions only need some of them)
*/
#define TAB_R 1                /* read */
#define TAB_W 2                /* write */
#define TAB_L 4                /* length */
#define TAB_RW (TAB_R | TAB_W) /* read/write */


#define aux_getn(L, n, w) (checktab(L, n, (w) | TAB_L), luaL_len(L, n))


static int checkfield(lua_State *L, const char *key, int n) {
  lua_pushstring(L, key);
  return (lua_rawget(L, -n) != LUA_TNIL);
}


/*
** Check that 'arg' either is a table or can behave like one (that is,
** has a metatable with the required metamethods)
*/
static void checktab(lua_State *L, int arg, int what) {
  if (lua_type(L, arg) != LUA_TTABLE) { /* is it not a table? */
    int n = 1;                          /* number of elements to pop */
    if (lua_getmetatable(L, arg) &&     /* must have metatable */
        (!(what & TAB_R) || checkfield(L, "__index", ++n)) &&
        (!(what & TAB_W) || checkfield(L, "__newindex", ++n)) &&
        (!(what & TAB_L) || checkfield(L, "__len", ++n))) {
      lua_pop(L, n); /* pop metatable and tested metamethods */
    }
    else
      luaL_checktype(L, arg, LUA_TTABLE); /* force an error */
  }
}


static int tcreate(lua_State *L) {
  lua_Unsigned sizeseq = (lua_Unsigned)luaL_checkinteger(L, 1);
  lua_Unsigned sizerest = (lua_Unsigned)luaL_optinteger(L, 2, 0);
  luaL_argcheck(L, sizeseq <= cast_uint(INT_MAX), 1, "out of range");
  luaL_argcheck(L, sizerest <= cast_uint(INT_MAX), 2, "out of range");
  lua_createtable(L, cast_int(sizeseq), cast_int(sizerest));
  return 1;
}


static int tinsert(lua_State *L) {
  lua_Integer pos; /* where to insert new element */
  lua_Integer e = aux_getn(L, 1, TAB_RW);
  e = luaL_intop(+, e, 1); /* first empty element */
  switch (lua_gettop(L)) {
    case 2: {  /* called with only 2 arguments */
      pos = e; /* insert new element at the end */
      break;
    }
    case 3: {
      lua_Integer i;
      pos = luaL_checkinteger(L, 2); /* 2nd argument is the position */
      /* check whether 'pos' is in [1, e] */
      luaL_argcheck(L, (lua_Unsigned)pos - 1u < (lua_Unsigned)e, 2,
                    "position out of bounds");
      for (i = e; i > pos; i--) { /* move up elements */
        lua_geti(L, 1, i - 1);
        lua_seti(L, 1, i); /* t[i] = t[i - 1] */
      }
      break;
    }
    default: {
      return luaL_error(L, "wrong number of arguments to 'insert'");
    }
  }
  lua_seti(L, 1, pos); /* t[pos] = v */
  return 0;
}


static int tremove(lua_State *L) {
  lua_Integer size = aux_getn(L, 1, TAB_RW);
  lua_Integer pos = luaL_optinteger(L, 2, size);
  if (pos != size) /* validate 'pos' if given */
    /* check whether 'pos' is in [1, size + 1] */
    luaL_argcheck(L, (lua_Unsigned)pos - 1u <= (lua_Unsigned)size, 2,
                  "position out of bounds");
  lua_geti(L, 1, pos); /* result = t[pos] */
  for (; pos < size; pos++) {
    lua_geti(L, 1, pos + 1);
    lua_seti(L, 1, pos); /* t[pos] = t[pos + 1] */
  }
  lua_pushnil(L);
  lua_seti(L, 1, pos); /* remove entry t[pos] */
  return 1;
}


/*
** Copy elements (1[f], ..., 1[e]) into (tt[t], tt[t+1], ...). Whenever
** possible, copy in increasing order, which is better for rehashing.
** "possible" means destination after original range, or smaller
** than origin, or copying to another table.
*/
static int tmove(lua_State *L) {
  lua_Integer f = luaL_checkinteger(L, 2);
  lua_Integer e = luaL_checkinteger(L, 3);
  lua_Integer t = luaL_checkinteger(L, 4);
  int tt = !lua_isnoneornil(L, 5) ? 5 : 1; /* destination table */
  checktab(L, 1, TAB_R);
  checktab(L, tt, TAB_W);
  if (e >= f) { /* otherwise, nothing to move */
    lua_Integer n, i;
    luaL_argcheck(L, f > 0 || e < LUA_MAXINTEGER + f, 3,
                  "too many elements to move");
    n = e - f + 1; /* number of elements to move */
    luaL_argcheck(L, t <= LUA_MAXINTEGER - n + 1, 4, "destination wrap around");
    if (t > e || t <= f || (tt != 1 && !lua_compare(L, 1, tt, LUA_OPEQ))) {
      for (i = 0; i < n; i++) {
        lua_geti(L, 1, f + i);
        lua_seti(L, tt, t + i);
      }
    }
    else {
      for (i = n - 1; i >= 0; i--) {
        lua_geti(L, 1, f + i);
        lua_seti(L, tt, t + i);
      }
    }
  }
  lua_pushvalue(L, tt); /* return destination table */
  return 1;
}


static void addfield(lua_State *L, luaL_Buffer *b, lua_Integer i) {
  lua_geti(L, 1, i);
  if (l_unlikely(!lua_isstring(L, -1)))
    luaL_error(L, "invalid value (%s) at index %I in table for 'concat'",
               luaL_typename(L, -1), (LUAI_UACINT)i);
  luaL_addvalue(b);
}


static int tconcat(lua_State *L) {
  luaL_Buffer b;
  lua_Integer last = aux_getn(L, 1, TAB_R);
  size_t lsep;
  const char *sep = luaL_optlstring(L, 2, "", &lsep);
  lua_Integer i = luaL_optinteger(L, 3, 1);
  last = luaL_optinteger(L, 4, last);
  luaL_buffinit(L, &b);
  for (; i < last; i++) {
    addfield(L, &b, i);
    luaL_addlstring(&b, sep, lsep);
  }
  if (i == last) /* add last value (if interval was not empty) */
    addfield(L, &b, i);
  luaL_pushresult(&b);
  return 1;
}


/*
** {======================================================
** Pack/unpack
** =======================================================
*/

static int tpack(lua_State *L) {
  int i;
  int n = lua_gettop(L);    /* number of elements to pack */
  lua_createtable(L, n, 1); /* create result table */
  lua_insert(L, 1);         /* put it at index 1 */
  for (i = n; i >= 1; i--)  /* assign elements */
    lua_seti(L, 1, i);
  lua_pushinteger(L, n);
  lua_setfield(L, 1, "n"); /* t.n = number of elements */
  return 1;                /* return table */
}


static int tunpack(lua_State *L) {
  lua_Unsigned n;
  lua_Integer i = luaL_optinteger(L, 2, 1);
  lua_Integer e = luaL_opt(L, luaL_checkinteger, 3, luaL_len(L, 1));
  if (i > e)
    return 0;                      /* empty range */
  n = l_castS2U(e) - l_castS2U(i); /* number of elements minus 1 */
  if (l_unlikely(n >= (unsigned int)INT_MAX || !lua_checkstack(L, (int)(++n))))
    return luaL_error(L, "too many results to unpack");
  for (; i < e; i++) { /* push arg[i..e - 1] (to avoid overflows) */
    lua_geti(L, 1, i);
  }
  lua_geti(L, 1, e); /* push last element */
  return (int)n;
}

/* }====================================================== */


/*
** {======================================================
** Quicksort
** (based on 'Algorithms in MODULA-3', Robert Sedgewick;
**  Addison-Wesley, 1993.)
** =======================================================
*/


/*
** Type for array indices. These indices are always limited by INT_MAX,
** so it is safe to cast them to lua_Integer even for Lua 32 bits.
*/
typedef unsigned int IdxT;


/* Versions of lua_seti/lua_geti specialized for IdxT */
#define geti(L, idt, idx) lua_geti(L, idt, l_castU2S(idx))
#define seti(L, idt, idx) lua_seti(L, idt, l_castU2S(idx))


/*
** Produce a "random" 'unsigned int' to randomize pivot choice. This
** macro is used only when 'sort' detects a big imbalance in the result
** of a partition. (If you don't want/need this "randomness", ~0 is a
** good choice.)
*/
#if !defined(l_randomizePivot)
#define l_randomizePivot(L) luaL_makeseed(L)
#endif /* } */


/* arrays larger than 'RANLIMIT' may use randomized pivots */
#define RANLIMIT 100u


static void set2(lua_State *L, IdxT i, IdxT j) {
  seti(L, 1, i);
  seti(L, 1, j);
}


/*
** Return true iff value at stack index 'a' is less than the value at
** index 'b' (according to the order of the sort).
*/
static int sort_comp(lua_State *L, int a, int b) {
  if (lua_isnil(L, 2))                     /* no function? */
    return lua_compare(L, a, b, LUA_OPLT); /* a < b */
  else {                                   /* function */
    int res;
    lua_pushvalue(L, 2);        /* push function */
    lua_pushvalue(L, a - 1);    /* -1 to compensate function */
    lua_pushvalue(L, b - 2);    /* -2 to compensate function and 'a' */
    lua_call(L, 2, 1);          /* call function */
    res = lua_toboolean(L, -1); /* get result */
    lua_pop(L, 1);              /* pop result */
    return res;
  }
}


/*
** Does the partition: Pivot P is at the top of the stack.
** precondition: a[lo] <= P == a[up-1] <= a[up],
** so it only needs to do the partition from lo + 1 to up - 2.
** Pos-condition: a[lo .. i - 1] <= a[i] == P <= a[i + 1 .. up]
** returns 'i'.
*/
static IdxT partition(lua_State *L, IdxT lo, IdxT up) {
  IdxT i = lo;     /* will be incremented before first use */
  IdxT j = up - 1; /* will be decremented before first use */
  /* loop invariant: a[lo .. i] <= P <= a[j .. up] */
  for (;;) {
    /* next loop: repeat ++i while a[i] < P */
    while ((void)geti(L, 1, ++i), sort_comp(L, -1, -2)) {
      if (l_unlikely(i == up - 1)) /* a[up - 1] < P == a[up - 1] */
        luaL_error(L, "invalid order function for sorting");
      lua_pop(L, 1); /* remove a[i] */
    }
    /* after the loop, a[i] >= P and a[lo .. i - 1] < P  (a) */
    /* next loop: repeat --j while P < a[j] */
    while ((void)geti(L, 1, --j), sort_comp(L, -3, -1)) {
      if (l_unlikely(j < i)) /* j <= i - 1 and a[j] > P, contradicts (a) */
        luaL_error(L, "invalid order function for sorting");
      lua_pop(L, 1); /* remove a[j] */
    }
    /* after the loop, a[j] <= P and a[j + 1 .. up] >= P */
    if (j < i) { /* no elements out of place? */
      /* a[lo .. i - 1] <= P <= a[j + 1 .. i .. up] */
      lua_pop(L, 1); /* pop a[j] */
      /* swap pivot (a[up - 1]) with a[i] to satisfy pos-condition */
      set2(L, up - 1, i);
      return i;
    }
    /* otherwise, swap a[i] - a[j] to restore invariant and repeat */
    set2(L, i, j);
  }
}


/*
** Choose an element in the middle (2nd-3th quarters) of [lo,up]
** "randomized" by 'rnd'
*/
static IdxT choosePivot(IdxT lo, IdxT up, unsigned int rnd) {
  IdxT r4 = (up - lo) / 4; /* range/4 */
  IdxT p = (rnd ^ lo ^ up) % (r4 * 2) + (lo + r4);
  lua_assert(lo + r4 <= p && p <= up - r4);
  return p;
}


/*
** Quicksort algorithm (recursive function)
*/
static void auxsort(lua_State *L, IdxT lo, IdxT up, unsigned rnd) {
  while (lo < up) { /* loop for tail recursion */
    IdxT p;         /* Pivot index */
    IdxT n;         /* to be used later */
    /* sort elements 'lo', 'p', and 'up' */
    geti(L, 1, lo);
    geti(L, 1, up);
    if (sort_comp(L, -1, -2)) /* a[up] < a[lo]? */
      set2(L, lo, up);        /* swap a[lo] - a[up] */
    else
      lua_pop(L, 2);                    /* remove both values */
    if (up - lo == 1)                   /* only 2 elements? */
      return;                           /* already sorted */
    if (up - lo < RANLIMIT || rnd == 0) /* small interval or no randomize? */
      p = (lo + up) / 2;                /* middle element is a good pivot */
    else /* for larger intervals, it is worth a random pivot */
      p = choosePivot(lo, up, rnd);
    geti(L, 1, p);
    geti(L, 1, lo);
    if (sort_comp(L, -2, -1)) /* a[p] < a[lo]? */
      set2(L, p, lo);         /* swap a[p] - a[lo] */
    else {
      lua_pop(L, 1); /* remove a[lo] */
      geti(L, 1, up);
      if (sort_comp(L, -1, -2)) /* a[up] < a[p]? */
        set2(L, p, up);         /* swap a[up] - a[p] */
      else
        lua_pop(L, 2);
    }
    if (up - lo == 2)     /* only 3 elements? */
      return;             /* already sorted */
    geti(L, 1, p);        /* get middle element (Pivot) */
    lua_pushvalue(L, -1); /* push Pivot */
    geti(L, 1, up - 1);   /* push a[up - 1] */
    set2(L, p, up - 1);   /* swap Pivot (a[p]) with a[up - 1] */
    p = partition(L, lo, up);
    /* a[lo .. p - 1] <= a[p] == P <= a[p + 1 .. up] */
    if (p - lo < up - p) {        /* lower interval is smaller? */
      auxsort(L, lo, p - 1, rnd); /* call recursively for lower interval */
      n = p - lo;                 /* size of smaller interval */
      lo = p + 1; /* tail call for [p + 1 .. up] (upper interval) */
    }
    else {
      auxsort(L, p + 1, up, rnd); /* call recursively for upper interval */
      n = up - p;                 /* size of smaller interval */
      up = p - 1; /* tail call for [lo .. p - 1]  (lower interval) */
    }
    if ((up - lo) / 128 > n)     /* partition too imbalanced? */
      rnd = l_randomizePivot(L); /* try a new randomization */
  } /* tail call auxsort(L, lo, up, rnd) */
}


static int sort(lua_State *L) {
  lua_Integer n = aux_getn(L, 1, TAB_RW);
  if (n > 1) { /* non-trivial interval? */
    luaL_argcheck(L, n < INT_MAX, 1, "array too big");
    if (!lua_isnoneornil(L, 2))            /* is there a 2nd argument? */
      luaL_checktype(L, 2, LUA_TFUNCTION); /* must be a function */
    lua_settop(L, 2); /* make sure there are two arguments */
    auxsort(L, 1, (IdxT)n, 0);
  }
  return 0;
}

/* }====================================================== */


/*
** {======================================================
** Clone
** =======================================================
*/

/*
** Helper for deep cloning. srcidx is the source table, mapidx is
** the table mapping source tables to their clones (for circular refs).
** Leaves the clone on top of the stack.
*/
static void clone_deep(lua_State *L, int srcidx, int mapidx) {
  /* Convert relative indices to absolute */
  srcidx = lua_absindex(L, srcidx);
  mapidx = lua_absindex(L, mapidx);
  
  /* Check if already cloned (circular reference) */
  lua_pushvalue(L, srcidx);
  if (lua_rawget(L, mapidx) != LUA_TNIL) {
    /* Already cloned - return existing clone */
    return;  /* clone is on stack */
  }
  lua_pop(L, 1);  /* pop nil */
  
  /* Create new table */
  lua_newtable(L);
  int newidx = lua_gettop(L);
  
  /* Register in map before recursing (for circular refs) */
  lua_pushvalue(L, srcidx);  /* key = source table */
  lua_pushvalue(L, newidx);  /* value = new table */
  lua_rawset(L, mapidx);
  
  /* Copy all key-value pairs */
  lua_pushnil(L);
  while (lua_next(L, srcidx) != 0) {
    /* Stack: key, value */
    int keyidx = lua_gettop(L) - 1;
    int validx = lua_gettop(L);
    
    /* Clone key if it's a table */
    if (lua_istable(L, keyidx)) {
      clone_deep(L, keyidx, mapidx);
      /* Stack: key, value, cloned_key */
    } else {
      lua_pushvalue(L, keyidx);
      /* Stack: key, value, key_copy */
    }
    
    /* Clone value if it's a table */
    if (lua_istable(L, validx)) {
      clone_deep(L, validx, mapidx);
      /* Stack: key, value, new_key, cloned_value */
    } else {
      lua_pushvalue(L, validx);
      /* Stack: key, value, new_key, value_copy */
    }
    
    /* Set new[new_key] = new_value */
    lua_settable(L, newidx);
    /* Stack: key, value */
    
    lua_pop(L, 1);  /* pop value, keep key for next iteration */
  }
  
  /* Copy metatable (shared, not deep cloned) */
  if (lua_getmetatable(L, srcidx)) {
    lua_setmetatable(L, newidx);
  }
  
  /* newidx table is already on top */
}


/*
** table.clone(t [, deep])
** Create a copy of table. If 'deep' is true, recursively clone nested tables.
** Deep copies preserve circular references.
*/
static int tclone(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int deep = lua_toboolean(L, 2);
  
  if (deep) {
    /* Need a table to track cloned tables for circular references */
    lua_newtable(L);  /* cloned_map at top of stack */
    int mapidx = lua_gettop(L);
    clone_deep(L, 1, mapidx);
    /* Remove the map, keep only the result */
    lua_remove(L, mapidx);
  } else {
    /* Shallow clone */
    lua_newtable(L);
    lua_pushnil(L);
    while (lua_next(L, 1) != 0) {
      /* Stack: new_table, key, value */
      lua_pushvalue(L, -2);  /* copy key */
      lua_insert(L, -2);     /* Stack: new_table, key, key_copy, value */
      lua_settable(L, -4);   /* new[key_copy] = value */
      /* Stack: new_table, key */
    }
    /* Copy metatable if present */
    if (lua_getmetatable(L, 1)) {
      lua_setmetatable(L, -2);
    }
  }
  return 1;
}

/* }====================================================== */


/*
** {======================================================
** Data processing
** =======================================================
*/


/* --- Aggregation -------------------------------------------------- */


static int tsum(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer len = luaL_len(L, 1);
  lua_Number sum = 0;
  for (lua_Integer i = 1; i <= len; i++) {
    lua_geti(L, 1, i);
    if (lua_isnumber(L, -1))
      sum += lua_tonumber(L, -1);
    lua_pop(L, 1);
  }
  lua_pushnumber(L, sum);
  return 1;
}


static int tmean(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer len = luaL_len(L, 1);
  lua_Number sum = 0;
  lua_Integer count = 0;
  for (lua_Integer i = 1; i <= len; i++) {
    lua_geti(L, 1, i);
    if (lua_isnumber(L, -1)) {
      sum += lua_tonumber(L, -1);
      count++;
    }
    lua_pop(L, 1);
  }
  if (count == 0)
    lua_pushnumber(L, (lua_Number)NAN); /* NaN */
  else
    lua_pushnumber(L, sum / (lua_Number)count);
  return 1;
}


static int numcmp(const void *a, const void *b) {
  lua_Number x = *(const lua_Number *)a;
  lua_Number y = *(const lua_Number *)b;
  if (x < y)
    return -1;
  if (x > y)
    return 1;
  return 0;
}


static int tmedian(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer len = luaL_len(L, 1);
  /* First pass: count numeric values */
  lua_Integer count = 0;
  for (lua_Integer i = 1; i <= len; i++) {
    lua_geti(L, 1, i);
    if (lua_isnumber(L, -1))
      count++;
    lua_pop(L, 1);
  }
  if (count == 0) {
    lua_pushnumber(L, (lua_Number)NAN); /* NaN */
    return 1;
  }
  /* Collect numeric values into C array */
  lua_Number *vals =
      (lua_Number *)lua_newuserdatauv(L, count * sizeof(lua_Number), 0);
  lua_Integer j = 0;
  for (lua_Integer i = 1; i <= len; i++) {
    lua_geti(L, 1, i);
    if (lua_isnumber(L, -1))
      vals[j++] = lua_tonumber(L, -1);
    lua_pop(L, 1);
  }
  qsort(vals, (size_t)count, sizeof(lua_Number), numcmp);
  if (count % 2 == 1)
    lua_pushnumber(L, vals[count / 2]);
  else
    lua_pushnumber(L, (vals[count / 2 - 1] + vals[count / 2]) / 2.0);
  return 1;
}


static int tstdev(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int sample = lua_toboolean(L, 2);
  lua_Integer len = luaL_len(L, 1);
  /* First pass: compute mean */
  lua_Number sum = 0;
  lua_Integer count = 0;
  for (lua_Integer i = 1; i <= len; i++) {
    lua_geti(L, 1, i);
    if (lua_isnumber(L, -1)) {
      sum += lua_tonumber(L, -1);
      count++;
    }
    lua_pop(L, 1);
  }
  if (count == 0 || (sample && count < 2)) {
    lua_pushnumber(L, (lua_Number)NAN); /* NaN */
    return 1;
  }
  lua_Number mean = sum / (lua_Number)count;
  /* Second pass: compute sum of squared deviations */
  lua_Number sumsq = 0;
  for (lua_Integer i = 1; i <= len; i++) {
    lua_geti(L, 1, i);
    if (lua_isnumber(L, -1)) {
      lua_Number diff = lua_tonumber(L, -1) - mean;
      sumsq += diff * diff;
    }
    lua_pop(L, 1);
  }
  lua_Number divisor = sample ? (lua_Number)(count - 1) : (lua_Number)count;
  lua_pushnumber(L, sqrt(sumsq / divisor));
  return 1;
}


/* --- Transformation ----------------------------------------------- */


static int tmap(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  lua_Integer len = luaL_len(L, 1);
  lua_createtable(L, (int)len, 0); /* result table */
  for (lua_Integer i = 1; i <= len; i++) {
    lua_pushvalue(L, 2);   /* push function */
    lua_geti(L, 1, i);     /* push element */
    lua_pushinteger(L, i); /* push index */
    lua_call(L, 2, 1);     /* call f(elem, i) */
    lua_seti(L, -2, i);    /* result[i] = return value */
  }
  return 1;
}


static int tfilter(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  lua_Integer len = luaL_len(L, 1);
  lua_newtable(L); /* result table */
  lua_Integer j = 1;
  for (lua_Integer i = 1; i <= len; i++) {
    lua_pushvalue(L, 2); /* push predicate */
    lua_geti(L, 1, i);   /* push element */
    lua_call(L, 1, 1);   /* call f(elem) */
    if (lua_toboolean(L, -1)) {
      lua_pop(L, 1);       /* pop result */
      lua_geti(L, 1, i);   /* push original element */
      lua_seti(L, -2, j);  /* result[j] = element */
      j++;
    }
    else {
      lua_pop(L, 1); /* pop result */
    }
  }
  return 1;
}


static int treduce(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  lua_Integer len = luaL_len(L, 1);
  lua_Integer start;
  if (!lua_isnoneornil(L, 3)) {
    lua_pushvalue(L, 3); /* accumulator = initial value */
    start = 1;
  }
  else {
    if (len == 0)
      return luaL_error(L, "'reduce' on empty table with no initial value");
    lua_geti(L, 1, 1); /* accumulator = t[1] */
    start = 2;
  }
  /* Stack: acc on top */
  for (lua_Integer i = start; i <= len; i++) {
    lua_pushvalue(L, 2);  /* push function */
    lua_pushvalue(L, -2); /* push accumulator */
    lua_geti(L, 1, i);    /* push element */
    lua_pushinteger(L, i); /* push index */
    lua_call(L, 3, 1);    /* call f(acc, elem, i) */
    lua_remove(L, -2);    /* remove old accumulator */
  }
  return 1; /* accumulator on top */
}


static int tgroupby(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  lua_Integer len = luaL_len(L, 1);
  lua_newtable(L); /* result table */
  int residx = lua_gettop(L);
  for (lua_Integer i = 1; i <= len; i++) {
    /* Call key function */
    lua_pushvalue(L, 2); /* push function */
    lua_geti(L, 1, i);   /* push element */
    lua_call(L, 1, 1);   /* call f(elem) -> key */
    /* Stack: result, key */
    lua_pushvalue(L, -1); /* duplicate key for lookup */
    lua_gettable(L, residx); /* get result[key] */
    if (lua_isnil(L, -1)) {
      /* Group doesn't exist yet: create it */
      lua_pop(L, 1);          /* pop nil */
      lua_pushvalue(L, -1);   /* duplicate key */
      lua_newtable(L);         /* new group array */
      lua_geti(L, 1, i);      /* push element */
      lua_seti(L, -2, 1);     /* group[1] = element */
      lua_settable(L, residx); /* result[key] = group */
      lua_pop(L, 1);          /* pop original key */
    }
    else {
      /* Group exists: append to it */
      int grpidx = lua_gettop(L);
      lua_Integer glen = luaL_len(L, grpidx);
      lua_geti(L, 1, i);           /* push element */
      lua_seti(L, grpidx, glen + 1); /* group[len+1] = element */
      lua_pop(L, 2); /* pop group and key */
    }
  }
  return 1;
}


/* Sortby quicksort helpers */

static void sortby_swap(lua_State *L, int tabidx, int keysidx,
                         lua_Integer a, lua_Integer b) {
  /* swap t[a] and t[b] */
  lua_geti(L, tabidx, a);
  lua_geti(L, tabidx, b);
  lua_seti(L, tabidx, a);
  lua_seti(L, tabidx, b);
  /* swap keys[a] and keys[b] */
  lua_geti(L, keysidx, a);
  lua_geti(L, keysidx, b);
  lua_seti(L, keysidx, a);
  lua_seti(L, keysidx, b);
}

/* Compare keys[a] vs keys[b]. Returns true if a should come before b. */
static int sortby_comp(lua_State *L, int keysidx, lua_Integer a,
                       lua_Integer b, int asc) {
  lua_geti(L, keysidx, a);
  lua_geti(L, keysidx, b);
  int result;
  if (asc)
    result = lua_compare(L, -2, -1, LUA_OPLT);
  else
    result = lua_compare(L, -1, -2, LUA_OPLT);
  lua_pop(L, 2);
  return result;
}

static void sortby_qsort(lua_State *L, int tabidx, int keysidx,
                          lua_Integer lo, lua_Integer hi, int asc) {
  while (lo < hi) {
    /* Median-of-three pivot selection */
    lua_Integer mid = lo + (hi - lo) / 2;
    if (sortby_comp(L, keysidx, mid, lo, asc))
      sortby_swap(L, tabidx, keysidx, lo, mid);
    if (sortby_comp(L, keysidx, hi, lo, asc))
      sortby_swap(L, tabidx, keysidx, lo, hi);
    if (sortby_comp(L, keysidx, hi, mid, asc))
      sortby_swap(L, tabidx, keysidx, mid, hi);
    /* Use mid as pivot, move to hi-1 */
    sortby_swap(L, tabidx, keysidx, mid, hi - 1);
    lua_Integer pivot = hi - 1;
    lua_Integer i = lo;
    lua_Integer j = hi - 1;
    for (;;) {
      while (sortby_comp(L, keysidx, ++i, pivot, asc))
        ;
      while (j > lo && sortby_comp(L, keysidx, pivot, --j, asc))
        ;
      if (i >= j) break;
      sortby_swap(L, tabidx, keysidx, i, j);
    }
    sortby_swap(L, tabidx, keysidx, i, hi - 1); /* restore pivot */
    /* Tail recursion on larger partition */
    if (i - lo < hi - i) {
      sortby_qsort(L, tabidx, keysidx, lo, i - 1, asc);
      lo = i + 1;
    }
    else {
      sortby_qsort(L, tabidx, keysidx, i + 1, hi, asc);
      hi = i - 1;
    }
  }
}

static int tsortby(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  int asc = lua_isnoneornil(L, 3) ? 1 : lua_toboolean(L, 3);
  lua_Integer len = luaL_len(L, 1);
  if (len <= 1) return 0;
  /* Build keys table */
  lua_createtable(L, (int)len, 0);
  int keysidx = lua_gettop(L);
  for (lua_Integer i = 1; i <= len; i++) {
    lua_pushvalue(L, 2); /* push keyfunc */
    lua_geti(L, 1, i);   /* push element */
    lua_call(L, 1, 1);   /* call f(elem) */
    lua_seti(L, keysidx, i); /* keys[i] = result */
  }
  sortby_qsort(L, 1, keysidx, 1, len, asc);
  return 0;
}


/* --- Combining ---------------------------------------------------- */


static int tzip(lua_State *L) {
  int nargs = lua_gettop(L);
  if (nargs == 0) {
    lua_newtable(L);
    return 1;
  }
  /* Find minimum length */
  lua_Integer minlen = LUA_MAXINTEGER;
  for (int k = 1; k <= nargs; k++) {
    luaL_checktype(L, k, LUA_TTABLE);
    lua_Integer l = luaL_len(L, k);
    if (l < minlen)
      minlen = l;
  }
  lua_createtable(L, (int)minlen, 0);
  for (lua_Integer i = 1; i <= minlen; i++) {
    lua_createtable(L, nargs, 0); /* tuple */
    for (int k = 1; k <= nargs; k++) {
      lua_geti(L, k, i);
      lua_seti(L, -2, k);
    }
    lua_seti(L, -2, i); /* result[i] = tuple */
  }
  return 1;
}


static int tunzip(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer n = luaL_len(L, 1);
  if (n == 0)
    return 0; /* no tuples, no return values */
  /* Get width from first tuple */
  lua_geti(L, 1, 1);
  luaL_checktype(L, -1, LUA_TTABLE);
  lua_Integer w = luaL_len(L, -1);
  lua_pop(L, 1);
  if (w == 0)
    return 0;
  /* Create w result tables */
  if (!lua_checkstack(L, (int)w + 2))
    return luaL_error(L, "too many columns to unzip");
  for (lua_Integer j = 1; j <= w; j++)
    lua_createtable(L, (int)n, 0);
  /* Stack: result1, result2, ..., resultw */
  int base = lua_gettop(L) - (int)w + 1; /* index of result1 */
  for (lua_Integer i = 1; i <= n; i++) {
    lua_geti(L, 1, i); /* push tuple */
    int tidx = lua_gettop(L);
    for (lua_Integer j = 1; j <= w; j++) {
      lua_geti(L, tidx, j);
      lua_seti(L, base + (int)j - 1, i); /* results[j][i] = tuple[j] */
    }
    lua_pop(L, 1); /* pop tuple */
  }
  return (int)w;
}


/* --- Matrix operations -------------------------------------------- */


static int ttranspose(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer rows = luaL_len(L, 1);
  if (rows == 0) {
    lua_newtable(L);
    return 1;
  }
  /* Get column count from first row */
  lua_geti(L, 1, 1);
  luaL_checktype(L, -1, LUA_TTABLE);
  lua_Integer cols = luaL_len(L, -1);
  lua_pop(L, 1);
  /* Validate all rows have same length */
  for (lua_Integer i = 2; i <= rows; i++) {
    lua_geti(L, 1, i);
    luaL_checktype(L, -1, LUA_TTABLE);
    if (luaL_len(L, -1) != cols) {
      lua_pop(L, 1);
      return luaL_error(L, "non-rectangular matrix in 'transpose'");
    }
    lua_pop(L, 1);
  }
  /* Build result: cols rows of rows elements */
  lua_createtable(L, (int)cols, 0);
  int residx = lua_gettop(L);
  for (lua_Integer j = 1; j <= cols; j++) {
    lua_createtable(L, (int)rows, 0);
    for (lua_Integer i = 1; i <= rows; i++) {
      lua_geti(L, 1, i);   /* push row i */
      lua_geti(L, -1, j);  /* push row[j] */
      lua_remove(L, -2);   /* remove row */
      lua_seti(L, -2, i);  /* new_row[i] = old_matrix[i][j] */
    }
    lua_seti(L, residx, j); /* result[j] = new_row */
  }
  return 1;
}


static int treshape(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer nrows = luaL_checkinteger(L, 2);
  lua_Integer ncols = luaL_checkinteger(L, 3);
  lua_Integer len = luaL_len(L, 1);
  luaL_argcheck(L, nrows > 0, 2, "rows must be positive");
  luaL_argcheck(L, ncols > 0, 3, "cols must be positive");
  if (len != nrows * ncols)
    return luaL_error(L,
        "array length %I does not match %I x %I", (LUAI_UACINT)len,
        (LUAI_UACINT)nrows, (LUAI_UACINT)ncols);
  lua_createtable(L, (int)nrows, 0);
  int residx = lua_gettop(L);
  for (lua_Integer r = 1; r <= nrows; r++) {
    lua_createtable(L, (int)ncols, 0);
    for (lua_Integer c = 1; c <= ncols; c++) {
      lua_geti(L, 1, (r - 1) * ncols + c);
      lua_seti(L, -2, c); /* row[c] = t[(r-1)*ncols + c] */
    }
    lua_seti(L, residx, r); /* result[r] = row */
  }
  return 1;
}


/* }====================================================== */


static const luaL_Reg tab_funcs[] = {
    {"clone", tclone},   {"concat", tconcat}, {"create", tcreate},
    {"filter", tfilter}, {"groupby", tgroupby},
    {"insert", tinsert}, {"map", tmap},       {"mean", tmean},
    {"median", tmedian}, {"move", tmove},      {"pack", tpack},
    {"reduce", treduce}, {"remove", tremove},  {"reshape", treshape},
    {"sort", sort},      {"sortby", tsortby},  {"stdev", tstdev},
    {"sum", tsum},       {"transpose", ttranspose},
    {"unpack", tunpack}, {"unzip", tunzip},    {"zip", tzip},
    {NULL, NULL}};


LUAMOD_API int luaopen_table(lua_State *L) {
  luaL_newlib(L, tab_funcs);
  return 1;
}
