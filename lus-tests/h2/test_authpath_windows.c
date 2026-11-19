/*
** Windows retained-path regression coverage.
*/

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#if defined(_WIN32)
#include <windows.h>
#include <winioctl.h>

#include "lauthpath.h"
#include "lauxlib.h"
#include "lpledge.h"
#include "lua.h"
#include "lualib.h"

static int failures = 0;

static void check(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    failures++;
  }
}

static char *utf8(const WCHAR *wide) {
  int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1,
                                   NULL, 0, NULL, NULL);
  char *text;
  if (needed <= 0)
    return NULL;
  text = (char *)malloc((size_t)needed);
  if (text == NULL)
    return NULL;
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, text, needed,
                          NULL, NULL) == 0) {
    free(text);
    return NULL;
  }
  return text;
}

static WCHAR *joinw(const WCHAR *parent, const WCHAR *leaf) {
  size_t parent_len;
  size_t leaf_len;
  WCHAR *path = NULL;
  if (parent == NULL || leaf == NULL)
    return NULL;
  parent_len = wcslen(parent);
  leaf_len = wcslen(leaf);
  path = (WCHAR *)malloc((parent_len + leaf_len + 2) * sizeof(WCHAR));
  if (path == NULL)
    return NULL;
  memcpy(path, parent, parent_len * sizeof(WCHAR));
  path[parent_len++] = L'\\';
  memcpy(path + parent_len, leaf, (leaf_len + 1) * sizeof(WCHAR));
  return path;
}

static WCHAR *drive_to_unc(const WCHAR *path) {
  static const WCHAR prefix[] = L"\\\\localhost\\";
  size_t path_len;
  size_t prefix_len = wcslen(prefix);
  WCHAR *result;
  if (path == NULL || path[0] == L'\0' || path[1] != L':')
    return NULL;
  path_len = wcslen(path);
  result = (WCHAR *)malloc((prefix_len + path_len + 2) * sizeof(WCHAR));
  if (result == NULL)
    return NULL;
  memcpy(result, prefix, prefix_len * sizeof(WCHAR));
  result[prefix_len] = path[0];
  result[prefix_len + 1] = L'$';
  memcpy(result + prefix_len + 2, path + 2, (path_len - 1) * sizeof(WCHAR));
  return result;
}

static WCHAR *long_directory(const WCHAR *parent) {
  static const WCHAR segment[] =
      L"retained-path-segment-0123456789-abcdefghijklmnop";
  WCHAR *path = _wcsdup(parent);
  int i;
  if (path == NULL)
    return NULL;
  for (i = 0; i < 6; i++) {
    WCHAR *next = joinw(path, segment);
    free(path);
    if (next == NULL)
      return NULL;
    path = next;
  }
  return path;
}

static int make_junction(const WCHAR *path, const WCHAR *target) {
  struct JunctionBuffer {
    ULONG ReparseTag;
    USHORT ReparseDataLength;
    USHORT Reserved;
    USHORT SubstituteNameOffset;
    USHORT SubstituteNameLength;
    USHORT PrintNameOffset;
    USHORT PrintNameLength;
    WCHAR PathBuffer[1];
  } *buffer;
  WCHAR *substitute;
  size_t target_len = wcslen(target);
  size_t substitute_len = target_len + 4;
  size_t size = offsetof(struct JunctionBuffer, PathBuffer) +
                (substitute_len + target_len + 2) * sizeof(WCHAR);
  HANDLE handle;
  DWORD returned;
  int ok;
  substitute = (WCHAR *)malloc((substitute_len + 1) * sizeof(WCHAR));
  buffer = (struct JunctionBuffer *)calloc(1, size);
  if (substitute == NULL || buffer == NULL) {
    free(substitute);
    free(buffer);
    return 0;
  }
  wcscpy(substitute, L"\\??\\");
  wcscpy(substitute + 4, target);
  if (!CreateDirectoryW(path, NULL)) {
    free(substitute);
    free(buffer);
    return 0;
  }
  handle = CreateFileW(
      path, GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (handle == INVALID_HANDLE_VALUE) {
    RemoveDirectoryW(path);
    free(substitute);
    free(buffer);
    return 0;
  }
  buffer->ReparseTag = IO_REPARSE_TAG_MOUNT_POINT;
  buffer->SubstituteNameLength = (USHORT)(substitute_len * sizeof(WCHAR));
  buffer->PrintNameOffset = (USHORT)((substitute_len + 1) * sizeof(WCHAR));
  buffer->PrintNameLength = (USHORT)(target_len * sizeof(WCHAR));
  memcpy(buffer->PathBuffer, substitute, (substitute_len + 1) * sizeof(WCHAR));
  memcpy((char *)buffer->PathBuffer + buffer->PrintNameOffset, target,
         (target_len + 1) * sizeof(WCHAR));
  buffer->ReparseDataLength = (USHORT)(size - 8);
  ok = DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, buffer, (DWORD)size,
                       NULL, 0, &returned, NULL);
  CloseHandle(handle);
  if (!ok)
    RemoveDirectoryW(path);
  free(substitute);
  free(buffer);
  return ok;
}

static int run(lua_State *L, const char *source, const char *argument) {
  int status;
  lua_settop(L, 0);
  status = luaL_loadstring(L, source);
  if (status != LUA_OK)
    return status;
  lua_pushstring(L, argument);
  return lua_pcall(L, 1, 0, 0);
}

static int run2(lua_State *L, const char *source, const char *first,
                const char *second) {
  int status;
  lua_settop(L, 0);
  status = luaL_loadstring(L, source);
  if (status != LUA_OK)
    return status;
  lua_pushstring(L, first);
  lua_pushstring(L, second);
  return lua_pcall(L, 2, 0, 0);
}

static void write_file(const WCHAR *path, const char *contents) {
  FILE *file = _wfopen(path, L"wb");
  if (file == NULL)
    return;
  fwrite(contents, 1, strlen(contents), file);
  fclose(file);
}

int main(void) {
  WCHAR temp[MAX_PATH];
  WCHAR seed[MAX_PATH];
  WCHAR *allowed;
  WCHAR *outside;
  WCHAR *junction;
  WCHAR *outside_secret;
  WCHAR *escaped_secret;
  WCHAR *unicode_file;
  WCHAR *unicode_link;
  WCHAR *move_source;
  WCHAR *move_target;
  WCHAR *escaped_missing;
  WCHAR *outside_missing;
  WCHAR *lock_dir;
  WCHAR *lock_moved;
  WCHAR *lock_file;
  WCHAR *long_dir;
  WCHAR *long_file;
  WCHAR *unc_allowed;
  WCHAR *unc_file;
  char *allowed_utf8;
  char *pattern;
  char *escaped_utf8;
  char *junction_utf8;
  char *junction_extended;
  char *unicode_utf8;
  char *unicode_link_utf8;
  char *move_source_utf8;
  char *move_target_utf8;
  char *escaped_missing_utf8;
  char *lock_file_utf8;
  char *long_dir_utf8;
  char *long_file_utf8;
  char *unc_file_utf8;
  lua_State *L;
  DWORD temp_len = GetTempPathW(MAX_PATH, temp);
  UINT seed_result;
  check(temp_len > 0 && temp_len < MAX_PATH, "temporary path is available");
  if (temp_len == 0 || temp_len >= MAX_PATH)
    return 1;
  seed_result = GetTempFileNameW(temp, L"lus", 0, seed);
  check(seed_result != 0, "temporary name is available");
  if (seed_result == 0)
    return 1;
  DeleteFileW(seed);
  allowed = joinw(seed, L"allowed");
  outside = joinw(seed, L"outside");
  junction = joinw(allowed, L"junction");
  outside_secret = joinw(outside, L"secret.lus");
  escaped_secret = joinw(junction, L"secret.lus");
  unicode_file = joinw(allowed, L"caf\x00e9-\x6e2c\x8a66.lus");
  unicode_link = joinw(allowed, L"caf\x00e9-link.lus");
  move_source = joinw(allowed, L"move-source.lus");
  move_target = joinw(allowed, L"move-target.lus");
  escaped_missing = joinw(junction, L"new-secret.lus");
  outside_missing = joinw(outside, L"new-secret.lus");
  lock_dir = joinw(allowed, L"locked-ancestor");
  lock_moved = joinw(allowed, L"moved-ancestor");
  lock_file = joinw(lock_dir, L"module.lus");
  long_dir = long_directory(allowed);
  long_file = joinw(long_dir, L"long-path.lus");
  unc_allowed = drive_to_unc(allowed);
  unc_file = joinw(unc_allowed, L"unc-path.lus");
  check(allowed != NULL && outside != NULL && junction != NULL &&
            outside_secret != NULL && escaped_secret != NULL &&
            unicode_file != NULL && unicode_link != NULL &&
            move_source != NULL && move_target != NULL &&
            escaped_missing != NULL && outside_missing != NULL &&
            lock_dir != NULL && lock_moved != NULL && lock_file != NULL &&
            long_dir != NULL && long_file != NULL && unc_allowed != NULL &&
            unc_file != NULL,
        "fixture paths allocate");
  if (failures != 0)
    return 1;
  check(wcslen(long_file) > MAX_PATH,
        "long path fixture exceeds the legacy path limit");
  CreateDirectoryW(seed, NULL);
  CreateDirectoryW(allowed, NULL);
  CreateDirectoryW(outside, NULL);
  CreateDirectoryW(lock_dir, NULL);
  write_file(outside_secret, "return 7\n");
  write_file(lock_file, "return 8\n");
  check(make_junction(junction, outside), "junction fixture is created");

  allowed_utf8 = utf8(allowed);
  escaped_utf8 = utf8(escaped_secret);
  junction_utf8 = utf8(junction);
  unicode_utf8 = utf8(unicode_file);
  unicode_link_utf8 = utf8(unicode_link);
  move_source_utf8 = utf8(move_source);
  move_target_utf8 = utf8(move_target);
  escaped_missing_utf8 = utf8(escaped_missing);
  lock_file_utf8 = utf8(lock_file);
  long_dir_utf8 = utf8(long_dir);
  long_file_utf8 = utf8(long_file);
  unc_file_utf8 = utf8(unc_file);
  check(allowed_utf8 != NULL && escaped_utf8 != NULL && junction_utf8 != NULL &&
            unicode_utf8 != NULL && unicode_link_utf8 != NULL &&
            move_source_utf8 != NULL && move_target_utf8 != NULL &&
            escaped_missing_utf8 != NULL && lock_file_utf8 != NULL &&
            long_dir_utf8 != NULL && long_file_utf8 != NULL &&
            unc_file_utf8 != NULL,
        "fixture paths convert to UTF-8");
  if (failures != 0)
    return 1;
  junction_extended = (char *)malloc(strlen(junction_utf8) + 5);
  check(junction_extended != NULL, "extended junction path allocates");
  if (junction_extended == NULL)
    return 1;
  sprintf(junction_extended, "\\\\?\\%s", junction_utf8);
  {
    char resolved_link[LUS_AUTH_PATH_MAX];
    int resolved_link_ok = luaAP_resolvelink(junction_extended, resolved_link,
                                             sizeof(resolved_link));
    check(resolved_link_ok,
          "exact extended reparse path resolves to its link object");
    check(resolved_link_ok && _stricmp(resolved_link, junction_extended) == 0,
          "extended reparse path retains the exact link identity");
  }
  pattern = (char *)malloc(strlen(allowed_utf8) + 3);
  check(pattern != NULL, "permission pattern allocates");
  if (pattern == NULL)
    return 1;
  sprintf(pattern, "%s\\*", allowed_utf8);

  L = luaL_newstate();
  check(L != NULL, "state is created");
  if (L == NULL)
    return 1;
  luaL_openlibs(L);
  {
    char resolved[LUS_AUTH_PATH_MAX];
    char repeated[LUS_AUTH_PATH_MAX];
    const char *relative_pattern = "./lus-authpath-roundtrip-*";
    const char *relative_leaf = "./lus-authpath-roundtrip-file";
    int resolved_ok =
        luaAP_resolvepattern(relative_pattern, resolved, sizeof(resolved));
    int repeated_ok = resolved_ok && luaAP_resolvepattern(resolved, repeated,
                                                          sizeof(repeated));
    check(resolved_ok,
          "relative wildcard pattern resolves to a canonical path");
    check(repeated_ok, "canonical extended wildcard pattern resolves again");
    check(resolved_ok && repeated_ok && strcmp(resolved, repeated) == 0,
          "canonical extended wildcard resolution is idempotent");
    check(lus_pledge(L, "fs:read", relative_pattern),
          "relative wildcard scope is granted");
    check(lus_haspledge(L, "fs:read", relative_leaf),
          "relative wildcard scope authorizes its canonical leaf");
  }
  check(lus_pledge(L, "fs:read", pattern), "read scope is granted");
  check(lus_pledge(L, "fs:write", pattern), "write scope is granted");
  check(lus_pledge(L, "load", NULL), "load scope is granted");

  check(run(L,
            "local p = ...\n"
            "local f = assert(io.open(p, 'wb'))\n"
            "f:write('return 7\\n')\n"
            "f:close()\n"
            "assert(loadfile(p))\n",
            unicode_utf8) == LUA_OK,
        "Unicode file I/O and module loading succeed inside the scope");
  check(run2(L,
             "local link, target = ...\n"
             "fs.createlink(link, target)\n"
             "assert(fs.follow(link) == target)\n"
             "fs.remove(link)\n",
             unicode_link_utf8, unicode_utf8) == LUA_OK,
        "Unicode symbolic link targets round-trip as UTF-8");
  check(run2(L,
             "local d, p = ...\n"
             "fs.createdirectory(d, true)\n"
             "local f = assert(io.open(p, 'wb'))\n"
             "f:write('long')\n"
             "f:close()\n",
             long_dir_utf8, long_file_utf8) == LUA_OK,
        "long drive path succeeds inside the retained scope");
  check(run(L,
            "local p = ...\n"
            "local f = assert(io.open(p, 'wb'))\n"
            "f:write('return 9\\n')\n"
            "f:close()\n"
            "assert(loadfile(p))\n",
            unc_file_utf8) == LUA_OK,
        "UNC file and module paths resolve to retained authorized objects");
  check(run(L, "local p = ...\nlocal f = io.open(p, 'rb')\n", escaped_utf8) !=
            LUA_OK,
        "junction read outside the retained scope is denied");
  check(run(L, "local p = ...\nloadfile(p)\n", escaped_utf8) != LUA_OK,
        "junction load outside the retained scope is denied");
  check(run(L, "local p = ...\nworker.create(p)\n", escaped_utf8) != LUA_OK,
        "junction worker load outside the retained scope is denied");
  check(run(L,
            "local p = ...\n"
            "local f = assert(io.open(p, 'wb'))\n"
            "f:write('escape')\n"
            "f:close()\n",
            escaped_missing_utf8) != LUA_OK,
        "missing leaf through a junction is denied");
  check(GetFileAttributesW(outside_missing) == INVALID_FILE_ATTRIBUTES,
        "denied missing leaf is not created outside the scope");
  {
    HANDLE target = luaAP_winopen(L, lock_file_utf8, GENERIC_READ,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 1, 0);
    LusAuthChain chain = {NULL, 0};
    DWORD move_error;
    int chain_locked;
    check(target != INVALID_HANDLE_VALUE,
          "retained target opens for ancestor-lock coverage");
    chain_locked =
        target != INVALID_HANDLE_VALUE && luaAP_winlockchain(target, &chain);
    check(chain_locked,
          "authorized target retains its canonical ancestor chain");
    if (chain_locked) {
      SetLastError(ERROR_SUCCESS);
      check(!MoveFileExW(lock_dir, lock_moved, MOVEFILE_WRITE_THROUGH),
            "retained ancestor rejects substitution by rename");
      move_error = GetLastError();
      check(move_error == ERROR_SHARING_VIOLATION ||
                move_error == ERROR_ACCESS_DENIED ||
                move_error == ERROR_LOCK_VIOLATION,
            "ancestor substitution fails with a Windows sharing error");
    }
    if (target != INVALID_HANDLE_VALUE) {
      luaAP_winclosechain(&chain);
      CloseHandle(target);
    }
    check(MoveFileExW(lock_dir, lock_moved, MOVEFILE_WRITE_THROUGH),
          "ancestor rename succeeds after retained handles close");
    check(MoveFileExW(lock_moved, lock_dir, MOVEFILE_WRITE_THROUGH),
          "fixture ancestor returns to its original name");
  }
  check(run2(L,
             "local from, to = ...\n"
             "local f = assert(io.open(from, 'wb'))\n"
             "f:write('move')\n"
             "f:close()\n"
             "fs.move(from, to)\n"
             "fs.remove(to)\n",
             move_source_utf8, move_target_utf8) == LUA_OK,
        "handle-bound move and removal succeed inside the retained scope");
  check(run(L, "local p = ...\nfs.remove(p)\n", junction_utf8) == LUA_OK,
        "removing a junction removes the retained link object");
  check(GetFileAttributesW(outside_secret) != INVALID_FILE_ATTRIBUTES,
        "removing a junction preserves its outside target");
  check(run(L, "local p = ...\nfs.remove(p, true)\n", long_dir_utf8) == LUA_OK,
        "recursive removal uses the retained long-path directory object");

  lua_close(L);
  DeleteFileW(unicode_link);
  DeleteFileW(unicode_file);
  DeleteFileW(unc_file);
  DeleteFileW(lock_file);
  DeleteFileW(outside_secret);
  RemoveDirectoryW(lock_dir);
  RemoveDirectoryW(allowed);
  RemoveDirectoryW(outside);
  RemoveDirectoryW(seed);
  free(pattern);
  free(unc_file_utf8);
  free(long_file_utf8);
  free(long_dir_utf8);
  free(move_target_utf8);
  free(move_source_utf8);
  free(unicode_link_utf8);
  free(lock_file_utf8);
  free(escaped_missing_utf8);
  free(unicode_utf8);
  free(junction_extended);
  free(junction_utf8);
  free(escaped_utf8);
  free(allowed_utf8);
  free(unc_file);
  free(unc_allowed);
  free(long_file);
  free(long_dir);
  free(move_target);
  free(move_source);
  free(unicode_link);
  free(lock_file);
  free(lock_moved);
  free(lock_dir);
  free(outside_missing);
  free(escaped_missing);
  free(unicode_file);
  free(escaped_secret);
  free(outside_secret);
  free(junction);
  free(outside);
  free(allowed);
  if (failures != 0)
    return 1;
  puts("Windows authorized path tests passed");
  return 0;
}

#else

int main(void) { return 0; }

#endif
