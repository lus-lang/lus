/*
** Assertion helpers shared by the embedding tests. Each test is a small
** host program that exits with status 0 when every check passes.
*/

#ifndef EMBED_CHECK_H
#define EMBED_CHECK_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lus.h"

static int check_failures = 0;

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
      check_failures++;                                                        \
    }                                                                          \
  } while (0)

/* Checks that a status is LUS_OK and prints the error value otherwise. */
#define CHECK_OK(L, expr)                                                      \
  do {                                                                         \
    int st_ = (expr);                                                          \
    if (st_ != LUS_OK) {                                                       \
      const char *m_ = lus_tostring((L), -1, NULL);                            \
      fprintf(stderr, "%s:%d: %s failed with status %d: %s\n", __FILE__,      \
              __LINE__, #expr, st_, m_ ? m_ : "(not a string)");               \
      check_failures++;                                                        \
      lus_pop((L), 1);                                                         \
    }                                                                          \
  } while (0)

/* Checks that the string at idx equals s. */
#define CHECK_STR(L, idx, s)                                                   \
  do {                                                                         \
    const char *v_ = lus_tostring((L), (idx), NULL);                           \
    if (v_ == NULL || strcmp(v_, (s)) != 0) {                                  \
      fprintf(stderr, "%s:%d: expected \"%s\", got \"%s\"\n", __FILE__,       \
              __LINE__, (s), v_ ? v_ : "(not a string)");                      \
      check_failures++;                                                        \
    }                                                                          \
  } while (0)

/* Checks that the string at idx contains s. */
#define CHECK_HAS(L, idx, s)                                                   \
  do {                                                                         \
    const char *v_ = lus_tostring((L), (idx), NULL);                           \
    if (v_ == NULL || strstr(v_, (s)) == NULL) {                               \
      fprintf(stderr, "%s:%d: expected text containing \"%s\", got \"%s\"\n", \
              __FILE__, __LINE__, (s), v_ ? v_ : "(not a string)");            \
      check_failures++;                                                        \
    }                                                                          \
  } while (0)

static int check_done(const char *name) {
  if (check_failures == 0) {
    printf("embed %s: ok\n", name);
    return 0;
  }
  fprintf(stderr, "embed %s: %d failures\n", name, check_failures);
  return 1;
}

#endif
