/*
** lglob.h
** Glob matching utilities for Lus
*/

#ifndef lglob_h
#define lglob_h

#include "llimits.h"

/*
** Basic glob matching with * (any chars) and ? (single char).
** Returns 1 if pattern matches string, 0 otherwise.
*/
LUAI_FUNC int lus_glob_match(const char *pattern, const char *string);

/*
** Path-based glob matching with canonicalization.
** Uses realpath() to resolve the actual path before matching.
** Returns 1 if pattern matches path, 0 otherwise.
** If canonicalize is true, both paths are canonicalized before matching.
*/
LUAI_FUNC int lus_glob_match_path(const char *pattern, const char *path,
                                  int canonicalize);

/*
** URL glob matching for network:http permissions.
** Returns 1 if pattern matches url, 0 otherwise.
*/
LUAI_FUNC int lus_glob_match_url(const char *pattern, const char *url);

#endif
