/*
** $Id: lbundle.c $
** Standalone bundle support
** See Copyright Notice in lua.h
*/

#define lbundle_c
#define LUA_CORE

#include "lprefix.h"

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
#endif

#if defined(LUA_USE_WINDOWS)
#include <windows.h>
#endif

/* Global bundle pointer (used by loadlib.c searcher, set by lua.c) */
LusBundle *g_bundle = NULL;

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
  DWORD len = GetModuleFileNameA(NULL, buf, (DWORD)bufsize);
  if (len == 0 || len >= bufsize)
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
  char exepath[4096];
  FILE *f;
  unsigned char footer[8];
  long filesize;

  if (!lusB_getexepath(exepath, sizeof(exepath)))
    return 0;

  f = fopen(exepath, "rb");
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
  fclose(f);

  /* Check magic */
  if (memcmp(footer + 4, LUSB_MAGIC, LUSB_MAGIC_SIZE) != 0)
    return 0;

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

  if (!lusB_getexepath(exepath, sizeof(exepath)))
    return NULL;

  f = fopen(exepath, "rb");
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

  /* Version */
  bundle->version = *p++;
  if (bundle->version != LUSB_VERSION) {
    free(index_data);
    lusB_free(bundle);
    fclose(f);
    return NULL;
  }

  /* num_args, num_files */
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
  len = read_u16(p);
  p += 2;
  if (len >= LUSB_MAX_NAME) {
    free(index_data);
    lusB_free(bundle);
    fclose(f);
    return NULL;
  }
  memcpy(bundle->entrypoint, p, len);
  bundle->entrypoint[len] = '\0';
  p += len;

  /* args */
  for (i = 0; i < bundle->num_args; i++) {
    len = read_u16(p);
    p += 2;
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
    len = read_u16(p);
    p += 2;
    if (len >= LUSB_MAX_NAME) {
      free(index_data);
      lusB_free(bundle);
      fclose(f);
      return NULL;
    }
    memcpy(bundle->files[i].name, p, len);
    bundle->files[i].name[len] = '\0';
    p += len;

    bundle->files[i].offset = (size_t)read_u32(p);
    p += 4;
    bundle->files[i].size = (size_t)read_u32(p);
    p += 4;
  }

  free(index_data);

  /* Calculate data offset: bytecode blob starts right after original exe,
  ** which is at: filesize - 8 - index_size - total_bytecode_size
  ** We need to calculate total bytecode size from file entries
  */
  {
    size_t total_bytecode = 0;
    for (i = 0; i < bundle->num_files; i++) {
      size_t end = bundle->files[i].offset + bundle->files[i].size;
      if (end > total_bytecode)
        total_bytecode = end;
    }
    bundle->data_offset =
        (size_t)(filesize - 8 - (long)index_size - (long)total_bytecode);
  }

  fclose(f);
  return bundle;
}

/*
** Get file contents from bundle.
*/
char *lusB_getfile(LusBundle *bundle, const char *name, size_t *size) {
  FILE *f;
  char *data;
  int i;

  if (bundle == NULL || name == NULL)
    return NULL;

  /* Find file in index */
  for (i = 0; i < bundle->num_files; i++) {
    if (strcmp(bundle->files[i].name, name) == 0) {
      /* Found - read from exe */
      f = fopen(bundle->exe_path, "rb");
      if (f == NULL)
        return NULL;

      if (fseek(f, (long)(bundle->data_offset + bundle->files[i].offset),
                SEEK_SET) != 0) {
        fclose(f);
        return NULL;
      }

      data = (char *)malloc(bundle->files[i].size);
      if (data == NULL) {
        fclose(f);
        return NULL;
      }

      if (fread(data, 1, bundle->files[i].size, f) != bundle->files[i].size) {
        free(data);
        fclose(f);
        return NULL;
      }

      fclose(f);
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

  /* Calculate total size */
  total_size += 1;                      /* version */
  total_size += 2;                      /* num_args */
  total_size += 2;                      /* num_files */
  total_size += 2 + strlen(entrypoint); /* entrypoint */

  for (i = 0; i < num_args; i++) {
    total_size += 2 + strlen(args[i]);
  }

  for (i = 0; i < num_files; i++) {
    total_size += 2 + strlen(names[i]); /* name */
    total_size += 4;                    /* offset */
    total_size += 4;                    /* size */
  }

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
