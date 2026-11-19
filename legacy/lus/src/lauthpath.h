/*
** lauthpath.h
** Descriptor-bound filesystem authorization
*/

#ifndef lauthpath_h
#define lauthpath_h

#include <stddef.h>
#include <stdio.h>

#include "lua.h"
#include "llimits.h"

#if defined(LUS_PLATFORM_WINDOWS)
#include <windows.h>

#define LUS_AUTH_PATH_MAX (32768u * 4u)

typedef struct LusAuthParent {
  HANDLE handle;
  WCHAR *leaf;
  char *canonical;
} LusAuthParent;

typedef struct LusAuthChain {
  HANDLE *handles;
  size_t count;
} LusAuthChain;

typedef struct LusAuthFile {
  HANDLE handle;
  LusAuthParent parent;
  LusAuthChain chain;
  char *canonical;
  unsigned int object_mode;
  long long object_size;
  int has_parent;
  int created;
  const char *denied_perm;
} LusAuthFile;

/* Open an object, authorize its final handle name, and retain that object. */
LUAI_FUNC HANDLE luaAP_winopen(lua_State *L, const char *path,
                               DWORD desired_access, DWORD disposition,
                               DWORD flags, int need_read, int need_write);

/* Open and authorize the retained parent used by relative operations. */
LUAI_FUNC int luaAP_parent(lua_State *L, const char *path, const char *perm,
                           LusAuthParent *parent);
LUAI_FUNC void luaAP_closeparent(LusAuthParent *parent);

/* Return a newly allocated canonical UTF-8 name for a retained handle. */
LUAI_FUNC char *luaAP_winhandlepath(HANDLE handle);
LUAI_FUNC int luaAP_winlockchain(HANDLE target, LusAuthChain *chain);
LUAI_FUNC void luaAP_winclosechain(LusAuthChain *chain);

/* Convert authorized handles into loader and standard I/O forms. */
LUAI_FUNC FILE *luaAP_fopen(lua_State *L, const char *path, const char *mode);
LUAI_FUNC int luaAP_winopenfd(lua_State *L, const char *path, int need_read,
                              int need_write);
LUAI_FUNC int luaAP_winopenrawfd(const char *path);
LUAI_FUNC int luaAP_loadfd(lua_State *L, int fd, const char *filename,
                           const char *mode);
LUAI_FUNC int luaAP_loadfile(lua_State *L, const char *filename,
                             const char *mode);

/* Handle-bound mutations used by the filesystem library. */
LUAI_FUNC int luaAP_wincopy(lua_State *L, const char *src, const char *dst);
LUAI_FUNC int luaAP_winmove(lua_State *L, const char *src, const char *dst);
LUAI_FUNC int luaAP_winremove(lua_State *L, const char *path);
LUAI_FUNC int luaAP_winmkdir(lua_State *L, const char *path);
LUAI_FUNC int luaAP_winsymlink(lua_State *L, const char *path,
                               const char *target);

#else
#include <limits.h>

#if !defined(PATH_MAX)
#define PATH_MAX 4096
#endif

#if !defined(NAME_MAX)
#define NAME_MAX 255
#endif

typedef struct LusAuthParent {
  int fd;
  char leaf[NAME_MAX + 1];
  char canonical[PATH_MAX];
} LusAuthParent;

typedef struct LusAuthFile {
  int fd;
  LusAuthParent parent;
  char canonical[PATH_MAX];
  unsigned long long device;
  unsigned long long inode;
  unsigned int object_mode;
  long long object_size;
  int has_parent;
  int created;
  const char *denied_perm;
} LusAuthFile;

/* A source path resolved once through a retained parent. The nofollow
** identity is checked again at commit, while fd retains the named object on
** platforms and file types that provide an openable descriptor. */
typedef struct LusAuthMoveSource {
  LusAuthParent parent;
  int fd;
  unsigned long long device;
  unsigned long long inode;
  unsigned int mode;
  const char *denied_perm;
} LusAuthMoveSource;
#endif

#define LUS_AUTH_READ 0x01
#define LUS_AUTH_WRITE 0x02
#define LUS_AUTH_CREATE 0x04
#define LUS_AUTH_EXCLUSIVE 0x08
#define LUS_AUTH_DELETE 0x10
#define LUS_AUTH_DELETE_ON_CLOSE 0x20

#define LUS_AUTH_OK 0
#define LUS_AUTH_MISSING 1
#define LUS_AUTH_EXISTS 2
#define LUS_AUTH_DENIED 3
#define LUS_AUTH_ERROR 4

/* Native POSIX deletion temporarily moves retained objects under a component
** with this prefix. Filesystem pledge matching reserves those components so
** another Lus state cannot enter the quarantine during an exact deletion. */
#define LUS_AUTH_QUARANTINE_PREFIX ".lus-delete-quarantine."

/* Non-raising object binding for callbacks that cannot unwind through a
** foreign library. The returned object and parent remain retained until
** luaAP_closeauthfile(). */
LUAI_FUNC int luaAP_tryopen(lua_State *L, const char *path, int options,
                            unsigned int mode, LusAuthFile *file);
/* Open anchor or a sibling through its retained parent. suffix is empty for
** anchor itself, or contains one suffix component. authorized_path is the
** canonical name approved when anchor was bound. anchor must remain retained
** until file is closed. */
LUAI_FUNC int luaAP_tryopensibling(lua_State *L, const LusAuthFile *anchor,
                                   const char *suffix,
                                   const char *authorized_path, int options,
                                   unsigned int mode, LusAuthFile *file);
LUAI_FUNC void luaAP_moveauthfile(LusAuthFile *destination,
                                  LusAuthFile *source);
LUAI_FUNC int luaAP_deleteauthfile(LusAuthFile *file);
/* Remove a retained directory tree after its root has been bound. */
LUAI_FUNC int luaAP_deleteauthrecursive(LusAuthFile *file);
LUAI_FUNC int luaAP_syncauthparent(LusAuthFile *file);
LUAI_FUNC void luaAP_closeauthfile(LusAuthFile *file);
LUAI_FUNC const char *luaAP_authfilepath(const LusAuthFile *file);

/* Resolve a pledge value once, when it is granted. */
LUAI_FUNC int luaAP_resolvepattern(const char *pattern, char *resolved,
                                   size_t resolved_size);

/* Capture WebAssembly host-console device identities before scripts run. */
LUAI_FUNC void luaAP_initwasmconsole(void);

/* Resolve an exact existing symbolic link as a link object. This complements
** luaAP_resolvepattern(), which retains the link's current target authority. */
LUAI_FUNC int luaAP_resolvelink(const char *path, char *resolved,
                                size_t resolved_size);

/* Remove a file relative to an authorized retained parent object. */
LUAI_FUNC int luaAP_unlink(lua_State *L, const char *path, const char *perm);

#if !defined(LUS_PLATFORM_WINDOWS)
typedef void (*LusAuthDeleteHook)(const char *phase, const char *path,
                                  void *context);

/* Open a file without mutating it before its retained object is authorized. */
LUAI_FUNC int luaAP_open(lua_State *L, const char *path, int flags,
                         unsigned int mode, int need_read, int need_write);

/* Open and authorize the parent of a path for an at-family operation. */
LUAI_FUNC int luaAP_parent(lua_State *L, const char *path, const char *perm,
                           LusAuthParent *parent);
LUAI_FUNC void luaAP_closeparent(LusAuthParent *parent);

/* Convert an authorized descriptor into the standard I/O and loader forms. */
LUAI_FUNC FILE *luaAP_fopen(lua_State *L, const char *path, const char *mode);
LUAI_FUNC int luaAP_loadfd(lua_State *L, int fd, const char *filename,
                           const char *mode);
LUAI_FUNC int luaAP_loadfile(lua_State *L, const char *filename,
                             const char *mode);

/* Return the canonical name of the retained object without reopening it. */
LUAI_FUNC int luaAP_fdpath(int fd, char *path, size_t path_size);

/* Resolve, authorize, and retain a move source before resolving its
** destination. luaAP_movebound() consumes no ownership. */
LUAI_FUNC int luaAP_bindmovesource(lua_State *L, const char *path,
                                   LusAuthMoveSource *source);
LUAI_FUNC int luaAP_movebound(lua_State *L, LusAuthMoveSource *source,
                              const char *destination);
LUAI_FUNC void luaAP_closemovesource(LusAuthMoveSource *source);

/* Bind an existing leaf without following its final symbolic link. */
LUAI_FUNC int luaAP_trybinddelete(lua_State *L, const char *path,
                                  const char *perm, LusAuthFile *file);

/* Delete an already retained file and parent pair. The descriptors remain
** borrowed by the caller. */
LUAI_FUNC int luaAP_deleteboundfd(int fd, int parent_fd, const char *leaf);

/* Install the synchronization hook used by retained deletion regressions. */
LUAI_FUNC void luaAP_setdeletehook(LusAuthDeleteHook hook, void *context);
#endif

#endif
