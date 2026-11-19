/*
** lworkerint.h
** Private worker implementation types
*/

#ifndef lworkerint_h
#define lworkerint_h

#include "larena.h"
#include "lua.h"

#if defined(LUS_PLATFORM_WINDOWS)
#include <windows.h>
typedef HANDLE lus_thread_t;
typedef CRITICAL_SECTION lus_mutex_t;
typedef CONDITION_VARIABLE lus_cond_t;
#define lus_mutex_init(m) InitializeCriticalSection(m)
#define lus_mutex_destroy(m) DeleteCriticalSection(m)
#define lus_mutex_lock(m) EnterCriticalSection(m)
#define lus_mutex_unlock(m) LeaveCriticalSection(m)
#define lus_cond_init(c) InitializeConditionVariable(c)
#define lus_cond_destroy(c) ((void)0)
#define lus_cond_wait(c, m) SleepConditionVariableCS(c, m, INFINITE)
#define lus_cond_signal(c) WakeConditionVariable(c)
#define lus_cond_broadcast(c) WakeAllConditionVariable(c)
#else
#include <pthread.h>
typedef pthread_t lus_thread_t;
typedef pthread_mutex_t lus_mutex_t;
typedef pthread_cond_t lus_cond_t;
#define lus_mutex_init(m) pthread_mutex_init(m, NULL)
#define lus_mutex_destroy(m) pthread_mutex_destroy(m)
#define lus_mutex_lock(m) pthread_mutex_lock(m)
#define lus_mutex_unlock(m) pthread_mutex_unlock(m)
#define lus_cond_init(c) pthread_cond_init(c, NULL)
#define lus_cond_destroy(c) pthread_cond_destroy(c)
#define lus_cond_wait(c, m) pthread_cond_wait(c, m)
#define lus_cond_signal(c) pthread_cond_signal(c)
#define lus_cond_broadcast(c) pthread_cond_broadcast(c)
#endif

typedef struct WorkerDomain WorkerDomain;
typedef struct WorkerPool WorkerPool;
typedef struct MessageNode MessageNode;

struct MessageNode {
  StandaloneArena *arena;
  char *data;
  size_t size;
  MessageNode *next;
};

typedef struct MessageQueue {
  MessageNode *head;
  MessageNode *tail;
  int count;
} MessageQueue;

typedef struct ReceiveContext {
  lus_mutex_t mutex;
  lus_cond_t cond;
  int ready;
} ReceiveContext;

struct WorkerDomain {
  lus_mutex_t mutex;
  lus_cond_t idle_cond;
  WorkerState *workers;
  int active_count;
  int refcount;
  int closing;
};

struct WorkerState {
  lua_State *L;
  lua_State *parent;
  lus_WorkerSetup setup;
  WorkerDomain *domain;
  WorkerState *next;
  WorkerState *domain_next;
  WorkerState *active_next;
  lus_mutex_t mutex;
  lus_cond_t outbox_cond;
  lus_cond_t inbox_cond;
  MessageQueue outbox;
  MessageQueue inbox;
  int status;
  char *error_msg;
  char *script_path;
  int script_fd;
  int script_errno;
  int nargs;
  int refcount;
  int domain_active;
  int shutdown;
  ReceiveContext *recv_ctx;
};

struct WorkerPool {
  lus_thread_t *threads;
  int nthreads;
  lus_mutex_t queue_mutex;
  lus_cond_t queue_cond;
  WorkerState *runnable_head;
  WorkerState *runnable_tail;
  WorkerState *active_head;
  int shutdown;
  int stopping;
  int initialized;
};

#endif
