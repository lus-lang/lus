/*
** Permissions: a third-party capability defined from C and pledged from a
** script, a custom matcher, the built-in capabilities, the host policy
** (grant, reject, seal), and the request hook.
*/

#include "check.h"

static const char *const myext_subs[] = {"read", "write", NULL};

/* myext.read(key) checks "myext:read" for key and echoes it. */
static int myext_read(lus_State *L) {
  const char *key = lus_tostring(L, 1, NULL);
  if (key == NULL)
    return lus_errorf(L, "bad argument #1 to 'read' (string expected)");
  if (lus_require(L, "myext:read", key) != LUS_OK)
    return lus_error(L);
  CHECK_OK(L, lus_pushfstring(L, "read %s", key));
  return 1;
}

/* myext.canwrite(key) answers without raising. */
static int myext_canwrite(lus_State *L) {
  lus_pushboolean(L, lus_allowed(L, "myext:write", lus_tostring(L, 1, NULL)));
  return 1;
}

/* A custom matcher: the granted value is a byte budget, and a request is
   covered when it asks for no more. */
static int quota_calls = 0;
static int quota_match(void *ud, const char *granted, const char *requested) {
  CHECK(ud == &quota_calls);
  quota_calls++;
  return atol(requested) <= atol(granted);
}

/* quota.use(n) checks "quota" for n. */
static int quota_use(lus_State *L) {
  const char *n = lus_tostring(L, 1, NULL);
  if (lus_require(L, "quota", n) != LUS_OK)
    return lus_error(L);
  lus_pushboolean(L, 1);
  return 1;
}

static void open_myext(lus_State *L) {
  lus_Capability cap = {0};
  cap.name = "myext";
  cap.subcapabilities = myext_subs;
  cap.kind = LUS_CAP_PATTERN;
  CHECK_OK(L, lus_defcapability(L, &cap));

  lus_Capability quota = {0};
  quota.name = "quota";
  quota.kind = LUS_CAP_CUSTOM;
  quota.match = quota_match;
  quota.ud = &quota_calls;
  CHECK_OK(L, lus_defcapability(L, &quota));

  CHECK_OK(L, lus_newtable(L, 0, 2));
  CHECK_OK(L, lus_pushcfunction(L, myext_read));
  CHECK_OK(L, lus_setfield(L, -2, "read"));
  CHECK_OK(L, lus_pushcfunction(L, myext_canwrite));
  CHECK_OK(L, lus_setfield(L, -2, "canwrite"));
  CHECK_OK(L, lus_setglobal(L, "myext"));
  CHECK_OK(L, lus_newtable(L, 0, 1));
  CHECK_OK(L, lus_pushcfunction(L, quota_use));
  CHECK_OK(L, lus_setfield(L, -2, "use"));
  CHECK_OK(L, lus_setglobal(L, "quota"));
}

static lus_State *fresh(void) {
  lus_State *L = lus_newstate();
  CHECK_OK(L, lus_openlibs(L));
  open_myext(L);
  return L;
}

static void script_pledges(void) {
  lus_State *L = fresh();

  /* Without a pledge the capability is denied with the standard error. */
  CHECK(lus_dostring(L, "return myext.read('docs/a')") == LUS_ERRRUN);
  CHECK_STR(L, -1, "(dostring):1: permission \"myext:read\" denied for 'docs/a'");
  lus_settop(L, 0);

  /* A script pledges the third-party capability with a value. */
  CHECK_OK(L, lus_dostring(L,
      "assert(pledge('myext:read=docs/**'))\n"
      "local a = myext.read('docs/a')\n"
      "local ok, e = catch myext.read('secret/x')\n"
      "return a, ok, e, myext.canwrite('docs/a')"));
  CHECK_STR(L, 1, "read docs/a");
  CHECK(lus_toboolean(L, 2) == 0);
  CHECK_HAS(L, 3, "permission \"myext:read\" denied for 'secret/x'");
  CHECK(lus_toboolean(L, 4) == 0);
  lus_settop(L, 0);

  /* Subcapabilities are validated against the declaration. */
  CHECK(lus_dostring(L, "pledge('myext:delete')") == LUS_ERRRUN);
  CHECK_HAS(L, -1, "invalid myext subpermission 'delete'");
  lus_settop(L, 0);
  CHECK(lus_dostring(L, "pledge('nosuchext')") == LUS_ERRRUN);
  CHECK_HAS(L, -1, "unknown permission: 'nosuchext'");
  lus_settop(L, 0);

  /* The custom matcher decides for its capability. */
  CHECK_OK(L, lus_dostring(L,
      "pledge('quota=100')\n"
      "local small = quota.use('40')\n"
      "local ok = catch quota.use('400')\n"
      "return small, ok"));
  CHECK(lus_toboolean(L, 1) == 1);
  CHECK(lus_toboolean(L, 2) == 0);
  CHECK(quota_calls >= 2);
  lus_settop(L, 0);

  /* Definitions are checked. */
  lus_Capability dup = {0};
  dup.name = "myext";
  CHECK(lus_defcapability(L, &dup) == LUS_ERRRUN);
  CHECK_HAS(L, -1, "already defined");
  lus_pop(L, 1);
  lus_Capability bad = {0};
  bad.name = "has:colon";
  CHECK(lus_defcapability(L, &bad) == LUS_ERRRUN);
  lus_pop(L, 1);
  lus_Capability nomatch = {0};
  nomatch.name = "lonely";
  nomatch.kind = LUS_CAP_CUSTOM;
  CHECK(lus_defcapability(L, &nomatch) == LUS_ERRRUN);
  lus_pop(L, 1);

  lus_close(L);
}

static void host_policy(void) {
  lus_State *L = fresh();

  /* Built-in capabilities are checked the same way from C. */
  CHECK(lus_allowed(L, "network:http", "https://example.com/x") == 0);
  CHECK(lus_require(L, "network:http", "https://example.com/x") == LUS_ERRRUN);
  CHECK_HAS(L, -1, "permission \"network:http\" denied");
  lus_pop(L, 1);
  CHECK_OK(L, lus_grant(L, "network:http=example.com"));
  CHECK(lus_allowed(L, "network:http", "https://example.com/x") == 1);
  CHECK(lus_allowed(L, "network:http", "https://example.org/") == 0);
  CHECK_OK(L, lus_require(L, "network:http", "https://example.com/x"));
  CHECK(lus_gettop(L) == 0);

  /* Host grants bound what scripts may pledge. */
  CHECK_OK(L, lus_grant(L, "myext:read=docs/**"));
  CHECK_OK(L, lus_dostring(L,
      "return pledge('myext:read=docs/a'), pledge('myext:read=etc/**')"));
  CHECK(lus_toboolean(L, 1) == 1);
  CHECK(lus_toboolean(L, 2) == 0);
  lus_settop(L, 0);

  /* Rejections are permanent. */
  CHECK_OK(L, lus_reject(L, "exec"));
  CHECK(lus_dostring(L, "pledge('exec')") == LUS_ERRRUN);
  CHECK_HAS(L, -1, "permission \"exec\" was rejected");
  lus_settop(L, 0);
  CHECK(lus_grant(L, "exec") == LUS_ERRRUN);
  lus_settop(L, 0);

  /* Malformed grants fail. */
  CHECK(lus_grant(L, "nosuchcap") == LUS_ERRRUN);
  CHECK_HAS(L, -1, "unknown permission");
  lus_settop(L, 0);

  /* A sealed set never changes again. */
  CHECK_OK(L, lus_seal(L));
  CHECK(lus_grant(L, "myext:write") == LUS_ERRRUN);
  CHECK_HAS(L, -1, "sealed");
  lus_settop(L, 0);
  CHECK_OK(L, lus_dostring(L, "return pledge('myext:read=docs/b')"));
  CHECK(lus_toboolean(L, -1) == 0);
  lus_settop(L, 0);
  CHECK(lus_allowed(L, "myext:write", "x") == 0);
  CHECK(lus_allowed(L, "myext:read", "docs/z") == 1);

  lus_close(L);
}

/* The request hook approves writes under tmp/ and nothing else. */
static int requests = 0;
static int approve(void *ud, lus_State *L, const char *capability,
                   const char *value) {
  (void)L;
  CHECK(ud == &requests);
  requests++;
  if (strcmp(capability, "myext:write") != 0 || value == NULL)
    return 0;
  return strncmp(value, "tmp/", 4) == 0;
}

static void request_hook(void) {
  lus_State *L = fresh();
  lus_onrequest(L, approve, &requests);
  CHECK_OK(L, lus_dostring(L,
      "return pledge('myext:write=tmp/**'), pledge('myext:write=/etc/**'),"
      " pledge('myext:read'), myext.canwrite('tmp/a'), myext.canwrite('/etc/x')"));
  CHECK(lus_toboolean(L, 1) == 1);
  CHECK(lus_toboolean(L, 2) == 0);
  CHECK(lus_toboolean(L, 3) == 0);
  CHECK(lus_toboolean(L, 4) == 1);
  CHECK(lus_toboolean(L, 5) == 0);
  CHECK(requests == 3);
  lus_settop(L, 0);

  /* What the host granted needs no approval. */
  CHECK_OK(L, lus_grant(L, "myext:read=docs/**"));
  CHECK_OK(L, lus_dostring(L, "return pledge('myext:read=docs/x')"));
  CHECK(lus_toboolean(L, -1) == 1);
  CHECK(requests == 3);
  lus_settop(L, 0);

  /* What the script pledged earlier stays out of the host ceiling, so the
     hook still decides it. */
  CHECK_OK(L, lus_dostring(L, "return pledge('myext:write=tmp/c')"));
  CHECK(lus_toboolean(L, -1) == 1);
  CHECK(requests == 4);
  lus_settop(L, 0);

  /* Without the hook, the ceiling alone decides again. */
  lus_onrequest(L, NULL, NULL);
  CHECK_OK(L, lus_dostring(L, "return pledge('myext:write=var/b')"));
  CHECK(lus_toboolean(L, -1) == 0);
  CHECK(requests == 4);
  lus_close(L);
}

int main(void) {
  script_pledges();
  host_policy();
  request_hook();
  return check_done("pledge");
}
