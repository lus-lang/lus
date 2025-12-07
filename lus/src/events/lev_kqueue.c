/*
** lev_kqueue.c
** macOS/BSD kqueue backend for event loop
*/

#define lev_kqueue_c
#define LUA_LIB

#include "../lprefix.h"

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) ||      \
    defined(__NetBSD__) || defined(__DragonFly__)

#include <errno.h>
#include <stdlib.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include "lev.h"

#define MAX_EVENTS 64

typedef struct {
  int fd;
  int events;
  void *data;
} FdData;

struct EventBackend {
  int kq;
  FdData *fds;
  int fds_capacity;
};

static EventBackend *kqueue_create_backend(void) {
  EventBackend *be = malloc(sizeof(EventBackend));
  if (!be)
    return NULL;

  be->kq = kqueue();
  if (be->kq < 0) {
    free(be);
    return NULL;
  }

  be->fds = NULL;
  be->fds_capacity = 0;
  return be;
}

static void kqueue_destroy_backend(EventBackend *be) {
  if (be) {
    if (be->kq >= 0)
      close(be->kq);
    free(be->fds);
    free(be);
  }
}

static int ensure_fd_capacity(EventBackend *be, int fd) {
  if (fd >= be->fds_capacity) {
    int new_cap = (fd + 1) * 2;
    FdData *new_fds = realloc(be->fds, new_cap * sizeof(FdData));
    if (!new_fds)
      return -1;

    for (int i = be->fds_capacity; i < new_cap; i++) {
      new_fds[i].fd = -1;
      new_fds[i].events = 0;
      new_fds[i].data = NULL;
    }
    be->fds = new_fds;
    be->fds_capacity = new_cap;
  }
  return 0;
}

static int kqueue_add(EventBackend *be, int fd, int events, void *data) {
  if (ensure_fd_capacity(be, fd) < 0)
    return -1;

  struct kevent evs[2];
  int n = 0;

  if (events & EVLOOP_READ) {
    EV_SET(&evs[n++], fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
  }
  if (events & EVLOOP_WRITE) {
    EV_SET(&evs[n++], fd, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, NULL);
  }

  if (n > 0 && kevent(be->kq, evs, n, NULL, 0, NULL) < 0) {
    return -1;
  }

  be->fds[fd].fd = fd;
  be->fds[fd].events = events;
  be->fds[fd].data = data;
  return 0;
}

static int kqueue_modify(EventBackend *be, int fd, int events) {
  if (fd >= be->fds_capacity || be->fds[fd].fd < 0)
    return -1;

  int old_events = be->fds[fd].events;
  struct kevent evs[4];
  int n = 0;

  /* Remove events no longer needed */
  if ((old_events & EVLOOP_READ) && !(events & EVLOOP_READ)) {
    EV_SET(&evs[n++], fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
  }
  if ((old_events & EVLOOP_WRITE) && !(events & EVLOOP_WRITE)) {
    EV_SET(&evs[n++], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
  }

  /* Add new events */
  if (!(old_events & EVLOOP_READ) && (events & EVLOOP_READ)) {
    EV_SET(&evs[n++], fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
  }
  if (!(old_events & EVLOOP_WRITE) && (events & EVLOOP_WRITE)) {
    EV_SET(&evs[n++], fd, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, NULL);
  }

  if (n > 0 && kevent(be->kq, evs, n, NULL, 0, NULL) < 0) {
    return -1;
  }

  be->fds[fd].events = events;
  return 0;
}

static int kqueue_remove(EventBackend *be, int fd) {
  if (fd >= be->fds_capacity || be->fds[fd].fd < 0)
    return -1;

  struct kevent evs[2];
  int n = 0;

  if (be->fds[fd].events & EVLOOP_READ) {
    EV_SET(&evs[n++], fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
  }
  if (be->fds[fd].events & EVLOOP_WRITE) {
    EV_SET(&evs[n++], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
  }

  kevent(be->kq, evs, n, NULL, 0, NULL); /* Ignore errors on delete */

  be->fds[fd].fd = -1;
  be->fds[fd].events = 0;
  be->fds[fd].data = NULL;
  return 0;
}

static int kqueue_wait_events(EventBackend *be, EventResult *results, int max,
                              int timeout_ms) {
  struct kevent events[MAX_EVENTS];
  int n = max < MAX_EVENTS ? max : MAX_EVENTS;
  struct timespec ts, *tsp = NULL;

  if (timeout_ms >= 0) {
    ts.tv_sec = timeout_ms / 1000;
    ts.tv_nsec = (timeout_ms % 1000) * 1000000L;
    tsp = &ts;
  }

  int ready = kevent(be->kq, NULL, 0, events, n, tsp);
  if (ready < 0) {
    if (errno == EINTR)
      return 0;
    return -1;
  }

  /* Consolidate events by fd */
  int result_count = 0;
  for (int i = 0; i < ready; i++) {
    int fd = (int)events[i].ident;
    int ev = 0;

    if (events[i].filter == EVFILT_READ)
      ev = EVLOOP_READ;
    if (events[i].filter == EVFILT_WRITE)
      ev = EVLOOP_WRITE;
    if (events[i].flags & EVLOOP_ERROR)
      ev |= EVLOOP_ERROR;

    /* Check if this fd already has a result */
    int found = 0;
    for (int j = 0; j < result_count; j++) {
      if (results[j].fd == fd) {
        results[j].events |= ev;
        found = 1;
        break;
      }
    }

    if (!found && result_count < max) {
      results[result_count].fd = fd;
      results[result_count].events = ev;
      results[result_count].data =
          (fd < be->fds_capacity) ? be->fds[fd].data : NULL;
      result_count++;
    }
  }

  return result_count;
}

static const BackendOps kqueue_ops = {
    .create = kqueue_create_backend,
    .destroy = kqueue_destroy_backend,
    .add = kqueue_add,
    .modify = kqueue_modify,
    .remove = kqueue_remove,
    .wait = kqueue_wait_events,
};

const BackendOps *eventloop_get_backend(void) { return &kqueue_ops; }

#endif /* __APPLE__ || __FreeBSD__ || ... */
