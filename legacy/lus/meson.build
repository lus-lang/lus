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

# Embedded states use the configured installation prefix. The standalone
# interpreter replaces these defaults only when it runs from an archive bin
# directory.
configured_prefix = get_option('prefix').replace('\\', '/')
if not configured_prefix.endswith('/')
  configured_prefix += '/'
endif
lus_c_args += '-DLUS_INSTALL_PREFIX="' + configured_prefix + '"'

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

# Vendored SQLite amalgamation, compiled as a separate static dependency.
# THREADSAFE=2 matches the worker model because each connection is confined to
# one interpreter state.
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
  override_options: ['warning_level=0', 'optimization=3', 'b_lto=false'],
  install: true,
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
  'src/lauthpath.c',
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
  'src/lworkerlib.h',
  'src/lua.hpp',
  'vendor/sqlite/sqlite3.h',
)

license_install_dir = get_option('datadir') / 'licenses' / 'lus'
install_data('../../LICENSE.md',
  install_dir: license_install_dir,
  rename: 'LICENSE.md',
)
install_data('../../packaging/THIRD_PARTY_NOTICES.md',
  install_dir: license_install_dir,
  rename: 'THIRD_PARTY_NOTICES.md',
)
install_data(
  '../../packaging/licenses/LICENSE.BROTLI.txt',
  '../../packaging/licenses/LICENSE.CARES.txt',
  '../../packaging/licenses/LICENSE.JTS.txt',
  '../../packaging/licenses/LICENSE.LUA.txt',
  '../../packaging/licenses/LICENSE.LUALS.txt',
  '../../packaging/licenses/LICENSE.LZ4.txt',
  '../../packaging/licenses/LICENSE.OPENSSL.txt',
  '../../packaging/licenses/LICENSE.SQLITE.txt',
  '../../packaging/licenses/LICENSE.UNICODE.txt',
  '../../packaging/licenses/LICENSE.ZLIB.txt',
  '../../packaging/licenses/LICENSE.ZSTD.txt',
  install_dir: license_install_dir,
)

# Static library
liblus = static_library('lus',
  core_sources + lib_sources,
  c_args: lus_c_args,
  include_directories: sqlite_inc,
  dependencies: lus_deps,
  install: true,
)

# Lus interpreter
lus_exe = executable('lus',
  'src/lua.c',
  c_args: lus_c_args,
  link_args: lus_link_args,
  link_with: [liblus, libsqlite],
  dependencies: lus_deps,
  install: true,
)

# Lus compiler
lusc_exe = executable('lusc',
  'src/luac.c',
  c_args: lus_c_args,
  link_args: lus_link_args,
  link_with: [liblus, libsqlite],
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
  libraries_private: '-lsqlite3',
)

if system == 'windows'
  install_data('cmake/LusConfig.cmake',
    install_dir: get_option('libdir') / 'cmake' / 'Lus',
  )
endif

# H1 and H2 are registered from one checked-in manifest. The configure-time
# validator rejects missing files, duplicate entries, and critical omissions.
qualification_python = import('python').find_installation()
qualification_root = meson.project_source_root() / '..'
qualification_script = qualification_root / 'lus-tests/qualification.py'
qualification_env = environment()
if get_option('b_sanitize').contains('address')
  qualification_env.set('LUS_TEST_SANITIZER', 'address')
else
  qualification_env.set('LUS_TEST_SANITIZER', 'none')
endif
qualification_result = run_command(
  qualification_python,
  qualification_script,
  'meson-records',
  check: true,
)
qualification_records = qualification_result.stdout().strip().split('\n')

foreach record : qualification_records
  fields = record.split('|')
  kind = fields[0]
  test_id = fields[1]
  if kind == 'h1'
    test(test_id, qualification_python,
      args: [
        qualification_script,
        'run',
        '--id', test_id,
        '--program', lus_exe.full_path(),
      ],
      workdir: qualification_root,
      env: qualification_env,
      suite: fields[3].split(','),
      timeout: fields[2].to_int(),
    )
  elif kind == 'h2'
    h2_sources = [qualification_root / fields[3]]
    if fields[9] != ''
      foreach extra_source : fields[9].split(',')
        h2_sources += qualification_root / extra_source
      endforeach
    endif
    h2_includes = [include_directories('src')]
    if fields[6] == 'true'
      h2_includes += sqlite_inc
    endif
    if fields[7] == 'true'
      h2_includes += include_directories('wasm')
    endif
    h2_c_args = []
    if fields[8] == 'true'
      h2_c_args += lus_c_args
    endif
    h2_target = executable(fields[2], h2_sources,
      include_directories: h2_includes,
      c_args: h2_c_args,
      link_with: [liblus, libsqlite],
      dependencies: lus_deps,
    )
    test(test_id, qualification_python,
      args: [
        qualification_script,
        'run',
        '--id', test_id,
        '--program', h2_target.full_path(),
      ],
      workdir: qualification_root,
      env: qualification_env,
      suite: fields[5].split(','),
      timeout: fields[4].to_int(),
    )
  else
    error('unknown qualification record kind: ' + kind)
  endif
endforeach

test('qualification/manifest', qualification_python,
  args: [
    qualification_script,
    'validate',
    '--build-dir', meson.current_build_dir(),
  ],
  workdir: qualification_root,
  env: qualification_env,
  suite: ['h1', 'h2', 'qualification'],
  timeout: 30,
)

test('qualification/selftest', qualification_python,
  args: [
    qualification_script,
    'self-test',
    '--program', lus_exe.full_path(),
  ],
  workdir: qualification_root,
  env: qualification_env,
  suite: ['h1', 'h2', 'qualification'],
  timeout: 30,
)


# H3 system cases are independent so one failure cannot hide later cases.
h3_script = qualification_root / 'lus-tests/h3/qualification.py'
h3_result = run_command(
  qualification_python,
  h3_script,
  'meson-records',
  check: true,
)
h3_records = h3_result.stdout().strip().split('\n')

test('h3/manifest', qualification_python,
  args: [
    h3_script,
    'validate',
    '--build-dir', meson.current_build_dir(),
  ],
  workdir: qualification_root,
  suite: ['h3', 'h3-ci', 'h3-local', 'qualification'],
  timeout: 30,
)

test('h3/selftest', qualification_python,
  args: [h3_script, 'self-test', '--program', lus_exe.full_path()],
  workdir: qualification_root,
  suite: ['h3', 'h3-ci', 'h3-local', 'qualification'],
  timeout: 30,
)

test('release/qualification-selftest', qualification_python,
  args: [qualification_root / 'release/qualification.py', 'self-test'],
  workdir: qualification_root,
  suite: ['qualification', 'release'],
  timeout: 30,
)

foreach record : h3_records
  fields = record.split('|')
  test_id = fields[0]
  test(test_id, qualification_python,
    args: [
      h3_script,
      'run',
      '--mode', 'direct',
      '--id', test_id,
      '--program', lus_exe.full_path(),
    ],
    workdir: qualification_root,
    suite: ['h3', 'h3-ci', 'system-integration'],
    timeout: fields[3].to_int(),
  )
  if fields[5] == 'true'
    test('h3-local/' + test_id.split('/')[1], qualification_python,
      args: [
        h3_script,
        'run',
        '--mode', 'container',
        '--id', test_id,
        '--program', lus_exe.full_path(),
      ],
      workdir: qualification_root,
      suite: ['h3-local', 'system-integration'],
      timeout: fields[3].to_int(),
    )
  endif
endforeach

# H4: paired performance evidence
# Benchmarks are opt-in: run with `meson test --suite h4`.
h4_python = import('python').find_installation()
h4_root = meson.project_source_root() / '..'
h4_harness = h4_root / 'lus-tests/h4/harness.py'
h4_env = environment()
h4_env.set('PYTHONPYCACHEPREFIX', meson.current_build_dir() / 'h4-pycache')

test('h4/manifest', h4_python,
  args: [h4_harness, 'validate'],
  workdir: h4_root,
  suite: 'h4',
  env: h4_env,
  timeout: 30,
)

test('h4/statistics', h4_python,
  args: [h4_root / 'lus-tests/h4/test_harness.py'],
  workdir: h4_root,
  suite: 'h4',
  env: h4_env,
  timeout: 30,
)

# H4_BASELINE selects the 1.6.2 release binary. Exit 77 records a Meson skip
# with an explicit message when release comparison has not been prepared.
test('h4/release', h4_python,
  args: [h4_harness, 'release', '--candidate', lus_exe.full_path()],
  workdir: h4_root,
  suite: 'h4',
  env: h4_env,
  timeout: 3600,
)

test('h4/fastcall', h4_python,
  args: [h4_harness, 'fastcall', '--binary', lus_exe.full_path()],
  workdir: h4_root,
  suite: 'h4',
  env: h4_env,
  timeout: 1800,
)
