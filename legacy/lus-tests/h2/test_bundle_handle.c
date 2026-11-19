#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lbundle.h"
#include "lua.h"
#include "lualib.h"

#if defined(_WIN32)
int main(void) { return 0; }
#else

#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct Bytecode {
  char *data;
  size_t size;
  size_t capacity;
} Bytecode;

static int dump_writer(lua_State *L, const void *data, size_t size, void *ud) {
  Bytecode *bytecode = (Bytecode *)ud;
  size_t needed = bytecode->size + size;
  char *grown;
  (void)L;
  if (needed < bytecode->size)
    return 1;
  if (needed > bytecode->capacity) {
    size_t capacity = bytecode->capacity == 0 ? 4096 : bytecode->capacity;
    while (capacity < needed) {
      if (capacity > SIZE_MAX / 2)
        return 1;
      capacity *= 2;
    }
    grown = (char *)realloc(bytecode->data, capacity);
    if (grown == NULL)
      return 1;
    bytecode->data = grown;
    bytecode->capacity = capacity;
  }
  memcpy(bytecode->data + bytecode->size, data, size);
  bytecode->size = needed;
  return 0;
}

static int write_all(int fd, const void *data, size_t size) {
  const char *bytes = (const char *)data;
  size_t done = 0;
  while (done < size) {
    ssize_t written = write(fd, bytes + done, size - done);
    if (written < 0 && errno == EINTR)
      continue;
    if (written <= 0)
      return 0;
    done += (size_t)written;
  }
  return 1;
}

static int copy_all(int input, int output) {
  char buffer[16384];
  for (;;) {
    ssize_t count = read(input, buffer, sizeof(buffer));
    if (count < 0 && errno == EINTR)
      continue;
    if (count < 0)
      return 0;
    if (count == 0)
      return 1;
    if (!write_all(output, buffer, (size_t)count))
      return 0;
  }
}

static int make_bundle_copy(const char *target) {
  const char *names[] = {"late"};
  size_t offsets[] = {0};
  size_t sizes[1];
  size_t index_size;
  unsigned char footer[8];
  unsigned char *index;
  Bytecode bytecode = {NULL, 0, 0};
  lua_State *L = luaL_newstate();
  char executable[4096];
  int input = -1;
  int output = -1;
  int ok = 0;

  if (L == NULL || !lusB_getexepath(executable, sizeof(executable)))
    goto done;
  if (luaL_loadstring(L, "return { value = 'original' }") != LUA_OK ||
      lua_dump(L, dump_writer, &bytecode, 1) != 0)
    goto done;
  sizes[0] = bytecode.size;
  index = lusB_buildindex(LUSB_VERSION, "late", 0, NULL, 1, names, offsets,
                          sizes, &index_size);
  if (index == NULL)
    goto done;
  input = open(executable, O_RDONLY | O_CLOEXEC);
  output = open(target, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0700);
  if (input < 0 || output < 0 || !copy_all(input, output) ||
      !write_all(output, bytecode.data, bytecode.size) ||
      !write_all(output, index, index_size)) {
    free(index);
    goto done;
  }
  footer[0] = (unsigned char)(index_size & 0xff);
  footer[1] = (unsigned char)((index_size >> 8) & 0xff);
  footer[2] = (unsigned char)((index_size >> 16) & 0xff);
  footer[3] = (unsigned char)((index_size >> 24) & 0xff);
  memcpy(footer + 4, LUSB_MAGIC, LUSB_MAGIC_SIZE);
  ok = write_all(output, footer, sizeof(footer));
  free(index);

done:
  if (input >= 0)
    close(input);
  if (output >= 0 && close(output) != 0)
    ok = 0;
  if (L != NULL)
    lua_close(L);
  free(bytecode.data);
  if (!ok)
    unlink(target);
  return ok;
}

typedef struct RequireResult {
  int failed;
} RequireResult;

static void *require_repeatedly(void *ud) {
  RequireResult *result = (RequireResult *)ud;
  int i;
  for (i = 0; i < 50; i++) {
    lua_State *L = luaL_newstate();
    if (L == NULL) {
      result->failed = 1;
      return NULL;
    }
    luaL_openlibs(L);
    if (luaL_dostring(L, "local m = require('late')\n"
                         "assert(m.value == 'original')\n") != LUA_OK)
      result->failed = 1;
    lua_close(L);
    if (result->failed)
      return NULL;
  }
  return NULL;
}

static int child_test(void) {
  char executable[4096];
  char original[4140];
  LusBundle *bundle = NULL;
  pthread_t threads[8];
  RequireResult results[8] = {{0}};
  int replacement = -1;
  int created = 0;
  int joined = 0;
  int ok = 0;
  int i;

  if (!lusB_getexepath(executable, sizeof(executable)) ||
      snprintf(original, sizeof(original), "%s.original", executable) >=
          (int)sizeof(original) ||
      !lusB_detect())
    return 1;
  unlink(original);
  if (rename(executable, original) != 0)
    return 1;
  replacement =
      open(executable, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0700);
  if (replacement < 0)
    goto done;
  close(replacement);
  replacement = -1;

  bundle = lusB_load();
  if (bundle == NULL)
    goto done;
  g_bundle = bundle;
  for (i = 0; i < 8; i++) {
    if (pthread_create(&threads[i], NULL, require_repeatedly, &results[i]) != 0)
      goto done;
    created++;
  }
  for (i = 0; i < created; i++) {
    if (pthread_join(threads[i], NULL) != 0)
      goto done;
    joined++;
  }
  for (i = 0; i < 8; i++) {
    if (results[i].failed)
      goto done;
  }
  ok = 1;

done:
  for (i = joined; i < created; i++)
    pthread_join(threads[i], NULL);
  g_bundle = NULL;
  lusB_free(bundle);
  if (replacement >= 0)
    close(replacement);
  unlink(executable);
  if (rename(original, executable) != 0)
    ok = 0;
  return ok ? 0 : 1;
}

int main(int argc, char **argv) {
  char copy[256];
  pid_t child;
  int status;

  if (argc == 2 && strcmp(argv[1], "--child") == 0)
    return child_test();
  if (snprintf(copy, sizeof(copy), "/tmp/lus-bundle-handle-%ld",
               (long)getpid()) >= (int)sizeof(copy))
    return 1;
  unlink(copy);
  if (!make_bundle_copy(copy))
    return 1;
  child = fork();
  if (child == 0) {
    char *const child_argv[] = {copy, "--child", NULL};
    execv(copy, child_argv);
    _exit(127);
  }
  if (child < 0 || waitpid(child, &status, 0) < 0) {
    unlink(copy);
    return 1;
  }
  unlink(copy);
  return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
}
#endif
