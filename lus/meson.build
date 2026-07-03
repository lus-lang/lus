project('lus', 'c',
  version: '1.7.0',
  default_options: [
    'c_std=gnu11',
    'warning_level=3',
    'optimization=2',
    'b_lto=true',
    'b_ndebug=if-release',
  ],
)

cc = meson.get_compiler('c')

# Math library (required)
m_dep = cc.find_library('m', required: false)

# Platform detection and configuration
system = host_machine.system()

lus_c_args = []
lus_link_args = []
lus_deps = [m_dep]

# Required dependencies for network library
openssl_dep = dependency('openssl', required: true)
cares_dep = dependency('libcares', required: true)
lus_deps += [openssl_dep, cares_dep]

if system == 'linux'
  lus_c_args += ['-DLUA_USE_LINUX', '-DLUS_PLATFORM_LINUX']
  lus_link_args += '-Wl,-E'
  dl_dep = cc.find_library('dl', required: false)
  lus_deps += dl_dep
elif system == 'darwin'
  lus_c_args += ['-DLUA_USE_MACOSX', '-DLUA_USE_READLINE', '-DLUS_PLATFORM_DARWIN']
  # ld resolves -lreadline to the SDK's libreadline.tbd, a stub for
  # system libedit. Linked by flag rather than find_library: no
  # libreadline.a or .dylib exists on disk (only the .tbd), so the
  # filesystem search find_library does under --prefer-static (or any
  # explicit static: kwarg) cannot see it.
  readline_dep = declare_dependency(link_args: '-lreadline')
  lus_deps += readline_dep
elif system == 'freebsd'
  lus_c_args += ['-DLUA_USE_LINUX', '-DLUA_USE_READLINE', '-DLUS_PLATFORM_FREEBSD']
  lus_link_args += '-Wl,-E'
  edit_dep = cc.find_library('edit', required: true)
  lus_deps += edit_dep
elif system == 'netbsd'
  lus_c_args += ['-DLUA_USE_LINUX', '-DLUA_USE_READLINE', '-DLUS_PLATFORM_NETBSD']
  lus_link_args += '-Wl,-E'
  edit_dep = cc.find_library('edit', required: true)
  lus_deps += edit_dep
elif system == 'openbsd'
  lus_c_args += ['-DLUA_USE_LINUX', '-DLUA_USE_READLINE', '-DLUS_PLATFORM_OPENBSD']
  lus_link_args += '-Wl,-E'
  edit_dep = cc.find_library('edit', required: true)
  lus_deps += edit_dep
elif system == 'sunos'
  lus_c_args += ['-DLUA_USE_POSIX', '-DLUA_USE_DLOPEN', '-D_REENTRANT', '-DLUS_PLATFORM_SUNOS']
  dl_dep = cc.find_library('dl', required: false)
  lus_deps += dl_dep
elif system == 'windows'
  lus_c_args += ['-DLUS_PLATFORM_WINDOWS', '-DLUA_USE_WINDOWS']
  if cc.get_argument_syntax() == 'msvc'
    # Same story as readline on macOS: under --prefer-static,
    # find_library's filesystem search cannot see SDK import
    # libraries. The linker resolves ws2_32.lib via %LIB% itself.
    ws2_dep = declare_dependency(link_args: 'ws2_32.lib')
  else
    ws2_dep = cc.find_library('ws2_32', required: true)
  endif
  lus_deps += ws2_dep
else
  # Generic POSIX fallback
  lus_c_args += ['-DLUA_USE_POSIX', '-DLUS_PLATFORM_POSIX']
endif

# Required dependencies for compression library
zlib_dep = dependency('zlib', required: true)
zstd_dep = dependency('libzstd', required: true)
brotlienc_dep = dependency('libbrotlienc', required: true)
brotlidec_dep = dependency('libbrotlidec', required: true)
lz4_dep = dependency('liblz4', required: true)
lus_deps += [zlib_dep, zstd_dep, brotlienc_dep, brotlidec_dep, lz4_dep]

# Threading library (for worker support)
thread_dep = dependency('threads', required: true)
lus_deps += thread_dep

# Vendored SQLite amalgamation, compiled into liblus. THREADSAFE=2 matches
# the worker model (each connection is confined to one interpreter state).
# TEMP_STORE=3 keeps statement journals and temp b-trees in memory so SQLite
# never writes to paths outside the pledge sweep. OMIT_LOAD_EXTENSION keeps
# the static musl link free of a dl requirement.
sqlite_args = [
  '-DSQLITE_THREADSAFE=2',
  '-DSQLITE_TEMP_STORE=3',
  '-DSQLITE_DQS=0',
  '-DSQLITE_OMIT_LOAD_EXTENSION',
  '-DSQLITE_OMIT_DEPRECATED',
  '-DSQLITE_OMIT_SHARED_CACHE',
  '-DSQLITE_OMIT_DECLTYPE',
  '-DSQLITE_OMIT_AUTOINIT',
  '-DSQLITE_DEFAULT_MEMSTATUS=0',
  '-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1',
  '-DSQLITE_LIKE_DOESNT_MATCH_BLOBS',
  '-DSQLITE_MAX_EXPR_DEPTH=0',
  '-DSQLITE_ENABLE_MATH_FUNCTIONS',
]
sqlite_inc = include_directories('vendor/sqlite')
libsqlite = static_library('sqlite3',
  'vendor/sqlite/sqlite3.c',
  c_args: sqlite_args,
  override_options: ['warning_level=0', 'optimization=s', 'b_lto=false'],
)
# Defines that alter the sqlite3.h API surface must be visible to the
# binding translation unit as well.
lus_c_args += [
  '-DSQLITE_OMIT_LOAD_EXTENSION',
  '-DSQLITE_OMIT_DEPRECATED',
  '-DSQLITE_OMIT_DECLTYPE',
  '-DSQLITE_OMIT_AUTOINIT',
]


# Core source files
core_sources = files(
  'src/lapi.c',
  'src/larena.c',
  'src/last.c',
  'src/lbundle.c',
  'src/lcode.c',
  'src/lctype.c',
  'src/ldebug.c',
  'src/ldo.c',
  'src/ldump.c',
  'src/lenum.c',
  'src/lfastcall.c',
  'src/lfunc.c',
  'src/lgc.c',
  'src/lglob.c',
  'src/llex.c',
  'src/lmem.c',
  'src/lobject.c',
  'src/lopcodes.c',
  'src/lpack.c',
  'src/lparser.c',
  'src/lpledge.c',
  'src/lquery.c',
  'src/lstate.c',
  'src/lstring.c',
  'src/ltable.c',
  'src/ltm.c',
  'src/lundump.c',
  'src/lvector.c',
  'src/lvm.c',
  'src/lzio.c',
)

# Library source files
lib_sources = files(
  'src/lauxlib.c',
  'src/lbaselib.c',
  'src/lcorolib.c',
  'src/ldblib.c',
  'src/lformat.c',
  'src/liolib.c',
  'src/lmathlib.c',
  'src/loadlib.c',
  'src/loslib.c',
  'src/lstrlib.c',
  'src/ltablib.c',
  'src/lutf8lib.c',
  'src/ljsonlib.c',
  'src/lcsvlib.c',
  'src/lfslib.c',
  'src/lnetlib.c',
  'src/lworkerlib.c',
  'src/lvectorlib.c',
  'src/larchivelib.c',
  'src/ltimelib.c',
  'src/lsqlitelib.c',
  'src/lquerylib.c',
  'src/ltzdata.c',
  'src/lwinzones.c',
  'src/linit.c',
)

# Headers to install
install_headers(
  'src/lua.h',
  'src/luaconf.h',
  'src/lualib.h',
  'src/lauxlib.h',
  'src/lua.hpp',
  'vendor/sqlite/sqlite3.h',
)

# Static library
liblus = static_library('lus',
  core_sources + lib_sources,
  c_args: lus_c_args,
  include_directories: sqlite_inc,
  dependencies: lus_deps,
  link_whole: libsqlite,
  install: true,
)

# Lus interpreter
lus_exe = executable('lus',
  'src/lua.c',
  c_args: lus_c_args,
  link_args: lus_link_args,
  link_with: liblus,
  dependencies: lus_deps,
  install: true,
)

# Lus compiler
lusc_exe = executable('lusc',
  'src/luac.c',
  c_args: lus_c_args,
  link_args: lus_link_args,
  link_with: liblus,
  dependencies: lus_deps,
  install: true,
)

# pkg-config file
pkg = import('pkgconfig')
fs = import('fs')
pkg.generate(liblus,
  name: 'lus',
  description: 'A small, productive programming language.',
  url: 'https://lus.dev/',
)

# H1: Language Integrity (Pure Lus)
h1_tests = [
  'h1/enum',
  'h1/errors',
  'h1/from',
  'h1/ifassign',
  'h1/whileassign',
  'h1/optchain',
  'h1/bitwise',
  'h1/math',
  'h1/strings',
  'h1/attrib',
  'h1/calls',
  'h1/catchstat',
  'h1/closure',
  'h1/constructs',
  'h1/coroutine',
  'h1/events',
  'h1/gc',
  'h1/goto',
  'h1/literals',
  'h1/locals',
  'h1/nextvar',
  'h1/pm',
  'h1/sort',
  'h1/tpack',
  'h1/transcode',
  'h1/utf8',
  'h1/vararg',
  'h1/db',
  'h1/big',
  'h1/bwcoercion',
  'h1/cstack',
  'h1/gengc',
  'h1/memerr',
  'h1/json',
  'h1/csv',
  'h1/dataproc',
  'h1/network',
  'h1/worker',
  'h1/global',
  'h1/parse',
  'h1/slices',
  'h1/groups',
  'h1/vectors',
  'h1/cloning',
  'h1/datetime',
  'h1/sqlite',
  'h1/sqlite_fs',
  'h1/archive',
  'h1/pledge',
  'h1/security',
  'h1/runtime-attrs',
  'h1/doexpr',
  'h1/interp',
  'h1/fastcall',
  'h1/traceback',
  'h1/userdata',
  'h1/varinfo',
  'h1/lsp-unit',
  'h1/lsp-integration',
  'h1/lsp-lint-h1',
  'h1/lsp-e2e',
  'h1/preinclude',
  'h1/flags',
  'h1/query_syntax',
  'h1/query',
]

foreach t : h1_tests
  # Network tests need more time due to external HTTP requests
  if t == 'h1/network'
    test('h1/' + fs.name(t), lus_exe,
      args: ['lus-tests' / t + '.lus'],
      workdir: meson.project_source_root() / '..',
      suite: 'h1',
      timeout: 120,
    )
  elif t == 'h1/flags'
    # Flags feature test: needs --flag/-F arguments on the command line
    test('h1/' + fs.name(t), lus_exe,
      args: ['-Fdebug', '-Fversion=1.5', '-Fcount=3', '-Fname=alpha',
             '--flag', 'empty=', 'lus-tests' / t + '.lus'],
      workdir: meson.project_source_root() / '..',
      suite: 'h1',
    )
  else
    test('h1/' + fs.name(t), lus_exe,
      args: ['lus-tests' / t + '.lus'],
      workdir: meson.project_source_root() / '..',
      suite: 'h1',
    )
  endif
endforeach

# H2: C API (Compiled Executables)
h2_stack = executable('test_stack', '../lus-tests/h2/test_stack.c',
  include_directories: include_directories('src'),
  link_with: liblus,
  dependencies: lus_deps,
)
test('h2/stack', h2_stack, suite: 'h2')

h2_call = executable('test_call', '../lus-tests/h2/test_call.c',
  include_directories: include_directories('src'),
  link_with: liblus,
  dependencies: lus_deps,
)
test('h2/call', h2_call, suite: 'h2')

h2_sqlite = executable('test_sqlite', '../lus-tests/h2/test_sqlite.c',
  include_directories: [include_directories('src'), sqlite_inc],
  link_with: liblus,
  dependencies: lus_deps,
)
test('h2/sqlite', h2_sqlite, suite: 'h2')


# H3: System Integration (Container Wrapper)
# Runs the Lus runner script
test('h3/io', lus_exe,
  args : ['lus-tests/h3/runner_local.lus'],
  workdir : meson.project_source_root() / '..',
  suite : ['h3', 'h3-local'])

# h3/ci runs directly on the host (CI environments only)
test('h3/ci', lus_exe,
  args : ['lus-tests/h3/runner_direct.lus'],
  workdir : meson.project_source_root() / '..',
  suite : ['h3-ci'],
  timeout: 60,
)

# H4: Performance (Lus Runner)
# Benchmarks are opt-in: run with `meson test --suite h4`
test('h4/bench', lus_exe,
  args: ['lus-tests/h4/runner.lus'],
  workdir: meson.project_source_root() / '..',
  suite: 'h4',
  env: ['BUILD_TYPE=Unstable'], # Default to Unstable for local tests
)

test('h4/fastcall', lus_exe,
  args: ['lus-tests/h4/runner_fastcall.lus'],
  workdir: meson.project_source_root() / '..',
  suite: 'h4',
  timeout: 600,
)

test('h4/micro', lus_exe,
  args: ['lus-tests/h4/runner_micro.lus'],
  workdir: meson.project_source_root() / '..',
  suite: 'h4',
  env: ['BUILD_TYPE=Unstable'],
  timeout: 600,
)


