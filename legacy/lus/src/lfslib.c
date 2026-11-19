/*
** lfslib.c
** Filesystem library for Lus
** Implements fs.* global functions
*/

#define lfslib_c
#define LUA_LIB

#if !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 700
#endif

#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include "lprefix.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lauthpath.h"
#include "lglob.h"
#include "lpledge.h"
#include "lua.h"
#include "lualib.h"

/* Platform specific headers */
#if defined(LUS_PLATFORM_WINDOWS)
#include <direct.h>
#include <stdint.h>
#include <wchar.h>
#include <windows.h>
#include <winioctl.h> /* FSCTL_GET_REPARSE_POINT for fs.follow */
#define mkdir(p) _mkdir(p)
#else
#include <dirent.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <sys/stat.h>
#include <unistd.h>
#if !defined(O_CLOEXEC)
#define O_CLOEXEC 0
#endif
#if !defined(O_NONBLOCK)
#define O_NONBLOCK 0
#endif
#if !defined(O_NOFOLLOW)
#define O_NOFOLLOW 0
#endif
#endif

/*
** {======================================================
** fs.path functions
** =======================================================
*/

#if defined(LUS_PLATFORM_WINDOWS)
#define FS_DIRSEP '\\'
#define FS_DIRSEPSTR "\\"
#define FS_PATH_SEP ";"
#else
#define FS_DIRSEP '/'
#define FS_DIRSEPSTR "/"
#define FS_PATH_SEP ":"
#endif

#if defined(LUS_PLATFORM_WINDOWS)
static WCHAR *fs_win_wide(const char *utf8);
static char *fs_win_child(const char *parent, const WCHAR *name);
#endif

/* Helper: check if character is a path separator */
static int is_sep(char c) {
#if defined(LUS_PLATFORM_WINDOWS)
  return c == '\\' || c == '/';
#else
  return c == '/';
#endif
}

/* Helper: check if path is absolute */
static int is_absolute(const char *path, size_t len) {
  if (len == 0)
    return 0;
#if defined(LUS_PLATFORM_WINDOWS)
  /* Absolute: starts with \ or / or has drive letter like C:\ */
  if (is_sep(path[0]))
    return 1;
  if (len >= 3 &&
      ((path[0] >= 'A' && path[0] <= 'Z') ||
       (path[0] >= 'a' && path[0] <= 'z')) &&
      path[1] == ':' && is_sep(path[2]))
    return 1;
  return 0;
#else
  return path[0] == '/';
#endif
}

static int fs_path_join(lua_State *L) {
  int n = lua_gettop(L);
  if (n == 0) {
    lua_pushliteral(L, "");
    return 1;
  }

  luaL_Buffer b;
  luaL_buffinit(L, &b);
  size_t result_len = 0;

  for (int i = 1; i <= n; i++) {
    size_t len;
    const char *s = luaL_checklstring(L, i, &len);

    if (len == 0)
      continue; /* Skip empty components */

    /* If this component is absolute, it replaces everything before it */
    if (is_absolute(s, len)) {
      luaL_pushresult(&b); /* flush and free any allocated buffer */
      lua_pop(L, 1);
      luaL_buffinit(L, &b);
      result_len = 0;
      luaL_addlstring(&b, s, len);
      result_len = len;
      continue;
    }

    /* Add separator if needed: result is non-empty and doesn't end with sep,
       and current component doesn't start with sep */
    if (result_len > 0) {
      /* Check last char in buffer - we track result_len for this */
      char *buf = luaL_buffaddr(&b);
      if (!is_sep(buf[result_len - 1]) && !is_sep(s[0])) {
        luaL_addchar(&b, FS_DIRSEP);
        result_len++;
      }
    }

    luaL_addlstring(&b, s, len);
    result_len += len;
  }

  luaL_pushresult(&b);
  return 1;
}

// Simple split implementation
static int fs_path_split(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  lua_newtable(L);
  int i = 1;
  const char *start = path;
  const char *p = path;
  while (*p) {
    if (*p == FS_DIRSEP ||
        *p == '/') {  // Handle both / and \ on Windows? stick to platform sep
                      // primarily but allow / as common
      lua_pushlstring(L, start, p - start);
      lua_rawseti(L, -2, i++);
      start = p + 1;
    }
    p++;
  }
  if (p > start) {
    lua_pushlstring(L, start, p - start);
    lua_rawseti(L, -2, i++);
  }
  return 1;
}

static int fs_path_name(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  const char *last_sep = strrchr(path, FS_DIRSEP);
#if defined(LUS_PLATFORM_WINDOWS)
  const char *alt_sep = strrchr(path, '/');
  if (alt_sep > last_sep)
    last_sep = alt_sep;
#endif

  if (last_sep) {
    lua_pushstring(L, last_sep + 1);
  }
  else {
    lua_pushstring(L, path);
  }
  return 1;
}

static int fs_path_parent(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  const char *last_sep = strrchr(path, FS_DIRSEP);
#if defined(LUS_PLATFORM_WINDOWS)
  const char *alt_sep = strrchr(path, '/');
  if (alt_sep > last_sep)
    last_sep = alt_sep;
#endif

  if (last_sep) {
    if (last_sep == path) {  // Root
      lua_pushlstring(L, path, 1);
    }
    else {
      lua_pushlstring(L, path, last_sep - path);
    }
  }
  else {
    lua_pushliteral(L, ".");
  }
  return 1;
}

/* }====================================================== */

/*
** {======================================================
** fs.* functions
** =======================================================
*/

// Glob matching helper
static int glob_match(const char *pattern, const char *string) {
#if defined(LUS_PLATFORM_WINDOWS)
  // Simple wildcard matching for Windows (could be improved)
  const char *p = pattern, *s = string;
  while (*p) {
    if (*p == '*') {
      while (*(p + 1) == '*')
        p++;  // skip multiple *
      if (*(p + 1) == 0)
        return 1;  // * at end matches everything
      const char *next = p + 1;
      while (*s) {
        if (glob_match(next, s))
          return 1;
        s++;
      }
      return 0;
    }
    else if (*p == '?') {
      if (!*s)
        return 0;
      p++;
      s++;
    }
    else {
      if (*p != *s)
        return 0;
      p++;
      s++;
    }
  }
  return !*s;
#else
  return fnmatch(pattern, string, 0) == 0;
#endif
}

/*
** fs granter: handles fs permission requests and checks.
** Called by lus_pledge for granting and lus_haspledge for checking.
*/
static void fs_granter(lua_State *L, lus_PledgeRequest *p) {
  /* Granting: accept read/write subpermissions or base fs */
  if (p->status == LUS_PLEDGE_GRANT || p->status == LUS_PLEDGE_UPDATE) {
    /* Reject unanchored patterns: paths are matched (after canonicalization) as
    ** absolute, and fnmatch('*', ...) spans '/', so a leading-wildcard pattern
    ** like "*.pem" would match files anywhere on the filesystem. Require an
    ** absolute, anchored pattern. */
    if (p->value != NULL && (p->value[0] == '*' || p->value[0] == '?')) {
      luaL_error(
          L,
          "fs pledge pattern must be an absolute path, not an unanchored "
          "wildcard: '%s'",
          p->value);
    }
    const char *value = p->value;
    const char *link_value = NULL;
#if defined(LUS_PLATFORM_WINDOWS)
    char *resolved = NULL;
    char *link_resolved = NULL;
    if (value != NULL && *value != '\0') {
      resolved = cast(char *, malloc(LUS_AUTH_PATH_MAX));
      if (resolved == NULL)
        luaL_error(L, "cannot resolve fs pledge path: out of memory");
      if (!luaAP_resolvepattern(value, resolved, LUS_AUTH_PATH_MAX)) {
        free(resolved);
        luaL_error(L, "cannot resolve fs pledge path: '%s'", value);
      }
      value = resolved;
      link_resolved = cast(char *, malloc(LUS_AUTH_PATH_MAX));
      if (link_resolved == NULL) {
        free(resolved);
        luaL_error(L, "cannot resolve fs pledge path: out of memory");
      }
      if (luaAP_resolvelink(p->value, link_resolved, LUS_AUTH_PATH_MAX))
        link_value = link_resolved;
    }
#else
    char resolved[PATH_MAX];
    char link_resolved[PATH_MAX];
    if (value != NULL && *value != '\0') {
      if (!luaAP_resolvepattern(value, resolved, sizeof(resolved)))
        luaL_error(L, "cannot resolve fs pledge path: '%s'", value);
      value = resolved;
      if (luaAP_resolvelink(p->value, link_resolved, sizeof(link_resolved)))
        link_value = link_resolved;
    }
#endif
    if (p->sub == NULL) {
      /* Grant global fs permission */
      lus_setpledge(L, p, NULL, value);
      if (link_value != NULL && strcmp(link_value, value) != 0)
        lus_setpledge(L, p, NULL, link_value);
    }
    else if (strcmp(p->sub, "read") == 0 || strcmp(p->sub, "write") == 0) {
      /* Grant read or write permission */
      lus_setpledge(L, p, p->sub, value);
      if (link_value != NULL && strcmp(link_value, value) != 0)
        lus_setpledge(L, p, p->sub, link_value);
    }
    else {
      /* Unknown subpermission = error */
#if defined(LUS_PLATFORM_WINDOWS)
      free(resolved);
      free(link_resolved);
#endif
      luaL_error(L, "unknown fs subpermission: '%s'", p->sub);
    }
#if defined(LUS_PLATFORM_WINDOWS)
    free(resolved);
    free(link_resolved);
#endif
    return;
  }

  /* Checking: match path against stored globs */
  if (p->status == LUS_PLEDGE_CHECK) {
    const char *path = p->value;

    /* Path-scoped grants cannot authorize operations without a concrete path. */
    if (path == NULL)
      return;

    /* If has_base and no values, global access */
    if (p->has_base && p->count == 0) {
      lus_setpledge(L, p, p->sub, NULL);
      return;
    }

    /* Iterate stored values and check against path using glob */
    while (lus_nextpledge(L, p)) {
      if (p->current && lus_glob_match_path(p->current, path, 1)) {
        lus_setpledge(L, p, p->sub, NULL);
        return;
      }
    }
    /* No match = not processed = denied */
  }
}

/* Helper: check fs permission before operations (using shared helper) */
#define check_fs_permission(L, perm, path) lus_checkfsperm(L, perm, path)

static int fs_list(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  const char *glob = luaL_optstring(L, 2, NULL);

#if !defined(LUS_PLATFORM_WINDOWS)
  check_fs_permission(L, "fs:read", path);
#endif

  lua_newtable(L);
  int i = 1;

#if defined(LUS_PLATFORM_WINDOWS)
  HANDLE directory =
      luaAP_winopen(L, path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
                    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 1, 0);
  LusAuthChain chain;
  char *canonical;
  char *search;
  WCHAR *wide_search;
  WIN32_FIND_DATAW fd;
  HANDLE hFind;
  size_t canonical_len;
  if (directory == INVALID_HANDLE_VALUE)
    return luaL_error(L, "cannot list directory '%s': error %lu", path,
                      (unsigned long)GetLastError());
  if (!luaAP_winlockchain(directory, &chain)) {
    DWORD error = GetLastError();
    CloseHandle(directory);
    return luaL_error(L, "cannot lock directory '%s': error %lu", path,
                      (unsigned long)error);
  }
  canonical = luaAP_winhandlepath(directory);
  if (canonical == NULL) {
    DWORD error = GetLastError();
    luaAP_winclosechain(&chain);
    CloseHandle(directory);
    return luaL_error(L, "cannot list directory '%s': error %lu", path,
                      (unsigned long)error);
  }
  canonical_len = strlen(canonical);
  search = cast(char *, malloc(canonical_len + 3));
  if (search == NULL) {
    free(canonical);
    luaAP_winclosechain(&chain);
    CloseHandle(directory);
    return luaL_error(L, "cannot list directory '%s': out of memory", path);
  }
  memcpy(search, canonical, canonical_len);
  memcpy(search + canonical_len, "\\*", 3);
  wide_search = fs_win_wide(search);
  free(search);
  if (wide_search == NULL) {
    free(canonical);
    luaAP_winclosechain(&chain);
    CloseHandle(directory);
    return luaL_error(L, "cannot list directory '%s': invalid UTF-8", path);
  }
  hFind = FindFirstFileW(wide_search, &fd);
  free(wide_search);
  if (hFind == INVALID_HANDLE_VALUE) {
    DWORD err = GetLastError();
    free(canonical);
    luaAP_winclosechain(&chain);
    CloseHandle(directory);
    if (err == ERROR_FILE_NOT_FOUND)
      return 1;
    if (err == ERROR_PATH_NOT_FOUND)
      return luaL_error(L, "cannot list directory '%s': path not found", path);
    return luaL_error(L, "cannot list directory '%s': error %lu", path,
                      (unsigned long)err);
  }
  do {
    if (wcscmp(fd.cFileName, L".") != 0 && wcscmp(fd.cFileName, L"..") != 0) {
      char *name = fs_win_child("", fd.cFileName);
      if (name == NULL) {
        FindClose(hFind);
        free(canonical);
        luaAP_winclosechain(&chain);
        CloseHandle(directory);
        return luaL_error(L, "cannot decode directory entry in '%s'", path);
      }
      if (*name == '\\')
        memmove(name, name + 1, strlen(name));
      if (glob == NULL || glob_match(glob, name)) {
        lua_pushstring(L, name);
        lua_rawseti(L, -2, i++);
      }
      free(name);
    }
  } while (FindNextFileW(hFind, &fd));
  FindClose(hFind);
  free(canonical);
  luaAP_winclosechain(&chain);
  CloseHandle(directory);
#else
  int dirfd = luaAP_open(L, path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0, 1, 0);
  DIR *d = dirfd >= 0 ? fdopendir(dirfd) : NULL;
  if (d == NULL) {
    if (dirfd >= 0)
      close(dirfd);
    if (errno == ENOTDIR)
      return luaL_error(L, "%s is not a directory", path);
    return luaL_error(L, "cannot list directory %s: %s", path, strerror(errno));
  }
  struct dirent *dir;
  while ((dir = readdir(d)) != NULL) {
    if (strcmp(dir->d_name, ".") != 0 && strcmp(dir->d_name, "..") != 0) {
      if (glob == NULL || glob_match(glob, dir->d_name)) {
        lua_pushstring(L, dir->d_name);
        lua_rawseti(L, -2, i++);
      }
    }
  }
  closedir(d);
#endif
  return 1;
}

static int fs_copy(lua_State *L) {
  const char *src = luaL_checkstring(L, 1);
  const char *dst = luaL_checkstring(L, 2);

  check_fs_permission(L, "fs:read", src);
  check_fs_permission(L, "fs:write", dst);

#if defined(LUS_PLATFORM_WINDOWS)
  if (!luaAP_wincopy(L, src, dst)) {
    DWORD err = GetLastError();
    if (err == ERROR_FILE_NOT_FOUND)
      return luaL_error(L, "cannot open source '%s': file not found", src);
    if (err == ERROR_FILE_EXISTS || err == ERROR_ALREADY_EXISTS)
      return luaL_error(L, "target '%s' already exists", dst);
    return luaL_error(L, "failed to copy '%s' to '%s': error %lu", src, dst,
                      (unsigned long)err);
  }
#else
  LusAuthFile dst_file;
  int status;
  int in_fd = luaAP_open(L, src, O_RDONLY | O_CLOEXEC, 0, 1, 0);
  if (in_fd < 0)
    return luaL_error(L, "cannot open source '%s': %s", src, strerror(errno));
  FILE *in = fdopen(in_fd, "rb");
  if (in == NULL) {
    int saved_errno = errno;
    close(in_fd);
    return luaL_error(L, "cannot open source '%s': %s", src,
                      strerror(saved_errno));
  }
  status = luaAP_tryopen(
      L, dst,
      LUS_AUTH_WRITE | LUS_AUTH_CREATE | LUS_AUTH_EXCLUSIVE | LUS_AUTH_DELETE,
      0666, &dst_file);
  if (status != LUS_AUTH_OK) {
    int saved_errno = errno;
    fclose(in);
    luaAP_closeauthfile(&dst_file);
    if (status == LUS_AUTH_EXISTS)
      return luaL_error(L, "target '%s' already exists", dst);
    if (status == LUS_AUTH_DENIED)
      return luaL_error(L, "permission \"%s\" denied for '%s'",
                        dst_file.denied_perm, dst);
    return luaL_error(L, "cannot create target '%s': %s", dst,
                      strerror(saved_errno));
  }
  int out_fd;
#if defined(F_DUPFD_CLOEXEC)
  out_fd = fcntl(dst_file.fd, F_DUPFD_CLOEXEC, 0);
#else
  out_fd = dup(dst_file.fd);
  if (out_fd >= 0 && fcntl(out_fd, F_SETFD, FD_CLOEXEC) != 0) {
    int saved_errno = errno;
    close(out_fd);
    out_fd = -1;
    errno = saved_errno;
  }
#endif
  if (out_fd < 0) {
    int saved_errno = errno;
    fclose(in);
    luaAP_deleteauthfile(&dst_file);
    luaAP_closeauthfile(&dst_file);
    return luaL_error(L, "cannot create target '%s': %s", dst,
                      strerror(saved_errno));
  }
  FILE *out = fdopen(out_fd, "wb");
  if (!out) {
    int saved_errno = errno;
    close(out_fd);
    fclose(in);
    luaAP_deleteauthfile(&dst_file);
    luaAP_closeauthfile(&dst_file);
    return luaL_error(L, "cannot open target '%s': %s", dst,
                      strerror(saved_errno));
  }

  char buf[8192];
  size_t n;
  int copy_error = 0;

  while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
    if (fwrite(buf, 1, n, out) != n) {
      copy_error = errno;
      break;
    }
  }

  /* Check for read error */
  if (!copy_error && ferror(in)) {
    copy_error = errno ? errno : EIO;
  }

  fclose(in);
  if (fclose(out) != 0 && !copy_error) {
    copy_error = errno;
  }

  if (copy_error) {
    luaAP_deleteauthfile(&dst_file);
    luaAP_closeauthfile(&dst_file);
    return luaL_error(L, "error copying '%s' to '%s': %s", src, dst,
                      strerror(copy_error));
  }
  luaAP_closeauthfile(&dst_file);
#endif
  return 0;
}

static int fs_move(lua_State *L) {
  const char *src = luaL_checkstring(L, 1);
  const char *dst = luaL_checkstring(L, 2);

#if defined(LUS_PLATFORM_WINDOWS)
  check_fs_permission(L, "fs:read", src);
  check_fs_permission(L, "fs:write", src); /* move deletes source */
  check_fs_permission(L, "fs:write", dst);
  if (!luaAP_winmove(L, src, dst)) {
    DWORD err = GetLastError();
    if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND)
      return luaL_error(L, "cannot move '%s': source does not exist", src);
    if (err == ERROR_FILE_EXISTS || err == ERROR_ALREADY_EXISTS)
      return luaL_error(L, "cannot move to '%s': target already exists", dst);
    return luaL_error(L, "cannot move '%s' to '%s': error %lu", src, dst,
                      (unsigned long)err);
  }
#else
  LusAuthMoveSource source;
  if (!luaAP_bindmovesource(L, src, &source))
    return luaL_error(L, "cannot move '%s': %s", src, strerror(errno));
  if (!luaAP_movebound(L, &source, dst)) {
    int err = errno;
    const char *denied = source.denied_perm;
    luaAP_closemovesource(&source);
    if (denied != NULL)
      return luaL_error(L, "permission \"%s\" denied for '%s'", denied, dst);
    if (err == ENOENT)
      return luaL_error(L, "cannot move '%s': source does not exist", src);
    if (err == EEXIST)
      return luaL_error(L, "cannot move to '%s': target already exists", dst);
    if (err == EAGAIN)
      return luaL_error(L, "cannot move '%s': source changed during move", src);
    if (err == EXDEV)
      return luaL_error(L, "cannot move '%s' to '%s': cross-device move", src,
                        dst);
    return luaL_error(L, "cannot move '%s' to '%s': %s", src, dst,
                      strerror(err));
  }
  luaAP_closemovesource(&source);
#endif
  return 0;
}

#if defined(LUS_PLATFORM_WINDOWS)
static WCHAR *fs_win_wide(const char *utf8) {
  WCHAR *wide;
  int needed =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
  if (needed <= 0)
    return NULL;
  wide = cast(WCHAR *, malloc(cast_sizet(needed) * sizeof(WCHAR)));
  if (wide == NULL)
    return NULL;
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, wide,
                          needed) == 0) {
    free(wide);
    return NULL;
  }
  return wide;
}

static char *fs_win_child(const char *parent, const WCHAR *name) {
  char *child;
  int name_len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name, -1,
                                     NULL, 0, NULL, NULL);
  size_t parent_len = strlen(parent);
  if (name_len <= 0 || parent_len > SIZE_MAX - cast_sizet(name_len) - 1)
    return NULL;
  child = cast(char *, malloc(parent_len + cast_sizet(name_len) + 1));
  if (child == NULL)
    return NULL;
  memcpy(child, parent, parent_len);
  child[parent_len++] = '\\';
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name, -1,
                          child + parent_len, name_len, NULL, NULL) == 0) {
    free(child);
    return NULL;
  }
  return child;
}

static int fs_remove_recursive(lua_State *L, const char *path) {
  HANDLE handle =
      luaAP_winopen(L, path, DELETE | FILE_READ_ATTRIBUTES, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT, 0, 1);
  LusAuthChain chain;
  int chain_locked = 0;
  BY_HANDLE_FILE_INFORMATION info;
  FILE_DISPOSITION_INFO remove = {TRUE};
  char *canonical = NULL;
  char *search = NULL;
  WCHAR *wide_search = NULL;
  HANDLE find = INVALID_HANDLE_VALUE;
  WIN32_FIND_DATAW entry;
  DWORD error = ERROR_SUCCESS;
  if (handle == INVALID_HANDLE_VALUE)
    return -1;
  if (!luaAP_winlockchain(handle, &chain)) {
    error = GetLastError();
    goto done;
  }
  chain_locked = 1;
  if (!GetFileInformationByHandle(handle, &info)) {
    error = GetLastError();
    goto done;
  }
  if ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
      (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0) {
    size_t canonical_len;
    canonical = luaAP_winhandlepath(handle);
    if (canonical == NULL) {
      error = GetLastError();
      goto done;
    }
    canonical_len = strlen(canonical);
    search = cast(char *, malloc(canonical_len + 3));
    if (search == NULL) {
      error = ERROR_OUTOFMEMORY;
      goto done;
    }
    memcpy(search, canonical, canonical_len);
    memcpy(search + canonical_len, "\\*", 3);
    wide_search = fs_win_wide(search);
    if (wide_search == NULL) {
      error = GetLastError();
      if (error == ERROR_SUCCESS)
        error = ERROR_NO_UNICODE_TRANSLATION;
      goto done;
    }
    find = FindFirstFileW(wide_search, &entry);
    if (find == INVALID_HANDLE_VALUE) {
      error = GetLastError();
      if (error == ERROR_FILE_NOT_FOUND)
        error = ERROR_SUCCESS;
      goto enumeration_done;
    }
    do {
      if (wcscmp(entry.cFileName, L".") != 0 &&
          wcscmp(entry.cFileName, L"..") != 0) {
        char *child = fs_win_child(canonical, entry.cFileName);
        if (child == NULL) {
          error = ERROR_OUTOFMEMORY;
          break;
        }
        if (fs_remove_recursive(L, child) != 0)
          error = GetLastError();
        free(child);
        if (error != ERROR_SUCCESS)
          break;
      }
    } while (FindNextFileW(find, &entry));
    if (error == ERROR_SUCCESS && GetLastError() != ERROR_NO_MORE_FILES)
      error = GetLastError();
  }
enumeration_done:
  if (find != INVALID_HANDLE_VALUE)
    FindClose(find);
  find = INVALID_HANDLE_VALUE;
  if (error == ERROR_SUCCESS &&
      !SetFileInformationByHandle(handle, FileDispositionInfo, &remove,
                                  sizeof(remove)))
    error = GetLastError();
done:
  if (find != INVALID_HANDLE_VALUE)
    FindClose(find);
  free(wide_search);
  free(search);
  free(canonical);
  if (chain_locked)
    luaAP_winclosechain(&chain);
  CloseHandle(handle);
  if (error != ERROR_SUCCESS) {
    SetLastError(error);
    return -1;
  }
  return 0;
}
#endif

static int fs_remove(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int recursive = lua_toboolean(L, 2);

#if defined(LUS_PLATFORM_WINDOWS)
  if (recursive ? fs_remove_recursive(L, path) != 0
                : !luaAP_winremove(L, path)) {
    DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
      return luaL_error(L, "cannot remove '%s': path does not exist", path);
    if (error == ERROR_DIR_NOT_EMPTY)
      return luaL_error(L, "cannot remove directory '%s': not empty", path);
    return luaL_error(L, "cannot remove '%s': error %lu", path,
                      (unsigned long)error);
  }
#else
  LusAuthFile file;
  int status = luaAP_trybinddelete(L, path, "fs:write", &file);
  int is_directory;
  int result;
  if (status != LUS_AUTH_OK) {
    int err = errno;
    const char *denied = file.denied_perm;
    luaAP_closeauthfile(&file);
    if (status == LUS_AUTH_MISSING)
      return luaL_error(L, "cannot remove '%s': path does not exist", path);
    if (status == LUS_AUTH_DENIED)
      return luaL_error(L, "permission \"%s\" denied for '%s'", denied, path);
    return luaL_error(L, "cannot remove '%s': %s", path, strerror(err));
  }
  is_directory = S_ISDIR(file.object_mode) && !S_ISLNK(file.object_mode);
  result = recursive && is_directory ? luaAP_deleteauthrecursive(&file)
                                     : luaAP_deleteauthfile(&file);
  if (!result) {
    int err = errno;
    luaAP_closeauthfile(&file);
    if (is_directory && !recursive && err == ENOTEMPTY)
      return luaL_error(L, "cannot remove directory '%s': not empty", path);
    if (is_directory && recursive)
      return luaL_error(L, "failed to remove directory '%s' recursively: %s",
                        path, strerror(err));
    if (err == EAGAIN)
      return luaL_error(L, "cannot remove '%s': path changed during removal",
                        path);
    return luaL_error(L, "cannot remove '%s': %s", path, strerror(err));
  }
  luaAP_closeauthfile(&file);
#endif
  return 0;
}

static int fs_type(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#if defined(LUS_PLATFORM_WINDOWS)
  HANDLE handle = luaAP_winopen(L, path, FILE_READ_ATTRIBUTES, OPEN_EXISTING,
                                FILE_FLAG_OPEN_REPARSE_POINT, 1, 0);
  BY_HANDLE_FILE_INFORMATION info;
  DWORD attrs;
  if (handle == INVALID_HANDLE_VALUE) {
    DWORD err = GetLastError();
    if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND)
      return luaL_error(L, "path '%s' does not exist", path);
    return luaL_error(L, "cannot get type of '%s': error %lu", path,
                      (unsigned long)err);
  }
  if (!GetFileInformationByHandle(handle, &info)) {
    DWORD err = GetLastError();
    CloseHandle(handle);
    return luaL_error(L, "cannot get type of '%s': error %lu", path,
                      (unsigned long)err);
  }
  attrs = info.dwFileAttributes;
  CloseHandle(handle);
  if (attrs & FILE_ATTRIBUTE_DIRECTORY)
    lua_pushliteral(L, "directory");
  else
    lua_pushliteral(L, "file");
  /* FILE_ATTRIBUTE_REPARSE_POINT indicates symlink (or junction) */
  lua_pushboolean(L, attrs & FILE_ATTRIBUTE_REPARSE_POINT);
#else
  LusAuthParent parent;
  if (!luaAP_parent(L, path, "fs:read", &parent))
    return luaL_error(L, "cannot get type of '%s': %s", path, strerror(errno));
  struct stat st;
  if (fstatat(parent.fd, parent.leaf, &st, AT_SYMLINK_NOFOLLOW) != 0) {
    int err = errno;
    luaAP_closeparent(&parent);
    if (err == ENOENT)
      return luaL_error(L, "path '%s' does not exist", path);
    return luaL_error(L, "cannot get type of '%s': %s", path, strerror(err));
  }
  if (S_ISDIR(st.st_mode))
    lua_pushliteral(L, "directory");
  else
    lua_pushliteral(L, "file");
  lua_pushboolean(L, S_ISLNK(st.st_mode));
  luaAP_closeparent(&parent);
#endif
  return 2;
}

static int fs_follow(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#if defined(LUS_PLATFORM_WINDOWS)
  /* Read the reparse data so the stored target comes back verbatim, the
  ** contract readlink gives on POSIX. Opening with the reparse flag keeps
  ** the link itself readable even when its target is missing, and lets a
  ** regular file be rejected instead of silently resolving to itself. */
  HANDLE hFile =
      luaAP_winopen(L, path, GENERIC_READ | FILE_READ_ATTRIBUTES, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT, 1, 0);
  if (hFile == INVALID_HANDLE_VALUE) {
    DWORD err = GetLastError();
    if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND)
      return luaL_error(L, "path '%s' not found", path);
    return luaL_error(L, "cannot open '%s': error %lu", path,
                      (unsigned long)err);
  }
  /* 16384 is MAXIMUM_REPARSE_DATA_BUFFER_SIZE, which only the driver kit
  ** headers define. The union keeps the payload aligned for the header
  ** fields. */
  union {
    unsigned char raw[16384];
    ULONG align;
  } rb;
  DWORD got = 0;
  if (!DeviceIoControl(hFile, FSCTL_GET_REPARSE_POINT, NULL, 0, rb.raw,
                       sizeof(rb.raw), &got, NULL)) {
    DWORD err = GetLastError();
    CloseHandle(hFile);
    if (err == ERROR_NOT_A_REPARSE_POINT)
      return luaL_error(L, "'%s' is not a symbolic link", path);
    return luaL_error(L, "cannot read link '%s': error %lu", path,
                      (unsigned long)err);
  }
  /* Minimal layout of the symlink reparse payload. The official
  ** REPARSE_DATA_BUFFER lives in the driver kit headers, so the needed
  ** fields are declared here. */
  typedef struct {
    ULONG ReparseTag;
    USHORT ReparseDataLength;
    USHORT Reserved;
    USHORT SubstituteNameOffset;
    USHORT SubstituteNameLength;
    USHORT PrintNameOffset;
    USHORT PrintNameLength;
    ULONG Flags;
    WCHAR PathBuffer[1];
  } lus_symlink_reparse;
  const lus_symlink_reparse *r = (const lus_symlink_reparse *)(void *)rb.raw;
  size_t header_size = offsetof(lus_symlink_reparse, PathBuffer);
  size_t record_size;
  size_t payload_size;
  if (got < header_size || r->ReparseTag != IO_REPARSE_TAG_SYMLINK) {
    CloseHandle(hFile);
    return luaL_error(L, "'%s' is not a symbolic link", path);
  }
  record_size = 8 + cast_sizet(r->ReparseDataLength);
  if (record_size < header_size || record_size > got) {
    CloseHandle(hFile);
    return luaL_error(L, "invalid symbolic link data for '%s'", path);
  }
  payload_size = record_size - header_size;
  /* Prefer the print name, which holds the target exactly as it was given
  ** to createlink. Fall back to the substitute name and strip its NT
  ** namespace prefix. */
  const WCHAR *wtarget;
  int wchars;
  int substitute = 0;
  if (r->PrintNameLength > 0) {
    if ((r->PrintNameOffset % sizeof(WCHAR)) != 0 ||
        (r->PrintNameLength % sizeof(WCHAR)) != 0 ||
        cast_sizet(r->PrintNameOffset) > payload_size ||
        cast_sizet(r->PrintNameLength) >
            payload_size - cast_sizet(r->PrintNameOffset)) {
      CloseHandle(hFile);
      return luaL_error(L, "invalid symbolic link data for '%s'", path);
    }
    wtarget = r->PathBuffer + r->PrintNameOffset / sizeof(WCHAR);
    wchars = (int)(r->PrintNameLength / sizeof(WCHAR));
  }
  else {
    if ((r->SubstituteNameOffset % sizeof(WCHAR)) != 0 ||
        (r->SubstituteNameLength % sizeof(WCHAR)) != 0 ||
        cast_sizet(r->SubstituteNameOffset) > payload_size ||
        cast_sizet(r->SubstituteNameLength) >
            payload_size - cast_sizet(r->SubstituteNameOffset)) {
      CloseHandle(hFile);
      return luaL_error(L, "invalid symbolic link data for '%s'", path);
    }
    wtarget = r->PathBuffer + r->SubstituteNameOffset / sizeof(WCHAR);
    wchars = (int)(r->SubstituteNameLength / sizeof(WCHAR));
    substitute = 1;
  }
  CloseHandle(hFile);
  int blen = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wtarget, wchars,
                                 NULL, 0, NULL, NULL);
  char *buf;
  if (blen <= 0)
    return luaL_error(L, "cannot decode link target for '%s'", path);
  buf = cast(char *, malloc(cast_sizet(blen) + 1));
  if (buf == NULL)
    return luaL_error(L, "cannot decode link target for '%s': out of memory",
                      path);
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wtarget, wchars, buf,
                          blen, NULL, NULL) == 0) {
    free(buf);
    return luaL_error(L, "cannot decode link target for '%s'", path);
  }
  buf[blen] = '\0';
  if (substitute && blen >= 8 && strncmp(buf, "\\??\\UNC\\", 8) == 0) {
    memmove(buf + 2, buf + 8, cast_sizet(blen - 8));
    buf[0] = '\\';
    buf[1] = '\\';
    blen -= 6;
  }
  else if (substitute && blen >= 4 && strncmp(buf, "\\??\\", 4) == 0) {
    memmove(buf, buf + 4, cast_sizet(blen - 4));
    blen -= 4;
  }
  lua_pushlstring(L, buf, cast_sizet(blen));
  free(buf);
  return 1;
#else
  LusAuthParent parent;
  if (!luaAP_parent(L, path, "fs:read", &parent))
    return luaL_error(L, "cannot stat '%s': %s", path, strerror(errno));
  struct stat st;
  if (fstatat(parent.fd, parent.leaf, &st, AT_SYMLINK_NOFOLLOW) != 0) {
    int err = errno;
    luaAP_closeparent(&parent);
    return luaL_error(L, "cannot stat '%s': %s", path, strerror(err));
  }
  if (!S_ISLNK(st.st_mode)) {
    luaAP_closeparent(&parent);
    return luaL_error(L, "'%s' is not a symbolic link", path);
  }

  /* Use PATH_MAX if available, otherwise a reasonable default */
#ifdef PATH_MAX
  char buf[PATH_MAX];
#else
  char buf[4096];
#endif
  ssize_t len = readlinkat(parent.fd, parent.leaf, buf, sizeof(buf) - 1);
  if (len == -1) {
    int err = errno;
    luaAP_closeparent(&parent);
    return luaL_error(L, "cannot read link '%s': %s", path, strerror(err));
  }
  if ((size_t)len >= sizeof(buf) - 1) {
    luaAP_closeparent(&parent);
    return luaL_error(L, "symlink target too long for '%s'", path);
  }
  buf[len] = '\0';
  lua_pushstring(L, buf);
  luaAP_closeparent(&parent);
  return 1;
#endif
}

static int fs_createlink(lua_State *L) {
  const char *at = luaL_checkstring(L, 1);
  const char *target = luaL_checkstring(L, 2);
#if !defined(LUS_PLATFORM_WINDOWS)
  check_fs_permission(L, "fs:write", at);
  /* Also gate the TARGET: a symlink that points outside the sandbox is the
  ** primitive behind the check-vs-open (TOCTOU) escape. Requiring the target to
  ** be within the writable scope prevents planting an out-of-sandbox link. */
  check_fs_permission(L, "fs:write", target);
#endif

#if defined(LUS_PLATFORM_WINDOWS)
  if (!luaAP_winsymlink(L, at, target)) {
    DWORD err = GetLastError();
    if (err == ERROR_PRIVILEGE_NOT_HELD)
      return luaL_error(
          L,
          "failed to create symlink '%s': requires administrator or "
          "developer mode",
          at);
    return luaL_error(L, "failed to create symlink '%s' -> '%s': error %lu", at,
                      target, (unsigned long)err);
  }
#else
  LusAuthParent parent;
  if (!luaAP_parent(L, at, "fs:write", &parent))
    return luaL_error(L, "failed to create symlink '%s' -> '%s': %s", at,
                      target, strerror(errno));
  if (symlinkat(target, parent.fd, parent.leaf) != 0) {
    int err = errno;
    luaAP_closeparent(&parent);
    return luaL_error(L, "failed to create symlink '%s' -> '%s': %s", at,
                      target, strerror(err));
  }
  luaAP_closeparent(&parent);
#endif
  return 0;
}

#if defined(LUS_PLATFORM_WINDOWS)
static int fs_win_ensure_directory(lua_State *L, const char *path) {
  if (luaAP_winmkdir(L, path))
    return 1;
  if (GetLastError() == ERROR_ALREADY_EXISTS ||
      GetLastError() == ERROR_FILE_EXISTS) {
    HANDLE handle = luaAP_winopen(L, path, FILE_READ_ATTRIBUTES, OPEN_EXISTING,
                                  FILE_FLAG_BACKUP_SEMANTICS, 0, 1);
    BY_HANDLE_FILE_INFORMATION info;
    int directory;
    if (handle == INVALID_HANDLE_VALUE)
      return 0;
    directory = GetFileInformationByHandle(handle, &info) &&
                (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    CloseHandle(handle);
    if (!directory)
      SetLastError(ERROR_DIRECTORY);
    return directory;
  }
  return 0;
}

static int fs_win_existing_directory(lua_State *L, const char *path) {
  static const char probe_leaf[] = "\\.__lus_directory_probe__";
  size_t length = strlen(path);
  char *probe;
  LusAuthParent parent;
  BY_HANDLE_FILE_INFORMATION info;
  int got_info;
  int directory;
  DWORD error;
  if (length > SIZE_MAX - sizeof(probe_leaf)) {
    SetLastError(ERROR_FILENAME_EXCED_RANGE);
    return 0;
  }
  probe = cast(char *, malloc(length + sizeof(probe_leaf)));
  if (probe == NULL) {
    SetLastError(ERROR_OUTOFMEMORY);
    return 0;
  }
  memcpy(probe, path, length);
  memcpy(probe + length, probe_leaf, sizeof(probe_leaf));
  if (!luaAP_parent(L, probe, NULL, &parent)) {
    free(probe);
    return 0;
  }
  free(probe);
  got_info = GetFileInformationByHandle(parent.handle, &info);
  directory =
      got_info && (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  error = got_info ? ERROR_DIRECTORY : GetLastError();
  luaAP_closeparent(&parent);
  if (!directory) {
    SetLastError(error);
  }
  return directory;
}

static size_t fs_win_root_length(const char *path) {
  const char *p;
  size_t length = strlen(path);
  if (length >= 3 &&
      ((path[0] >= 'A' && path[0] <= 'Z') ||
       (path[0] >= 'a' && path[0] <= 'z')) &&
      path[1] == ':' && is_sep(path[2]))
    return 3;
  if (length >= 7 && strncmp(path, "\\\\?\\", 4) == 0 && path[4] != '\0' &&
      path[5] == ':' && is_sep(path[6]))
    return 7;
  if (length >= 8 && strncmp(path, "\\\\?\\UNC\\", 8) == 0)
    p = path + 8;
  else if (length >= 2 && is_sep(path[0]) && is_sep(path[1]))
    p = path + 2;
  else
    return 0;
  while (*p != '\0' && !is_sep(*p))
    p++;
  if (*p != '\0')
    p++;
  while (*p != '\0' && !is_sep(*p))
    p++;
  return *p == '\0' ? cast_sizet(p - path) : cast_sizet(p - path + 1);
}

static int create_dirs_recursive(lua_State *L, const char *path) {
  size_t len = strlen(path);
  size_t root;
  char *copy;
  if (len == 0)
    return 0;
  copy = cast(char *, malloc(len + 1));
  if (copy == NULL)
    return luaL_error(L, "cannot create directory '%s': out of memory", path);
  memcpy(copy, path, len + 1);
  root = fs_win_root_length(copy);
  for (size_t i = root; i < len; i++) {
    if (is_sep(copy[i])) {
      char separator = copy[i];
      copy[i] = '\0';
      if (*copy != '\0' && (lus_haspledge(L, "fs:write", copy)
                                ? !fs_win_ensure_directory(L, copy)
                                : !fs_win_existing_directory(L, copy))) {
        DWORD error = GetLastError();
        free(copy);
        return luaL_error(L, "cannot create directory '%s': error %lu", path,
                          (unsigned long)error);
      }
      copy[i] = separator;
    }
  }
  if (!fs_win_ensure_directory(L, copy)) {
    DWORD error = GetLastError();
    free(copy);
    return luaL_error(L, "cannot create directory '%s': error %lu", path,
                      (unsigned long)error);
  }
  free(copy);
  return 0;
}
#else
static int append_component(char *path, size_t path_size,
                            const char *component) {
  size_t len = strlen(path);
  size_t component_len = strlen(component);
  int needs_sep = len == 0 || path[len - 1] != '/';
  if (len + cast_sizet(needs_sep) + component_len + 1 > path_size)
    return 0;
  if (needs_sep)
    path[len++] = '/';
  memcpy(path + len, component, component_len + 1);
  return 1;
}

static int remaining_canonical(const char *current, char **parts, int index,
                               int count, char result[PATH_MAX]) {
  size_t len = strlen(current);
  if (len >= PATH_MAX)
    return 0;
  memcpy(result, current, len + 1);
  for (; index < count; index++) {
    if (!append_component(result, PATH_MAX, parts[index]))
      return 0;
  }
  return 1;
}

static int create_dirs_recursive_posix(lua_State *L, const char *path) {
  char copy[PATH_MAX];
  char canonical[PATH_MAX];
  char candidate[PATH_MAX];
  char *parts[PATH_MAX / 2];
  char *save = NULL;
  char *part;
  int count = 0;
  int fd;
  size_t len = strlen(path);
  if (len == 0)
    return 0;
  if (len >= sizeof(copy))
    return luaL_error(L, "path too long: '%s'", path);
  memcpy(copy, path, len + 1);
  part = strtok_r(copy, "/", &save);
  while (part != NULL) {
    if (strcmp(part, ".") == 0) {
      part = strtok_r(NULL, "/", &save);
      continue;
    }
    if (strcmp(part, "..") == 0)
      return luaL_error(L, "cannot create directory '%s': '..' is denied",
                        path);
    if (count >= cast_int(sizeof(parts) / sizeof(parts[0])))
      return luaL_error(L, "path has too many components: '%s'", path);
    parts[count++] = part;
    part = strtok_r(NULL, "/", &save);
  }
  fd = open(path[0] == '/' ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0 || !luaAP_fdpath(fd, canonical, sizeof(canonical))) {
    int err = errno;
    if (fd >= 0)
      close(fd);
    return luaL_error(L, "cannot create directory '%s': %s", path,
                      strerror(err));
  }
  for (int i = 0; i < count; i++) {
    int next = openat(fd, parts[i], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (next < 0 && errno == ENOENT) {
      if (!remaining_canonical(canonical, parts, i, count, candidate)) {
        close(fd);
        return luaL_error(L, "path too long: '%s'", path);
      }
      if (!luaP_hasfscanonical(L, "fs:write", candidate)) {
        close(fd);
        return luaL_error(L, "permission \"fs:write\" denied for '%s'", path);
      }
      if (mkdirat(fd, parts[i], 0777) != 0 && errno != EEXIST) {
        int err = errno;
        close(fd);
        return luaL_error(L, "cannot create directory '%s': %s", path,
                          strerror(err));
      }
      next = openat(fd, parts[i], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    }
    if (next < 0) {
      int err = errno;
      close(fd);
      return luaL_error(L, "cannot create directory '%s': %s", path,
                        strerror(err));
    }
    close(fd);
    fd = next;
    if (!luaAP_fdpath(fd, canonical, sizeof(canonical))) {
      int err = errno;
      close(fd);
      return luaL_error(L, "cannot create directory '%s': %s", path,
                        strerror(err));
    }
    if (!remaining_canonical(canonical, parts, i + 1, count, candidate)) {
      close(fd);
      return luaL_error(L, "path too long: '%s'", path);
    }
    if (!luaP_hasfscanonical(L, "fs:write", candidate)) {
      close(fd);
      return luaL_error(L, "permission \"fs:write\" denied for '%s'", path);
    }
  }
  close(fd);
  return 0;
}
#endif

static int fs_createdirectory(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int recursive = lua_toboolean(L, 2);

#if defined(LUS_PLATFORM_WINDOWS)
  if (!recursive)
    check_fs_permission(L, "fs:write", path);
#else
  check_fs_permission(L, "fs:write", path);
#endif

  if (recursive) {
#if defined(LUS_PLATFORM_WINDOWS)
    return create_dirs_recursive(L, path);
#else
    return create_dirs_recursive_posix(L, path);
#endif
  }

#if defined(LUS_PLATFORM_WINDOWS)
  if (!luaAP_winmkdir(L, path)) {
    DWORD err = GetLastError();
    if (err == ERROR_ALREADY_EXISTS)
      return luaL_error(L, "cannot create directory '%s': already exists",
                        path);
    if (err == ERROR_PATH_NOT_FOUND)
      return luaL_error(
          L, "cannot create directory '%s': parent does not exist", path);
    return luaL_error(L, "cannot create directory '%s': error %lu", path,
                      (unsigned long)err);
  }
#else
  LusAuthParent parent;
  if (!luaAP_parent(L, path, "fs:write", &parent))
    return luaL_error(L, "cannot create directory '%s': %s", path,
                      strerror(errno));
  if (mkdirat(parent.fd, parent.leaf, 0777) != 0) {
    int err = errno;
    luaAP_closeparent(&parent);
    if (err == EEXIST)
      return luaL_error(L, "cannot create directory '%s': already exists",
                        path);
    if (err == ENOENT)
      return luaL_error(
          L, "cannot create directory '%s': parent does not exist", path);
    if (err == EACCES)
      return luaL_error(L, "cannot create directory '%s': permission denied",
                        path);
    return luaL_error(L, "cannot create directory '%s': %s", path,
                      strerror(err));
  }
  luaAP_closeparent(&parent);
#endif
  return 0;
}

static const luaL_Reg fslib[] = {{"list", fs_list},
                                 {"copy", fs_copy},
                                 {"move", fs_move},
                                 {"remove", fs_remove},
                                 {"type", fs_type},
                                 {"follow", fs_follow},
                                 {"createlink", fs_createlink},
                                 {"createdirectory", fs_createdirectory},
                                 {NULL, NULL}};

static const luaL_Reg fspathlib[] = {{"join", fs_path_join},
                                     {"split", fs_path_split},
                                     {"name", fs_path_name},
                                     {"parent", fs_path_parent},
                                     {NULL, NULL}};

LUAMOD_API int luaopen_fs(lua_State *L) {
  /* Register fs granter for permission checking */
  lus_registerpledge(L, "fs", fs_granter);

  luaL_newlib(L, fslib);
  /* Add fs.path */
  luaL_newlib(L, fspathlib);
  /* Add constants */
  lua_pushliteral(L, FS_DIRSEPSTR);
  lua_setfield(L, -2, "separator");
  lua_pushliteral(L, FS_PATH_SEP);
  lua_setfield(L, -2, "delimiter");

  lua_setfield(L, -2, "path");
  return 1;
}
