/*
** H2: lus_tosqlite and embedding behavior of the SQLite binding.
**
** Verifies that lus_tosqlite hands back the live sqlite3 connection
** (proven by writing through it directly and reading the row back from
** the Lus side), returns NULL for every non-database value including
** the nearest-miss statement userdata, respects closed handles, that
** pledge gating applies to io.sqlite from an embedded state, and that
** lua_close with live handles shuts down cleanly.
*/

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <direct.h>
#include <process.h>
#include <windows.h>
#else
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "sqlite3.h"

#include "lua.h"

#include "lauthpath.h"
#include "lauxlib.h"
#include "lpledge.h"
#include "lsqlitelib.h"
#include "lualib.h"

static int fail(const char *what, const char *detail) {
  fprintf(stderr, "FAIL: %s%s%s\n", what, detail ? ": " : "",
          detail ? detail : "");
  return 1;
}

typedef struct FileSnapshot {
  unsigned char *data;
  size_t size;
  int exists;
} FileSnapshot;

static int make_sidecar_path(char *out, size_t outsize, const char *dbpath,
                             const char *suffix) {
  int n = snprintf(out, outsize, "%s%s", dbpath, suffix);
  return n >= 0 && (size_t)n < outsize;
}

static void remove_database(const char *dbpath) {
  static const char *const suffixes[] = {"", "-wal", "-shm", "-journal"};
  char path[512];
  size_t i;
  for (i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); i++) {
    if (make_sidecar_path(path, sizeof(path), dbpath, suffixes[i]))
      remove(path);
  }
}

static int snapshot_file(const char *path, FileSnapshot *snapshot) {
  FILE *file;
  long length;
  memset(snapshot, 0, sizeof(*snapshot));
  errno = 0;
  file = fopen(path, "rb");
  if (file == NULL)
    return errno == ENOENT;
  snapshot->exists = 1;
  if (fseek(file, 0, SEEK_END) != 0 || (length = ftell(file)) < 0 ||
      fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return 0;
  }
  snapshot->size = (size_t)length;
  if (snapshot->size != 0) {
    snapshot->data = (unsigned char *)malloc(snapshot->size);
    if (snapshot->data == NULL ||
        fread(snapshot->data, 1, snapshot->size, file) != snapshot->size) {
      free(snapshot->data);
      snapshot->data = NULL;
      fclose(file);
      return 0;
    }
  }
  if (fclose(file) != 0) {
    free(snapshot->data);
    snapshot->data = NULL;
    return 0;
  }
  return 1;
}

static int snapshots_equal(const FileSnapshot *before,
                           const FileSnapshot *after) {
  return before->exists == after->exists && before->size == after->size &&
         (before->size == 0 ||
          memcmp(before->data, after->data, before->size) == 0);
}

static void free_snapshot(FileSnapshot *snapshot) {
  free(snapshot->data);
  snapshot->data = NULL;
}

static int write_bytes(const char *path, const void *data, size_t size) {
  FILE *file = fopen(path, "wb");
  int ok;
  if (file == NULL)
    return 0;
  ok = fwrite(data, 1, size, file) == size;
  if (fclose(file) != 0)
    ok = 0;
  return ok;
}

/*
** Commit a WAL transaction and terminate without closing the connection.
** The parent process can then exercise recovery against the exact sidecars a
** crashed process leaves behind.
*/
static int crash_wal_writer(const char *dbpath) {
  sqlite3 *db = NULL;
  char *errmsg = NULL;
  int rc;
  if (sqlite3_initialize() != SQLITE_OK)
    return fail("child SQLite initialization", NULL);
  rc = sqlite3_open_v2(dbpath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                       NULL);
  if (rc != SQLITE_OK)
    return fail("child WAL open", db != NULL ? sqlite3_errmsg(db) : NULL);
  rc = sqlite3_exec(db,
                    "PRAGMA journal_mode=WAL;"
                    "PRAGMA wal_autocheckpoint=0;"
                    "CREATE TABLE t (n INTEGER);"
                    "INSERT INTO t VALUES (7)",
                    NULL, NULL, &errmsg);
  if (rc != SQLITE_OK) {
    int result =
        fail("child WAL write", errmsg != NULL ? errmsg : sqlite3_errmsg(db));
    sqlite3_free(errmsg);
    sqlite3_close(db);
    return result;
  }
  _Exit(EXIT_SUCCESS);
}

static int run_crash_wal_writer(const char *program, const char *dbpath) {
#ifdef _WIN32
  return _spawnl(_P_WAIT, program, program, "--crash-wal-writer", dbpath,
                 NULL) == 0;
#else
  pid_t child = fork();
  pid_t waited;
  int status;
  if (child < 0)
    return 0;
  if (child == 0) {
    execl(program, program, "--crash-wal-writer", dbpath, (char *)NULL);
    _exit(127);
  }
  do {
    waited = waitpid(child, &status, 0);
  } while (waited < 0 && errno == EINTR);
  return waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
#endif
}

static int read_wal_with_pledge(const char *dbpath, int require_row,
                                int require_write_denial) {
  lua_State *reader = luaL_newstate();
  int status;
  if (reader == NULL)
    return 0;
  luaL_openlibs(reader);
  lua_pushstring(reader, dbpath);
  lua_setglobal(reader, "H2_SQLITE_PATH");
  if (require_write_denial) {
    status = luaL_dostring(
        reader, "pledge('fs:read=./h2_sqlite_*', 'seal')\n"
                "local db <close> = io.sqlite(H2_SQLITE_PATH, 'r')\n"
                "local function read_row()\n"
                "    for _ in db:query('SELECT n FROM t') do end\n"
                "end\n"
                "local ok, err = catch read_row()\n"
                "assert(not ok, 'missing SHM read unexpectedly succeeded')\n"
                "assert(string.find(tostring(err), "
                "'permission \"fs:write\" denied', 1, true), tostring(err))");
  } else if (require_row) {
    status = luaL_dostring(
        reader, "pledge('fs:read=./h2_sqlite_*', 'seal')\n"
                "local db <close> = io.sqlite(H2_SQLITE_PATH, 'r')\n"
                "local n\n"
                "for row in db:query('SELECT n FROM t') do n = row.n end\n"
                "assert(n == 7)");
  } else {
    status = luaL_dostring(reader,
                           "pledge('fs:read=./h2_sqlite_*', 'seal')\n"
                           "local db <close> = io.sqlite(H2_SQLITE_PATH, 'r')\n"
                           "local function read_row()\n"
                           "    for _ in db:query('SELECT n FROM t') do end\n"
                           "end\n"
                           "catch read_row()");
  }
  if (status != LUA_OK)
    fprintf(stderr, "read-only WAL fixture: %s\n", lua_tostring(reader, -1));
  lua_close(reader);
  return status == LUA_OK;
}

#ifndef _WIN32
static int observed_fchown_calls;

static int observe_fchown(int fd, uid_t uid, gid_t gid) {
  (void)fd;
  (void)uid;
  (void)gid;
  observed_fchown_calls++;
  return 0;
}

static uid_t pretend_root(void) { return 0; }

static int verify_readonly_shm_metadata(const char *program) {
  const char *dbpath = "./h2_sqlite_shm_metadata.db";
#if defined(LUS_PLATFORM_DARWIN)
  sqlite3_vfs *vfs = sqlite3_vfs_find("unix-posix");
#else
  sqlite3_vfs *vfs = sqlite3_vfs_find("unix");
#endif
  int ok = 0;
  remove_database(dbpath);
  if (vfs == NULL || vfs->iVersion < 3 || vfs->xSetSystemCall == NULL ||
      !run_crash_wal_writer(program, dbpath))
    goto done;
  observed_fchown_calls = 0;
  if (vfs->xSetSystemCall(vfs, "geteuid", (sqlite3_syscall_ptr)pretend_root) !=
          SQLITE_OK ||
      vfs->xSetSystemCall(vfs, "fchown", (sqlite3_syscall_ptr)observe_fchown) !=
          SQLITE_OK)
    goto restore;
  ok = read_wal_with_pledge(dbpath, 1, 0) && observed_fchown_calls == 0;
restore:
  vfs->xSetSystemCall(vfs, "geteuid", NULL);
  vfs->xSetSystemCall(vfs, "fchown", NULL);
done:
  remove_database(dbpath);
  return ok;
}
#endif

static int verify_shm_unchanged(const char *program, const char *dbpath,
                                int shape, int require_row,
                                int require_write_denial) {
  static const unsigned char undersized[] = {'s', 'h', 'm'};
  FileSnapshot before;
  FileSnapshot after;
  char shm[512];
  char wal[512];
  int ok = 0;
  remove_database(dbpath);
  if (!run_crash_wal_writer(program, dbpath) ||
      !make_sidecar_path(shm, sizeof(shm), dbpath, "-shm") ||
      !make_sidecar_path(wal, sizeof(wal), dbpath, "-wal"))
    goto done;
  if (shape == 0) {
    if (remove(shm) != 0)
      goto done;
  } else if (shape == 1 && !write_bytes(shm, undersized, sizeof(undersized))) {
    goto done;
  }
  if (!snapshot_file(wal, &after) || !after.exists || after.size == 0) {
    free_snapshot(&after);
    goto done;
  }
  free_snapshot(&after);
  if (!snapshot_file(shm, &before))
    goto done;
  if ((shape == 0 && before.exists) ||
      (shape == 1 && (!before.exists || before.size != 3)) ||
      (shape == 2 && (!before.exists || before.size != 32 * 1024))) {
    free_snapshot(&before);
    goto done;
  }
  if (!read_wal_with_pledge(dbpath, require_row, require_write_denial) ||
      !snapshot_file(shm, &after)) {
    free_snapshot(&before);
    goto done;
  }
  ok = snapshots_equal(&before, &after);
  free_snapshot(&before);
  free_snapshot(&after);
done:
  remove_database(dbpath);
  return ok;
}

static lua_State *open_sealed_wal_reader(const char *dbpath) {
  lua_State *reader = luaL_newstate();
  int status;
  if (reader == NULL)
    return NULL;
  luaL_openlibs(reader);
  lua_pushstring(reader, dbpath);
  lua_setglobal(reader, "H2_SQLITE_PATH");
  status =
      luaL_dostring(reader, "pledge('fs:read=./h2_sqlite_*', 'seal')\n"
                            "H2_SQLITE_DB = io.sqlite(H2_SQLITE_PATH, 'r')\n"
                            "local n\n"
                            "for row in H2_SQLITE_DB:query(\n"
                            "        'SELECT count(*) AS n FROM t') do\n"
                            "    n = row.n\n"
                            "end\n"
                            "assert(n == 1, tostring(n))");
  if (status != LUA_OK) {
    fprintf(stderr, "mixed SHM reader: %s\n", lua_tostring(reader, -1));
    lua_close(reader);
    return NULL;
  }
  return reader;
}

static int repeat_sealed_wal_read(lua_State *reader) {
  int status =
      luaL_dostring(reader, "local n\n"
                            "for row in H2_SQLITE_DB:query(\n"
                            "        'SELECT count(*) AS n FROM t') do\n"
                            "    n = row.n\n"
                            "end\n"
                            "assert(n == 1, tostring(n))");
  if (status != LUA_OK)
    fprintf(stderr, "mixed SHM repeated read: %s\n", lua_tostring(reader, -1));
  return status == LUA_OK;
}

/* A sealed read-only connection may share an in-process WAL node with an
** ordinary writer. Its SHM capability remains read-only for the lifetime of
** that connection, independent of which open created the shared node. */
static int verify_mixed_shm_readonly(const char *program) {
  const char *writer_first = "./h2_sqlite_mixed_writer_first.db";
  const char *reader_first = "./h2_sqlite_mixed_reader_first.db";
  char shm[512];
  FileSnapshot before;
  FileSnapshot after;
  sqlite3 *writer = NULL;
  sqlite3 *held_db = NULL;
  sqlite3_stmt *held_read = NULL;
  lua_State *reader = NULL;
  char *errmsg = NULL;
  int rc;
  int ok = 0;
  memset(&before, 0, sizeof(before));
  memset(&after, 0, sizeof(after));

  remove_database(writer_first);
  rc = sqlite3_open_v2(writer_first, &writer,
                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
  if (rc != SQLITE_OK)
    goto done;
  rc = sqlite3_exec(writer,
                    "PRAGMA journal_mode=WAL;"
                    "PRAGMA wal_autocheckpoint=0;"
                    "CREATE TABLE t (n INTEGER);"
                    "INSERT INTO t VALUES (7)",
                    NULL, NULL, &errmsg);
  if (rc != SQLITE_OK ||
      sqlite3_open_v2(writer_first, &held_db, SQLITE_OPEN_READWRITE, NULL) !=
          SQLITE_OK ||
      sqlite3_prepare_v2(held_db, "SELECT n FROM t", -1, &held_read, NULL) !=
          SQLITE_OK ||
      sqlite3_step(held_read) != SQLITE_ROW ||
      sqlite3_exec(writer, "UPDATE t SET n = 8", NULL, NULL, &errmsg) !=
          SQLITE_OK ||
      !make_sidecar_path(shm, sizeof(shm), writer_first, "-shm") ||
      !snapshot_file(shm, &before) || !before.exists)
    goto done;

  reader = open_sealed_wal_reader(writer_first);
  if (reader == NULL || !snapshot_file(shm, &after) ||
      !snapshots_equal(&before, &after))
    goto done;
  free_snapshot(&after);
  if (!repeat_sealed_wal_read(reader) || !snapshot_file(shm, &after) ||
      !snapshots_equal(&before, &after))
    goto done;
  free_snapshot(&after);
  lua_close(reader);
  reader = NULL;
  if (!snapshot_file(shm, &after) || !snapshots_equal(&before, &after))
    goto done;
  free_snapshot(&after);

  reader = open_sealed_wal_reader(writer_first);
  if (reader == NULL || !snapshot_file(shm, &after) ||
      !snapshots_equal(&before, &after))
    goto done;
  free_snapshot(&after);
  lua_close(reader);
  reader = NULL;
  sqlite3_finalize(held_read);
  held_read = NULL;
  if (sqlite3_close(held_db) != SQLITE_OK)
    goto done;
  held_db = NULL;
  if (sqlite3_close(writer) != SQLITE_OK)
    goto done;
  writer = NULL;
  free_snapshot(&before);

  remove_database(reader_first);
  if (!run_crash_wal_writer(program, reader_first) ||
      !make_sidecar_path(shm, sizeof(shm), reader_first, "-shm"))
    goto done;
  reader = open_sealed_wal_reader(reader_first);
  if (reader == NULL || !snapshot_file(shm, &before) || !before.exists)
    goto done;
  rc = sqlite3_open_v2(reader_first, &writer, SQLITE_OPEN_READWRITE, NULL);
  if (rc != SQLITE_OK)
    goto done;
  sqlite3_free(errmsg);
  errmsg = NULL;
  rc = sqlite3_exec(writer, "INSERT INTO t VALUES (8)", NULL, NULL, &errmsg);
  if ((rc & 0xff) != SQLITE_READONLY || !snapshot_file(shm, &after) ||
      !snapshots_equal(&before, &after))
    goto done;
  free_snapshot(&after);
  if (sqlite3_close(writer) != SQLITE_OK)
    goto done;
  writer = NULL;
  if (!snapshot_file(shm, &after) || !snapshots_equal(&before, &after))
    goto done;
  free_snapshot(&after);
  lua_close(reader);
  reader = NULL;
  free_snapshot(&before);

  rc = sqlite3_open_v2(reader_first, &writer, SQLITE_OPEN_READWRITE, NULL);
  if (rc != SQLITE_OK ||
      sqlite3_exec(writer, "INSERT INTO t VALUES (8)", NULL, NULL, NULL) !=
          SQLITE_OK ||
      sqlite3_close(writer) != SQLITE_OK)
    goto done;
  writer = NULL;
  ok = 1;

done:
  if (!ok && writer != NULL)
    fprintf(stderr, "mixed SHM writer: %s\n", sqlite3_errmsg(writer));
  sqlite3_free(errmsg);
  free_snapshot(&before);
  free_snapshot(&after);
  if (reader != NULL)
    lua_close(reader);
  sqlite3_finalize(held_read);
  if (held_db != NULL)
    sqlite3_close(held_db);
  if (writer != NULL)
    sqlite3_close(writer);
  remove_database(writer_first);
  remove_database(reader_first);
  return ok;
}

static void probe_granter(lua_State *L, lus_PledgeRequest *p) {
  if (p->status == LUS_PLEDGE_GRANT) {
    lus_setpledge(L, p, p->sub, p->value);
    return;
  }
  while (lus_nextpledge(L, p)) {
    if (p->current != NULL && p->value != NULL &&
        strcmp(p->current, p->value) == 0) {
      lus_setpledge(L, p, p->sub, NULL);
      return;
    }
  }
}

static int seed_database(const char *path, const char *value) {
  sqlite3 *db = NULL;
  sqlite3_stmt *stmt = NULL;
  int rc;
  remove_database(path);
  rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                       NULL);
  if (rc != SQLITE_OK)
    goto done;
  rc = sqlite3_exec(db, "CREATE TABLE value (text TEXT)", NULL, NULL, NULL);
  if (rc != SQLITE_OK)
    goto done;
  rc = sqlite3_prepare_v2(db, "INSERT INTO value VALUES (?)", -1, &stmt, NULL);
  if (rc != SQLITE_OK)
    goto done;
  sqlite3_bind_text(stmt, 1, value, -1, SQLITE_STATIC);
  rc = sqlite3_step(stmt) == SQLITE_DONE ? SQLITE_OK : SQLITE_ERROR;
done:
  sqlite3_finalize(stmt);
  if (db != NULL && sqlite3_close(db) != SQLITE_OK)
    rc = SQLITE_ERROR;
  return rc == SQLITE_OK;
}

static int grant_sqlite_tree(lua_State *L, const char *directory) {
  char pattern[1024];
  int n = snprintf(pattern, sizeof(pattern), "%s/*", directory);
  return n > 0 && (size_t)n < sizeof(pattern) &&
         lus_pledge(L, "fs:read", pattern) &&
         lus_pledge(L, "fs:write", pattern);
}

typedef struct SQLiteSwap {
  const char *before_phase;
  const char *after_phase;
  char original[1024];
  char saved[1024];
  char replacement[1024];
  int swapped;
  int restored;
  int blocked;
  int failed;
} SQLiteSwap;

static int make_directory(const char *path) {
#ifdef _WIN32
  return _mkdir(path) == 0;
#else
  return mkdir(path, 0700) == 0;
#endif
}

static void remove_directory(const char *path) {
#ifdef _WIN32
  _rmdir(path);
#else
  rmdir(path);
#endif
}

static int copy_path(char *out, size_t outsize, const char *base,
                     const char *suffix) {
  int n = snprintf(out, outsize, "%s%s", base, suffix);
  return n >= 0 && (size_t)n < outsize;
}

static int configure_swap(SQLiteSwap *swap, const char *before,
                          const char *after, const char *original,
                          const char *saved, const char *replacement) {
  memset(swap, 0, sizeof(*swap));
  swap->before_phase = before;
  swap->after_phase = after;
  return copy_path(swap->original, sizeof(swap->original), original, "") &&
         copy_path(swap->saved, sizeof(swap->saved), saved, "") &&
         copy_path(swap->replacement, sizeof(swap->replacement), replacement,
                   "");
}

static void sqlite_swap_hook(const char *phase, const char *path,
                             void *context) {
  SQLiteSwap *swap = (SQLiteSwap *)context;
  (void)path;
  if (swap->blocked)
    return;
  if (!swap->swapped && strcmp(phase, swap->before_phase) == 0) {
    if (rename(swap->original, swap->saved) != 0) {
#ifdef _WIN32
      if (errno == EACCES || errno == EPERM) {
        swap->blocked = 1;
        return;
      }
#endif
      swap->failed = 1;
      return;
    }
    if (rename(swap->replacement, swap->original) != 0) {
#ifdef _WIN32
      int error = errno;
#endif
      if (rename(swap->saved, swap->original) != 0)
        swap->failed = 1;
#ifdef _WIN32
      else if (error == EACCES || error == EPERM)
        swap->blocked = 1;
      else
#endif
        swap->failed = 1;
      return;
    }
    swap->swapped = 1;
  } else if (swap->swapped && !swap->restored && swap->after_phase != NULL &&
             strcmp(phase, swap->after_phase) == 0) {
    if (rename(swap->original, swap->replacement) != 0 ||
        rename(swap->saved, swap->original) != 0) {
      swap->failed = 1;
      return;
    }
    swap->restored = 1;
  }
}

#ifndef _WIN32
static void auth_delete_swap_hook(const char *phase, const char *path,
                                  void *context) {
  SQLiteSwap *swap = (SQLiteSwap *)context;
  if (path != NULL && strcmp(path, swap->original) == 0)
    sqlite_swap_hook(phase, path, context);
}
#endif

static int finish_swap(SQLiteSwap *swap) {
  if (swap->blocked)
    return !swap->failed;
  if (swap->swapped && !swap->restored) {
    if (rename(swap->original, swap->replacement) != 0 ||
        rename(swap->saved, swap->original) != 0)
      swap->failed = 1;
    else
      swap->restored = 1;
  }
  return swap->swapped && swap->restored && !swap->failed;
}

static int run_main_swap(const char *root, int ancestor) {
  char live[1024];
  char held[1024];
  char replacement[1024];
  char dbpath[1024];
  char replacement_db[1024];
  SQLiteSwap swap;
  lua_State *L = NULL;
  int status;
  int ok = 0;
  if (!copy_path(live, sizeof(live), root, "/main-live") ||
      !copy_path(held, sizeof(held), root, "/main-held") ||
      !copy_path(replacement, sizeof(replacement), root, "/main-replacement") ||
      !make_directory(live) || !make_directory(replacement) ||
      !copy_path(dbpath, sizeof(dbpath), live, "/db.sqlite") ||
      !copy_path(replacement_db, sizeof(replacement_db), replacement,
                 "/db.sqlite") ||
      !seed_database(dbpath, "trusted") ||
      !seed_database(replacement_db, "attacker"))
    goto done;
  if (ancestor) {
    if (!configure_swap(&swap, "main", "main-opened", live, held, replacement))
      goto done;
  } else {
    char saved_db[1024];
    if (!copy_path(saved_db, sizeof(saved_db), root, "/main-saved.db") ||
        !configure_swap(&swap, "main", "main-opened", dbpath, saved_db,
                        replacement_db))
      goto done;
  }
  L = luaL_newstate();
  if (L == NULL)
    goto done;
  luaL_openlibs(L);
  if (!grant_sqlite_tree(L, root))
    goto done;
  lua_pushstring(L, dbpath);
  lua_setglobal(L, "H2_SQLITE_PATH");
  luaS_setsqlitepathhook(sqlite_swap_hook, &swap);
  status = luaL_dostring(
      L, "local db <close> = io.sqlite(H2_SQLITE_PATH, 'r')\n"
         "local got\n"
         "for row in db:query('SELECT text FROM value') do got = row.text end\n"
         "assert(got == 'trusted', tostring(got))");
  luaS_setsqlitepathhook(NULL, NULL);
  ok = status == LUA_OK && finish_swap(&swap);
done:
  luaS_setsqlitepathhook(NULL, NULL);
  if (L != NULL) {
    if (!ok && lua_gettop(L) > 0)
      fprintf(stderr, "main swap: %s\n", lua_tostring(L, -1));
    lua_close(L);
  }
  remove_database(dbpath);
  remove_database(replacement_db);
  remove_directory(live);
  remove_directory(held);
  remove_directory(replacement);
  return ok;
}

static int run_sidecar_swap(const char *root, const char *kind, int ancestor) {
  static const unsigned char marker[] = "attacker sidecar marker";
  char live[1024];
  char held[1024];
  char replacement[1024];
  char dbpath[1024];
  char replacement_db[1024];
  char sidecar[1024];
  char replacement_sidecar[1024];
  char saved_sidecar[1024];
  const char *suffix = strcmp(kind, "wal") == 0 ? "-wal" : "-shm";
  const char *after = strcmp(kind, "wal") == 0 ? "wal-opened" : "shm-opened";
  SQLiteSwap swap;
  FileSnapshot before;
  FileSnapshot after_snapshot;
  lua_State *L = NULL;
  int status;
  int ok = 0;
  memset(&before, 0, sizeof(before));
  memset(&after_snapshot, 0, sizeof(after_snapshot));
  saved_sidecar[0] = '\0';
  if (!copy_path(live, sizeof(live), root, "/side-live") ||
      !copy_path(held, sizeof(held), root, "/side-held") ||
      !copy_path(replacement, sizeof(replacement), root, "/side-replacement") ||
      !make_directory(live) || !make_directory(replacement) ||
      !copy_path(dbpath, sizeof(dbpath), live, "/db.sqlite") ||
      !seed_database(dbpath, "trusted") ||
      !copy_path(sidecar, sizeof(sidecar), dbpath, suffix) ||
      !copy_path(replacement_db, sizeof(replacement_db), replacement,
                 "/db.sqlite") ||
      !copy_path(replacement_sidecar, sizeof(replacement_sidecar),
                 replacement_db, suffix) ||
      !write_bytes(replacement_sidecar, marker, sizeof(marker)) ||
      !snapshot_file(replacement_sidecar, &before))
    goto done;
  if (ancestor) {
    if (!configure_swap(&swap, "main-opened", after, live, held, replacement))
      goto done;
  } else {
    if (!copy_path(saved_sidecar, sizeof(saved_sidecar), root, "/side-saved") ||
        !configure_swap(&swap, kind, after, sidecar, saved_sidecar,
                        replacement_sidecar))
      goto done;
  }
  L = luaL_newstate();
  if (L == NULL)
    goto done;
  luaL_openlibs(L);
  if (!grant_sqlite_tree(L, root))
    goto done;
  lua_pushstring(L, dbpath);
  lua_setglobal(L, "H2_SQLITE_PATH");
  luaS_setsqlitepathhook(sqlite_swap_hook, &swap);
  status = luaL_dostring(L, "local db <close> = io.sqlite(H2_SQLITE_PATH)\n"
                            "db:exec('PRAGMA journal_mode=WAL')\n"
                            "db:run('INSERT INTO value VALUES (?)', 'new')");
  luaS_setsqlitepathhook(NULL, NULL);
  if (!finish_swap(&swap) ||
      !snapshot_file(replacement_sidecar, &after_snapshot))
    goto done;
  ok = status == LUA_OK && snapshots_equal(&before, &after_snapshot);
  free_snapshot(&after_snapshot);
done:
  luaS_setsqlitepathhook(NULL, NULL);
  free_snapshot(&before);
  if (L != NULL) {
    if (!ok && lua_gettop(L) > 0)
      fprintf(stderr, "%s swap: %s\n", kind, lua_tostring(L, -1));
    lua_close(L);
  }
  remove_database(dbpath);
  remove_database(replacement_sidecar);
  remove(saved_sidecar);
  remove_directory(live);
  remove_directory(held);
  remove_directory(replacement);
  return ok;
}

static int run_shm_delete_swap(const char *root) {
  static const unsigned char marker[] = "attacker SHM replacement";
  char dbpath[1024];
  char shm[1024];
  char saved_shm[1024];
  char replacement_shm[1024];
  SQLiteSwap swap;
  FileSnapshot before;
  FileSnapshot replacement_after;
  FileSnapshot saved_after;
  lua_State *L = NULL;
  int status = LUA_ERRRUN;
  int ok = 0;
  memset(&before, 0, sizeof(before));
  memset(&replacement_after, 0, sizeof(replacement_after));
  memset(&saved_after, 0, sizeof(saved_after));
  if (!copy_path(dbpath, sizeof(dbpath), root, "/shm-delete.db") ||
      !copy_path(shm, sizeof(shm), dbpath, "-shm") ||
      !copy_path(saved_shm, sizeof(saved_shm), root, "/shm-delete.saved") ||
      !copy_path(replacement_shm, sizeof(replacement_shm), root,
                 "/shm-delete.replacement") ||
      !seed_database(dbpath, "trusted") ||
      !write_bytes(replacement_shm, marker, sizeof(marker)) ||
      !snapshot_file(replacement_shm, &before) ||
#ifdef _WIN32
      !configure_swap(&swap, "shm-opened", NULL, shm, saved_shm,
#else
      !configure_swap(&swap, "validated", NULL, shm, saved_shm,
#endif
                      replacement_shm))
    goto done;
  L = luaL_newstate();
  if (L == NULL)
    goto done;
  luaL_openlibs(L);
  if (!grant_sqlite_tree(L, root))
    goto done;
  lua_pushstring(L, dbpath);
  lua_setglobal(L, "H2_SQLITE_PATH");
#ifdef _WIN32
  luaS_setsqlitepathhook(sqlite_swap_hook, &swap);
#else
  luaAP_setdeletehook(auth_delete_swap_hook, &swap);
#endif
  status = luaL_dostring(L, "local db = io.sqlite(H2_SQLITE_PATH)\n"
                            "db:exec('PRAGMA journal_mode=WAL')\n"
                            "db:run('INSERT INTO value VALUES (?)', 'new')\n"
                            "db:close()");
#ifdef _WIN32
  luaS_setsqlitepathhook(NULL, NULL);
#else
  luaAP_setdeletehook(NULL, NULL);
#endif
  if (swap.blocked) {
    ok = status == LUA_OK && !swap.failed;
    goto restore;
  }
  if (!swap.swapped || swap.failed || !snapshot_file(shm, &replacement_after) ||
      !snapshot_file(saved_shm, &saved_after))
    goto restore;
  ok = status == LUA_OK && saved_after.exists &&
       snapshots_equal(&before, &replacement_after);
restore:
  if (!finish_swap(&swap))
    ok = 0;
done:
#ifdef _WIN32
  luaS_setsqlitepathhook(NULL, NULL);
#else
  luaAP_setdeletehook(NULL, NULL);
#endif
  free_snapshot(&before);
  free_snapshot(&replacement_after);
  free_snapshot(&saved_after);
  if (L != NULL) {
    if (!ok && lua_gettop(L) > 0)
      fprintf(stderr, "SHM delete swap: %s\n", lua_tostring(L, -1));
    lua_close(L);
  }
  remove_database(dbpath);
  remove(saved_shm);
  remove(replacement_shm);
  return ok;
}

static int run_delete_swap(const char *root, int ancestor) {
  static const unsigned char marker[] = "attacker delete marker";
  char live[1024];
  char held[1024];
  char replacement[1024];
  char dbpath[1024];
  char journal[1024];
  char replacement_journal[1024];
  char saved_journal[1024];
  SQLiteSwap swap;
  FileSnapshot before;
  FileSnapshot after_snapshot;
  lua_State *L = NULL;
  int status;
  int ok = 0;
  memset(&before, 0, sizeof(before));
  memset(&after_snapshot, 0, sizeof(after_snapshot));
  saved_journal[0] = '\0';
  if (!copy_path(live, sizeof(live), root, "/delete-live") ||
      !copy_path(held, sizeof(held), root, "/delete-held") ||
      !copy_path(replacement, sizeof(replacement), root,
                 "/delete-replacement") ||
      !make_directory(live) || !make_directory(replacement) ||
      !copy_path(dbpath, sizeof(dbpath), live, "/db.sqlite") ||
      !seed_database(dbpath, "trusted") ||
      !copy_path(journal, sizeof(journal), dbpath, "-journal") ||
      !copy_path(replacement_journal, sizeof(replacement_journal), replacement,
                 "/db.sqlite-journal") ||
      !write_bytes(replacement_journal, marker, sizeof(marker)) ||
      !snapshot_file(replacement_journal, &before))
    goto done;
  if (ancestor) {
    if (!configure_swap(&swap, "delete", "delete-done", live, held,
                        replacement))
      goto done;
  } else {
    if (!copy_path(saved_journal, sizeof(saved_journal), root,
                   "/delete-saved-journal") ||
        !configure_swap(&swap,
#ifdef _WIN32
                        "delete",
#else
                        "validated",
#endif
                        NULL, journal, saved_journal, replacement_journal))
      goto done;
  }
  L = luaL_newstate();
  if (L == NULL)
    goto done;
  luaL_openlibs(L);
  if (!grant_sqlite_tree(L, root))
    goto done;
  lua_pushstring(L, dbpath);
  lua_setglobal(L, "H2_SQLITE_PATH");
#ifdef _WIN32
  luaS_setsqlitepathhook(sqlite_swap_hook, &swap);
#else
  if (ancestor)
    luaS_setsqlitepathhook(sqlite_swap_hook, &swap);
  else
    luaAP_setdeletehook(auth_delete_swap_hook, &swap);
#endif
  status = luaL_dostring(L, "local db <close> = io.sqlite(H2_SQLITE_PATH)\n"
                            "db:run('INSERT INTO value VALUES (?)', 'delete')");
  luaS_setsqlitepathhook(NULL, NULL);
#ifndef _WIN32
  luaAP_setdeletehook(NULL, NULL);
#endif
  if (!ancestor && !swap.blocked && !snapshot_file(journal, &after_snapshot))
    goto done;
  if ((ancestor || swap.blocked) &&
      !snapshot_file(replacement_journal, &after_snapshot))
    goto done;
  ok = swap.swapped && !swap.failed &&
       snapshots_equal(&before, &after_snapshot) &&
       ((ancestor && status == LUA_OK && swap.restored) ||
        (!ancestor && status != LUA_OK));
  if (swap.blocked)
    ok = status == LUA_OK && snapshots_equal(&before, &after_snapshot);
  free_snapshot(&after_snapshot);
  if (!finish_swap(&swap))
    ok = 0;
done:
  luaS_setsqlitepathhook(NULL, NULL);
#ifndef _WIN32
  luaAP_setdeletehook(NULL, NULL);
#endif
  free_snapshot(&before);
  if (L != NULL)
    lua_close(L);
  remove_database(dbpath);
  remove_database(replacement_journal);
  remove(saved_journal);
  remove_directory(live);
  remove_directory(held);
  remove_directory(replacement);
  return ok;
}

static int verify_bound_path_races(void) {
#ifdef _WIN32
  char temp[MAX_PATH + 1];
  char candidate[MAX_PATH + 1];
  char canonical[1024];
  DWORD got = GetTempPathA(MAX_PATH, temp);
  if (got == 0 || got > MAX_PATH ||
      GetTempFileNameA(temp, "lus", 0, candidate) == 0 ||
      !DeleteFileA(candidate) || !CreateDirectoryA(candidate, NULL) ||
      GetFullPathNameA(candidate, sizeof(canonical), canonical, NULL) == 0)
    return 0;
#else
  char template_path[] = "/tmp/lus-sqlite-bound-XXXXXX";
  char canonical[PATH_MAX];
  char *created = mkdtemp(template_path);
  if (created == NULL || realpath(created, canonical) == NULL)
    return 0;
#endif
  int ok;
  ok = run_main_swap(canonical, 0) && run_main_swap(canonical, 1) &&
       run_sidecar_swap(canonical, "wal", 0) &&
       run_sidecar_swap(canonical, "wal", 1) &&
       run_sidecar_swap(canonical, "shm", 0) &&
       run_sidecar_swap(canonical, "shm", 1) &&
       run_shm_delete_swap(canonical) && run_delete_swap(canonical, 0) &&
       run_delete_swap(canonical, 1);
  remove_directory(canonical);
  return ok;
}

static int verify_denied_delete_is_nonmutating(void) {
  char path[512];
  static const unsigned char contents[] = "must survive denied delete";
  FileSnapshot before;
  FileSnapshot after;
  LusAuthFile auth;
  lua_State *L = luaL_newstate();
  int status;
  int ok = 0;
#ifdef _WIN32
  long process_id = (long)_getpid();
#else
  long process_id = (long)getpid();
#endif
  memset(&before, 0, sizeof(before));
  memset(&after, 0, sizeof(after));
  snprintf(path, sizeof(path), "./h2_sqlite_denied_delete_%ld.db", process_id);
  if (L == NULL || !write_bytes(path, contents, sizeof(contents)) ||
      !snapshot_file(path, &before))
    goto done;
  luaL_openlibs(L);
  if (!lus_pledge(L, "fs:read", path))
    goto done;
  status = luaAP_tryopen(L, path, LUS_AUTH_READ | LUS_AUTH_DELETE_ON_CLOSE, 0,
                         &auth);
  luaAP_closeauthfile(&auth);
  if (!snapshot_file(path, &after))
    goto done;
  ok = status == LUS_AUTH_DENIED && snapshots_equal(&before, &after);
  free_snapshot(&after);
done:
  free_snapshot(&before);
  remove(path);
  if (L != NULL)
    lua_close(L);
  return ok;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--crash-wal-writer") == 0)
    return crash_wal_writer(argv[2]);

  printf("Running H2: test_sqlite\n");

  lua_State *L = luaL_newstate();
  luaL_openlibs(L);

  /* Check-only granter acknowledgements must not plant a global entry. */
  lus_registerpledge(L, "probe", probe_granter);
  if (!lus_pledge(L, "probe", "allowed"))
    return fail("probe pledge setup", NULL);
  if (!lus_haspledge(L, "probe:read", "allowed"))
    return fail("matching probe check", NULL);
  if (lus_haspledge(L, "probe:read", "denied"))
    return fail("check-only mutation widened a pledge", NULL);

  /* 1: open a database and seed it from the Lus side */
  if (luaL_dostring(L, "db = io.sqlite(':memory:')\n"
                       "db:exec('CREATE TABLE t (n INTEGER)')\n"
                       "db:run('INSERT INTO t VALUES (?)', 1)\n"
                       "return db") != LUA_OK)
    return fail("setup", lua_tostring(L, -1));

  /* 2: lus_tosqlite returns the live connection */
  sqlite3 *conn = (sqlite3 *)lus_tosqlite(L, -1);
  if (conn == NULL)
    return fail("lus_tosqlite returned NULL for an open db", NULL);
  if (sqlite3_exec(conn, "INSERT INTO t VALUES (2)", NULL, NULL, NULL) !=
      SQLITE_OK)
    return fail("direct sqlite3_exec on the returned connection",
                sqlite3_errmsg(conn));
  if (luaL_dostring(L,
                    "local n\n"
                    "for row in db:query('SELECT count(*) AS n FROM t') do\n"
                    "    n = row.n\n"
                    "end\n"
                    "assert(n == 2, 'the C-side insert is visible')") != LUA_OK)
    return fail("C-side insert visibility", lua_tostring(L, -1));

  /* 3: NULL for non-database values, including the nearest misses */
  lua_pushinteger(L, 42);
  if (lus_tosqlite(L, -1) != NULL)
    return fail("lus_tosqlite on a number", NULL);
  lua_pop(L, 1);
  lua_pushstring(L, "db");
  if (lus_tosqlite(L, -1) != NULL)
    return fail("lus_tosqlite on a string", NULL);
  lua_pop(L, 1);
  lua_getglobal(L, "io");
  lua_getfield(L, -1, "stdout");
  if (lus_tosqlite(L, -1) != NULL)
    return fail("lus_tosqlite on a file userdata", NULL);
  lua_pop(L, 2);
  if (luaL_dostring(L, "return db:prepare('SELECT 1')") != LUA_OK)
    return fail("prepare", lua_tostring(L, -1));
  if (lus_tosqlite(L, -1) != NULL)
    return fail("lus_tosqlite on a statement userdata", NULL);
  lua_pop(L, 1);

  /* 4: NULL after close */
  if (luaL_dostring(L, "db:close()\nreturn db") != LUA_OK)
    return fail("close", lua_tostring(L, -1));
  if (lus_tosqlite(L, -1) != NULL)
    return fail("lus_tosqlite on a closed db", NULL);
  lua_settop(L, 0);

  /* 5: pledge gating applies to embedded states too */
  if (luaL_dostring(L, "return catch io.sqlite('./h2_denied.db')") == LUA_OK) {
    int ok = lua_toboolean(L, 1);
    if (ok)
      return fail("unpledged file open succeeded", NULL);
  } else {
    return fail("pledge probe errored", lua_tostring(L, -1));
  }
  lua_settop(L, 0);
  if (luaL_dostring(L, "pledge('fs:read=./h2_sqlite_*',"
                       "       'fs:write=./h2_sqlite_*')\n"
                       "local db <close> = io.sqlite('./h2_sqlite_ok.db')\n"
                       "db:exec('CREATE TABLE t (n INTEGER)')\n"
                       "db:run('INSERT INTO t VALUES (1)')") != LUA_OK)
    return fail("pledged file open", lua_tostring(L, -1));
  remove("./h2_sqlite_ok.db");
  remove("./h2_sqlite_ok.db-wal");
  remove("./h2_sqlite_ok.db-shm");
  remove("./h2_sqlite_ok.db-journal");

  /* 6: read-only WAL recovery never creates or changes SHM storage. */
  if (!verify_shm_unchanged(argv[0], "./h2_sqlite_shm_absent.db", 0, 0, 1))
    return fail("read-only WAL created a missing SHM file", NULL);
  if (!verify_shm_unchanged(argv[0], "./h2_sqlite_shm_short.db", 1, 0, 0))
    return fail("read-only WAL changed an undersized SHM file", NULL);
  if (!verify_shm_unchanged(argv[0], "./h2_sqlite_shm_existing.db", 2, 1, 0))
    return fail("read-only WAL changed an existing SHM file", NULL);
  if (!verify_mixed_shm_readonly(argv[0]))
    return fail("mixed writable and read-only SHM node", NULL);
  /* 7: authorization retains the exact object and parent across races. */
  if (!verify_denied_delete_is_nonmutating())
    return fail("denied delete-on-close changed an existing file", NULL);
  if (!verify_bound_path_races())
    return fail("SQLite authorized-path race fixture", NULL);
#ifndef _WIN32
  if (!verify_readonly_shm_metadata(argv[0]))
    return fail("read-only SHM changed ownership metadata", NULL);
#endif

  /* 8: lua_close with an open db and an open statement is clean */
  if (luaL_dostring(L,
                    "leak_db = io.sqlite(':memory:')\n"
                    "leak_db:exec('CREATE TABLE t (n INTEGER)')\n"
                    "leak_stmt = leak_db:prepare('SELECT * FROM t')") != LUA_OK)
    return fail("leak setup", lua_tostring(L, -1));
  lua_close(L); /* the sanitizer job turns UAF here into a hard failure */

  printf("sqlite test passed\n");
  return 0;
}
