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

/* Fold overflow/underflow so 0 <= nsec < LUS_NANOS_PER_SEC. */
l_sinline void lus_time_norm(lua_Integer *sec, int *nsec) {
  *sec += *nsec / LUS_NANOS_PER_SEC;
  *nsec %= LUS_NANOS_PER_SEC;
  if (*nsec < 0) {
    *nsec += LUS_NANOS_PER_SEC;
    *sec -= 1;
  }
}

/*
** Scalar duration arithmetic shared by the C constructors and the
** FC_TIME_* intrinsics. The multiplications use unsigned arithmetic,
** which keeps out-of-range inputs defined (two's complement wrap, the
** behavior every supported target already produced) under the
** sanitizer builds. The intrinsics decline any input whose product
** would overflow, so only the C path ever exercises the wraparound.
*/
l_sinline void lus_dur_compute(lua_Integer n, lua_Integer unit_sec,
                               lua_Integer unit_ns, lua_Integer *sec,
                               int *nsec) {
  lua_Integer total_ns = l_castU2S(l_castS2U(n) * l_castS2U(unit_ns));
  *sec = l_castU2S(l_castS2U(n) * l_castS2U(unit_sec) +
                   l_castS2U(total_ns / LUS_NANOS_PER_SEC));
  *nsec = (int)(total_ns % LUS_NANOS_PER_SEC);
  lus_time_norm(sec, nsec);
}

#endif
