/*
** lworkerlib.c
** Worker library for Lus - M:N thread pool with message passing
*/

#define lworkerlib_c
#define LUA_LIB

#include "lprefix.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "larena.h"
#include "lauthpath.h"
#include "lauxlib.h"
#include "ldo.h"
#include "lobject.h"
#include "lpledge.h"
#include "lstate.h"
#include "ltable.h"
#include "lua.h"
#include "lualib.h"
#include "lworkerlib.h"
#include "lworkerint.h"

/* Metatable name for worker userdata */
#define WORKER_METATABLE "worker.state"

/* Global worker pool (single instance) */
static WorkerPool g_pool = {0};

static void signal_recv_ctx(WorkerState *w);

/*
** {======================================================
** Platform-specific helpers
** =======================================================
*/

#if defined(LUS_PLATFORM_WINDOWS)
#include <io.h>
#define worker_closefd(fd) _close(fd)
static int get_cpu_count(void) {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  return (int)si.dwNumberOfProcessors;
}
#else
#include <fcntl.h>
#include <unistd.h>
#define worker_closefd(fd) close(fd)
#if !defined(O_CLOEXEC)
#define O_CLOEXEC 0
#endif
#if defined(_SC_NPROCESSORS_ONLN)
static int get_cpu_count(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return (n > 0) ? (int)n : 1;
}
#else
static int get_cpu_count(void) {
  return 4; /* fallback */
}
#endif
#endif

/* Serialize process-pool startup, shutdown, and enqueue operations. */
#if defined(LUS_PLATFORM_WINDOWS)
static SRWLOCK g_pool_lifecycle = SRWLOCK_INIT;
#define pool_lifecycle_lock() AcquireSRWLockExclusive(&g_pool_lifecycle)
#define pool_lifecycle_unlock() ReleaseSRWLockExclusive(&g_pool_lifecycle)
#else
static pthread_mutex_t g_pool_lifecycle = PTHREAD_MUTEX_INITIALIZER;
#define pool_lifecycle_lock() pthread_mutex_lock(&g_pool_lifecycle)
#define pool_lifecycle_unlock() pthread_mutex_unlock(&g_pool_lifecycle)
#endif

/* }====================================================== */

/*
** {======================================================
** Message Queue Operations
** =======================================================
*/

static void msgqueue_init(MessageQueue *q) {
  q->head = NULL;
  q->tail = NULL;
  q->count = 0;
}

static int msgqueue_push(MessageQueue *q, StandaloneArena *arena, char *data,
                         size_t size) {
  MessageNode *node = (MessageNode *)malloc(sizeof(MessageNode));
  if (node == NULL)
    return 0;
  node->arena = arena;
  node->data = data;
  node->size = size;
  node->next = NULL;
  if (q->tail) {
    q->tail->next = node;
  }
  else {
    q->head = node;
  }
  q->tail = node;
  q->count++;
  return 1;
}

static int msgqueue_pop(MessageQueue *q, StandaloneArena **arena, char **data,
                        size_t *size) {
  MessageNode *node = q->head;
  if (!node)
    return 0;
  q->head = node->next;
  if (!q->head)
    q->tail = NULL;
  q->count--;
  *arena = node->arena;
  *data = node->data;
  *size = node->size;
  free(node);
  return 1;
}

static void msgqueue_clear(MessageQueue *q) {
  StandaloneArena *arena;
  char *data;
  size_t size;
  while (msgqueue_pop(q, &arena, &data, &size)) {
    luaA_freestandalone(arena);
  }
}

/* }====================================================== */

/*
** {======================================================
** Value Serialization
** =======================================================
*/

/* Serialization format tags */
#define SER_NIL 0
#define SER_BOOL 1
#define SER_INT 2
#define SER_NUM 3
#define SER_STRING 4
#define SER_TABLE 5

/*
** Buffer for serialization - uses standalone arena for cross-thread safety.
** Arena provides backing storage; we maintain a contiguous buffer within it.
*/
typedef struct {
  StandaloneArena *arena; /* arena for data storage */
  char *data;             /* contiguous buffer in arena */
  size_t size;            /* bytes written */
  size_t cap;             /* buffer capacity */
  const char *err;        /* static error format (NULL if no error) */
  const char *errarg;     /* optional argument for 'err' (may be NULL) */
} SerBuffer;

/* Default arena block size for serialization (64KB) */
#define SERBUF_ARENA_SIZE (64 * 1024)
/* Default initial buffer size */
#define SERBUF_INIT_SIZE 256

static void serbuf_init(SerBuffer *b) {
  b->arena = luaA_newstandalone(SERBUF_ARENA_SIZE);
  b->data = NULL;
  b->size = 0;
  b->cap = 0;
  b->err = NULL;
  b->errarg = NULL;
  if (b->arena == NULL)
    return; /* first write will report out of memory */
  /* Pre-allocate initial buffer from arena */
  b->data = (char *)luaA_allocstandalone(b->arena, SERBUF_INIT_SIZE);
  if (b->data != NULL)
    b->cap = SERBUF_INIT_SIZE;
}

static void serbuf_free(SerBuffer *b) {
  if (b->arena != NULL) {
    luaA_freestandalone(b->arena);
    b->arena = NULL;
    b->data = NULL;
    b->size = 0;
    b->cap = 0;
  }
}

/* record a serialization failure; always returns 0 */
static int serbuf_fail(SerBuffer *b, const char *err, const char *errarg) {
  if (b->err == NULL) { /* keep the first error */
    b->err = err;
    b->errarg = errarg;
  }
  return 0;
}

static int serbuf_ensure(SerBuffer *b, size_t need) {
  if (b->arena == NULL)
    return 0; /* initial arena allocation failed */
  if (b->size + need > b->cap) {
    if (b->size > SIZE_MAX - need)
      return 0; /* overflow */
    /* Need larger buffer - allocate new one from arena */
    size_t newcap = b->cap * 2;
    while (newcap < b->size + need)
      newcap *= 2;
    char *newdata = (char *)luaA_allocstandalone(b->arena, newcap);
    if (newdata == NULL)
      return 0; /* allocation failed */
    /* Copy existing data to new buffer */
    if (b->size > 0)
      memcpy(newdata, b->data, b->size);
    /* Old buffer stays in arena (will be freed with arena) */
    b->data = newdata;
    b->cap = newcap;
  }
  return 1;
}

/*
** Serialization must not raise Lua errors: a longjmp would skip the
** caller's serbuf_free and leak the arena. Failures are recorded in the
** buffer and reported by the caller after cleanup.
*/
static int serbuf_write(SerBuffer *b, const void *p, size_t n) {
  if (!serbuf_ensure(b, n))
    return serbuf_fail(b, "out of memory in worker serialization", NULL);
  memcpy(b->data + b->size, p, n);
  b->size += n;
  return 1;
}

static int serbuf_write_byte(SerBuffer *b, unsigned char c) {
  return serbuf_write(b, &c, 1);
}

/* Forward declaration for recursive serialization */
static int serialize_value(lua_State *L, int idx, SerBuffer *b, int depth);

static int serialize_table(lua_State *L, int idx, SerBuffer *b, int depth) {
  if (depth > 100) {
    return serbuf_fail(b, "table nesting too deep for serialization", NULL);
  }
  /* Each nesting level keeps a key and value live on the value stack across
  ** the recursion. Reserve room without raising, since a longjmp here would
  ** skip the caller's serbuf_free and leak the arena. lua_checkstack grows the
  ** stack incrementally, so the depth cap above fires with a clean error long
  ** before a cyclic or very deep table could overflow the stack. */
  if (!lua_checkstack(L, 4)) {
    return serbuf_fail(b, "table nesting too deep for serialization", NULL);
  }
  idx = lua_absindex(L, idx);
  if (!serbuf_write_byte(b, SER_TABLE))
    return 0;

  /* Count entries first */
  lua_Integer count = 0;
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    count++;
    lua_pop(L, 1);
  }
  if (!serbuf_write(b, &count, sizeof(count)))
    return 0;

  /* Serialize each key-value pair */
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    /* key at -2, value at -1 */
    if (!serialize_value(L, -2, b, depth + 1))
      return 0;
    if (!serialize_value(L, -1, b, depth + 1))
      return 0;
    lua_pop(L, 1);
  }
  return 1;
}

static int serialize_value(lua_State *L, int idx, SerBuffer *b, int depth) {
  int t = lua_type(L, idx);
  switch (t) {
    case LUA_TNIL: return serbuf_write_byte(b, SER_NIL);
    case LUA_TBOOLEAN: {
      unsigned char v = lua_toboolean(L, idx) ? 1 : 0;
      return serbuf_write_byte(b, SER_BOOL) && serbuf_write_byte(b, v);
    }
    case LUA_TNUMBER:
      if (lua_isinteger(L, idx)) {
        lua_Integer i = lua_tointeger(L, idx);
        return serbuf_write_byte(b, SER_INT) && serbuf_write(b, &i, sizeof(i));
      }
      else {
        lua_Number n = lua_tonumber(L, idx);
        return serbuf_write_byte(b, SER_NUM) && serbuf_write(b, &n, sizeof(n));
      }
    case LUA_TSTRING: {
      size_t len;
      const char *s = lua_tolstring(L, idx, &len);
      return serbuf_write_byte(b, SER_STRING) &&
             serbuf_write(b, &len, sizeof(len)) && serbuf_write(b, s, len);
    }
    case LUA_TTABLE: return serialize_table(L, idx, b, depth);
    default:
      return serbuf_fail(b, "cannot serialize %s to worker",
                         lua_typename(L, t));
  }
}

/* Deserialization */
typedef struct {
  const char *data;
  size_t size;
  size_t pos;
} DeserBuffer;

static int deser_read(DeserBuffer *b, void *out, size_t n) {
  if (n > b->size - b->pos)
    return 0;
  memcpy(out, b->data + b->pos, n);
  b->pos += n;
  return 1;
}

static int deser_read_byte(DeserBuffer *b, unsigned char *out) {
  return deser_read(b, out, 1);
}

/* Forward declaration */
static int deserialize_value(lua_State *L, DeserBuffer *b, int depth);

static int deserialize_table(lua_State *L, DeserBuffer *b, int depth) {
  if (depth > 100)
    return 0;
  luaL_checkstack(L, 3, "deserialize");
  lua_Integer count;
  if (!deser_read(b, &count, sizeof(count)))
    return 0;
  if (count < 0 || count > 10000000)
    return 0;
  /* Do not presize the hash part from the (untrusted) declared count: a tiny
  ** message can claim millions of entries and force a huge upfront alloc. Cap
  ** the size hint; the table grows naturally as entries are actually read. */
  lua_createtable(L, 0, count < 1024 ? (int)count : 1024);
  for (lua_Integer i = 0; i < count; i++) {
    if (!deserialize_value(L, b, depth + 1))
      return 0; /* key */
    if (!deserialize_value(L, b, depth + 1))
      return 0; /* value */
    lua_settable(L, -3);
  }
  return 1;
}

static int deserialize_value(lua_State *L, DeserBuffer *b, int depth) {
  unsigned char tag;
  if (!deser_read_byte(b, &tag))
    return 0;

  switch (tag) {
    case SER_NIL: lua_pushnil(L); break;
    case SER_BOOL: {
      unsigned char v;
      if (!deser_read_byte(b, &v))
        return 0;
      lua_pushboolean(L, v);
      break;
    }
    case SER_INT: {
      lua_Integer i;
      if (!deser_read(b, &i, sizeof(i)))
        return 0;
      lua_pushinteger(L, i);
      break;
    }
    case SER_NUM: {
      lua_Number n;
      if (!deser_read(b, &n, sizeof(n)))
        return 0;
      lua_pushnumber(L, n);
      break;
    }
    case SER_STRING: {
      size_t len;
      if (!deser_read(b, &len, sizeof(len)))
        return 0;
      if (len > b->size - b->pos)
        return 0;
      lua_pushlstring(L, b->data + b->pos, len);
      b->pos += len;
      break;
    }
    case SER_TABLE: return deserialize_table(L, b, depth + 1);
    default: return 0;
  }
  return 1;
}

/* }====================================================== */

/*
** {======================================================
** Worker State Management
** =======================================================
*/

static void worker_state_shutdown(lua_State *L);

static void worker_domain_destroy(WorkerDomain *domain) {
  lus_cond_destroy(&domain->idle_cond);
  lus_mutex_destroy(&domain->mutex);
  free(domain);
}

static WorkerDomain *worker_domain_get(lua_State *L) {
  global_State *g = G(L);
  WorkerDomain *domain = g->workerdomain;
  if (domain != NULL)
    return domain;

  domain = (WorkerDomain *)malloc(sizeof(WorkerDomain));
  if (domain == NULL)
    return NULL;
  memset(domain, 0, sizeof(WorkerDomain));
  lus_mutex_init(&domain->mutex);
  lus_cond_init(&domain->idle_cond);
  domain->refcount = 1; /* owning global_State */
  g->workerdomain = domain;
  g->worker_close = worker_state_shutdown;
  return domain;
}

static int worker_domain_attach(WorkerDomain *domain, WorkerState *w) {
  int attached = 0;
  lus_mutex_lock(&domain->mutex);
  if (!domain->closing) {
    w->domain = domain;
    w->domain_next = domain->workers;
    domain->workers = w;
    domain->refcount++; /* WorkerState owns a domain reference */
    attached = 1;
  }
  lus_mutex_unlock(&domain->mutex);
  return attached;
}

static void worker_domain_detach(WorkerState *w) {
  WorkerDomain *domain = w->domain;
  int destroy = 0;
  if (domain == NULL)
    return;

  lus_mutex_lock(&domain->mutex);
  WorkerState **link = &domain->workers;
  while (*link != NULL && *link != w)
    link = &(*link)->domain_next;
  if (*link == w)
    *link = w->domain_next;
  w->domain = NULL;
  w->domain_next = NULL;
  domain->refcount--;
  destroy = (domain->refcount == 0);
  lus_mutex_unlock(&domain->mutex);
  if (destroy)
    worker_domain_destroy(domain);
}

static int worker_domain_start(WorkerState *w) {
  WorkerDomain *domain = w->domain;
  int started = 0;
  lus_mutex_lock(&domain->mutex);
  if (!domain->closing) {
    domain->active_count++;
    w->domain_active = 1;
    started = 1;
  }
  lus_mutex_unlock(&domain->mutex);
  return started;
}

static void worker_domain_complete(WorkerState *w) {
  WorkerDomain *domain = w->domain;
  if (domain == NULL)
    return;
  lus_mutex_lock(&domain->mutex);
  if (w->domain_active) {
    w->domain_active = 0;
    domain->active_count--;
    if (domain->active_count == 0)
      lus_cond_broadcast(&domain->idle_cond);
  }
  lus_mutex_unlock(&domain->mutex);
}

/*
** Remove work owned by one state before waiting for its domain to become
** idle. Pool lifecycle serialization keeps the queue mutex alive throughout
** the scan. A stopping process pool has already detached the complete queue
** and will finish those workers itself.
*/
static WorkerState *pool_cancel_domain_queued(WorkerDomain *domain) {
  WorkerState *cancelled_head = NULL;
  WorkerState *cancelled_tail = NULL;

  pool_lifecycle_lock();
  if (g_pool.initialized && !g_pool.stopping) {
    WorkerState *previous = NULL;
    WorkerState *worker;

    lus_mutex_lock(&g_pool.queue_mutex);
    worker = g_pool.runnable_head;
    while (worker != NULL) {
      WorkerState *next = worker->next;
      if (worker->domain == domain) {
        if (previous != NULL)
          previous->next = next;
        else
          g_pool.runnable_head = next;
        if (g_pool.runnable_tail == worker)
          g_pool.runnable_tail = previous;

        worker->next = NULL;
        if (cancelled_tail != NULL)
          cancelled_tail->next = worker;
        else
          cancelled_head = worker;
        cancelled_tail = worker;
      }
      else
        previous = worker;
      worker = next;
    }
    lus_mutex_unlock(&g_pool.queue_mutex);
  }
  pool_lifecycle_unlock();
  return cancelled_head;
}

static void worker_state_shutdown(lua_State *L) {
  global_State *g = G(L);
  WorkerDomain *domain = g->workerdomain;
  WorkerState *cancelled;
  int destroy;
  if (domain == NULL)
    return;

  lus_mutex_lock(&domain->mutex);
  domain->closing = 1;
  for (WorkerState *w = domain->workers; w != NULL; w = w->domain_next) {
    lus_mutex_lock(&w->mutex);
    w->shutdown = 1;
    lus_cond_broadcast(&w->inbox_cond);
    lus_cond_broadcast(&w->outbox_cond);
    if (w->recv_ctx != NULL) {
      lus_mutex_lock(&w->recv_ctx->mutex);
      w->recv_ctx->ready = 1;
      lus_cond_signal(&w->recv_ctx->cond);
      lus_mutex_unlock(&w->recv_ctx->mutex);
    }
    lus_mutex_unlock(&w->mutex);
  }

  /* Release the domain lock before taking the process-pool locks. Enqueue
  ** checks the shutdown bit while holding the lifecycle lock, so a worker
  ** that passed worker_domain_start just before closing either appears in
  ** this cancellation scan or declines to join the queue. */
  lus_mutex_unlock(&domain->mutex);
  cancelled = pool_cancel_domain_queued(domain);

  while (cancelled != NULL) {
    WorkerState *next = cancelled->next;
    cancelled->next = NULL;
    lus_mutex_lock(&cancelled->mutex);
    cancelled->shutdown = 1;
    cancelled->status = LUS_WORKER_DEAD;
    lus_cond_broadcast(&cancelled->inbox_cond);
    lus_cond_broadcast(&cancelled->outbox_cond);
    signal_recv_ctx(cancelled);
    worker_domain_complete(cancelled);
    lus_worker_release(cancelled); /* runnable queue reference */
    cancelled = next;
  }

  lus_mutex_lock(&domain->mutex);
  while (domain->active_count != 0)
    lus_cond_wait(&domain->idle_cond, &domain->mutex);

  g->workerdomain = NULL;
  g->worker_close = NULL;
  domain->refcount--; /* owning global_State */
  destroy = (domain->refcount == 0);
  lus_mutex_unlock(&domain->mutex);
  if (destroy)
    worker_domain_destroy(domain);
}

static WorkerState *worker_new(lua_State *parent, const char *path,
                               int script_fd, int script_errno) {
  WorkerDomain *domain = worker_domain_get(parent);
  WorkerState *w = (WorkerState *)malloc(sizeof(WorkerState));
  if (domain == NULL || w == NULL) {
    if (script_fd >= 0)
      worker_closefd(script_fd);
    free(w);
    return NULL;
  }

  memset(w, 0, sizeof(WorkerState));
  /* Domain ownership and callbacks follow the global state. Keeping the main
  ** thread here also prevents a collected coroutine from becoming a dangling
  ** asynchronous parent pointer. */
  w->parent = mainthread(G(parent));
  w->setup = G(parent)->worker_setup;
  w->script_path = strdup(path);
  if (w->script_path == NULL) {
    if (script_fd >= 0)
      worker_closefd(script_fd);
    free(w);
    return NULL;
  }
  w->status = LUS_WORKER_RUNNING;
  w->refcount = 1;
  w->recv_ctx = NULL;
  w->script_fd = script_fd;
  w->script_errno = script_errno;

  lus_mutex_init(&w->mutex);
  lus_cond_init(&w->outbox_cond);
  lus_cond_init(&w->inbox_cond);
  msgqueue_init(&w->outbox);
  msgqueue_init(&w->inbox);

  if (!worker_domain_attach(domain, w)) {
    lus_cond_destroy(&w->outbox_cond);
    lus_cond_destroy(&w->inbox_cond);
    lus_mutex_destroy(&w->mutex);
    free(w->script_path);
    if (w->script_fd >= 0)
      worker_closefd(w->script_fd);
    free(w);
    return NULL;
  }

  return w;
}

LUA_API WorkerState *lus_worker_retain(WorkerState *w) {
  if (w == NULL)
    return NULL;
  lus_mutex_lock(&w->mutex);
  w->refcount++;
  lus_mutex_unlock(&w->mutex);
  return w;
}

LUA_API void lus_worker_release(WorkerState *w) {
  int should_free = 0;
  if (w == NULL)
    return;
  lus_mutex_lock(&w->mutex);
  w->refcount--;
  if (w->refcount <= 0)
    should_free = 1;
  lus_mutex_unlock(&w->mutex);

  if (should_free) {
    if (w->L)
      lua_close(w->L);
    worker_domain_detach(w);
    free(w->script_path);
    if (w->script_fd >= 0)
      worker_closefd(w->script_fd);
    free(w->error_msg);
    msgqueue_clear(&w->outbox);
    msgqueue_clear(&w->inbox);
    lus_cond_destroy(&w->outbox_cond);
    lus_cond_destroy(&w->inbox_cond);
    lus_mutex_destroy(&w->mutex);
    free(w);
  }
}

/* }====================================================== */

/*
** Signal the receive context if a receiver is waiting.
** Call with worker mutex already locked. Holds w->mutex while signaling
** ctx to prevent lib_receive from destroying ctx on the stack before we
** finish accessing it. No deadlock: lib_receive never holds both mutexes.
*/
static void signal_recv_ctx(WorkerState *w) {
  ReceiveContext *ctx = w->recv_ctx;
  if (ctx) {
    lus_mutex_lock(&ctx->mutex);
    ctx->ready = 1; /* set flag before signal to prevent lost wakeup */
    lus_cond_signal(&ctx->cond);
    lus_mutex_unlock(&ctx->mutex);
  }
  lus_mutex_unlock(&w->mutex);
}

/*
** {======================================================
** Thread Pool
** =======================================================
*/

static int pool_enqueue(WorkerState *w) {
  if (!worker_domain_start(w))
    return 0;

  pool_lifecycle_lock();
  if (!g_pool.initialized || g_pool.shutdown) {
    pool_lifecycle_unlock();
    worker_domain_complete(w);
    return 0;
  }

  /* State close can begin after worker_domain_start and before this lifecycle
  ** lock. Recheck its shutdown mark before making the active count visible in
  ** the runnable queue. Holding the lifecycle lock makes this check atomic
  ** with the domain cancellation scan. */
  lus_mutex_lock(&w->mutex);
  int shutting_down = w->shutdown;
  lus_mutex_unlock(&w->mutex);
  if (shutting_down) {
    pool_lifecycle_unlock();
    worker_domain_complete(w);
    return 0;
  }

  lus_worker_retain(w); /* runnable queue and pool thread */
  lus_mutex_lock(&g_pool.queue_mutex);
  w->next = NULL;
  if (g_pool.runnable_tail) {
    g_pool.runnable_tail->next = w;
  }
  else {
    g_pool.runnable_head = w;
  }
  g_pool.runnable_tail = w;
  lus_cond_signal(&g_pool.queue_cond);
  lus_mutex_unlock(&g_pool.queue_mutex);
  pool_lifecycle_unlock();
  return 1;
}

/*
** Track workers currently running on pool threads so shutdown can wake
** any of them blocked in worker.peek. If shutdown already started when a
** worker registers (dequeued just before the flag flipped), mark it
** immediately: it would otherwise miss the shutdown broadcast.
*/
static void pool_register_active(WorkerState *w) {
  lus_mutex_lock(&g_pool.queue_mutex);
  w->active_next = g_pool.active_head;
  g_pool.active_head = w;
  if (g_pool.shutdown) {
    lus_mutex_lock(&w->mutex);
    w->shutdown = 1;
    lus_mutex_unlock(&w->mutex);
  }
  lus_mutex_unlock(&g_pool.queue_mutex);
}

static void pool_unregister_active(WorkerState *w) {
  lus_mutex_lock(&g_pool.queue_mutex);
  WorkerState **p = &g_pool.active_head;
  while (*p && *p != w)
    p = &(*p)->active_next;
  if (*p)
    *p = w->active_next;
  w->active_next = NULL;
  lus_mutex_unlock(&g_pool.queue_mutex);
}

static WorkerState *pool_dequeue(void) {
  lus_mutex_lock(&g_pool.queue_mutex);
  while (!g_pool.runnable_head && !g_pool.shutdown) {
    lus_cond_wait(&g_pool.queue_cond, &g_pool.queue_mutex);
  }
  if (g_pool.shutdown) {
    lus_mutex_unlock(&g_pool.queue_mutex);
    return NULL;
  }
  WorkerState *w = g_pool.runnable_head;
  g_pool.runnable_head = w->next;
  if (!g_pool.runnable_head)
    g_pool.runnable_tail = NULL;
  w->next = NULL;
  lus_mutex_unlock(&g_pool.queue_mutex);
  return w;
}

/* Worker thread: get global worker object to call worker.message */
static int worker_lib_message(lua_State *L) {
  /* Get worker state from registry */
  lua_getfield(L, LUA_REGISTRYINDEX, "_WORKER_STATE");
  WorkerState *w = (WorkerState *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (!w)
    return luaL_error(L, "worker.message called outside worker context");

  /* Serialize the value */
  SerBuffer buf;
  serbuf_init(&buf);
  if (!serialize_value(L, 1, &buf, 0)) {
    serbuf_free(&buf); /* 'err'/'errarg' are static strings; safe after free */
    return luaL_error(L, buf.err ? buf.err : "worker serialization failed",
                      buf.errarg);
  }

  /* Push to outbox - ownership of arena transfers to message queue */
  lus_mutex_lock(&w->mutex);
  if (!msgqueue_push(&w->outbox, buf.arena, buf.data, buf.size)) {
    lus_mutex_unlock(&w->mutex);
    serbuf_free(&buf);
    return luaL_error(L, "out of memory");
  }
  lus_cond_signal(&w->outbox_cond);

  /* Signal multi-worker select if receiver is waiting.
  ** Hold w->mutex while accessing ctx to prevent lib_receive from
  ** destroying the stack-allocated ReceiveContext before we finish. */
  ReceiveContext *ctx = w->recv_ctx;
  if (ctx) {
    lus_mutex_lock(&ctx->mutex);
    ctx->ready = 1; /* set flag before signal to prevent lost wakeup */
    lus_cond_signal(&ctx->cond);
    lus_mutex_unlock(&ctx->mutex);
  }
  lus_mutex_unlock(&w->mutex);

  return 0;
}

/* Worker thread: peek message from inbox */
static int worker_lib_peek(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, "_WORKER_STATE");
  WorkerState *w = (WorkerState *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (!w)
    return luaL_error(L, "worker.peek called outside worker context");

  StandaloneArena *arena = NULL;
  char *data = NULL;
  size_t size = 0;

  lus_mutex_lock(&w->mutex);
  while (w->inbox.count == 0 && !w->shutdown) {
    /* Block until message arrives */
    lus_cond_wait(&w->inbox_cond, &w->mutex);
  }
  if (w->inbox.count == 0) { /* woken by pool shutdown */
    lus_mutex_unlock(&w->mutex);
    /* This unwind must not be interceptable by ANYTHING in the worker
    ** script -- neither a 'catch' retry loop nor an intermediate C
    ** protection (e.g. worker.peek called from a load() reader): either
    ** would keep the pool thread from reaching pool_dequeue and hang
    ** interpreter exit in pthread_join. Free the script's catch chain
    ** and longjmp directly to the BASE C protection (worker_run's
    ** pcall). Intermediate luaD_pcall frames are skipped entirely, so
    ** their C-local saved catch pointers are never restored -- which is
    ** exactly why the freed nodes cannot be observed afterwards. */
    lua_pushliteral(L, "worker.peek interrupted: interpreter shutting down");
    luaE_clearcatch(L);
    luaD_throwbaselevel(L, LUA_ERRRUN);
  }
  msgqueue_pop(&w->inbox, &arena, &data, &size);
  lus_mutex_unlock(&w->mutex);

  /* Deserialize */
  DeserBuffer db = {data, size, 0};
  if (!deserialize_value(L, &db, 0)) {
    luaA_freestandalone(arena);
    return luaL_error(L, "failed to deserialize message");
  }
  luaA_freestandalone(arena);
  return 1;
}

/* Run worker script in its own Lua state */
/*
** Protected pledge inheritance: luaP_copypledges allocates with the
** throwing luaM_* functions, and worker_run has no active protected
** frame -- an unprotected memory error would abort the process.
*/
static int copy_pledges_protected(lua_State *L) {
  lua_State *parent = (lua_State *)lua_touserdata(L, 1);
  PledgeStore *inherited = luaP_copypledges(L, parent->pledges);
  if (inherited != NULL) {
    luaP_freepledges(L, L->pledges); /* drop the fresh granter-only store */
    L->pledges = inherited;
  }
  return 0;
}

static void worker_run(WorkerState *w) {
  lus_mutex_lock(&w->mutex);
  if (w->shutdown) {
    w->status = LUS_WORKER_DEAD;
    lus_cond_signal(&w->outbox_cond);
    signal_recv_ctx(w);
    return;
  }
  lus_mutex_unlock(&w->mutex);

  lua_State *L = luaL_newstate();
  if (!L) {
    lus_mutex_lock(&w->mutex);
    w->status = LUS_WORKER_ERROR;
    w->error_msg = strdup("failed to create Lua state");
    if (!w->error_msg)
      w->status = LUS_WORKER_DEAD;
    lus_cond_signal(&w->outbox_cond); /* wake blocked receive */
    signal_recv_ctx(w);               /* wake multi-worker select */
    return;
  }
  w->L = L;
  /* Mark this state as a worker body. When its last handle is dropped the
  ** state closes on a pool thread, and close_state must not let that reenter
  ** the pool shutdown that only the owning interpreter performs. */
  G(L)->isworker = 1;

  /* Call the setup callback if registered */
  if (w->setup != NULL) {
    w->setup(w->parent, L);
  }

  /* Inherit the parent's pledges, then seal them. A worker must run with the
  ** SAME permissions as its parent (it needs them e.g. to load its own script
  ** file and to do whatever I/O the parent allowed) but must not be able to
  ** grant itself MORE -- otherwise spawning a worker would be a sandbox escape
  ** (the fresh state starts with an unsealed, empty store the worker could
  ** pledge() itself out of). The copy uses the worker's own allocator. The
  ** parent configures its pledges before spawning workers, so its store is
  ** stable to read here. */
  if (w->parent != NULL) {
    lua_pushcfunction(L, copy_pledges_protected);
    lua_pushlightuserdata(L, w->parent);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
      lus_mutex_lock(&w->mutex);
      w->status = LUS_WORKER_ERROR;
      w->error_msg = strdup("failed to inherit pledges (out of memory)");
      if (!w->error_msg)
        w->status = LUS_WORKER_DEAD;
      lus_cond_signal(&w->outbox_cond); /* wake blocked receive */
      signal_recv_ctx(w);               /* wake multi-worker select */
      return;
    }
  }
  luaP_sealpledges(L); /* worker cannot escalate its own pledges */

  /* Store worker state pointer in registry */
  lua_pushlightuserdata(L, w);
  lua_setfield(L, LUA_REGISTRYINDEX, "_WORKER_STATE");

  /* Register worker.message and worker.peek in the worker table. Under
  ** --readonly-env the setup callback has already frozen the module
  ** tables, so lift the readonly bit for this runtime-internal setup
  ** step and restore it (user code never observes the table mutable). */
  lua_getglobal(L, "worker");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_setglobal(L, "worker");
    lua_getglobal(L, "worker");
  }
  {
    Table *wt = hvalue(s2v(L->top.p - 1));
    int was_readonly = isreadonly(wt);
    if (was_readonly)
      wt->flags = cast_byte(wt->flags & ~BITREADONLY);
    lua_pushcfunction(L, worker_lib_message);
    lua_setfield(L, -2, "message");
    lua_pushcfunction(L, worker_lib_peek);
    lua_setfield(L, -2, "peek");
    if (was_readonly)
      setreadonly(wt);
  }
  lua_pop(L, 1);

  /* Deserialize and push initial arguments from inbox */
  int nargs = w->nargs;
  for (int i = 0; i < nargs; i++) {
    StandaloneArena *arena;
    char *data;
    size_t size;
    lus_mutex_lock(&w->mutex);
    int got = msgqueue_pop(&w->inbox, &arena, &data, &size);
    lus_mutex_unlock(&w->mutex);
    if (!got)
      break; /* shouldn't happen if nargs was set correctly */
    DeserBuffer db = {data, size, 0};
    if (!deserialize_value(L, &db, 0)) {
      luaA_freestandalone(arena);
      lus_mutex_lock(&w->mutex);
      w->status = LUS_WORKER_ERROR;
      w->error_msg = strdup("failed to deserialize initial argument");
      if (!w->error_msg)
        w->status = LUS_WORKER_DEAD;
      lus_cond_signal(&w->outbox_cond);
      signal_recv_ctx(w); /* wake multi-worker select */
      return;
    }
    luaA_freestandalone(arena);
  }

  /* Load and run the script */
  int load_status;
  if (w->script_fd < 0) {
    lua_pushfstring(L, "cannot open worker script '%s': %s", w->script_path,
                    strerror(w->script_errno));
    load_status = LUA_ERRFILE;
  }
  else {
    load_status = luaAP_loadfd(L, w->script_fd, w->script_path,
                               lus_issealed(L) ? "t" : "bt");
  }
  if (load_status != LUA_OK) {
    lus_mutex_lock(&w->mutex);
    w->status = LUS_WORKER_ERROR;
    const char *err = lua_tostring(L, -1);
    w->error_msg = strdup(err ? err : "unknown load error");
    if (!w->error_msg)
      w->status = LUS_WORKER_DEAD;
    lus_cond_signal(&w->outbox_cond); /* wake blocked receive */
    signal_recv_ctx(w);               /* wake multi-worker select */
    return;
  }

  /* Move function below arguments */
  if (nargs > 0) {
    lua_insert(L, -(nargs + 1)); /* move chunk under args */
  }

  if (lua_pcall(L, nargs, 0, 0) != LUA_OK) {
    lus_mutex_lock(&w->mutex);
    w->status = LUS_WORKER_ERROR;
    const char *err = lua_tostring(L, -1);
    w->error_msg = strdup(err ? err : "unknown runtime error");
    if (!w->error_msg)
      w->status = LUS_WORKER_DEAD;
    lus_cond_signal(&w->outbox_cond); /* wake blocked receive */
    signal_recv_ctx(w);               /* wake multi-worker select */
    return;
  }

  lus_mutex_lock(&w->mutex);
  w->status = LUS_WORKER_DEAD;
  lus_cond_signal(&w->outbox_cond); /* wake blocked receive */
  signal_recv_ctx(w);               /* wake multi-worker select */
}

/* Pool thread function */
#if defined(LUS_PLATFORM_WINDOWS)
static DWORD WINAPI pool_thread_func(LPVOID arg) {
#else
static void *pool_thread_func(void *arg) {
#endif
  (void)arg;
  while (1) {
    WorkerState *w = pool_dequeue();
    if (!w)
      break; /* shutdown */
    pool_register_active(w);
    worker_run(w);
    pool_unregister_active(w);
    worker_domain_complete(w);
    lus_worker_release(w);
  }
#if defined(LUS_PLATFORM_WINDOWS)
  return 0;
#else
  return NULL;
#endif
}

/*
** Pool threads deserialize incoming messages with the recursive deserializer,
** which permits table nesting up to the same depth the serializer allows. The
** platform default thread stack (about 512KB on macOS) overflows well before
** that cap, crashing the process instead of reporting a clean error. Give pool
** threads a stack large enough that the documented depth is actually safe.
*/
#define LUS_WORKER_STACK_SIZE (8 * 1024 * 1024)

static void worker_pool_init_locked(void) {
  int started;
  if (g_pool.initialized || g_pool.stopping)
    return;

  g_pool.nthreads = get_cpu_count();
  if (g_pool.nthreads < 1)
    g_pool.nthreads = 1;
  if (g_pool.nthreads > 32)
    g_pool.nthreads = 32;

  g_pool.threads =
      (lus_thread_t *)malloc(sizeof(lus_thread_t) * g_pool.nthreads);
  if (g_pool.threads == NULL)
    return;
  lus_mutex_init(&g_pool.queue_mutex);
  lus_cond_init(&g_pool.queue_cond);
  g_pool.runnable_head = NULL;
  g_pool.runnable_tail = NULL;
  g_pool.active_head = NULL;
  g_pool.shutdown = 0;
  g_pool.stopping = 0;

#if !defined(LUS_PLATFORM_WINDOWS)
  pthread_attr_t attr;
  int have_attr = (pthread_attr_init(&attr) == 0);
  if (have_attr)
    pthread_attr_setstacksize(&attr, LUS_WORKER_STACK_SIZE);
#endif
  started = 0;
  for (int i = 0; i < g_pool.nthreads; i++) {
#if defined(LUS_PLATFORM_WINDOWS)
    g_pool.threads[i] = CreateThread(NULL, LUS_WORKER_STACK_SIZE,
                                     pool_thread_func, NULL, 0, NULL);
    if (g_pool.threads[i] == NULL)
      break;
#else
    if (pthread_create(&g_pool.threads[i], have_attr ? &attr : NULL,
                       pool_thread_func, NULL) != 0)
      break;
#endif
    started++;
  }
#if !defined(LUS_PLATFORM_WINDOWS)
  if (have_attr)
    pthread_attr_destroy(&attr);
#endif
  g_pool.nthreads = started;
  if (started == 0) {
    free(g_pool.threads);
    g_pool.threads = NULL;
    lus_cond_destroy(&g_pool.queue_cond);
    lus_mutex_destroy(&g_pool.queue_mutex);
    return;
  }

  g_pool.initialized = 1;
}

LUA_API void lus_worker_pool_init(lua_State *L) {
  (void)L;
  pool_lifecycle_lock();
  worker_pool_init_locked();
  pool_lifecycle_unlock();
}

LUA_API void lus_worker_pool_shutdown(void) {
  WorkerState *queued;
  pool_lifecycle_lock();
  if (!g_pool.initialized || g_pool.stopping) {
    pool_lifecycle_unlock();
    return;
  }
  g_pool.stopping = 1;

  lus_mutex_lock(&g_pool.queue_mutex);
  g_pool.shutdown = 1;
  lus_cond_broadcast(&g_pool.queue_cond);
  queued = g_pool.runnable_head;
  g_pool.runnable_head = NULL;
  g_pool.runnable_tail = NULL;
  /* wake running workers blocked in worker.peek so their threads can
     unwind and reach the shutdown check in pool_dequeue */
  for (WorkerState *w = g_pool.active_head; w != NULL; w = w->active_next) {
    lus_mutex_lock(&w->mutex);
    w->shutdown = 1;
    lus_cond_broadcast(&w->inbox_cond);
    lus_mutex_unlock(&w->mutex);
  }
  lus_mutex_unlock(&g_pool.queue_mutex);
  pool_lifecycle_unlock();

  /* Queued workers will not be picked up after shutdown. Complete them before
  ** joining so an active worker that owns one can finish its state teardown. */
  while (queued != NULL) {
    WorkerState *next = queued->next;
    queued->next = NULL;
    lus_mutex_lock(&queued->mutex);
    queued->shutdown = 1;
    queued->status = LUS_WORKER_DEAD;
    lus_cond_broadcast(&queued->inbox_cond);
    lus_cond_broadcast(&queued->outbox_cond);
    signal_recv_ctx(queued);
    worker_domain_complete(queued);
    lus_worker_release(queued); /* runnable queue reference */
    queued = next;
  }

  for (int i = 0; i < g_pool.nthreads; i++) {
#if defined(LUS_PLATFORM_WINDOWS)
    WaitForSingleObject(g_pool.threads[i], INFINITE);
    CloseHandle(g_pool.threads[i]);
#else
    pthread_join(g_pool.threads[i], NULL);
#endif
  }

  pool_lifecycle_lock();
  free(g_pool.threads);
  g_pool.threads = NULL;
  lus_cond_destroy(&g_pool.queue_cond);
  lus_mutex_destroy(&g_pool.queue_mutex);
  g_pool.initialized = 0;
  g_pool.shutdown = 0;
  g_pool.stopping = 0;
  pool_lifecycle_unlock();
}

LUA_API void lus_onworker(lua_State *L, lus_WorkerSetup fn) {
  G(L)->worker_setup = fn;
}

/* }====================================================== */

/*
** {======================================================
** Lua Library Functions
** =======================================================
*/

static WorkerState *check_worker(lua_State *L, int idx) {
  WorkerState *w = *(WorkerState **)luaL_checkudata(L, idx, WORKER_METATABLE);
  if (w == NULL)
    luaL_argerror(L, idx, "released worker handle");
  return w;
}

/* worker.create(path, ...) */
static int lib_create(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int script_fd = -1;
  int script_errno = 0;

  /* Check permissions */
  if (!lus_haspledge(L, "load", NULL)) {
    return luaL_error(L, "permission denied: 'load' pledge required");
  }
#if defined(LUS_PLATFORM_WINDOWS)
  script_fd = luaAP_winopenfd(L, path, 1, 0);
#else
  script_fd = luaAP_open(L, path, O_RDONLY | O_CLOEXEC, 0, 1, 0);
#endif
  if (script_fd < 0)
    script_errno = errno;

  /* Initialize pool if needed */
  lus_worker_pool_init(L);

  /* Create worker state */
  WorkerState *w = worker_new(L, path, script_fd, script_errno);
  if (!w)
    return luaL_error(L, "failed to allocate worker");

  /* Serialize initial arguments (varargs after path) */
  int nargs = lua_gettop(L) - 1;
  for (int i = 2; i <= nargs + 1; i++) {
    SerBuffer buf;
    serbuf_init(&buf);
    if (!serialize_value(L, i, &buf, 0)) {
      lus_worker_release(w);
      serbuf_free(&buf);
      return luaL_error(L, buf.err ? buf.err : "worker serialization failed",
                        buf.errarg);
    }
    lus_mutex_lock(&w->mutex);
    if (!msgqueue_push(&w->inbox, buf.arena, buf.data, buf.size)) {
      lus_mutex_unlock(&w->mutex);
      serbuf_free(&buf);
      lus_worker_release(w);
      return luaL_error(L, "out of memory");
    }
    lus_mutex_unlock(&w->mutex);
  }
  w->nargs = nargs;

  /* Create userdata */
  WorkerState **ud =
      (WorkerState **)lua_newuserdatauv(L, sizeof(WorkerState *), 0);
  *ud = w; /* transfer worker_new's owned reference to the userdata */
  luaL_setmetatable(L, WORKER_METATABLE);

  /* Enqueue to pool */
  if (!pool_enqueue(w)) {
    *ud = NULL;
    lus_worker_release(w);
    return luaL_error(L, "failed to start worker thread pool");
  }

  return 1;
}

/* worker.status(w) */
static int lib_status(lua_State *L) {
  WorkerState *w = check_worker(L, 1);
  lus_mutex_lock(&w->mutex);
  int status = w->status;
  lus_mutex_unlock(&w->mutex);

  switch (status) {
    case LUS_WORKER_RUNNING:
    case LUS_WORKER_BLOCKED: lua_pushliteral(L, "running"); break;
    default: lua_pushliteral(L, "dead"); break;
  }
  return 1;
}

/* worker.receive(w1, w2, ...) - select-style */
static int lib_receive(lua_State *L) {
  int nworkers = lua_gettop(L);
  if (nworkers == 0)
    return luaL_error(L, "expected at least one worker");

  /* validate all arguments before malloc: check_worker raises on bad
     arguments and would leak the array */
  for (int i = 0; i < nworkers; i++) {
    check_worker(L, i + 1);
  }
  WorkerState **workers =
      (WorkerState **)malloc(sizeof(WorkerState *) * nworkers);
  if (workers == NULL)
    return luaL_error(L, "out of memory");
  for (int i = 0; i < nworkers; i++) {
    workers[i] = *(WorkerState **)lua_touserdata(L, i + 1);
  }

  /* Create shared receive context for multi-worker select */
  ReceiveContext ctx;
  lus_mutex_init(&ctx.mutex);
  lus_cond_init(&ctx.cond);
  ctx.ready = 0;

  /* Register this context with each worker */
  for (int i = 0; i < nworkers; i++) {
    lus_mutex_lock(&workers[i]->mutex);
    workers[i]->recv_ctx = &ctx;
    lus_mutex_unlock(&workers[i]->mutex);
  }

  int result = 0;

  /* Try to get message from any worker */
  while (1) {
    int all_dead = 1;

    /* Check each worker */
    for (int i = 0; i < nworkers; i++) {
      WorkerState *w = workers[i];
      lus_mutex_lock(&w->mutex);

      if (w->status == LUS_WORKER_ERROR && w->error_msg) {
        char *errmsg = strdup(w->error_msg);
        lus_mutex_unlock(&w->mutex);
        /* Cleanup before error */
        for (int k = 0; k < nworkers; k++) {
          lus_mutex_lock(&workers[k]->mutex);
          workers[k]->recv_ctx = NULL;
          lus_mutex_unlock(&workers[k]->mutex);
        }
        lus_cond_destroy(&ctx.cond);
        lus_mutex_destroy(&ctx.mutex);
        free(workers);
        lua_pushstring(L, errmsg ? errmsg : "worker error");
        free(errmsg);
        return lua_error(L);
      }

      if (w->status != LUS_WORKER_DEAD && w->status != LUS_WORKER_ERROR) {
        all_dead = 0;
      }

      StandaloneArena *arena;
      char *data;
      size_t size;
      if (msgqueue_pop(&w->outbox, &arena, &data, &size)) {
        lus_mutex_unlock(&w->mutex);
        /* Deserialize and return */
        DeserBuffer db = {data, size, 0};
        /* Push nils for workers before this one */
        for (int j = 0; j < i; j++)
          lua_pushnil(L);
        if (!deserialize_value(L, &db, 0)) {
          luaA_freestandalone(arena);
          /* Cleanup */
          for (int k = 0; k < nworkers; k++) {
            lus_mutex_lock(&workers[k]->mutex);
            workers[k]->recv_ctx = NULL;
            lus_mutex_unlock(&workers[k]->mutex);
          }
          lus_cond_destroy(&ctx.cond);
          lus_mutex_destroy(&ctx.mutex);
          free(workers);
          return luaL_error(L, "failed to deserialize message");
        }
        luaA_freestandalone(arena);
        /* Push nils for remaining workers */
        for (int j = i + 1; j < nworkers; j++)
          lua_pushnil(L);
        result = nworkers;
        goto cleanup;
      }
      lus_mutex_unlock(&w->mutex);
    }

    /* If all dead and no messages, return all nils */
    if (all_dead) {
      for (int i = 0; i < nworkers; i++)
        lua_pushnil(L);
      result = nworkers;
      goto cleanup;
    }

    /* Wait on shared condition - any worker can wake us */
    /* Hold mutex during check-and-wait to prevent lost wakeup race */
    lus_mutex_lock(&ctx.mutex);
    while (!ctx.ready) {
      lus_cond_wait(&ctx.cond, &ctx.mutex);
    }
    ctx.ready = 0; /* reset for next iteration */
    lus_mutex_unlock(&ctx.mutex);
  }

cleanup:
  /* Unregister context from all workers */
  for (int i = 0; i < nworkers; i++) {
    lus_mutex_lock(&workers[i]->mutex);
    workers[i]->recv_ctx = NULL;
    lus_mutex_unlock(&workers[i]->mutex);
  }
  lus_cond_destroy(&ctx.cond);
  lus_mutex_destroy(&ctx.mutex);
  free(workers);
  return result;
}

/* worker.send(w, value) */
static int lib_send(lua_State *L) {
  WorkerState *w = check_worker(L, 1);

  /* Serialize the value */
  SerBuffer buf;
  serbuf_init(&buf);
  if (!serialize_value(L, 2, &buf, 0)) {
    serbuf_free(&buf);
    return luaL_error(L, buf.err ? buf.err : "worker serialization failed",
                      buf.errarg);
  }

  /* Push to inbox - ownership of arena transfers to message queue */
  lus_mutex_lock(&w->mutex);
  if (!msgqueue_push(&w->inbox, buf.arena, buf.data, buf.size)) {
    lus_mutex_unlock(&w->mutex);
    serbuf_free(&buf);
    return luaL_error(L, "out of memory");
  }
  lus_cond_signal(&w->inbox_cond);
  lus_mutex_unlock(&w->mutex);

  return 0;
}

/* GC metamethod */
static int worker_gc(lua_State *L) {
  WorkerState **ud = (WorkerState **)luaL_checkudata(L, 1, WORKER_METATABLE);
  WorkerState *w = *ud;
  *ud = NULL;
  lus_worker_release(w);
  return 0;
}

/* __tostring metamethod */
static int worker_tostring(lua_State *L) {
  WorkerState *w = check_worker(L, 1);
  lua_pushfstring(L, "worker: %p", (void *)w);
  return 1;
}

static const luaL_Reg worker_methods[] = {{"create", lib_create},
                                          {"status", lib_status},
                                          {"receive", lib_receive},
                                          {"send", lib_send},
                                          {NULL, NULL}};

static const luaL_Reg worker_meta[] = {
    {"__gc", worker_gc}, {"__tostring", worker_tostring}, {NULL, NULL}};

LUAMOD_API int luaopen_worker(lua_State *L) {
  /* Create metatable */
  luaL_newmetatable(L, WORKER_METATABLE);
  luaL_setfuncs(L, worker_meta, 0);
  lua_pop(L, 1);

  /* Create library table */
  luaL_newlib(L, worker_methods);

  /* Set as global */
  lua_pushvalue(L, -1);
  lua_setglobal(L, "worker");

  return 1;
}

/* }====================================================== */

/*
** {======================================================
** C API Implementation
** =======================================================
*/

LUA_API WorkerState *lus_worker_create(lua_State *L, const char *path) {
  int script_fd = -1;
  int script_errno = 0;
#if defined(LUS_PLATFORM_WINDOWS)
  script_fd = luaAP_winopenrawfd(path);
#else
  script_fd = open(path, O_RDONLY | O_CLOEXEC);
#endif
  if (script_fd < 0)
    script_errno = errno;
  lus_worker_pool_init(L);
  WorkerState *w = worker_new(L, path, script_fd, script_errno);
  if (w == NULL)
    return NULL;
  if (!pool_enqueue(w)) {
    lus_worker_release(w);
    return NULL;
  }
  return w;
}

LUA_API int lus_worker_send(lua_State *L, WorkerState *w, int idx) {
  if (w == NULL)
    return 0;
  lus_worker_retain(w);
  SerBuffer buf;
  serbuf_init(&buf);
  if (!serialize_value(L, idx, &buf, 0)) {
    serbuf_free(&buf);
    lus_worker_release(w);
    return 0;
  }
  lus_mutex_lock(&w->mutex);
  if (w->shutdown || !msgqueue_push(&w->inbox, buf.arena, buf.data, buf.size)) {
    lus_mutex_unlock(&w->mutex);
    serbuf_free(&buf);
    lus_worker_release(w);
    return 0;
  }
  lus_cond_signal(&w->inbox_cond);
  lus_mutex_unlock(&w->mutex);
  lus_worker_release(w);
  return 1;
}

LUA_API int lus_worker_receive(lua_State *L, WorkerState *w) {
  StandaloneArena *arena;
  char *data;
  size_t size;
  if (w == NULL)
    return 0;
  lus_worker_retain(w);
  lus_mutex_lock(&w->mutex);
  int got = msgqueue_pop(&w->outbox, &arena, &data, &size);
  lus_mutex_unlock(&w->mutex);
  if (!got) {
    lus_worker_release(w);
    return 0;
  }

  DeserBuffer db = {data, size, 0};
  int ok = deserialize_value(L, &db, 0);
  luaA_freestandalone(arena);
  lus_worker_release(w);
  return ok;
}

LUA_API int lus_worker_status(WorkerState *w) {
  int status;
  if (w == NULL)
    return LUS_WORKER_DEAD;
  lus_worker_retain(w);
  lus_mutex_lock(&w->mutex);
  status = w->status;
  lus_mutex_unlock(&w->mutex);
  lus_worker_release(w);
  return status;
}

/* }====================================================== */
