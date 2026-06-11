/*
** lglob.c
** Glob matching utilities for Lus
*/

#define lglob_c
#define LUA_CORE

#include "lprefix.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lglob.h"

/* Platform specific for canonicalization */
#if defined(LUS_PLATFORM_WINDOWS)
#include <windows.h>
#else
#include <fnmatch.h>
#include <limits.h>
#endif

/*
** Basic glob matching: * matches any sequence, ? matches one character.
** This is used on Windows (no fnmatch) and for URL matching.
*/
static int glob_match_internal(const char *pattern, const char *string) {
  const char *p = pattern;
  const char *s = string;

  while (*p) {
    if (*p == '*') {
      /* Skip consecutive asterisks */
      while (*(p + 1) == '*')
        p++;
      /* If * is at end, it matches everything remaining */
      if (*(p + 1) == '\0')
        return 1;
      /* Try matching the rest of pattern against each suffix of string */
      const char *next = p + 1;
      while (*s) {
        if (glob_match_internal(next, s))
          return 1;
        s++;
      }
      return 0;
    }
    else if (*p == '?') {
      /* ? matches exactly one character */
      if (*s == '\0')
        return 0;
      p++;
      s++;
    }
    else {
      /* Literal character match */
      if (*p != *s)
        return 0;
      p++;
      s++;
    }
  }
  return *s == '\0';
}

int lus_glob_match(const char *pattern, const char *string) {
#if defined(LUS_PLATFORM_WINDOWS)
  return glob_match_internal(pattern, string);
#else
  return fnmatch(pattern, string, 0) == 0;
#endif
}

#if !defined(LUS_PLATFORM_WINDOWS)
/*
** Canonicalize 'path' into 'out' (size PATH_MAX), resolving symlinks and
** '..'/'.' segments. If the path itself does not exist (the normal case
** when creating a new file via fs.write/fs.move/...), resolve its parent
** directory and re-append the final component, so '..' is still resolved.
** Returns 1 on success, 0 if it cannot be resolved. A 0 return MUST be
** treated as "denied" by the caller -- we never fall back to matching the
** raw, unresolved path, which would let '..' traversal escape a pledge.
*/
static int canon_path_posix(const char *path, char out[PATH_MAX]) {
  char tmp[PATH_MAX];
  char parent[PATH_MAX];
  char *slash;
  const char *base;
  size_t len;
  int n;
  if (realpath(path, out) != NULL)
    return 1; /* exists: fully resolved */
  /* Leaf may not exist yet: resolve the parent directory instead. */
  len = strlen(path);
  if (len == 0 || len >= sizeof(tmp))
    return 0;
  memcpy(tmp, path, len + 1);
  slash = strrchr(tmp, '/');
  if (slash == NULL) { /* bare name, relative to CWD */
    if (realpath(".", parent) == NULL)
      return 0;
    base = tmp;
  }
  else if (slash == tmp) { /* parent is the root directory */
    parent[0] = '/';
    parent[1] = '\0';
    base = slash + 1;
  }
  else {
    *slash = '\0';
    base = slash + 1;
    if (realpath(tmp, parent) == NULL)
      return 0; /* a non-final component is missing: deny */
  }
  n = snprintf(out, PATH_MAX, "%s/%s", parent, base);
  if (n < 0 || (size_t)n >= PATH_MAX)
    return 0;
  return 1;
}
#endif

int lus_glob_match_path(const char *pattern, const char *path,
                        int canonicalize) {
  if (!canonicalize) {
    return lus_glob_match(pattern, path);
  }

#if defined(LUS_PLATFORM_WINDOWS)
  /*
  ** On Windows, use GetFullPathName for canonicalization (resolves '..' and
  ** makes the path absolute). On failure -- including a path longer than the
  ** buffer -- deny rather than copying the raw path into a fixed buffer
  ** (which would overflow) or matching an unresolved path.
  */
  {
    char canon_path[MAX_PATH];
    char canon_pattern[MAX_PATH];
    DWORD path_len = GetFullPathNameA(path, MAX_PATH, canon_path, NULL);
    if (path_len == 0 || path_len >= MAX_PATH)
      return 0; /* cannot canonicalize -> deny (fail closed) */

    /* Canonicalize the pattern only if it looks like a path. */
    if (pattern[0] != '*' && pattern[0] != '?') {
      DWORD pattern_len =
          GetFullPathNameA(pattern, MAX_PATH, canon_pattern, NULL);
      if (pattern_len == 0 || pattern_len >= MAX_PATH)
        return glob_match_internal(pattern, canon_path); /* keep raw pattern */
      return glob_match_internal(canon_pattern, canon_path);
    }
    return glob_match_internal(pattern, canon_path);
  }
#else
  /*
  ** On POSIX, resolve the checked path with realpath (resolving symlinks and
  ** '..'). Fail closed if it cannot be resolved -- never match the raw path.
  */
  {
    char canon_path[PATH_MAX];
    char canon_pattern[PATH_MAX];
    const char *pattern_to_use = pattern;

    if (!canon_path_posix(path, canon_path))
      return 0; /* unresolvable -> deny (fail closed) */

    /* Canonicalize the pattern if it looks like a path (starts with / or .) */
    if (pattern[0] == '/' || pattern[0] == '.') {
      size_t len = strlen(pattern);
      size_t i;
      for (i = 0; i < len; i++) {
        if (pattern[i] == '*' || pattern[i] == '?')
          break;
      }
      if (i == len) {
        /* No wildcards - canonicalize the whole pattern */
        if (canon_path_posix(pattern, canon_pattern))
          pattern_to_use = canon_pattern;
      }
      else if (i > 0 && i < PATH_MAX) {
        /* Has wildcards - canonicalize the (bounded) prefix */
        char prefix[PATH_MAX];
        char resolved_prefix[PATH_MAX];
        char *last_sep;
        memcpy(prefix, pattern, i);
        prefix[i] = '\0';
        last_sep = strrchr(prefix, '/');
        if (last_sep != NULL && last_sep != prefix) {
          *last_sep = '\0';
          if (realpath(prefix, resolved_prefix) != NULL) {
            int n = snprintf(canon_pattern, PATH_MAX, "%s%s", resolved_prefix,
                             pattern + (last_sep - prefix));
            if (n > 0 && (size_t)n < PATH_MAX)
              pattern_to_use = canon_pattern;
          }
        }
        else if (last_sep == NULL) {
          /* Pattern like "dir*" - resolve the prefix as a directory */
          if (realpath(prefix, resolved_prefix) != NULL) {
            int n = snprintf(canon_pattern, PATH_MAX, "%s%s", resolved_prefix,
                             pattern + i);
            if (n > 0 && (size_t)n < PATH_MAX)
              pattern_to_use = canon_pattern;
          }
        }
      }
    }

    return lus_glob_match(pattern_to_use, canon_path);
  }
#endif
}

/*
** Helper: extract host from URL (handles http:// and https://)
*/
static const char *get_url_host(const char *url, size_t *host_len) {
  const char *p = url;

  /* Skip scheme */
  if (strncmp(p, "http://", 7) == 0) {
    p += 7;
  }
  else if (strncmp(p, "https://", 8) == 0) {
    p += 8;
  }

  /* Find end of host (port, path, or end of string) */
  const char *host_start = p;
  while (*p && *p != ':' && *p != '/' && *p != '?') {
    p++;
  }

  *host_len = p - host_start;
  return host_start;
}

int lus_glob_match_url(const char *pattern, const char *url) {
  /*
  ** URL pattern matching:
  ** - Pattern can be a domain: "example.com" matches "http://example.com/..."
  ** - Pattern can have wildcard subdomain: "*.example.com"
  */

  /* If pattern has no scheme, only match against host */
  if (strncmp(pattern, "http://", 7) != 0 &&
      strncmp(pattern, "https://", 8) != 0) {
    /* Pattern is host-only (possibly with wildcards and path) */
    size_t url_host_len;
    const char *url_host = get_url_host(url, &url_host_len);

    /* Check if pattern has a path component */
    const char *pattern_slash = strchr(pattern, '/');
    if (pattern_slash) {
      /* Pattern has path: match host + path */
      size_t pattern_host_len = pattern_slash - pattern;
      char host_buf[256];
      if (url_host_len >= sizeof(host_buf))
        return 0;
      memcpy(host_buf, url_host, url_host_len);
      host_buf[url_host_len] = '\0';

      /* Match host part */
      char pattern_host[256];
      if (pattern_host_len >= sizeof(pattern_host))
        return 0;
      memcpy(pattern_host, pattern, pattern_host_len);
      pattern_host[pattern_host_len] = '\0';

      if (!glob_match_internal(pattern_host, host_buf))
        return 0;

      /* Match path part */
      const char *url_path = url_host + url_host_len;
      if (*url_path == ':') {
        /* Skip port */
        while (*url_path && *url_path != '/')
          url_path++;
      }
      if (*url_path == '\0')
        url_path = "/";

      return glob_match_internal(pattern_slash, url_path);
    }
    else {
      /* Pattern is host only: match just the host */
      char host_buf[256];
      if (url_host_len >= sizeof(host_buf))
        return 0;
      memcpy(host_buf, url_host, url_host_len);
      host_buf[url_host_len] = '\0';

      return glob_match_internal(pattern, host_buf);
    }
  }

  /* Pattern has scheme: do full URL match */
  return glob_match_internal(pattern, url);
}
