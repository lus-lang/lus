/*
** lev_epoll.c
** Linux epoll backend for event loop
*/

#define lev_epoll_c
#define LUA_LIB

#include "../lprefix.h"

#if defined(__linux__)

#include <errno.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <unistd.h>

#include "lev.h"

#define MAX_EVENTS 64

typedef struct {
  int fd;
  void *data;
} FdData;

struct EventBackend {
  int epfd;
  FdData *fds; /* Array indexed by fd */
  int fds_capacity;
};

static EventBackend *epoll_create_backend(void) {
  EventBackend *be = malloc(sizeof(EventBackend));
  if (!be)
    return NULL;

  be->epfd = epoll_create1(EPOLL_CLOEXEC);
  if (be->epfd < 0) {
    free(be);
    return NULL;
  }

  be->fds = NULL;
  be->fds_capacity = 0;
  return be;
}

static void epoll_destroy_backend(EventBackend *be) {
  if (be) {
    if (be->epfd >= 0)
      close(be->epfd);
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
      new_fds[i].data = NULL;
    }
    be->fds = new_fds;
    be->fds_capacity = new_cap;
  }
  return 0;
}

static int translate_events_to_epoll(int events) {
  int eev = 0;
  if (events & EVLOOP_READ)
    eev |= EPOLLIN;
  if (events & EVLOOP_WRITE)
    eev |= EPOLLOUT;
  return eev;
}

static int translate_events_from_epoll(int eev) {
  int events = 0;
  if (eev & EPOLLIN)
    events |= EVLOOP_READ;
  if (eev & EPOLLOUT)
    events |= EVLOOP_WRITE;
  if (eev & (EPOLLERR | EPOLLHUP))
    events |= EVLOOP_ERROR;
  return events;
}

static int epoll_add(EventBackend *be, int fd, int events, void *data) {
  if (ensure_fd_capacity(be, fd) < 0)
    return -1;

  struct epoll_event ev;
  ev.events = translate_events_to_epoll(events);
  ev.data.fd = fd;

  if (epoll_ctl(be->epfd, EPOLL_CTL_ADD, fd, &ev) < 0) {
    return -1;
  }

  be->fds[fd].fd = fd;
  be->fds[fd].data = data;
  return 0;
}

static int epoll_modify(EventBackend *be, int fd, int events) {
  if (fd >= be->fds_capacity || be->fds[fd].fd < 0)
    return -1;

  struct epoll_event ev;
  ev.events = translate_events_to_epoll(events);
  ev.data.fd = fd;

  return epoll_ctl(be->epfd, EPOLL_CTL_MOD, fd, &ev);
}

static int epoll_remove(EventBackend *be, int fd) {
  if (fd >= be->fds_capacity || be->fds[fd].fd < 0)
    return -1;

  epoll_ctl(be->epfd, EPOLL_CTL_DEL, fd, NULL);
  be->fds[fd].fd = -1;
  be->fds[fd].data = NULL;
  return 0;
}

static int epoll_wait_events(EventBackend *be, EventResult *results, int max,
                             int timeout_ms) {
  struct epoll_event events[MAX_EVENTS];
  int n = max < MAX_EVENTS ? max : MAX_EVENTS;

  int ready = epoll_wait(be->epfd, events, n, timeout_ms);
  if (ready < 0) {
    if (errno == EINTR)
      return 0;
    return -1;
  }

  for (int i = 0; i < ready; i++) {
    int fd = events[i].data.fd;
    results[i].fd = fd;
    results[i].events = translate_events_from_epoll(events[i].events);
    results[i].data = (fd < be->fds_capacity) ? be->fds[fd].data : NULL;
  }

  return ready;
}

static const BackendOps epoll_ops = {
    .create = epoll_create_backend,
    .destroy = epoll_destroy_backend,
    .add = epoll_add,
    .modify = epoll_modify,
    .remove = epoll_remove,
    .wait = epoll_wait_events,
};

const BackendOps *eventloop_get_backend(void) { return &epoll_ops; }

#endif /* __linux__ */
