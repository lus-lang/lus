/*
** lsqlitelib.c
** Embedded SQLite binding for Lus
** See Copyright Notice in lua.h
**
** Exposes io.sqlite(path [, mode]), which opens a database handle whose
** methods run statements (exec/run/query/prepare/transaction). Three
** userdata types cooperate here:
**
**   sqlite.db     : the connection. Uservalue 1 is a weak-valued registry
**                   of every live statement, so closing the database can
**                   finalize them first (SQLite requires it). Uservalue 2
**                   retains the thread whose pledge store backs its VFS.
**   sqlite.stmt   : a prepared statement. Uservalue 1 is the db userdata,
**                   which keeps the connection alive. The stmt pointer is
**                   the single owner of the sqlite3_stmt: every finalize
**                   routes through finalize_stmt so a pointer can never be
**                   finalized twice.
**   sqlite.cursor : one live iteration. Uservalue 1 is the stmt userdata.
**                   A generation counter detects statements reset while an
**                   iterator is live. db:query and stmt:query return the
**                   cursor as the generic for's closing value, so breaking
**                   out of a loop still releases the statement.
**
** Security: file-backed connections use a pledge-aware VFS that checks each
** file operation. ATTACH, VACUUM INTO, and path-changing PRAGMAs are denied
** through an authorizer. URI filenames are rejected. SQLITE_TEMP_STORE=3
** keeps temp structures in memory. ":memory:" opens with no pledge at all.
*/

#define lsqlitelib_c
#define LUA_LIB

#include "lprefix.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "sqlite3.h"

#include "lua.h"

#include "lauxlib.h"
#include "lauthpath.h"
#include "lgc.h"
#include "lobject.h"
#include "lpledge.h"
#include "lstate.h"
#include "lsqlitelib.h"
#include "lvector.h"

#define SQLITE_DB_METATABLE "sqlite.db"
#define SQLITE_STMT_METATABLE "sqlite.stmt"
#define SQLITE_CURSOR_METATABLE "sqlite.cursor"
#define SQLITE_TABLEREF_METATABLE "sqlite.tableref"

/* Private bridge between this wrapper and the bundled native VFS. This
** intentionally stays out of the installed sqlite3.h API. */
#define SQLITE_FCNTL_LUS_BOUND_SHM 0x4c530001

typedef int (*sqlite3_lus_delete_file)(sqlite3_int64 file_handle,
                                       sqlite3_int64 parent_handle,
                                       const char *leaf);

typedef struct sqlite3_lus_bound_shm {
  sqlite3_int64 file_handle;
  sqlite3_int64 parent_handle;
  sqlite3_lus_delete_file delete_file;
  int readonly;
} sqlite3_lus_bound_shm;

typedef struct LSqliteVFS LSqliteVFS;

typedef struct LSqliteFile {
  sqlite3_file base;
  sqlite3_file *real;
  LSqliteVFS *owner;
  sqlite3_filename realname;
  const char *path;
  int can_read;
  int can_write;
  int shm_read;
  int shm_write;
  int shm_bound;
  unsigned int object_mode;
} LSqliteFile;

struct LSqliteVFS {
  sqlite3_vfs vfs;
  sqlite3_vfs *real;
  lua_State *L;
  LusAuthFile main_file;
  char *name;
  char *denied_path;
  char *sidecar_path;
  const char *denied_perm;
  int readonly;
  int main_bound;
  int denied;
};

typedef struct LSqliteDB {
  sqlite3 *db; /* NULL means closed, io-style */
  LSqliteVFS *vfs;
  int readonly;
} LSqliteDB;

typedef struct LSqliteStmt {
  sqlite3_stmt *stmt; /* NULL means closed or finalized */
  LSqliteDB *db;      /* backing struct, kept valid by uservalue 1 */
  int generation;     /* bumped on every reset and finalize */
} LSqliteStmt;

typedef struct LSqliteCursor {
  LSqliteStmt *stmt; /* NULL once spent or closed */
  int generation;    /* snapshot taken when the iteration began */
  int owns;          /* 1: finalize on completion, 0: reset */
} LSqliteCursor;

typedef struct LSqliteTableRef {
  LSqliteDB *db;   /* backing struct, kept valid by uservalue 1 */
} LSqliteTableRef; /* uservalue 1: the db userdata, 2: the table name */

static LusSQLitePathHook sqlite_path_hook;
static void *sqlite_path_hook_context;

void luaS_setsqlitepathhook(LusSQLitePathHook hook, void *context) {
  sqlite_path_hook = hook;
  sqlite_path_hook_context = context;
}

static void sqlite_path_sync(const char *phase, const char *path) {
  if (sqlite_path_hook != NULL)
    sqlite_path_hook(phase, path, sqlite_path_hook_context);
}

#if !defined(LUS_PLATFORM_WINDOWS)
static int sqlite_delete_bound_file(sqlite3_int64 file_handle,
                                    sqlite3_int64 parent_handle,
                                    const char *leaf) {
  if (file_handle < 0 || file_handle > INT_MAX || parent_handle < 0 ||
      parent_handle > INT_MAX)
    return 0;
  return luaAP_deleteboundfd(cast_int(file_handle), cast_int(parent_handle),
                             leaf);
}
#endif

/* ===================================================================
** Pledge-aware VFS
** =================================================================== */

#define SQLITE_VFS_NAME_BYTES 64

static size_t sqlite_real_offset(void) {
  size_t align = _Alignof(max_align_t);
  return (sizeof(LSqliteFile) + align - 1) & ~(align - 1);
}

static LSqliteFile *sqlite_file(sqlite3_file *file) {
  return (LSqliteFile *)file;
}

static LSqliteVFS *sqlite_vfs(sqlite3_vfs *vfs) {
  return (LSqliteVFS *)vfs->pAppData;
}

static void sqlite_vfs_deny(LSqliteVFS *vfs, const char *perm,
                            const char *path) {
  vfs->denied = 1;
  vfs->denied_perm = perm;
  sqlite3_snprintf(vfs->real->mxPathname + 1, vfs->denied_path, "%s",
                   path != NULL ? path : "(temporary file)");
}

/* This is the replaceable authorization hook for SQLite. It deliberately
** performs no Lua allocation and cannot raise across SQLite's C frames. */
static int sqlite_vfs_allowed(LSqliteVFS *vfs, const char *perm,
                              const char *path) {
  if (vfs->L != NULL && path != NULL && luaP_hasfsperm(vfs->L, perm, path)) {
    vfs->denied = 0;
    return 1;
  }
  sqlite_vfs_deny(vfs, perm, path);
  return 0;
}

static const char *sqlite_auth_path(const LusAuthFile *file,
                                    const char *fallback) {
  const char *canonical = luaAP_authfilepath(file);
  if (canonical != NULL && *canonical != '\0')
    return canonical;
#if defined(LUS_PLATFORM_WINDOWS)
  if (file->has_parent && file->parent.canonical != NULL)
    return file->parent.canonical;
#else
  if (file->has_parent && file->parent.canonical[0] != '\0')
    return file->parent.canonical;
#endif
  return fallback;
}

static int sqlite_auth_status(LSqliteVFS *vfs, const LusAuthFile *file,
                              const char *path, int status) {
  if (status == LUS_AUTH_DENIED) {
    sqlite_vfs_deny(vfs,
                    file->denied_perm != NULL ? file->denied_perm : "fs:read",
                    sqlite_auth_path(file, path));
  }
  return status;
}

static int sqlite_hex_digit(char byte) {
  return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') ||
         (byte >= 'A' && byte <= 'F');
}

static int sqlite_known_sidecar(const char *suffix) {
  size_t length;
  size_t i;
  if (strcmp(suffix, "-journal") == 0 || strcmp(suffix, "-wal") == 0 ||
      strcmp(suffix, "-shm") == 0)
    return 1;
  length = strlen(suffix);
  if (length != 12 || memcmp(suffix, "-mj", 3) != 0)
    return 0;
  for (i = 3; i < length; i++) {
    if (!sqlite_hex_digit(suffix[i]))
      return 0;
  }
  return 1;
}

static int sqlite_bound_main(LSqliteVFS *vfs, const char *path) {
  const char *main_path;
  if (!vfs->main_bound || path == NULL)
    return 0;
  main_path = luaAP_authfilepath(&vfs->main_file);
  return main_path != NULL && strcmp(path, main_path) == 0;
}

static const char *sqlite_bound_suffix(LSqliteVFS *vfs, const char *path) {
  const char *main_path;
  const char *suffix;
  size_t length;
  if (!vfs->main_bound || path == NULL)
    return NULL;
  main_path = luaAP_authfilepath(&vfs->main_file);
  if (main_path == NULL)
    return NULL;
  length = strlen(main_path);
  if (strncmp(path, main_path, length) != 0)
    return NULL;
  suffix = path + length;
  return sqlite_known_sidecar(suffix) ? suffix : NULL;
}

static int sqlite_tryopen(LSqliteVFS *vfs, const char *path, int options,
                          unsigned int mode, LusAuthFile *file) {
  const char *suffix = sqlite_bound_suffix(vfs, path);
  if (sqlite_bound_main(vfs, path))
    return luaAP_tryopensibling(vfs->L, &vfs->main_file, "", path, options,
                                mode, file);
  if (suffix != NULL)
    return luaAP_tryopensibling(vfs->L, &vfs->main_file, suffix, path, options,
                                mode, file);
  return luaAP_tryopen(vfs->L, path, options, mode, file);
}

static int sqlite_bound_allowed(LSqliteVFS *vfs, const char *perm,
                                const char *path) {
  if (sqlite_bound_main(vfs, path) || sqlite_bound_suffix(vfs, path) != NULL) {
    if (vfs->L != NULL && luaP_hasfscanonical(vfs->L, perm, path)) {
      vfs->denied = 0;
      return 1;
    }
    sqlite_vfs_deny(vfs, perm, path);
    return 0;
  }
  return sqlite_vfs_allowed(vfs, perm, path);
}

static sqlite3_filename sqlite_bound_filename(const char *path,
                                              const LusAuthFile *file,
                                              int readonly_shm,
                                              int delete_unlinked) {
  const char *params[8];
  char object[32];
  int count = 0;
#if defined(LUS_PLATFORM_WINDOWS)
  snprintf(object, sizeof(object), "%lld",
           cast(long long, cast(intptr_t, file->handle)));
  params[count * 2] = "lus_bound_handle";
  params[count * 2 + 1] = object;
  count++;
#else
  char parent[32];
  snprintf(object, sizeof(object), "%d", file->fd);
  snprintf(parent, sizeof(parent), "%d", file->parent.fd);
  params[count * 2] = "lus_bound_fd";
  params[count * 2 + 1] = object;
  count++;
  params[count * 2] = "lus_bound_dirfd";
  params[count * 2 + 1] = parent;
  count++;
#endif
  if (readonly_shm) {
    params[count * 2] = "readonly_shm";
    params[count * 2 + 1] = "1";
    count++;
  }
  if (delete_unlinked) {
    params[count * 2] = "lus_delete_unlinked";
    params[count * 2 + 1] = "1";
    count++;
  }
  return sqlite3_create_filename(path, "", "", count, params);
}

static int sqlite_open_options(int flags) {
  int options = LUS_AUTH_READ;
  if ((flags & SQLITE_OPEN_READWRITE) != 0)
    options |= LUS_AUTH_WRITE;
  if ((flags & SQLITE_OPEN_CREATE) != 0)
    options |= LUS_AUTH_CREATE;
  if ((flags & SQLITE_OPEN_EXCLUSIVE) != 0)
    options |= LUS_AUTH_EXCLUSIVE;
  if ((flags & SQLITE_OPEN_DELETEONCLOSE) != 0)
    options |= LUS_AUTH_DELETE_ON_CLOSE;
  return options;
}

static const char *sqlite_sidecar(LSqliteFile *file, const char *suffix) {
  LSqliteVFS *vfs = file->owner;
  if (strlen(file->path) + strlen(suffix) > (size_t)vfs->real->mxPathname)
    return NULL;
  sqlite3_snprintf(vfs->real->mxPathname + 1, vfs->sidecar_path, "%s%s",
                   file->path, suffix);
  return vfs->sidecar_path;
}

static int sqlite_shm_allowed(LSqliteFile *file, int write) {
  int *cached = write ? &file->shm_write : &file->shm_read;
  const char *perm = write ? "fs:write" : "fs:read";
  const char *path = sqlite_sidecar(file, "-shm");
  if (*cached)
    return 1;
  if (!sqlite_bound_allowed(file->owner, perm, path))
    return 0;
  *cached = 1;
  return 1;
}

static int sqlite_io_close(sqlite3_file *file) {
  LSqliteFile *f = sqlite_file(file);
  int rc = f->real->pMethods->xClose(f->real);
  sqlite3_free_filename(f->realname);
  f->realname = NULL;
  file->pMethods = NULL;
  return rc;
}

static int sqlite_io_read(sqlite3_file *file, void *buf, int amount,
                          sqlite3_int64 offset) {
  LSqliteFile *f = sqlite_file(file);
  if (!f->can_read) {
    sqlite_vfs_deny(f->owner, "fs:read", f->path);
    memset(buf, 0, (size_t)amount);
    return SQLITE_IOERR_READ;
  }
  return f->real->pMethods->xRead(f->real, buf, amount, offset);
}

static int sqlite_io_write(sqlite3_file *file, const void *buf, int amount,
                           sqlite3_int64 offset) {
  LSqliteFile *f = sqlite_file(file);
  if (!f->can_write) {
    sqlite_vfs_deny(f->owner, "fs:write", f->path);
    return SQLITE_IOERR_WRITE;
  }
  return f->real->pMethods->xWrite(f->real, buf, amount, offset);
}

static int sqlite_io_truncate(sqlite3_file *file, sqlite3_int64 size) {
  LSqliteFile *f = sqlite_file(file);
  if (!f->can_write) {
    sqlite_vfs_deny(f->owner, "fs:write", f->path);
    return SQLITE_IOERR_TRUNCATE;
  }
  return f->real->pMethods->xTruncate(f->real, size);
}

static int sqlite_io_sync(sqlite3_file *file, int flags) {
  LSqliteFile *f = sqlite_file(file);
  if (!f->can_write) {
    sqlite_vfs_deny(f->owner, "fs:write", f->path);
    return SQLITE_IOERR_FSYNC;
  }
  return f->real->pMethods->xSync(f->real, flags);
}

static int sqlite_io_filesize(sqlite3_file *file, sqlite3_int64 *size) {
  LSqliteFile *f = sqlite_file(file);
  if (!f->can_read) {
    sqlite_vfs_deny(f->owner, "fs:read", f->path);
    return SQLITE_IOERR_FSTAT;
  }
  return f->real->pMethods->xFileSize(f->real, size);
}

static int sqlite_io_lock(sqlite3_file *file, int level) {
  LSqliteFile *f = sqlite_file(file);
  return f->real->pMethods->xLock(f->real, level);
}

static int sqlite_io_unlock(sqlite3_file *file, int level) {
  LSqliteFile *f = sqlite_file(file);
  return f->real->pMethods->xUnlock(f->real, level);
}

static int sqlite_io_reserved(sqlite3_file *file, int *out) {
  LSqliteFile *f = sqlite_file(file);
  return f->real->pMethods->xCheckReservedLock(f->real, out);
}

static int sqlite_io_control(sqlite3_file *file, int op, void *arg) {
  LSqliteFile *f = sqlite_file(file);
  if (op == SQLITE_FCNTL_SET_LOCKPROXYFILE) {
    sqlite_vfs_deny(f->owner, "fs:write", f->path);
    return SQLITE_PERM;
  }
  if ((op == SQLITE_FCNTL_SIZE_HINT || op == SQLITE_FCNTL_OVERWRITE ||
       op == SQLITE_FCNTL_BEGIN_ATOMIC_WRITE ||
       op == SQLITE_FCNTL_COMMIT_ATOMIC_WRITE ||
       op == SQLITE_FCNTL_ROLLBACK_ATOMIC_WRITE) &&
      !f->can_write) {
    sqlite_vfs_deny(f->owner, "fs:write", f->path);
    return SQLITE_PERM;
  }
  return f->real->pMethods->xFileControl(f->real, op, arg);
}

static int sqlite_io_sector(sqlite3_file *file) {
  LSqliteFile *f = sqlite_file(file);
  return f->real->pMethods->xSectorSize(f->real);
}

static int sqlite_io_characteristics(sqlite3_file *file) {
  LSqliteFile *f = sqlite_file(file);
  return f->real->pMethods->xDeviceCharacteristics(f->real);
}

static int sqlite_bind_shm(LSqliteFile *file) {
  LSqliteVFS *owner = file->owner;
  LusAuthFile auth;
  sqlite3_lus_bound_shm bound;
  const char *path = sqlite_sidecar(file, "-shm");
  int options = LUS_AUTH_READ;
  int status;
  int rc;
  if (file->shm_bound)
    return SQLITE_OK;
  if (path == NULL)
    return SQLITE_CANTOPEN;
  if (!owner->readonly)
    options |= LUS_AUTH_WRITE | LUS_AUTH_CREATE | LUS_AUTH_DELETE;
  status = sqlite_tryopen(
      owner, path, options,
      file->object_mode != 0 ? file->object_mode & 0777u : 0666u, &auth);
  sqlite_auth_status(owner, &auth, path, status);
  if (status != LUS_AUTH_OK) {
    if (owner->readonly && status == LUS_AUTH_MISSING)
      sqlite_vfs_deny(owner, "fs:write", sqlite_auth_path(&auth, path));
    luaAP_closeauthfile(&auth);
    return status == LUS_AUTH_DENIED || status == LUS_AUTH_MISSING
               ? SQLITE_PERM
               : SQLITE_CANTOPEN;
  }
  sqlite_path_sync("shm", path);
#if defined(LUS_PLATFORM_WINDOWS)
  bound.file_handle = cast(sqlite3_int64, cast(intptr_t, auth.handle));
  bound.parent_handle = 0;
  bound.delete_file = NULL;
#else
  bound.file_handle = auth.fd;
  bound.parent_handle = auth.parent.fd;
  bound.delete_file = sqlite_delete_bound_file;
#endif
  bound.readonly = owner->readonly;
  rc = file->real->pMethods->xFileControl(file->real,
                                          SQLITE_FCNTL_LUS_BOUND_SHM, &bound);
  if (rc != SQLITE_OK && auth.created)
    luaAP_deleteauthfile(&auth);
  luaAP_closeauthfile(&auth);
  if (rc == SQLITE_OK)
    file->shm_bound = 1;
  return rc;
}

static int sqlite_io_shmmap(sqlite3_file *file, int page, int pagesize,
                            int write, void volatile **out) {
  LSqliteFile *f = sqlite_file(file);
  int rc;
  if (f->real->pMethods->iVersion < 2 || f->real->pMethods->xShmMap == NULL)
    return SQLITE_IOERR_SHMMAP;
  if (!sqlite_shm_allowed(f, 0))
    return SQLITE_IOERR_SHMMAP;
  if (write && f->owner->readonly) {
    sqlite_vfs_deny(f->owner, "fs:write", sqlite_sidecar(f, "-shm"));
    return SQLITE_READONLY;
  }
  if (!f->owner->readonly && !sqlite_shm_allowed(f, 1))
    return SQLITE_IOERR_SHMMAP;
  if (sqlite_bind_shm(f) != SQLITE_OK)
    return SQLITE_IOERR_SHMOPEN;
  rc = f->real->pMethods->xShmMap(f->real, page, pagesize, write, out);
  sqlite_path_sync("shm-opened", f->path);
  return rc;
}

static int sqlite_io_shmlock(sqlite3_file *file, int offset, int count,
                             int flags) {
  LSqliteFile *f = sqlite_file(file);
  if (f->owner->readonly && (flags & SQLITE_SHM_LOCK) != 0 &&
      (flags & SQLITE_SHM_EXCLUSIVE) != 0) {
    sqlite_vfs_deny(f->owner, "fs:write", sqlite_sidecar(f, "-shm"));
    return SQLITE_READONLY;
  }
  if (!sqlite_shm_allowed(f, 0) ||
      (!f->owner->readonly && !sqlite_shm_allowed(f, 1)))
    return SQLITE_IOERR_SHMLOCK;
  if (sqlite_bind_shm(f) != SQLITE_OK)
    return SQLITE_IOERR_SHMOPEN;
  if (f->real->pMethods->iVersion < 2 || f->real->pMethods->xShmLock == NULL)
    return SQLITE_IOERR_SHMLOCK;
  return f->real->pMethods->xShmLock(f->real, offset, count, flags);
}

static void sqlite_io_shmbarrier(sqlite3_file *file) {
  LSqliteFile *f = sqlite_file(file);
  if (f->real->pMethods->iVersion >= 2 &&
      f->real->pMethods->xShmBarrier != NULL)
    f->real->pMethods->xShmBarrier(f->real);
}

static int sqlite_io_shmunmap(sqlite3_file *file, int remove) {
  LSqliteFile *f = sqlite_file(file);
  if (remove && !sqlite_shm_allowed(f, 1))
    return SQLITE_IOERR_SHMOPEN;
  if (f->real->pMethods->iVersion < 2 || f->real->pMethods->xShmUnmap == NULL)
    return SQLITE_IOERR_SHMOPEN;
  return f->real->pMethods->xShmUnmap(f->real, remove);
}

static int sqlite_io_fetch(sqlite3_file *file, sqlite3_int64 offset, int amount,
                           void **out) {
  LSqliteFile *f = sqlite_file(file);
  if (!f->can_read) {
    sqlite_vfs_deny(f->owner, "fs:read", f->path);
    return SQLITE_IOERR_READ;
  }
  if (f->real->pMethods->iVersion < 3 || f->real->pMethods->xFetch == NULL) {
    *out = NULL;
    return SQLITE_OK;
  }
  return f->real->pMethods->xFetch(f->real, offset, amount, out);
}

static int sqlite_io_unfetch(sqlite3_file *file, sqlite3_int64 offset,
                             void *ptr) {
  LSqliteFile *f = sqlite_file(file);
  if (f->real->pMethods->iVersion < 3 || f->real->pMethods->xUnfetch == NULL)
    return SQLITE_OK;
  return f->real->pMethods->xUnfetch(f->real, offset, ptr);
}

static const sqlite3_io_methods sqlite_io_methods = {
    3,
    sqlite_io_close,
    sqlite_io_read,
    sqlite_io_write,
    sqlite_io_truncate,
    sqlite_io_sync,
    sqlite_io_filesize,
    sqlite_io_lock,
    sqlite_io_unlock,
    sqlite_io_reserved,
    sqlite_io_control,
    sqlite_io_sector,
    sqlite_io_characteristics,
    sqlite_io_shmmap,
    sqlite_io_shmlock,
    sqlite_io_shmbarrier,
    sqlite_io_shmunmap,
    sqlite_io_fetch,
    sqlite_io_unfetch,
};

static int sqlite_vfs_open(sqlite3_vfs *vfs, const char *path,
                           sqlite3_file *file, int flags, int *outflags) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  LSqliteFile *f = sqlite_file(file);
  LusAuthFile auth;
  size_t offset = sqlite_real_offset();
  int realflags = flags;
  int options;
  int status;
  int delete_unlinked = 0;
  const char *canonical;
  const char *phase = "open";
  int rc;
  memset(f, 0, sizeof(*f));
  f->real = (sqlite3_file *)((char *)file + offset);
  f->owner = owner;
  f->path = (const char *)f->real + owner->real->szOsFile;
  if (path == NULL) {
    sqlite_vfs_deny(owner, "fs:read", NULL);
    return SQLITE_CANTOPEN;
  }

  /* A reader may consume an existing WAL through a read-only descriptor.
  ** Creation and every writable descriptor remain write-gated. */
  if (owner->readonly && (flags & SQLITE_OPEN_WAL)) {
    realflags &=
        ~(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE);
    realflags |= SQLITE_OPEN_READONLY;
  }
  options = sqlite_open_options(realflags);
  status = sqlite_tryopen(owner, path, options, 0666, &auth);
  sqlite_auth_status(owner, &auth, path, status);
  if (status == LUS_AUTH_ERROR && (realflags & SQLITE_OPEN_READWRITE) != 0 &&
      (realflags & SQLITE_OPEN_EXCLUSIVE) == 0) {
    luaAP_closeauthfile(&auth);
    realflags &= ~(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    realflags |= SQLITE_OPEN_READONLY;
    status = sqlite_tryopen(owner, path, LUS_AUTH_READ, 0, &auth);
    sqlite_auth_status(owner, &auth, path, status);
  }
  if (status != LUS_AUTH_OK) {
    if (owner->readonly && (flags & SQLITE_OPEN_WAL) != 0 &&
        status == LUS_AUTH_MISSING)
      sqlite_vfs_deny(owner, "fs:write", sqlite_auth_path(&auth, path));
    luaAP_closeauthfile(&auth);
    return status == LUS_AUTH_DENIED ? SQLITE_PERM : SQLITE_CANTOPEN;
  }
  canonical = luaAP_authfilepath(&auth);
  if (canonical == NULL ||
      strlen(canonical) > (size_t)owner->real->mxPathname) {
    rc = canonical == NULL ? SQLITE_CANTOPEN : SQLITE_CANTOPEN_FULLPATH;
    if (auth.created)
      luaAP_deleteauthfile(&auth);
    luaAP_closeauthfile(&auth);
    return rc;
  }
  sqlite3_snprintf(owner->real->mxPathname + 1, (char *)f->path, "%s",
                   canonical);
  if ((flags & SQLITE_OPEN_MAIN_DB) != 0)
    phase = "main";
  else if ((flags & SQLITE_OPEN_WAL) != 0)
    phase = "wal";
  else if ((flags & (SQLITE_OPEN_MAIN_JOURNAL | SQLITE_OPEN_SUPER_JOURNAL)) !=
           0)
    phase = "journal";
  sqlite_path_sync(phase, path);
#if !defined(LUS_PLATFORM_WINDOWS)
  if ((flags & SQLITE_OPEN_DELETEONCLOSE) != 0) {
    if (!luaAP_deleteauthfile(&auth)) {
      luaAP_closeauthfile(&auth);
      return SQLITE_IOERR_DELETE;
    }
    delete_unlinked = 1;
  }
#endif
  f->realname = sqlite_bound_filename(
      f->path, &auth, owner->readonly && (flags & SQLITE_OPEN_MAIN_DB) != 0,
      delete_unlinked);
  if (f->realname == NULL) {
    if (auth.created && !delete_unlinked)
      luaAP_deleteauthfile(&auth);
    luaAP_closeauthfile(&auth);
    return SQLITE_NOMEM;
  }
  f->can_read = 1;
  f->can_write = (realflags & SQLITE_OPEN_READWRITE) != 0;
  f->object_mode = auth.object_mode;
  realflags |= SQLITE_OPEN_URI;
  memset(f->real, 0, (size_t)owner->real->szOsFile);
  rc = owner->real->xOpen(owner->real, f->realname, f->real, realflags,
                          outflags);
  if (rc == SQLITE_OK) {
    file->pMethods = &sqlite_io_methods;
    if (strcmp(phase, "main") == 0) {
      if (!owner->main_bound) {
        luaAP_moveauthfile(&owner->main_file, &auth);
        owner->main_bound = 1;
      }
      sqlite_path_sync("main-opened", path);
    }
    else if (strcmp(phase, "wal") == 0)
      sqlite_path_sync("wal-opened", path);
    else if (strcmp(phase, "journal") == 0)
      sqlite_path_sync("journal-opened", path);
  }
  else {
    if (auth.created && !delete_unlinked)
      luaAP_deleteauthfile(&auth);
    sqlite3_free_filename(f->realname);
    f->realname = NULL;
  }
  luaAP_closeauthfile(&auth);
  return rc;
}

static int sqlite_vfs_delete(sqlite3_vfs *vfs, const char *path, int syncdir) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  LusAuthFile auth;
  int status = sqlite_tryopen(owner, path, LUS_AUTH_DELETE, 0, &auth);
  sqlite_auth_status(owner, &auth, path, status);
  if (status == LUS_AUTH_MISSING) {
    luaAP_closeauthfile(&auth);
    return SQLITE_IOERR_DELETE_NOENT;
  }
  if (status != LUS_AUTH_OK) {
    luaAP_closeauthfile(&auth);
    return status == LUS_AUTH_DENIED ? SQLITE_PERM : SQLITE_IOERR_DELETE;
  }
  sqlite_path_sync("delete", path);
  if (!luaAP_deleteauthfile(&auth)) {
    luaAP_closeauthfile(&auth);
    return SQLITE_IOERR_DELETE;
  }
  sqlite_path_sync("delete-done", path);
  if (syncdir && !luaAP_syncauthparent(&auth)) {
    luaAP_closeauthfile(&auth);
    return SQLITE_IOERR_DIR_FSYNC;
  }
  luaAP_closeauthfile(&auth);
  return SQLITE_OK;
}

static int sqlite_vfs_access(sqlite3_vfs *vfs, const char *path, int flags,
                             int *out) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  LusAuthFile auth;
  int options = LUS_AUTH_READ;
  int status;
  if (flags == SQLITE_ACCESS_READWRITE)
    options |= LUS_AUTH_WRITE;
  status = sqlite_tryopen(owner, path, options, 0, &auth);
  sqlite_auth_status(owner, &auth, path, status);
  if (status == LUS_AUTH_DENIED) {
    *out = 0;
    luaAP_closeauthfile(&auth);
    return SQLITE_PERM;
  }
  if (status == LUS_AUTH_MISSING || status == LUS_AUTH_ERROR) {
    *out = 0;
    luaAP_closeauthfile(&auth);
    return SQLITE_OK;
  }
  *out = 1;
  luaAP_closeauthfile(&auth);
  return SQLITE_OK;
}

static int sqlite_vfs_fullpath(sqlite3_vfs *vfs, const char *path, int bytes,
                               char *out) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  LusAuthFile auth;
  const char *canonical;
  int status = sqlite_tryopen(owner, path, LUS_AUTH_READ, 0, &auth);
  sqlite_auth_status(owner, &auth, path, status);
  if (status != LUS_AUTH_OK && status != LUS_AUTH_MISSING) {
    luaAP_closeauthfile(&auth);
    return status == LUS_AUTH_DENIED ? SQLITE_PERM : SQLITE_CANTOPEN;
  }
  canonical = sqlite_auth_path(&auth, path);
  if (strlen(canonical) >= cast_sizet(bytes)) {
    luaAP_closeauthfile(&auth);
    return SQLITE_CANTOPEN_FULLPATH;
  }
  sqlite3_snprintf(bytes, out, "%s", canonical);
  luaAP_closeauthfile(&auth);
  return SQLITE_OK;
}

static void *sqlite_vfs_dlopen(sqlite3_vfs *vfs, const char *path) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  if (!sqlite_vfs_allowed(owner, "fs:read", path))
    return NULL;
  return owner->real->xDlOpen(owner->real, path);
}

static void sqlite_vfs_dlerror(sqlite3_vfs *vfs, int bytes, char *out) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  owner->real->xDlError(owner->real, bytes, out);
}

static void (*sqlite_vfs_dlsym(sqlite3_vfs *vfs, void *handle,
                               const char *symbol))(void) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  return owner->real->xDlSym(owner->real, handle, symbol);
}

static void sqlite_vfs_dlclose(sqlite3_vfs *vfs, void *handle) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  owner->real->xDlClose(owner->real, handle);
}

static int sqlite_vfs_random(sqlite3_vfs *vfs, int bytes, char *out) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  return owner->real->xRandomness(owner->real, bytes, out);
}

static int sqlite_vfs_sleep(sqlite3_vfs *vfs, int micros) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  return owner->real->xSleep(owner->real, micros);
}

static int sqlite_vfs_time(sqlite3_vfs *vfs, double *out) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  return owner->real->xCurrentTime(owner->real, out);
}

static int sqlite_vfs_lasterror(sqlite3_vfs *vfs, int bytes, char *out) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  if (owner->denied) {
    sqlite3_snprintf(bytes, out, "permission %s denied for '%s'",
                     owner->denied_perm, owner->denied_path);
    return SQLITE_PERM;
  }
  if (owner->real->xGetLastError != NULL)
    return owner->real->xGetLastError(owner->real, bytes, out);
  return 0;
}

static int sqlite_vfs_time64(sqlite3_vfs *vfs, sqlite3_int64 *out) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  if (owner->real->iVersion >= 2 && owner->real->xCurrentTimeInt64 != NULL)
    return owner->real->xCurrentTimeInt64(owner->real, out);
  return SQLITE_NOTFOUND;
}

static int sqlite_vfs_setcall(sqlite3_vfs *vfs, const char *name,
                              sqlite3_syscall_ptr call) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  if (owner->real->iVersion >= 3 && owner->real->xSetSystemCall != NULL)
    return owner->real->xSetSystemCall(owner->real, name, call);
  return SQLITE_NOTFOUND;
}

static sqlite3_syscall_ptr sqlite_vfs_getcall(sqlite3_vfs *vfs,
                                              const char *name) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  if (owner->real->iVersion >= 3 && owner->real->xGetSystemCall != NULL)
    return owner->real->xGetSystemCall(owner->real, name);
  return NULL;
}

static const char *sqlite_vfs_nextcall(sqlite3_vfs *vfs, const char *name) {
  LSqliteVFS *owner = sqlite_vfs(vfs);
  if (owner->real->iVersion >= 3 && owner->real->xNextSystemCall != NULL)
    return owner->real->xNextSystemCall(owner->real, name);
  return NULL;
}

static LSqliteVFS *sqlite_vfs_create(lua_State *L, int readonly) {
#if defined(LUS_PLATFORM_WINDOWS)
  sqlite3_vfs *real = sqlite3_vfs_find(NULL);
#elif defined(LUS_PLATFORM_DARWIN)
  sqlite3_vfs *real = sqlite3_vfs_find("unix-posix");
#else
  sqlite3_vfs *real = sqlite3_vfs_find("unix");
#endif
  LSqliteVFS *vfs;
  size_t realoff = sqlite_real_offset();
  size_t filebytes;
  size_t pathbytes;
  if (real == NULL || real->mxPathname < 1)
    return NULL;
  pathbytes = (size_t)real->mxPathname + 1;
  if (realoff > (size_t)INT_MAX || pathbytes > (size_t)INT_MAX - realoff ||
      (size_t)real->szOsFile > (size_t)INT_MAX - realoff - pathbytes)
    return NULL;
  filebytes = realoff + (size_t)real->szOsFile + pathbytes;
  vfs = (LSqliteVFS *)sqlite3_malloc64(sizeof(*vfs));
  if (vfs == NULL)
    return NULL;
  memset(vfs, 0, sizeof(*vfs));
  vfs->name = (char *)sqlite3_malloc64(SQLITE_VFS_NAME_BYTES);
  vfs->denied_path = (char *)sqlite3_malloc64(pathbytes);
  vfs->sidecar_path = (char *)sqlite3_malloc64(pathbytes);
  if (vfs->name == NULL || vfs->denied_path == NULL ||
      vfs->sidecar_path == NULL) {
    sqlite3_free(vfs->name);
    sqlite3_free(vfs->denied_path);
    sqlite3_free(vfs->sidecar_path);
    sqlite3_free(vfs);
    return NULL;
  }
  vfs->real = real;
  vfs->L = L;
  vfs->readonly = readonly;
  sqlite3_snprintf(SQLITE_VFS_NAME_BYTES, vfs->name, "lus-pledge-%p",
                   (void *)vfs);
  vfs->vfs.iVersion = real->iVersion > 3 ? 3 : real->iVersion;
  vfs->vfs.szOsFile = (int)filebytes;
  vfs->vfs.mxPathname = real->mxPathname;
  vfs->vfs.zName = vfs->name;
  vfs->vfs.pAppData = vfs;
  vfs->vfs.xOpen = sqlite_vfs_open;
  vfs->vfs.xDelete = sqlite_vfs_delete;
  vfs->vfs.xAccess = sqlite_vfs_access;
  vfs->vfs.xFullPathname = sqlite_vfs_fullpath;
  vfs->vfs.xDlOpen = sqlite_vfs_dlopen;
  vfs->vfs.xDlError = sqlite_vfs_dlerror;
  vfs->vfs.xDlSym = sqlite_vfs_dlsym;
  vfs->vfs.xDlClose = sqlite_vfs_dlclose;
  vfs->vfs.xRandomness = sqlite_vfs_random;
  vfs->vfs.xSleep = sqlite_vfs_sleep;
  vfs->vfs.xCurrentTime = sqlite_vfs_time;
  vfs->vfs.xGetLastError = sqlite_vfs_lasterror;
  vfs->vfs.xCurrentTimeInt64 = sqlite_vfs_time64;
  vfs->vfs.xSetSystemCall = sqlite_vfs_setcall;
  vfs->vfs.xGetSystemCall = sqlite_vfs_getcall;
  vfs->vfs.xNextSystemCall = sqlite_vfs_nextcall;
  if (sqlite3_vfs_register(&vfs->vfs, 0) != SQLITE_OK) {
    sqlite3_free(vfs->name);
    sqlite3_free(vfs->denied_path);
    sqlite3_free(vfs->sidecar_path);
    sqlite3_free(vfs);
    return NULL;
  }
  return vfs;
}

static void sqlite_vfs_destroy(LSqliteVFS *vfs) {
  if (vfs == NULL)
    return;
  sqlite3_vfs_unregister(&vfs->vfs);
  if (vfs->main_bound)
    luaAP_closeauthfile(&vfs->main_file);
  sqlite3_free(vfs->name);
  sqlite3_free(vfs->denied_path);
  sqlite3_free(vfs->sidecar_path);
  sqlite3_free(vfs);
}

/* ===================================================================
** Handle checking
** =================================================================== */

/*
** Paths and SQL must be actual strings. The usual number-to-string
** coercion would turn io.sqlite(42) into a database named "42".
*/
static const char *checkstring_strict(lua_State *L, int idx) {
  luaL_checktype(L, idx, LUA_TSTRING);
  return lua_tostring(L, idx);
}

static LSqliteDB *checkdb(lua_State *L) {
  LSqliteDB *d = (LSqliteDB *)luaL_checkudata(L, 1, SQLITE_DB_METATABLE);
  if (l_unlikely(d->db == NULL))
    luaL_error(L, "attempt to use a closed database");
  return d;
}

static LSqliteStmt *checkstmt(lua_State *L) {
  LSqliteStmt *s = (LSqliteStmt *)luaL_checkudata(L, 1, SQLITE_STMT_METATABLE);
  if (l_unlikely(s->stmt == NULL))
    luaL_error(L, "attempt to use a closed statement");
  if (l_unlikely(s->db->db == NULL))
    luaL_error(L, "attempt to use a closed database");
  return s;
}

static void sqlite_push_error(lua_State *L, LSqliteDB *d,
                              const char *fallback) {
  if (d->vfs != NULL && d->vfs->denied) {
    lua_pushfstring(L, "permission \"%s\" denied for '%s'", d->vfs->denied_perm,
                    d->vfs->denied_path);
    d->vfs->denied = 0;
  }
  else
    lua_pushstring(L, fallback);
}

/*
** The single owner of every sqlite3_stmt. Nulling the pointer and bumping
** the generation here is what makes the close/GC/cursor interleavings
** safe: any other holder checks the NULL sentinel before touching it.
*/
static void finalize_stmt(LSqliteStmt *s) {
  if (s->stmt != NULL) {
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
    s->generation++;
  }
}

/* ===================================================================
** Opening and closing
** =================================================================== */

/*
** Deny ATTACH with a filename, which also covers the VACUUM INTO target.
** Both would open files the pledge sweep never saw. A nameless attach is
** how plain VACUUM builds its temp database, which SQLITE_TEMP_STORE=3
** keeps in memory, so it stays allowed. The callback only returns a
** code, so it can never longjmp across SQLite frames.
*/
static int sqlite_auth(void *ud, int action, const char *a3, const char *a4,
                       const char *a5, const char *a6) {
  (void)ud;
  (void)a4;
  (void)a5;
  (void)a6;
  if (action == SQLITE_ATTACH && a3 != NULL && a3[0] != '\0')
    return SQLITE_DENY;
  if (action == SQLITE_PRAGMA && a3 != NULL &&
      (sqlite3_stricmp(a3, "data_store_directory") == 0 ||
       sqlite3_stricmp(a3, "temp_store_directory") == 0 ||
       sqlite3_stricmp(a3, "lock_proxy_file") == 0))
    return SQLITE_DENY;
  return SQLITE_OK;
}

/*
** Check the requested database itself before entering SQLite. The VFS checks
** each sidecar when SQLite actually accesses it, so unused paths need no
** speculative grant.
*/
static void sqlite_checkfsperm(lua_State *L, const char *path, int readonly) {
  lus_checkfsperm(L, "fs:read", path);
  if (!readonly)
    lus_checkfsperm(L, "fs:write", path);
}

/*
** Drain the weak statement registry (uservalue 1 of the db userdata at
** 'idx'), finalize every live statement, then close the connection.
*/
static void close_db(lua_State *L, LSqliteDB *d, int idx) {
  sqlite3_stmt *stmt;
  int rc;
  if (lua_getiuservalue(L, idx, 1) == LUA_TTABLE) {
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
      LSqliteStmt *s = (LSqliteStmt *)lua_touserdata(L, -1);
      if (s != NULL)
        finalize_stmt(s);
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  /* Embedders can prepare statements through lus_tosqlite. Closing a Lus
  ** database invalidates the connection, so finalize any such unregistered
  ** statements before freeing the per-connection VFS. */
  while ((stmt = sqlite3_next_stmt(d->db, NULL)) != NULL)
    sqlite3_finalize(stmt);
  rc = sqlite3_close(d->db);
  if (rc != SQLITE_OK) {
    /* An outstanding embedding operation can keep the SQLite connection in a
    ** zombie state after close_v2. Detach it from the Lua state so later VFS
    ** callbacks fail closed. The wrapper stays registered because SQLite may
    ** still hold its address. */
    if (d->vfs != NULL)
      d->vfs->L = NULL;
    sqlite3_close_v2(d->db);
    d->db = NULL;
    d->vfs = NULL;
    return;
  }
  d->db = NULL;
  sqlite_vfs_destroy(d->vfs);
  d->vfs = NULL;
}

static int db_close(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  close_db(L, d, 1);
  lua_pushboolean(L, 1);
  return 1;
}

/* Tolerant variant bound to both __gc and __close */
static int db_gc(lua_State *L) {
  LSqliteDB *d = (LSqliteDB *)luaL_checkudata(L, 1, SQLITE_DB_METATABLE);
  if (d->db != NULL)
    close_db(L, d, 1);
  return 0;
}

static int db_tostring(lua_State *L) {
  LSqliteDB *d = (LSqliteDB *)luaL_checkudata(L, 1, SQLITE_DB_METATABLE);
  if (d->db == NULL)
    lua_pushliteral(L, "database (closed)");
  else
    lua_pushfstring(L, "database (%p)", (void *)d->db);
  return 1;
}

static int io_sqlite(lua_State *L) {
  const char *path = checkstring_strict(L, 1);
  const char *mode = luaL_optstring(L, 2, "rw");
  LSqliteDB *d;
  sqlite3 *db = NULL;
  int readonly, in_memory, rc;
  int flags;
  if (strcmp(mode, "r") == 0)
    readonly = 1;
  else {
    luaL_argcheck(L, strcmp(mode, "rw") == 0, 2, "invalid mode");
    readonly = 0;
  }
  flags = readonly ? SQLITE_OPEN_READONLY
                   : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
  luaL_argcheck(L, *path != '\0', 1, "empty database path");
  luaL_argcheck(L, strncmp(path, "file:", 5) != 0, 1,
                "URI filenames are not supported");
  in_memory = (strcmp(path, ":memory:") == 0);
  if (!in_memory)
    sqlite_checkfsperm(L, path, readonly);
  /* create a closed handle first, so a raise leaves a consistent state */
  d = (LSqliteDB *)lua_newuserdatauv(L, sizeof(LSqliteDB), 2);
  d->db = NULL;
  d->vfs = NULL;
  d->readonly = readonly;
  luaL_setmetatable(L, SQLITE_DB_METATABLE);
  lua_createtable(L, 0, 0); /* the statement registry, weak-valued */
  lua_createtable(L, 0, 1);
  lua_pushliteral(L, "v");
  lua_setfield(L, -2, "__mode");
  lua_setmetatable(L, -2);
  lua_setiuservalue(L, -2, 1);
  lua_pushthread(L);
  lua_setiuservalue(L, -2, 2);
  if (!in_memory) {
    d->vfs = sqlite_vfs_create(L, readonly);
    if (d->vfs == NULL)
      return luaL_error(L, "cannot create pledge-aware SQLite VFS");
  }
  rc = sqlite3_open_v2(path, &db, flags,
                       d->vfs != NULL ? d->vfs->vfs.zName : NULL);
  if (rc != SQLITE_OK) {
    if (d->vfs != NULL && d->vfs->denied)
      sqlite_push_error(L, d, sqlite3_errstr(rc));
    else
      lua_pushfstring(L, "cannot open database '%s' (%s)", path,
                      db != NULL ? sqlite3_errmsg(db) : sqlite3_errstr(rc));
    sqlite3_close(db);
    sqlite_vfs_destroy(d->vfs);
    d->vfs = NULL;
    return lua_error(L);
  }
  d->db = db;
  sqlite3_set_authorizer(db, sqlite_auth, NULL);
  sqlite3_busy_timeout(db, 5000);
  if (!in_memory && !readonly) {
    /* the acquis promises WAL reader/writer concurrency for file-backed
       databases; a corrupt or non-SQLite file also surfaces here */
    char *errmsg = NULL;
    if (sqlite3_exec(db, "PRAGMA journal_mode=WAL", NULL, NULL, &errmsg) !=
        SQLITE_OK) {
      if (d->vfs != NULL && d->vfs->denied)
        sqlite_push_error(L, d, errmsg != NULL ? errmsg : sqlite3_errmsg(db));
      else
        lua_pushfstring(L, "cannot open database '%s' (%s)", path,
                        errmsg != NULL ? errmsg : sqlite3_errmsg(db));
      sqlite3_free(errmsg);
      close_db(L, d, -1);
      return lua_error(L);
    }
  }
  return 1;
}

/* ===================================================================
** Statement preparation and binding
** =================================================================== */

/*
** Wrap a raw sqlite3_stmt in a statement userdata anchored to the db
** userdata at 'dbidx', and register it in the db's weak registry so
** db:close can finalize it. Pushes the userdata and returns its struct.
*/
static LSqliteStmt *new_stmt(lua_State *L, int dbidx, sqlite3_stmt *stmt) {
  LSqliteStmt *s;
  dbidx = lua_absindex(L, dbidx);
  s = (LSqliteStmt *)lua_newuserdatauv(L, sizeof(LSqliteStmt), 1);
  s->db = (LSqliteDB *)lua_touserdata(L, dbidx);
  s->generation = 0;
  s->stmt = stmt;
  luaL_setmetatable(L, SQLITE_STMT_METATABLE);
  lua_pushvalue(L, dbidx);
  lua_setiuservalue(L, -2, 1);
  lua_getiuservalue(L, dbidx, 1); /* the weak statement registry */
  lua_pushlightuserdata(L, (void *)s);
  lua_pushvalue(L, -3);
  lua_rawset(L, -3);
  lua_pop(L, 1);
  return s;
}

/*
** Prepare exactly one statement from 'sql', wrap it, push the userdata,
** and return its struct. The tail after the first statement may hold
** only whitespace and SQL comments, which is checked by preparing it:
** a tail that yields another statement (or fails to parse) raises.
*/
static LSqliteStmt *prepare_single(lua_State *L, LSqliteDB *d, const char *sql,
                                   int dbidx) {
  sqlite3_stmt *stmt = NULL;
  const char *tail = NULL;
  if (sqlite3_prepare_v2(d->db, sql, -1, &stmt, &tail) != SQLITE_OK) {
    sqlite_push_error(L, d, sqlite3_errmsg(d->db));
    lua_error(L);
  }
  if (stmt == NULL) /* comment- or whitespace-only sql */
    luaL_error(L, "sql contains no statement");
  if (tail != NULL && *tail != '\0') {
    sqlite3_stmt *rest = NULL;
    int rc = sqlite3_prepare_v2(d->db, tail, -1, &rest, NULL);
    if (rest != NULL || rc != SQLITE_OK) {
      sqlite3_finalize(rest);
      sqlite3_finalize(stmt);
      luaL_error(L, "sql contains more than one statement");
    }
  }
  return new_stmt(L, dbidx, stmt);
}

/*
** Bind the value at 'argidx' to parameter 'pidx'. The statement is
** already owned by a userdata, so raising here leaks nothing.
*/
static void bind_one(lua_State *L, LSqliteStmt *s, int pidx, int argidx) {
  int rc;
  switch (lua_type(L, argidx)) {
    case LUA_TNIL: rc = sqlite3_bind_null(s->stmt, pidx); break;
    case LUA_TBOOLEAN:
      rc = sqlite3_bind_int64(s->stmt, pidx, lua_toboolean(L, argidx));
      break;
    case LUA_TNUMBER:
      if (lua_isinteger(L, argidx))
        rc = sqlite3_bind_int64(s->stmt, pidx,
                                (sqlite3_int64)lua_tointeger(L, argidx));
      else
        rc = sqlite3_bind_double(s->stmt, pidx, lua_tonumber(L, argidx));
      break;
    case LUA_TSTRING: {
      size_t len;
      const char *v = lua_tolstring(L, argidx, &len);
      rc = sqlite3_bind_text64(s->stmt, pidx, v, (sqlite3_uint64)len,
                               SQLITE_TRANSIENT, SQLITE_UTF8);
      break;
    }
    case LUA_TVECTOR: {
      /* a NULL data pointer would bind NULL, so a zero-length blob
         binds through a non-NULL dummy pointer instead */
      Vector *v = vecvalue(s2v(L->ci->func.p + argidx));
      const void *data =
          (v->len > 0) ? (const void *)v->data : (const void *)"";
      rc = sqlite3_bind_blob64(s->stmt, pidx, data, (sqlite3_uint64)v->len,
                               SQLITE_TRANSIENT);
      break;
    }
    default:
      rc = 0;
      luaL_error(L, "cannot bind %s value to parameter %d",
                 luaL_typename(L, argidx), pidx);
  }
  if (rc != SQLITE_OK)
    luaL_error(L, "%s", sqlite3_errmsg(s->db->db));
}

/*
** Bind every parameter of the statement from the stack slice
** [firstarg, lastarg]. Named parameters (:name, @name, $name) bind from
** a single table argument, positional '?' parameters bind from the
** values in order, and the two styles never mix.
*/
static void bind_values(lua_State *L, LSqliteStmt *s, int firstarg,
                        int lastarg) {
  int np = sqlite3_bind_parameter_count(s->stmt);
  int named = 0, positional = 0;
  int i;
  int nvals = lastarg - firstarg + 1;
  if (nvals < 0)
    nvals = 0;
  for (i = 1; i <= np; i++) {
    const char *name = sqlite3_bind_parameter_name(s->stmt, i);
    if (name == NULL)
      positional = 1;
    else if (name[0] == '?')
      luaL_error(L, "numbered parameters are not supported");
    else
      named = 1;
  }
  if (named && positional)
    luaL_error(L, "statement mixes named and positional parameters");
  if (named) {
    if (nvals != 1 || !lua_istable(L, firstarg))
      luaL_error(L, "statement uses named parameters, but no table was given");
    for (i = 1; i <= np; i++) {
      const char *name = sqlite3_bind_parameter_name(s->stmt, i);
      lua_getfield(L, firstarg, name + 1); /* skip the sigil */
      if (lua_isnil(L, -1))
        luaL_error(L, "no value for parameter '%s'", name);
      bind_one(L, s, i, lua_gettop(L));
      lua_pop(L, 1);
    }
  }
  else {
    if (np > 0 && nvals == 1 && lua_istable(L, firstarg))
      luaL_error(L, "statement uses positional parameters, but a table "
                    "was given");
    if (nvals != np)
      luaL_error(L, "statement has %d parameters, but %d values were given", np,
                 nvals);
    for (i = 1; i <= np; i++)
      bind_one(L, s, i, firstarg + i - 1);
  }
}

/* Step a statement to completion, discarding any rows */
static void run_to_completion(lua_State *L, LSqliteStmt *s) {
  int rc;
  while ((rc = sqlite3_step(s->stmt)) == SQLITE_ROW) {}
  if (rc != SQLITE_DONE) {
    sqlite_push_error(L, s->db, sqlite3_errmsg(s->db->db));
    sqlite3_reset(s->stmt);
    lua_error(L);
  }
}

/* ===================================================================
** Query iteration
** =================================================================== */

/* Push the current row as a table keyed by column name */
static void push_row(lua_State *L, LSqliteStmt *s) {
  sqlite3_stmt *stmt = s->stmt;
  int ncols = sqlite3_column_count(stmt);
  int i;
  luaL_checkstack(L, 4, "sqlite row");
  lua_createtable(L, 0, ncols);
  for (i = 0; i < ncols; i++) {
    switch (sqlite3_column_type(stmt, i)) {
      case SQLITE_INTEGER:
        lua_pushinteger(L, (lua_Integer)sqlite3_column_int64(stmt, i));
        break;
      case SQLITE_FLOAT:
        lua_pushnumber(L, (lua_Number)sqlite3_column_double(stmt, i));
        break;
      case SQLITE_TEXT:
        lua_pushlstring(L, (const char *)sqlite3_column_text(stmt, i),
                        (size_t)sqlite3_column_bytes(stmt, i));
        break;
      case SQLITE_BLOB: {
        size_t len = (size_t)sqlite3_column_bytes(stmt, i);
        const void *data = sqlite3_column_blob(stmt, i);
        Vector *v = luaV_newvec(L, len, 1);
        if (len > 0) /* no allocation between the vector's creation and here */
          memcpy(v->data, data, len);
        setvecvalue(L, s2v(L->top.p), v);
        L->top.p++;
        break;
      }
      default: /* SQLITE_NULL: the key is simply absent */ continue;
    }
    lua_setfield(L, -2, sqlite3_column_name(stmt, i));
  }
}

static int query_iter(lua_State *L) {
  LSqliteCursor *cur = (LSqliteCursor *)lua_touserdata(L, lua_upvalueindex(1));
  LSqliteStmt *s = cur->stmt;
  int rc;
  if (s == NULL) { /* spent cursor keeps returning nil */
    lua_pushnil(L);
    return 1;
  }
  if (s->stmt == NULL)
    return luaL_error(L, "attempt to use a closed statement");
  if (s->db->db == NULL)
    return luaL_error(L, "attempt to use a closed database");
  if (cur->generation != s->generation)
    return luaL_error(L, "statement was reset during iteration");
  rc = sqlite3_step(s->stmt);
  if (rc == SQLITE_ROW) {
    push_row(L, s);
    return 1;
  }
  cur->stmt = NULL;
  if (rc == SQLITE_DONE) {
    if (cur->owns)
      finalize_stmt(s);
    else
      sqlite3_reset(s->stmt);
    lua_pushnil(L);
    return 1;
  }
  sqlite_push_error(L, s->db, sqlite3_errmsg(s->db->db));
  if (cur->owns)
    finalize_stmt(s);
  else
    sqlite3_reset(s->stmt);
  return lua_error(L);
}

/*
** Build the iteration quadruple (iter, nil, nil, cursor) over the
** statement userdata at 'stmtidx'. The cursor doubles as the generic
** for's closing value, so early exits release the statement.
*/
static int make_query(lua_State *L, int stmtidx, int owns) {
  LSqliteStmt *s;
  LSqliteCursor *cur;
  stmtidx = lua_absindex(L, stmtidx);
  s = (LSqliteStmt *)lua_touserdata(L, stmtidx);
  cur = (LSqliteCursor *)lua_newuserdatauv(L, sizeof(LSqliteCursor), 1);
  cur->stmt = NULL;
  cur->generation = 0;
  cur->owns = owns;
  luaL_setmetatable(L, SQLITE_CURSOR_METATABLE);
  lua_pushvalue(L, stmtidx);
  lua_setiuservalue(L, -2, 1);
  cur->stmt = s;
  cur->generation = s->generation;
  lua_pushvalue(L, -1);
  lua_pushcclosure(L, query_iter, 1);
  lua_pushnil(L);
  lua_pushnil(L);
  lua_pushvalue(L, -4);
  return 4;
}

/*
** Close a cursor: finalize (db:query) or reset (stmt:query) the
** underlying statement, unless it was already finalized or reused.
** Tolerant by design, since this backs __close and __gc.
*/
static int cursor_close(lua_State *L) {
  LSqliteCursor *cur =
      (LSqliteCursor *)luaL_checkudata(L, 1, SQLITE_CURSOR_METATABLE);
  LSqliteStmt *s = cur->stmt;
  if (s != NULL) {
    cur->stmt = NULL;
    if (s->stmt != NULL && cur->generation == s->generation) {
      if (cur->owns)
        finalize_stmt(s);
      else
        sqlite3_reset(s->stmt);
    }
  }
  return 0;
}

/* ===================================================================
** Database methods
** =================================================================== */

static int db_exec(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  const char *sql = checkstring_strict(L, 2);
  char *errmsg = NULL;
  if (sqlite3_exec(d->db, sql, NULL, NULL, &errmsg) != SQLITE_OK) {
    sqlite_push_error(L, d, errmsg != NULL ? errmsg : sqlite3_errmsg(d->db));
    sqlite3_free(errmsg);
    return lua_error(L);
  }
  return 0;
}

static int db_run(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  const char *sql = checkstring_strict(L, 2);
  int lastarg = lua_gettop(L);
  LSqliteStmt *s = prepare_single(L, d, sql, 1);
  bind_values(L, s, 3, lastarg);
  run_to_completion(L, s);
  finalize_stmt(s);
  lua_pushinteger(L, (lua_Integer)sqlite3_changes64(d->db));
  lua_pushinteger(L, (lua_Integer)sqlite3_last_insert_rowid(d->db));
  return 2;
}

static int db_query(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  const char *sql = checkstring_strict(L, 2);
  int lastarg = lua_gettop(L);
  LSqliteStmt *s = prepare_single(L, d, sql, 1);
  bind_values(L, s, 3, lastarg);
  return make_query(L, lua_gettop(L), 1);
}

static int db_prepare(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  const char *sql = checkstring_strict(L, 2);
  prepare_single(L, d, sql, 1);
  return 1;
}

static int db_transaction(lua_State *L) {
  LSqliteDB *d = checkdb(L);
  char *errmsg = NULL;
  int status;
  luaL_checktype(L, 2, LUA_TFUNCTION);
  lua_settop(L, 2);
  if (sqlite3_exec(d->db, "BEGIN", NULL, NULL, &errmsg) != SQLITE_OK) {
    sqlite_push_error(L, d, errmsg != NULL ? errmsg : sqlite3_errmsg(d->db));
    sqlite3_free(errmsg);
    return lua_error(L);
  }
  lua_pushvalue(L, 2);
  status = lua_pcall(L, 0, LUA_MULTRET, 0);
  if (d->db == NULL)
    return luaL_error(L, "database closed during transaction");
  if (status == LUA_OK) {
    if (sqlite3_exec(d->db, "COMMIT", NULL, NULL, &errmsg) != SQLITE_OK) {
      sqlite_push_error(L, d, errmsg != NULL ? errmsg : sqlite3_errmsg(d->db));
      sqlite3_free(errmsg);
      sqlite3_exec(d->db, "ROLLBACK", NULL, NULL, NULL);
      return lua_error(L);
    }
    return lua_gettop(L) - 2; /* everything fn returned */
  }
  else {
    sqlite3_exec(d->db, "ROLLBACK", NULL, NULL, NULL);
    return lua_error(L); /* rethrow fn's error value, already on top */
  }
}

/* ===================================================================
** Statement methods
** =================================================================== */

/* Reset for re-execution, invalidating any live iterator */
static void stmt_rearm(LSqliteStmt *s) {
  sqlite3_reset(s->stmt);
  sqlite3_clear_bindings(s->stmt);
  s->generation++;
}

static int stmt_run(lua_State *L) {
  LSqliteStmt *s = checkstmt(L);
  stmt_rearm(s);
  bind_values(L, s, 2, lua_gettop(L));
  run_to_completion(L, s);
  sqlite3_reset(s->stmt);
  lua_pushinteger(L, (lua_Integer)sqlite3_changes64(s->db->db));
  lua_pushinteger(L, (lua_Integer)sqlite3_last_insert_rowid(s->db->db));
  return 2;
}

static int stmt_query(lua_State *L) {
  LSqliteStmt *s = checkstmt(L);
  stmt_rearm(s);
  bind_values(L, s, 2, lua_gettop(L));
  return make_query(L, 1, 0);
}

static int stmt_close(lua_State *L) {
  LSqliteStmt *s = checkstmt(L);
  finalize_stmt(s);
  lua_pushboolean(L, 1);
  return 1;
}

/* Tolerant variant bound to both __gc and __close */
static int stmt_gc(lua_State *L) {
  LSqliteStmt *s = (LSqliteStmt *)luaL_checkudata(L, 1, SQLITE_STMT_METATABLE);
  finalize_stmt(s);
  return 0;
}

static int stmt_tostring(lua_State *L) {
  LSqliteStmt *s = (LSqliteStmt *)luaL_checkudata(L, 1, SQLITE_STMT_METATABLE);
  if (s->stmt == NULL)
    lua_pushliteral(L, "statement (closed)");
  else
    lua_pushfstring(L, "statement (%p)", (void *)s->stmt);
  return 1;
}

/* ===================================================================
** Table references and the query provider
**
** Indexing a database handle with a key that is not a method yields a
** table reference, the query source for that table. The provider
** below translates accepted conjuncts into a parameterized SELECT and
** streams the rows back through the shared cursor machinery, so every
** value still travels as a bound parameter.
**
** The provider only accepts shapes whose semantics are identical in
** SQL and in the in-memory engine: comparisons over columns, nil,
** numeric and string operands, combined with and/or, plus +, -, *,
** unary minus, and concatenation. Booleans, not, division, and host
** closures stay residual, since their SQL semantics would diverge.
** =================================================================== */

static int sqlite_expr_ok(lua_State *L, const lus_Query *q,
                          const lus_QueryNode *n) {
  switch (lus_qnodekind(n)) {
    case LUS_QN_COLUMN: return 1;
    case LUS_QN_LIT:
    case LUS_QN_PARAM: {
      int t;
      lus_qnodevalue(L, q, n);
      t = lua_type(L, -1);
      lua_pop(L, 1);
      return t == LUA_TNIL || t == LUA_TNUMBER || t == LUA_TSTRING;
    }
    case LUS_QN_ARITH: {
      int op = lus_qnodeop(n);
      if (op != LUS_QAR_ADD && op != LUS_QAR_SUB && op != LUS_QAR_MUL &&
          op != LUS_QAR_UNM)
        return 0; /* SQL integer division and friends diverge */
      if (!sqlite_expr_ok(L, q, lus_qnodechild(q, n, 0)))
        return 0;
      return op == LUS_QAR_UNM || sqlite_expr_ok(L, q, lus_qnodechild(q, n, 1));
    }
    case LUS_QN_CONCAT:
      return sqlite_expr_ok(L, q, lus_qnodechild(q, n, 0)) &&
             sqlite_expr_ok(L, q, lus_qnodechild(q, n, 1));
    default: return 0;
  }
}

static int sqlite_bool_ok(lua_State *L, const lus_Query *q,
                          const lus_QueryNode *n) {
  switch (lus_qnodekind(n)) {
    case LUS_QN_CMP:
      return sqlite_expr_ok(L, q, lus_qnodechild(q, n, 0)) &&
             sqlite_expr_ok(L, q, lus_qnodechild(q, n, 1));
    case LUS_QN_AND:
    case LUS_QN_OR:
      return sqlite_bool_ok(L, q, lus_qnodechild(q, n, 0)) &&
             sqlite_bool_ok(L, q, lus_qnodechild(q, n, 1));
    default: return 0;
  }
}

static int sqlite_accepts(lua_State *L, const lus_Query *q,
                          const lus_QueryNode *n) {
  return sqlite_bool_ok(L, q, n);
}

/* append a double-quoted SQL identifier, doubling interior quotes */
static void addident(luaL_Buffer *b, const char *s, size_t len) {
  size_t i;
  luaL_addchar(b, '"');
  for (i = 0; i < len; i++) {
    if (s[i] == '"')
      luaL_addchar(b, '"');
    luaL_addchar(b, s[i]);
  }
  luaL_addchar(b, '"');
}

#define SQLITE_MAXBINDS 200

typedef struct SqliteGen {
  const lus_QueryNode *binds[SQLITE_MAXBINDS];
  int nbinds;
} SqliteGen;

static void gen_expr(lua_State *L, luaL_Buffer *b, const lus_Query *q,
                     const lus_QueryNode *n, SqliteGen *g) {
  switch (lus_qnodekind(n)) {
    case LUS_QN_COLUMN: {
      size_t len = 0;
      const char *s = lus_qnodename(q, n, &len);
      addident(b, s, len);
      break;
    }
    case LUS_QN_LIT:
    case LUS_QN_PARAM:
      if (g->nbinds >= SQLITE_MAXBINDS)
        luaL_error(L, "query too complex");
      g->binds[g->nbinds++] = n;
      luaL_addchar(b, '?');
      break;
    case LUS_QN_CMP: {
      static const char *const ops[] = {" = ",  " <> ", " < ",
                                        " <= ", " > ",  " >= "};
      luaL_addchar(b, '(');
      gen_expr(L, b, q, lus_qnodechild(q, n, 0), g);
      luaL_addstring(b, ops[lus_qnodeop(n)]);
      gen_expr(L, b, q, lus_qnodechild(q, n, 1), g);
      luaL_addchar(b, ')');
      break;
    }
    case LUS_QN_AND:
    case LUS_QN_OR:
      luaL_addchar(b, '(');
      gen_expr(L, b, q, lus_qnodechild(q, n, 0), g);
      luaL_addstring(b, lus_qnodekind(n) == LUS_QN_AND ? " AND " : " OR ");
      gen_expr(L, b, q, lus_qnodechild(q, n, 1), g);
      luaL_addchar(b, ')');
      break;
    case LUS_QN_ARITH: {
      int op = lus_qnodeop(n);
      luaL_addchar(b, '(');
      if (op == LUS_QAR_UNM) {
        luaL_addchar(b, '-');
        gen_expr(L, b, q, lus_qnodechild(q, n, 0), g);
      }
      else {
        gen_expr(L, b, q, lus_qnodechild(q, n, 0), g);
        luaL_addstring(b, op == LUS_QAR_ADD   ? " + "
                          : op == LUS_QAR_SUB ? " - "
                                              : " * ");
        gen_expr(L, b, q, lus_qnodechild(q, n, 1), g);
      }
      luaL_addchar(b, ')');
      break;
    }
    case LUS_QN_CONCAT:
      luaL_addchar(b, '(');
      gen_expr(L, b, q, lus_qnodechild(q, n, 0), g);
      luaL_addstring(b, " || ");
      gen_expr(L, b, q, lus_qnodechild(q, n, 1), g);
      luaL_addchar(b, ')');
      break;
    default: luaL_error(L, "unsupported node in a pushed conjunct");
  }
}

static void sqlite_open(lua_State *L, const lus_Query *q, int srcindex,
                        const lus_QueryNode *const *pushed, int npushed) {
  LSqliteTableRef *t;
  LSqliteStmt *s;
  SqliteGen g;
  luaL_Buffer b;
  const char *sql;
  int refidx, dbidx;
  int i;
  g.nbinds = 0;
  lus_querysource(L, q, srcindex - 1);
  refidx = lua_gettop(L);
  t = (LSqliteTableRef *)luaL_checkudata(L, refidx, SQLITE_TABLEREF_METATABLE);
  if (t->db->db == NULL)
    luaL_error(L, "attempt to use a closed database");
  lua_getiuservalue(L, refidx, 1); /* the db userdata, for anchoring */
  dbidx = lua_gettop(L);
  luaL_buffinit(L, &b);
  luaL_addstring(&b, "SELECT * FROM ");
  lua_getiuservalue(L, refidx, 2); /* the table name */
  {
    size_t len;
    const char *name = lua_tolstring(L, -1, &len);
    addident(&b, name, len);
    lua_pop(L, 1);
  }
  for (i = 0; i < npushed; i++) {
    luaL_addstring(&b, i == 0 ? " WHERE " : " AND ");
    gen_expr(L, &b, q, pushed[i], &g);
  }
  luaL_pushresult(&b);
  sql = lua_tostring(L, -1);
  s = prepare_single(L, t->db, sql, dbidx);
  for (i = 0; i < g.nbinds; i++) {
    lus_qnodevalue(L, (lus_Query *)q, g.binds[i]);
    bind_one(L, s, i + 1, lua_gettop(L));
    lua_pop(L, 1);
  }
  make_query(L, lua_gettop(L), 1); /* (iter, nil, nil, cursor) */
  lua_pop(L, 3);                   /* only the iterator is needed */
  /* clear everything below it off the stack */
  lua_replace(L, refidx);
  lua_settop(L, refidx);
}

static const lus_QueryProvider sqlite_provider = {sqlite_accepts, sqlite_open};

static int tableref_tostring(lua_State *L) {
  luaL_checkudata(L, 1, SQLITE_TABLEREF_METATABLE);
  lua_getiuservalue(L, 1, 2);
  lua_pushfstring(L, "table reference (%s)", lua_tostring(L, -1));
  return 1;
}

/*
** __index of the database handle: methods win, and any other string
** key yields a table reference for use as a query source.
*/
static int db_index(lua_State *L) {
  LSqliteDB *d;
  LSqliteTableRef *t;
  lua_pushvalue(L, 2);
  lua_rawget(L, lua_upvalueindex(1)); /* the method table */
  if (!lua_isnil(L, -1))
    return 1;
  lua_pop(L, 1);
  d = (LSqliteDB *)luaL_checkudata(L, 1, SQLITE_DB_METATABLE);
  if (lua_type(L, 2) != LUA_TSTRING) {
    lua_pushnil(L);
    return 1;
  }
  if (d->db == NULL)
    luaL_error(L, "attempt to use a closed database");
  t = (LSqliteTableRef *)lua_newuserdatauv(L, sizeof(LSqliteTableRef), 2);
  t->db = d;
  luaL_setmetatable(L, SQLITE_TABLEREF_METATABLE);
  lua_pushvalue(L, 1);
  lua_setiuservalue(L, -2, 1);
  lua_pushvalue(L, 2);
  lua_setiuservalue(L, -2, 2);
  return 1;
}

/* ===================================================================
** Registration
** =================================================================== */

LUA_API void *lus_tosqlite(lua_State *L, int idx) {
  LSqliteDB *d = (LSqliteDB *)luaL_testudata(L, idx, SQLITE_DB_METATABLE);
  return d != NULL ? (void *)d->db : NULL;
}

static const luaL_Reg db_meth[] = {{"exec", db_exec},
                                   {"run", db_run},
                                   {"query", db_query},
                                   {"prepare", db_prepare},
                                   {"transaction", db_transaction},
                                   {"close", db_close},
                                   {NULL, NULL}};

static const luaL_Reg db_metameth[] = {{"__gc", db_gc},
                                       {"__close", db_gc},
                                       {"__tostring", db_tostring},
                                       {NULL, NULL}};

static const luaL_Reg stmt_meth[] = {{"run", stmt_run},
                                     {"query", stmt_query},
                                     {"close", stmt_close},
                                     {NULL, NULL}};

static const luaL_Reg stmt_metameth[] = {{"__gc", stmt_gc},
                                         {"__close", stmt_gc},
                                         {"__tostring", stmt_tostring},
                                         {NULL, NULL}};

static const luaL_Reg cursor_metameth[] = {
    {"__gc", cursor_close}, {"__close", cursor_close}, {NULL, NULL}};

static void make_meta(lua_State *L, const char *name, const luaL_Reg *methods,
                      const luaL_Reg *meta) {
  luaL_newmetatable(L, name);
  luaL_setfuncs(L, meta, 0);
  if (methods != NULL) {
    lua_newtable(L);
    luaL_setfuncs(L, methods, 0);
    lua_setfield(L, -2, "__index");
  }
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable"); /* hide the metatable */
  lua_pop(L, 1);
}

/*
** Called from luaopen_io with the io table on the stack top. SQLite has
** a single entry point, so it lives alongside io.open instead of owning
** a module table of its own.
*/
void lus_sqlite_register(lua_State *L) {
  if (sqlite3_initialize() != SQLITE_OK) /* required by SQLITE_OMIT_AUTOINIT */
    luaL_error(L, "cannot initialize sqlite");
  /* the db metatable indexes methods first and table references after */
  luaL_newmetatable(L, SQLITE_DB_METATABLE);
  luaL_setfuncs(L, db_metameth, 0);
  lua_newtable(L);
  luaL_setfuncs(L, db_meth, 0);
  lua_pushcclosure(L, db_index, 1);
  lua_setfield(L, -2, "__index");
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable"); /* hide the metatable */
  lua_pop(L, 1);
  make_meta(L, SQLITE_STMT_METATABLE, stmt_meth, stmt_metameth);
  make_meta(L, SQLITE_CURSOR_METATABLE, NULL, cursor_metameth);
  /* table references carry the native query provider */
  luaL_newmetatable(L, SQLITE_TABLEREF_METATABLE);
  lua_pushcfunction(L, tableref_tostring);
  lua_setfield(L, -2, "__tostring");
  lus_setqueryprovider(L, -1, &sqlite_provider);
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable");
  lua_pop(L, 1);
  lua_pushcfunction(L, io_sqlite);
  lua_setfield(L, -2, "sqlite");
}
