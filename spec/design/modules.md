# Versions, require trees, and remote modules

This note records three parts of the `lus` binary that work together: the version manager, the index of a program's require tree, and remote modules loaded from a URL. Each part is a contract. Sections 1, 4, and 5 define formats and behavior that every Lus release from 2.0 on implements identically, so a script, a server, or an older `lus` can depend on them forever. Sections 2 and 3 define the behavior that a program observes, which is also fixed. They also define the optimizations that the runtime may apply without changing that behavior.

The normative copies of the frozen contracts are `spec/tools/version.md` and `spec/tools/atmosphere.md`. This note gives the reasons behind them.

## 1. Version management

The `lus` binary installs, lists, selects, and removes other releases of Lus. A user who works on programs written for different releases keeps every release they need in one directory and runs any of them by version. Selection is per user and per command. A program that needs a particular release says so with `lus +VERSION`, in its shebang line, its build script, or its continuous integration configuration.

We built the manager into `lus` because a separate tool would have to be installed, updated, and trusted on its own. The cost is that every release must carry the manager and implement it identically, since the user may run `lus version` from any release they have. Therefore the commands, the output for scripts, the exit statuses, the directory layout, and the release index are frozen from 2.0. A later release may add a subcommand, an option, or a JSON field. It never removes or changes one.

### Version names

A _version_ is a release number of the form `MAJOR.MINOR.PATCH`, optionally followed by `-` and a prerelease label, such as `2.0.3` or `2.1.0-unstable.7`. Versions order as Semantic Versioning 2.0.0 orders them.

A _version request_ selects a version. It has one of these forms.

- `2.0.3` selects exactly that version.
- `2.0` selects the highest version `2.0.x` that has no prerelease label.
- `2` selects the highest version `2.x.y` that has no prerelease label.
- `stable` selects the newest release of the stable channel.
- `unstable` selects the newest release of the unstable channel.

A _channel_ is a named stream of releases. The `stable` channel holds the releases tagged `vMAJOR.MINOR.PATCH`. The `unstable` channel holds builds of the development branch, whose versions carry the label `unstable.N`, where `N` counts up. Lus 2.0 has exactly these two channels.

Commands that install resolve a request against the release index. Commands that select resolve it against the installed versions. For `stable` and `unstable`, an installed version belongs to the channel it was installed from, which the manager records.

### Commands

The manager is the `version` command of `lus`. Every subcommand accepts `--json`, which replaces the human output on standard output with one JSON object followed by a newline.

| Command | Effect |
| --- | --- |
| `lus version` | Print the version of the running binary, as `lus -v` does. |
| `lus version list` | List the installed versions. |
| `lus version list --remote [CHANNEL]` | List the versions in the release index, by default those of `stable`. |
| `lus version install REQUEST` | Download, verify, and install the version that `REQUEST` selects. |
| `lus version use REQUEST` | Make an installed version the default. |
| `lus version remove VERSION` | Delete an installed version. `VERSION` must be exact. |
| `lus version which [REQUEST]` | Print the path of the executable of an installed version, by default the default version. |

`lus +REQUEST ARGS...` runs the installed version that `REQUEST` selects with `ARGS`. The `+` form is recognized only as the first argument, so `lus +2.0 test` runs `lus test` under 2.0 and `lus test +2.0` passes `+2.0` to the test runner. On POSIX systems the running process replaces itself with the selected executable, so the exit status, signals, and standard streams are those of the selected release. On Windows the running process starts the selected executable, waits for it, and exits with its status. `lus +REQUEST` never downloads. A request that selects no installed version prints the command that installs it and exits with status 3.

The human output of `which` is the path alone on one line, so `$(lus version which 2.0)` works in a shell. The human output of the other subcommands is for people and may change between releases. Scripts use `--json`.

### JSON output

Every JSON object has the field `"schema": 1`. A failure under `--json` prints an object with an `error` field and exits with the status that the table below gives.

```json
{"schema": 1, "default": "2.0.3", "versions": [
  {"version": "2.0.3", "channel": "stable", "default": true, "path": "/home/ana/.lus/versions/2.0.3/bin/lus"},
  {"version": "2.1.0-unstable.7", "channel": "unstable", "default": false, "path": "/home/ana/.lus/versions/2.1.0-unstable.7/bin/lus"}
]}
```

The object above is the output of `list`. The other subcommands print the objects below, in order: `list --remote`, `install`, `use`, `remove`, `which`, and a failure.

```json
{"schema": 1, "channel": "stable", "versions": [{"version": "2.0.3", "published": "2027-02-01T12:00:00Z", "installed": true}]}
{"schema": 1, "version": "2.0.3", "path": "/home/ana/.lus/versions/2.0.3/bin/lus", "already": false}
{"schema": 1, "version": "2.0.3", "path": "/home/ana/.lus/bin/lus", "previous": "2.0.2"}
{"schema": 1, "version": "2.0.2", "removed": true}
{"schema": 1, "version": "2.0.3", "path": "/home/ana/.lus/versions/2.0.3/bin/lus"}
{"schema": 1, "error": {"code": "not-installed", "message": "lus 2.1 is not installed"}}
```

`previous` is `null` when no default was set. `already` is `true` when the version was installed before the command ran, which is a success.

### Exit statuses

| Status | Code in JSON | Meaning |
| --- | --- | --- |
| 0 | | Success. |
| 1 | `network`, `io` | The download or a file operation failed. |
| 2 | `usage` | The arguments are malformed, including a malformed version request. |
| 3 | `not-installed`, `not-found` | No installed version matches (`not-installed`), or no release in the index matches (`not-found`). |
| 4 | `verify` | A digest or a signature did not verify. Nothing was installed. |
| 5 | `in-use` | `remove` named the default version. |

The `lus +REQUEST` form uses statuses 2 and 3 for its own failures and otherwise exits with the status of the selected release.

### Directory layout

The manager keeps everything in one per-user directory, the _Lus home_. It is the value of the environment variable `LUS_HOME` when that is set. Otherwise it is `~/.lus` on POSIX systems and `%LOCALAPPDATA%\lus` on Windows. The same directory holds the module cache of section 4, so deleting it resets Lus to its installed state.

```
$LUS_HOME/
  bin/lus                     the default version (a symbolic link, a hard link on Windows)
  default                     one line: the exact default version
  versions/2.0.3/             the release archive, unpacked as published
    bin/lus
    channel                   one line: the channel it was installed from
  versions/2.1.0-unstable.7/
  index/seen                  the newest release index accepted so far
  cache/                      the module cache (section 4)
  lock                        held while a command changes the directory
```

The user adds `$LUS_HOME/bin` to `PATH` once. `use` replaces `bin/lus` with an atomic rename. When `lus` on `PATH` resolves to another file, `use` and `which` print a warning that names that file. `install` unpacks into a temporary directory under `versions/` and renames it into place, so an interrupted install leaves no partial version. A command that changes the directory holds an exclusive lock on `lock` for its duration, so two installs never interleave.

### Release index

The manager learns about releases from the _release index_, a signed JSON document at `https://lus.dev/releases/index.json`. The environment variable `LUS_RELEASE_URL` replaces `https://lus.dev/releases/` for mirrors and tests. The index is a signed envelope (section 5). Its payload has this shape.

```json
{
  "schema": 1,
  "generated": "2027-02-01T12:00:00Z",
  "channels": {"stable": "2.0.3", "unstable": "2.1.0-unstable.7"},
  "releases": [
    {
      "version": "2.0.3",
      "channel": "stable",
      "published": "2027-02-01T12:00:00Z",
      "assets": {
        "aarch64-macos": {"url": "https://github.com/.../lus-v2.0.3-aarch64-macos.tar.gz", "sha256": "9f2c...", "size": 4194304}
      }
    }
  ]
}
```

The targets are named `aarch64-macos`, `x86_64-macos`, `aarch64-linux-musl`, `x86_64-linux-musl`, and `x86_64-windows`, which are the names of the release archives in `packaging/install`. A later release may add targets.

`install` verifies in three steps. It installs nothing unless all three pass.

1. The envelope of the index must carry a valid Ed25519 signature by a key that the running binary trusts. Each binary embeds the public keys of the Lus release process.
2. The `generated` time of the index must not be older than the one in `index/seen`. This rejects an attacker who replays an old index to keep a user on a release with a known flaw. After the check, the manager records the new time.
3. The SHA-256 digest of the downloaded archive must equal the `sha256` of its asset. Its length must equal `size`.

Each release signs with every key that it has not retired, so a binary that trusts only an older key still accepts a newer index. Key rotation therefore never strands an installed release.

The release workflow publishes the index and its signature with every release of either channel. It also adds the unstable channel, which publishes a build of the development branch. Both are changes to `.github/workflows/release.yml` and `packaging/release`.

## 2. Require trees

When `lus` starts a program, and when `lus build` bundles one, it first indexes the program's _require tree_: the main chunk, every module that a literal `require` in it names, and so on recursively. A _literal require_ is a call of the global `require` whose single argument is a string constant, written `require("name")` or `require "name"`. The index finds them in the syntax tree, so a call of a local or a field named `require` is not one.

The index does three things.

- It fetches every remote module in the tree before the program runs (section 3), so a program pays the network latency once, up front, in parallel.
- It compiles every module in the tree once per process. Every state of the process, including workers, loads the compiled module from memory. Remote modules also keep their compiled form on disk (section 4).
- It gives `lus build` the set of modules to bundle and tells it which modules no code can reach.

### What the index may not change

A program observes the same behavior with the index as without it, except for timing and the warning of section 3. This rule fixes four properties.

1. **Module bodies run when `require` runs.** The index reads and compiles files ahead of time. It never runs a module early, so the side effects of a module happen in the same order as before.
2. **Errors happen at the `require`.** A module of the tree that fails to compile or to download raises its error when a `require` of it runs. A module that the program never requires never raises an error, even when it is broken.
3. **Resolution follows `package.path` at the time of the `require`.** The index resolves names with the starting value of `package.path`, but each entry records the file it read and the file's length and modification time. A `require` resolves its name as it always does. It uses the compiled entry only when it reaches the same file unchanged. A program that changes `package.path` first therefore still loads what it asked for.
4. **Permissions are checked at the `require`.** The index reads files under the authority of the runtime, as `--include` does. Each `require` still checks `load` and `fs:read` for a file, or `load` and `network:http` for a URL. A module in the index that the program lacks permission to load fails exactly as it would without the index.

The index skips any read or fetch that the command line forbids. When `-P` limits a program, the index fetches only from hosts and reads only files that the limit could ever allow. A program started with `-P` and no network permission therefore makes no network request at startup.

### Dynamic requires

A _dynamic require_ is a load whose module the index cannot name. These forms are dynamic.

- A call of `require` with any argument other than one string constant, such as `require(name)` or ``require(`plugins.{kind}`)``.
- Any use of the global `require` other than as the function of a call, such as `local r = require` or `pcall(require, name)`.
- A call of `load`, `loadfile`, or `dofile`, because the chunk it runs may require anything.
- A read of a global through a computed key, such as `_G[k]`, `_ENV[k]`, or `rawget(_G, k)`, because the key may be `"require"`.

The index records whether the tree contains a dynamic require. At run time a dynamic require works as `require` always has. Its module is resolved, read, fetched, and compiled at the moment it runs, which for a remote module prints the warning of section 3.

### Tree shaking in `lus build`

`lus build` bundles the modules of the tree. It also bundles the modules named with `--include`. An `--include` of a single file is a root that the user asked for, so the bundle always keeps it. An `--include` of a directory names candidates. If the tree contains no dynamic require, `lus build` drops each candidate that no literal require reaches and lists what it dropped. If the tree contains a dynamic require, it keeps every candidate, because any of them may be loaded by name.

### Which whole-program optimizations are sound

A module is a table, and tables are mutable. Any code that holds the module's table may add, replace, or remove its fields at any time, through an assignment, `rawset`, the `debug` library, or a loaded chunk. Any code may pass the table on, iterate it with `pairs`, or encode it. This decides which optimizations the runtime may apply across modules.

These optimizations are sound and the runtime applies them.

- Dropping a module that no load can reach. Reachability is a property of the source, so it holds for every run, provided the tree contains no dynamic require.
- Reading, fetching, and compiling a module before the program runs. These steps have no effects that a program can observe, by the four properties above.
- Compiling a module once per process and sharing the compiled form between states. A compiled function holds no state, and every state runs the module body itself.

These optimizations are unsound in general, so the runtime does not apply them statically.

- Removing a field of a module table that no importer names. An importer may read the field with a computed key or iterate the table.
- Replacing `M.VERSION` or a call of `M.f` in an importer with its value or its body. Another module may assign a new value first.
- Running a module body early, or skipping a body whose result goes unused. The body may have side effects.

The optimizing JIT reaches the same speed as inlining across modules without the unsoundness. It predicts the function stored in `M.f` from what it observed, inlines it behind a guard on the table's shape, and leaves the optimized code when the guard fails (`opt.md`). A module whose table is readonly gives the JIT a guard that never fails.

## 3. Remote modules

A _remote module_ is a module named by a URL. `require` loads it from the network, the first time, and from the cache afterwards.

```lus nocheck
pledge("load", "network:http=atmosp.here")

local schema = require("https://atmosp.here/2.0/jsonschema.lus")
```

A remote module name is an absolute `https` URL whose path ends in `.lus` and which has no query and no fragment. An `http` URL is accepted only for a loopback host (`127.0.0.1`, `::1`, or `localhost`), so a test or a local mirror needs no certificate. Any other URL raises an error at the `require`. `require` normalizes the URL before it uses it as the key of `package.loaded`: the scheme and the host become lowercase, a default port is removed, and `.` and `..` segments of the path are resolved. Two spellings of one URL therefore load one module.

Two kinds of servers provide remote modules.

- An _atmosphere server_ speaks the protocol of section 5. It serves a signed manifest and a compressed bundle that holds the package's modules. `https://atmosp.here` is the official one, and anyone may run another.
- A _generic server_ is any other web server. `require` downloads the file at the URL and runs it as a Lus source.

`require` tells the two apart by content negotiation on the module URL, as section 5 describes, so one request decides. A host that answered once as an atmosphere server is recorded in the cache. A later response from that host that is not an atmosphere manifest is an error, which stops an attacker who controls the network path from downgrading a signed package to an unsigned file. `atmosp.here` is recorded in every binary.

### Requires inside a remote module

A remote module resolves the names it requires relative to itself. `require` finds the module that calls it from the chunk of the calling function, so a function defined in a remote module resolves relative to that module wherever it is called from.

A name that is a URL loads that URL. A name of the standard library, or a name already in `package.loaded` or `package.preload`, loads as usual. Any other name `a.b` resolves as follows.

- In a module of an atmosphere bundle, `a.b` is the file `a/b.lus` or `a/b/init.lus` at the root of the bundle. Its key in `package.loaded` is the URL of the package followed by `#a.b`, such as `https://atmosp.here/2.0/jsonschema.lus#jsonschema.draft7`.
- In a module from a generic server, `a.b` is the URL `a/b.lus` relative to the directory of the module's URL, then `a/b/init.lus`. Its key is that URL.

A remote module never loads a file from the local filesystem by name. A module from the network that could read local modules would run code that its author never saw.

### When fetching happens

The index of section 2 finds every literal require of a URL, including the literal requires inside remote modules once they arrive, and the remote dependencies that atmosphere manifests list. It fetches all of them before the main chunk runs, in parallel, and compiles them once.

A remote module that the index did not fetch, because a dynamic require names it, is fetched when its `require` runs. The fetch works, but it stops the program for a network round trip. `lus` prints one warning per module to standard error, such as the one below, so a developer sees what slows the run.

```
lus: warning: main.lus:12: fetched https://atmosp.here/2.0/csvx.lus during execution. A literal require lets lus fetch it before the program starts.
```

A fetch inside a detached coroutine waits through the scheduler, so the other coroutines keep running.

Three options of `lus` control fetching. `--offline` never contacts the network and loads remote modules only from the cache. `--reload` revalidates every remote module of the tree with its server before the program runs. `--no-prefetch` turns off fetching before the run, so every remote module is fetched at its `require`, which is useful to see which code paths load which modules.

`lus build` fetches every remote module of the tree and bundles it with its manifest. The executable never contacts the network to load a module.

### Permissions

Every `require` of a remote module needs the `load` permission and the `network:http` permission for the module's URL, checked as `network.fetch` checks its URL. This holds when the module was prefetched or cached, because the permission controls which code the program may load. A module inside a bundle needs the same permissions as the package that contains it. A bundle download must use the host of the module URL, and redirects are followed only within that host, so the permission the program pledged covers every request.

A package runs with the permissions of the program that loads it. A package declares the permissions its functions use in its header (section 6), so the author of a program knows what to pledge. A package never calls `pledge` to acquire a permission. It may restrict the permissions of a coroutine that it creates.

The guide's best practices change accordingly. Only the main program pledges restrictions or seals. It loads its dependencies first, then rejects what it no longer needs and seals.

```lus nocheck
pledge("load", "network:http=atmosp.here", "fs:read=./data/*")

local schema = require("https://atmosp.here/2.0/jsonschema.lus")
local csvx = require("https://atmosp.here/2.0/csvx.lus")

pledge("~load", "~network", "seal")
```

## 4. The module cache

The module cache is `$LUS_HOME/cache`, with the Lus home of section 1. It holds what the runtime downloaded and compiled. Deleting it at any time is safe, because the next run downloads again.

```
cache/
  hosts/<host>.json             atmosphere or generic, the pinned registry keys
  modules/<url-hash>/
    url                         the normalized module URL
    record.json                 the resolution: version, bundle digest, fetched, expires, ETag, author key
    source.lus                  the file, for a generic server
  bundles/<sha256>/             an unpacked bundle, shared by every URL that resolves to it
    manifest.json               the signed manifest envelope
    files/...                   the modules of the package
  compiled/<build-id>/<sha256>  compiled chunks, keyed by the digest of the source
```

`<url-hash>` is the first 32 hexadecimal digits of the SHA-256 digest of the normalized URL. Hashing keeps file names valid on every filesystem, including case-insensitive ones. `<build-id>` names the runtime build, so two releases never load each other's compiled chunks.

A resolution record is _fresh_ until its `expires` time. A fresh record is used without contacting the network. A stale record is revalidated with a conditional request that sends the stored ETag. A `304 Not Modified` response renews it. If the server cannot be reached, `require` uses the stale record and prints a warning, so a program keeps working offline with the modules it last had. A module that was never fetched raises an error when the network is unavailable.

The `expires` time comes from the server, through the `ttl` of the manifest or the `Cache-Control` header for a generic server. The client limits it to seven days and uses one day when the server gives none.

## 5. The atmosphere protocol

This section is the client side of the protocol between `lus` and an atmosphere server. The server implements it in the atmosphere project. Version 1 of the protocol is frozen with Lus 2.0.

### URLs

An atmosphere module URL has the form `https://HOST/LINE/NAME.lus`. `LINE` is the Lus release line the package is published for, such as `2.0`, or `unstable`. `NAME` is the package name. A URL names one compatibility line of one package: the server serves only patch releases of the package under one URL, so a program that uses the URL keeps working without a lockfile. A change that breaks compatibility is published under another URL.

The client treats the path as opaque, except that it enforces the patch rule itself. It records the version of the first manifest it accepts for a URL. It accepts a later manifest only if its version has the same `MAJOR.MINOR`. A violation is an error that names both versions.

### Detection and the manifest

The client requests the module URL with the header `Accept: application/vnd.lus.atmosphere+json;v=1, text/plain;q=0.1`. An atmosphere server answers with the content type `application/vnd.lus.atmosphere+json;v=1` and a signed manifest envelope. Any other content type marks a generic server, whose body is the source of the module. An atmosphere server must send `Vary: Accept`, so a cache in between keeps the two answers apart. A browser that opens the URL therefore receives the source of the main module.

A _signed envelope_ is the format that both the release index and atmosphere manifests use. It carries the exact bytes that were signed, so no canonical form of JSON is needed.

```json
{
  "payload": "<base64 of the payload bytes>",
  "signatures": [{"key": "<hex Ed25519 public key>", "sig": "<hex Ed25519 signature of the payload bytes>"}]
}
```

An envelope is valid if at least one signature verifies under a key the client trusts. For `atmosp.here`, the binary embeds the registry keys. For any other host, the client pins the keys of the first valid envelope it receives in `hosts/<host>.json` and refuses an envelope signed only by other keys afterwards. The error names the file to delete to accept the new key.

The payload of a manifest is JSON with this shape.

```json
{
  "atmosphere": 1,
  "url": "https://atmosp.here/2.0/jsonschema.lus",
  "name": "jsonschema",
  "version": "1.4.2",
  "lus": "2.0",
  "channel": "stable",
  "main": "jsonschema.lus",
  "ttl": 86400,
  "bundle": {"url": "/bundles/jsonschema-1.4.2.tar.zst", "sha256": "3be1...", "size": 18213},
  "requires": ["https://atmosp.here/2.0/uri.lus"],
  "permissions": ["network:http"],
  "flags": ["strict"],
  "author": {"key": "<hex Ed25519 public key>", "sig": "<hex signature>"}
}
```

- `url` must equal the normalized URL the client requested.
- `lus` is the oldest Lus release line the package supports, as `MAJOR.MINOR`.
- `channel` is `stable` or `unstable`. It is `unstable` exactly when `LINE` is.
- `main` is the path of the main module inside the bundle.
- `bundle.url` is absolute or relative to the module URL. Its host must equal the module's host.
- `requires` lists the remote modules that literal requires in the package name, so the client prefetches them without unpacking first.
- `permissions` and `flags` copy the package header (section 6).
- `author.sig` signs the bytes of the line `atmosphere-bundle 1 URL VERSION SHA256`, with single spaces, where `SHA256` is the hexadecimal digest of the bundle.

### Checks

The client loads an atmosphere package only after every check below passes. A failed check raises an error at the `require` and leaves the cache as it was.

1. The envelope is valid under a trusted registry key.
2. `url` matches, and `channel` agrees with the URL.
3. The Lus version check: the major version in `lus` equals the major version of the running release. Its minor version is at most the minor version of the running release. A package for `2.1` fails on Lus 2.0 with the message `https://atmosp.here/2.1/x.lus needs Lus 2.1, this is Lus 2.0.3`.
4. The patch rule of the URL holds.
5. The bundle's length and SHA-256 digest match `bundle`.
6. The author check, for the `stable` channel. `author.sig` verifies under `author.key`. The client pins the author key of a URL on first use. A later manifest must use the pinned key unless the manifest also carries `author.rotation`, a signature by the pinned key of the line `atmosphere-rotate 1 URL NEWKEY`. Manifests of the `unstable` channel skip this check, so unreviewed builds can be published without an author key. The registry signature still applies to them.

### The bundle

A bundle is a tar archive in the POSIX ustar format, compressed with Zstandard. It holds the files of the package with paths relative to the package root. The client accepts only regular files and directories. It rejects an archive with a link, a device, an absolute path, a `..` segment, a path with a character outside `A-Z a-z 0-9 . _ - /`, more than 10000 entries, or more than 64 MiB unpacked. The client unpacks into a temporary directory and renames it into `bundles/<sha256>/` once complete, so a bundle in the cache is always whole.

### Searching

An atmosphere server also answers `GET https://HOST/api/1/search?q=PREFIX&line=LINE` with a JSON array of results, each with `url`, `name`, `version`, and `description`. The runtime never calls it. The `atmos` CLI and the language server use it for completion.

## 6. Package metadata

A _package_ is a set of modules with one main module. The main module starts with a doc comment that holds the `@package` annotation. This _package header_ describes the package. `lus doc` reads it, the atmosphere server copies it into the manifest, and the language server shows it.

```lus nocheck
--- Validates JSON values against JSON Schema documents.
---
--- @package jsonschema
--- @version 1.4.2
--- @lus 2.0
--- @license MIT
--- @flag strict Reject keywords that the draft does not define.
--- @permission network:http Fetches documents that a `$ref` names by URL.
--- @permission fs:read Reads documents that a `$ref` names by path.

local M = {}
```

The text before the first annotation is the description, in Markdown. The annotations are the following.

- `@package NAME` names the package. A name has at most 64 characters from `a-z`, `0-9`, and `-`, and starts with a letter. Required.
- `@version VERSION` is the version of the package, in the version format of section 1. Required.
- `@lus LINE` is the oldest Lus release line the package supports, as `MAJOR.MINOR`. Required.
- `@license EXPR` is an SPDX license expression. Required.
- `@flag NAME DESCRIPTION` documents a compile flag (`-F`) that the package reads from `flags`. One annotation per flag.
- `@permission NAME DESCRIPTION` documents a permission that functions of the package use, with the most precise value the package knows. One annotation per permission.
- `@homepage URL` and `@repository URL` link to the project. Optional.

A blank line separates the header from the first declaration, so the header documents the module and not that declaration. `lus doc` adds a `package` object with these fields to its JSON model and to the frontmatter of its Markdown output. `lus check` reports a header that lacks a required annotation, and a top-level call of `pledge` in a module that has a header, which would acquire permissions on behalf of the program.

## 7. The language server

Inside the string of a `require`, the language server completes atmosphere URLs when the `atmos` command is on `PATH`. It runs `atmos search --json --server SERVER PREFIX` for `https://atmosp.here` and for every server in the setting `lus.atmosphere.servers`, a list of base URLs of custom atmosphere servers. URL completion needs `atmos`. Hover over a remote require shows the package header from the cached manifest. A permission that the header declares and the program never pledges is reported as a diagnostic.

## 8. WebAssembly

The WebAssembly build has no network library. `require` of a URL raises `remote modules are unavailable in this build`. The index of section 2 indexes local modules only. A host that wants remote modules fetches them itself and adds them to `package.preload`. `lus version` is unavailable there, because the build cannot start another process.

## 9. Tests

The contracts of sections 1 and 5 are pinned by tool tests that run real `lus` processes.

- `tests/version` serves a release index and archives from a loopback HTTP server, with an index signed by a test key. It checks every subcommand in human and JSON form, every exit status, the directory layout, the rejection of a tampered archive, of a bad signature, and of a replayed index, and `lus +VERSION`. A loopback `LUS_RELEASE_URL` may name its own trusted key through `LUS_RELEASE_KEY`. A non-loopback URL ignores that variable.
- `tests/remote` serves an atmosphere server and a generic server on loopback. It checks detection, every manifest check of section 5, the bundle limits, the cache layout, freshness and revalidation, `--offline`, the warning for a fetch during execution, the permission errors, and relative requires.
- Conformance tests cover the index rules of section 2 that a program observes: a broken module that is never required, a `package.path` change before a `require`, and the order of module bodies.
- `lus build` tests cover tree shaking with and without a dynamic require, and bundling a remote module.
