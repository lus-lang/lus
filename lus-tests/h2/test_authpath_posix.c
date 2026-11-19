/*
** POSIX retained-path regression coverage.
*/

#if defined(_WIN32)
int main(void) { return 0; }
#else

#if !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 700
#endif

#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "lauthpath.h"
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

#if !defined(PATH_MAX)
#define PATH_MAX 4096
#endif

static int failures;

static void check(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    failures++;
  }
}

static int join(char *result, size_t result_size, const char *parent,
                const char *leaf) {
  int written = snprintf(result, result_size, "%s/%s", parent, leaf);
  return written >= 0 && cast_sizet(written) < result_size;
}

static int write_text(const char *path, const char *text) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  size_t length = strlen(text);
  size_t offset = 0;
  if (fd < 0)
    return 0;
  while (offset < length) {
    ssize_t written = write(fd, text + offset, length - offset);
    if (written < 0 && errno == EINTR)
      continue;
    if (written <= 0) {
      close(fd);
      return 0;
    }
    offset += cast_sizet(written);
  }
  return close(fd) == 0;
}

static int text_is(const char *path, const char *expected) {
  char buffer[128];
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  ssize_t got;
  if (fd < 0)
    return 0;
  got = read(fd, buffer, sizeof(buffer) - 1);
  close(fd);
  if (got < 0)
    return 0;
  buffer[got] = '\0';
  return strcmp(buffer, expected) == 0;
}

static int find_quarantine(const char *root, char *result, size_t result_size) {
  static const char prefix[] = ".lus-delete-quarantine.";
  DIR *directory = opendir(root);
  struct dirent *entry;
  int found = 0;
  if (directory == NULL)
    return -1;
  while ((entry = readdir(directory)) != NULL) {
    if (strncmp(entry->d_name, prefix, sizeof(prefix) - 1) == 0) {
      if (found == 0 && !join(result, result_size, root, entry->d_name)) {
        closedir(directory);
        return -1;
      }
      found++;
    }
  }
  closedir(directory);
  return found;
}

static lua_State *new_state(void) {
  lua_State *L = luaL_newstate();
  if (L != NULL)
    luaL_openlibs(L);
  return L;
}

static int grant(lua_State *L, const char *permission, const char *path) {
  int status;
  lua_getglobal(L, "pledge");
  if (path != NULL)
    lua_pushfstring(L, "%s=%s", permission, path);
  else
    lua_pushstring(L, permission);
  status = lua_pcall(L, 1, 1, 0);
  if (status != LUA_OK) {
    fprintf(stderr, "pledge failed: %s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
    return 0;
  }
  status = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return status;
}

static void test_retained_ancestor(const char *root) {
  char source_parent[PATH_MAX];
  char replacement_parent[PATH_MAX];
  char retained_parent[PATH_MAX];
  char source[PATH_MAX];
  char replacement[PATH_MAX];
  char retained_source[PATH_MAX];
  char destination[PATH_MAX];
  LusAuthMoveSource bound;
  lua_State *L = new_state();
  check(L != NULL, "create retained-ancestor state");
  if (L == NULL)
    return;
  check(grant(L, "fs", NULL), "grant test filesystem authority");
  check(
      join(source_parent, sizeof(source_parent), root, "source-parent") &&
          join(replacement_parent, sizeof(replacement_parent), root,
               "replacement-parent") &&
          join(retained_parent, sizeof(retained_parent), root,
               "retained-parent") &&
          join(source, sizeof(source), source_parent, "item") &&
          join(replacement, sizeof(replacement), replacement_parent, "item") &&
          join(retained_source, sizeof(retained_source), retained_parent,
               "item") &&
          join(destination, sizeof(destination), root, "moved-item"),
      "build retained-ancestor paths");
  check(mkdir(source_parent, 0700) == 0, "create original parent");
  check(mkdir(replacement_parent, 0700) == 0, "create replacement parent");
  check(write_text(source, "original"), "write original source");
  check(write_text(replacement, "replacement"), "write replacement source");
  check(luaAP_bindmovesource(L, source, &bound), "bind original move source");
  check(rename(source_parent, retained_parent) == 0,
        "rename bound source parent away");
  check(rename(replacement_parent, source_parent) == 0,
        "substitute lexical source parent");
  check(luaAP_movebound(L, &bound, destination),
        "move through the retained source parent");
  luaAP_closemovesource(&bound);
  check(text_is(destination, "original"),
        "destination contains the originally bound object");
  check(text_is(source, "replacement"),
        "replacement ancestor remains untouched");
  check(access(retained_source, F_OK) != 0 && errno == ENOENT,
        "original source name was consumed from retained parent");
  unlink(destination);
  unlink(source);
  rmdir(retained_parent);
  rmdir(source_parent);
  lua_close(L);
}

static void test_source_identity_change(const char *root) {
  char source[PATH_MAX];
  char displaced[PATH_MAX];
  char destination[PATH_MAX];
  LusAuthMoveSource bound;
  lua_State *L = new_state();
  int move_errno;
  check(L != NULL, "create identity-change state");
  if (L == NULL)
    return;
  check(grant(L, "fs", NULL), "grant identity test filesystem authority");
  check(join(source, sizeof(source), root, "identity-source") &&
            join(displaced, sizeof(displaced), root, "identity-original") &&
            join(destination, sizeof(destination), root, "identity-moved"),
        "build identity-change paths");
  check(write_text(source, "original"), "write identity source");
  check(luaAP_bindmovesource(L, source, &bound), "bind identity source");
  check(rename(source, displaced) == 0, "displace bound source object");
  check(write_text(source, "replacement"), "substitute source object");
  errno = 0;
  check(!luaAP_movebound(L, &bound, destination),
        "changed source identity fails closed");
  move_errno = errno;
  luaAP_closemovesource(&bound);
  check(move_errno == EAGAIN, "identity change reports EAGAIN");
  check(access(destination, F_OK) != 0 && errno == ENOENT,
        "identity failure creates no destination");
  check(text_is(source, "replacement"), "replacement source remains in place");
  check(text_is(displaced, "original"), "bound original remains displaced");
  unlink(source);
  unlink(displaced);
  lua_close(L);
}

static void test_exact_link_contract(const char *root) {
  char target[PATH_MAX];
  char link[PATH_MAX];
  lua_State *L = new_state();
  check(L != NULL, "create exact-link state");
  if (L == NULL)
    return;
  check(join(target, sizeof(target), root, "exact-target") &&
            join(link, sizeof(link), root, "exact-link"),
        "build exact-link paths");
  check(write_text(target, "target"), "write exact-link target");
  check(symlink("exact-target", link) == 0, "create exact symbolic link");
  check(grant(L, "fs:read", link), "grant exact link read authority");
  check(grant(L, "fs:write", link), "grant exact link write authority");
  lua_pushstring(L, link);
  lua_setglobal(L, "AUTH_LINK");
  check(luaL_dostring(L, "global fs, assert, AUTH_LINK\n"
                         "local kind, linked = fs.type(AUTH_LINK)\n"
                         "assert(kind == 'file' and linked == true)\n"
                         "assert(fs.follow(AUTH_LINK) == 'exact-target')\n"
                         "fs.remove(AUTH_LINK)\n") == LUA_OK,
        "exact existing link grants metadata, follow, and removal");
  if (lua_gettop(L) > 0) {
    fprintf(stderr, "exact-link error: %s\n", lua_tostring(L, -1));
    lua_settop(L, 0);
  }
  check(access(link, F_OK) != 0 && errno == ENOENT,
        "exact link removal deletes the link object");
  check(text_is(target, "target"), "exact link removal preserves its target");
  unlink(target);
  lua_close(L);
}

static void test_symlink_move(const char *root) {
  char target[PATH_MAX];
  char source[PATH_MAX];
  char destination[PATH_MAX];
  char stored[PATH_MAX];
  struct stat info;
  ssize_t length;
  lua_State *L = new_state();
  check(L != NULL, "create symlink-move state");
  if (L == NULL)
    return;
  check(join(target, sizeof(target), root, "move-target") &&
            join(source, sizeof(source), root, "move-link") &&
            join(destination, sizeof(destination), root, "move-destination"),
        "build symlink-move paths");
  check(write_text(target, "target"), "write symlink-move target");
  check(symlink("move-target", source) == 0, "create move source link");
  check(grant(L, "fs:read", source), "grant exact move source read");
  check(grant(L, "fs:write", source), "grant exact move source write");
  check(grant(L, "fs:write", destination), "grant exact move destination");
  lua_pushstring(L, source);
  lua_setglobal(L, "MOVE_SOURCE");
  lua_pushstring(L, destination);
  lua_setglobal(L, "MOVE_DESTINATION");
  check(luaL_dostring(L, "global fs, MOVE_SOURCE, MOVE_DESTINATION\n"
                         "fs.move(MOVE_SOURCE, MOVE_DESTINATION)\n") == LUA_OK,
        "public fs.move moves an exact-granted symbolic link");
  if (lua_gettop(L) > 0) {
    fprintf(stderr, "symlink-move error: %s\n", lua_tostring(L, -1));
    lua_settop(L, 0);
  }
  check(lstat(destination, &info) == 0 && S_ISLNK(info.st_mode),
        "move destination remains a symbolic link");
  length = readlink(destination, stored, sizeof(stored) - 1);
  if (length >= 0)
    stored[length] = '\0';
  check(length >= 0 && strcmp(stored, "move-target") == 0,
        "move preserves the symbolic link payload");
  check(text_is(target, "target"), "symlink move preserves the target");
  check(access(source, F_OK) != 0 && errno == ENOENT,
        "symlink move consumes the source link name");
  unlink(destination);
  unlink(target);
  lua_close(L);
}

typedef enum DeleteHookMode {
  DELETE_HOOK_SWAP,
  DELETE_HOOK_RECREATE,
  DELETE_HOOK_EXIT,
  DELETE_HOOK_QUARANTINE_MODE,
  DELETE_HOOK_QUARANTINE_SWAP,
} DeleteHookMode;

typedef struct DeleteHookContext {
  DeleteHookMode mode;
  lua_State *L;
  const char *root;
  const char *saved;
  const char *replacement;
  char quarantine[PATH_MAX];
  char saved_quarantine[PATH_MAX];
  int fired;
  int quarantine_denied;
} DeleteHookContext;

static void delete_sync_hook(const char *phase, const char *path,
                             void *opaque) {
  DeleteHookContext *context = cast(DeleteHookContext *, opaque);
  if (context->fired)
    return;
  if (context->mode == DELETE_HOOK_SWAP && strcmp(phase, "validated") == 0) {
    context->fired = rename(path, context->saved) == 0 &&
                     rename(context->replacement, path) == 0;
  } else if (context->mode == DELETE_HOOK_RECREATE &&
             strcmp(phase, "quarantined") == 0) {
    char quarantine[PATH_MAX];
    LusAuthFile denied;
    int count = find_quarantine(context->root, quarantine, sizeof(quarantine));
    if (count == 1) {
      int status =
          luaAP_trybinddelete(context->L, quarantine, "fs:write", &denied);
      context->quarantine_denied = status == LUS_AUTH_DENIED;
      luaAP_closeauthfile(&denied);
    }
    context->fired = write_text(path, "replacement");
  } else if (context->mode == DELETE_HOOK_EXIT &&
             strcmp(phase, "quarantined") == 0)
    _exit(0);
  else if (context->mode == DELETE_HOOK_QUARANTINE_MODE &&
           strcmp(phase, "quarantine-created") == 0) {
    context->fired = chmod(path, 0000) == 0;
  } else if (context->mode == DELETE_HOOK_QUARANTINE_SWAP &&
             strcmp(phase, "quarantine-created") == 0) {
    int length = snprintf(context->saved_quarantine,
                          sizeof(context->saved_quarantine), "%s.saved", path);
    context->fired = length > 0 &&
                     cast_sizet(length) < sizeof(context->saved_quarantine) &&
                     strlen(path) < sizeof(context->quarantine) &&
                     (memcpy(context->quarantine, path, strlen(path) + 1), 1) &&
                     rename(path, context->saved_quarantine) == 0 &&
                     write_text(path, "namespace replacement");
  }
}

static void test_delete_validation_swap(const char *root) {
  char path[PATH_MAX];
  char saved[PATH_MAX];
  char replacement[PATH_MAX];
  char quarantine[PATH_MAX];
  LusAuthFile file;
  lua_State *L = new_state();
  DeleteHookContext context;
  int status;
  int result;
  int error;
  check(L != NULL, "create exact-delete state");
  if (L == NULL)
    return;
  check(grant(L, "fs", NULL), "grant exact-delete filesystem authority");
  check(join(path, sizeof(path), root, "delete-bound") &&
            join(saved, sizeof(saved), root, "delete-saved") &&
            join(replacement, sizeof(replacement), root, "delete-replacement"),
        "build exact-delete paths");
  check(write_text(path, "original"), "write exact-delete original");
  check(write_text(replacement, "replacement"),
        "write exact-delete replacement");
  status = luaAP_trybinddelete(L, path, "fs:write", &file);
  check(status == LUS_AUTH_OK, "bind exact-delete original");
  memset(&context, 0, sizeof(context));
  context.mode = DELETE_HOOK_SWAP;
  context.saved = saved;
  context.replacement = replacement;
  luaAP_setdeletehook(delete_sync_hook, &context);
  errno = 0;
  result = luaAP_deleteauthfile(&file);
  error = errno;
  luaAP_setdeletehook(NULL, NULL);
  luaAP_closeauthfile(&file);
  check(!result && error == EAGAIN,
        "post-validation replacement fails exact deletion");
  check(context.fired, "post-validation replacement hook ran");
  check(text_is(path, "replacement"),
        "post-validation replacement is restored");
  check(text_is(saved, "original"), "bound original remains displaced");
  check(find_quarantine(root, quarantine, sizeof(quarantine)) == 0,
        "restored mismatch leaves no quarantine directory");
  unlink(path);
  unlink(saved);
  lua_close(L);
}

static void test_delete_post_quarantine_replacement(const char *root) {
  char path[PATH_MAX];
  char quarantine[PATH_MAX];
  LusAuthFile file;
  lua_State *L = new_state();
  DeleteHookContext context;
  int status;
  check(L != NULL, "create post-quarantine state");
  if (L == NULL)
    return;
  check(grant(L, "fs", NULL), "grant post-quarantine filesystem authority");
  check(join(path, sizeof(path), root, "delete-recreated"),
        "build post-quarantine path");
  check(write_text(path, "original"), "write post-quarantine original");
  status = luaAP_trybinddelete(L, path, "fs:write", &file);
  check(status == LUS_AUTH_OK, "bind post-quarantine original");
  memset(&context, 0, sizeof(context));
  context.mode = DELETE_HOOK_RECREATE;
  context.L = L;
  context.root = root;
  luaAP_setdeletehook(delete_sync_hook, &context);
  check(luaAP_deleteauthfile(&file), "delete quarantined bound original");
  luaAP_setdeletehook(NULL, NULL);
  luaAP_closeauthfile(&file);
  check(context.fired, "post-quarantine replacement hook ran");
  check(context.quarantine_denied,
        "active quarantine is outside pledged filesystem authority");
  check(text_is(path, "replacement"),
        "post-quarantine replacement survives exact deletion");
  check(find_quarantine(root, quarantine, sizeof(quarantine)) == 0,
        "successful deletion removes its quarantine directory");
  unlink(path);
  lua_close(L);
}

static void test_delete_directory_contracts(const char *root) {
  char directory[PATH_MAX];
  char child[PATH_MAX];
  char quarantine[PATH_MAX];
  lua_State *L = new_state();
  check(L != NULL, "create directory-delete state");
  if (L == NULL)
    return;
  check(grant(L, "fs", NULL), "grant directory-delete authority");
  check(join(directory, sizeof(directory), root, "delete-directory") &&
            join(child, sizeof(child), directory, "child"),
        "build directory-delete paths");
  check(mkdir(directory, 0700) == 0 && write_text(child, "child"),
        "create nonempty directory");
  lua_pushstring(L, directory);
  lua_setglobal(L, "DELETE_DIRECTORY");
  check(luaL_dostring(L, "global fs, DELETE_DIRECTORY, assert\n"
                         "local ok = catch fs.remove(DELETE_DIRECTORY)\n"
                         "assert(not ok)\n") == LUA_OK,
        "nonrecursive removal rejects a nonempty directory");
  if (lua_gettop(L) > 0) {
    fprintf(stderr, "directory-delete error: %s\n", lua_tostring(L, -1));
    lua_settop(L, 0);
  }
  check(text_is(child, "child"), "nonempty directory is restored in place");
  check(find_quarantine(root, quarantine, sizeof(quarantine)) == 0,
        "failed nonrecursive removal cleans its quarantine");
  check(luaL_dostring(L, "global fs, DELETE_DIRECTORY\n"
                         "fs.remove(DELETE_DIRECTORY, true)\n") == LUA_OK,
        "recursive removal deletes the retained directory tree");
  if (lua_gettop(L) > 0) {
    fprintf(stderr, "recursive-delete error: %s\n", lua_tostring(L, -1));
    lua_settop(L, 0);
  }
  check(access(directory, F_OK) != 0 && errno == ENOENT,
        "recursive removal consumes the directory root");
  check(find_quarantine(root, quarantine, sizeof(quarantine)) == 0,
        "recursive removal cleans its quarantine");
  lua_close(L);
}

static void test_delete_crash_residue(const char *root) {
  char path[PATH_MAX];
  char quarantine[PATH_MAX];
  char object[PATH_MAX];
  char recovered[PATH_MAX];
  pid_t child;
  int status;
  check(join(path, sizeof(path), root, "delete-crash") &&
            join(recovered, sizeof(recovered), root, "delete-recovered"),
        "build crash-residue paths");
  check(write_text(path, "recoverable"), "write crash-residue object");
  child = fork();
  if (child == 0) {
    LusAuthFile file;
    lua_State *L = new_state();
    DeleteHookContext context;
    if (L == NULL || !grant(L, "fs", NULL) ||
        luaAP_trybinddelete(L, path, "fs:write", &file) != LUS_AUTH_OK)
      _exit(2);
    memset(&context, 0, sizeof(context));
    context.mode = DELETE_HOOK_EXIT;
    luaAP_setdeletehook(delete_sync_hook, &context);
    luaAP_deleteauthfile(&file);
    _exit(3);
  }
  check(child > 0, "fork crash-residue process");
  if (child <= 0)
    return;
  check(waitpid(child, &status, 0) == child && WIFEXITED(status) &&
            WEXITSTATUS(status) == 0,
        "crash-residue process stopped after quarantine rename");
  check(access(path, F_OK) != 0 && errno == ENOENT,
        "crash residue is absent from its former name");
  check(find_quarantine(root, quarantine, sizeof(quarantine)) == 1 &&
            join(object, sizeof(object), quarantine, "object") &&
            text_is(object, "recoverable"),
        "crash residue preserves the quarantined object");
  check(rename(object, recovered) == 0 && rmdir(quarantine) == 0,
        "host can recover and clean a crash residue");
  check(text_is(recovered, "recoverable"),
        "recovered crash residue retains its contents");
  unlink(recovered);
}

static void test_quarantine_open_failures(const char *root) {
  char path[PATH_MAX];
  char quarantine[PATH_MAX];
  LusAuthFile file;
  lua_State *L = new_state();
  DeleteHookContext context;
  struct rlimit original_limit;
  struct rlimit exhausted_limit;
  int injected = 0;
  int status;
  check(L != NULL, "create quarantine-failure state");
  if (L == NULL)
    return;
  check(grant(L, "fs", NULL), "grant quarantine-failure authority");
  check(join(path, sizeof(path), root, "quarantine-open-failure"),
        "build quarantine-failure path");
  check(write_text(path, "original"), "write quarantine-failure original");
  status = luaAP_trybinddelete(L, path, "fs:write", &file);
  check(status == LUS_AUTH_OK, "bind quarantine-failure original");
  memset(&context, 0, sizeof(context));
  context.mode = DELETE_HOOK_QUARANTINE_MODE;
  luaAP_setdeletehook(delete_sync_hook, &context);
  check(!luaAP_deleteauthfile(&file),
        "unopenable quarantine fails before moving the target");
  luaAP_setdeletehook(NULL, NULL);
  luaAP_closeauthfile(&file);
  check(context.fired, "quarantine mode fault hook ran");
  check(text_is(path, "original"),
        "quarantine validation failure preserves the target");
  check(find_quarantine(root, quarantine, sizeof(quarantine)) == 0,
        "same-object quarantine validation failure cleans the directory");

  status = luaAP_trybinddelete(L, path, "fs:write", &file);
  check(status == LUS_AUTH_OK, "rebind namespace-swap original");
  memset(&context, 0, sizeof(context));
  context.mode = DELETE_HOOK_QUARANTINE_SWAP;
  luaAP_setdeletehook(delete_sync_hook, &context);
  check(!luaAP_deleteauthfile(&file),
        "quarantine namespace replacement fails closed");
  luaAP_setdeletehook(NULL, NULL);
  luaAP_closeauthfile(&file);
  check(context.fired, "quarantine namespace swap hook ran");
  check(text_is(path, "original"),
        "namespace replacement leaves the target in place");
  check(text_is(context.quarantine, "namespace replacement"),
        "unsafe quarantine replacement is preserved");
  check(rmdir(context.saved_quarantine) == 0,
        "host removes the displaced empty quarantine");
  check(unlink(context.quarantine) == 0,
        "host removes the preserved namespace replacement");

  status = luaAP_trybinddelete(L, path, "fs:write", &file);
  check(status == LUS_AUTH_OK, "rebind pre-identity failure original");
  if (getrlimit(RLIMIT_NOFILE, &original_limit) == 0) {
    exhausted_limit = original_limit;
    exhausted_limit.rlim_cur = 0;
    if (setrlimit(RLIMIT_NOFILE, &exhausted_limit) == 0) {
      int result;
      int error;
      injected = 1;
      errno = 0;
      result = luaAP_deleteauthfile(&file);
      error = errno;
      check(setrlimit(RLIMIT_NOFILE, &original_limit) == 0,
            "restore descriptor limit after quarantine open failure");
      check(!result && error == EMFILE,
            "quarantine open failure preserves an unbound namespace");
    }
  }
  check(injected, "inject quarantine descriptor-open failure");
  luaAP_closeauthfile(&file);
  check(text_is(path, "original"),
        "pre-identity quarantine failure preserves the target");
  if (injected) {
    check(find_quarantine(root, quarantine, sizeof(quarantine)) == 1,
          "pre-identity failure preserves one reserved directory");
    check(rmdir(quarantine) == 0,
          "host removes the pre-identity quarantine residue");
  }
  unlink(path);
  lua_close(L);
}

static void test_quarantine_prefix_contract(const char *root) {
  char shorter[PATH_MAX];
  char exact[PATH_MAX];
  char reserved[PATH_MAX];
  LusAuthFile file;
  lua_State *L = new_state();
  int status;
  check(L != NULL, "create quarantine-prefix state");
  if (L == NULL)
    return;
  check(grant(L, "fs", NULL), "grant quarantine-prefix authority");
  check(
      join(shorter, sizeof(shorter), root, ".lus-delete-quarantine") &&
          join(exact, sizeof(exact), root, LUS_AUTH_QUARANTINE_PREFIX) &&
          join(reserved, sizeof(reserved), root, ".lus-delete-quarantine.user"),
      "build quarantine-prefix paths");
  check(write_text(shorter, "shorter") && write_text(exact, "exact") &&
            write_text(reserved, "reserved"),
        "write quarantine-prefix files");
  status = luaAP_trybinddelete(L, shorter, "fs:write", &file);
  check(status == LUS_AUTH_OK,
        "shorter quarantine-like component remains available");
  luaAP_closeauthfile(&file);
  status = luaAP_trybinddelete(L, exact, "fs:write", &file);
  check(status == LUS_AUTH_DENIED,
        "exact quarantine-prefix component is outside pledge authority");
  luaAP_closeauthfile(&file);
  status = luaAP_trybinddelete(L, reserved, "fs:write", &file);
  check(status == LUS_AUTH_DENIED,
        "reserved quarantine component is outside pledge authority");
  luaAP_closeauthfile(&file);
  unlink(shorter);
  unlink(exact);
  unlink(reserved);
  lua_close(L);
}

int main(void) {
  char root[] = "/tmp/lus-authpath-posix-XXXXXX";
  if (mkdtemp(root) == NULL) {
    perror("mkdtemp");
    return 1;
  }
  test_retained_ancestor(root);
  test_source_identity_change(root);
  test_exact_link_contract(root);
  test_symlink_move(root);
  test_delete_validation_swap(root);
  test_delete_post_quarantine_replacement(root);
  test_delete_directory_contracts(root);
  test_quarantine_open_failures(root);
  test_quarantine_prefix_contract(root);
  test_delete_crash_residue(root);
  check(rmdir(root) == 0, "remove test root");
  if (failures != 0)
    fprintf(stderr, "%d authpath POSIX regression(s) failed\n", failures);
  return failures == 0 ? 0 : 1;
}
#endif
