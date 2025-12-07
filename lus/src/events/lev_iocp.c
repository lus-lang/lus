/*
** lev_iocp.c
** Windows I/O Completion Ports backend for event loop
**
** IOCP is completion-based, not readiness-based like epoll/kqueue.
** We use zero-byte reads to get readiness notifications.
*/

#define lev_iocp_c
#define LUA_LIB

#include "../lprefix.h"

#if defined(LUS_PLATFORM_WINDOWS)

#include <mswsock.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <winsock2.h>

#include "lev.h"

#define MAX_COMPLETIONS 64
#define MAX_FDS 4096

/* Per-fd state tracking */
typedef struct {
  SOCKET sock;
  int events; /* Requested events */
  void *data;
  OVERLAPPED read_ov;  /* For read-ready detection */
  OVERLAPPED write_ov; /* For write-ready detection */
  int read_pending;
  int write_pending;
} FdState;

struct EventBackend {
  HANDLE iocp;
  FdState *fds;
  int fds_capacity;
};

static EventBackend *iocp_create_backend(void) {
  EventBackend *be = malloc(sizeof(EventBackend));
  if (!be)
    return NULL;

  be->iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
  if (!be->iocp) {
    free(be);
    return NULL;
  }

  be->fds = NULL;
  be->fds_capacity = 0;
  return be;
}

static void iocp_destroy_backend(EventBackend *be) {
  if (be) {
    if (be->iocp)
      CloseHandle(be->iocp);
    free(be->fds);
    free(be);
  }
}

static int ensure_fd_capacity(EventBackend *be, SOCKET sock) {
  int idx = (int)sock;
  if (idx >= be->fds_capacity) {
    int new_cap = (idx + 1) * 2;
    if (new_cap > MAX_FDS)
      new_cap = MAX_FDS;
    if (idx >= new_cap)
      return -1;

    FdState *new_fds = realloc(be->fds, new_cap * sizeof(FdState));
    if (!new_fds)
      return -1;

    memset(new_fds + be->fds_capacity, 0,
           (new_cap - be->fds_capacity) * sizeof(FdState));
    for (int i = be->fds_capacity; i < new_cap; i++) {
      new_fds[i].sock = INVALID_SOCKET;
    }

    be->fds = new_fds;
    be->fds_capacity = new_cap;
  }
  return 0;
}

/* Start async operation to detect read-ready */
static void start_read_detect(EventBackend *be, FdState *fs) {
  if (fs->read_pending)
    return;

  memset(&fs->read_ov, 0, sizeof(OVERLAPPED));

  DWORD flags = 0;
  WSABUF buf = {0, NULL}; /* Zero-byte read */

  int result = WSARecv(fs->sock, &buf, 1, NULL, &flags, &fs->read_ov, NULL);
  if (result == 0 || WSAGetLastError() == WSA_IO_PENDING) {
    fs->read_pending = 1;
  }
}

/* Start async operation to detect write-ready */
static void start_write_detect(EventBackend *be, FdState *fs) {
  if (fs->write_pending)
    return;

  memset(&fs->write_ov, 0, sizeof(OVERLAPPED));

  WSABUF buf = {0, NULL}; /* Zero-byte write */

  int result = WSASend(fs->sock, &buf, 1, NULL, 0, &fs->write_ov, NULL);
  if (result == 0 || WSAGetLastError() == WSA_IO_PENDING) {
    fs->write_pending = 1;
  }
}

static int iocp_add(EventBackend *be, int fd, int events, void *data) {
  SOCKET sock = (SOCKET)fd;
  if (ensure_fd_capacity(be, sock) < 0)
    return -1;

  /* Associate socket with IOCP */
  if (!CreateIoCompletionPort((HANDLE)sock, be->iocp, (ULONG_PTR)sock, 0)) {
    return -1;
  }

  FdState *fs = &be->fds[sock];
  fs->sock = sock;
  fs->events = events;
  fs->data = data;
  fs->read_pending = 0;
  fs->write_pending = 0;

  /* Start detection for requested events */
  if (events & EVLOOP_READ)
    start_read_detect(be, fs);
  if (events & EVLOOP_WRITE)
    start_write_detect(be, fs);

  return 0;
}

static int iocp_modify(EventBackend *be, int fd, int events) {
  SOCKET sock = (SOCKET)fd;
  if (sock >= (SOCKET)be->fds_capacity)
    return -1;

  FdState *fs = &be->fds[sock];
  if (fs->sock == INVALID_SOCKET)
    return -1;

  int old_events = fs->events;
  fs->events = events;

  /* Start detection for newly requested events */
  if ((events & EVLOOP_READ) && !(old_events & EVLOOP_READ)) {
    start_read_detect(be, fs);
  }
  if ((events & EVLOOP_WRITE) && !(old_events & EVLOOP_WRITE)) {
    start_write_detect(be, fs);
  }

  return 0;
}

static int iocp_remove(EventBackend *be, int fd) {
  SOCKET sock = (SOCKET)fd;
  if (sock >= (SOCKET)be->fds_capacity)
    return -1;

  FdState *fs = &be->fds[sock];
  fs->sock = INVALID_SOCKET;
  fs->events = 0;
  fs->data = NULL;
  /* Pending operations will complete with error, we ignore them */

  return 0;
}

static int iocp_wait_events(EventBackend *be, EventResult *results, int max,
                            int timeout_ms) {
  OVERLAPPED_ENTRY entries[MAX_COMPLETIONS];
  ULONG count;
  DWORD timeout = (timeout_ms < 0) ? INFINITE : (DWORD)timeout_ms;

  BOOL ok = GetQueuedCompletionStatusEx(
      be->iocp, entries, max < MAX_COMPLETIONS ? max : MAX_COMPLETIONS, &count,
      timeout, FALSE);
  if (!ok) {
    if (GetLastError() == WAIT_TIMEOUT)
      return 0;
    return -1;
  }

  int result_count = 0;
  for (ULONG i = 0; i < count && result_count < max; i++) {
    SOCKET sock = (SOCKET)entries[i].lpCompletionKey;
    OVERLAPPED *ov = entries[i].lpOverlapped;

    if (sock >= (SOCKET)be->fds_capacity)
      continue;
    FdState *fs = &be->fds[sock];
    if (fs->sock == INVALID_SOCKET)
      continue;

    int events = 0;

    /* Determine which operation completed */
    if (ov == &fs->read_ov) {
      fs->read_pending = 0;
      events |= EVLOOP_READ;
      /* Re-arm if still interested */
      if (fs->events & EVLOOP_READ)
        start_read_detect(be, fs);
    }
    if (ov == &fs->write_ov) {
      fs->write_pending = 0;
      events |= EVLOOP_WRITE;
      if (fs->events & EVLOOP_WRITE)
        start_write_detect(be, fs);
    }

    /* Check for errors */
    if (entries[i].dwNumberOfBytesTransferred == 0 &&
        GetLastError() != ERROR_SUCCESS) {
      events |= EVLOOP_ERROR;
    }

    if (events) {
      /* Consolidate with existing result for same fd */
      int found = 0;
      for (int j = 0; j < result_count; j++) {
        if (results[j].fd == (int)sock) {
          results[j].events |= events;
          found = 1;
          break;
        }
      }
      if (!found) {
        results[result_count].fd = (int)sock;
        results[result_count].events = events;
        results[result_count].data = fs->data;
        result_count++;
      }
    }
  }

  return result_count;
}

static const BackendOps iocp_ops = {
    .create = iocp_create_backend,
    .destroy = iocp_destroy_backend,
    .add = iocp_add,
    .modify = iocp_modify,
    .remove = iocp_remove,
    .wait = iocp_wait_events,
};

const BackendOps *eventloop_get_backend(void) { return &iocp_ops; }

#endif /* LUS_PLATFORM_WINDOWS */
