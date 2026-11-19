/*
** $Id: lbundle.c $
** Standalone bundle support
** See Copyright Notice in lua.h
*/

#define lbundle_c
#define LUA_CORE

#include "lprefix.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lbundle.h"
#include "lua.h"

/* Platform-specific includes for exe path */
#if defined(LUA_USE_LINUX) || defined(LUA_USE_POSIX)
#include <limits.h>
#include <unistd.h>
#endif

#if defined(LUA_USE_MACOSX)
#include <limits.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#endif

#if defined(LUA_USE_WINDOWS)
#include <io.h>
#include <share.h>
#include <windows.h>

static FILE *win_open_self(void) {
  WCHAR path[32768];
  DWORD length = GetModuleFileNameW(NULL, path, 32768);
  if (length == 0 || length >= 32768)
    return NULL;
  return _wfsopen(path, L"rb", _SH_DENYWR);
}
#endif

/* Global bundle pointer (used by loadlib.c searcher, set by lua.c) */
LusBundle *g_bundle = NULL;

/*
** A successful probe retains the inspected executable object for lusB_load.
** This prevents a path replacement between bundle detection and parsing from
** selecting a different file.
*/
static FILE *detected_source = NULL;

/*
** Read little-endian u16
*/
static unsigned int read_u16(const unsigned char *p) {
  return (unsigned int)p[0] | ((unsigned int)p[1] << 8);
}

/*
** Read little-endian u32
*/
static unsigned long read_u32(const unsigned char *p) {
  return (unsigned long)p[0] | ((unsigned long)p[1] << 8) |
         ((unsigned long)p[2] << 16) | ((unsigned long)p[3] << 24);
}

/*
** Write little-endian u16
*/
static void write_u16(unsigned char *p, unsigned int v) {
  p[0] = (unsigned char)(v & 0xFF);
  p[1] = (unsigned char)((v >> 8) & 0xFF);
}

/*
** Write little-endian u32
*/
static void write_u32(unsigned char *p, unsigned long v) {
  p[0] = (unsigned char)(v & 0xFF);
  p[1] = (unsigned char)((v >> 8) & 0xFF);
  p[2] = (unsigned char)((v >> 16) & 0xFF);
  p[3] = (unsigned char)((v >> 24) & 0xFF);
}

/*
** Get path to currently running executable.
*/
int lusB_getexepath(char *buf, size_t bufsize) {
#if defined(LUA_USE_LINUX)
  ssize_t len = readlink("/proc/self/exe", buf, bufsize - 1);
  if (len == -1)
    return 0;
  buf[len] = '\0';
  return 1;

#elif defined(LUA_USE_MACOSX)
  uint32_t size = (uint32_t)bufsize;
  if (_NSGetExecutablePath(buf, &size) != 0)
    return 0;
  /* Resolve symlinks */
  char resolved[PATH_MAX];
  if (realpath(buf, resolved) != NULL) {
    strncpy(buf, resolved, bufsize - 1);
    buf[bufsize - 1] = '\0';
  }
  return 1;

#elif defined(LUA_USE_WINDOWS)
  WCHAR path[32768];
  DWORD length = GetModuleFileNameW(NULL, path, 32768);
  int needed;
  if (length == 0 || length >= 32768)
    return 0;
  needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1, NULL,
                               0, NULL, NULL);
  if (needed <= 0 || (size_t)needed > bufsize)
    return 0;
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1, buf, needed,
                          NULL, NULL) == 0)
    return 0;
  return 1;

#elif defined(__FreeBSD__) || defined(__DragonFly__)
  ssize_t len = readlink("/proc/curproc/file", buf, bufsize - 1);
  if (len == -1)
    return 0;
  buf[len] = '\0';
  return 1;

#elif defined(__NetBSD__)
  ssize_t len = readlink("/proc/curproc/exe", buf, bufsize - 1);
  if (len == -1)
    return 0;
  buf[len] = '\0';
  return 1;

#else
  /* Fallback: try /proc/self/exe anyway */
  ssize_t len = readlink("/proc/self/exe", buf, bufsize - 1);
  if (len == -1)
    return 0;
  buf[len] = '\0';
  return 1;
#endif
}

/*
** Detect if running executable has an embedded bundle.
** Returns 1 if bundle detected, 0 otherwise.
*/
int lusB_detect(void) {
#if !defined(LUA_USE_WINDOWS)
  char exepath[4096];
#endif
  FILE *f;
  unsigned char footer[8];
  long filesize;

  if (detected_source != NULL) {
    fclose(detected_source);
    detected_source = NULL;
  }

#if defined(LUA_USE_WINDOWS)
  f = win_open_self();
#else
  if (!lusB_getexepath(exepath, sizeof(exepath)))
    return 0;
  f = fopen(exepath, "rb");
#endif
  if (f == NULL)
    return 0;

  /* Seek to end and get file size */
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return 0;
  }
  filesize = ftell(f);
  if (filesize < 8) {
    fclose(f);
    return 0;
  }

  /* Read last 8 bytes: index_size (4) + magic (4) */
  if (fseek(f, -8, SEEK_END) != 0) {
    fclose(f);
    return 0;
  }
  if (fread(footer, 1, 8, f) != 8) {
    fclose(f);
    return 0;
  }
  /* Check magic */
  if (memcmp(footer + 4, LUSB_MAGIC, LUSB_MAGIC_SIZE) != 0) {
    fclose(f);
    return 0;
  }

  detected_source = f;
  return 1;
}

/*
** Load and parse bundle from self executable.
*/
LusBundle *lusB_load(void) {
  char exepath[4096];
  FILE *f;
  unsigned char footer[8];
  long filesize;
  unsigned long index_size;
  unsigned char *index_data;
  unsigned char *p;
  LusBundle *bundle;
  int i;
  unsigned int len;

#if defined(LUA_USE_WINDOWS)
  exepath[0] = '\0';
  (void)lusB_getexepath(exepath, sizeof(exepath));
#else
  if (!lusB_getexepath(exepath, sizeof(exepath))) {
    if (detected_source != NULL) {
      fclose(detected_source);
      detected_source = NULL;
    }
    return NULL;
  }
#endif

  if (detected_source != NULL) {
    f = detected_source;
    detected_source = NULL;
  }
  else {
#if defined(LUA_USE_WINDOWS)
    f = win_open_self();
#else
    f = fopen(exepath, "rb");
#endif
  }
  if (f == NULL)
    return NULL;

  /* Get file size */
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  filesize = ftell(f);
  if (filesize < 8) {
    fclose(f);
    return NULL;
  }

  /* Read footer */
  if (fseek(f, -8, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  if (fread(footer, 1, 8, f) != 8) {
    fclose(f);
    return NULL;
  }

  /* Verify magic */
  if (memcmp(footer + 4, LUSB_MAGIC, LUSB_MAGIC_SIZE) != 0) {
    fclose(f);
    return NULL;
  }

  /* Parse index size */
  index_size = read_u32(footer);
  if (index_size == 0 || index_size > (unsigned long)filesize - 8) {
    fclose(f);
    return NULL;
  }

  /* Allocate and read index */
  index_data = (unsigned char *)malloc(index_size);
  if (index_data == NULL) {
    fclose(f);
    return NULL;
  }

  /* Seek to index start: filesize - 8 - index_size */
  if (fseek(f, filesize - 8 - (long)index_size, SEEK_SET) != 0) {
    free(index_data);
    fclose(f);
    return NULL;
  }
  if (fread(index_data, 1, index_size, f) != index_size) {
    free(index_data);
    fclose(f);
    return NULL;
  }

  /* Allocate bundle */
  bundle = (LusBundle *)calloc(1, sizeof(LusBundle));
  if (bundle == NULL) {
    free(index_data);
    fclose(f);
    return NULL;
  }
#if defined(LUA_USE_WINDOWS)
  bundle->source_handle = INVALID_HANDLE_VALUE;
  InitializeSRWLock(&bundle->source_lock);
#else
  bundle->source_fd = -1;
#endif
  strncpy(bundle->exe_path, exepath, sizeof(bundle->exe_path) - 1);

  /* Parse index
  ** Format:
  **   version:        u8
  **   num_args:       u16 LE
  **   num_files:      u16 LE
  **   entrypoint_len: u16 LE
  **   entrypoint:     [u8; entrypoint_len]
  **   args (repeated):
  **     arg_len: u16 LE
  **     arg:     [u8; arg_len]
  **   files (repeated):
  **     name_len: u16 LE
  **     name:     [u8; name_len]
  **     offset:   u32 LE
  **     size:     u32 LE
  */
  p = index_data;
  unsigned char *end = index_data + index_size;

#define BUNDLE_CHECK(cond) \
  do {                     \
    if (!(cond)) {         \
      free(index_data);    \
      lusB_free(bundle);   \
      fclose(f);           \
      return NULL;         \
    }                      \
  } while (0)

  /* Version */
  BUNDLE_CHECK(p + 1 <= end);
  bundle->version = *p++;
  if (bundle->version != LUSB_VERSION) {
    free(index_data);
    lusB_free(bundle);
    fclose(f);
    return NULL;
  }

  /* num_args, num_files */
  BUNDLE_CHECK(p + 4 <= end);
  bundle->num_args = (int)read_u16(p);
  p += 2;
  bundle->num_files = (int)read_u16(p);
  p += 2;

  if (bundle->num_args > LUSB_MAX_ARGS || bundle->num_files > LUSB_MAX_FILES) {
    free(index_data);
    lusB_free(bundle);
    fclose(f);
    return NULL;
  }

  /* entrypoint */
  BUNDLE_CHECK(p + 2 <= end);
  len = read_u16(p);
  p += 2;
  BUNDLE_CHECK(len < LUSB_MAX_NAME && p + len <= end);
  memcpy(bundle->entrypoint, p, len);
  bundle->entrypoint[len] = '\0';
  p += len;

  /* args */
  for (i = 0; i < bundle->num_args; i++) {
    BUNDLE_CHECK(p + 2 <= end);
    len = read_u16(p);
    p += 2;
    BUNDLE_CHECK(p + len <= end);
    bundle->args[i] = (char *)malloc(len + 1);
    if (bundle->args[i] == NULL) {
      free(index_data);
      lusB_free(bundle);
      fclose(f);
      return NULL;
    }
    memcpy(bundle->args[i], p, len);
    bundle->args[i][len] = '\0';
    p += len;
  }

  /* files */
  bundle->files =
      (LusBundleFile *)calloc(bundle->num_files, sizeof(LusBundleFile));
  if (bundle->files == NULL) {
    free(index_data);
    lusB_free(bundle);
    fclose(f);
    return NULL;
  }

  for (i = 0; i < bundle->num_files; i++) {
    BUNDLE_CHECK(p + 2 <= end);
    len = read_u16(p);
    p += 2;
    BUNDLE_CHECK(len < LUSB_MAX_NAME && p + len + 8 <= end);
    memcpy(bundle->files[i].name, p, len);
    bundle->files[i].name[len] = '\0';
    p += len;

    bundle->files[i].offset = (size_t)read_u32(p);
    p += 4;
    bundle->files[i].size = (size_t)read_u32(p);
    p += 4;
  }

#undef BUNDLE_CHECK

  free(index_data);

  /* Calculate data offset: bytecode blob starts right after original exe,
  ** which is at: filesize - 8 - index_size - total_bytecode_size
  ** We need to calculate total bytecode size from file entries
  */
  {
    /* 64-bit accumulation: offset/size are attacker-controlled u32s from
       the index; their sum must not wrap on 32-bit size_t, and the blob
       plus index and footer must actually fit inside the file */
    uint64_t total_bytecode = 0;
    for (i = 0; i < bundle->num_files; i++) {
      uint64_t end =
          (uint64_t)bundle->files[i].offset + bundle->files[i].size;
      if (end > total_bytecode)
        total_bytecode = end;
    }
    if (total_bytecode + index_size + 8 > (uint64_t)filesize) {
      lusB_free(bundle);
      fclose(f);
      return NULL;
    }
    bundle->data_offset =
        (size_t)((uint64_t)filesize - 8 - index_size - total_bytecode);
  }

#if defined(LUA_USE_WINDOWS)
  {
    HANDLE current = (HANDLE)(intptr_t)_get_osfhandle(_fileno(f));
    if (current == INVALID_HANDLE_VALUE ||
        !DuplicateHandle(GetCurrentProcess(), current, GetCurrentProcess(),
                         &bundle->source_handle, GENERIC_READ, FALSE, 0)) {
      lusB_free(bundle);
      fclose(f);
      return NULL;
    }
  }
#else
  bundle->source_fd = dup(fileno(f));
  if (bundle->source_fd < 0) {
    lusB_free(bundle);
    fclose(f);
    return NULL;
  }
#endif
  fclose(f);
  return bundle;
}

/*
** Get file contents from bundle.
*/
char *lusB_getfile(LusBundle *bundle, const char *name, size_t *size) {
  char *data;
  int i;

  if (bundle == NULL || name == NULL)
    return NULL;

  /* Find file in index */
  for (i = 0; i < bundle->num_files; i++) {
    if (strcmp(bundle->files[i].name, name) == 0) {
      /* Found - read from exe */
#if defined(LUA_USE_WINDOWS)
      LARGE_INTEGER offset;
      size_t done = 0;
      DWORD error = ERROR_SUCCESS;
      if (bundle->source_handle == NULL ||
          bundle->source_handle == INVALID_HANDLE_VALUE)
        return NULL;
      data = (char *)malloc(bundle->files[i].size == 0
                                ? 1
                                : bundle->files[i].size);
      if (data == NULL)
        return NULL;
      offset.QuadPart = (LONGLONG)bundle->data_offset +
                        (LONGLONG)bundle->files[i].offset;
      AcquireSRWLockExclusive(&bundle->source_lock);
      if (!SetFilePointerEx(bundle->source_handle, offset, NULL, FILE_BEGIN))
        error = GetLastError();
      while (error == ERROR_SUCCESS && done < bundle->files[i].size) {
        DWORD request = (DWORD)(bundle->files[i].size - done > MAXDWORD
                                    ? MAXDWORD
                                    : bundle->files[i].size - done);
        DWORD got;
        if (!ReadFile(bundle->source_handle, data + done, request, &got, NULL) ||
            got == 0) {
          error = GetLastError();
          if (error == ERROR_SUCCESS)
            error = ERROR_HANDLE_EOF;
          break;
        }
        done += got;
      }
      ReleaseSRWLockExclusive(&bundle->source_lock);
      if (error != ERROR_SUCCESS) {
        free(data);
        return NULL;
      }
#else
      size_t done = 0;
      if (bundle->source_fd < 0)
        return NULL;
      data = (char *)malloc(bundle->files[i].size == 0
                                ? 1
                                : bundle->files[i].size);
      if (data == NULL)
        return NULL;
      while (done < bundle->files[i].size) {
        off_t offset = (off_t)(bundle->data_offset + bundle->files[i].offset +
                               done);
        ssize_t got = pread(bundle->source_fd, data + done,
                            bundle->files[i].size - done, offset);
        if (got < 0 && errno == EINTR)
          continue;
        if (got <= 0) {
          free(data);
          return NULL;
        }
        done += (size_t)got;
      }
#endif
      if (size)
        *size = bundle->files[i].size;
      return data;
    }
  }

  return NULL;
}

/*
** Free bundle resources.
*/
void lusB_free(LusBundle *bundle) {
  int i;
  if (bundle == NULL)
    return;

  for (i = 0; i < bundle->num_args; i++) {
    free(bundle->args[i]);
  }
  free(bundle->files);
#if defined(LUA_USE_WINDOWS)
  if (bundle->source_handle != NULL &&
      bundle->source_handle != INVALID_HANDLE_VALUE)
    CloseHandle(bundle->source_handle);
#else
  if (bundle->source_fd >= 0)
    close(bundle->source_fd);
#endif
  free(bundle);
}

/*
** Build bundle index from arrays.
** Returns allocated index buffer; caller must free.
** Sets *index_size to buffer size.
*/
unsigned char *lusB_buildindex(int version, const char *entrypoint,
                               int num_args, char **args, int num_files,
                               const char **names, size_t *offsets,
                               size_t *sizes, size_t *index_size) {
  size_t total_size = 0;
  unsigned char *buf, *p;
  int i;
  size_t len;

  if (version < 0 || version > UINT8_MAX || entrypoint == NULL ||
      index_size == NULL || num_args < 0 || num_args > LUSB_MAX_ARGS ||
      num_files < 1 || num_files > LUSB_MAX_FILES ||
      (num_args > 0 && args == NULL) || names == NULL || offsets == NULL ||
      sizes == NULL)
    return NULL;

  /* Calculate total size */
  total_size += 1; /* version */
  total_size += 2; /* num_args */
  total_size += 2; /* num_files */
  len = strlen(entrypoint);
  if (len > UINT16_MAX)
    return NULL;
  total_size += 2 + len; /* entrypoint */

  for (i = 0; i < num_args; i++) {
    if (args[i] == NULL)
      return NULL;
    len = strlen(args[i]);
    if (len > UINT16_MAX || total_size > SIZE_MAX - 2 ||
        len > SIZE_MAX - total_size - 2)
      return NULL;
    total_size += 2 + len;
  }

  for (i = 0; i < num_files; i++) {
    if (names[i] == NULL || offsets[i] > UINT32_MAX || sizes[i] > UINT32_MAX)
      return NULL;
    len = strlen(names[i]);
    if (len == 0 || len >= LUSB_MAX_NAME || total_size > SIZE_MAX - 10 ||
        len > SIZE_MAX - total_size - 10)
      return NULL;
    total_size += 2 + len; /* name */
    total_size += 4;       /* offset */
    total_size += 4;       /* size */
  }

  if (total_size > UINT32_MAX)
    return NULL;

  /* Allocate */
  buf = (unsigned char *)malloc(total_size);
  if (buf == NULL)
    return NULL;
  p = buf;

  /* Write version */
  *p++ = (unsigned char)version;

  /* Write counts */
  write_u16(p, (unsigned int)num_args);
  p += 2;
  write_u16(p, (unsigned int)num_files);
  p += 2;

  /* Write entrypoint */
  len = strlen(entrypoint);
  write_u16(p, (unsigned int)len);
  p += 2;
  memcpy(p, entrypoint, len);
  p += len;

  /* Write args */
  for (i = 0; i < num_args; i++) {
    len = strlen(args[i]);
    write_u16(p, (unsigned int)len);
    p += 2;
    memcpy(p, args[i], len);
    p += len;
  }

  /* Write files */
  for (i = 0; i < num_files; i++) {
    len = strlen(names[i]);
    write_u16(p, (unsigned int)len);
    p += 2;
    memcpy(p, names[i], len);
    p += len;
    write_u32(p, (unsigned long)offsets[i]);
    p += 4;
    write_u32(p, (unsigned long)sizes[i]);
    p += 4;
  }

  *index_size = total_size;
  return buf;
}
