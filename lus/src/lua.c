/*
** $Id: lua.c $
** Lua stand-alone interpreter
** See Copyright Notice in lua.h
*/

#define lua_c

#include "lprefix.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <signal.h>

#if !defined(_WIN32)
#include <sys/stat.h>
#else
#include <windows.h>
#endif

#include "lua.h"

#include "last.h"
#include "lauxlib.h"
#include "lbundle.h"
#include "lmem.h"
#include "lparser.h"
#include "lpledge.h"
#include "lstate.h"
#include "lualib.h"
#include "lworkerlib.h"
#include "lformat.h"
#include "lzio.h"

#if !defined(LUA_PROGNAME)
#define LUA_PROGNAME "lus"
#endif

#if !defined(LUA_INIT_VAR)
#define LUA_INIT_VAR "LUA_INIT"
#endif

#define LUA_INITVARVERSION LUA_INIT_VAR LUA_VERSUFFIX

static lua_State *globalL = NULL;

static const char *progname = LUA_PROGNAME;

static const char *astgraph_output = NULL; /* --ast-graph output file */
static const char *astjson_output = NULL;  /* --ast-json output file */
static int pedantic_warnings = 0;          /* -Wpedantic flag */

/* Standalone bundle options */
static const char *standalone_entry = NULL; /* --standalone entry file */
#define MAX_INCLUDES 256
static const char *includes[MAX_INCLUDES]; /* --include files */
static int num_includes = 0;
#define MAX_PRESERVED_ARGS 64
static const char *preserved_args[MAX_PRESERVED_ARGS]; /* --args values */
static int num_preserved_args = 0;

/*
** Worker setup callback - gives workers the same libraries as main state
*/
static void worker_setup(lua_State *parent, lua_State *worker) {
  (void)parent;
  luaL_openselectedlibs(worker, ~0, 0); /* open all standard libraries */
}

#if defined(LUA_USE_POSIX) /* { */

/*
** Use 'sigaction' when available.
*/
static void setsignal(int sig, void (*handler)(int)) {
  struct sigaction sa;
  sa.sa_handler = handler;
  sa.sa_flags = 0;
  sigemptyset(&sa.sa_mask); /* do not mask any signal */
  sigaction(sig, &sa, NULL);
}

#else /* }{ */

#define setsignal signal

#endif /* } */

/*
** Hook set by signal function to stop the interpreter.
*/
static void lstop(lua_State *L, lua_Debug *ar) {
  (void)ar;                   /* unused arg. */
  lua_sethook(L, NULL, 0, 0); /* reset hook */
  luaL_error(L, "interrupted!");
}

/*
** Function to be called at a C signal. Because a C signal cannot
** just change a Lua state (as there is no proper synchronization),
** this function only sets a hook that, when called, will stop the
** interpreter.
*/
static void laction(int i) {
  int flag = LUA_MASKCALL | LUA_MASKRET | LUA_MASKLINE | LUA_MASKCOUNT;
  setsignal(i, SIG_DFL); /* if another SIGINT happens, terminate process */
  lua_sethook(globalL, lstop, flag, 1);
}

static void print_usage(const char *badoption) {
  lua_writestringerror("%s: ", progname);
  if (badoption[1] == 'e' || badoption[1] == 'l')
    lua_writestringerror("'%s' needs argument\n", badoption);
  else
    lua_writestringerror("unrecognized option '%s'\n", badoption);
  lua_writestringerror(
      "usage: %s [command] [options] [script [args]]\n"
      "\n"
      "Commands:\n"
      "  format    Format Lus source files\n"
      "  run       Run a Lus script (default)\n"
      "\n"
      "Options:\n"
      "  -e stat   execute string 'stat'\n"
      "  -i        enter interactive mode after executing 'script'\n"
      "  -l mod    require library 'mod' into global 'mod'\n"
      "  -l g=mod  require library 'mod' into global 'g'\n"
      "  -v        show version information\n"
      "  -E        ignore environment variables\n"
      "  -W        turn warnings on\n"
      "  -Wpedantic turn on pedantic warnings\n"
      "  -P perm   grant permission (e.g., -Pfs:read, -Pnetwork)\n"
      "  --pledge perm  same as -P\n"
      "  --ast-graph file  dump AST to .dot file (does not run script)\n"
      "  --ast-json file   dump AST to JSON file (does not run script)\n"
      "  --standalone file create standalone executable from script\n"
      "  --include path[:alias] include file/dir in standalone bundle\n"
      "  --        stop handling options\n"
      "  -         stop handling options and execute stdin\n",
      progname);
}

/*
** =======================================================
** Subcommand infrastructure
** =======================================================
*/

/* Forward declarations for functions defined later in the file */
static void l_message(const char *pname, const char *msg);

/* Forward declarations for subcommand handlers */
static int cmd_format(lua_State *L, int argc, char **argv);

/* Subcommand table entry */
typedef struct {
  const char *name;
  int (*handler)(lua_State *L, int argc, char **argv);
  const char *help;
} Subcommand;

static const Subcommand subcommands[] = {
  {"format", cmd_format, "Format Lus source files"},
  {NULL, NULL, NULL}
};

/*
** Find a subcommand by name. Returns NULL if not found.
*/
static const Subcommand *find_subcommand(const char *name) {
  const Subcommand *cmd;
  for (cmd = subcommands; cmd->name != NULL; cmd++) {
    if (strcmp(name, cmd->name) == 0)
      return cmd;
  }
  return NULL;
}

/*
** Read entire file contents into a malloc'd buffer. Returns NULL on error.
*/
static char *read_file_contents(const char *filename, size_t *out_len) {
  FILE *f;
  long len;
  char *buf;

  f = fopen(filename, "rb");
  if (f == NULL) return NULL;

  fseek(f, 0, SEEK_END);
  len = ftell(f);
  fseek(f, 0, SEEK_SET);

  if (len < 0) { fclose(f); return NULL; }

  buf = (char *)malloc((size_t)len + 1);
  if (buf == NULL) { fclose(f); return NULL; }

  if (len > 0 && fread(buf, 1, (size_t)len, f) != (size_t)len) {
    free(buf); fclose(f); return NULL;
  }
  buf[len] = '\0';
  fclose(f);
  if (out_len) *out_len = (size_t)len;
  return buf;
}

/*
** Read all of stdin into a malloc'd buffer.
*/
static char *read_stdin_contents(size_t *out_len) {
  size_t cap = 4096, len = 0;
  char *buf = (char *)malloc(cap);
  if (buf == NULL) return NULL;

  while (!feof(stdin)) {
    if (len + 4096 > cap) {
      cap *= 2;
      buf = (char *)realloc(buf, cap);
      if (buf == NULL) return NULL;
    }
    size_t n = fread(buf + len, 1, 4096, stdin);
    len += n;
    if (n == 0) break;
  }
  buf[len] = '\0';
  if (out_len) *out_len = len;
  return buf;
}

/*
** `lus format` subcommand handler.
**
** Usage: lus format [options] [file ...]
**   --check    Check if files are formatted (exit 1 if not)
**   --write    Format files in-place
**   --stdin    Read from stdin, write to stdout
**   --indent N Set indent width (default: 4)
**   --help     Show help
*/
static int cmd_format(lua_State *L, int argc, char **argv) {
  int check_mode = 0;
  int write_mode = 0;
  int stdin_mode = 0;
  int indent_width = 4;
  int file_start = -1;  /* index of first file argument */
  int i;

  /* Parse format-specific options */
  for (i = 1; i < argc; i++) {
    if (argv[i][0] != '-') {
      file_start = i;
      break;
    }
    if (strcmp(argv[i], "--check") == 0) {
      check_mode = 1;
    } else if (strcmp(argv[i], "--write") == 0) {
      write_mode = 1;
    } else if (strcmp(argv[i], "--stdin") == 0) {
      stdin_mode = 1;
    } else if (strcmp(argv[i], "--indent") == 0) {
      if (i + 1 < argc) {
        indent_width = atoi(argv[++i]);
        if (indent_width <= 0) indent_width = 4;
      } else {
        l_message(progname, "'--indent' needs a number argument");
        return 0;
      }
    } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      lua_writestringerror(
        "Usage: %s format [options] [file ...]\n"
        "\n"
        "Options:\n"
        "  --check    Check if files are formatted (exit 1 if not)\n"
        "  --write    Format files in-place\n"
        "  --stdin    Read from stdin, write to stdout\n"
        "  --indent N Set indent width (default: 4)\n"
        "  --help     Show this help\n"
        "\n"
        "With no --write or --check, prints formatted output to stdout.\n",
        progname);
      return 1;
    } else {
      l_message(progname,
        lua_pushfstring(L, "format: unrecognized option '%s'", argv[i]));
      return 0;
    }
  }

  /* stdin mode */
  if (stdin_mode) {
    size_t srclen;
    char *source = read_stdin_contents(&srclen);
    if (source == NULL) {
      l_message(progname, "failed to read stdin");
      return 0;
    }
    const char *fmterr = NULL;
    char *formatted = lusF_format(L, source, srclen, "=stdin",
                                  indent_width, 80, &fmterr);
    if (formatted == NULL) {
      l_message(progname, fmterr ? fmterr : "format error");
      free(source);
      return 0;
    }
    if (check_mode) {
      int same = (strcmp(source, formatted) == 0);
      free(source);
      free(formatted);
      return same;
    }
    fputs(formatted, stdout);
    free(source);
    free(formatted);
    return 1;
  }

  /* File mode: need at least one file */
  if (file_start < 0) {
    l_message(progname,
      "format: no input files (use --stdin to read from stdin)");
    return 0;
  }

  int all_formatted = 1;  /* for --check mode */

  for (i = file_start; i < argc; i++) {
    const char *filename = argv[i];
    size_t srclen;
    char *source = read_file_contents(filename, &srclen);
    if (source == NULL) {
      fprintf(stderr, "%s: cannot read '%s'\n", progname, filename);
      return 0;
    }

    const char *fmterr = NULL;
    char *formatted = lusF_format(L, source, srclen, filename,
                                  indent_width, 80, &fmterr);
    if (formatted == NULL) {
      fprintf(stderr, "%s: %s\n", filename,
              fmterr ? fmterr : "format error");
      free(source);
      return 0;
    }

    if (check_mode) {
      if (strcmp(source, formatted) != 0) {
        fprintf(stderr, "%s: not formatted\n", filename);
        all_formatted = 0;
      }
    } else if (write_mode) {
      FILE *f = fopen(filename, "wb");
      if (f == NULL) {
        fprintf(stderr, "%s: cannot write '%s'\n", progname, filename);
        free(source);
        free(formatted);
        return 0;
      }
      fputs(formatted, f);
      fclose(f);
    } else {
      fputs(formatted, stdout);
    }

    free(source);
    free(formatted);
  }

  return check_mode ? all_formatted : 1;
}

/*
** Prints an error message, adding the program name in front of it
** (if present)
*/
static void l_message(const char *pname, const char *msg) {
  if (pname)
    lua_writestringerror("%s: ", pname);
  lua_writestringerror("%s\n", msg);
}

/*
** Check whether 'status' is not OK and, if so, prints the error
** message on the top of the stack.
*/
static int report(lua_State *L, int status) {
  if (status != LUA_OK) {
    const char *msg = lua_tostring(L, -1);
    if (msg == NULL)
      msg = "(error message not a string)";
    l_message(progname, msg);
    lua_pop(L, 1); /* remove message */
  }
  return status;
}

/*
** Message handler used to run all chunks
*/
static int msghandler(lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  if (msg == NULL) {                         /* is error object not a string? */
    if (luaL_callmeta(L, 1, "__tostring") && /* does it have a metamethod */
        lua_type(L, -1) == LUA_TSTRING)      /* that produces a string? */
      return 1;                              /* that is the message */
    else
      msg = lua_pushfstring(L, "(error object is a %s value)",
                            luaL_typename(L, 1));
  }
  luaL_traceback(L, L, msg, 1); /* append a standard traceback */
  return 1;                     /* return the traceback */
}

/*
** Interface to 'lua_pcall', which sets appropriate message function
** and C-signal handler. Used to run all chunks.
*/
static int docall(lua_State *L, int narg, int nres) {
  int status;
  int base = lua_gettop(L) - narg;  /* function index */
  lua_pushcfunction(L, msghandler); /* push message handler */
  lua_insert(L, base);              /* put it under function and args */
  globalL = L;                      /* to be available to 'laction' */
  setsignal(SIGINT, laction);       /* set C-signal handler */
  status = lua_pcall(L, narg, nres, base);
  setsignal(SIGINT, SIG_DFL); /* reset C-signal handler */
  lua_remove(L, base);        /* remove message handler from the stack */
  return status;
}

static void print_version(void) {
  lua_writestring(LUA_COPYRIGHT, strlen(LUA_COPYRIGHT));
  lua_writeline();
}

/*
** Create the 'arg' table, which stores all arguments from the
** command line ('argv'). It should be aligned so that, at index 0,
** it has 'argv[script]', which is the script name. The arguments
** to the script (everything after 'script') go to positive indices;
** other arguments (before the script name) go to negative indices.
** If there is no script name, assume interpreter's name as base.
** (If there is no interpreter's name either, 'script' is -1, so
** table sizes are zero.)
*/
static void createargtable(lua_State *L, char **argv, int argc, int script) {
  int i, narg;
  narg = argc - (script + 1); /* number of positive indices */
  lua_createtable(L, narg, script + 1);
  for (i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i - script);
  }
  lua_setglobal(L, "arg");
}

static int dochunk(lua_State *L, int status) {
  if (status == LUA_OK)
    status = docall(L, 0, 0);
  return report(L, status);
}

static int dofile(lua_State *L, const char *name) {
  return dochunk(L, luaL_loadfile(L, name));
}

static int dostring(lua_State *L, const char *s, const char *name) {
  return dochunk(L, luaL_loadbuffer(L, s, strlen(s), name));
}

/*
** Receives 'globname[=modname]' and runs 'globname = require(modname)'.
** If there is no explicit modname and globname contains a '-', cut
** the suffix after '-' (the "version") to make the global name.
*/
static int dolibrary(lua_State *L, char *globname) {
  int status;
  char *suffix = NULL;
  char *modname = strchr(globname, '=');
  if (modname == NULL) { /* no explicit name? */
    modname = globname;  /* module name is equal to global name */
    suffix = strchr(modname, *LUA_IGMARK); /* look for a suffix mark */
  } else {
    *modname = '\0'; /* global name ends here */
    modname++;       /* module name starts after the '=' */
  }
  lua_getglobal(L, "require");
  lua_pushstring(L, modname);
  status = docall(L, 1, 1); /* call 'require(modname)' */
  if (status == LUA_OK) {
    if (suffix != NULL)         /* is there a suffix mark? */
      *suffix = '\0';           /* remove suffix from global name */
    lua_setglobal(L, globname); /* globname = require(modname) */
  }
  return report(L, status);
}

/*
** Push on the stack the contents of table 'arg' from 1 to #arg
*/
static int pushargs(lua_State *L) {
  int i, n;
  if (lua_getglobal(L, "arg") != LUA_TTABLE)
    luaL_error(L, "'arg' is not a table");
  n = (int)luaL_len(L, -1);
  luaL_checkstack(L, n + 3, "too many arguments to script");
  for (i = 1; i <= n; i++)
    lua_rawgeti(L, -i, i);
  lua_remove(L, -i); /* remove table from the stack */
  return n;
}

static int handle_script(lua_State *L, char **argv) {
  int status;
  const char *fname = argv[0];
  if (strcmp(fname, "-") == 0 && strcmp(argv[-1], "--") != 0)
    fname = NULL; /* stdin */
  status = luaL_loadfile(L, fname);
  if (status == LUA_OK) {
    int n = pushargs(L); /* push arguments to script */
    status = docall(L, n, LUA_MULTRET);
  }
  return report(L, status);
}
/*
** String reader for AST graph generation
*/
typedef struct {
  const char *s;
  size_t size;
} AstGraphReader;

static const char *astgraph_getS(lua_State *L, void *ud, size_t *sz) {
  AstGraphReader *ls = (AstGraphReader *)ud;
  (void)L; /* unused */
  if (ls->size == 0)
    return NULL;
  *sz = ls->size;
  ls->size = 0;
  return ls->s;
}

/*
** Handle --ast-graph option: parse script and dump AST to .dot file
*/
static int handle_astgraph(lua_State *L, const char *fname,
                           const char *output) {
  FILE *f;
  char *content;
  long fsize;
  LusAst *ast;
  Mbuffer buff;
  Dyndata dyd;
  ZIO z;
  AstGraphReader reader;
  int c;

  /* Read file content */
  f = fopen(fname, "r");
  if (f == NULL) {
    l_message(progname, "cannot open file for AST dump");
    return 0;
  }
  fseek(f, 0, SEEK_END);
  fsize = ftell(f);
  fseek(f, 0, SEEK_SET);
  content = luaM_newblock(L, fsize + 1);
  if (fread(content, 1, fsize, f) != (size_t)fsize) {
    fclose(f);
    luaM_freemem(L, content, fsize + 1);
    l_message(progname, "cannot read file");
    return 0;
  }
  content[fsize] = '\0';
  fclose(f);

  /* Parse with AST generation */
  ast = lusA_new(L);
  if (ast == NULL) {
    luaM_freemem(L, content, fsize + 1);
    l_message(progname, "cannot create AST");
    return 0;
  }

  /* Initialize parser data structures */
  luaZ_initbuffer(L, &buff);
  luaY_initdyndata(L, &dyd);

  /* Initialize reader */
  reader.s = content;
  reader.size = (size_t)fsize;
  luaZ_init(L, &z, astgraph_getS, &reader);
  c = zgetc(&z); /* read first character */

  /* Check for binary chunk */
  if (c == LUA_SIGNATURE[0]) {
    lusA_free(L, ast);
    luaZ_freebuffer(L, &buff);
    luaY_freedyndata(&dyd);
    luaM_freemem(L, content, fsize + 1);
    l_message(progname, "cannot parse binary chunk");
    return 0;
  }

  /* Parse */
  luaY_parser(L, &z, &buff, &dyd, fname, c, ast);

  /* Clean up parser data */
  luaZ_freebuffer(L, &buff);
  luaY_freedyndata(&dyd); /* free arena (all arrays freed with it) */
  lua_pop(L, 1); /* remove closure */

  luaM_freemem(L, content, fsize + 1);

  /* Dump AST to .dot file */
  if (!lusA_tographviz(ast, output)) {
    lusA_free(L, ast);
    l_message(progname, "cannot write AST graph file");
    return 0;
  }

  lua_writestringerror("AST graph written to %s\n", output);

  lusA_free(L, ast);
  return 1;
}

/*
** Handle --ast-json option: parse script and dump AST to JSON file
*/
static int handle_astjson(lua_State *L, const char *fname, const char *output) {
  FILE *f;
  char *content;
  long fsize;
  LusAst *ast;
  Mbuffer buff;
  Dyndata dyd;
  ZIO z;
  AstGraphReader reader;
  int c;

  /* Read file content */
  f = fopen(fname, "r");
  if (f == NULL) {
    l_message(progname, "cannot open file for AST dump");
    return 0;
  }
  fseek(f, 0, SEEK_END);
  fsize = ftell(f);
  fseek(f, 0, SEEK_SET);
  content = luaM_newblock(L, fsize + 1);
  if (fread(content, 1, fsize, f) != (size_t)fsize) {
    fclose(f);
    luaM_freemem(L, content, fsize + 1);
    l_message(progname, "cannot read file");
    return 0;
  }
  content[fsize] = '\0';
  fclose(f);

  /* Parse with AST generation */
  ast = lusA_new(L);
  if (ast == NULL) {
    luaM_freemem(L, content, fsize + 1);
    l_message(progname, "cannot create AST");
    return 0;
  }

  /* Initialize parser data structures */
  luaZ_initbuffer(L, &buff);
  luaY_initdyndata(L, &dyd);

  /* Initialize reader */
  reader.s = content;
  reader.size = (size_t)fsize;
  luaZ_init(L, &z, astgraph_getS, &reader);
  c = zgetc(&z); /* read first character */

  /* Check for binary chunk */
  if (c == LUA_SIGNATURE[0]) {
    lusA_free(L, ast);
    luaZ_freebuffer(L, &buff);
    luaY_freedyndata(&dyd);
    luaM_freemem(L, content, fsize + 1);
    l_message(progname, "cannot parse binary chunk");
    return 0;
  }

  /* Parse */
  luaY_parser(L, &z, &buff, &dyd, fname, c, ast);

  /* Clean up parser data */
  luaZ_freebuffer(L, &buff);
  luaY_freedyndata(&dyd); /* free arena (all arrays freed with it) */
  lua_pop(L, 1); /* remove closure */

  luaM_freemem(L, content, fsize + 1);

  /* Dump AST to JSON file */
  if (!lusA_tojson(ast, output)) {
    lusA_free(L, ast);
    l_message(progname, "cannot write AST JSON file");
    return 0;
  }

  lua_writestringerror("AST JSON written to %s\n", output);

  lusA_free(L, ast);
  return 1;
}

/*
** Writer function for lua_dump to write to a buffer
*/
typedef struct {
  char *buf;
  size_t size;
  size_t capacity;
} DumpBuffer;

static int dump_writer(lua_State *L, const void *p, size_t sz, void *ud) {
  DumpBuffer *db = (DumpBuffer *)ud;
  if (db->size + sz > db->capacity) {
    size_t newcap = db->capacity * 2;
    if (newcap < db->size + sz)
      newcap = db->size + sz + 1024;
    db->buf = luaM_reallocvchar(L, db->buf, db->capacity, newcap);
    db->capacity = newcap;
  }
  memcpy(db->buf + db->size, p, sz);
  db->size += sz;
  return 0;
}

/*
** Get module name from file path, optionally with alias
** "foo.lua" -> "foo"
** "foo.lua:bar" -> "bar"
** "dir/foo.lua" -> "dir.foo"
*/
static void get_module_name(const char *path, char *out, size_t outsize) {
  const char *colon = strchr(path, ':');
  if (colon != NULL) {
    /* Use alias after colon */
    size_t len = strlen(colon + 1);
    if (len >= outsize)
      len = outsize - 1;
    memcpy(out, colon + 1, len);
    out[len] = '\0';
    return;
  }

  /* Extract basename and remove extension */
  const char *start = path;
  const char *p;

  /* Find last component for basename */
  for (p = path; *p; p++) {
    if (*p == '/' || *p == '\\')
      start = p + 1;
  }

  /* Copy and convert path separators to dots, remove extension */
  size_t i = 0;
  for (p = start; *p && i < outsize - 1; p++) {
    if (*p == '/' || *p == '\\') {
      out[i++] = '.';
    } else if (*p == '.' &&
               (strcmp(p, ".lua") == 0 || strcmp(p, ".lus") == 0)) {
      break;
    } else {
      out[i++] = *p;
    }
  }
  out[i] = '\0';
}

/*
** Get file path without alias
*/
static const char *get_file_path(const char *path) {
  const char *colon = strchr(path, ':');
  if (colon != NULL) {
    static char buf[4096];
    size_t len = colon - path;
    if (len >= sizeof(buf))
      len = sizeof(buf) - 1;
    memcpy(buf, path, len);
    buf[len] = '\0';
    return buf;
  }
  return path;
}

/*
** Check if path is a directory
*/
static int is_directory(const char *path) {
#if defined(_WIN32)
  DWORD attr = GetFileAttributesA(path);
  return (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY));
#else
  struct stat st;
  return (stat(path, &st) == 0 && S_ISDIR(st.st_mode));
#endif
}

#if !defined(_WIN32)
#include <dirent.h>
#endif

/*
** Add files from a directory to the include list (recursive).
** Returns number of files added, or -1 on error.
*/
static int include_directory(const char *dirpath, const char *prefix,
                             const char **file_list, int *file_count,
                             int max_files) {
  char fullpath[4096];
  char modprefix[LUSB_MAX_NAME];
  int added = 0;

#if defined(_WIN32)
  char search_path[4096];
  WIN32_FIND_DATA fd;
  HANDLE hFind;

  snprintf(search_path, sizeof(search_path), "%s\\*", dirpath);
  hFind = FindFirstFile(search_path, &fd);
  if (hFind == INVALID_HANDLE_VALUE)
    return -1;

  do {
    /* Skip . and .. */
    if (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0)
      continue;

    /* Build full path */
    snprintf(fullpath, sizeof(fullpath), "%s\\%s", dirpath, fd.cFileName);

    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      /* Recurse into subdirectory */
      if (prefix[0] != '\0')
        snprintf(modprefix, sizeof(modprefix), "%s.%s", prefix, fd.cFileName);
      else
        snprintf(modprefix, sizeof(modprefix), "%s", fd.cFileName);

      int sub = include_directory(fullpath, modprefix, file_list, file_count,
                                  max_files);
      if (sub < 0) {
        FindClose(hFind);
        return -1;
      }
      added += sub;
    } else {
      /* Check if it's a .lua or .lus file */
      size_t len = strlen(fd.cFileName);
      if ((len > 4 && strcmp(fd.cFileName + len - 4, ".lua") == 0) ||
          (len > 4 && strcmp(fd.cFileName + len - 4, ".lus") == 0)) {
        if (*file_count >= max_files) {
          FindClose(hFind);
          return -1;
        }
        /* Store as "path:module.name" format */
        char *entry_str = (char *)malloc(4096);
        if (entry_str == NULL) {
          FindClose(hFind);
          return -1;
        }
        /* Build module name: prefix + basename without extension */
        char modname[LUSB_MAX_NAME];
        size_t baselen = len - 4;
        if (prefix[0] != '\0')
          snprintf(modname, sizeof(modname), "%s.%.*s", prefix, (int)baselen,
                   fd.cFileName);
        else
          snprintf(modname, sizeof(modname), "%.*s", (int)baselen,
                   fd.cFileName);

        snprintf(entry_str, 4096, "%s:%s", fullpath, modname);
        file_list[*file_count] = entry_str;
        (*file_count)++;
        added++;
      }
    }
  } while (FindNextFile(hFind, &fd));
  FindClose(hFind);

#else /* POSIX */
  DIR *dir;
  struct dirent *entry;

  dir = opendir(dirpath);
  if (dir == NULL)
    return -1;

  while ((entry = readdir(dir)) != NULL) {
    /* Skip . and .. */
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
      continue;

    /* Build full path */
    snprintf(fullpath, sizeof(fullpath), "%s/%s", dirpath, entry->d_name);

    if (is_directory(fullpath)) {
      /* Recurse into subdirectory */
      if (prefix[0] != '\0')
        snprintf(modprefix, sizeof(modprefix), "%s.%s", prefix, entry->d_name);
      else
        snprintf(modprefix, sizeof(modprefix), "%s", entry->d_name);

      int sub = include_directory(fullpath, modprefix, file_list, file_count,
                                  max_files);
      if (sub < 0) {
        closedir(dir);
        return -1;
      }
      added += sub;
    } else {
      /* Check if it's a .lua or .lus file */
      size_t len = strlen(entry->d_name);
      if ((len > 4 && strcmp(entry->d_name + len - 4, ".lua") == 0) ||
          (len > 4 && strcmp(entry->d_name + len - 4, ".lus") == 0)) {
        if (*file_count >= max_files) {
          closedir(dir);
          return -1;
        }
        /* Store as "path:module.name" format */
        char *entry_str = (char *)malloc(4096);
        if (entry_str == NULL) {
          closedir(dir);
          return -1;
        }
        /* Build module name: prefix + basename without extension */
        char modname[LUSB_MAX_NAME];
        size_t baselen = len - 4; /* strip .lua or .lus */
        if (prefix[0] != '\0')
          snprintf(modname, sizeof(modname), "%s.%.*s", prefix, (int)baselen,
                   entry->d_name);
        else
          snprintf(modname, sizeof(modname), "%.*s", (int)baselen,
                   entry->d_name);

        snprintf(entry_str, 4096, "%s:%s", fullpath, modname);
        file_list[*file_count] = entry_str;
        (*file_count)++;
        added++;
      }
    }
  }

  closedir(dir);
#endif

  return added;
}

/*
** Create standalone executable with bundled scripts
*/
static int create_standalone(lua_State *L) {
  char exepath[4096];
  char outpath[4096];
  FILE *exefile, *outfile;
  long exesize;
  char *exedata;
  DumpBuffer *bytecodes = NULL;
  const char **names = NULL;
  size_t *offsets = NULL;
  size_t *sizes = NULL;
  int file_count = 0;
  int file_capacity = 0;
  size_t total_bytecode_size = 0;
  unsigned char *index_data;
  size_t index_size;
  unsigned char footer[8];
  const char *entryname = "main";
  int i;

  /* Get current executable path */
  if (!lusB_getexepath(exepath, sizeof(exepath))) {
    l_message(progname, "cannot get executable path");
    return 0;
  }

  /* Open current executable for reading */
  exefile = fopen(exepath, "rb");
  if (exefile == NULL) {
    l_message(progname, "cannot open executable");
    return 0;
  }

  /* Get executable size */
  fseek(exefile, 0, SEEK_END);
  exesize = ftell(exefile);
  fseek(exefile, 0, SEEK_SET);

  /* Read executable */
  exedata = luaM_newblock(L, (size_t)exesize);
  if (fread(exedata, 1, exesize, exefile) != (size_t)exesize) {
    luaM_freemem(L, exedata, (size_t)exesize);
    fclose(exefile);
    l_message(progname, "cannot read executable");
    return 0;
  }
  fclose(exefile);

  /* Create output filename from entry point */
  {
    const char *entry = standalone_entry;
    const char *base = entry;
    const char *p, *ext;

    /* Find basename */
    for (p = entry; *p; p++) {
      if (*p == '/' || *p == '\\')
        base = p + 1;
    }

    /* Find extension */
    ext = strrchr(base, '.');
    if (ext == NULL)
      ext = base + strlen(base);

    /* Build output path */
    size_t baselen = ext - base;
    if (baselen >= sizeof(outpath))
      baselen = sizeof(outpath) - 1;
    memcpy(outpath, base, baselen);
#if defined(_WIN32)
    strcpy(outpath + baselen, ".exe");
#else
    outpath[baselen] = '\0';
#endif
  }

  /* Compile entry point and all includes */
  file_capacity = num_includes + 1;
  bytecodes = luaM_newvector(L, file_capacity, DumpBuffer);
  names = luaM_newvector(L, file_capacity, const char *);
  offsets = luaM_newvector(L, file_capacity, size_t);
  sizes = luaM_newvector(L, file_capacity, size_t);

  /* Compile entry point */
  {
    char modname[LUSB_MAX_NAME];
    get_module_name(standalone_entry, modname, sizeof(modname));
    entryname = strdup(modname);

    if (luaL_loadfile(L, standalone_entry) != LUA_OK) {
      l_message(progname, lua_tostring(L, -1));
      luaM_freemem(L, exedata, (size_t)exesize);
      luaM_freearray(L, bytecodes, file_capacity);
      luaM_freearray(L, names, file_capacity);
      luaM_freearray(L, offsets, file_capacity);
      luaM_freearray(L, sizes, file_capacity);
      return 0;
    }

    bytecodes[file_count].buf = NULL;
    bytecodes[file_count].size = 0;
    bytecodes[file_count].capacity = 0;

    if (lua_dump(L, dump_writer, &bytecodes[file_count], 1) != 0) {
      l_message(progname, "cannot dump bytecode");
      luaM_freemem(L, exedata, (size_t)exesize);
      luaM_freearray(L, bytecodes, file_capacity);
      luaM_freearray(L, names, file_capacity);
      luaM_freearray(L, offsets, file_capacity);
      luaM_freearray(L, sizes, file_capacity);
      return 0;
    }
    lua_pop(L, 1);

    names[file_count] = entryname;
    offsets[file_count] = total_bytecode_size;
    sizes[file_count] = bytecodes[file_count].size;
    total_bytecode_size += bytecodes[file_count].size;
    file_count++;
  }

  /* Expand directories and compile includes */
  {
    /* Build expanded file list from includes (files + directory contents) */
    const char *expanded[LUSB_MAX_FILES];
    int expanded_count = 0;

    for (i = 0; i < num_includes; i++) {
      const char *filepath = get_file_path(includes[i]);

      if (is_directory(filepath)) {
        /* Get directory base name for module prefix */
        const char *dirbase = filepath;
        const char *p;
        for (p = filepath; *p; p++) {
          if (*p == '/' || *p == '\\')
            dirbase = p + 1;
        }
        /* Expand directory recursively */
        if (include_directory(filepath, dirbase, expanded, &expanded_count,
                              LUSB_MAX_FILES) < 0) {
          lua_writestringerror("warning: failed to include directory: %s\n",
                               filepath);
        }
      } else {
        /* Regular file */
        if (expanded_count >= LUSB_MAX_FILES) {
          l_message(progname, "too many include files");
          for (int j = 0; j < file_count; j++)
            luaM_freemem(L, bytecodes[j].buf, bytecodes[j].capacity);
          luaM_freemem(L, exedata, (size_t)exesize);
          luaM_freearray(L, bytecodes, file_capacity);
          luaM_freearray(L, names, file_capacity);
          luaM_freearray(L, offsets, file_capacity);
          luaM_freearray(L, sizes, file_capacity);
          return 0;
        }
        expanded[expanded_count++] = includes[i];
      }
    }

    /* Reallocate arrays if we have more files from directory expansion */
    if (file_count + expanded_count > file_capacity) {
      int old_capacity = file_capacity;
      file_capacity = file_count + expanded_count;
      bytecodes = luaM_reallocvector(L, bytecodes, old_capacity, file_capacity,
                                     DumpBuffer);
      names = luaM_reallocvector(L, names, old_capacity, file_capacity,
                                 const char *);
      offsets =
          luaM_reallocvector(L, offsets, old_capacity, file_capacity, size_t);
      sizes =
          luaM_reallocvector(L, sizes, old_capacity, file_capacity, size_t);
    }

    /* Compile each expanded file */
    for (i = 0; i < expanded_count; i++) {
      const char *filepath = get_file_path(expanded[i]);
      char modname[LUSB_MAX_NAME];

      get_module_name(expanded[i], modname, sizeof(modname));

      if (luaL_loadfile(L, filepath) != LUA_OK) {
        l_message(progname, lua_tostring(L, -1));
        /* Clean up */
        for (int j = 0; j < file_count; j++)
          luaM_freemem(L, bytecodes[j].buf, bytecodes[j].capacity);
        for (int j = 0; j < expanded_count; j++) {
          /* Free strings allocated by include_directory */
          if (expanded[j] != includes[j])
            free((void *)expanded[j]);
        }
        luaM_freemem(L, exedata, (size_t)exesize);
        luaM_freearray(L, bytecodes, file_capacity);
        luaM_freearray(L, names, file_capacity);
        luaM_freearray(L, offsets, file_capacity);
        luaM_freearray(L, sizes, file_capacity);
        return 0;
      }

      bytecodes[file_count].buf = NULL;
      bytecodes[file_count].size = 0;
      bytecodes[file_count].capacity = 0;

      if (lua_dump(L, dump_writer, &bytecodes[file_count], 1) != 0) {
        l_message(progname, "cannot dump bytecode");
        for (int j = 0; j < file_count; j++)
          luaM_freemem(L, bytecodes[j].buf, bytecodes[j].capacity);
        for (int j = 0; j < expanded_count; j++) {
          if (expanded[j] != includes[j])
            free((void *)expanded[j]);
        }
        luaM_freemem(L, exedata, (size_t)exesize);
        luaM_freearray(L, bytecodes, file_capacity);
        luaM_freearray(L, names, file_capacity);
        luaM_freearray(L, offsets, file_capacity);
        luaM_freearray(L, sizes, file_capacity);
        return 0;
      }
      lua_pop(L, 1);

      names[file_count] = strdup(modname);
      offsets[file_count] = total_bytecode_size;
      sizes[file_count] = bytecodes[file_count].size;
      total_bytecode_size += bytecodes[file_count].size;
      file_count++;
    }

    /* Free strings allocated by include_directory */
    for (i = 0; i < expanded_count; i++) {
      if (expanded[i] != includes[i])
        free((void *)expanded[i]);
    }
  }

  /* Build index with preserved CLI args */
  index_data = lusB_buildindex(LUSB_VERSION, entryname, num_preserved_args,
                               (char **)preserved_args, file_count, names,
                               offsets, sizes, &index_size);

  if (index_data == NULL) {
    for (i = 0; i < file_count; i++)
      luaM_freemem(L, bytecodes[i].buf, bytecodes[i].capacity);
    luaM_freemem(L, exedata, (size_t)exesize);
    luaM_freearray(L, bytecodes, file_capacity);
    luaM_freearray(L, names, file_capacity);
    luaM_freearray(L, offsets, file_capacity);
    luaM_freearray(L, sizes, file_capacity);
    l_message(progname, "cannot build index");
    return 0;
  }

  /* Write output file */
  outfile = fopen(outpath, "wb");
  if (outfile == NULL) {
    for (i = 0; i < file_count; i++)
      luaM_freemem(L, bytecodes[i].buf, bytecodes[i].capacity);
    free(index_data); /* allocated by lusB_buildindex (uses malloc) */
    luaM_freemem(L, exedata, (size_t)exesize);
    luaM_freearray(L, bytecodes, file_capacity);
    luaM_freearray(L, names, file_capacity);
    luaM_freearray(L, offsets, file_capacity);
    luaM_freearray(L, sizes, file_capacity);
    l_message(progname, "cannot create output file");
    return 0;
  }

  /* Write executable */
  fwrite(exedata, 1, exesize, outfile);

  /* Write bytecode blobs */
  for (i = 0; i < file_count; i++) {
    fwrite(bytecodes[i].buf, 1, bytecodes[i].size, outfile);
  }

  /* Write index */
  fwrite(index_data, 1, index_size, outfile);

  /* Write footer: index_size (4 bytes LE) + magic (4 bytes) */
  footer[0] = (unsigned char)(index_size & 0xFF);
  footer[1] = (unsigned char)((index_size >> 8) & 0xFF);
  footer[2] = (unsigned char)((index_size >> 16) & 0xFF);
  footer[3] = (unsigned char)((index_size >> 24) & 0xFF);
  memcpy(footer + 4, LUSB_MAGIC, LUSB_MAGIC_SIZE);
  fwrite(footer, 1, 8, outfile);

  fclose(outfile);

#if !defined(_WIN32)
  /* Make output executable on Unix */
  chmod(outpath, 0755);
#endif

  lua_writestringerror("Created standalone: %s\n", outpath);

  /* Cleanup */
  for (i = 0; i < file_count; i++) {
    luaM_freemem(L, bytecodes[i].buf, bytecodes[i].capacity);
  }
  free(index_data); /* allocated by lusB_buildindex (uses malloc) */
  luaM_freemem(L, exedata, (size_t)exesize);
  luaM_freearray(L, bytecodes, file_capacity);
  luaM_freearray(L, names, file_capacity);
  luaM_freearray(L, offsets, file_capacity);
  luaM_freearray(L, sizes, file_capacity);

  return 1;
}

/* bits of various argument indicators in 'args' */
#define has_error 1 /* bad option */
#define has_i 2     /* -i */
#define has_v 4     /* -v */
#define has_e 8     /* -e */
#define has_E 16    /* -E */

/*
** Traverses all arguments from 'argv', returning a mask with those
** needed before running any Lua code or an error code if it finds any
** invalid argument. In case of error, 'first' is the index of the bad
** argument.  Otherwise, 'first' is -1 if there is no program name,
** 0 if there is no script name, or the index of the script name.
*/
static int collectargs(char **argv, int *first) {
  int args = 0;
  int i;
  if (argv[0] != NULL) {  /* is there a program name? */
    if (argv[0][0])       /* not empty? */
      progname = argv[0]; /* save it */
  } else {                /* no program name */
    *first = -1;
    return 0;
  }
  for (i = 1; argv[i] != NULL; i++) { /* handle arguments */
    *first = i;
    if (argv[i][0] != '-')      /* not an option? */
      return args;              /* stop handling options */
    switch (argv[i][1]) {       /* else check option */
    case '-':                   /* '--' */
      if (argv[i][2] != '\0') { /* extra characters after '--'? */
        /* Check for --pledge */
        if (strcmp(argv[i] + 2, "pledge") == 0) {
          i++; /* skip to argument */
          if (argv[i] == NULL || argv[i][0] == '-')
            return has_error; /* no argument */
          /* Preserve for bundle */
          if (standalone_entry && num_preserved_args < MAX_PRESERVED_ARGS - 1) {
            preserved_args[num_preserved_args++] = "--pledge";
            preserved_args[num_preserved_args++] = argv[i];
          }
          break;
        }
        if (strcmp(argv[i] + 2, "ast-graph") == 0) {
          i++; /* skip to argument */
          if (argv[i] == NULL || argv[i][0] == '-')
            return has_error; /* no argument */
          astgraph_output = argv[i];
          break;
        }
        if (strcmp(argv[i] + 2, "ast-json") == 0) {
          i++; /* skip to argument */
          if (argv[i] == NULL || argv[i][0] == '-')
            return has_error; /* no argument */
          astjson_output = argv[i];
          break;
        }
        if (strcmp(argv[i] + 2, "standalone") == 0) {
          i++; /* skip to argument */
          if (argv[i] == NULL || argv[i][0] == '-')
            return has_error; /* no argument */
          standalone_entry = argv[i];
          break;
        }
        if (strcmp(argv[i] + 2, "include") == 0) {
          i++; /* skip to argument */
          if (argv[i] == NULL || argv[i][0] == '-')
            return has_error; /* no argument */
          if (num_includes >= MAX_INCLUDES) {
            l_message(progname, "too many --include arguments");
            return has_error;
          }
          includes[num_includes++] = argv[i];
          break;
        }
        return has_error; /* invalid option */
      }
      /* if there is a script name, it comes after '--' */
      *first = (argv[i + 1] != NULL) ? i + 1 : 0;
      return args;
    case '\0':     /* '-' */
      return args; /* script "name" is '-' */
    case 'E':
      if (argv[i][2] != '\0') /* extra characters? */
        return has_error;     /* invalid option */
      args |= has_E;
      break;
    case 'W':
      if (argv[i][2] == '\0') { /* just -W */
        /* Preserve for bundle */
        if (standalone_entry && num_preserved_args < MAX_PRESERVED_ARGS)
          preserved_args[num_preserved_args++] = argv[i];
        break;
      } else if (strcmp(argv[i] + 2, "pedantic") == 0) { /* -Wpedantic */
        pedantic_warnings = 1;
        /* Preserve for bundle */
        if (standalone_entry && num_preserved_args < MAX_PRESERVED_ARGS)
          preserved_args[num_preserved_args++] = argv[i];
        break;
      } else
        return has_error; /* unknown -W option */
    case 'i':
      args |= has_i; /* (-i implies -v) */ /* FALLTHROUGH */
    case 'v':
      if (argv[i][2] != '\0') /* extra characters? */
        return has_error;     /* invalid option */
      args |= has_v;
      break;
    case 'e':
      args |= has_e;            /* FALLTHROUGH */
    case 'l':                   /* both options need an argument */
      if (argv[i][2] == '\0') { /* no concatenated argument? */
        i++;                    /* try next 'argv' */
        if (argv[i] == NULL || argv[i][0] == '-')
          return has_error; /* no next argument or it is another option */
        /* Preserve for bundle (2 args) */
        if (standalone_entry && num_preserved_args < MAX_PRESERVED_ARGS - 1) {
          preserved_args[num_preserved_args++] = argv[i - 1];
          preserved_args[num_preserved_args++] = argv[i];
        }
      } else {
        /* Preserve for bundle (1 concatenated arg) */
        if (standalone_entry && num_preserved_args < MAX_PRESERVED_ARGS)
          preserved_args[num_preserved_args++] = argv[i];
      }
      break;
    case 'P':                   /* pledge option */
      if (argv[i][2] == '\0') { /* no concatenated argument? */
        i++;                    /* try next 'argv' */
        if (argv[i] == NULL || argv[i][0] == '-')
          return has_error; /* no next argument or it is another option */
        /* Preserve for bundle (2 args) */
        if (standalone_entry && num_preserved_args < MAX_PRESERVED_ARGS - 1) {
          preserved_args[num_preserved_args++] = argv[i - 1];
          preserved_args[num_preserved_args++] = argv[i];
        }
      } else {
        /* Preserve for bundle (1 concatenated arg) */
        if (standalone_entry && num_preserved_args < MAX_PRESERVED_ARGS)
          preserved_args[num_preserved_args++] = argv[i];
      }
      break;
    default: /* invalid option */
      return has_error;
    }
  }
  *first = 0; /* no script name */
  return args;
}

/*
** Processes options 'e' and 'l', which involve running Lua code, and
** 'W', which also affects the state.
** Returns 0 if some code raises an error.
*/
static int runargs(lua_State *L, char **argv, int n) {
  int i;
  for (i = 1; i < n; i++) {
    int option = argv[i][1];
    lua_assert(argv[i][0] == '-'); /* already checked */
    switch (option) {
    case '-': /* long options: --standalone, --include, --pledge, etc. */
      /* Skip long options that have arguments */
      if (strcmp(argv[i] + 2, "standalone") == 0 ||
          strcmp(argv[i] + 2, "include") == 0 ||
          strcmp(argv[i] + 2, "pledge") == 0 ||
          strcmp(argv[i] + 2, "ast-graph") == 0 ||
          strcmp(argv[i] + 2, "ast-json") == 0) {
        i++; /* skip the argument */
      }
      /* else: just '--' by itself or unrecognized - skip it */
      break;
    case 'e':
    case 'l': {
      int status;
      char *extra = argv[i] + 2; /* both options need an argument */
      if (*extra == '\0')
        extra = argv[++i];
      lua_assert(extra != NULL);
      status = (option == 'e') ? dostring(L, extra, "=(command line)")
                               : dolibrary(L, extra);
      if (status != LUA_OK)
        return 0;
      break;
    }
    case 'W':
      lua_warning(L, "@on", 0); /* warnings on (both -W and -Wpedantic) */
      if (strcmp(argv[i] + 2, "pedantic") == 0) {
        /* Enable pedantic AST-based warnings */
        G(L)->pedantic = 1;
      }
      break;
    case 'P': { /* pledge permission */
      char *pledge_str = argv[i] + 2;
      if (*pledge_str == '\0')
        pledge_str = argv[++i];
      lua_assert(pledge_str != NULL);
      /* Parse and grant the pledge */
      int rejected = 0;
      const char *p = pledge_str;
      if (*p == '~') {
        rejected = 1;
        p++;
      }
      /* Extract name and value */
      const char *eq = strchr(p, '=');
      char namebuf[256];
      const char *value = NULL;
      if (eq) {
        size_t namelen = eq - p;
        if (namelen >= sizeof(namebuf)) {
          l_message(progname, "pledge name too long");
          return 0;
        }
        memcpy(namebuf, p, namelen);
        namebuf[namelen] = '\0';
        value = eq + 1;
      } else {
        size_t namelen = strlen(p);
        if (namelen >= sizeof(namebuf)) {
          l_message(progname, "pledge name too long");
          return 0;
        }
        strcpy(namebuf, p);
      }
      /* Handle special permissions */
      if (strcmp(namebuf, "all") == 0 && !rejected) {
        /* Grant common permissions - all from CLI is allowed */
        lus_pledge(L, "exec", NULL);
        lus_pledge(L, "load", NULL);
        lus_pledge(L, "fs", NULL);
        lus_pledge(L, "network", NULL);
      } else if (strcmp(namebuf, "seal") == 0) {
        /* Seal is handled after all pledges are processed */
        /* Store it - we'll seal at the end */
        /* For now, just grant it; the pledge system handles sealing */
        lus_pledge(L, "seal", NULL);
      } else if (rejected) {
        /* Mark as rejected */
        lus_rejectpledge(L, namebuf);
      } else {
        if (!lus_pledge(L, namebuf, value)) {
          char msg[512];
          snprintf(msg, sizeof(msg), "failed to grant pledge '%s'", pledge_str);
          l_message(progname, msg);
          return 0;
        }
      }
      break;
    }
    }
  }
  return 1;
}

static int handle_luainit(lua_State *L) {
  const char *name = "=" LUA_INITVARVERSION;
  const char *init = getenv(name + 1);
  if (init == NULL) {
    name = "=" LUA_INIT_VAR;
    init = getenv(name + 1); /* try alternative name */
  }
  if (init == NULL)
    return LUA_OK;
  else if (init[0] == '@')
    return dofile(L, init + 1);
  else
    return dostring(L, init, name);
}

/*
** {==================================================================
** Read-Eval-Print Loop (REPL)
** ===================================================================
*/

#if !defined(LUA_PROMPT)
#define LUA_PROMPT "> "
#define LUA_PROMPT2 ">> "
#endif

#if !defined(LUA_MAXINPUT)
#define LUA_MAXINPUT 512
#endif

/*
** lua_stdin_is_tty detects whether the standard input is a 'tty' (that
** is, whether we're running lua interactively).
*/
#if !defined(lua_stdin_is_tty) /* { */

#if defined(LUA_USE_POSIX) /* { */

#include <unistd.h>
#define lua_stdin_is_tty() isatty(0)

#elif defined(LUA_USE_WINDOWS) /* }{ */

#include <io.h>
#include <windows.h>

#define lua_stdin_is_tty() _isatty(_fileno(stdin))

#else                        /* }{ */

/* ISO C definition */
#define lua_stdin_is_tty() 1 /* assume stdin is a tty */

#endif /* } */

#endif /* } */

/*
** * lua_initreadline initializes the readline system.
** * lua_readline defines how to show a prompt and then read a line from
**   the standard input.
** * lua_saveline defines how to "save" a read line in a "history".
** * lua_freeline defines how to free a line read by lua_readline.
*/

#if !defined(lua_readline) /* { */
/* Otherwise, all previously listed functions should be defined. */

#if defined(LUA_USE_READLINE) /* { */
/* Lua will be linked with '-lreadline' */

#include <readline/history.h>
#include <readline/readline.h>

#define lua_initreadline(L) ((void)L, rl_readline_name = "lua")
#define lua_readline(buff, prompt) ((void)buff, readline(prompt))
#define lua_saveline(line) add_history(line)
#define lua_freeline(line) free(line)

#else /* }{ */
/* use dynamically loaded readline (or nothing) */

/* pointer to 'readline' function (if any) */
typedef char *(*l_readlineT)(const char *prompt);
static l_readlineT l_readline = NULL;

/* pointer to 'add_history' function (if any) */
typedef void (*l_addhistT)(const char *string);
static l_addhistT l_addhist = NULL;

static char *lua_readline(char *buff, const char *prompt) {
  if (l_readline != NULL)         /* is there a 'readline'? */
    return (*l_readline)(prompt); /* use it */
  else {                          /* emulate 'readline' over 'buff' */
    fputs(prompt, stdout);
    fflush(stdout);                          /* show prompt */
    return fgets(buff, LUA_MAXINPUT, stdin); /* read line */
  }
}

static void lua_saveline(const char *line) {
  if (l_addhist != NULL) /* is there an 'add_history'? */
    (*l_addhist)(line);  /* use it */
  /* else nothing to be done */
}

static void lua_freeline(char *line) {
  if (l_readline != NULL) /* is there a 'readline'? */
    free(line);           /* free line created by it */
  /* else 'lua_readline' used an automatic buffer; nothing to free */
}

#if defined(LUA_USE_DLOPEN) && defined(LUA_READLINELIB) /* { */
/* try to load 'readline' dynamically */

#include <dlfcn.h>

static void lua_initreadline(lua_State *L) {
  void *lib = dlopen(LUA_READLINELIB, RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL)
    lua_warning(L, "library '" LUA_READLINELIB "' not found", 0);
  else {
    const char **name = cast(const char **, dlsym(lib, "rl_readline_name"));
    if (name != NULL)
      *name = "lua";
    l_readline = cast(l_readlineT, cast_func(dlsym(lib, "readline")));
    l_addhist = cast(l_addhistT, cast_func(dlsym(lib, "add_history")));
    if (l_readline == NULL)
      lua_warning(L, "unable to load 'readline'", 0);
  }
}

#else /* }{ */
/* no dlopen or LUA_READLINELIB undefined */

/* Leave pointers with NULL */
#define lua_initreadline(L) ((void)L)

#endif /* } */

#endif /* } */

#endif /* } */

/*
** Return the string to be used as a prompt by the interpreter. Leave
** the string (or nil, if using the default value) on the stack, to keep
** it anchored.
*/
static const char *get_prompt(lua_State *L, int firstline) {
  if (lua_getglobal(L, firstline ? "_PROMPT" : "_PROMPT2") == LUA_TNIL)
    return (firstline ? LUA_PROMPT : LUA_PROMPT2); /* use the default */
  else { /* apply 'tostring' over the value */
    const char *p = luaL_tolstring(L, -1, NULL);
    lua_remove(L, -2); /* remove original value */
    return p;
  }
}

/* mark in error messages for incomplete statements */
#define EOFMARK "<eof>"
#define marklen (sizeof(EOFMARK) / sizeof(char) - 1)

/*
** Check whether 'status' signals a syntax error and the error
** message at the top of the stack ends with the above mark for
** incomplete statements.
*/
static int incomplete(lua_State *L, int status) {
  if (status == LUA_ERRSYNTAX) {
    size_t lmsg;
    const char *msg = lua_tolstring(L, -1, &lmsg);
    if (lmsg >= marklen && strcmp(msg + lmsg - marklen, EOFMARK) == 0)
      return 1;
  }
  return 0; /* else... */
}

/*
** Prompt the user, read a line, and push it into the Lua stack.
*/
static int pushline(lua_State *L, int firstline) {
  char buffer[LUA_MAXINPUT];
  size_t l;
  const char *prmt = get_prompt(L, firstline);
  char *b = lua_readline(buffer, prmt);
  lua_pop(L, 1); /* remove prompt */
  if (b == NULL)
    return 0; /* no input */
  l = strlen(b);
  if (l > 0 && b[l - 1] == '\n') /* line ends with newline? */
    b[--l] = '\0';               /* remove it */
  lua_pushlstring(L, b, l);
  lua_freeline(b);
  return 1;
}

/*
** Try to compile line on the stack as 'return <line>;'; on return, stack
** has either compiled chunk or original line (if compilation failed).
*/
static int addreturn(lua_State *L) {
  const char *line = lua_tostring(L, -1); /* original line */
  const char *retline = lua_pushfstring(L, "return %s;", line);
  int status = luaL_loadbuffer(L, retline, strlen(retline), "=stdin");
  if (status == LUA_OK)
    lua_remove(L, -2); /* remove modified line */
  else
    lua_pop(L, 2); /* pop result from 'luaL_loadbuffer' and modified line */
  return status;
}

static void checklocal(const char *line) {
  static const size_t szloc = sizeof("local") - 1;
  static const char space[] = " \t";
  line += strspn(line, space);                  /* skip spaces */
  if (strncmp(line, "local", szloc) == 0 &&     /* "local"? */
      strchr(space, *(line + szloc)) != NULL) { /* followed by a space? */
    lua_writestringerror(
        "%s\n",
        "warning: locals do not survive across lines in interactive mode");
  }
}

/*
** Read multiple lines until a complete Lua statement or an error not
** for an incomplete statement. Start with first line already read in
** the stack.
*/
static int multiline(lua_State *L) {
  size_t len;
  const char *line = lua_tolstring(L, 1, &len); /* get first line */
  checklocal(line);
  for (;;) { /* repeat until gets a complete statement */
    int status = luaL_loadbuffer(L, line, len, "=stdin"); /* try it */
    if (!incomplete(L, status) || !pushline(L, 0))
      return status;   /* should not or cannot try to add continuation line */
    lua_remove(L, -2); /* remove error message (from incomplete line) */
    lua_pushliteral(L, "\n");         /* add newline... */
    lua_insert(L, -2);                /* ...between the two lines */
    lua_concat(L, 3);                 /* join them */
    line = lua_tolstring(L, 1, &len); /* get what is has */
  }
}

/*
** Read a line and try to load (compile) it first as an expression (by
** adding "return " in front of it) and second as a statement. Return
** the final status of load/call with the resulting function (if any)
** in the top of the stack.
*/
static int loadline(lua_State *L) {
  const char *line;
  int status;
  lua_settop(L, 0);
  if (!pushline(L, 1))
    return -1;                           /* no input */
  if ((status = addreturn(L)) != LUA_OK) /* 'return ...' did not work? */
    status = multiline(L); /* try as command, maybe with continuation lines */
  line = lua_tostring(L, 1);
  if (line[0] != '\0')  /* non empty? */
    lua_saveline(line); /* keep history */
  lua_remove(L, 1);     /* remove line from the stack */
  lua_assert(lua_gettop(L) == 1);
  return status;
}

/*
** Prints (calling the Lua 'print' function) any values on the stack
*/
static void l_print(lua_State *L) {
  int n = lua_gettop(L);
  if (n > 0) { /* any result to be printed? */
    luaL_checkstack(L, LUA_MINSTACK, "too many results to print");
    lua_getglobal(L, "print");
    lua_insert(L, 1);
    if (lua_pcall(L, n, 0, 0) != LUA_OK)
      l_message(progname, lua_pushfstring(L, "error calling 'print' (%s)",
                                          lua_tostring(L, -1)));
  }
}

/*
** Do the REPL: repeatedly read (load) a line, evaluate (call) it, and
** print any results.
*/
static void doREPL(lua_State *L) {
  int status;
  const char *oldprogname = progname;
  progname = NULL; /* no 'progname' on errors in interactive mode */
  lua_initreadline(L);
  while ((status = loadline(L)) != -1) {
    if (status == LUA_OK)
      status = docall(L, 0, LUA_MULTRET);
    if (status == LUA_OK)
      l_print(L);
    else
      report(L, status);
  }
  lua_settop(L, 0); /* clear stack */
  lua_writeline();
  progname = oldprogname;
}

/* }================================================================== */

#if !defined(luai_openlibs)
#define luai_openlibs(L) luaL_openselectedlibs(L, ~0, 0)
#endif

/*
** Main body of stand-alone interpreter (to be called in protected mode).
** Reads the options and handles them all.
*/
static int pmain(lua_State *L) {
  int argc = (int)lua_tointeger(L, 1);
  char **argv = (char **)lua_touserdata(L, 2);
  int script;

  /* Check for subcommand before standard argument processing.
  ** A subcommand is argv[1] that exactly matches a known command name
  ** and does not start with '-'. If argv[1] is not a subcommand,
  ** it falls through to the existing behavior (treated as a script). */
  if (argc >= 2 && argv[1] != NULL && argv[1][0] != '-'
      && g_bundle == NULL) {  /* skip subcommands for bundled executables */
    const Subcommand *cmd = find_subcommand(argv[1]);
    if (cmd != NULL) {
      /* Initialize libraries for the subcommand */
      luaL_checkversion(L);
      luai_openlibs(L);
      lua_gc(L, LUA_GCRESTART);
      lua_gc(L, LUA_GCGEN);
      /* Route to subcommand handler with shifted argv */
      int result = cmd->handler(L, argc - 1, argv + 1);
      lua_pushboolean(L, result);
      return 1;
    }
    /* Not a subcommand -- fall through to existing behavior */
  }

  int args = collectargs(argv, &script);
  int optlim = (script > 0) ? script : argc; /* first argv not an option */
  luaL_checkversion(L);        /* check that interpreter has correct version */
  if (args == has_error) {     /* bad arg? */
    print_usage(argv[script]); /* 'script' has index of bad arg. */
    return 0;
  }
  if (args & has_v) /* option '-v'? */
    print_version();
  if (args & has_E) {      /* option '-E'? */
    lua_pushboolean(L, 1); /* signal for libraries to ignore env. vars. */
    lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
  }
  luai_openlibs(L);                      /* open standard libraries */
  lus_onworker(L, worker_setup);         /* setup workers to get same libs */
  createargtable(L, argv, argc, script); /* create table 'arg' */
  lua_gc(L, LUA_GCRESTART);              /* start GC... */
  lua_gc(L, LUA_GCGEN);                  /* ...in generational mode */
  if (!(args & has_E)) {                 /* no option '-E'? */
    if (handle_luainit(L) != LUA_OK)     /* run LUA_INIT */
      return 0;                          /* error running LUA_INIT */
  }
  if (!runargs(L, argv, optlim)) /* execute arguments -e and -l */
    return 0;                    /* something failed */

  /* Handle --ast-graph option */
  if (astgraph_output != NULL && script > 0) {
    if (!handle_astgraph(L, argv[script], astgraph_output))
      return 0;
    lua_pushboolean(L, 1);
    return 1; /* done - don't run script */
  }

  /* Handle --ast-json option */
  if (astjson_output != NULL && script > 0) {
    if (!handle_astjson(L, argv[script], astjson_output))
      return 0;
    lua_pushboolean(L, 1);
    return 1; /* done - don't run script */
  }

  /* Handle --standalone option */
  if (standalone_entry != NULL) {
    if (!create_standalone(L))
      return 0;
    lua_pushboolean(L, 1);
    return 1; /* done - created standalone */
  }

  /* Handle bundle execution (if running from embedded bundle) */
  if (g_bundle != NULL) {
    size_t size;
    char *bytecode = lusB_getfile(g_bundle, g_bundle->entrypoint, &size);
    if (bytecode == NULL) {
      l_message(progname, "cannot find entrypoint in bundle");
      return 0;
    }
    /* Load bytecode */
    char chunkname[300];
    snprintf(chunkname, sizeof(chunkname), "=%s", g_bundle->entrypoint);
    int status = luaL_loadbuffer(L, bytecode, size, chunkname);
    free(bytecode);
    if (status != LUA_OK) {
      report(L, status);
      return 0;
    }
    /* Call entrypoint with script args */
    int n = pushargs(L);
    status = docall(L, n, LUA_MULTRET);
    if (status != LUA_OK)
      return 0;
    lua_pushboolean(L, 1);
    return 1;
  }

  if (script > 0) { /* execute main script (if there is one) */
    if (handle_script(L, argv + script) != LUA_OK)
      return 0; /* interrupt in case of error */
  }
  if (args & has_i) /* -i option? */
    doREPL(L);      /* do read-eval-print loop */
  else if (script < 1 && !(args & (has_e | has_v))) { /* no active option? */
    if (lua_stdin_is_tty()) { /* running in interactive mode? */
      print_version();
      doREPL(L); /* do read-eval-print loop */
    } else
      dofile(L, NULL); /* executes stdin as a file */
  }
  lua_pushboolean(L, 1); /* signal no errors */
  return 1;
}

int main(int argc, char **argv) {
  int status, result;
  lua_State *L;
  char **effective_argv = argv;
  int effective_argc = argc;
  char **synthetic_argv = NULL;

  /* Check for embedded bundle before anything else */
  if (lusB_detect()) {
    g_bundle = lusB_load();
    if (g_bundle == NULL) {
      l_message(argv[0], "cannot load embedded bundle");
      return EXIT_FAILURE;
    }
    /*
    ** Inject preserved args + "--" + entrypoint into argv
    ** Format: argv[0] + preserved_args + "--" + entrypoint + user_args
    ** This ensures:
    ** - preserved args are processed by runargs()
    ** - "--" stops option parsing
    ** - entrypoint becomes arg[0] (the "script name")
    ** - user args become arg[1], arg[2], etc.
    */
    effective_argc =
        argc + g_bundle->num_args + 2; /* +1 for "--", +1 for entrypoint */
    synthetic_argv = (char **)malloc((effective_argc + 1) * sizeof(char *));
    if (synthetic_argv == NULL) {
      l_message(argv[0], "cannot allocate argv");
      lusB_free(g_bundle);
      return EXIT_FAILURE;
    }
    synthetic_argv[0] = argv[0];
    for (int i = 0; i < g_bundle->num_args; i++) {
      synthetic_argv[1 + i] = g_bundle->args[i];
    }
    synthetic_argv[1 + g_bundle->num_args] = "--";
    synthetic_argv[2 + g_bundle->num_args] = argv[0];
    for (int i = 1; i < argc; i++) {
      synthetic_argv[g_bundle->num_args + 2 + i] = argv[i];
    }
    synthetic_argv[effective_argc] = NULL;
    effective_argv = synthetic_argv;
  }

  L = luaL_newstate(); /* create state */
  if (L == NULL) {
    l_message(argv[0], "cannot create state: not enough memory");
    free(synthetic_argv);
    if (g_bundle)
      lusB_free(g_bundle);
    return EXIT_FAILURE;
  }
  lua_gc(L, LUA_GCSTOP);              /* stop GC while building state */
  lua_pushcfunction(L, &pmain);       /* to call 'pmain' in protected mode */
  lua_pushinteger(L, effective_argc); /* 1st argument */
  lua_pushlightuserdata(L, effective_argv); /* 2nd argument */
  status = lua_pcall(L, 2, 1, 0);           /* do the call */
  result = lua_toboolean(L, -1);            /* get result */
  report(L, status);
  lua_close(L);
  free(synthetic_argv);
  if (g_bundle)
    lusB_free(g_bundle);
  return (result && status == LUA_OK) ? EXIT_SUCCESS : EXIT_FAILURE;
}
