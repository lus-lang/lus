/*
** lev_select.c
** Portable select() fallback backend for event loop
*/

#define lev_select_c
#define LUA_LIB

#include "../lprefix.h"

/* Only compile if no better backend is available */
#if !defined(__linux__) && !defined(__APPLE__) && !defined(__FreeBSD__) &&     \
    !defined(__OpenBSD__) && !defined(__NetBSD__) &&                           \
    !defined(__DragonFly__) && !defined(LUS_PLATFORM_WINDOWS)

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>

#include "lev.h"

#define MAX_FDS 1024

typedef struct {
  int fd;
  int events;
  void *data;
} FdEntry;

struct EventBackend {
  FdEntry entries[MAX_FDS];
  int count;
  int max_fd;
};

static EventBackend *select_create_backend(void) {
  EventBackend *be = malloc(sizeof(EventBackend));
  if (!be)
    return NULL;

  memset(be->entries, 0, sizeof(be->entries));
  for (int i = 0; i < MAX_FDS; i++) {
    be->entries[i].fd = -1;
  }
  be->count = 0;
  be->max_fd = -1;
  return be;
}

static void select_destroy_backend(EventBackend *be) { free(be); }

static int find_entry(EventBackend *be, int fd) {
  for (int i = 0; i < be->count; i++) {
    if (be->entries[i].fd == fd)
      return i;
  }
  return -1;
}

static void update_max_fd(EventBackend *be) {
  be->max_fd = -1;
  for (int i = 0; i < be->count; i++) {
    if (be->entries[i].fd > be->max_fd) {
      be->max_fd = be->entries[i].fd;
    }
  }
}

static int select_add(EventBackend *be, int fd, int events, void *data) {
  if (be->count >= MAX_FDS)
    return -1;
  if (fd >= FD_SETSIZE)
    return -1; /* select() limit */

  int idx = be->count++;
  be->entries[idx].fd = fd;
  be->entries[idx].events = events;
  be->entries[idx].data = data;

  if (fd > be->max_fd)
    be->max_fd = fd;
  return 0;
}

static int select_modify(EventBackend *be, int fd, int events) {
  int idx = find_entry(be, fd);
  if (idx < 0)
    return -1;

  be->entries[idx].events = events;
  return 0;
}

static int select_remove(EventBackend *be, int fd) {
  int idx = find_entry(be, fd);
  if (idx < 0)
    return -1;

  /* Swap with last entry */
  be->count--;
  if (idx < be->count) {
    be->entries[idx] = be->entries[be->count];
  }
  be->entries[be->count].fd = -1;

  update_max_fd(be);
  return 0;
}

static int select_wait_events(EventBackend *be, EventResult *results, int max,
                              int timeout_ms) {
  fd_set read_fds, write_fds, except_fds;
  struct timeval tv, *tvp = NULL;

  FD_ZERO(&read_fds);
  FD_ZERO(&write_fds);
  FD_ZERO(&except_fds);

  for (int i = 0; i < be->count; i++) {
    int fd = be->entries[i].fd;
    if (be->entries[i].events & EVLOOP_READ)
      FD_SET(fd, &read_fds);
    if (be->entries[i].events & EVLOOP_WRITE)
      FD_SET(fd, &write_fds);
    FD_SET(fd, &except_fds);
  }

  if (timeout_ms >= 0) {
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    tvp = &tv;
  }

  int ready = select(be->max_fd + 1, &read_fds, &write_fds, &except_fds, tvp);
  if (ready < 0) {
    if (errno == EINTR)
      return 0;
    return -1;
  }

  int result_count = 0;
  for (int i = 0; i < be->count && result_count < max; i++) {
    int fd = be->entries[i].fd;
    int events = 0;

    if (FD_ISSET(fd, &read_fds))
      events |= EVLOOP_READ;
    if (FD_ISSET(fd, &write_fds))
      events |= EVLOOP_WRITE;
    if (FD_ISSET(fd, &except_fds))
      events |= EVLOOP_ERROR;

    if (events) {
      results[result_count].fd = fd;
      results[result_count].events = events;
      results[result_count].data = be->entries[i].data;
      result_count++;
    }
  }

  return result_count;
}

static const BackendOps select_ops = {
    .create = select_create_backend,
    .destroy = select_destroy_backend,
    .add = select_add,
    .modify = select_modify,
    .remove = select_remove,
    .wait = select_wait_events,
};

const BackendOps *eventloop_get_backend(void) { return &select_ops; }

#endif /* Fallback select */
