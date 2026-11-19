/*
** Userdata with a registered metatable: methods, type checks, and a
** finalizer that runs on collection and when the state closes.
*/

#include "check.h"

typedef struct Point {
  double x, y;
  int *alive; /* counts live points in the host */
} Point;

static int live_points = 0;

static Point *check_point(lus_State *L, int idx) {
  return (Point *)lus_toudata(L, idx, "Point");
}

/* Point.new(x, y) */
static int point_new(lus_State *L) {
  Point *p = (Point *)lus_newuserdata(L, sizeof(Point));
  if (p == NULL)
    return lus_error(L);
  p->x = lus_tonumber(L, 1, NULL);
  p->y = lus_tonumber(L, 2, NULL);
  p->alive = &live_points;
  live_points++;
  lus_getmetatable(L, "Point");
  if (lus_setmetatable(L, -2) != LUS_OK)
    return lus_error(L);
  return 1;
}

/* point:length2() */
static int point_length2(lus_State *L) {
  Point *p = check_point(L, 1);
  if (p == NULL)
    return lus_errorf(L, "bad self: Point expected, got %s",
                      lus_typename(lus_type(L, 1)));
  lus_pushnumber(L, p->x * p->x + p->y * p->y);
  return 1;
}

/* The finalizer releases the host resource. */
static int point_gc(lus_State *L) {
  Point *p = check_point(L, 1);
  if (p != NULL)
    (*p->alive)--;
  return 0;
}

static void register_point(lus_State *L) {
  CHECK(lus_newmetatable(L, "Point") == 1);
  CHECK_OK(L, lus_newtable(L, 0, 2));
  CHECK_OK(L, lus_pushcfunction(L, point_length2));
  CHECK_OK(L, lus_setfield(L, -2, "length2"));
  CHECK_OK(L, lus_setfield(L, -2, "__index"));
  CHECK_OK(L, lus_pushcfunction(L, point_gc));
  CHECK_OK(L, lus_setfield(L, -2, "__gc"));
  lus_pop(L, 1);
  /* A second call finds the same table. */
  CHECK(lus_newmetatable(L, "Point") == 0);
  CHECK_OK(L, lus_getfield(L, -1, "__name"));
  CHECK_STR(L, -1, "Point");
  lus_pop(L, 2);

  CHECK_OK(L, lus_newtable(L, 0, 1));
  CHECK_OK(L, lus_pushcfunction(L, point_new));
  CHECK_OK(L, lus_setfield(L, -2, "new"));
  CHECK_OK(L, lus_setglobal(L, "Point"));
}

int main(void) {
  lus_State *L = lus_newstate();
  CHECK_OK(L, lus_openlibs(L));
  register_point(L);

  CHECK_OK(L, lus_dostring(L, "local p = Point.new(3, 4) return p:length2(), p"));
  CHECK(lus_tonumber(L, 1, NULL) == 25.0);
  CHECK(lus_type(L, 2) == LUS_TUSERDATA);
  Point *p = check_point(L, 2);
  CHECK(p != NULL && p->x == 3.0 && p->y == 4.0);
  CHECK(((uintptr_t)p % 8) == 0);
  CHECK(lus_touserdata(L, 2) == p);
  CHECK(live_points == 1);

  /* The name check rejects other userdata. */
  lus_newuserdata(L, 4);
  CHECK(check_point(L, -1) == NULL);
  CHECK(lus_toudata(L, 2, "Other") == NULL);

  /* Type errors raised from C reach the script with a position. */
  CHECK(lus_dostring(L, "local m = Point.new(1, 1).length2 return m({})") ==
        LUS_ERRRUN);
  CHECK_HAS(L, -1, "bad self: Point expected, got table");
  CHECK_HAS(L, -1, "(dostring):1:");
  lus_settop(L, 0);
  /* One point was created and dropped by the failed chunk. */
  CHECK(live_points == 2);

  /* Unreachable points are finalized by a collection. */
  lus_collect(L);
  CHECK(live_points == 0);

  /* Points still alive run their finalizer when the state closes. */
  CHECK_OK(L, lus_dostring(L, "keep = { Point.new(1, 2), Point.new(5, 6) }"));
  CHECK(live_points == 2);
  lus_close(L);
  CHECK(live_points == 0);
  return check_done("userdata");
}
