/*
** $Id: ltimecore.h $
** Shared value layout and scalar arithmetic for the time module.
** ltimelib.c and the fastcall intrinsics in lfastcall.c both include
** this header, so the C path and the fast path share one
** implementation by construction. Only the pieces the intrinsics need
** live here. The zoned and zone types stay private to ltimelib.c.
** See Copyright Notice in lua.h
*/

#ifndef ltimecore_h
#define ltimecore_h

#include "llimits.h"
#include "lua.h"

#define LUS_INSTANT_MT "time.instant"
#define LUS_DURATION_MT "time.duration"

#define LUS_NANOS_PER_SEC 1000000000

/* Absolute point on the timeline. When `mono` is set the value comes from a
** monotonic clock and is only meaningful when subtracted from another reading
** of the same clock. Formatting or epoch extraction is rejected. */
typedef struct {
  lua_Integer sec; /* seconds since the Unix epoch (or since an arbitrary
                      monotonic origin when mono != 0) */
  int nsec;        /* normalized: 0 <= nsec < LUS_NANOS_PER_SEC */
  int mono;        /* 1 if read from a monotonic clock */
} l_instant;

/* A signed span. Sign lives in `sec`, and `nsec` is always in
** [0, LUS_NANOS_PER_SEC). */
typedef struct {
  lua_Integer sec;
  int nsec;
} l_duration;

/* Checked integer helpers shared by time constructors and arithmetic. */
l_sinline int lus_time_add_checked(lua_Integer a, lua_Integer b,
                                   lua_Integer *result) {
  if ((b > 0 && a > LUA_MAXINTEGER - b) || (b < 0 && a < LUA_MININTEGER - b))
    return 0;
  *result = a + b;
  return 1;
}

l_sinline int lus_time_sub_checked(lua_Integer a, lua_Integer b,
                                   lua_Integer *result) {
  if ((b > 0 && a < LUA_MININTEGER + b) || (b < 0 && a > LUA_MAXINTEGER + b))
    return 0;
  *result = a - b;
  return 1;
}

l_sinline int lus_time_mul_checked(lua_Integer a, lua_Integer b,
                                   lua_Integer *result) {
  int negative = (a < 0) != (b < 0);
  lua_Unsigned ua = a < 0 ? 0u - l_castS2U(a) : l_castS2U(a);
  lua_Unsigned ub = b < 0 ? 0u - l_castS2U(b) : l_castS2U(b);
  lua_Unsigned limit = l_castS2U(LUA_MAXINTEGER) + cast(lua_Unsigned, negative);
  lua_Unsigned product;
  if (ub != 0 && ua > limit / ub)
    return 0;
  product = ua * ub;
  *result = negative ? l_castU2S(0u - product) : l_castU2S(product);
  return 1;
}

/* Fold nanosecond overflow while keeping the seconds value representable. */
l_sinline int lus_time_norm_checked(lua_Integer sec, lua_Integer nsec,
                                    lua_Integer *outsec, int *outnsec) {
  lua_Integer carry = nsec / LUS_NANOS_PER_SEC;
  lua_Integer rem = nsec % LUS_NANOS_PER_SEC;
  if (!lus_time_add_checked(sec, carry, &sec))
    return 0;
  if (rem < 0) {
    rem += LUS_NANOS_PER_SEC;
    if (!lus_time_sub_checked(sec, 1, &sec))
      return 0;
  }
  *outsec = sec;
  *outnsec = cast_int(rem);
  return 1;
}

/* The intrinsic uses this only after proving that normalization is safe. */
l_sinline void lus_time_norm(lua_Integer *sec, int *nsec) {
  lua_Integer outsec = 0;
  int outnsec = 0;
  int ok = lus_time_norm_checked(*sec, *nsec, &outsec, &outnsec);
  lua_assert(ok);
  (void)ok;
  *sec = outsec;
  *nsec = outnsec;
}

/*
** Scalar duration arithmetic shared by the C constructors and the
** FC_TIME_* intrinsics. Splitting nanosecond units into quotient and
** remainder avoids an overflowing intermediate for large millisecond
** counts whose normalized duration still fits.
*/
l_sinline int lus_dur_compute_checked(lua_Integer n, lua_Integer unit_sec,
                                      lua_Integer unit_ns, lua_Integer *sec,
                                      int *nsec) {
  lua_Integer result_sec;
  lua_Integer whole_ns;
  lua_Integer rem_ns;
  lua_Integer rem_product;
  lua_Integer carry;
  if (!lus_time_mul_checked(n, unit_sec, &result_sec))
    return 0;
  whole_ns = n / LUS_NANOS_PER_SEC;
  rem_ns = n % LUS_NANOS_PER_SEC;
  if (!lus_time_mul_checked(whole_ns, unit_ns, &whole_ns) ||
      !lus_time_mul_checked(rem_ns, unit_ns, &rem_product) ||
      !lus_time_add_checked(result_sec, whole_ns, &result_sec))
    return 0;
  carry = rem_product / LUS_NANOS_PER_SEC;
  if (!lus_time_add_checked(result_sec, carry, &result_sec))
    return 0;
  return lus_time_norm_checked(result_sec, rem_product % LUS_NANOS_PER_SEC, sec,
                               nsec);
}

l_sinline void lus_dur_compute(lua_Integer n, lua_Integer unit_sec,
                               lua_Integer unit_ns, lua_Integer *sec,
                               int *nsec) {
  int ok = lus_dur_compute_checked(n, unit_sec, unit_ns, sec, nsec);
  lua_assert(ok);
  (void)ok;
}

#endif
