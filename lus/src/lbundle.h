/*
** $Id: lbundle.h $
** Standalone bundle support
** See Copyright Notice in lua.h
*/

#ifndef lbundle_h
#define lbundle_h

#include <stddef.h>

#include "lua.h"

/* Bundle magic signature (at end of file) */
#define LUSB_MAGIC "LUSB"
#define LUSB_MAGIC_SIZE 4

/* Bundle format version */
#define LUSB_VERSION 1

/* Maximum module name length */
#define LUSB_MAX_NAME 256

/* Maximum number of preserved CLI args */
#define LUSB_MAX_ARGS 64

/* Maximum number of bundled files */
#define LUSB_MAX_FILES 1024

/*
** File entry in bundle index
*/
typedef struct LusBundleFile {
  char name[LUSB_MAX_NAME]; /* module name for require() */
  size_t offset;            /* offset from start of bytecode blob */
  size_t size;              /* bytecode size */
} LusBundleFile;

/*
** Parsed bundle index
*/
typedef struct LusBundle {
  int version;                    /* format version */
  char entrypoint[LUSB_MAX_NAME]; /* main module name */
  int num_args;                   /* preserved CLI args count */
  char *args[LUSB_MAX_ARGS];      /* preserved CLI args */
  int num_files;                  /* bundled files count */
  LusBundleFile *files;           /* file entries */
  size_t data_offset;             /* offset to bytecode blob in exe */
  char exe_path[4096];            /* path to self executable */
} LusBundle;

/*
** Detect if running executable has an embedded bundle.
** Returns 1 if bundle detected, 0 otherwise.
*/
int lusB_detect(void);

/*
** Load and parse bundle from self executable.
** Returns bundle on success, NULL on failure.
** Caller must free with lusB_free().
*/
LusBundle *lusB_load(void);

/*
** Get file contents from bundle.
** Returns pointer to bytecode data (must be freed by caller).
** Sets *size to bytecode size.
** Returns NULL if file not found.
*/
char *lusB_getfile(LusBundle *bundle, const char *name, size_t *size);

/*
** Free bundle resources.
*/
void lusB_free(LusBundle *bundle);

/*
** Get path to currently running executable.
** Returns 1 on success, 0 on failure.
*/
int lusB_getexepath(char *buf, size_t bufsize);

/*
** Build bundle index from arrays.
** Returns allocated index buffer; caller must free.
** Sets *index_size to buffer size.
*/
unsigned char *lusB_buildindex(int version, const char *entrypoint,
                               int num_args, char **args, int num_files,
                               const char **names, size_t *offsets,
                               size_t *sizes, size_t *index_size);

/*
** Global bundle pointer (defined in lua.c, used by loadlib.c searcher)
*/
extern LusBundle *g_bundle;

#endif
