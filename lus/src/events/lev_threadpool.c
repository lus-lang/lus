/*
** lev_threadpool.c
** Cross-platform thread pool implementation
**
** Uses pthreads on POSIX systems, Windows threads on Windows.
** Provides a simple work queue with condition variable signaling.
*/

#define lev_threadpool_c

#include "lev_threadpool.h"

#include <stdlib.h>
#include <string.h>

#if defined(_WIN32) || defined(_WIN64)
#define LUS_PLATFORM_WINDOWS
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#endif

/* Maximum number of completed tasks to buffer */
#define MAX_COMPLETED 256

struct ThreadPool {
#ifdef LUS_PLATFORM_WINDOWS
  HANDLE *threads;
  CRITICAL_SECTION queue_lock;     /* Protects pending queue */
  CRITICAL_SECTION completed_lock; /* Protects completed queue */
  CONDITION_VARIABLE queue_cond;   /* New work available */
  HANDLE notify_event;             /* Signaled when task completes */
#else
  pthread_t *threads;
  pthread_mutex_t queue_lock;
  pthread_mutex_t completed_lock;
  pthread_cond_t queue_cond;
  int notify_pipe[2]; /* Pipe for epoll/kqueue integration */
#endif

  int num_threads;
  volatile int shutdown;

  /* Pending queue (protected by queue_lock) */
  ThreadPoolTask *pending_head;
  ThreadPoolTask *pending_tail;

  /* Completed queue (protected by completed_lock) */
  ThreadPoolTask *completed_head;
  ThreadPoolTask *completed_tail;
  int completed_count;
};

/* Forward declaration */
#ifdef LUS_PLATFORM_WINDOWS
static DWORD WINAPI worker_thread(LPVOID arg);
#else
static void *worker_thread(void *arg);
#endif

ThreadPool *threadpool_create(int num_threads) {
  ThreadPool *pool = (ThreadPool *)malloc(sizeof(ThreadPool));
  if (!pool)
    return NULL;

  memset(pool, 0, sizeof(ThreadPool));
  pool->num_threads = num_threads;
  pool->shutdown = 0;

#ifdef LUS_PLATFORM_WINDOWS
  InitializeCriticalSection(&pool->queue_lock);
  InitializeCriticalSection(&pool->completed_lock);
  InitializeConditionVariable(&pool->queue_cond);
  pool->notify_event = CreateEvent(NULL, FALSE, FALSE, NULL);

  pool->threads = (HANDLE *)malloc(sizeof(HANDLE) * num_threads);
  if (!pool->threads) {
    DeleteCriticalSection(&pool->queue_lock);
    DeleteCriticalSection(&pool->completed_lock);
    CloseHandle(pool->notify_event);
    free(pool);
    return NULL;
  }

  for (int i = 0; i < num_threads; i++) {
    pool->threads[i] = CreateThread(NULL, 0, worker_thread, pool, 0, NULL);
  }
#else
  pthread_mutex_init(&pool->queue_lock, NULL);
  pthread_mutex_init(&pool->completed_lock, NULL);
  pthread_cond_init(&pool->queue_cond, NULL);

  /* Create notification pipe for event loop integration */
  if (pipe(pool->notify_pipe) < 0) {
    pthread_mutex_destroy(&pool->queue_lock);
    pthread_mutex_destroy(&pool->completed_lock);
    pthread_cond_destroy(&pool->queue_cond);
    free(pool);
    return NULL;
  }

  /* Make pipe non-blocking */
  int flags = fcntl(pool->notify_pipe[0], F_GETFL, 0);
  fcntl(pool->notify_pipe[0], F_SETFL, flags | O_NONBLOCK);
  flags = fcntl(pool->notify_pipe[1], F_GETFL, 0);
  fcntl(pool->notify_pipe[1], F_SETFL, flags | O_NONBLOCK);

  pool->threads = (pthread_t *)malloc(sizeof(pthread_t) * num_threads);
  if (!pool->threads) {
    close(pool->notify_pipe[0]);
    close(pool->notify_pipe[1]);
    pthread_mutex_destroy(&pool->queue_lock);
    pthread_mutex_destroy(&pool->completed_lock);
    pthread_cond_destroy(&pool->queue_cond);
    free(pool);
    return NULL;
  }

  for (int i = 0; i < num_threads; i++) {
    pthread_create(&pool->threads[i], NULL, worker_thread, pool);
  }
#endif

  return pool;
}

void threadpool_destroy(ThreadPool *pool) {
  if (!pool)
    return;

  /* Signal shutdown */
  pool->shutdown = 1;

#ifdef LUS_PLATFORM_WINDOWS
  /* Wake all waiting threads */
  WakeAllConditionVariable(&pool->queue_cond);

  /* Wait for threads to finish */
  WaitForMultipleObjects(pool->num_threads, pool->threads, TRUE, INFINITE);

  for (int i = 0; i < pool->num_threads; i++) {
    CloseHandle(pool->threads[i]);
  }
  free(pool->threads);

  DeleteCriticalSection(&pool->queue_lock);
  DeleteCriticalSection(&pool->completed_lock);
  CloseHandle(pool->notify_event);
#else
  /* Wake all waiting threads */
  pthread_mutex_lock(&pool->queue_lock);
  pthread_cond_broadcast(&pool->queue_cond);
  pthread_mutex_unlock(&pool->queue_lock);

  /* Wait for threads to finish */
  for (int i = 0; i < pool->num_threads; i++) {
    pthread_join(pool->threads[i], NULL);
  }
  free(pool->threads);

  close(pool->notify_pipe[0]);
  close(pool->notify_pipe[1]);
  pthread_mutex_destroy(&pool->queue_lock);
  pthread_mutex_destroy(&pool->completed_lock);
  pthread_cond_destroy(&pool->queue_cond);
#endif

  /* Free any remaining tasks */
  ThreadPoolTask *task = pool->pending_head;
  while (task) {
    ThreadPoolTask *next = task->next;
    if (task->error)
      free(task->error);
    task = next;
  }

  task = pool->completed_head;
  while (task) {
    ThreadPoolTask *next = task->next;
    if (task->error)
      free(task->error);
    task = next;
  }

  free(pool);
}

void threadpool_submit(ThreadPool *pool, ThreadPoolTask *task) {
  task->done = 0;
  task->next = NULL;
  task->error = NULL;

#ifdef LUS_PLATFORM_WINDOWS
  EnterCriticalSection(&pool->queue_lock);
#else
  pthread_mutex_lock(&pool->queue_lock);
#endif

  /* Add to pending queue */
  if (pool->pending_tail) {
    pool->pending_tail->next = task;
    pool->pending_tail = task;
  } else {
    pool->pending_head = pool->pending_tail = task;
  }

#ifdef LUS_PLATFORM_WINDOWS
  WakeConditionVariable(&pool->queue_cond);
  LeaveCriticalSection(&pool->queue_lock);
#else
  pthread_cond_signal(&pool->queue_cond);
  pthread_mutex_unlock(&pool->queue_lock);
#endif
}

int threadpool_poll(ThreadPool *pool, ThreadPoolTask **completed, int max) {
  int count = 0;

#ifdef LUS_PLATFORM_WINDOWS
  EnterCriticalSection(&pool->completed_lock);
#else
  pthread_mutex_lock(&pool->completed_lock);

  /* Drain the notification pipe */
  char buf[64];
  while (read(pool->notify_pipe[0], buf, sizeof(buf)) > 0) {
    /* Just drain */
  }
#endif

  /* Collect completed tasks */
  while (pool->completed_head && count < max) {
    ThreadPoolTask *task = pool->completed_head;
    pool->completed_head = task->next;
    if (!pool->completed_head) {
      pool->completed_tail = NULL;
    }
    pool->completed_count--;

    task->next = NULL;
    completed[count++] = task;
  }

#ifdef LUS_PLATFORM_WINDOWS
  LeaveCriticalSection(&pool->completed_lock);
#else
  pthread_mutex_unlock(&pool->completed_lock);
#endif

  return count;
}

int threadpool_get_notify_fd(ThreadPool *pool) {
#ifdef LUS_PLATFORM_WINDOWS
  (void)pool;
  return -1; /* Not supported on Windows, use polling */
#else
  return pool->notify_pipe[0];
#endif
}

/* Worker thread function */
#ifdef LUS_PLATFORM_WINDOWS
static DWORD WINAPI worker_thread(LPVOID arg) {
  ThreadPool *pool = (ThreadPool *)arg;
#else
static void *worker_thread(void *arg) {
  ThreadPool *pool = (ThreadPool *)arg;
#endif

  while (!pool->shutdown) {
    ThreadPoolTask *task = NULL;

    /* Get a task from the pending queue */
#ifdef LUS_PLATFORM_WINDOWS
    EnterCriticalSection(&pool->queue_lock);

    while (!pool->pending_head && !pool->shutdown) {
      SleepConditionVariableCS(&pool->queue_cond, &pool->queue_lock, INFINITE);
    }

    if (pool->pending_head) {
      task = pool->pending_head;
      pool->pending_head = task->next;
      if (!pool->pending_head) {
        pool->pending_tail = NULL;
      }
    }

    LeaveCriticalSection(&pool->queue_lock);
#else
    pthread_mutex_lock(&pool->queue_lock);

    while (!pool->pending_head && !pool->shutdown) {
      pthread_cond_wait(&pool->queue_cond, &pool->queue_lock);
    }

    if (pool->pending_head) {
      task = pool->pending_head;
      pool->pending_head = task->next;
      if (!pool->pending_head) {
        pool->pending_tail = NULL;
      }
    }

    pthread_mutex_unlock(&pool->queue_lock);
#endif

    if (!task)
      continue;

    /* Execute the work function */
    task->work(task);
    task->done = 1;

    /* Add to completed queue */
#ifdef LUS_PLATFORM_WINDOWS
    EnterCriticalSection(&pool->completed_lock);

    if (pool->completed_tail) {
      pool->completed_tail->next = task;
      pool->completed_tail = task;
    } else {
      pool->completed_head = pool->completed_tail = task;
    }
    pool->completed_count++;

    SetEvent(pool->notify_event);
    LeaveCriticalSection(&pool->completed_lock);
#else
    pthread_mutex_lock(&pool->completed_lock);

    if (pool->completed_tail) {
      pool->completed_tail->next = task;
      pool->completed_tail = task;
    } else {
      pool->completed_head = pool->completed_tail = task;
    }
    pool->completed_count++;

    /* Notify via pipe */
    char c = 1;
    ssize_t ret = write(pool->notify_pipe[1], &c, 1);
    (void)ret; /* Ignore errors, pipe might be full */

    pthread_mutex_unlock(&pool->completed_lock);
#endif
  }

#ifdef LUS_PLATFORM_WINDOWS
  return 0;
#else
  return NULL;
#endif
}
