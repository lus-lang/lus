/*
** lauthpath.c
** Descriptor-bound filesystem authorization
*/

#define lauthpath_c
#define LUA_CORE

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

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

#include "lua.h"

#include "lauthpath.h"
#include "lauxlib.h"
#include "llimits.h"
#include "lpledge.h"

#if !defined(__EMSCRIPTEN__)
void luaAP_initwasmconsole(void) {
}
#endif

#if defined(LUS_PLATFORM_WINDOWS)
#include <fcntl.h>
#include <io.h>
#include <limits.h>
#include <stdint.h>
#include <wchar.h>
#include <wctype.h>
#include <windows.h>
#include <winioctl.h>

#if !defined(OBJ_CASE_INSENSITIVE)
#define OBJ_CASE_INSENSITIVE 0x00000040L
#endif

#define LUS_FILE_DIRECTORY_FILE 0x00000001UL
#define LUS_FILE_SYNCHRONOUS_IO_NONALERT 0x00000020UL
#define LUS_FILE_NON_DIRECTORY_FILE 0x00000040UL
#define LUS_FILE_OPEN_REPARSE_POINT 0x00200000UL
#define LUS_FILE_OPEN 0x00000001UL
#define LUS_FILE_CREATE 0x00000002UL

typedef LONG LusNtStatus;

typedef struct LusUnicodeString {
  USHORT Length;
  USHORT MaximumLength;
  PWSTR Buffer;
} LusUnicodeString;

typedef struct LusObjectAttributes {
  ULONG Length;
  HANDLE RootDirectory;
  LusUnicodeString *ObjectName;
  ULONG Attributes;
  PVOID SecurityDescriptor;
  PVOID SecurityQualityOfService;
} LusObjectAttributes;

typedef struct LusIoStatusBlock {
  union {
    LusNtStatus Status;
    PVOID Pointer;
  } result;
  ULONG_PTR Information;
} LusIoStatusBlock;

typedef LusNtStatus(NTAPI *LusNtCreateFile)(PHANDLE, ACCESS_MASK,
                                            LusObjectAttributes *,
                                            LusIoStatusBlock *, LARGE_INTEGER *,
                                            ULONG, ULONG, ULONG, ULONG, PVOID,
                                            ULONG);
typedef ULONG(WINAPI *LusRtlNtStatusToDosError)(LusNtStatus);

static WCHAR *win_utf8_raw(const char *text);

static void win_set_errno(DWORD error) {
  switch (error) {
    case ERROR_FILE_NOT_FOUND:
    case ERROR_PATH_NOT_FOUND: errno = ENOENT; break;
    case ERROR_FILE_EXISTS:
    case ERROR_ALREADY_EXISTS: errno = EEXIST; break;
    case ERROR_ACCESS_DENIED:
    case ERROR_SHARING_VIOLATION: errno = EACCES; break;
    case ERROR_NOT_ENOUGH_MEMORY:
    case ERROR_OUTOFMEMORY: errno = ENOMEM; break;
    case ERROR_DIRECTORY: errno = ENOTDIR; break;
    case ERROR_DIR_NOT_EMPTY: errno = ENOTEMPTY; break;
    case ERROR_FILENAME_EXCED_RANGE: errno = ENAMETOOLONG; break;
    default: errno = EIO; break;
  }
}

static WCHAR *win_utf8_to_fullpath(const char *path) {
  WCHAR *input;
  WCHAR *full;
  DWORD needed;
  int input_len;
  if (path == NULL || *path == '\0') {
    SetLastError(ERROR_INVALID_NAME);
    win_set_errno(ERROR_INVALID_NAME);
    return NULL;
  }
  input_len =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (input_len <= 0) {
    win_set_errno(GetLastError());
    return NULL;
  }
  input = cast(WCHAR *, malloc(cast_sizet(input_len) * sizeof(WCHAR)));
  if (input == NULL) {
    SetLastError(ERROR_OUTOFMEMORY);
    errno = ENOMEM;
    return NULL;
  }
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, input,
                          input_len) == 0) {
    DWORD error = GetLastError();
    free(input);
    SetLastError(error);
    win_set_errno(error);
    return NULL;
  }
  if (wcsncmp(input, L"\\\\.\\", 4) == 0 ||
      (wcsncmp(input, L"\\\\?\\", 4) == 0 &&
       wcsncmp(input, L"\\\\?\\UNC\\", 8) != 0 &&
       !(wcslen(input) >= 7 && input[4] != L'\0' && input[5] == L':' &&
         input[6] == L'\\'))) {
    free(input);
    SetLastError(ERROR_INVALID_NAME);
    win_set_errno(ERROR_INVALID_NAME);
    return NULL;
  }
  needed = GetFullPathNameW(input, 0, NULL, NULL);
  if (needed == 0 || needed > 32768) {
    DWORD error = needed == 0 ? GetLastError() : ERROR_FILENAME_EXCED_RANGE;
    free(input);
    SetLastError(error);
    win_set_errno(error);
    return NULL;
  }
  full = cast(WCHAR *, malloc(cast_sizet(needed + 8) * sizeof(WCHAR)));
  if (full == NULL) {
    free(input);
    SetLastError(ERROR_OUTOFMEMORY);
    errno = ENOMEM;
    return NULL;
  }
  if (GetFullPathNameW(input, needed, full, NULL) == 0) {
    DWORD error = GetLastError();
    free(input);
    free(full);
    SetLastError(error);
    win_set_errno(error);
    return NULL;
  }
  free(input);
  return full;
}

static WCHAR *win_extended_path(WCHAR *full) {
  size_t length = wcslen(full);
  WCHAR *extended;
  if (wcsncmp(full, L"\\\\?\\", 4) == 0)
    return full;
  if (wcsncmp(full, L"\\\\", 2) == 0) {
    extended = cast(WCHAR *, malloc((length + 7) * sizeof(WCHAR)));
    if (extended == NULL)
      return NULL;
    wcscpy(extended, L"\\\\?\\UNC\\");
    wcscpy(extended + 8, full + 2);
  }
  else {
    extended = cast(WCHAR *, malloc((length + 5) * sizeof(WCHAR)));
    if (extended == NULL)
      return NULL;
    wcscpy(extended, L"\\\\?\\");
    wcscpy(extended + 4, full);
  }
  free(full);
  return extended;
}

static WCHAR *win_path(const char *path) {
  WCHAR *full = win_utf8_to_fullpath(path);
  WCHAR *extended;
  if (full == NULL)
    return NULL;
  extended = win_extended_path(full);
  if (extended == NULL) {
    free(full);
    SetLastError(ERROR_OUTOFMEMORY);
    errno = ENOMEM;
  }
  return extended;
}

static char *win_wide_to_utf8(const WCHAR *path, int length) {
  char *utf8;
  int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, length,
                                   NULL, 0, NULL, NULL);
  if (needed <= 0)
    return NULL;
  utf8 = cast(char *, malloc(cast_sizet(needed) + 1));
  if (utf8 == NULL) {
    SetLastError(ERROR_OUTOFMEMORY);
    return NULL;
  }
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, length, utf8,
                          needed, NULL, NULL) == 0) {
    free(utf8);
    return NULL;
  }
  utf8[needed] = '\0';
  return utf8;
}

char *luaAP_winhandlepath(HANDLE handle) {
  WCHAR *wide;
  char *utf8;
  DWORD needed = GetFinalPathNameByHandleW(
      handle, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (needed == 0 || needed > 32768) {
    if (needed > 32768)
      SetLastError(ERROR_FILENAME_EXCED_RANGE);
    return NULL;
  }
  wide = cast(WCHAR *, malloc(cast_sizet(needed + 1) * sizeof(WCHAR)));
  if (wide == NULL) {
    SetLastError(ERROR_OUTOFMEMORY);
    return NULL;
  }
  if (GetFinalPathNameByHandleW(handle, wide, needed + 1,
                                FILE_NAME_NORMALIZED | VOLUME_NAME_DOS) == 0) {
    free(wide);
    return NULL;
  }
  utf8 = win_wide_to_utf8(wide, -1);
  free(wide);
  return utf8;
}

static int win_same_object(HANDLE left, HANDLE right) {
  BY_HANDLE_FILE_INFORMATION a;
  BY_HANDLE_FILE_INFORMATION b;
  return GetFileInformationByHandle(left, &a) &&
         GetFileInformationByHandle(right, &b) &&
         a.dwVolumeSerialNumber == b.dwVolumeSerialNumber &&
         a.nFileIndexHigh == b.nFileIndexHigh &&
         a.nFileIndexLow == b.nFileIndexLow;
}

void luaAP_winclosechain(LusAuthChain *chain) {
  if (chain == NULL)
    return;
  for (size_t i = 0; i < chain->count; i++)
    CloseHandle(chain->handles[i]);
  free(chain->handles);
  chain->handles = NULL;
  chain->count = 0;
}

static size_t win_wide_root(const WCHAR *path) {
  const WCHAR *p;
  size_t length = wcslen(path);
  if (length >= 7 && wcsncmp(path, L"\\\\?\\", 4) == 0 && path[5] == L':' &&
      path[6] == L'\\')
    return 7;
  if (length >= 8 && wcsncmp(path, L"\\\\?\\UNC\\", 8) == 0)
    p = path + 8;
  else if (length >= 2 && path[0] == L'\\' && path[1] == L'\\')
    p = path + 2;
  else
    return 0;
  while (*p != L'\0' && *p != L'\\')
    p++;
  if (*p != L'\0')
    p++;
  while (*p != L'\0' && *p != L'\\')
    p++;
  return *p == L'\0' ? cast_sizet(p - path) : cast_sizet(p - path + 1);
}

int luaAP_winlockchain(HANDLE target, LusAuthChain *chain) {
  char *canonical = NULL;
  WCHAR *wide = NULL;
  HANDLE verify = INVALID_HANDLE_VALUE;
  BY_HANDLE_FILE_INFORMATION target_info;
  size_t root;
  size_t length;
  size_t capacity;
  int result = 0;
  DWORD error = ERROR_SUCCESS;
  if (chain == NULL || target == NULL || target == INVALID_HANDLE_VALUE) {
    SetLastError(ERROR_INVALID_HANDLE);
    win_set_errno(ERROR_INVALID_HANDLE);
    return 0;
  }
  memset(chain, 0, sizeof(*chain));
  canonical = luaAP_winhandlepath(target);
  if (canonical == NULL)
    goto done;
  wide = win_utf8_raw(canonical);
  if (wide == NULL)
    goto done;
  root = win_wide_root(wide);
  length = wcslen(wide);
  if (root == 0 || root >= length) {
    SetLastError(ERROR_INVALID_NAME);
    goto done;
  }
  capacity = length - root + 1;
  chain->handles = cast(HANDLE *, calloc(capacity, sizeof(HANDLE)));
  if (chain->handles == NULL) {
    SetLastError(ERROR_OUTOFMEMORY);
    goto done;
  }
  {
    WCHAR saved = wide[root];
    wide[root] = L'\0';
    chain->handles[chain->count] =
        CreateFileW(wide, FILE_READ_ATTRIBUTES | FILE_TRAVERSE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                    FILE_FLAG_BACKUP_SEMANTICS, NULL);
    wide[root] = saved;
    if (chain->handles[chain->count] == INVALID_HANDLE_VALUE)
      goto done;
    chain->count++;
  }
  for (size_t i = root; i < length; i++) {
    if (wide[i] == L'\\' && i + 1 < length) {
      WCHAR saved = wide[i];
      wide[i] = L'\0';
      chain->handles[chain->count] =
          CreateFileW(wide, FILE_READ_ATTRIBUTES | FILE_TRAVERSE,
                      FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                      FILE_FLAG_BACKUP_SEMANTICS, NULL);
      wide[i] = saved;
      if (chain->handles[chain->count] == INVALID_HANDLE_VALUE)
        goto done;
      chain->count++;
    }
  }
  if (!GetFileInformationByHandle(target, &target_info))
    goto done;
  verify = CreateFileW(
      wide, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS |
          ((target_info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0
               ? FILE_FLAG_OPEN_REPARSE_POINT
               : 0),
      NULL);
  if (verify == INVALID_HANDLE_VALUE || !win_same_object(target, verify)) {
    SetLastError(ERROR_RETRY);
    goto done;
  }
  result = 1;
done:
  if (!result) {
    error = GetLastError();
    if (error == ERROR_SUCCESS)
      error = ERROR_INVALID_DATA;
  }
  if (verify != INVALID_HANDLE_VALUE)
    CloseHandle(verify);
  free(wide);
  free(canonical);
  if (!result) {
    luaAP_winclosechain(chain);
    SetLastError(error);
    win_set_errno(error);
  }
  return result;
}

static int win_split(WCHAR *full, WCHAR **parent, WCHAR **leaf) {
  WCHAR *slash = wcsrchr(full, L'\\');
  WCHAR *alt = wcsrchr(full, L'/');
  if (alt != NULL && (slash == NULL || alt > slash))
    slash = alt;
  if (slash == NULL || slash[1] == L'\0' || wcscmp(slash + 1, L".") == 0 ||
      wcscmp(slash + 1, L"..") == 0) {
    SetLastError(ERROR_INVALID_NAME);
    win_set_errno(ERROR_INVALID_NAME);
    return 0;
  }
  {
    size_t leaf_len = wcslen(slash + 1);
    *leaf = cast(WCHAR *, malloc((leaf_len + 1) * sizeof(WCHAR)));
    if (*leaf != NULL)
      memcpy(*leaf, slash + 1, (leaf_len + 1) * sizeof(WCHAR));
  }
  if (*leaf == NULL) {
    SetLastError(ERROR_OUTOFMEMORY);
    errno = ENOMEM;
    return 0;
  }
  if (slash == full + 6 && full[4] != L'\\')
    slash[1] = L'\0';
  else
    *slash = L'\0';
  *parent = full;
  return 1;
}

static char *win_candidate(HANDLE parent, const WCHAR *leaf) {
  char *base = luaAP_winhandlepath(parent);
  char *name = win_wide_to_utf8(leaf, -1);
  char *candidate;
  size_t base_len;
  size_t name_len;
  int separator;
  if (base == NULL || name == NULL) {
    free(base);
    free(name);
    return NULL;
  }
  base_len = strlen(base);
  name_len = strlen(name);
  separator = base_len == 0 || base[base_len - 1] != '\\';
  if (base_len > SIZE_MAX - name_len - cast_sizet(separator) - 1) {
    free(base);
    free(name);
    SetLastError(ERROR_FILENAME_EXCED_RANGE);
    return NULL;
  }
  candidate =
      cast(char *, malloc(base_len + name_len + cast_sizet(separator) + 1));
  if (candidate != NULL) {
    memcpy(candidate, base, base_len);
    if (separator)
      candidate[base_len++] = '\\';
    memcpy(candidate + base_len, name, name_len + 1);
  }
  else
    SetLastError(ERROR_OUTOFMEMORY);
  free(base);
  free(name);
  return candidate;
}

static l_noret win_deny(lua_State *L, const char *perm, const char *display) {
  luaL_error(L, "permission \"%s\" denied for '%s'", perm, display);
  abort();
}

static int win_authorize(lua_State *L, HANDLE handle, int need_read,
                         int need_write, const char **denied) {
  char *canonical = luaAP_winhandlepath(handle);
  int allowed = canonical != NULL;
  if (allowed && need_read && !luaP_hasfscanonical(L, "fs:read", canonical)) {
    *denied = "fs:read";
    allowed = 0;
  }
  if (allowed && need_write && !luaP_hasfscanonical(L, "fs:write", canonical)) {
    *denied = "fs:write";
    allowed = 0;
  }
  free(canonical);
  return allowed;
}

static int win_parent_raw(const char *path, LusAuthParent *result) {
  WCHAR *full = win_path(path);
  WCHAR *parent;
  memset(result, 0, sizeof(*result));
  result->handle = INVALID_HANDLE_VALUE;
  if (full == NULL || !win_split(full, &parent, &result->leaf)) {
    free(full);
    return 0;
  }
  result->handle = CreateFileW(
      parent, FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS, NULL);
  free(full);
  if (result->handle == INVALID_HANDLE_VALUE) {
    win_set_errno(GetLastError());
    free(result->leaf);
    result->leaf = NULL;
    return 0;
  }
  result->canonical = win_candidate(result->handle, result->leaf);
  if (result->canonical == NULL) {
    DWORD error = GetLastError();
    luaAP_closeparent(result);
    SetLastError(error);
    win_set_errno(error);
    return 0;
  }
  return 1;
}

int luaAP_parent(lua_State *L, const char *path, const char *perm,
                 LusAuthParent *result) {
  if (!win_parent_raw(path, result))
    return 0;
  if (perm != NULL && !luaP_hasfscanonical(L, perm, result->canonical)) {
    luaAP_closeparent(result);
    win_deny(L, perm, path);
  }
  return 1;
}

void luaAP_closeparent(LusAuthParent *parent) {
  if (parent->handle != NULL && parent->handle != INVALID_HANDLE_VALUE)
    CloseHandle(parent->handle);
  free(parent->leaf);
  free(parent->canonical);
  parent->handle = INVALID_HANDLE_VALUE;
  parent->leaf = NULL;
  parent->canonical = NULL;
}

static HANDLE win_open_relative(LusAuthParent *parent, DWORD desired_access,
                                int directory, ULONG disposition,
                                ULONG extra_options) {
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  LusNtCreateFile nt_create =
      ntdll == NULL
          ? NULL
          : cast(LusNtCreateFile, GetProcAddress(ntdll, "NtCreateFile"));
  LusRtlNtStatusToDosError to_error =
      ntdll == NULL ? NULL
                    : cast(LusRtlNtStatusToDosError,
                           GetProcAddress(ntdll, "RtlNtStatusToDosError"));
  LusUnicodeString name;
  LusObjectAttributes attributes;
  LusIoStatusBlock status_block;
  LusNtStatus status;
  HANDLE handle = INVALID_HANDLE_VALUE;
  size_t leaf_len;
  if (nt_create == NULL || to_error == NULL) {
    SetLastError(ERROR_PROC_NOT_FOUND);
    win_set_errno(ERROR_PROC_NOT_FOUND);
    return INVALID_HANDLE_VALUE;
  }
  leaf_len = wcslen(parent->leaf);
  if (leaf_len == 0 || leaf_len > USHRT_MAX / sizeof(WCHAR)) {
    SetLastError(ERROR_INVALID_NAME);
    win_set_errno(ERROR_INVALID_NAME);
    return INVALID_HANDLE_VALUE;
  }
  name.Length = cast(USHORT, leaf_len * sizeof(WCHAR));
  name.MaximumLength = name.Length;
  name.Buffer = parent->leaf;
  attributes.Length = sizeof(attributes);
  attributes.RootDirectory = parent->handle;
  attributes.ObjectName = &name;
  attributes.Attributes = OBJ_CASE_INSENSITIVE;
  attributes.SecurityDescriptor = NULL;
  attributes.SecurityQualityOfService = NULL;
  memset(&status_block, 0, sizeof(status_block));
  status = nt_create(
      &handle, desired_access | FILE_READ_ATTRIBUTES | SYNCHRONIZE, &attributes,
      &status_block, NULL, FILE_ATTRIBUTE_NORMAL,
      FILE_SHARE_READ | FILE_SHARE_WRITE, disposition,
      LUS_FILE_SYNCHRONOUS_IO_NONALERT |
          (directory ? LUS_FILE_DIRECTORY_FILE : LUS_FILE_NON_DIRECTORY_FILE) |
          extra_options,
      NULL, 0);
  if (status < 0) {
    DWORD error = to_error(status);
    SetLastError(error);
    win_set_errno(error);
    return INVALID_HANDLE_VALUE;
  }
  return handle;
}

static HANDLE win_create_relative(LusAuthParent *parent, DWORD desired_access,
                                  int directory) {
  return win_open_relative(parent, desired_access, directory, LUS_FILE_CREATE,
                           0);
}

static int win_truncate(HANDLE handle) {
  LARGE_INTEGER zero;
  zero.QuadPart = 0;
  if (!SetFilePointerEx(handle, zero, NULL, FILE_BEGIN) ||
      !SetEndOfFile(handle)) {
    win_set_errno(GetLastError());
    return 0;
  }
  return 1;
}

HANDLE luaAP_winopen(lua_State *L, const char *path, DWORD desired_access,
                     DWORD disposition, DWORD flags, int need_read,
                     int need_write) {
  WCHAR *wide = NULL;
  HANDLE handle = INVALID_HANDLE_VALUE;
  const char *denied = NULL;
  int create = disposition == CREATE_NEW || disposition == CREATE_ALWAYS ||
               disposition == OPEN_ALWAYS;
  int truncate =
      disposition == CREATE_ALWAYS || disposition == TRUNCATE_EXISTING;
  if (disposition != CREATE_NEW) {
    wide = win_path(path);
    if (wide == NULL)
      return INVALID_HANDLE_VALUE;
    handle =
        CreateFileW(wide, desired_access | FILE_READ_ATTRIBUTES,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                    flags | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    free(wide);
    if (handle != INVALID_HANDLE_VALUE) {
      if (!win_authorize(L, handle, need_read, need_write, &denied)) {
        DWORD error = GetLastError();
        CloseHandle(handle);
        if (denied != NULL)
          win_deny(L, denied, path);
        SetLastError(error);
        win_set_errno(error);
        return INVALID_HANDLE_VALUE;
      }
      if (truncate && !win_truncate(handle)) {
        DWORD error = GetLastError();
        CloseHandle(handle);
        SetLastError(error);
        return INVALID_HANDLE_VALUE;
      }
      return handle;
    }
    if (!create && (GetLastError() == ERROR_FILE_NOT_FOUND ||
                    GetLastError() == ERROR_PATH_NOT_FOUND)) {
      LusAuthParent parent;
      const char *missing_perm = need_read ? "fs:read" : "fs:write";
      if (luaAP_parent(L, path, missing_perm, &parent))
        luaAP_closeparent(&parent);
      SetLastError(ERROR_FILE_NOT_FOUND);
      errno = ENOENT;
      return INVALID_HANDLE_VALUE;
    }
    if (!create || (GetLastError() != ERROR_FILE_NOT_FOUND &&
                    GetLastError() != ERROR_PATH_NOT_FOUND)) {
      win_set_errno(GetLastError());
      return INVALID_HANDLE_VALUE;
    }
  }
  {
    LusAuthParent parent;
    const char *creation_perm = need_write ? "fs:write" : "fs:read";
    if (!luaAP_parent(L, path, creation_perm, &parent))
      return INVALID_HANDLE_VALUE;
    if (need_read && !luaP_hasfscanonical(L, "fs:read", parent.canonical)) {
      luaAP_closeparent(&parent);
      win_deny(L, "fs:read", path);
    }
    handle = win_create_relative(&parent, desired_access, 0);
    if (handle == INVALID_HANDLE_VALUE) {
      DWORD error = GetLastError();
      luaAP_closeparent(&parent);
      SetLastError(error);
      return INVALID_HANDLE_VALUE;
    }
    if (!win_authorize(L, handle, need_read, need_write, &denied)) {
      FILE_DISPOSITION_INFO remove = {TRUE};
      DWORD error = GetLastError();
      SetFileInformationByHandle(handle, FileDispositionInfo, &remove,
                                 sizeof(remove));
      CloseHandle(handle);
      luaAP_closeparent(&parent);
      if (denied != NULL)
        win_deny(L, denied, path);
      SetLastError(error);
      win_set_errno(error);
      return INVALID_HANDLE_VALUE;
    }
    luaAP_closeparent(&parent);
  }
  return handle;
}

static void win_authfile_init(LusAuthFile *file) {
  memset(file, 0, sizeof(*file));
  file->handle = INVALID_HANDLE_VALUE;
  file->parent.handle = INVALID_HANDLE_VALUE;
}

static int win_authfile_authorize(lua_State *L, LusAuthFile *file,
                                  int need_read, int need_write) {
  const char *denied = NULL;
  BY_HANDLE_FILE_INFORMATION info;
  if (!win_authorize(L, file->handle, need_read, need_write, &denied)) {
    file->denied_perm = denied;
    return denied != NULL ? LUS_AUTH_DENIED : LUS_AUTH_ERROR;
  }
  file->canonical = luaAP_winhandlepath(file->handle);
  if (file->canonical == NULL ||
      !GetFileInformationByHandle(file->handle, &info))
    return LUS_AUTH_ERROR;
  if ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    SetLastError(ERROR_DIRECTORY);
    errno = EISDIR;
    return LUS_AUTH_ERROR;
  }
  file->object_mode = cast_uint(info.dwFileAttributes);
  file->object_size =
      cast(long long, (cast(unsigned long long, info.nFileSizeHigh) << 32) |
                          cast(unsigned long long, info.nFileSizeLow));
  if (!luaAP_winlockchain(file->handle, &file->chain))
    return LUS_AUTH_ERROR;
  if (!file->has_parent) {
    if (!win_parent_raw(file->canonical, &file->parent))
      return LUS_AUTH_ERROR;
    file->has_parent = 1;
  }
  return LUS_AUTH_OK;
}

int luaAP_tryopen(lua_State *L, const char *path, int options,
                  unsigned int mode, LusAuthFile *file) {
  int need_read = (options & LUS_AUTH_READ) != 0;
  int need_write =
      (options & (LUS_AUTH_WRITE | LUS_AUTH_CREATE | LUS_AUTH_DELETE |
                  LUS_AUTH_DELETE_ON_CLOSE)) != 0;
  int content_write = (options & LUS_AUTH_WRITE) != 0;
  int create = (options & LUS_AUTH_CREATE) != 0;
  int exclusive = (options & LUS_AUTH_EXCLUSIVE) != 0;
  DWORD access = FILE_READ_ATTRIBUTES | SYNCHRONIZE;
  DWORD attributes = FILE_ATTRIBUTE_NORMAL;
  int tries;
  UNUSED(mode);
  if (need_read)
    access |= GENERIC_READ;
  if (content_write)
    access |= GENERIC_WRITE;
  if ((options & (LUS_AUTH_DELETE | LUS_AUTH_DELETE_ON_CLOSE)) != 0)
    access |= DELETE;
  win_authfile_init(file);
  for (tries = 0; tries < 3; tries++) {
    int status;
    if (!exclusive) {
      WCHAR *wide = win_path(path);
      if (wide == NULL)
        return LUS_AUTH_ERROR;
      file->handle = CreateFileW(
          wide, access, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
          attributes | FILE_FLAG_BACKUP_SEMANTICS, NULL);
      free(wide);
      if (file->handle != INVALID_HANDLE_VALUE) {
        status = win_authfile_authorize(L, file, need_read, need_write);
        if (status == LUS_AUTH_OK &&
            (options & LUS_AUTH_DELETE_ON_CLOSE) != 0) {
          FILE_DISPOSITION_INFO disposition = {TRUE};
          if (!SetFileInformationByHandle(file->handle, FileDispositionInfo,
                                          &disposition, sizeof(disposition))) {
            DWORD error = GetLastError();
            luaAP_closeauthfile(file);
            SetLastError(error);
            win_set_errno(error);
            return LUS_AUTH_ERROR;
          }
        }
        if (status == LUS_AUTH_OK)
          return status;
        luaAP_closeauthfile(file);
        return status;
      }
      if (GetLastError() != ERROR_FILE_NOT_FOUND &&
          GetLastError() != ERROR_PATH_NOT_FOUND) {
        win_set_errno(GetLastError());
        return LUS_AUTH_ERROR;
      }
    }
    if (!create) {
      if (!win_parent_raw(path, &file->parent))
        return LUS_AUTH_ERROR;
      file->has_parent = 1;
      if (need_read &&
          !luaP_hasfscanonical(L, "fs:read", file->parent.canonical)) {
        file->denied_perm = "fs:read";
        return LUS_AUTH_DENIED;
      }
      if (need_write &&
          !luaP_hasfscanonical(L, "fs:write", file->parent.canonical)) {
        file->denied_perm = "fs:write";
        return LUS_AUTH_DENIED;
      }
      return LUS_AUTH_MISSING;
    }
    if (!win_parent_raw(path, &file->parent))
      return LUS_AUTH_ERROR;
    file->has_parent = 1;
    if (need_read &&
        !luaP_hasfscanonical(L, "fs:read", file->parent.canonical)) {
      file->denied_perm = "fs:read";
      return LUS_AUTH_DENIED;
    }
    if (need_write &&
        !luaP_hasfscanonical(L, "fs:write", file->parent.canonical)) {
      file->denied_perm = "fs:write";
      return LUS_AUTH_DENIED;
    }
    file->handle = win_create_relative(&file->parent, access, 0);
    if (file->handle != INVALID_HANDLE_VALUE) {
      file->created = 1;
      status = win_authfile_authorize(L, file, need_read, need_write);
      if (status == LUS_AUTH_OK && (options & LUS_AUTH_DELETE_ON_CLOSE) != 0) {
        FILE_DISPOSITION_INFO disposition = {TRUE};
        if (!SetFileInformationByHandle(file->handle, FileDispositionInfo,
                                        &disposition, sizeof(disposition))) {
          DWORD error = GetLastError();
          luaAP_deleteauthfile(file);
          luaAP_closeauthfile(file);
          SetLastError(error);
          win_set_errno(error);
          return LUS_AUTH_ERROR;
        }
      }
      if (status == LUS_AUTH_OK)
        return status;
      luaAP_deleteauthfile(file);
      luaAP_closeauthfile(file);
      return status;
    }
    {
      DWORD error = GetLastError();
      luaAP_closeauthfile(file);
      if ((error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS) &&
          !exclusive)
        continue;
      SetLastError(error);
      win_set_errno(error);
      return error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS
                 ? LUS_AUTH_EXISTS
                 : LUS_AUTH_ERROR;
    }
  }
  SetLastError(ERROR_RETRY);
  errno = EAGAIN;
  return LUS_AUTH_ERROR;
}

static int win_sibling_parent(const LusAuthFile *anchor, const char *suffix,
                              const char *authorized_path, LusAuthFile *file) {
  WCHAR *wide_suffix = NULL;
  WCHAR *leaf = NULL;
  char *canonical = NULL;
  HANDLE parent = INVALID_HANDLE_VALUE;
  int suffix_length;
  size_t base_length;
  size_t path_length;
  if (anchor == NULL || !anchor->has_parent || anchor->parent.handle == NULL ||
      anchor->parent.handle == INVALID_HANDLE_VALUE ||
      anchor->parent.leaf == NULL || suffix == NULL ||
      (suffix[0] != '\0' && (suffix[0] != '-' || suffix[1] == '\0' ||
                             strpbrk(suffix, "/\\") != NULL)) ||
      authorized_path == NULL) {
    SetLastError(ERROR_INVALID_PARAMETER);
    errno = EINVAL;
    return 0;
  }
  suffix_length =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, suffix, -1, NULL, 0);
  if (suffix_length <= 0) {
    win_set_errno(GetLastError());
    return 0;
  }
  base_length = wcslen(anchor->parent.leaf);
  if (base_length > SIZE_MAX - cast_sizet(suffix_length)) {
    SetLastError(ERROR_FILENAME_EXCED_RANGE);
    errno = ENAMETOOLONG;
    return 0;
  }
  wide_suffix =
      cast(WCHAR *, malloc(cast_sizet(suffix_length) * sizeof(WCHAR)));
  leaf = cast(WCHAR *, malloc((base_length + cast_sizet(suffix_length)) *
                              sizeof(WCHAR)));
  path_length = strlen(authorized_path);
  canonical = cast(char *, malloc(path_length + 1));
  if (wide_suffix == NULL || leaf == NULL || canonical == NULL) {
    SetLastError(ERROR_OUTOFMEMORY);
    errno = ENOMEM;
    goto fail;
  }
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, suffix, -1,
                          wide_suffix, suffix_length) == 0)
    goto fail;
  memcpy(leaf, anchor->parent.leaf, base_length * sizeof(WCHAR));
  memcpy(leaf + base_length, wide_suffix,
         cast_sizet(suffix_length) * sizeof(WCHAR));
  memcpy(canonical, authorized_path, path_length + 1);
  if (!DuplicateHandle(GetCurrentProcess(), anchor->parent.handle,
                       GetCurrentProcess(), &parent, 0, FALSE,
                       DUPLICATE_SAME_ACCESS))
    goto fail;
  file->parent.handle = parent;
  file->parent.leaf = leaf;
  file->parent.canonical = canonical;
  file->has_parent = 1;
  free(wide_suffix);
  return 1;

fail: {
  DWORD error = GetLastError();
  if (parent != INVALID_HANDLE_VALUE)
    CloseHandle(parent);
  free(canonical);
  free(leaf);
  free(wide_suffix);
  SetLastError(error);
  win_set_errno(error);
  return 0;
}
}

static int win_sibling_object(const LusAuthFile *anchor, int anchor_object,
                              LusAuthFile *file, const char *authorized_path) {
  BY_HANDLE_FILE_INFORMATION info;
  size_t length = strlen(authorized_path);
  if (!GetFileInformationByHandle(file->handle, &info))
    return 0;
  if (anchor_object && !win_same_object(anchor->handle, file->handle)) {
    SetLastError(ERROR_RETRY);
    errno = EAGAIN;
    return 0;
  }
  if ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    SetLastError(ERROR_DIRECTORY);
    errno = EISDIR;
    return 0;
  }
  if ((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    SetLastError(ERROR_ACCESS_DENIED);
    errno = EACCES;
    return 0;
  }
  file->canonical = cast(char *, malloc(length + 1));
  if (file->canonical == NULL) {
    SetLastError(ERROR_OUTOFMEMORY);
    errno = ENOMEM;
    return 0;
  }
  memcpy(file->canonical, authorized_path, length + 1);
  file->object_mode = cast_uint(info.dwFileAttributes);
  file->object_size =
      cast(long long, (cast(unsigned long long, info.nFileSizeHigh) << 32) |
                          cast(unsigned long long, info.nFileSizeLow));
  return 1;
}

static int win_sibling_delete_on_close(LusAuthFile *file, int options) {
  if ((options & LUS_AUTH_DELETE_ON_CLOSE) != 0) {
    FILE_DISPOSITION_INFO disposition = {TRUE};
    if (!SetFileInformationByHandle(file->handle, FileDispositionInfo,
                                    &disposition, sizeof(disposition))) {
      win_set_errno(GetLastError());
      return 0;
    }
  }
  return 1;
}

int luaAP_tryopensibling(lua_State *L, const LusAuthFile *anchor,
                         const char *suffix, const char *authorized_path,
                         int options, unsigned int mode, LusAuthFile *file) {
  int need_read = (options & LUS_AUTH_READ) != 0;
  int need_write =
      (options & (LUS_AUTH_WRITE | LUS_AUTH_CREATE | LUS_AUTH_DELETE |
                  LUS_AUTH_DELETE_ON_CLOSE)) != 0;
  int content_write = (options & LUS_AUTH_WRITE) != 0;
  int create = (options & LUS_AUTH_CREATE) != 0;
  int exclusive = (options & LUS_AUTH_EXCLUSIVE) != 0;
  DWORD access = FILE_READ_ATTRIBUTES | SYNCHRONIZE;
  int anchor_object = suffix != NULL && suffix[0] == '\0';
  int tries;
  UNUSED(mode);
  win_authfile_init(file);
  if (!win_sibling_parent(anchor, suffix, authorized_path, file))
    return LUS_AUTH_ERROR;
  if (need_read && !luaP_hasfscanonical(L, "fs:read", authorized_path)) {
    file->denied_perm = "fs:read";
    return LUS_AUTH_DENIED;
  }
  if (need_write && !luaP_hasfscanonical(L, "fs:write", authorized_path)) {
    file->denied_perm = "fs:write";
    return LUS_AUTH_DENIED;
  }
  if (need_read)
    access |= GENERIC_READ;
  if (content_write)
    access |= GENERIC_WRITE;
  if ((options & (LUS_AUTH_DELETE | LUS_AUTH_DELETE_ON_CLOSE)) != 0)
    access |= DELETE;
  for (tries = 0; tries < 3; tries++) {
    if (!exclusive) {
      file->handle = win_open_relative(&file->parent, access, 0, LUS_FILE_OPEN,
                                       LUS_FILE_OPEN_REPARSE_POINT);
      if (file->handle != INVALID_HANDLE_VALUE) {
        if (!win_sibling_object(anchor, anchor_object, file, authorized_path) ||
            !win_sibling_delete_on_close(file, options)) {
          DWORD error = GetLastError();
          luaAP_closeauthfile(file);
          SetLastError(error);
          win_set_errno(error);
          return LUS_AUTH_ERROR;
        }
        return LUS_AUTH_OK;
      }
      if (GetLastError() != ERROR_FILE_NOT_FOUND &&
          GetLastError() != ERROR_PATH_NOT_FOUND) {
        win_set_errno(GetLastError());
        return LUS_AUTH_ERROR;
      }
    }
    if (!create)
      return LUS_AUTH_MISSING;
    file->handle = win_create_relative(&file->parent, access, 0);
    if (file->handle != INVALID_HANDLE_VALUE) {
      file->created = 1;
      if (win_sibling_object(anchor, anchor_object, file, authorized_path) &&
          win_sibling_delete_on_close(file, options))
        return LUS_AUTH_OK;
      {
        DWORD error = GetLastError();
        luaAP_deleteauthfile(file);
        luaAP_closeauthfile(file);
        SetLastError(error);
        win_set_errno(error);
        return LUS_AUTH_ERROR;
      }
    }
    {
      DWORD error = GetLastError();
      if ((error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS) &&
          !exclusive)
        continue;
      win_set_errno(error);
      return error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS
                 ? LUS_AUTH_EXISTS
                 : LUS_AUTH_ERROR;
    }
  }
  SetLastError(ERROR_RETRY);
  errno = EAGAIN;
  return LUS_AUTH_ERROR;
}

void luaAP_moveauthfile(LusAuthFile *destination, LusAuthFile *source) {
  if (destination == NULL || source == NULL || destination == source)
    return;
  *destination = *source;
  win_authfile_init(source);
}

int luaAP_deleteauthfile(LusAuthFile *file) {
  FILE_DISPOSITION_INFO disposition = {TRUE};
  if (file == NULL || file->handle == INVALID_HANDLE_VALUE) {
    SetLastError(ERROR_INVALID_HANDLE);
    errno = EBADF;
    return 0;
  }
  if (!SetFileInformationByHandle(file->handle, FileDispositionInfo,
                                  &disposition, sizeof(disposition))) {
    win_set_errno(GetLastError());
    return 0;
  }
  return 1;
}

int luaAP_syncauthparent(LusAuthFile *file) {
  UNUSED(file);
  return 1;
}

void luaAP_closeauthfile(LusAuthFile *file) {
  DWORD error = GetLastError();
  int saved_errno = errno;
  if (file == NULL)
    return;
  if (file->handle != NULL && file->handle != INVALID_HANDLE_VALUE)
    CloseHandle(file->handle);
  if (file->has_parent)
    luaAP_closeparent(&file->parent);
  luaAP_winclosechain(&file->chain);
  free(file->canonical);
  file->handle = INVALID_HANDLE_VALUE;
  file->has_parent = 0;
  file->canonical = NULL;
  SetLastError(error);
  errno = saved_errno;
}

const char *luaAP_authfilepath(const LusAuthFile *file) {
  return file != NULL ? file->canonical : NULL;
}

static void win_mode(const char *mode, DWORD *access, DWORD *disposition,
                     int *oflags, int *need_read, int *need_write) {
  int plus = strchr(mode, '+') != NULL;
  int binary = strchr(mode, 'b') != NULL;
  int exclusive = strchr(mode, 'x') != NULL;
  *need_read = *mode == 'r' || plus;
  *need_write = *mode != 'r' || plus;
  *access = (*need_read ? GENERIC_READ : 0) | (*need_write ? GENERIC_WRITE : 0);
  if (*mode == 'r')
    *disposition = OPEN_EXISTING;
  else if (exclusive)
    *disposition = CREATE_NEW;
  else if (*mode == 'w')
    *disposition = CREATE_ALWAYS;
  else
    *disposition = OPEN_ALWAYS;
  *oflags = (binary ? _O_BINARY : _O_TEXT) |
            (plus ? _O_RDWR : (*need_read ? _O_RDONLY : _O_WRONLY));
  if (*mode == 'a')
    *oflags |= _O_APPEND;
}

FILE *luaAP_fopen(lua_State *L, const char *path, const char *mode) {
  DWORD access;
  DWORD disposition;
  int oflags;
  int need_read;
  int need_write;
  HANDLE handle;
  int fd;
  FILE *file;
  win_mode(mode, &access, &disposition, &oflags, &need_read, &need_write);
  handle = luaAP_winopen(L, path, access, disposition, FILE_ATTRIBUTE_NORMAL,
                         need_read, need_write);
  if (handle == INVALID_HANDLE_VALUE)
    return NULL;
  fd = _open_osfhandle(cast(intptr_t, handle), oflags);
  if (fd < 0) {
    CloseHandle(handle);
    return NULL;
  }
  file = _fdopen(fd, mode);
  if (file == NULL)
    _close(fd);
  return file;
}

int luaAP_winopenfd(lua_State *L, const char *path, int need_read,
                    int need_write) {
  DWORD access =
      (need_read ? GENERIC_READ : 0) | (need_write ? GENERIC_WRITE : 0);
  int oflags =
      _O_BINARY |
      (need_read && need_write ? _O_RDWR : (need_read ? _O_RDONLY : _O_WRONLY));
  HANDLE handle = luaAP_winopen(L, path, access, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL, need_read, need_write);
  int fd;
  if (handle == INVALID_HANDLE_VALUE)
    return -1;
  fd = _open_osfhandle(cast(intptr_t, handle), oflags);
  if (fd < 0)
    CloseHandle(handle);
  return fd;
}

int luaAP_winopenrawfd(const char *path) {
  WCHAR *wide = win_path(path);
  HANDLE handle;
  int fd;
  if (wide == NULL)
    return -1;
  handle = CreateFileW(wide, GENERIC_READ | FILE_READ_ATTRIBUTES,
                       FILE_SHARE_READ, NULL, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
  free(wide);
  if (handle == INVALID_HANDLE_VALUE) {
    win_set_errno(GetLastError());
    return -1;
  }
  fd = _open_osfhandle(cast(intptr_t, handle), _O_RDONLY | _O_BINARY);
  if (fd < 0)
    CloseHandle(handle);
  return fd;
}

typedef struct WinLoadF {
  unsigned int n;
  FILE *f;
  char buff[BUFSIZ];
} WinLoadF;

static const char *win_getF(lua_State *L, void *ud, size_t *size) {
  WinLoadF *lf = cast(WinLoadF *, ud);
  UNUSED(L);
  if (lf->n > 0) {
    *size = lf->n;
    lf->n = 0;
  }
  else {
    if (feof(lf->f))
      return NULL;
    *size = fread(lf->buff, 1, sizeof(lf->buff), lf->f);
  }
  return lf->buff;
}

static int win_skipBOM(FILE *f) {
  int c = getc(f);
  if (c == 0xEF && getc(f) == 0xBB && getc(f) == 0xBF)
    return getc(f);
  return c;
}

static int win_skipcomment(FILE *f, int *cp) {
  int c = *cp = win_skipBOM(f);
  if (c == '#') {
    do {
      c = getc(f);
    } while (c != EOF && c != '\n');
    *cp = getc(f);
    return 1;
  }
  return 0;
}

int luaAP_loadfd(lua_State *L, int fd, const char *filename, const char *mode) {
  WinLoadF lf;
  int status;
  int readstatus;
  int c;
  int fnameindex = lua_gettop(L) + 1;
  int owned = _dup(fd);
  if (owned < 0) {
    lua_pushfstring(L, "cannot open %s: %s", filename, strerror(errno));
    return LUA_ERRFILE;
  }
  if (_lseeki64(owned, 0, SEEK_SET) < 0 ||
      (lf.f = _fdopen(owned, "rb")) == NULL) {
    int error = errno;
    _close(owned);
    lua_pushfstring(L, "cannot open %s: %s", filename, strerror(error));
    return LUA_ERRFILE;
  }
  lua_pushfstring(L, "@%s", filename);
  lf.n = 0;
  if (win_skipcomment(lf.f, &c))
    lf.buff[lf.n++] = '\n';
  if (c == LUA_SIGNATURE[0])
    lf.n = 0;
  if (c != EOF)
    lf.buff[lf.n++] = cast_char(c);
  status = lua_load(L, win_getF, &lf, lua_tostring(L, -1), mode);
  readstatus = ferror(lf.f);
  fclose(lf.f);
  if (readstatus) {
    lua_settop(L, fnameindex);
    lua_pushfstring(L, "cannot read %s", filename);
    lua_remove(L, fnameindex);
    return LUA_ERRFILE;
  }
  lua_remove(L, fnameindex);
  return status;
}

int luaAP_loadfile(lua_State *L, const char *filename, const char *mode) {
  int fd;
  int status;
  if (filename == NULL)
    return luaL_loadfilex(L, NULL, mode);
  fd = luaAP_winopenfd(L, filename, 1, 0);
  if (fd < 0) {
    lua_pushfstring(L, "cannot open %s: %s", filename, strerror(errno));
    return LUA_ERRFILE;
  }
  status = luaAP_loadfd(L, fd, filename, mode);
  _close(fd);
  return status;
}

static void win_delete_handle(HANDLE handle) {
  FILE_DISPOSITION_INFO remove = {TRUE};
  SetFileInformationByHandle(handle, FileDispositionInfo, &remove,
                             sizeof(remove));
}

int luaAP_wincopy(lua_State *L, const char *src, const char *dst) {
  char buffer[64 * 1024];
  HANDLE input = luaAP_winopen(L, src, GENERIC_READ, OPEN_EXISTING,
                               FILE_FLAG_SEQUENTIAL_SCAN, 1, 0);
  HANDLE output;
  DWORD got = 0;
  DWORD error = ERROR_SUCCESS;
  int result = 0;
  if (input == INVALID_HANDLE_VALUE)
    return 0;
  output = luaAP_winopen(L, dst, GENERIC_WRITE | DELETE, CREATE_NEW,
                         FILE_ATTRIBUTE_NORMAL, 0, 1);
  if (output == INVALID_HANDLE_VALUE) {
    CloseHandle(input);
    return 0;
  }
  for (;;) {
    DWORD offset = 0;
    if (!ReadFile(input, buffer, sizeof(buffer), &got, NULL)) {
      error = GetLastError();
      break;
    }
    if (got == 0) {
      result = 1;
      break;
    }
    while (offset < got) {
      DWORD wrote;
      if (!WriteFile(output, buffer + offset, got - offset, &wrote, NULL) ||
          wrote == 0) {
        error = GetLastError();
        if (error == ERROR_SUCCESS)
          error = ERROR_WRITE_FAULT;
        goto done;
      }
      offset += wrote;
    }
  }
done:
  if (!result)
    win_delete_handle(output);
  CloseHandle(output);
  CloseHandle(input);
  if (!result) {
    SetLastError(error);
    win_set_errno(error);
  }
  return result;
}

int luaAP_winmove(lua_State *L, const char *src, const char *dst) {
  LusAuthParent parent;
  HANDLE source =
      luaAP_winopen(L, src, DELETE | FILE_READ_ATTRIBUTES, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT, 1, 1);
  FILE_RENAME_INFO *rename;
  size_t leaf_bytes;
  size_t size;
  int result;
  DWORD error = ERROR_SUCCESS;
  if (source == INVALID_HANDLE_VALUE)
    return 0;
  if (!luaAP_parent(L, dst, "fs:write", &parent)) {
    error = GetLastError();
    CloseHandle(source);
    SetLastError(error);
    return 0;
  }
  leaf_bytes = wcslen(parent.leaf) * sizeof(WCHAR);
  if (leaf_bytes > MAXDWORD ||
      leaf_bytes > SIZE_MAX - sizeof(FILE_RENAME_INFO)) {
    luaAP_closeparent(&parent);
    CloseHandle(source);
    SetLastError(ERROR_FILENAME_EXCED_RANGE);
    errno = ENAMETOOLONG;
    return 0;
  }
  size = sizeof(FILE_RENAME_INFO) + leaf_bytes;
  rename = cast(FILE_RENAME_INFO *, calloc(1, size));
  if (rename == NULL) {
    luaAP_closeparent(&parent);
    CloseHandle(source);
    SetLastError(ERROR_OUTOFMEMORY);
    errno = ENOMEM;
    return 0;
  }
  rename->ReplaceIfExists = FALSE;
  rename->RootDirectory = parent.handle;
  rename->FileNameLength = cast(DWORD, leaf_bytes);
  memcpy(rename->FileName, parent.leaf, leaf_bytes);
  result = SetFileInformationByHandle(source, FileRenameInfo, rename,
                                      cast(DWORD, size));
  if (!result)
    error = GetLastError();
  free(rename);
  luaAP_closeparent(&parent);
  CloseHandle(source);
  if (!result) {
    SetLastError(error);
    win_set_errno(error);
  }
  return result;
}

int luaAP_winremove(lua_State *L, const char *path) {
  HANDLE handle =
      luaAP_winopen(L, path, DELETE | FILE_READ_ATTRIBUTES, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT, 0, 1);
  FILE_DISPOSITION_INFO remove = {TRUE};
  int result;
  DWORD error = ERROR_SUCCESS;
  if (handle == INVALID_HANDLE_VALUE)
    return 0;
  result = SetFileInformationByHandle(handle, FileDispositionInfo, &remove,
                                      sizeof(remove));
  if (!result)
    error = GetLastError();
  CloseHandle(handle);
  if (!result) {
    SetLastError(error);
    win_set_errno(error);
  }
  return result;
}

int luaAP_unlink(lua_State *L, const char *path, const char *perm) {
  (void)perm;
  return luaAP_winremove(L, path);
}

int luaAP_winmkdir(lua_State *L, const char *path) {
  LusAuthParent parent;
  HANDLE handle;
  if (!luaAP_parent(L, path, "fs:write", &parent))
    return 0;
  handle = win_create_relative(&parent, FILE_LIST_DIRECTORY | DELETE, 1);
  if (handle == INVALID_HANDLE_VALUE) {
    DWORD error = GetLastError();
    luaAP_closeparent(&parent);
    SetLastError(error);
    return 0;
  }
  luaAP_closeparent(&parent);
  CloseHandle(handle);
  return 1;
}

static WCHAR *win_utf8_raw(const char *text) {
  WCHAR *wide;
  int needed =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  if (needed <= 0)
    return NULL;
  wide = cast(WCHAR *, malloc(cast_sizet(needed) * sizeof(WCHAR)));
  if (wide == NULL) {
    SetLastError(ERROR_OUTOFMEMORY);
    return NULL;
  }
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide,
                          needed) == 0) {
    free(wide);
    return NULL;
  }
  return wide;
}

int luaAP_winsymlink(lua_State *L, const char *path, const char *target) {
  LusAuthParent parent;
  char *base = NULL;
  char *effective = NULL;
  WCHAR *print_name = NULL;
  WCHAR *substitute = NULL;
  HANDLE target_handle = INVALID_HANDLE_VALUE;
  HANDLE link_handle = INVALID_HANDLE_VALUE;
  BY_HANDLE_FILE_INFORMATION target_info;
  int target_is_directory = 0;
  int relative;
  int result = 0;
  DWORD error = ERROR_SUCCESS;
  size_t print_chars;
  size_t substitute_chars;
  size_t buffer_size;
  struct LusSymlinkBuffer {
    ULONG ReparseTag;
    USHORT ReparseDataLength;
    USHORT Reserved;
    USHORT SubstituteNameOffset;
    USHORT SubstituteNameLength;
    USHORT PrintNameOffset;
    USHORT PrintNameLength;
    ULONG Flags;
    WCHAR PathBuffer[1];
  } *buffer = NULL;
  if (!luaAP_parent(L, path, "fs:write", &parent))
    return 0;
  print_name = win_utf8_raw(target);
  if (print_name == NULL) {
    error = GetLastError();
    goto done;
  }
  for (WCHAR *p = print_name; *p != L'\0'; p++) {
    if (*p == L'/')
      *p = L'\\';
  }
  print_chars = wcslen(print_name);
  relative = !(
      (print_chars >= 3 && iswalpha(print_name[0]) && print_name[1] == L':' &&
       print_name[2] == L'\\') ||
      (print_chars >= 2 && print_name[0] == L'\\' && print_name[1] == L'\\') ||
      (print_chars >= 1 && print_name[0] == L'\\'));
  if (relative) {
    size_t base_len;
    size_t target_len = strlen(target);
    base = luaAP_winhandlepath(parent.handle);
    if (base == NULL) {
      error = GetLastError();
      goto done;
    }
    base_len = strlen(base);
    effective = cast(char *, malloc(base_len + target_len + 2));
    if (effective == NULL) {
      error = ERROR_OUTOFMEMORY;
      goto done;
    }
    memcpy(effective, base, base_len);
    effective[base_len++] = '\\';
    memcpy(effective + base_len, target, target_len + 1);
  }
  else {
    effective = _strdup(target);
    if (effective == NULL) {
      error = ERROR_OUTOFMEMORY;
      goto done;
    }
  }
  target_handle =
      luaAP_winopen(L, effective, FILE_READ_ATTRIBUTES, OPEN_EXISTING,
                    FILE_FLAG_BACKUP_SEMANTICS, 0, 1);
  if (target_handle != INVALID_HANDLE_VALUE) {
    if (GetFileInformationByHandle(target_handle, &target_info))
      target_is_directory =
          (target_info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    CloseHandle(target_handle);
    target_handle = INVALID_HANDLE_VALUE;
  }
  else if (GetLastError() == ERROR_FILE_NOT_FOUND ||
           GetLastError() == ERROR_PATH_NOT_FOUND) {
    LusAuthParent target_parent;
    if (!luaAP_parent(L, effective, "fs:write", &target_parent)) {
      error = GetLastError();
      goto done;
    }
    luaAP_closeparent(&target_parent);
  }
  else {
    error = GetLastError();
    goto done;
  }
  if (relative)
    substitute = win_utf8_raw(target);
  else {
    WCHAR *full = win_utf8_to_fullpath(target);
    size_t full_len;
    if (full == NULL) {
      error = GetLastError();
      goto done;
    }
    for (WCHAR *p = full; *p != L'\0'; p++) {
      if (*p == L'/')
        *p = L'\\';
    }
    full_len = wcslen(full);
    if (wcsncmp(full, L"\\\\", 2) == 0) {
      substitute = cast(WCHAR *, malloc((full_len + 7) * sizeof(WCHAR)));
      if (substitute != NULL) {
        wcscpy(substitute, L"\\??\\UNC\\");
        wcscpy(substitute + 8, full + 2);
      }
    }
    else {
      substitute = cast(WCHAR *, malloc((full_len + 5) * sizeof(WCHAR)));
      if (substitute != NULL) {
        wcscpy(substitute, L"\\??\\");
        wcscpy(substitute + 4, full);
      }
    }
    free(full);
  }
  if (substitute == NULL) {
    error = ERROR_OUTOFMEMORY;
    goto done;
  }
  substitute_chars = wcslen(substitute);
  if (print_chars > USHRT_MAX / sizeof(WCHAR) ||
      substitute_chars > USHRT_MAX / sizeof(WCHAR) ||
      print_chars + substitute_chars > (USHRT_MAX - 12) / sizeof(WCHAR)) {
    error = ERROR_FILENAME_EXCED_RANGE;
    goto done;
  }
  buffer_size = offsetof(struct LusSymlinkBuffer, PathBuffer) +
                (print_chars + substitute_chars) * sizeof(WCHAR);
  buffer = cast(struct LusSymlinkBuffer *, calloc(1, buffer_size));
  if (buffer == NULL) {
    error = ERROR_OUTOFMEMORY;
    goto done;
  }
  buffer->ReparseTag = IO_REPARSE_TAG_SYMLINK;
  buffer->ReparseDataLength = cast(USHORT, buffer_size - 8);
  buffer->SubstituteNameOffset = 0;
  buffer->SubstituteNameLength = cast(USHORT, substitute_chars * sizeof(WCHAR));
  buffer->PrintNameOffset = buffer->SubstituteNameLength;
  buffer->PrintNameLength = cast(USHORT, print_chars * sizeof(WCHAR));
  buffer->Flags = relative ? 1 : 0;
  memcpy(buffer->PathBuffer, substitute, substitute_chars * sizeof(WCHAR));
  memcpy(cast(char *, buffer->PathBuffer) + buffer->PrintNameOffset, print_name,
         print_chars * sizeof(WCHAR));
  link_handle =
      win_create_relative(&parent, GENERIC_WRITE | DELETE, target_is_directory);
  if (link_handle == INVALID_HANDLE_VALUE) {
    error = GetLastError();
    goto done;
  }
  {
    DWORD returned;
    if (!DeviceIoControl(link_handle, FSCTL_SET_REPARSE_POINT, buffer,
                         cast(DWORD, buffer_size), NULL, 0, &returned, NULL)) {
      error = GetLastError();
      win_delete_handle(link_handle);
      goto done;
    }
  }
  result = 1;
done:
  if (target_handle != INVALID_HANDLE_VALUE)
    CloseHandle(target_handle);
  if (link_handle != INVALID_HANDLE_VALUE)
    CloseHandle(link_handle);
  free(buffer);
  free(substitute);
  free(print_name);
  free(effective);
  free(base);
  luaAP_closeparent(&parent);
  if (!result) {
    SetLastError(error);
    win_set_errno(error);
  }
  return result;
}

#else
#include <dirent.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <sys/stat.h>
#if defined(LUS_PLATFORM_LINUX)
#include <sys/syscall.h>
#endif
#include <sys/types.h>
#include <unistd.h>

#if defined(LUS_PLATFORM_DARWIN) || defined(LUS_PLATFORM_FREEBSD)
#include <sys/param.h>
#endif

#if !defined(O_CLOEXEC)
#define O_CLOEXEC 0
#endif

#if !defined(O_DIRECTORY)
#define O_DIRECTORY 0
#endif

#if defined(__EMSCRIPTEN__)
/* Emscripten binds stdout and stderr to MEMFS character-device objects. Match
** opened objects against those retained descriptors so aliases and renamed
** device nodes cannot bypass the WebAssembly output capture boundary. */
#define EMSCRIPTEN_CONSOLE_IDENTITIES 6

static struct stat emscripten_console_identities[EMSCRIPTEN_CONSOLE_IDENTITIES];
static unsigned char emscripten_console_valid[EMSCRIPTEN_CONSOLE_IDENTITIES];
static int emscripten_console_initialized;

static int emscripten_same_console(const struct stat *object,
                                   const struct stat *console) {
  return S_ISCHR(console->st_mode) &&
         ((object->st_dev == console->st_dev &&
           object->st_ino == console->st_ino) ||
          (console->st_rdev != 0 && object->st_rdev == console->st_rdev));
}

void luaAP_initwasmconsole(void) {
  static const char *const paths[] = {"/dev/stdout", "/dev/stderr", "/dev/tty",
                                      "/dev/tty1"};
  int saved_errno = errno;
  size_t i;

  if (emscripten_console_initialized)
    return;
  emscripten_console_initialized = 1;
  emscripten_console_valid[0] =
      fstat(STDOUT_FILENO, &emscripten_console_identities[0]) == 0;
  emscripten_console_valid[1] =
      fstat(STDERR_FILENO, &emscripten_console_identities[1]) == 0;
  for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
    emscripten_console_valid[i + 2] =
        stat(paths[i], &emscripten_console_identities[i + 2]) == 0;
  }
  errno = saved_errno;
}

static int emscripten_is_host_console_stat(const struct stat *object) {
  size_t i;

  if (!S_ISCHR(object->st_mode))
    return 0;
  luaAP_initwasmconsole();
  for (i = 0; i < EMSCRIPTEN_CONSOLE_IDENTITIES; i++) {
    if (emscripten_console_valid[i] &&
        emscripten_same_console(object, &emscripten_console_identities[i]))
      return 1;
  }
  return 0;
}

static int emscripten_is_host_console_fd(int fd) {
  struct stat object;

  return fstat(fd, &object) == 0 && emscripten_is_host_console_stat(&object);
}

static l_noret emscripten_deny_host_console(lua_State *L) {
  luaL_error(L, "host console devices are unavailable in WebAssembly");
  abort();
}
#endif

#if defined(LUS_PLATFORM_LINUX)
#define LUS_RENAME_NOREPLACE 1U

static int posix_rename_noreplace(int olddirfd, const char *oldpath,
                                  int newdirfd, const char *newpath) {
#if defined(SYS_renameat2)
  return cast_int(syscall(SYS_renameat2, olddirfd, oldpath, newdirfd, newpath,
                          LUS_RENAME_NOREPLACE));
#else
  UNUSED(olddirfd);
  UNUSED(oldpath);
  UNUSED(newdirfd);
  UNUSED(newpath);
  errno = ENOSYS;
  return -1;
#endif
}
#endif

static int append_path(char *out, size_t out_size, const char *parent,
                       const char *leaf) {
  int n;
  if (strcmp(parent, "/") == 0)
    n = snprintf(out, out_size, "/%s", leaf);
  else
    n = snprintf(out, out_size, "%s/%s", parent, leaf);
  return n >= 0 && (size_t)n < out_size;
}

static int split_parent(const char *path, char *parent, size_t parent_size,
                        char *leaf, size_t leaf_size) {
  char copy[PATH_MAX];
  char *slash;
  size_t len = strlen(path);
  if (len == 0 || len >= sizeof(copy)) {
    errno = ENAMETOOLONG;
    return 0;
  }
  memcpy(copy, path, len + 1);
  while (len > 1 && copy[len - 1] == '/')
    copy[--len] = '\0';
  slash = strrchr(copy, '/');
  if (slash == NULL) {
    if (strlen(copy) >= leaf_size || parent_size < 2) {
      errno = ENAMETOOLONG;
      return 0;
    }
    strcpy(parent, ".");
    strcpy(leaf, copy);
  }
  else {
    const char *name = slash + 1;
    size_t plen = cast_sizet(slash - copy);
    if (*name == '\0' || strlen(name) >= leaf_size) {
      errno = EINVAL;
      return 0;
    }
    if (slash == copy) {
      if (parent_size < 2) {
        errno = ENAMETOOLONG;
        return 0;
      }
      strcpy(parent, "/");
    }
    else {
      if (plen >= parent_size) {
        errno = ENAMETOOLONG;
        return 0;
      }
      memcpy(parent, copy, plen);
      parent[plen] = '\0';
    }
    strcpy(leaf, name);
  }
  if (strcmp(leaf, ".") == 0 || strcmp(leaf, "..") == 0) {
    errno = EINVAL;
    return 0;
  }
  return 1;
}

int luaAP_fdpath(int fd, char *path, size_t path_size) {
#if defined(LUS_PLATFORM_DARWIN)
  if (path_size < MAXPATHLEN) {
    errno = ENAMETOOLONG;
    return 0;
  }
  if (fcntl(fd, F_GETPATH, path) == 0)
    return 1;
  return 0;
#else
  char linkpath[64];
  ssize_t got;
#if defined(LUS_PLATFORM_FREEBSD) || defined(LUS_PLATFORM_NETBSD)
  snprintf(linkpath, sizeof(linkpath), "/proc/curproc/fd/%d", fd);
#else
  snprintf(linkpath, sizeof(linkpath), "/proc/self/fd/%d", fd);
#endif
  got = readlink(linkpath, path, path_size - 1);
  if (got < 0 || (size_t)got >= path_size - 1) {
    if (got >= 0)
      errno = ENAMETOOLONG;
    return 0;
  }
  path[got] = '\0';
  return 1;
#endif
}

static int check_canonical(lua_State *L, const char *perm,
                           const char *canonical) {
  return luaP_hasfscanonical(L, perm, canonical);
}

static l_noret deny_canonical(lua_State *L, const char *perm,
                              const char *display) {
  luaL_error(L, "permission \"%s\" denied for '%s'", perm, display);
  abort();
}

static int posix_parent_raw(const char *path, LusAuthParent *result) {
  char parent[PATH_MAX];
  char canonical_parent[PATH_MAX];
  memset(result, 0, sizeof(*result));
  result->fd = -1;
  if (!split_parent(path, parent, sizeof(parent), result->leaf,
                    sizeof(result->leaf)))
    return 0;
  result->fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (result->fd < 0)
    return 0;
#if defined(__EMSCRIPTEN__)
  /* Emscripten MEMFS runs each C operation synchronously inside one JavaScript
  ** worker event. Canonicalize its virtual parent path directly, while native
  ** host filesystems retain descriptor-bound authorization. */
  if (realpath(parent, canonical_parent) == NULL ||
#else
  if (!luaAP_fdpath(result->fd, canonical_parent, sizeof(canonical_parent)) ||
#endif
      !append_path(result->canonical, sizeof(result->canonical),
                   canonical_parent, result->leaf)) {
    int err = errno;
    close(result->fd);
    result->fd = -1;
    errno = err != 0 ? err : ENAMETOOLONG;
    return 0;
  }
  return 1;
}

int luaAP_parent(lua_State *L, const char *path, const char *perm,
                 LusAuthParent *result) {
  if (!posix_parent_raw(path, result))
    return 0;
  if (perm != NULL && !check_canonical(L, perm, result->canonical)) {
    luaAP_closeparent(result);
    deny_canonical(L, perm, path);
  }
  return 1;
}

void luaAP_closeparent(LusAuthParent *parent) {
  if (parent->fd >= 0)
    close(parent->fd);
  parent->fd = -1;
}

static int authorize_fd(lua_State *L, int fd, int need_read, int need_write,
                        const char **denied) {
  char canonical[PATH_MAX];
  if (!luaAP_fdpath(fd, canonical, sizeof(canonical)))
    return 0;
  if (need_read && !check_canonical(L, "fs:read", canonical)) {
    *denied = "fs:read";
    return 0;
  }
  if (need_write && !check_canonical(L, "fs:write", canonical)) {
    *denied = "fs:write";
    return 0;
  }
  return 1;
}

static void posix_authfile_init(LusAuthFile *file) {
  memset(file, 0, sizeof(*file));
  file->fd = -1;
  file->parent.fd = -1;
}

static int posix_authfile_parent(LusAuthFile *file) {
  struct stat object;
  struct stat named;
  if (!file->has_parent) {
    if (!posix_parent_raw(file->canonical, &file->parent))
      return 0;
    file->has_parent = 1;
  }
  if (fstat(file->fd, &object) != 0 ||
      fstatat(file->parent.fd, file->parent.leaf, &named,
              AT_SYMLINK_NOFOLLOW) != 0 ||
      object.st_dev != named.st_dev || object.st_ino != named.st_ino) {
    int err = errno != 0 ? errno : EAGAIN;
    luaAP_closeparent(&file->parent);
    file->has_parent = 0;
    errno = err;
    return 0;
  }
  file->device = cast(unsigned long long, object.st_dev);
  file->inode = cast(unsigned long long, object.st_ino);
  file->object_mode = cast_uint(object.st_mode);
  file->object_size = cast(long long, object.st_size);
  return 1;
}

static int posix_authfile_authorize(lua_State *L, LusAuthFile *file,
                                    int need_read, int need_write) {
#if defined(__EMSCRIPTEN__)
  if (need_write && emscripten_is_host_console_fd(file->fd)) {
    errno = EPERM;
    return LUS_AUTH_ERROR;
  }
#endif
  if (!luaAP_fdpath(file->fd, file->canonical, sizeof(file->canonical)))
    return LUS_AUTH_ERROR;
  if (need_read && !luaP_hasfscanonical(L, "fs:read", file->canonical)) {
    file->denied_perm = "fs:read";
    return LUS_AUTH_DENIED;
  }
  if (need_write && !luaP_hasfscanonical(L, "fs:write", file->canonical)) {
    file->denied_perm = "fs:write";
    return LUS_AUTH_DENIED;
  }
  if (!posix_authfile_parent(file))
    return LUS_AUTH_ERROR;
  return LUS_AUTH_OK;
}

int luaAP_tryopen(lua_State *L, const char *path, int options,
                  unsigned int mode, LusAuthFile *file) {
  int need_read = (options & LUS_AUTH_READ) != 0;
  int need_write =
      (options & (LUS_AUTH_WRITE | LUS_AUTH_CREATE | LUS_AUTH_DELETE |
                  LUS_AUTH_DELETE_ON_CLOSE)) != 0;
  int content_write = (options & LUS_AUTH_WRITE) != 0;
  int create = (options & LUS_AUTH_CREATE) != 0;
  int exclusive = (options & LUS_AUTH_EXCLUSIVE) != 0;
  int openflags = O_CLOEXEC;
  int tries;
  posix_authfile_init(file);
  if (need_read && content_write)
    openflags |= O_RDWR;
  else if (content_write)
    openflags |= O_WRONLY;
  else
    openflags |= O_RDONLY;
  for (tries = 0; tries < 3; tries++) {
    int status;
    if (!exclusive) {
      file->fd = open(path, openflags, (mode_t)mode);
      if (file->fd >= 0) {
        status = posix_authfile_authorize(L, file, need_read, need_write);
        if (status == LUS_AUTH_OK)
          return status;
        luaAP_closeauthfile(file);
        return status;
      }
      if (errno != ENOENT)
        return LUS_AUTH_ERROR;
    }
    if (!create) {
      if (!posix_parent_raw(path, &file->parent))
        return LUS_AUTH_ERROR;
      file->has_parent = 1;
      if (need_read &&
          !luaP_hasfscanonical(L, "fs:read", file->parent.canonical)) {
        file->denied_perm = "fs:read";
        return LUS_AUTH_DENIED;
      }
      if (need_write &&
          !luaP_hasfscanonical(L, "fs:write", file->parent.canonical)) {
        file->denied_perm = "fs:write";
        return LUS_AUTH_DENIED;
      }
      return LUS_AUTH_MISSING;
    }
    if (!posix_parent_raw(path, &file->parent))
      return LUS_AUTH_ERROR;
    file->has_parent = 1;
    if (need_read &&
        !luaP_hasfscanonical(L, "fs:read", file->parent.canonical)) {
      file->denied_perm = "fs:read";
      return LUS_AUTH_DENIED;
    }
    if (need_write &&
        !luaP_hasfscanonical(L, "fs:write", file->parent.canonical)) {
      file->denied_perm = "fs:write";
      return LUS_AUTH_DENIED;
    }
    file->fd = openat(file->parent.fd, file->parent.leaf,
                      openflags | O_CREAT | O_EXCL, (mode_t)mode);
    if (file->fd >= 0) {
      file->created = 1;
      status = posix_authfile_authorize(L, file, need_read, need_write);
      if (status == LUS_AUTH_OK)
        return status;
      luaAP_deleteauthfile(file);
      luaAP_closeauthfile(file);
      return status;
    }
    {
      int err = errno;
      luaAP_closeauthfile(file);
      if (err == EEXIST && !exclusive)
        continue;
      errno = err;
      return err == EEXIST ? LUS_AUTH_EXISTS : LUS_AUTH_ERROR;
    }
  }
  errno = EAGAIN;
  return LUS_AUTH_ERROR;
}

static int posix_duplicate_cloexec(int fd) {
#if defined(F_DUPFD_CLOEXEC)
  return fcntl(fd, F_DUPFD_CLOEXEC, 0);
#else
  int duplicate = dup(fd);
  if (duplicate >= 0 && fcntl(duplicate, F_SETFD, FD_CLOEXEC) != 0) {
    int err = errno;
    close(duplicate);
    errno = err;
    return -1;
  }
  return duplicate;
#endif
}

static int posix_sibling_parent(const LusAuthFile *anchor, const char *suffix,
                                const char *authorized_path,
                                LusAuthFile *file) {
  int leaf_length;
  size_t path_length;
  if (anchor == NULL || !anchor->has_parent || anchor->parent.fd < 0 ||
      suffix == NULL ||
      (suffix[0] != '\0' && (suffix[0] != '-' || suffix[1] == '\0' ||
                             strchr(suffix, '/') != NULL)) ||
      authorized_path == NULL) {
    errno = EINVAL;
    return 0;
  }
  leaf_length = snprintf(file->parent.leaf, sizeof(file->parent.leaf), "%s%s",
                         anchor->parent.leaf, suffix);
  path_length = strlen(authorized_path);
  if (leaf_length < 0 || cast_sizet(leaf_length) >= sizeof(file->parent.leaf) ||
      path_length >= sizeof(file->parent.canonical)) {
    errno = ENAMETOOLONG;
    return 0;
  }
  file->parent.fd = posix_duplicate_cloexec(anchor->parent.fd);
  if (file->parent.fd < 0)
    return 0;
  memcpy(file->parent.canonical, authorized_path, path_length + 1);
  file->has_parent = 1;
  return 1;
}

static int posix_sibling_object(const LusAuthFile *anchor, int anchor_object,
                                LusAuthFile *file,
                                const char *authorized_path) {
  struct stat anchor_stat;
  struct stat object;
  struct stat named;
  size_t length = strlen(authorized_path);
  if (fstat(file->fd, &object) != 0 ||
      fstatat(file->parent.fd, file->parent.leaf, &named,
              AT_SYMLINK_NOFOLLOW) != 0 ||
      object.st_dev != named.st_dev || object.st_ino != named.st_ino) {
    if (errno == 0)
      errno = EAGAIN;
    return 0;
  }
  if (anchor_object && (fstat(anchor->fd, &anchor_stat) != 0 ||
                        anchor_stat.st_dev != object.st_dev ||
                        anchor_stat.st_ino != object.st_ino)) {
    if (errno == 0)
      errno = EAGAIN;
    return 0;
  }
  if (S_ISDIR(object.st_mode)) {
    errno = EISDIR;
    return 0;
  }
  memcpy(file->canonical, authorized_path, length + 1);
  file->device = cast(unsigned long long, object.st_dev);
  file->inode = cast(unsigned long long, object.st_ino);
  file->object_mode = cast_uint(object.st_mode);
  file->object_size = cast(long long, object.st_size);
  return 1;
}

int luaAP_tryopensibling(lua_State *L, const LusAuthFile *anchor,
                         const char *suffix, const char *authorized_path,
                         int options, unsigned int mode, LusAuthFile *file) {
  int need_read = (options & LUS_AUTH_READ) != 0;
  int need_write =
      (options & (LUS_AUTH_WRITE | LUS_AUTH_CREATE | LUS_AUTH_DELETE |
                  LUS_AUTH_DELETE_ON_CLOSE)) != 0;
  int content_write = (options & LUS_AUTH_WRITE) != 0;
  int create = (options & LUS_AUTH_CREATE) != 0;
  int exclusive = (options & LUS_AUTH_EXCLUSIVE) != 0;
  int openflags = O_CLOEXEC;
  int anchor_object = suffix != NULL && suffix[0] == '\0';
  int tries;
  posix_authfile_init(file);
  if (!posix_sibling_parent(anchor, suffix, authorized_path, file))
    return LUS_AUTH_ERROR;
  if (need_read && !luaP_hasfscanonical(L, "fs:read", authorized_path)) {
    file->denied_perm = "fs:read";
    return LUS_AUTH_DENIED;
  }
  if (need_write && !luaP_hasfscanonical(L, "fs:write", authorized_path)) {
    file->denied_perm = "fs:write";
    return LUS_AUTH_DENIED;
  }
  if (need_read && content_write)
    openflags |= O_RDWR;
  else if (content_write)
    openflags |= O_WRONLY;
  else
    openflags |= O_RDONLY;
#if !defined(O_NOFOLLOW)
  errno = ENOTSUP;
  return LUS_AUTH_ERROR;
#else
  openflags |= O_NOFOLLOW;
#endif
  for (tries = 0; tries < 3; tries++) {
    if (!exclusive) {
      file->fd =
          openat(file->parent.fd, file->parent.leaf, openflags, (mode_t)mode);
      if (file->fd >= 0) {
        if (posix_sibling_object(anchor, anchor_object, file,
                                 authorized_path)) {
#if defined(__EMSCRIPTEN__)
          if (need_write && emscripten_is_host_console_fd(file->fd)) {
            errno = EPERM;
            luaAP_closeauthfile(file);
            return LUS_AUTH_ERROR;
          }
#endif
          return LUS_AUTH_OK;
        }
        {
          int err = errno;
          luaAP_closeauthfile(file);
          errno = err;
          return LUS_AUTH_ERROR;
        }
      }
      if (errno != ENOENT)
        return LUS_AUTH_ERROR;
    }
    if (!create)
      return LUS_AUTH_MISSING;
    file->fd = openat(file->parent.fd, file->parent.leaf,
                      openflags | O_CREAT | O_EXCL, (mode_t)mode);
    if (file->fd >= 0) {
      file->created = 1;
      if (posix_sibling_object(anchor, anchor_object, file, authorized_path)) {
#if defined(__EMSCRIPTEN__)
        if (need_write && emscripten_is_host_console_fd(file->fd)) {
          errno = EPERM;
          luaAP_deleteauthfile(file);
          luaAP_closeauthfile(file);
          return LUS_AUTH_ERROR;
        }
#endif
        return LUS_AUTH_OK;
      }
      {
        int err = errno;
        luaAP_deleteauthfile(file);
        luaAP_closeauthfile(file);
        errno = err;
        return LUS_AUTH_ERROR;
      }
    }
    if (errno != EEXIST || exclusive)
      return errno == EEXIST ? LUS_AUTH_EXISTS : LUS_AUTH_ERROR;
  }
  errno = EAGAIN;
  return LUS_AUTH_ERROR;
}

void luaAP_moveauthfile(LusAuthFile *destination, LusAuthFile *source) {
  if (destination == NULL || source == NULL || destination == source)
    return;
  *destination = *source;
  posix_authfile_init(source);
}

static LusAuthDeleteHook posix_delete_hook;
static void *posix_delete_hook_context;
static _Atomic unsigned long posix_delete_nonce;

void luaAP_setdeletehook(LusAuthDeleteHook hook, void *context) {
  posix_delete_hook = hook;
  posix_delete_hook_context = context;
}

static int posix_same_identity(const struct stat *first,
                               const struct stat *second) {
  return first->st_dev == second->st_dev && first->st_ino == second->st_ino;
}

static int posix_authfile_matches(const LusAuthFile *file, struct stat *named) {
  struct stat object;
  if (file == NULL || !file->has_parent || file->parent.fd < 0) {
    errno = EINVAL;
    return 0;
  }
  if (fstatat(file->parent.fd, file->parent.leaf, named, AT_SYMLINK_NOFOLLOW) !=
      0)
    return 0;
  if (cast(unsigned long long, named->st_dev) != file->device ||
      cast(unsigned long long, named->st_ino) != file->inode) {
    errno = EAGAIN;
    return 0;
  }
  if (file->fd >= 0 && fstat(file->fd, &object) != 0)
    return 0;
  if (file->fd >= 0 && !posix_same_identity(&object, named)) {
    errno = EAGAIN;
    return 0;
  }
  return 1;
}

static int posix_delete_tree_fd(int root_fd) {
  int owned = posix_duplicate_cloexec(root_fd);
  DIR *directory;
  struct dirent *entry;
  if (owned < 0)
    return 0;
  directory = fdopendir(owned);
  if (directory == NULL) {
    int err = errno;
    close(owned);
    errno = err;
    return 0;
  }
  while ((entry = readdir(directory)) != NULL) {
    struct stat object;
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
      continue;
    if (fstatat(root_fd, entry->d_name, &object, AT_SYMLINK_NOFOLLOW) != 0)
      goto failed;
    if (S_ISDIR(object.st_mode) && !S_ISLNK(object.st_mode)) {
      int child = openat(root_fd, entry->d_name,
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (child < 0)
        goto failed;
      if (!posix_delete_tree_fd(child)) {
        int err = errno;
        close(child);
        errno = err;
        goto failed;
      }
      close(child);
      if (unlinkat(root_fd, entry->d_name, AT_REMOVEDIR) != 0)
        goto failed;
    }
    else if (unlinkat(root_fd, entry->d_name, 0) != 0)
      goto failed;
  }
  return closedir(directory) == 0;

failed: {
  int err = errno;
  closedir(directory);
  errno = err;
  return 0;
}
}

static int posix_directory_is_empty(int root_fd) {
  int owned = posix_duplicate_cloexec(root_fd);
  DIR *directory;
  struct dirent *entry;
  if (owned < 0)
    return -1;
  directory = fdopendir(owned);
  if (directory == NULL) {
    int err = errno;
    close(owned);
    errno = err;
    return -1;
  }
  while ((entry = readdir(directory)) != NULL) {
    if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
      closedir(directory);
      errno = ENOTEMPTY;
      return 0;
    }
  }
  if (closedir(directory) != 0)
    return -1;
  return 1;
}

#if !defined(__EMSCRIPTEN__)
static void posix_cleanup_created_quarantine(const LusAuthFile *file,
                                             const char *name, int directory_fd,
                                             const struct stat *created) {
  struct stat opened;
  struct stat current;
  int err = errno;
  if (fstat(directory_fd, &opened) == 0 &&
      posix_same_identity(created, &opened) &&
      fstatat(file->parent.fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
      posix_same_identity(created, &current))
    unlinkat(file->parent.fd, name, AT_REMOVEDIR);
  close(directory_fd);
  errno = err;
}

static int posix_open_quarantine(const LusAuthFile *file, char *name,
                                 size_t name_size, int *directory_fd) {
  unsigned int tries;
  for (tries = 0; tries < 1024; tries++) {
    unsigned long nonce = atomic_fetch_add(&posix_delete_nonce, 1) + 1;
    struct stat created;
    struct stat opened;
    struct stat named;
    char parent[PATH_MAX];
    char canonical[PATH_MAX];
    int length = snprintf(name, name_size, LUS_AUTH_QUARANTINE_PREFIX "%ld.%lu",
                          (long)getpid(), nonce);
    if (length < 0 || cast_sizet(length) >= name_size) {
      errno = ENAMETOOLONG;
      return 0;
    }
    if (mkdirat(file->parent.fd, name, 0700) != 0) {
      if (errno == EEXIST)
        continue;
      return 0;
    }
    *directory_fd = openat(file->parent.fd, name,
                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (*directory_fd < 0) {
      /* No retained identity exists, so preserve the reserved directory. */
      return 0;
    }
    if (fstat(*directory_fd, &created) != 0) {
      int err = errno;
      close(*directory_fd);
      *directory_fd = -1;
      /* Without the retained identity, removing the name is not fail-safe. */
      errno = err;
      return 0;
    }
    if (!S_ISDIR(created.st_mode) || created.st_uid != geteuid() ||
        (created.st_mode & 0777) != 0700) {
      int err = EACCES;
      posix_cleanup_created_quarantine(file, name, *directory_fd, &created);
      *directory_fd = -1;
      errno = err;
      return 0;
    }
    if (posix_delete_hook != NULL &&
        luaAP_fdpath(file->parent.fd, parent, sizeof(parent)) &&
        append_path(canonical, sizeof(canonical), parent, name))
      posix_delete_hook("quarantine-created", canonical,
                        posix_delete_hook_context);
    if (fstat(*directory_fd, &opened) != 0 ||
        fstatat(file->parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISDIR(opened.st_mode) || opened.st_uid != created.st_uid ||
        (opened.st_mode & 0777) != 0700 ||
        !posix_same_identity(&created, &opened) ||
        !posix_same_identity(&created, &named)) {
      int err = EAGAIN;
      posix_cleanup_created_quarantine(file, name, *directory_fd, &created);
      *directory_fd = -1;
      errno = err;
      return 0;
    }
    return 1;
  }
  errno = EEXIST;
  return 0;
}

static int posix_restore_quarantine(const LusAuthFile *file, int directory_fd) {
#if defined(LUS_PLATFORM_DARWIN)
  return renameatx_np(directory_fd, "object", file->parent.fd,
                      file->parent.leaf, RENAME_EXCL) == 0;
#elif defined(LUS_PLATFORM_LINUX)
  return posix_rename_noreplace(directory_fd, "object", file->parent.fd,
                                file->parent.leaf) == 0;
#else
  if (!S_ISDIR(file->object_mode) &&
      linkat(directory_fd, "object", file->parent.fd, file->parent.leaf, 0) ==
          0) {
    int result = unlinkat(directory_fd, "object", 0);
    if (result == 0)
      return 1;
    errno = EAGAIN;
    return 0;
  }
  errno = ENOTSUP;
  return 0;
#endif
}

static void posix_remove_empty_quarantine(const LusAuthFile *file,
                                          const char *name, int directory_fd) {
  struct stat created;
  int err = errno;
  if (fstat(directory_fd, &created) == 0)
    posix_cleanup_created_quarantine(file, name, directory_fd, &created);
  else
    close(directory_fd);
  errno = err;
}
#endif

static int posix_deleteauthfile(LusAuthFile *file, int recursive) {
  struct stat named;
  int flags;
  if (!posix_authfile_matches(file, &named))
    return 0;
  flags = S_ISDIR(named.st_mode) && !S_ISLNK(named.st_mode) ? AT_REMOVEDIR : 0;
  if (!recursive && flags == AT_REMOVEDIR &&
      posix_directory_is_empty(file->fd) <= 0)
    return 0;
  if (posix_delete_hook != NULL)
    posix_delete_hook("validated", file->canonical, posix_delete_hook_context);

#if defined(LUS_PLATFORM_FREEBSD) && __FreeBSD_version >= 1300000
  if (!recursive && file->fd >= 0)
    return funlinkat(file->parent.fd, file->parent.leaf, file->fd, flags) == 0;
#endif

#if defined(__EMSCRIPTEN__)
  if (!posix_authfile_matches(file, &named))
    return 0;
  if (recursive && flags == AT_REMOVEDIR && !posix_delete_tree_fd(file->fd))
    return 0;
  return unlinkat(file->parent.fd, file->parent.leaf, flags) == 0;
#else
  {
    char quarantine[NAME_MAX + 1];
    int directory_fd = -1;
    struct stat moved;
    int err;
    if (!posix_open_quarantine(file, quarantine, sizeof(quarantine),
                               &directory_fd))
      return 0;
    if (renameat(file->parent.fd, file->parent.leaf, directory_fd, "object") !=
        0) {
      err = errno;
      posix_remove_empty_quarantine(file, quarantine, directory_fd);
      errno = err;
      return 0;
    }
    if (posix_delete_hook != NULL)
      posix_delete_hook("quarantined", file->canonical,
                        posix_delete_hook_context);
    if (fstatat(directory_fd, "object", &moved, AT_SYMLINK_NOFOLLOW) != 0 ||
        cast(unsigned long long, moved.st_dev) != file->device ||
        cast(unsigned long long, moved.st_ino) != file->inode) {
      err = EAGAIN;
      if (posix_restore_quarantine(file, directory_fd))
        posix_remove_empty_quarantine(file, quarantine, directory_fd);
      else
        close(directory_fd);
      errno = err;
      return 0;
    }
    if (recursive && flags == AT_REMOVEDIR && !posix_delete_tree_fd(file->fd)) {
      err = errno;
      if (posix_restore_quarantine(file, directory_fd))
        posix_remove_empty_quarantine(file, quarantine, directory_fd);
      else
        close(directory_fd);
      errno = err;
      return 0;
    }
    if (unlinkat(directory_fd, "object", flags) != 0) {
      err = errno;
      if (posix_restore_quarantine(file, directory_fd))
        posix_remove_empty_quarantine(file, quarantine, directory_fd);
      else
        close(directory_fd);
      errno = err;
      return 0;
    }
    posix_remove_empty_quarantine(file, quarantine, directory_fd);
    return 1;
  }
#endif
}

int luaAP_deleteauthfile(LusAuthFile *file) {
  return posix_deleteauthfile(file, 0);
}

int luaAP_deleteauthrecursive(LusAuthFile *file) {
  return posix_deleteauthfile(file, 1);
}

int luaAP_syncauthparent(LusAuthFile *file) {
  if (file == NULL || !file->has_parent) {
    errno = EINVAL;
    return 0;
  }
  return fsync(file->parent.fd) == 0;
}

void luaAP_closeauthfile(LusAuthFile *file) {
  int err = errno;
  if (file == NULL)
    return;
  if (file->fd >= 0)
    close(file->fd);
  if (file->has_parent)
    luaAP_closeparent(&file->parent);
  file->fd = -1;
  file->has_parent = 0;
  errno = err;
}

const char *luaAP_authfilepath(const LusAuthFile *file) {
  return file != NULL ? file->canonical : NULL;
}

int luaAP_open(lua_State *L, const char *path, int flags, unsigned int mode,
               int need_read, int need_write) {
#if defined(__EMSCRIPTEN__)
  char canonical[PATH_MAX];
  int safe_flags = flags & ~O_TRUNC;
  int fd;
  /* Emscripten MEMFS calls run synchronously inside one JavaScript worker
  ** event. The canonical virtual name remains the pledge authority, while
  ** native builds authorize and retain the opened object below. */
  if (!luaAP_resolvepattern(path, canonical, sizeof(canonical)))
    return -1;
  if (need_read && !check_canonical(L, "fs:read", canonical))
    deny_canonical(L, "fs:read", path);
  if (need_write && !check_canonical(L, "fs:write", canonical))
    deny_canonical(L, "fs:write", path);
  fd = open(path, safe_flags | O_CLOEXEC, (mode_t)mode);
  if (fd >= 0 && need_write && emscripten_is_host_console_fd(fd)) {
    close(fd);
    emscripten_deny_host_console(L);
  }
  if (fd >= 0 && (flags & O_TRUNC) && ftruncate(fd, 0) != 0) {
    int err = errno;
    close(fd);
    errno = err;
    return -1;
  }
  return fd;
#else
  int safe_flags = flags & ~O_TRUNC;
  int fd;
  int tries;
  const char *denied = NULL;
  for (tries = 0; tries < 3; tries++) {
    fd = open(path, safe_flags & ~(O_CREAT | O_EXCL), (mode_t)mode);
    if (fd >= 0) {
      if ((flags & O_CREAT) && (flags & O_EXCL)) {
        close(fd);
        errno = EEXIST;
        return -1;
      }
      if (!authorize_fd(L, fd, need_read, need_write, &denied)) {
        int lookup_error = errno;
        close(fd);
        if (denied != NULL)
          deny_canonical(L, denied, path);
        errno = lookup_error;
        return -1;
      }
      if ((flags & O_TRUNC) && ftruncate(fd, 0) != 0) {
        int err = errno;
        close(fd);
        errno = err;
        return -1;
      }
      return fd;
    }
    if (errno != ENOENT)
      return -1;
    if (!(flags & O_CREAT)) {
      LusAuthParent parent;
      const char *perm = need_read ? "fs:read" : "fs:write";
      if (luaAP_parent(L, path, perm, &parent))
        luaAP_closeparent(&parent);
      errno = ENOENT;
      return -1;
    }
    {
      LusAuthParent parent;
      if (!luaAP_parent(L, path, "fs:write", &parent))
        return -1;
      if (need_read && !check_canonical(L, "fs:read", parent.canonical)) {
        luaAP_closeparent(&parent);
        deny_canonical(L, "fs:read", path);
      }
      fd = openat(parent.fd, parent.leaf,
                  safe_flags | O_CREAT | O_EXCL | O_CLOEXEC, (mode_t)mode);
      if (fd >= 0) {
        luaAP_closeparent(&parent);
        if ((flags & O_TRUNC) && ftruncate(fd, 0) != 0) {
          int err = errno;
          close(fd);
          errno = err;
          return -1;
        }
        return fd;
      }
      if (errno == EEXIST && !(flags & O_EXCL)) {
        fd =
            openat(parent.fd, parent.leaf, safe_flags & ~O_CREAT, (mode_t)mode);
        if (fd >= 0 && !authorize_fd(L, fd, need_read, need_write, &denied)) {
          int lookup_error = errno;
          close(fd);
          luaAP_closeparent(&parent);
          if (denied != NULL)
            deny_canonical(L, denied, path);
          errno = lookup_error;
          return -1;
        }
      }
      {
        int err = errno;
        luaAP_closeparent(&parent);
        errno = err;
      }
      if (fd >= 0) {
        if ((flags & O_TRUNC) && ftruncate(fd, 0) != 0) {
          int err = errno;
          close(fd);
          errno = err;
          return -1;
        }
        return fd;
      }
      if (errno != ENOENT)
        return -1;
    }
  }
  errno = EAGAIN;
  return -1;
#endif
}

static int mode_flags(const char *mode, int *need_read, int *need_write) {
  int plus = strchr(mode, '+') != NULL;
  int flags;
  *need_read = (*mode == 'r' || plus);
  *need_write = (*mode != 'r' || plus);
  if (*mode == 'r')
    flags = plus ? O_RDWR : O_RDONLY;
  else if (*mode == 'w')
    flags = (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC;
  else
    flags = (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND;
  return flags | O_CLOEXEC;
}

FILE *luaAP_fopen(lua_State *L, const char *path, const char *mode) {
  int need_read;
  int need_write;
  int flags = mode_flags(mode, &need_read, &need_write);
  int fd = luaAP_open(L, path, flags, 0666, need_read, need_write);
  FILE *f;
  if (fd < 0)
    return NULL;
  f = fdopen(fd, mode);
  if (f == NULL) {
    int err = errno;
    close(fd);
    errno = err;
  }
  return f;
}

typedef struct LoadF {
  unsigned int n;
  FILE *f;
  char buff[BUFSIZ];
} LoadF;

static const char *getF(lua_State *L, void *ud, size_t *size) {
  LoadF *lf = cast(LoadF *, ud);
  UNUSED(L);
  if (lf->n > 0) {
    *size = lf->n;
    lf->n = 0;
  }
  else {
    if (feof(lf->f))
      return NULL;
    *size = fread(lf->buff, 1, sizeof(lf->buff), lf->f);
  }
  return lf->buff;
}

static int skipBOM(FILE *f) {
  int c = getc(f);
  if (c == 0xEF && getc(f) == 0xBB && getc(f) == 0xBF)
    return getc(f);
  return c;
}

static int skipcomment(FILE *f, int *cp) {
  int c = *cp = skipBOM(f);
  if (c == '#') {
    do {
      c = getc(f);
    } while (c != EOF && c != '\n');
    *cp = getc(f);
    return 1;
  }
  return 0;
}

int luaAP_loadfd(lua_State *L, int fd, const char *filename, const char *mode) {
  LoadF lf;
  int status;
  int readstatus;
  int c;
  int fnameindex = lua_gettop(L) + 1;
  int owned = dup(fd);
  if (owned < 0) {
    lua_pushfstring(L, "@%s", filename);
    lua_pushfstring(L, "cannot open %s: %s", filename, strerror(errno));
    lua_remove(L, fnameindex);
    return LUA_ERRFILE;
  }
  if (lseek(owned, 0, SEEK_SET) < 0 || (lf.f = fdopen(owned, "rb")) == NULL) {
    int err = errno;
    close(owned);
    lua_pushfstring(L, "cannot open %s: %s", filename, strerror(err));
    return LUA_ERRFILE;
  }
  lua_pushfstring(L, "@%s", filename);
  lf.n = 0;
  if (skipcomment(lf.f, &c))
    lf.buff[lf.n++] = '\n';
  if (c == LUA_SIGNATURE[0])
    lf.n = 0;
  if (c != EOF)
    lf.buff[lf.n++] = cast_char(c);
  status = lua_load(L, getF, &lf, lua_tostring(L, -1), mode);
  readstatus = ferror(lf.f);
  fclose(lf.f);
  if (readstatus) {
    lua_settop(L, fnameindex);
    lua_pushfstring(L, "cannot read %s", filename);
    lua_remove(L, fnameindex);
    return LUA_ERRFILE;
  }
  lua_remove(L, fnameindex);
  return status;
}

int luaAP_loadfile(lua_State *L, const char *filename, const char *mode) {
  int fd;
  int status;
  if (filename == NULL)
    return luaL_loadfilex(L, NULL, mode);
  fd = luaAP_open(L, filename, O_RDONLY | O_CLOEXEC, 0, 1, 0);
  if (fd < 0) {
    lua_pushfstring(L, "cannot open %s: %s", filename, strerror(errno));
    return LUA_ERRFILE;
  }
  status = luaAP_loadfd(L, fd, filename, mode);
  close(fd);
  return status;
}

int luaAP_unlink(lua_State *L, const char *path, const char *perm) {
  LusAuthFile file;
  int status;
  int result;
  int err;
  status = luaAP_trybinddelete(L, path, perm, &file);
  if (status != LUS_AUTH_OK) {
    if (status == LUS_AUTH_DENIED)
      deny_canonical(L, perm, path);
    luaAP_closeauthfile(&file);
    return 0;
  }
  result = luaAP_deleteauthfile(&file);
  err = errno;
  luaAP_closeauthfile(&file);
  errno = err;
  return result;
}

static int posix_open_move_object(const LusAuthParent *parent,
                                  const struct stat *identity) {
#if defined(O_PATH)
  if (S_ISDIR(identity->st_mode))
    return openat(parent->fd, parent->leaf,
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  return openat(parent->fd, parent->leaf, O_PATH | O_NOFOLLOW | O_CLOEXEC);
#elif defined(LUS_PLATFORM_DARWIN)
  if (S_ISLNK(identity->st_mode))
    return openat(parent->fd, parent->leaf, O_SYMLINK | O_CLOEXEC);
  if (S_ISDIR(identity->st_mode))
    return openat(parent->fd, parent->leaf,
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  return openat(parent->fd, parent->leaf, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC);
#elif defined(O_NOFOLLOW)
  UNUSED(identity);
  return openat(parent->fd, parent->leaf,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
#else
  UNUSED(parent);
  UNUSED(identity);
  errno = ENOTSUP;
  return -1;
#endif
}

int luaAP_trybinddelete(lua_State *L, const char *path, const char *perm,
                        LusAuthFile *file) {
  int tries;
  posix_authfile_init(file);
  if (!posix_parent_raw(path, &file->parent))
    return LUS_AUTH_ERROR;
  file->has_parent = 1;
  if (perm != NULL && !check_canonical(L, perm, file->parent.canonical)) {
    file->denied_perm = perm;
    return LUS_AUTH_DENIED;
  }
  for (tries = 0; tries < 3; tries++) {
    struct stat named;
    struct stat confirmed;
    struct stat retained;
    int candidate;
    if (fstatat(file->parent.fd, file->parent.leaf, &named,
                AT_SYMLINK_NOFOLLOW) != 0)
      return errno == ENOENT ? LUS_AUTH_MISSING : LUS_AUTH_ERROR;
#if defined(__EMSCRIPTEN__)
    if (emscripten_is_host_console_stat(&named)) {
      errno = EPERM;
      return LUS_AUTH_ERROR;
    }
#endif
    candidate = posix_open_move_object(&file->parent, &named);
    if (candidate >= 0) {
      if (fstat(candidate, &retained) == 0 &&
          posix_same_identity(&named, &retained)) {
        file->fd = candidate;
        file->device = cast(unsigned long long, named.st_dev);
        file->inode = cast(unsigned long long, named.st_ino);
        file->object_mode = cast_uint(named.st_mode);
        file->object_size = cast(long long, named.st_size);
        memcpy(file->canonical, file->parent.canonical,
               strlen(file->parent.canonical) + 1);
        return LUS_AUTH_OK;
      }
      close(candidate);
    }
    if (fstatat(file->parent.fd, file->parent.leaf, &confirmed,
                AT_SYMLINK_NOFOLLOW) == 0 &&
        posix_same_identity(&named, &confirmed)) {
      file->device = cast(unsigned long long, named.st_dev);
      file->inode = cast(unsigned long long, named.st_ino);
      file->object_mode = cast_uint(named.st_mode);
      file->object_size = cast(long long, named.st_size);
      memcpy(file->canonical, file->parent.canonical,
             strlen(file->parent.canonical) + 1);
      return LUS_AUTH_OK;
    }
  }
  errno = EAGAIN;
  return LUS_AUTH_ERROR;
}

int luaAP_deleteboundfd(int fd, int parent_fd, const char *leaf) {
  LusAuthFile file;
  struct stat object;
  char parent[PATH_MAX];
  size_t leaf_length;
  if (fd < 0 || parent_fd < 0 || leaf == NULL || *leaf == '\0' ||
      strchr(leaf, '/') != NULL) {
    errno = EINVAL;
    return 0;
  }
  leaf_length = strlen(leaf);
  if (leaf_length > NAME_MAX || fstat(fd, &object) != 0)
    return 0;
  posix_authfile_init(&file);
  file.fd = fd;
  file.parent.fd = parent_fd;
  memcpy(file.parent.leaf, leaf, leaf_length + 1);
  /* Deletion is descriptor-relative and does not require the retained parent
  ** to have a recoverable lexical path. Keep a best-effort path only for the
  ** diagnostic synchronization hook used by regression tests. */
  if (luaAP_fdpath(parent_fd, parent, sizeof(parent)) &&
      append_path(file.parent.canonical, sizeof(file.parent.canonical), parent,
                  leaf)) {
    memcpy(file.canonical, file.parent.canonical,
           strlen(file.parent.canonical) + 1);
  }
  else {
    memcpy(file.parent.canonical, leaf, leaf_length + 1);
    memcpy(file.canonical, leaf, leaf_length + 1);
  }
  file.device = cast(unsigned long long, object.st_dev);
  file.inode = cast(unsigned long long, object.st_ino);
  file.object_mode = cast_uint(object.st_mode);
  file.object_size = cast(long long, object.st_size);
  file.has_parent = 1;
  return luaAP_deleteauthfile(&file);
}

static int posix_move_source_matches(const LusAuthMoveSource *source) {
  struct stat named;
  struct stat retained;
  if (fstatat(source->parent.fd, source->parent.leaf, &named,
              AT_SYMLINK_NOFOLLOW) != 0)
    return 0;
  if (cast(unsigned long long, named.st_dev) != source->device ||
      cast(unsigned long long, named.st_ino) != source->inode) {
    errno = EAGAIN;
    return 0;
  }
  if (source->fd >= 0) {
    if (fstat(source->fd, &retained) != 0)
      return 0;
    if (!posix_same_identity(&named, &retained)) {
      errno = EAGAIN;
      return 0;
    }
  }
  return 1;
}

int luaAP_bindmovesource(lua_State *L, const char *path,
                         LusAuthMoveSource *source) {
  int tries;
  memset(source, 0, sizeof(*source));
  source->parent.fd = -1;
  source->fd = -1;
  if (!posix_parent_raw(path, &source->parent))
    return 0;
  if (!check_canonical(L, "fs:read", source->parent.canonical)) {
    luaAP_closemovesource(source);
    deny_canonical(L, "fs:read", path);
  }
  if (!check_canonical(L, "fs:write", source->parent.canonical)) {
    luaAP_closemovesource(source);
    deny_canonical(L, "fs:write", path);
  }
  for (tries = 0; tries < 3; tries++) {
    struct stat named;
    struct stat confirmed;
    struct stat retained;
    int candidate;
    if (fstatat(source->parent.fd, source->parent.leaf, &named,
                AT_SYMLINK_NOFOLLOW) != 0) {
      int err = errno;
      luaAP_closemovesource(source);
      errno = err;
      return 0;
    }
#if defined(__EMSCRIPTEN__)
    if (emscripten_is_host_console_stat(&named)) {
      luaAP_closemovesource(source);
      errno = EPERM;
      return 0;
    }
#endif
    candidate = posix_open_move_object(&source->parent, &named);
    if (candidate >= 0) {
      if (fstat(candidate, &retained) == 0 &&
          posix_same_identity(&named, &retained)) {
        source->fd = candidate;
        source->device = cast(unsigned long long, named.st_dev);
        source->inode = cast(unsigned long long, named.st_ino);
        source->mode = cast_uint(named.st_mode);
        return 1;
      }
      close(candidate);
    }
    /* Some POSIX object types do not have a portable nofollow open. Retain the
    ** containing directory and bind the nofollow identity twice so a swap
    ** during acquisition fails closed. */
    if (fstatat(source->parent.fd, source->parent.leaf, &confirmed,
                AT_SYMLINK_NOFOLLOW) == 0 &&
        posix_same_identity(&named, &confirmed)) {
      source->device = cast(unsigned long long, named.st_dev);
      source->inode = cast(unsigned long long, named.st_ino);
      source->mode = cast_uint(named.st_mode);
      return 1;
    }
  }
  luaAP_closemovesource(source);
  errno = EAGAIN;
  return 0;
}

int luaAP_movebound(lua_State *L, LusAuthMoveSource *source,
                    const char *destination) {
  LusAuthParent target;
  struct stat existing;
  int result;
  int err;
  if (source == NULL || source->parent.fd < 0) {
    errno = EINVAL;
    return 0;
  }
  source->denied_perm = NULL;
  if (!posix_move_source_matches(source))
    return 0;
  if (!posix_parent_raw(destination, &target))
    return 0;
  if (!check_canonical(L, "fs:write", target.canonical)) {
    source->denied_perm = "fs:write";
    luaAP_closeparent(&target);
    errno = EACCES;
    return 0;
  }
  if (fstatat(target.fd, target.leaf, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
    luaAP_closeparent(&target);
    errno = EEXIST;
    return 0;
  }
  if (errno != ENOENT) {
    err = errno;
    luaAP_closeparent(&target);
    errno = err;
    return 0;
  }
  if (!posix_move_source_matches(source)) {
    err = errno;
    luaAP_closeparent(&target);
    errno = err;
    return 0;
  }
#if defined(LUS_PLATFORM_DARWIN)
  result = renameatx_np(source->parent.fd, source->parent.leaf, target.fd,
                        target.leaf, RENAME_EXCL);
#elif defined(LUS_PLATFORM_LINUX)
  result = posix_rename_noreplace(source->parent.fd, source->parent.leaf,
                                  target.fd, target.leaf);
#elif defined(RENAME_NOREPLACE)
  result = renameat2(source->parent.fd, source->parent.leaf, target.fd,
                     target.leaf, RENAME_NOREPLACE);
#else
  result =
      renameat(source->parent.fd, source->parent.leaf, target.fd, target.leaf);
#endif
  err = errno;
  luaAP_closeparent(&target);
  errno = err;
  return result == 0;
}

void luaAP_closemovesource(LusAuthMoveSource *source) {
  int err = errno;
  if (source == NULL)
    return;
  if (source->fd >= 0)
    close(source->fd);
  if (source->parent.fd >= 0)
    luaAP_closeparent(&source->parent);
  source->fd = -1;
  source->parent.fd = -1;
  errno = err;
}
#endif

#if defined(LUS_PLATFORM_WINDOWS)
static const char *win_first_wildcard(const char *path) {
  const char *start = path;
  if (strncmp(path, "\\\\?\\", 4) == 0)
    start += 4;
  return strpbrk(start, "*?");
}
#endif

int luaAP_resolvelink(const char *path, char *resolved, size_t resolved_size) {
#if defined(LUS_PLATFORM_WINDOWS)
  WCHAR *wide;
  HANDLE handle;
  BY_HANDLE_FILE_INFORMATION info;
  char *canonical;
  size_t length;
  if (win_first_wildcard(path) != NULL)
    return 0;
  wide = win_path(path);
  if (wide == NULL)
    return 0;
  handle = CreateFileW(
      wide, FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      NULL);
  free(wide);
  if (handle == INVALID_HANDLE_VALUE)
    return 0;
  if (!GetFileInformationByHandle(handle, &info) ||
      !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    CloseHandle(handle);
    return 0;
  }
  canonical = luaAP_winhandlepath(handle);
  CloseHandle(handle);
  if (canonical == NULL)
    return 0;
  length = strlen(canonical);
  if (length >= resolved_size) {
    free(canonical);
    return 0;
  }
  memcpy(resolved, canonical, length + 1);
  free(canonical);
  return 1;
#else
  LusAuthParent parent;
  struct stat object;
  int ok;
  if (strpbrk(path, "*?") != NULL || !posix_parent_raw(path, &parent))
    return 0;
  ok = fstatat(parent.fd, parent.leaf, &object, AT_SYMLINK_NOFOLLOW) == 0 &&
       S_ISLNK(object.st_mode) && strlen(parent.canonical) < resolved_size;
  if (ok)
    memcpy(resolved, parent.canonical, strlen(parent.canonical) + 1);
  luaAP_closeparent(&parent);
  return ok;
#endif
}

int luaAP_resolvepattern(const char *pattern, char *resolved,
                         size_t resolved_size) {
#if defined(LUS_PLATFORM_WINDOWS)
  const char *wild = win_first_wildcard(pattern);
  char *canonical = NULL;
  if (wild == NULL) {
    WCHAR *wide = win_path(pattern);
    HANDLE handle = INVALID_HANDLE_VALUE;
    if (wide != NULL) {
      handle = CreateFileW(wide, FILE_READ_ATTRIBUTES,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                           OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
      free(wide);
    }
    if (handle != INVALID_HANDLE_VALUE) {
      canonical = luaAP_winhandlepath(handle);
      CloseHandle(handle);
    }
    else {
      LusAuthParent parent;
      if (GetLastError() != ERROR_FILE_NOT_FOUND &&
          GetLastError() != ERROR_PATH_NOT_FOUND)
        return 0;
      if (!win_parent_raw(pattern, &parent))
        return 0;
      canonical = parent.canonical;
      parent.canonical = NULL;
      luaAP_closeparent(&parent);
    }
  }
  else {
    const char *slash = wild;
    char *prefix;
    const char *suffix;
    size_t prefix_len;
    WCHAR *wide;
    HANDLE handle;
    char *base;
    size_t base_len;
    size_t suffix_len;
    while (slash > pattern && slash[-1] != '\\' && slash[-1] != '/')
      slash--;
    if (slash == pattern) {
      prefix = cast(char *, malloc(2));
      if (prefix != NULL)
        memcpy(prefix, ".", 2);
      suffix = pattern;
    }
    else {
      prefix_len = cast_sizet(slash - pattern);
      while (
          prefix_len > 1 &&
          (pattern[prefix_len - 1] == '\\' || pattern[prefix_len - 1] == '/') &&
          pattern[prefix_len - 2] != ':')
        prefix_len--;
      prefix = cast(char *, malloc(prefix_len + 1));
      if (prefix != NULL) {
        memcpy(prefix, pattern, prefix_len);
        prefix[prefix_len] = '\0';
      }
      suffix = pattern + prefix_len;
    }
    if (prefix == NULL)
      return 0;
    wide = win_path(prefix);
    free(prefix);
    if (wide == NULL)
      return 0;
    handle = CreateFileW(
        wide, FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS, NULL);
    free(wide);
    if (handle == INVALID_HANDLE_VALUE)
      return 0;
    base = luaAP_winhandlepath(handle);
    CloseHandle(handle);
    if (base == NULL)
      return 0;
    for (const char *part = suffix; *part != '\0';) {
      const char *end;
      while (*part == '\\' || *part == '/')
        part++;
      end = part;
      while (*end != '\0' && *end != '\\' && *end != '/')
        end++;
      if ((end - part == 1 && part[0] == '.') ||
          (end - part == 2 && part[0] == '.' && part[1] == '.')) {
        free(base);
        return 0;
      }
      part = end;
    }
    base_len = strlen(base);
    suffix_len = strlen(suffix);
    canonical = cast(char *, malloc(base_len + suffix_len + 2));
    if (canonical != NULL) {
      memcpy(canonical, base, base_len);
      if (base_len > 0 && canonical[base_len - 1] != '\\' &&
          canonical[base_len - 1] != '/' && *suffix != '\\' && *suffix != '/')
        canonical[base_len++] = '\\';
      memcpy(canonical + base_len, suffix, suffix_len + 1);
      for (char *p = canonical; *p != '\0'; p++) {
        if (*p == '/')
          *p = '\\';
      }
    }
    free(base);
  }
  if (canonical == NULL || strlen(canonical) >= resolved_size) {
    free(canonical);
    return 0;
  }
  memcpy(resolved, canonical, strlen(canonical) + 1);
  free(canonical);
  return 1;
#else
  const char *wild = strpbrk(pattern, "*?");
  char prefix[PATH_MAX];
  char canonical[PATH_MAX];
  const char *suffix;
  size_t prefix_len;
  int n;
  if (wild == NULL) {
    if (realpath(pattern, resolved) != NULL)
      return 1;
    {
      char parent[PATH_MAX];
      char leaf[NAME_MAX + 1];
      if (!split_parent(pattern, parent, sizeof(parent), leaf, sizeof(leaf)) ||
          realpath(parent, canonical) == NULL)
        return 0;
      return append_path(resolved, resolved_size, canonical, leaf);
    }
  }
  prefix_len = cast_sizet(wild - pattern);
  while (prefix_len > 0 && pattern[prefix_len - 1] != '/')
    prefix_len--;
  while (prefix_len > 0 && pattern[prefix_len - 1] == '/')
    prefix_len--;
  if (prefix_len >= sizeof(prefix))
    return 0;
  memcpy(prefix, pattern, prefix_len);
  prefix[prefix_len] = '\0';
  while (realpath(prefix_len == 0 ? "." : prefix, canonical) == NULL) {
    char *slash;
    if (prefix_len == 0)
      return 0;
    slash = strrchr(prefix, '/');
    if (slash == NULL) {
      prefix_len = 0;
      prefix[0] = '\0';
    }
    else if (slash == prefix) {
      prefix_len = 1;
      prefix[1] = '\0';
    }
    else {
      prefix_len = cast_sizet(slash - prefix);
      prefix[prefix_len] = '\0';
    }
  }
  suffix = pattern + prefix_len;
  if (strstr(suffix, "/../") != NULL || strstr(suffix, "/./") != NULL)
    return 0;
  while (*suffix == '/')
    suffix++;
  n = snprintf(resolved, resolved_size, "%s/%s", canonical, suffix);
  return n >= 0 && (size_t)n < resolved_size;
#endif
}
