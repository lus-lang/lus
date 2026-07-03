/*
** ltimelib.c
** Date and time library for Lus
** Implements the `time` module: instant, duration, and zoned datetime types.
**
** Design (see lus-spec/stdlib/time/):
**   - instant  : an absolute point on the UTC timeline (int64 seconds + nanos)
**   - duration : a signed span of time (int64 seconds + nanos)
**   - zoned    : a civil date/time observed in a particular zone offset
**
** All three are immutable userdata with metamethods. Arithmetic on instants is
** exact SI-seconds; calendar arithmetic on zoned values is intentionally a
** distinct operation (:add, still TODO) so the two can never be confused.
**
** Timezone handling here covers UTC and fixed offsets only. IANA named zones
** are read from an embedded, zstd-compressed tzdata blob decompressed per zone;
** that subsystem is not wired up yet (see the TODOs below and the design memo).
*/

#define ltimelib_c
#define LUA_LIB

#include "lprefix.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <zstd.h>

#include "lauxlib.h"
#include "lobject.h" /* Enum struct, for reading an enum argument's index */
#include "ltzdata.h"
#include "lua.h"
#include "lualib.h"
#include "lwinzones.h"

#if defined(LUS_PLATFORM_WINDOWS)
#include <windows.h>
#else
#include <unistd.h>
#endif

/*
** {======================================================
** Types
** =======================================================
*/

#define INSTANT_METATABLE "time.instant"
#define DURATION_METATABLE "time.duration"
#define ZONED_METATABLE "time.zoned"
#define ZONE_METATABLE "time.zone"

#define NANOS_PER_SEC 1000000000

/* Registry keys for the lazily-decompressed tzdata (one copy per lua_State,
** so worker threads never share it and no locking is needed). */
#define TZBLOB_KEY "lus.time.tzblob"   /* Lua string: decompressed container */
#define TZINDEX_KEY "lus.time.tzindex" /* Lua table: zone name -> byte offset */
#define WEEKDAY_KEY "lus.time.weekday" /* Enum value: monday..sunday */

/* Absolute point on the timeline. When `mono` is set the value comes from a
** monotonic clock and is only meaningful when subtracted from another reading
** of the same clock; formatting or epoch extraction is rejected. */
typedef struct {
  lua_Integer sec; /* seconds since the Unix epoch (or since an arbitrary
                      monotonic origin when mono != 0) */
  int nsec;        /* normalized: 0 <= nsec < NANOS_PER_SEC */
  int mono;        /* 1 if read from a monotonic clock */
} l_instant;

/* A signed span. Sign lives in `sec`; `nsec` is always in [0, NANOS_PER_SEC). */
typedef struct {
  lua_Integer sec;
  int nsec;
} l_duration;

/* A civil datetime. `sec`/`nsec` hold the underlying UTC instant; `offset` is
** the zone's offset east of UTC in seconds, so wall-clock = sec + offset. */
typedef struct {
  lua_Integer sec;
  int nsec;
  int offset;
} l_zoned;

/* A daylight-saving transition rule from a POSIX TZ string. */
typedef struct {
  int mode; /* 1 = Jn (1..365, skips Feb 29); 2 = n (0..365); 3 = Mm.w.d */
  int mon;  /* month 1..12  (mode 3) */
  int week; /* week 1..5, 5 = last  (mode 3) */
  int day;  /* weekday 0 = Sunday  (mode 3) */
  int yday; /* day number  (modes 1, 2) */
  int time; /* seconds after local midnight (default 02:00:00) */
} tzrule;

/* A time zone: either a fixed offset, or a set of UTC transitions parsed from a
** TZif record. The transition arrays are allocated inline after this header in
** a single userdata block, so the GC reclaims them with the object. The zone's
** name is kept in user value 1. `has_tz` and the tz_* fields carry the trailing
** POSIX rule that governs instants past the last explicit transition. */
typedef struct {
  int fixed;     /* 1 = fixed offset (no transition table) */
  int fixed_off; /* offset east of UTC in seconds, when fixed */
  int timecnt;   /* number of transitions */
  int typecnt;   /* number of local-time types */
  int has_tz;    /* 1 = a usable POSIX footer rule was parsed */
  int tz_has_dst;
  int tz_std_off; /* UTC offset east, standard time (seconds) */
  int tz_dst_off; /* UTC offset east, daylight time (seconds) */
  tzrule tz_start, tz_end;
  /* inline layout follows:
  **   int64_t times[timecnt]   transition instants (UTC epoch seconds)
  **   int32_t offs[typecnt]    utc offset of each type (seconds)
  **   uint8_t ttype[timecnt]   type index active after each transition
  **   uint8_t isdst[typecnt]   DST flag of each type */
} l_zone;

static int64_t *zone_times(l_zone *z) {
  return (int64_t *)(void *)((char *)z + sizeof(l_zone));
}
static int32_t *zone_offs(l_zone *z) {
  return (int32_t *)(void *)(zone_times(z) + z->timecnt);
}
static uint8_t *zone_ttype(l_zone *z) {
  return (uint8_t *)(void *)(zone_offs(z) + z->typecnt);
}
static uint8_t *zone_isdst(l_zone *z) { return zone_ttype(z) + z->timecnt; }

/*
** {======================================================
** Civil <-> days algorithms (Howard Hinnant, public domain)
** These avoid libc's mktime/localtime, whose global TZ state is not worker
** safe. days == 0 is 1970-01-01.
** =======================================================
*/

/* Days from 1970-01-01 to the given civil date (proleptic Gregorian). */
static lua_Integer days_from_civil(lua_Integer y, unsigned m, unsigned d) {
  y -= m <= 2;
  lua_Integer era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400); /* [0, 399] */
  unsigned doy = (153u * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1; /* [0,365] */
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;           /* [0,146096]*/
  return era * 146097 + (lua_Integer)doe - 719468;
}

/* Civil date from a day count relative to 1970-01-01. */
static void civil_from_days(lua_Integer z, lua_Integer *y, unsigned *m,
                            unsigned *d) {
  z += 719468;
  lua_Integer era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097); /* [0, 146096] */
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  lua_Integer yy = (lua_Integer)yoe + era * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100); /* [0, 365] */
  unsigned mp = (5 * doy + 2) / 153;                      /* [0, 11] */
  *d = doy - (153 * mp + 2) / 5 + 1;                      /* [1, 31] */
  *m = mp + (mp < 10 ? 3 : -9);                           /* [1, 12] */
  *y = yy + (*m <= 2);
}

/* ISO weekday for a day count: 1 = Monday .. 7 = Sunday. */
static int weekday_from_days(lua_Integer z) {
  int wd = (int)((z >= -3 ? (z + 3) % 7 : (z + 4) % 7 + 6)); /* 0 = Monday */
  return wd + 1;
}

/*
** {======================================================
** Constructors / helpers
** =======================================================
*/

static void norm(lua_Integer *sec, int *nsec) {
  /* Fold overflow/underflow so 0 <= nsec < NANOS_PER_SEC. */
  *sec += *nsec / NANOS_PER_SEC;
  *nsec %= NANOS_PER_SEC;
  if (*nsec < 0) {
    *nsec += NANOS_PER_SEC;
    *sec -= 1;
  }
}

static l_instant *push_instant(lua_State *L, lua_Integer sec, int nsec,
                               int mono) {
  l_instant *i = (l_instant *)lua_newuserdatauv(L, sizeof(l_instant), 0);
  norm(&sec, &nsec);
  i->sec = sec;
  i->nsec = nsec;
  i->mono = mono;
  luaL_setmetatable(L, INSTANT_METATABLE);
  return i;
}

static l_duration *push_duration(lua_State *L, lua_Integer sec, int nsec) {
  l_duration *d = (l_duration *)lua_newuserdatauv(L, sizeof(l_duration), 0);
  norm(&sec, &nsec);
  d->sec = sec;
  d->nsec = nsec;
  luaL_setmetatable(L, DURATION_METATABLE);
  return d;
}

/* A zoned carries its originating zone (or nil for a bare fixed offset) in user
** value 1, so calendar operations can re-resolve the offset across DST. */
static l_zoned *push_zoned(lua_State *L, lua_Integer sec, int nsec, int offset) {
  l_zoned *z = (l_zoned *)lua_newuserdatauv(L, sizeof(l_zoned), 1);
  norm(&sec, &nsec);
  z->sec = sec;
  z->nsec = nsec;
  z->offset = offset;
  luaL_setmetatable(L, ZONED_METATABLE);
  return z; /* user value 1 defaults to nil */
}

static l_instant *check_instant(lua_State *L, int arg) {
  return (l_instant *)luaL_checkudata(L, arg, INSTANT_METATABLE);
}

static l_duration *check_duration(lua_State *L, int arg) {
  return (l_duration *)luaL_checkudata(L, arg, DURATION_METATABLE);
}

static l_zoned *check_zoned(lua_State *L, int arg) {
  return (l_zoned *)luaL_checkudata(L, arg, ZONED_METATABLE);
}

static l_zone *check_zone(lua_State *L, int arg) {
  return (l_zone *)luaL_checkudata(L, arg, ZONE_METATABLE);
}

/*
** {======================================================
** Timezone database: decompression, indexing, TZif parsing
** =======================================================
*/

/* Forward declarations: the POSIX footer parser is called from parse_tzif and
** its evaluator from zone_offset_at, both defined before their bodies. */
static int parse_posix_tz(const char *s, size_t len, l_zone *z);
static int posix_offset(l_zone *z, lua_Integer t);

/* Big-endian readers for TZif fields. */
static uint32_t be32(const unsigned char *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static int64_t be64(const unsigned char *p) {
  return (int64_t)(((uint64_t)be32(p) << 32) | be32(p + 4));
}
/* Little-endian readers for our own container format. */
static uint32_t le32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}
static uint32_t le16(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8);
}

/* Decompress the embedded blob once per state and build a name -> offset index,
** both cached in the registry. Leaves nothing on the stack. */
static void ensure_tzdata(lua_State *L) {
  if (lua_getfield(L, LUA_REGISTRYINDEX, TZINDEX_KEY) != LUA_TNIL) {
    lua_pop(L, 1);
    return;
  }
  lua_pop(L, 1); /* the nil */

  void *raw = malloc(lus_tzdata_raw_len);
  if (raw == NULL)
    luaL_error(L, "out of memory decompressing tzdata");
  size_t got = ZSTD_decompress(raw, lus_tzdata_raw_len, lus_tzdata_z,
                               lus_tzdata_z_len);
  if (ZSTD_isError(got) || got != lus_tzdata_raw_len) {
    free(raw);
    luaL_error(L, "corrupt embedded tzdata");
  }
  /* Copy into a Lua string (owns the bytes henceforth) and cache it. */
  lua_pushlstring(L, (const char *)raw, got);
  lua_setfield(L, LUA_REGISTRYINDEX, TZBLOB_KEY);
  free(raw);

  /* Re-fetch the interned blob and walk it to build the index. */
  size_t len;
  const unsigned char *b;
  lua_getfield(L, LUA_REGISTRYINDEX, TZBLOB_KEY);
  b = (const unsigned char *)lua_tolstring(L, -1, &len);
  lua_pop(L, 1);

  lua_newtable(L); /* the index */
  size_t pos = 0;
  if (len < 9 || memcmp(b, "LTZ1", 4) != 0)
    luaL_error(L, "bad tzdata container header");
  pos = 4;
  pos += 1 + b[4];               /* version length + string */
  uint32_t count = le32(b + pos); /* zone_count */
  pos += 4;
  for (uint32_t i = 0; i < count; i++) {
    if (pos + 2 > len)
      luaL_error(L, "truncated tzdata index");
    uint32_t nlen = le16(b + pos);
    pos += 2;
    if (pos + nlen + 4 > len)
      luaL_error(L, "truncated tzdata entry");
    lua_pushlstring(L, (const char *)(b + pos), nlen); /* key: name */
    pos += nlen;
    lua_pushinteger(L, (lua_Integer)pos); /* value: offset of the u32 length */
    lua_settable(L, -3);
    uint32_t dlen = le32(b + pos);
    pos += 4 + dlen; /* skip length prefix + TZif bytes */
  }
  lua_setfield(L, LUA_REGISTRYINDEX, TZINDEX_KEY);
}

/* Parse a TZif record [p, p+len) into a fresh l_zone userdata pushed on the
** stack. Returns 1, or raises on malformed input. */
static int parse_tzif(lua_State *L, const unsigned char *p, size_t len) {
  if (len < 44 || memcmp(p, "TZif", 4) != 0)
    return luaL_error(L, "malformed TZif record");
  char version = (char)p[4];

  /* v1 counts start at offset 20. */
  const unsigned char *h = p;
  uint32_t timecnt = be32(h + 32);
  uint32_t typecnt = be32(h + 36);
  uint32_t charcnt = be32(h + 40);
  uint32_t isutcnt = be32(h + 20);
  uint32_t isstdcnt = be32(h + 24);
  uint32_t leapcnt = be32(h + 28);
  int timesize = 4;
  const unsigned char *base = p + 44;

  if (version >= '2') {
    /* Skip the whole v1 block and use the 64-bit v2+ block instead. */
    size_t v1 = (size_t)timecnt * 4 + timecnt + (size_t)typecnt * 6 + charcnt +
                (size_t)leapcnt * 8 + isstdcnt + isutcnt;
    size_t off2 = 44 + v1;
    if (off2 + 44 > len)
      return luaL_error(L, "truncated TZif v2 header");
    h = p + off2;
    if (memcmp(h, "TZif", 4) != 0)
      return luaL_error(L, "bad TZif v2 magic");
    timecnt = be32(h + 32);
    typecnt = be32(h + 36);
    charcnt = be32(h + 40);
    isutcnt = be32(h + 20);
    isstdcnt = be32(h + 24);
    leapcnt = be32(h + 28);
    timesize = 8;
    base = h + 44;
  }
  if (typecnt == 0)
    return luaL_error(L, "TZif record has no local-time types");

  /* Bounds-check the data section we are about to read. */
  const unsigned char *times = base;
  const unsigned char *types = times + (size_t)timecnt * timesize;
  const unsigned char *ttinfo = types + timecnt;
  const unsigned char *end = ttinfo + (size_t)typecnt * 6;
  if (end > p + len)
    return luaL_error(L, "truncated TZif data");

  size_t sz = sizeof(l_zone) + (size_t)timecnt * sizeof(int64_t) +
              (size_t)typecnt * sizeof(int32_t) + timecnt + typecnt;
  l_zone *z = (l_zone *)lua_newuserdatauv(L, sz, 1);
  z->fixed = 0;
  z->fixed_off = 0;
  z->timecnt = (int)timecnt;
  z->typecnt = (int)typecnt;
  z->has_tz = 0;
  int64_t *zt = zone_times(z);
  int32_t *zo = zone_offs(z);
  uint8_t *zty = zone_ttype(z);
  uint8_t *zds = zone_isdst(z);
  for (uint32_t i = 0; i < timecnt; i++)
    zt[i] = timesize == 8 ? be64(times + (size_t)i * 8)
                          : (int32_t)be32(times + (size_t)i * 4);
  for (uint32_t i = 0; i < timecnt; i++) {
    zty[i] = types[i];
    if (zty[i] >= typecnt)
      return luaL_error(L, "TZif transition type out of range");
  }
  for (uint32_t i = 0; i < typecnt; i++) {
    zo[i] = (int32_t)be32(ttinfo + (size_t)i * 6);
    zds[i] = ttinfo[(size_t)i * 6 + 4] ? 1 : 0;
  }

  /* The v2+ record ends with a newline-delimited POSIX TZ string that governs
  ** instants beyond the last explicit transition. */
  if (version >= '2') {
    size_t v2data = (size_t)timecnt * 8 + timecnt + (size_t)typecnt * 6 +
                    charcnt + (size_t)leapcnt * 12 + isstdcnt + isutcnt;
    const unsigned char *foot = base + v2data;
    if (foot < p + len && *foot == '\n') {
      const unsigned char *fs = foot + 1, *fe = foot + 1;
      while (fe < p + len && *fe != '\n')
        fe++;
      if (fe > fs)
        parse_posix_tz((const char *)fs, (size_t)(fe - fs), z);
    }
  }
  luaL_setmetatable(L, ZONE_METATABLE);
  return 1;
}

/* Look up a named zone and push it. Returns 1 if found (zone on stack), or 0
** with nothing pushed. */
static int lookup_zone(lua_State *L, const char *name) {
  ensure_tzdata(L);
  lua_getfield(L, LUA_REGISTRYINDEX, TZINDEX_KEY);
  lua_getfield(L, -1, name);
  if (!lua_isinteger(L, -1)) {
    lua_pop(L, 2); /* value + index */
    return 0;
  }
  lua_Integer pos = lua_tointeger(L, -1);
  lua_pop(L, 2); /* value + index */

  size_t len;
  const unsigned char *b;
  lua_getfield(L, LUA_REGISTRYINDEX, TZBLOB_KEY);
  b = (const unsigned char *)lua_tolstring(L, -1, &len);
  if ((size_t)pos + 4 > len) {
    lua_pop(L, 1);
    return 0;
  }
  uint32_t dlen = le32(b + pos);
  if ((size_t)pos + 4 + dlen > len) {
    lua_pop(L, 1);
    return 0;
  }
  parse_tzif(L, b + pos + 4, dlen); /* pushes the zone */
  lua_remove(L, -2);                /* drop the blob string */
  /* attach the zone name as user value 1 */
  lua_pushstring(L, name);
  lua_setiuservalue(L, -2, 1);
  return 1;
}

static void push_fixed_zone(lua_State *L, int offset, const char *name) {
  l_zone *z = (l_zone *)lua_newuserdatauv(L, sizeof(l_zone), 1);
  z->fixed = 1;
  z->fixed_off = offset;
  z->timecnt = 0;
  z->typecnt = 0;
  luaL_setmetatable(L, ZONE_METATABLE);
  lua_pushstring(L, name);
  lua_setiuservalue(L, -2, 1);
}

/* Offset east of UTC (seconds) that this zone observes at UTC instant t. */
static int zone_offset_at(l_zone *z, lua_Integer t) {
  if (z->fixed)
    return z->fixed_off;
  int64_t *times = zone_times(z);
  int32_t *offs = zone_offs(z);
  uint8_t *ttype = zone_ttype(z);
  uint8_t *isdst = zone_isdst(z);
  if (z->timecnt == 0)
    return z->has_tz ? posix_offset(z, t) : offs[0];
  if (t < times[0]) {
    /* Before the first transition: use the earliest non-DST type. */
    for (int i = 0; i < z->typecnt; i++)
      if (!isdst[i])
        return offs[i];
    return offs[0];
  }
  int lo = 0, hi = z->timecnt - 1, ans = 0;
  while (lo <= hi) {
    int mid = lo + (hi - lo) / 2;
    if (times[mid] <= (int64_t)t) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  /* Past the last explicit transition, defer to the POSIX footer rule. */
  if (ans == z->timecnt - 1 && z->has_tz)
    return posix_offset(z, t);
  return offs[ttype[ans]];
}

/* Floored integer division (rounds toward negative infinity). */
static lua_Integer floordiv(lua_Integer a, lua_Integer b) {
  lua_Integer q = a / b, r = a % b;
  if (r != 0 && (r < 0) != (b < 0))
    q--;
  return q;
}

static int days_in_month(lua_Integer y, int m) {
  static const int dm[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  if (m == 2) {
    int leap = (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0));
    return leap ? 29 : 28;
  }
  return dm[m - 1];
}

/* --- POSIX TZ footer parsing (RFC 8536 §3.3.1, POSIX.1 "TZ" grammar) --- */

/* Consume a zone abbreviation: <quoted> or a run of non-offset characters. */
static int tz_name(const char **p, const char *e) {
  if (*p < e && **p == '<') {
    (*p)++;
    while (*p < e && **p != '>')
      (*p)++;
    if (*p < e)
      (*p)++;
    return 1;
  }
  int n = 0;
  while (*p < e && **p != '+' && **p != '-' && **p != ',' &&
         !(**p >= '0' && **p <= '9')) {
    (*p)++;
    n++;
  }
  return n > 0;
}

/* Read hh[:mm[:ss]] (up to 3 leading hour digits), returning total seconds. */
static int tz_hms(const char **p, const char *e) {
  int hh = 0, mm = 0, ss = 0, n = 0, k;
  while (*p < e && **p >= '0' && **p <= '9' && n < 3) {
    hh = hh * 10 + (**p - '0');
    (*p)++;
    n++;
  }
  if (*p < e && **p == ':') {
    (*p)++;
    for (k = 0; *p < e && **p >= '0' && **p <= '9' && k < 2; k++, (*p)++)
      mm = mm * 10 + (**p - '0');
  }
  if (*p < e && **p == ':') {
    (*p)++;
    for (k = 0; *p < e && **p >= '0' && **p <= '9' && k < 2; k++, (*p)++)
      ss = ss * 10 + (**p - '0');
  }
  return hh * 3600 + mm * 60 + ss;
}

/* Parse a signed offset. POSIX offsets are positive west of UTC, so the eastward
** offset we store is negated. Sets *ok to whether any digits were present. */
static int tz_offset(const char **p, const char *e, int *ok) {
  int sign = 1;
  if (*p < e && (**p == '+' || **p == '-')) {
    if (**p == '-')
      sign = -1;
    (*p)++;
  }
  if (!(*p < e && **p >= '0' && **p <= '9')) {
    *ok = 0;
    return 0;
  }
  *ok = 1;
  return -(sign * tz_hms(p, e));
}

/* Parse a Jn / n / Mm.w.d transition rule with an optional /time suffix. */
static int tz_rule(const char **p, const char *e, tzrule *r) {
  r->time = 2 * 3600; /* POSIX default 02:00:00 local */
  if (*p >= e)
    return 0;
  if (**p == 'J') {
    (*p)++;
    int v = 0, n = 0;
    while (*p < e && **p >= '0' && **p <= '9') {
      v = v * 10 + (**p - '0');
      (*p)++;
      n++;
    }
    if (!n)
      return 0;
    r->mode = 1;
    r->yday = v;
  } else if (**p == 'M') {
    (*p)++;
    int m = 0, w = 0, d = 0, n;
    for (n = 0; *p < e && **p >= '0' && **p <= '9'; n++, (*p)++)
      m = m * 10 + (**p - '0');
    if (!n || *p >= e || **p != '.')
      return 0;
    (*p)++;
    for (n = 0; *p < e && **p >= '0' && **p <= '9'; n++, (*p)++)
      w = w * 10 + (**p - '0');
    if (!n || *p >= e || **p != '.')
      return 0;
    (*p)++;
    for (n = 0; *p < e && **p >= '0' && **p <= '9'; n++, (*p)++)
      d = d * 10 + (**p - '0');
    if (!n)
      return 0;
    r->mode = 3;
    r->mon = m;
    r->week = w;
    r->day = d;
  } else {
    int v = 0, n = 0;
    while (*p < e && **p >= '0' && **p <= '9') {
      v = v * 10 + (**p - '0');
      (*p)++;
      n++;
    }
    if (!n)
      return 0;
    r->mode = 2;
    r->yday = v;
  }
  if (*p < e && **p == '/') {
    (*p)++;
    int sign = 1;
    if (*p < e && (**p == '+' || **p == '-')) {
      if (**p == '-')
        sign = -1;
      (*p)++;
    }
    r->time = sign * tz_hms(p, e);
  }
  return 1;
}

static int parse_posix_tz(const char *s, size_t len, l_zone *z) {
  const char *p = s, *e = s + len;
  int ok;
  if (!tz_name(&p, e))
    return 0;
  z->tz_std_off = tz_offset(&p, e, &ok);
  if (!ok)
    return 0;
  z->tz_has_dst = 0;
  z->tz_dst_off = z->tz_std_off + 3600; /* default: one hour east of standard */
  if (p < e && *p != ',') {             /* a DST abbreviation follows */
    if (!tz_name(&p, e))
      return 0;
    z->tz_has_dst = 1;
    if (p < e && *p != ',') {
      int ok2, o = tz_offset(&p, e, &ok2);
      if (ok2)
        z->tz_dst_off = o;
    }
  }
  if (z->tz_has_dst) {
    if (p >= e || *p++ != ',' || !tz_rule(&p, e, &z->tz_start))
      return 0;
    if (p >= e || *p++ != ',' || !tz_rule(&p, e, &z->tz_end))
      return 0;
  }
  z->has_tz = 1;
  return 1;
}

/* Day count (relative to 1970-01-01) of a transition rule within `year`. */
static lua_Integer rule_day_count(tzrule *r, lua_Integer year) {
  lua_Integer first = days_from_civil(year, 1, 1);
  if (r->mode == 3) {
    lua_Integer fom = days_from_civil(year, (unsigned)r->mon, 1);
    int sun0 = weekday_from_days(fom) % 7; /* 0 = Sunday */
    int add = (r->day - sun0 + 7) % 7;
    lua_Integer dc = fom + add + (lua_Integer)(r->week - 1) * 7;
    if (dc >= fom + days_in_month(year, r->mon))
      dc -= 7; /* week 5 means the last such weekday */
    return dc;
  }
  if (r->mode == 1) { /* Jn: 1..365, never counts Feb 29 */
    int leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
    return first + (r->yday - 1) + ((leap && r->yday >= 60) ? 1 : 0);
  }
  return first + r->yday; /* mode 2: 0-based, counts Feb 29 */
}

/* Offset east of UTC at instant t, from the POSIX footer rule. */
static int posix_offset(l_zone *z, lua_Integer t) {
  if (!z->tz_has_dst)
    return z->tz_std_off;
  lua_Integer days = t >= 0 ? t / 86400 : (t - 86399) / 86400;
  lua_Integer y;
  unsigned mo, d;
  civil_from_days(days, &y, &mo, &d);
  lua_Integer startL = rule_day_count(&z->tz_start, y) * 86400 + z->tz_start.time;
  lua_Integer endL = rule_day_count(&z->tz_end, y) * 86400 + z->tz_end.time;
  lua_Integer startU = startL - z->tz_std_off; /* std in effect before start */
  lua_Integer endU = endL - z->tz_dst_off;     /* dst in effect before end */
  int dst;
  if (startU < endU)
    dst = (t >= startU && t < endU);
  else
    dst = (t >= startU || t < endU); /* southern hemisphere: DST spans New Year */
  return dst ? z->tz_dst_off : z->tz_std_off;
}

/* Decompose a zoned into its wall-clock civil fields. */
static void zoned_civil(l_zoned *z, lua_Integer *Y, int *Mo, int *D, int *H,
                        int *Mi, int *S) {
  lua_Integer wall = z->sec + z->offset;
  lua_Integer days = wall >= 0 ? wall / 86400 : (wall - 86399) / 86400;
  lua_Integer rem = wall - days * 86400;
  lua_Integer y;
  unsigned mo, d;
  civil_from_days(days, &y, &mo, &d);
  *Y = y;
  *Mo = (int)mo;
  *D = (int)d;
  *H = (int)(rem / 3600);
  *Mi = (int)((rem % 3600) / 60);
  *S = (int)(rem % 60);
}

/* Given a wall-clock instant `naive` (seconds since the epoch as if UTC),
** resolve it through the zone at `zoneidx`, push the resulting zoned, and
** attach that zone as its user value. One correction pass handles the usual
** DST step; gaps and overlaps resolve to a single deterministic side. */
static void push_zoned_in_zone(lua_State *L, lua_Integer naive, int frac,
                               int zoneidx) {
  l_zone *z = check_zone(L, zoneidx);
  int g = zone_offset_at(z, naive);
  lua_Integer utc = naive - g;
  int g2 = zone_offset_at(z, utc);
  if (g2 != g) {
    utc = naive - g2;
    g = g2;
  }
  push_zoned(L, utc, frac, g);   /* zoned on top */
  lua_pushvalue(L, zoneidx);     /* the zone */
  lua_setiuservalue(L, -2, 1);   /* attach it */
}

/* Rebuild a zoned from a wall-clock instant, re-resolving through its own zone
** when it has one, else keeping its fixed offset. `zonedarg` is the stack index
** of the source zoned. Leaves the new zoned on top. */
static void rebuild_zoned(lua_State *L, int zonedarg, l_zoned *src,
                          lua_Integer naive, int frac) {
  lua_getiuservalue(L, zonedarg, 1); /* zone or nil */
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    push_zoned(L, naive - src->offset, frac, src->offset);
  } else {
    int zi = lua_gettop(L);
    push_zoned_in_zone(L, naive, frac, zi);
    lua_remove(L, zi); /* drop the zone copy left underneath */
  }
}

/*
** {======================================================
** Module functions
** =======================================================
*/

/* Read a wall-clock or monotonic time into (sec, nsec). Returns 1 on success. */
static int read_clock(int monotonic, lua_Integer *sec, int *nsec) {
#if defined(LUS_PLATFORM_WINDOWS)
  if (monotonic) {
    LARGE_INTEGER freq, ctr;
    if (!QueryPerformanceFrequency(&freq) || !QueryPerformanceCounter(&ctr))
      return 0;
    *sec = (lua_Integer)(ctr.QuadPart / freq.QuadPart);
    *nsec = (int)(((ctr.QuadPart % freq.QuadPart) * NANOS_PER_SEC) /
                  freq.QuadPart);
    return 1;
  } else {
    FILETIME ft;
    ULARGE_INTEGER u;
    GetSystemTimePreciseAsFileTime(&ft);
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    /* FILETIME is 100ns ticks since 1601-01-01; 11644473600s to Unix epoch. */
    uint64_t t = u.QuadPart - 116444736000000000ULL;
    *sec = (lua_Integer)(t / 10000000ULL);
    *nsec = (int)((t % 10000000ULL) * 100);
    return 1;
  }
#else
  struct timespec ts;
  clockid_t clk = monotonic ? CLOCK_MONOTONIC : CLOCK_REALTIME;
  if (clock_gettime(clk, &ts) != 0)
    return 0;
  *sec = (lua_Integer)ts.tv_sec;
  *nsec = (int)ts.tv_nsec;
  return 1;
#endif
}

static int time_now(lua_State *L) {
  lua_Integer sec;
  int nsec;
  if (!read_clock(0, &sec, &nsec))
    return luaL_error(L, "failed to read system clock");
  push_instant(L, sec, nsec, 0);
  return 1;
}

static int time_monotonic(lua_State *L) {
  lua_Integer sec;
  int nsec;
  if (!read_clock(1, &sec, &nsec))
    return luaL_error(L, "failed to read monotonic clock");
  push_instant(L, sec, nsec, 1);
  return 1;
}

static int time_instant(lua_State *L) {
  lua_Integer sec = luaL_checkinteger(L, 1);
  lua_Integer nsec = luaL_optinteger(L, 2, 0);
  push_instant(L, sec, (int)(nsec % NANOS_PER_SEC), 0);
  return 1;
}

/* Read an optional integer field from a table. Also accepts an enum value
** (e.g. time.month.july), taking its 1-based index, so the month/weekday enums
** can be used interchangeably with integers in constructors. */
static lua_Integer field(lua_State *L, int arg, const char *key,
                         lua_Integer def) {
  lua_Integer v = def;
  if (lua_getfield(L, arg, key) != LUA_TNIL) {
    if (lua_type(L, -1) == LUA_TENUM)
      v = ((const Enum *)lua_topointer(L, -1))->idx; /* 1-based enum index */
    else
      v = luaL_checkinteger(L, -1);
  }
  lua_pop(L, 1);
  return v;
}

static int time_duration(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer sec = 0;
  sec += field(L, 1, "days", 0) * 86400;
  sec += field(L, 1, "hours", 0) * 3600;
  sec += field(L, 1, "minutes", 0) * 60;
  sec += field(L, 1, "seconds", 0);
  lua_Integer nsec = field(L, 1, "millis", 0) * 1000000 +
                     field(L, 1, "micros", 0) * 1000 + field(L, 1, "nanos", 0);
  push_duration(L, sec, (int)(nsec % NANOS_PER_SEC));
  /* fold whole seconds out of the nanos accumulator */
  {
    l_duration *d = check_duration(L, -1);
    d->sec += nsec / NANOS_PER_SEC;
  }
  return 1;
}

/* Scalar duration helpers: time.seconds(n), time.minutes(n), ... */
static int dur_helper(lua_State *L, lua_Integer unit_sec, lua_Integer unit_ns) {
  lua_Integer n = luaL_checkinteger(L, 1);
  lua_Integer total_ns = n * unit_ns;
  push_duration(L, n * unit_sec + total_ns / NANOS_PER_SEC,
                (int)(total_ns % NANOS_PER_SEC));
  return 1;
}
static int time_days(lua_State *L) { return dur_helper(L, 86400, 0); }
static int time_hours(lua_State *L) { return dur_helper(L, 3600, 0); }
static int time_minutes(lua_State *L) { return dur_helper(L, 60, 0); }
static int time_seconds(lua_State *L) { return dur_helper(L, 1, 0); }
static int time_millis(lua_State *L) { return dur_helper(L, 0, 1000000); }

static int time_zoned(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer year = field(L, 1, "year", 1970);
  lua_Integer month = field(L, 1, "month", 1);
  lua_Integer day = field(L, 1, "day", 1);
  lua_Integer hour = field(L, 1, "hour", 0);
  lua_Integer min = field(L, 1, "minute", 0);
  lua_Integer secf = field(L, 1, "second", 0);
  lua_Integer nsec = field(L, 1, "nanosecond", 0);
  luaL_argcheck(L, month >= 1 && month <= 12, 1, "month out of range");
  luaL_argcheck(L, day >= 1 && day <= 31, 1, "day out of range");
  lua_Integer days = days_from_civil(year, (unsigned)month, (unsigned)day);
  lua_Integer naive = days * 86400 + hour * 3600 + min * 60 + secf; /* wall */
  int frac = (int)(nsec % NANOS_PER_SEC);
  if (luaL_testudata(L, 2, ZONE_METATABLE)) {
    push_zoned_in_zone(L, naive, frac, 2);
  } else {
    int offset = (int)luaL_optinteger(L, 2, 0); /* fixed offset seconds */
    push_zoned(L, naive - offset, frac, offset);
  }
  return 1;
}

/* Read exactly `digits` decimal digits, advancing *pp. Returns 1 on success. */
static int rd_digits(const char **pp, int digits, int *out) {
  const char *p = *pp;
  int v = 0;
  for (int i = 0; i < digits; i++) {
    if (*p < '0' || *p > '9')
      return 0;
    v = v * 10 + (*p - '0');
    p++;
  }
  *out = v;
  *pp = p;
  return 1;
}

/* Read 1..maxd decimal digits, advancing *pp. Returns 1 on success. */
static int rd_num(const char **pp, int maxd, int *out) {
  const char *p = *pp;
  int v = 0, n = 0;
  while (n < maxd && *p >= '0' && *p <= '9') {
    v = v * 10 + (*p - '0');
    p++;
    n++;
  }
  if (n == 0)
    return 0;
  *out = v;
  *pp = p;
  return 1;
}

/* Parse `s` against an explicit strftime-style pattern. Supports the numeric
** field specifiers %Y %y %m %d %e %H %M %S, the zone %z (Z or +/-HH[:]MM), and
** %% for a literal percent; a space in the pattern matches a run of whitespace,
** and any other literal must match exactly. Deliberately portable: it does not
** depend on the platform's strptime. */
static int parse_format(lua_State *L, const char *s, const char *fmt) {
  int Y = 1970, Mo = 1, D = 1, H = 0, Mi = 0, S = 0, off = 0, zoned = 0;
  const char *p = s;
  const char *fmt0 = fmt;
  for (; *fmt; fmt++) {
    if (*fmt == '%') {
      fmt++;
      switch (*fmt) {
      case 'Y':
        if (!rd_num(&p, 4, &Y))
          goto bad;
        break;
      case 'y': {
        int yy;
        if (!rd_num(&p, 2, &yy))
          goto bad;
        Y = 2000 + yy;
        break;
      }
      case 'm':
        if (!rd_num(&p, 2, &Mo))
          goto bad;
        break;
      case 'e': /* space-padded day */
      case 'd':
        while (*p == ' ')
          p++;
        if (!rd_num(&p, 2, &D))
          goto bad;
        break;
      case 'H':
        if (!rd_num(&p, 2, &H))
          goto bad;
        break;
      case 'M':
        if (!rd_num(&p, 2, &Mi))
          goto bad;
        break;
      case 'S':
        if (!rd_num(&p, 2, &S))
          goto bad;
        break;
      case 'z':
        if (*p == 'Z') {
          p++; /* UTC */
        } else if (*p == '+' || *p == '-') {
          int sign = *p == '-' ? -1 : 1, oh, om = 0;
          p++;
          if (!rd_num(&p, 2, &oh))
            goto bad;
          if (*p == ':')
            p++;
          if (*p >= '0' && *p <= '9' && !rd_num(&p, 2, &om))
            goto bad;
          off = sign * (oh * 3600 + om * 60);
          zoned = 1;
        } else {
          goto bad;
        }
        break;
      case '%':
        if (*p != '%')
          goto bad;
        p++;
        break;
      default:
        return luaL_error(L, "unsupported time format specifier '%%%c'", *fmt);
      }
    } else if (*fmt == ' ') {
      while (*p == ' ' || *p == '\t')
        p++;
    } else {
      if (*p != *fmt)
        goto bad;
      p++;
    }
  }
  if (Mo < 1 || Mo > 12 || D < 1 || D > 31)
    goto bad;
  {
    lua_Integer naive = days_from_civil(Y, (unsigned)Mo, (unsigned)D) * 86400 +
                        (lua_Integer)H * 3600 + Mi * 60 + S;
    if (zoned)
      push_zoned(L, naive - off, 0, off);
    else
      push_instant(L, naive, 0, 0);
  }
  return 1;
bad:
  return luaL_error(L, "'%s' does not match time format '%s'", s, fmt0);
}

/* Parse an ISO 8601 date/time (or, with a format argument, an explicit
** pattern). Returns an instant when the input is in UTC ("Z") or carries no
** offset (assumed UTC), or a zoned when it carries an explicit numeric offset. */
static int time_parse(lua_State *L) {
  const char *s = luaL_checkstring(L, 1);
  if (!lua_isnoneornil(L, 2))
    return parse_format(L, s, luaL_checkstring(L, 2));
  const char *p = s;
  int y, mo, d, hh = 0, mi = 0, ss = 0;
  int frac = 0, off = 0, zoned = 0;

  if (!rd_digits(&p, 4, &y) || *p++ != '-' || !rd_digits(&p, 2, &mo) ||
      *p++ != '-' || !rd_digits(&p, 2, &d))
    return luaL_error(L, "invalid ISO 8601 date in '%s'", s);
  if (mo < 1 || mo > 12 || d < 1 || d > 31)
    return luaL_error(L, "ISO 8601 date out of range in '%s'", s);

  if (*p == 'T' || *p == ' ') {
    p++;
    if (!rd_digits(&p, 2, &hh) || *p++ != ':' || !rd_digits(&p, 2, &mi))
      return luaL_error(L, "invalid ISO 8601 time in '%s'", s);
    if (*p == ':') {
      p++;
      if (!rd_digits(&p, 2, &ss))
        return luaL_error(L, "invalid ISO 8601 seconds in '%s'", s);
    }
    if (*p == '.' || *p == ',') { /* fractional seconds, up to 9 digits */
      p++;
      int scale = NANOS_PER_SEC / 10;
      if (*p < '0' || *p > '9')
        return luaL_error(L, "invalid fractional seconds in '%s'", s);
      while (*p >= '0' && *p <= '9') {
        if (scale >= 1) {
          frac += (*p - '0') * scale;
          scale /= 10;
        }
        p++;
      }
    }
    if (*p == 'Z') {
      p++; /* UTC */
    } else if (*p == '+' || *p == '-') {
      int sign = *p == '-' ? -1 : 1;
      int oh, om = 0;
      p++;
      if (!rd_digits(&p, 2, &oh))
        return luaL_error(L, "invalid zone offset in '%s'", s);
      if (*p == ':')
        p++;
      if (*p >= '0' && *p <= '9' && !rd_digits(&p, 2, &om))
        return luaL_error(L, "invalid zone offset in '%s'", s);
      off = sign * (oh * 3600 + om * 60);
      zoned = 1;
    }
  }
  while (*p == ' ')
    p++;
  if (*p != '\0')
    return luaL_error(L, "trailing characters in '%s'", s);

  lua_Integer days = days_from_civil(y, (unsigned)mo, (unsigned)d);
  lua_Integer naive = days * 86400 + hh * 3600 + mi * 60 + ss;
  if (zoned)
    push_zoned(L, naive - off, frac, off);
  else
    push_instant(L, naive, frac, 0); /* Z or no offset -> UTC instant */
  return 1;
}

static int time_zone(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  if (!lookup_zone(L, name))
    return luaL_error(L, "unknown time zone '%s'", name);
  return 1;
}

static int time_offset(lua_State *L) {
  lua_Integer secs = luaL_checkinteger(L, 1);
  luaL_argcheck(L, secs >= -24 * 3600 && secs <= 24 * 3600, 1,
                "offset out of range");
  char name[16];
  int a = secs < 0 ? -(int)secs : (int)secs;
  snprintf(name, sizeof(name), "%c%02d:%02d", secs < 0 ? '-' : '+', a / 3600,
           (a % 3600) / 60);
  push_fixed_zone(L, (int)secs, name);
  return 1;
}

/* Resolve the system's local IANA zone name into buf. Returns 1 on success. */
static int detect_local_zone(char *buf, size_t bufsz) {
#if defined(LUS_PLATFORM_WINDOWS)
  DYNAMIC_TIME_ZONE_INFORMATION dtzi;
  if (GetDynamicTimeZoneInformation(&dtzi) != TIME_ZONE_ID_INVALID) {
    char key[128];
    int n = WideCharToMultiByte(CP_UTF8, 0, dtzi.TimeZoneKeyName, -1, key,
                                (int)sizeof(key), NULL, NULL);
    if (n > 0) {
      const char *iana = lus_windows_to_iana(key);
      if (iana) {
        snprintf(buf, bufsz, "%s", iana);
        return 1;
      }
    }
  }
  return 0;
#else
  const char *tz = getenv("TZ");
  if (tz && *tz) {
    if (*tz == ':')
      tz++;
    if (*tz == '/') { /* absolute path into a zoneinfo tree */
      const char *zi = strstr(tz, "/zoneinfo/");
      if (zi) {
        snprintf(buf, bufsz, "%s", zi + 10);
        return 1;
      }
    } else if (*tz) { /* a bare zone name (POSIX TZ rules are not resolved) */
      snprintf(buf, bufsz, "%s", tz);
      return 1;
    }
  }
  /* /etc/localtime is normally a symlink into the zoneinfo tree. */
  char link[512];
  ssize_t n = readlink("/etc/localtime", link, sizeof(link) - 1);
  if (n > 0) {
    link[n] = '\0';
    const char *zi = strstr(link, "/zoneinfo/");
    if (zi) {
      snprintf(buf, bufsz, "%s", zi + 10);
      return 1;
    }
  }
  /* Debian and derivatives record the name in /etc/timezone. */
  FILE *f = fopen("/etc/timezone", "r");
  if (f) {
    if (fgets(buf, (int)bufsz, f)) {
      size_t l = strlen(buf);
      while (l && (buf[l - 1] == '\n' || buf[l - 1] == '\r' ||
                   buf[l - 1] == ' '))
        buf[--l] = '\0';
      fclose(f);
      return buf[0] != '\0';
    }
    fclose(f);
  }
  return 0;
#endif
}

static int time_localzone(lua_State *L) {
  char name[256];
  if (detect_local_zone(name, sizeof(name)) && lookup_zone(L, name))
    return 1;
  push_fixed_zone(L, 0, "UTC"); /* fall back to UTC when detection fails */
  return 1;
}

static int time_tzdata_version(lua_State *L) {
  lua_pushstring(L, lus_tzdata_version);
  return 1;
}

/*
** {======================================================
** Formatting shared by instant and zoned
** =======================================================
*/

/* Format the wall-clock seconds (already offset-adjusted) with strftime. */
static int format_wall(lua_State *L, lua_Integer wall_sec, int nsec,
                       const char *fmt) {
  lua_Integer days =
      wall_sec >= 0 ? wall_sec / 86400 : (wall_sec - 86399) / 86400;
  lua_Integer rem = wall_sec - days * 86400;
  lua_Integer y;
  unsigned mo, d;
  civil_from_days(days, &y, &mo, &d);
  struct tm tm;
  memset(&tm, 0, sizeof(tm));
  tm.tm_year = (int)(y - 1900);
  tm.tm_mon = (int)mo - 1;
  tm.tm_mday = (int)d;
  tm.tm_hour = (int)(rem / 3600);
  tm.tm_min = (int)((rem % 3600) / 60);
  tm.tm_sec = (int)(rem % 60);
  tm.tm_wday = weekday_from_days(days) % 7; /* strftime wants 0 = Sunday */
  tm.tm_yday = (int)(days - days_from_civil(y, 1, 1));
  char buf[256];
  size_t n = strftime(buf, sizeof(buf), fmt, &tm);
  if (n == 0 && fmt[0] != '\0') {
    /* Output did not fit; report rather than silently truncate. */
    return luaL_error(L, "formatted time exceeds buffer");
  }
  (void)nsec;
  lua_pushlstring(L, buf, n);
  return 1;
}

/*
** {======================================================
** instant methods + metamethods
** =======================================================
*/

static int inst_reject_mono(lua_State *L, l_instant *i) {
  if (i->mono)
    return luaL_error(L, "monotonic instants have no calendar representation");
  return 0;
}

static int inst_epoch(lua_State *L) {
  l_instant *i = check_instant(L, 1);
  inst_reject_mono(L, i);
  lua_pushinteger(L, i->sec);
  return 1;
}

static int inst_nanos(lua_State *L) {
  l_instant *i = check_instant(L, 1);
  lua_pushinteger(L, i->nsec);
  return 1;
}

static int inst_format(lua_State *L) {
  l_instant *i = check_instant(L, 1);
  const char *fmt = luaL_optstring(L, 2, "%Y-%m-%dT%H:%M:%SZ");
  inst_reject_mono(L, i);
  return format_wall(L, i->sec, i->nsec, fmt);
}

static int inst_iso(lua_State *L) {
  l_instant *i = check_instant(L, 1);
  inst_reject_mono(L, i);
  return format_wall(L, i->sec, i->nsec, "%Y-%m-%dT%H:%M:%SZ");
}

static int inst_in(lua_State *L) {
  l_instant *i = check_instant(L, 1);
  inst_reject_mono(L, i);
  if (luaL_testudata(L, 2, ZONE_METATABLE)) {
    int offset = zone_offset_at(check_zone(L, 2), i->sec);
    push_zoned(L, i->sec, i->nsec, offset);
    lua_pushvalue(L, 2); /* remember the zone for later calendar ops */
    lua_setiuservalue(L, -2, 1);
  } else {
    int offset = (int)luaL_checkinteger(L, 2); /* fixed offset seconds */
    push_zoned(L, i->sec, i->nsec, offset);
  }
  return 1;
}

static int inst_add(lua_State *L) {
  l_instant *i = check_instant(L, 1);
  l_duration *d = check_duration(L, 2);
  push_instant(L, i->sec + d->sec, i->nsec + d->nsec, i->mono);
  return 1;
}

/* i + duration -> instant */
static int inst_meta_add(lua_State *L) {
  l_instant *i = check_instant(L, 1);
  l_duration *d = check_duration(L, 2);
  push_instant(L, i->sec + d->sec, i->nsec + d->nsec, i->mono);
  return 1;
}

/* i - duration -> instant ; i - instant -> duration */
static int inst_meta_sub(lua_State *L) {
  l_instant *i = check_instant(L, 1);
  if (luaL_testudata(L, 2, INSTANT_METATABLE)) {
    l_instant *j = check_instant(L, 2);
    if (i->mono != j->mono)
      return luaL_error(L, "cannot subtract instants from different clocks");
    push_duration(L, i->sec - j->sec, i->nsec - j->nsec);
  } else {
    l_duration *d = check_duration(L, 2);
    push_instant(L, i->sec - d->sec, i->nsec - d->nsec, i->mono);
  }
  return 1;
}

static int inst_meta_eq(lua_State *L) {
  l_instant *a = check_instant(L, 1);
  l_instant *b = check_instant(L, 2);
  lua_pushboolean(L, a->sec == b->sec && a->nsec == b->nsec &&
                         a->mono == b->mono);
  return 1;
}

static int inst_meta_lt(lua_State *L) {
  l_instant *a = check_instant(L, 1);
  l_instant *b = check_instant(L, 2);
  lua_pushboolean(L, a->sec < b->sec || (a->sec == b->sec && a->nsec < b->nsec));
  return 1;
}

static int inst_meta_le(lua_State *L) {
  l_instant *a = check_instant(L, 1);
  l_instant *b = check_instant(L, 2);
  lua_pushboolean(L, a->sec < b->sec ||
                         (a->sec == b->sec && a->nsec <= b->nsec));
  return 1;
}

static int inst_meta_tostring(lua_State *L) {
  l_instant *i = check_instant(L, 1);
  if (i->mono) {
    lua_pushfstring(L, "time.instant(monotonic %I s + %d ns)", i->sec, i->nsec);
    return 1;
  }
  return format_wall(L, i->sec, i->nsec, "%Y-%m-%dT%H:%M:%SZ");
}

/*
** {======================================================
** duration methods + metamethods
** =======================================================
*/

static int dur_seconds(lua_State *L) {
  l_duration *d = check_duration(L, 1);
  lua_pushnumber(L, (lua_Number)d->sec + (lua_Number)d->nsec / NANOS_PER_SEC);
  return 1;
}

static int dur_millis(lua_State *L) {
  l_duration *d = check_duration(L, 1);
  lua_pushnumber(L, (lua_Number)d->sec * 1000.0 +
                        (lua_Number)d->nsec / 1000000.0);
  return 1;
}

static int dur_parts(lua_State *L) {
  l_duration *d = check_duration(L, 1);
  /* Break the absolute magnitude into components; report the sign separately. */
  int neg = (d->sec < 0);
  lua_Integer s;
  lua_Integer nanos;
  if (!neg) {
    s = d->sec;
    nanos = d->nsec;
  } else {
    s = -d->sec;
    nanos = d->nsec;
    if (nanos != 0) { /* borrow: |sec + nsec/1e9| */
      s -= 1;
      nanos = NANOS_PER_SEC - nanos;
    }
  }
  lua_newtable(L);
  lua_pushboolean(L, neg);
  lua_setfield(L, -2, "negative");
  lua_pushinteger(L, s / 86400);
  lua_setfield(L, -2, "days");
  lua_pushinteger(L, (s % 86400) / 3600);
  lua_setfield(L, -2, "hours");
  lua_pushinteger(L, (s % 3600) / 60);
  lua_setfield(L, -2, "minutes");
  lua_pushinteger(L, s % 60);
  lua_setfield(L, -2, "seconds");
  lua_pushinteger(L, nanos);
  lua_setfield(L, -2, "nanos");
  return 1;
}

static int dur_meta_add(lua_State *L) {
  l_duration *a = check_duration(L, 1);
  l_duration *b = check_duration(L, 2);
  push_duration(L, a->sec + b->sec, a->nsec + b->nsec);
  return 1;
}

static int dur_meta_sub(lua_State *L) {
  l_duration *a = check_duration(L, 1);
  l_duration *b = check_duration(L, 2);
  push_duration(L, a->sec - b->sec, a->nsec - b->nsec);
  return 1;
}

static int dur_meta_mul(lua_State *L) {
  /* duration * integer (either operand order) */
  l_duration *d;
  lua_Integer k;
  if (luaL_testudata(L, 1, DURATION_METATABLE)) {
    d = check_duration(L, 1);
    k = luaL_checkinteger(L, 2);
  } else {
    k = luaL_checkinteger(L, 1);
    d = check_duration(L, 2);
  }
  push_duration(L, d->sec * k, (int)((lua_Integer)d->nsec * k % NANOS_PER_SEC));
  {
    l_duration *r = check_duration(L, -1);
    r->sec += (lua_Integer)d->nsec * k / NANOS_PER_SEC;
  }
  return 1;
}

static int dur_meta_unm(lua_State *L) {
  l_duration *d = check_duration(L, 1);
  push_duration(L, -d->sec, -d->nsec);
  return 1;
}

static int dur_cmp(l_duration *a, l_duration *b) {
  if (a->sec != b->sec)
    return a->sec < b->sec ? -1 : 1;
  if (a->nsec != b->nsec)
    return a->nsec < b->nsec ? -1 : 1;
  return 0;
}

static int dur_meta_eq(lua_State *L) {
  lua_pushboolean(L, dur_cmp(check_duration(L, 1), check_duration(L, 2)) == 0);
  return 1;
}
static int dur_meta_lt(lua_State *L) {
  lua_pushboolean(L, dur_cmp(check_duration(L, 1), check_duration(L, 2)) < 0);
  return 1;
}
static int dur_meta_le(lua_State *L) {
  lua_pushboolean(L, dur_cmp(check_duration(L, 1), check_duration(L, 2)) <= 0);
  return 1;
}

static int dur_meta_tostring(lua_State *L) {
  l_duration *d = check_duration(L, 1);
  lua_pushfstring(L, "time.duration(%I s + %d ns)", d->sec, d->nsec);
  return 1;
}

/*
** {======================================================
** zoned field access + methods
** =======================================================
*/

static int zoned_instant(lua_State *L) {
  l_zoned *z = check_zoned(L, 1);
  push_instant(L, z->sec, z->nsec, 0);
  return 1;
}

static int zoned_format(lua_State *L) {
  l_zoned *z = check_zoned(L, 1);
  const char *fmt = luaL_optstring(L, 2, "%Y-%m-%dT%H:%M:%S");
  return format_wall(L, z->sec + z->offset, z->nsec, fmt);
}

static int zoned_iso(lua_State *L) {
  l_zoned *z = check_zoned(L, 1);
  format_wall(L, z->sec + z->offset, z->nsec, "%Y-%m-%dT%H:%M:%S"); /* pushes */
  int off = z->offset;
  if (off == 0) {
    lua_pushliteral(L, "Z");
  } else {
    char sign = off < 0 ? '-' : '+';
    int a = off < 0 ? -off : off;
    char buf[16];
    snprintf(buf, sizeof(buf), "%c%02d:%02d", sign, a / 3600, (a % 3600) / 60);
    lua_pushstring(L, buf);
  }
  lua_concat(L, 2);
  return 1;
}

/* Immutable field replacement. Given fields override the current wall-clock
** components; the result is re-resolved through the zone (so replacing the hour
** across a DST boundary yields the correct offset). */
static int zoned_with(lua_State *L) {
  l_zoned *z = check_zoned(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_Integer Y;
  int Mo, D, H, Mi, S;
  zoned_civil(z, &Y, &Mo, &D, &H, &Mi, &S);
  lua_Integer nsec = z->nsec;
  Y = field(L, 2, "year", Y);
  Mo = (int)field(L, 2, "month", Mo);
  D = (int)field(L, 2, "day", D);
  H = (int)field(L, 2, "hour", H);
  Mi = (int)field(L, 2, "minute", Mi);
  S = (int)field(L, 2, "second", S);
  nsec = field(L, 2, "nanosecond", nsec);
  luaL_argcheck(L, Mo >= 1 && Mo <= 12, 2, "month out of range");
  luaL_argcheck(L, D >= 1 && D <= 31, 2, "day out of range");
  lua_Integer naive = days_from_civil(Y, (unsigned)Mo, (unsigned)D) * 86400 +
                      (lua_Integer)H * 3600 + Mi * 60 + S;
  rebuild_zoned(L, 1, z, naive, (int)(nsec % NANOS_PER_SEC));
  return 1;
}

/* Calendar arithmetic. All components move the wall clock (not the absolute
** instant), then the result is re-resolved through the zone, so `:add{days=1}`
** lands on the same wall time the next day even across a DST change. Years and
** months are applied first, clamping the day to the target month's length. */
static int zoned_add(lua_State *L) {
  l_zoned *z = check_zoned(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_Integer Y;
  int Mo, D, H, Mi, S;
  zoned_civil(z, &Y, &Mo, &D, &H, &Mi, &S);

  Y += field(L, 2, "years", 0);
  lua_Integer m0 = (lua_Integer)(Mo - 1) + field(L, 2, "months", 0);
  Y += floordiv(m0, 12);
  Mo = (int)(m0 - floordiv(m0, 12) * 12) + 1; /* 1..12 */
  int dim = days_in_month(Y, Mo);
  if (D > dim)
    D = dim; /* e.g. Jan 31 + 1 month -> Feb 28/29 */

  lua_Integer dayCount = days_from_civil(Y, (unsigned)Mo, (unsigned)D) +
                        field(L, 2, "weeks", 0) * 7 + field(L, 2, "days", 0);
  lua_Integer secOfDay = (lua_Integer)H * 3600 + Mi * 60 + S +
                        field(L, 2, "hours", 0) * 3600 +
                        field(L, 2, "minutes", 0) * 60 +
                        field(L, 2, "seconds", 0);
  lua_Integer nsecTotal = (lua_Integer)z->nsec + field(L, 2, "nanos", 0);
  lua_Integer naive = dayCount * 86400 + secOfDay + floordiv(nsecTotal,
                                                             NANOS_PER_SEC);
  int frac = (int)(nsecTotal - floordiv(nsecTotal, NANOS_PER_SEC) *
                                   NANOS_PER_SEC);
  rebuild_zoned(L, 1, z, naive, frac);
  return 1;
}

/* __index handler: exposes both civil fields and methods. */
static int zoned_index(lua_State *L) {
  l_zoned *z = check_zoned(L, 1);
  const char *k = lua_tostring(L, 2);
  if (k == NULL) {
    lua_pushnil(L);
    return 1;
  }
  /* Method lookup first. */
  luaL_getmetatable(L, ZONED_METATABLE);
  lua_getfield(L, -1, "__methods");
  lua_getfield(L, -1, k);
  if (!lua_isnil(L, -1))
    return 1;
  lua_pop(L, 3);

  lua_Integer wall = z->sec + z->offset;
  lua_Integer days = wall >= 0 ? wall / 86400 : (wall - 86399) / 86400;
  lua_Integer rem = wall - days * 86400;
  lua_Integer y;
  unsigned mo, d;
  civil_from_days(days, &y, &mo, &d);
  if (strcmp(k, "year") == 0)
    lua_pushinteger(L, y);
  else if (strcmp(k, "month") == 0)
    lua_pushinteger(L, mo);
  else if (strcmp(k, "day") == 0)
    lua_pushinteger(L, d);
  else if (strcmp(k, "hour") == 0)
    lua_pushinteger(L, rem / 3600);
  else if (strcmp(k, "minute") == 0)
    lua_pushinteger(L, (rem % 3600) / 60);
  else if (strcmp(k, "second") == 0)
    lua_pushinteger(L, rem % 60);
  else if (strcmp(k, "nanosecond") == 0)
    lua_pushinteger(L, z->nsec);
  else if (strcmp(k, "weekday") == 0) {
    /* Return the time.weekday enum value (monday..sunday). */
    lua_getfield(L, LUA_REGISTRYINDEX, WEEKDAY_KEY);
    lua_geti(L, -1, weekday_from_days(days)); /* enum[idx] -> sibling value */
    lua_remove(L, -2);                        /* drop the enum root */
  } else if (strcmp(k, "yearday") == 0)
    lua_pushinteger(L, days - days_from_civil(y, 1, 1) + 1);
  else if (strcmp(k, "offset") == 0)
    lua_pushinteger(L, z->offset);
  else
    lua_pushnil(L);
  return 1;
}

static int zoned_meta_tostring(lua_State *L) {
  return zoned_iso(L);
}

/*
** {======================================================
** zone methods
** =======================================================
*/

static int zone_name(lua_State *L) {
  check_zone(L, 1);
  lua_getiuservalue(L, 1, 1); /* the name string */
  return 1;
}

static int zone_offset_method(lua_State *L) {
  l_zone *z = check_zone(L, 1);
  l_instant *i = check_instant(L, 2);
  inst_reject_mono(L, i);
  lua_pushinteger(L, zone_offset_at(z, i->sec));
  return 1;
}

static int zone_meta_tostring(lua_State *L) {
  check_zone(L, 1);
  lua_getiuservalue(L, 1, 1);
  return 1;
}

/*
** {======================================================
** Registration
** =======================================================
*/

static const luaL_Reg instant_methods[] = {
    {"epoch", inst_epoch},   {"nanos", inst_nanos}, {"format", inst_format},
    {"iso", inst_iso},       {"at", inst_in},       {"add", inst_add},
    {NULL, NULL}};

static const luaL_Reg instant_meta[] = {{"__add", inst_meta_add},
                                        {"__sub", inst_meta_sub},
                                        {"__eq", inst_meta_eq},
                                        {"__lt", inst_meta_lt},
                                        {"__le", inst_meta_le},
                                        {"__tostring", inst_meta_tostring},
                                        {NULL, NULL}};

static const luaL_Reg duration_methods[] = {{"seconds", dur_seconds},
                                            {"millis", dur_millis},
                                            {"parts", dur_parts},
                                            {NULL, NULL}};

static const luaL_Reg duration_meta[] = {{"__add", dur_meta_add},
                                         {"__sub", dur_meta_sub},
                                         {"__mul", dur_meta_mul},
                                         {"__unm", dur_meta_unm},
                                         {"__eq", dur_meta_eq},
                                         {"__lt", dur_meta_lt},
                                         {"__le", dur_meta_le},
                                         {"__tostring", dur_meta_tostring},
                                         {NULL, NULL}};

static const luaL_Reg zoned_methods[] = {{"instant", zoned_instant},
                                         {"format", zoned_format},
                                         {"iso", zoned_iso},
                                         {"with", zoned_with},
                                         {"add", zoned_add},
                                         {NULL, NULL}};

static const luaL_Reg zone_methods[] = {{"name", zone_name},
                                        {"offset", zone_offset_method},
                                        {NULL, NULL}};

static const luaL_Reg zone_meta[] = {{"__tostring", zone_meta_tostring},
                                     {NULL, NULL}};

static const luaL_Reg time_funcs[] = {{"now", time_now},
                                      {"monotonic", time_monotonic},
                                      {"instant", time_instant},
                                      {"zoned", time_zoned},
                                      {"duration", time_duration},
                                      {"parse", time_parse},
                                      {"zone", time_zone},
                                      {"offset", time_offset},
                                      {"localzone", time_localzone},
                                      {"days", time_days},
                                      {"hours", time_hours},
                                      {"minutes", time_minutes},
                                      {"seconds", time_seconds},
                                      {"millis", time_millis},
                                      {"tzdata_version", time_tzdata_version},
                                      {NULL, NULL}};

/* Build a first-class enum from `names` (1-based) and leave it on the stack. */
static void build_enum(lua_State *L, const char *const *names, int n) {
  for (int i = 0; i < n; i++) {
    lua_pushstring(L, names[i]);
    lua_pushinteger(L, i + 1);
  }
  lua_pushenum(L, n); /* consumes the 2n pairs, pushes the enum value */
}

/* Create a metatable whose __index is a methods subtable. */
static void make_simple_meta(lua_State *L, const char *name,
                             const luaL_Reg *methods, const luaL_Reg *meta) {
  luaL_newmetatable(L, name);
  luaL_setfuncs(L, meta, 0);
  lua_newtable(L);
  luaL_setfuncs(L, methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable"); /* hide the metatable */
  lua_pop(L, 1);
}

LUAMOD_API int luaopen_time(lua_State *L) {
  make_simple_meta(L, INSTANT_METATABLE, instant_methods, instant_meta);
  make_simple_meta(L, DURATION_METATABLE, duration_methods, duration_meta);
  make_simple_meta(L, ZONE_METATABLE, zone_methods, zone_meta);

  /* zoned needs a function __index for computed fields; stash methods aside. */
  luaL_newmetatable(L, ZONED_METATABLE);
  lua_pushcfunction(L, zoned_index);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, zoned_meta_tostring);
  lua_setfield(L, -2, "__tostring");
  lua_newtable(L);
  luaL_setfuncs(L, zoned_methods, 0);
  lua_setfield(L, -2, "__methods");
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable");
  lua_pop(L, 1);

  luaL_newlib(L, time_funcs);

  /* First-class weekday (ISO: Monday = 1) and month (January = 1) enums. */
  static const char *const wd[] = {"monday",   "tuesday", "wednesday",
                                   "thursday", "friday",  "saturday",
                                   "sunday"};
  static const char *const mo[] = {"january", "february", "march",
                                   "april",   "may",      "june",
                                   "july",    "august",   "september",
                                   "october", "november", "december"};
  build_enum(L, wd, 7);
  lua_pushvalue(L, -1);
  lua_setfield(L, LUA_REGISTRYINDEX, WEEKDAY_KEY); /* anchor for zoned.weekday */
  lua_setfield(L, -2, "weekday");
  build_enum(L, mo, 12);
  lua_setfield(L, -2, "month");
  return 1;
}
