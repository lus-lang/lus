# Atmosphere

Atmosphere is the package registry of Lus 2.0, served at `atmosp.here`. A program loads a package by its URL, as in `require("https://atmosp.here/2.0/dates.lus")`. The runtime downloads the package, verifies it, and caches it. Authors publish by pushing to a git repository on `git.atmosp.here`. `atmos` is the command line tool for authors. It wraps git and the registry API. Nothing requires it, because a package can be published, installed, and used with git, `lus`, and an account alone.

This note is the server half of the design. The runtime half, which covers how `require` fetches, verifies, and caches a URL, is `spec/design/modules.md`. Both notes describe one wire protocol, given in [Release documents and bundles](#release-documents-and-bundles).

## Goals

1. **The URL is the dependency.** A program names a package by URL. It needs no manifest, no lockfile to get started, and no installer.
2. **A package is pegged to a Lus release line.** A _line_ is a Lus major and minor version, such as `2.0`. A package that works on `2.0` keeps working on every `2.0` patch release of Lus, because within a line an author may publish only patch versions of the package.
3. **Everything is signed.** Authors sign what they publish with keys registered to their account. Atmosphere signs every release it serves. The runtime refuses anything else.
4. **Quality is measured and shown.** Every push runs the checker, a permission analysis, and a compilation report. Failures block a stable release. The measurements rank search results, so the poorest packages stay out of prominent places.
5. **Documentation serves people and agents equally.** Every package has rendered pages, Markdown and JSON twins of each page, and an `llms.txt`. The registry has a search API.
6. **The server is a Lus program.** It runs on `network.serve` with SQLite for state. It runs the git binaries for the git wire protocol.

## Names and addresses

A package name is 2 to 40 characters from `a` to `z`, `0` to `9`, and `_`. It starts with a letter. The name is a valid Lus identifier, so a package that a program stores in a local of the same name reads naturally. Names are global to the registry and belong to the account that created them. Atmosphere reserves the names of the standard library modules, `lus`, `atmos`, `atmosphere`, `std`, and `test`.

Every address of a package carries its line. The addresses of the package `dates` are the following.

| Address | Content |
| --- | --- |
| `https://atmosp.here/2.0/dates.lus` | The release document of the newest release of `dates` for the `2.0` line. |
| `https://atmosp.here/2.0/dates@1.4.1.lus` | The release document of release `1.4.1`, which never changes. |
| `https://atmosp.here/unstable/dates.lus` | The release document of the newest commit on `main`. |
| `https://atmosp.here/2.0/dates` | The documentation page of the package for the line. |
| `https://atmosp.here/2.0/dates.md`, `.json` | The Markdown and JSON twins of that page. |
| `https://atmosp.here/2.0/dates/llms.txt` | The agent documentation of the package. |
| `https://git.atmosp.here/2.0/dates.git` | The git repository of the package. |

The git repository is one repository for every line. The line in its address is the line that `atmos` prints and that the template configures as the remote. `git.atmosp.here/dates.git` and `git.atmosp.here/2.1/dates.git` name the same repository. A push publishes to the lines that its tags name, whatever line the remote address contains.

## Versions

A package version is a strict semantic version, `MAJOR.MINOR.PATCH`, with no build metadata. The version is the `@version` annotation in the [package header](#the-package-header).

### Lines and patches

The first release of a package for a line fixes its major and minor version on that line. Every later release on the line must keep that major and minor version and raise the patch number. A push that breaks this rule is refused with a message that names the version the line allows next. For example, once `dates` publishes `1.4.0` for `2.0`, the next release for `2.0` must be `1.4.1` or a higher patch. The release for `2.1` may be `1.5.0` or `2.0.0`.

The rule follows how Debian treats a stable release. A program that runs on Lus 2.0 receives fixes to its dependencies and never a change of their interface, so a program written today still runs when its dependencies publish new releases. A change of interface waits for the next line of Lus, which is the point at which a program changes anyway. The cost is that a feature reaches the users of an existing line only through `unstable` or through the next line.

A package version may run ahead of or behind the Lus version. The two numbers are independent apart from the patch rule.

### Zero versions

A version with major version `0` may appear only on `unstable`. A push that publishes a zero version to a stable line is refused. A package therefore states a stable interface, with a major version of at least `1`, before any program on a stable line can depend on it.

### Unstable

The newest commit on `main` is published to the `unstable` line on every push. Its version is the header version followed by `-unstable.N`, where `N` is the number of pushes to `main` since the package was created, such as `0.3.0-unstable.42`. The version rules of the previous sections do not apply to `unstable`. The commit must still be signed. The quality checks run and are reported. They never block an unstable release.

An unstable release runs on the line that its `@lus` annotation names. A stable package must not require an unstable one. The push that adds such a require is refused.

### Yanking and deprecation

An author _yanks_ a release that must not be used, for example one with a security flaw. The address of the line then resolves to the newest release that is not yanked. The pinned address of the yanked release still answers, with `"yanked": true` in its release document, so a program pinned to it keeps running and the runtime prints a warning. Yanking never deletes a release.

An author _deprecates_ a package or a single release with a message, such as the name of a replacement. The release document carries the message. The runtime prints it once per run. Deprecation changes nothing else.

## Publishing with git

A push to `git.atmosp.here` publishes. The server reads three kinds of ref.

- **`main`.** The newest commit is published to `unstable`. The tip commit must be signed by a key of an author of the package. The commits before it may have any author and need no signature, so a package accepts contributions from people without an account.
- **A line tag**, named after a line, such as `2.0`. The tag must be an annotated tag signed by a key of an author. The commit it points to is published as the next release for that line. Moving the tag to a newer commit and pushing it with `--force` publishes the next patch release. The server keeps every published commit under `refs/atmos/2.0/1.4.1`, which pushes cannot change, so moving a tag never loses a release.
- **A control tag**, under `atmos/`. A signed annotated tag `atmos/yank/2.0/1.4.1` yanks that release. Its message is the reason. `atmos/deprecate/2.0` deprecates the package on a line. `atmos/deprecate/2.0/1.4.1` deprecates one release. The message of the tag is the message of the deprecation. `atmos/undeprecate/...` removes it. The server records the action and deletes the control tag from the repository.

Branches other than `main` and tags of any other name are stored and never published. A push that changes nothing published passes no checks.

The server validates a push before git accepts it. If any ref fails, the whole push is refused. Git prints each reason on the pusher's terminal as a line that starts with `remote:`. A push therefore either publishes everything it contains or changes nothing.

The following commands publish the first release of `dates` for `2.0` with git alone.

```sh
git tag -s 2.0 -m "dates 1.4.0"
git push origin main 2.0
```

## Signing

### Author signatures

An author registers public keys with their account: SSH keys of type `ssh-ed25519`, or OpenPGP keys. Git signs commits and tags with either kind. For each push, the server writes the keys of the authors of the package to an allowed signers file and a temporary keyring, then runs `git verify-commit` or `git verify-tag` for each ref it publishes. A signature by any other key, by a revoked key, or by a key registered after the signature was made refuses the ref.

A commit that a web interface creates, such as a merge on GitHub, carries the signature of that service. Its key belongs to no author, so such a commit is refused as the tip of `main`. The author publishes by pushing a signed commit on top of it, which `atmos publish` does.

### Atmosphere signatures

Atmosphere signs every release document with Ed25519. The runtime embeds the public half of the atmosphere _root key_. The root key signs only the list of _signing keys_ at `https://atmosp.here/.well-known/atmos-keys.json`, where each key has an identifier, a public key, and a period of validity. A release document names the signing key that signed it. The runtime accepts a signature when the root key signed that key and the release was signed within the key's period.

The split lets atmosphere replace a signing key without a release of the runtime. The root key stays offline. It signs a new key list only when a signing key changes.

## Release documents and bundles

A _release document_ describes one release. A _bundle_ holds its files. The runtime fetches the release document first, verifies it, and then fetches the bundle that it names.

### Release documents

A request for `https://atmosp.here/LINE/NAME.lus` or `https://atmosp.here/LINE/NAME@VERSION.lus` returns status 200 with the content type `application/vnd.atmos.release+json`. The body is canonical JSON: keys sorted by byte value, no insignificant whitespace, and UTF-8. Its fields are the following.

| Field | Value |
| --- | --- |
| `name` | The package name. |
| `version` | The package version. |
| `lus` | The line the release runs on, such as `"2.0"`. |
| `lus_min` | The oldest Lus release of the line that the release runs on, such as `"2.0.0"`. |
| `main` | The path of the main module inside the bundle. |
| `bundle` | The URL of the bundle. |
| `sha256` | The SHA-256 of the bundle, in lowercase hexadecimal. |
| `size` | The size of the bundle in bytes. |
| `files` | A table from each path in the bundle to the SHA-256 of that file. |
| `permissions` | The permissions that the package declares, as `pledge` strings. |
| `flags` | The build flags that the package declares, each with `name`, `type`, and `default`. |
| `requires` | The atmosphere URLs that the package requires. |
| `commit` | The git commit of the release. |
| `yanked` | `true` for a yanked release, otherwise `false`. |
| `deprecated` | The deprecation message, or `null`. |
| `key` | The identifier of the signing key. |
| `signature` | The Ed25519 signature, in base64, of the canonical JSON of the document without its `signature` field. |

The document for a line address may change with every release, so it is served with `Cache-Control: max-age=300`. The document for a pinned address is served with `Cache-Control: immutable` apart from its `yanked` and `deprecated` fields, which the runtime reads again when it revalidates.

The runtime decides compatibility from the document alone. The line in the URL selects which document the server returns. The runtime never trusts it. The runtime accepts the document when its own major and minor version equal `lus` and its own version is at least `lus_min`. Otherwise `require` raises an error that names both versions.

### Bundles

A bundle is a ustar archive compressed with `vector.archive.zstd`, served at `https://atmosp.here/b/SHA256.tar.zst`. Its address is its hash, so a bundle never changes and every cache may keep it forever. It holds the package's `.lus` files except test files, together with `LICENSE`, `README.md`, and `AGENTS.md` when they exist. Every path is relative to the root of the repository.

A bundle holds source code only. The runtime compiles each file with the build flags of the program, so a `-F` flag removes dead branches inside packages as it does in the program.

### Errors

An error is a JSON object with the fields `error`, a stable code, and `message`. A name that atmosphere does not know, and a package with no release for the requested line, return 404. A package that its author or the registry removed returns 410. A release withheld for a legal reason returns 451.

## The package header

The metadata of a package is a doc comment at the start of its main module. The main module of the package `dates` is `dates.lus` at the root of its repository. `lus doc` reads the header together with the rest of the module's documentation, so the description that a reader sees and the metadata that the registry reads are one text.

The following header declares a package that reads time zone data.

```lus
--- Parses, formats, and compares dates in ISO 8601.
---
--- `dates.parse` reads a date and `dates.format` writes one.
--- @package dates
--- @version 1.4.1
--- @lus 2.0
--- @license 0BSD
--- @repository https://github.com/example/dates
--- @permission fs:read=/usr/share/zoneinfo/* Reads the system time zone database.
--- @flag tzdata string Path of a time zone database to use in place of the system one.

local dates = {}

return dates
```

The header annotations are the following. `@package`, `@version`, `@lus`, and `@license` are required.

- `@package NAME` names the package. It must equal the file name and the repository name.
- `@version VERSION` gives the package version.
- `@lus LINE` gives the line. `@lus 2.0.3` also sets `lus_min` to `2.0.3`.
- `@license SPDX` gives the license as an SPDX identifier, such as `0BSD` or `MIT`.
- `@permission PLEDGE DESCRIPTION` declares one permission that the package needs, in the form that `pledge` accepts, with the reason. It repeats for each permission.
- `@flag NAME TYPE DEFAULT DESCRIPTION` declares one build flag. `TYPE` is `boolean`, `number`, `string`, or a list of strings such as `"fast"|"small"`. `DEFAULT` is optional.
- `@repository URL` and `@homepage URL` link to other places.

### Build flags of a package

A program passes a flag to a package by prefixing the flag with the package name, as in `lus -F dates.tzdata=/opt/tz main.lus`. Inside the files of `dates`, `flags.tzdata` holds `"/opt/tz"`. A package sees only its own flags. Its flags never appear as unprefixed names, so the flags of two packages never collide with each other or with the program's own flags. The checker reports a read of a flag that the header does not declare. The package page lists every declared flag with its type, default, and description.

This scheme needs the runtime to give the chunks of each package a `flags` table of their own. `spec/design/modules.md` records that part.

## Quality checks

The same checks run on every push and on the author's machine through `atmos check`. Each check produces diagnostics with stable codes in the format of `lus check --json`. On a stable line, an error refuses the push. On `unstable`, nothing refuses the push. Every diagnostic is stored and shown on the package page.

### The checker

`lus check` runs over every `.lus` file of the repository. It reports its errors as errors and its warnings as warnings.

### Permissions

A package declares its permissions with `@permission`. The analysis reads the syntax tree of every file with `debug.parse` and finds each call to a standard library function. The `pledges` field of the function's entry in the standard library specification names the permission that the call needs. The analysis reports the following.

| Code | Severity | Reports |
| --- | --- | --- |
| `permission-undeclared` | error | A call needs a permission that no `@permission` covers. |
| `permission-unused` | warning | A declared permission covers no call. |
| `package-restricts` | error | A package calls `pledge` with `seal` or with a rejection such as `~exec`. |
| `package-grants` | warning | A package calls `pledge` to grant a permission. |
| `package-load` | warning | A package calls `load` or `require` with a name that is not a literal string, so its permissions cannot be analyzed. |
| `flag-undeclared` | error | A package reads a field of `flags` that no `@flag` declares. |

Restricting permissions is the job of the main program. A program grants the permissions that its dependencies declare, loads them, and then seals, as in `pledge("fs:read=/usr/share/zoneinfo/*", "seal")` after its last `require`. A package that seals or rejects permits nothing more to the program that loads it, so the program loses permissions that it may still need. The failure then appears far from its cause. A package that grants itself a permission defeats the program's choice in the same way, which is why `package-grants` is reported. The push is refused when the granted permission is not declared.

The package page shows the declared permissions of the package and, separately, the union of the permissions of all its dependencies. A user sees what a dependency asks for before adding it.

### Compilation

A package whose code the JIT compiles poorly makes every program that uses it slower. Two measurements report this.

The first is a set of static warnings for constructs that keep a hot loop in the interpreter or out of the optimizing tier, such as a global read inside a loop, `select` over varargs inside a loop, string concatenation that grows a string inside a loop, `debug.sethook` and `debug.setlocal`, and `setmetatable` with a `__gc` metamethod on a table made inside a loop. Each warning has a code under `perf-`. A warning enters this set only after a benchmark in `tests/bench` shows the construct costing at least 10 percent against its alternative on the same build. The measurement is then recorded in this note.

The second runs the package's tests under `LUS_JIT=opt-eager` and reads the number of exits that `debug.jit()` reports. A package whose tests leave optimized code far more often than the median package is marked on its page. This measurement never refuses a push, because exits depend on the tests as much as on the code.

### Documentation and hygiene

The checks also record the fraction of public entries that carry a doc comment, whether the repository has tests that `lus test` runs and passes, whether `lus fmt --check` passes, and whether the repository has `README.md`, `LICENSE`, and `AGENTS.md`. A missing `LICENSE` refuses a stable release. The others are scored.

## Ranking

Each release receives a quality score from 0 to 100 from its diagnostics, its documentation fraction, its tests, and its compilation report. Search ranks packages by relevance to the query, then by the quality score, then by the number of distinct programs that fetched the package in the last 90 days. The page of every package shows its score and the diagnostics that lowered it, so an author can see how to raise it.

A package with a score below 30, or one whose latest release on a line has an error, is _hidden_. A hidden package is missing from the front page, from category listings, and from search results unless the query matches its name exactly. Its addresses and pages keep working. The thresholds are settings of the server and are tuned on the first hundred packages.

## Documentation for people and agents

On every release, the server runs `lus doc --format json` over the package and stores the result. Each package page is rendered three ways from that one source.

- **HTML** for a browser, at `https://atmosp.here/2.0/dates`. It shows the description, the entries, the permissions, the flags, the score, and the versions.
- **Markdown** at the same address with `.md` appended, and in answer to `Accept: text/markdown`.
- **JSON** at the same address with `.json` appended, and in answer to `Accept: application/json`. It contains the release document fields and the `lus doc` output.

`https://atmosp.here/2.0/dates/llms.txt` lists the package's entries with one line each, in the format of the `llms.txt` that Lus builds for itself. `llms-full.txt` beside it holds the complete Markdown documentation of the package in one file. `https://atmosp.here/llms.txt` describes the registry, its addresses, and the search API, so an agent that knows only the domain finds everything else.

The search API is `GET https://atmosp.here/api/v1/search?q=QUERY&lus=2.0`. It returns JSON with one object per package: the name, the one-line description, the newest version on the line, the quality score, the declared permissions, and the address of the release document. The optional parameter `permission` keeps only packages whose declared permissions are covered by the given `pledge` string, so an agent can ask for "a JSON schema validator that needs no permissions". The parameter `hidden=1` includes hidden packages.

Every response of the API and every page is the same for every client. Nothing requires an account to read.

## Accounts and authentication

Accounts are by invitation. An administrator creates an invitation, which is a single-use link valid for 7 days. The person who opens it chooses a user name and a password and registers at least one signing key. The server stores the password as an Argon2id hash.

A program authenticates with a _token_: 32 random bytes, encoded in base32 with the prefix `atmos_`. The server stores the SHA-256 of each token, never the token. A token has a name, an optional expiry, and a scope, which is `publish`, `read`, or `admin`. Git uses a token as the password of HTTP basic authentication, with the user name as the user. A person without `atmos` creates a token on the account page and stores it with any git credential helper.

`atmos auth login` creates a token without a password prompt in the terminal. It requests a short code from the server and opens `https://atmosp.here/device` in a browser, where the signed-in user confirms the code. The command then receives the token and stores it.

A package has one owner and any number of authors. The owner adds and removes authors. Every author may publish, yank, and deprecate.

## Mirrors and redirects

An author who keeps a package's main repository elsewhere, such as on GitHub, registers it as the package's _upstream_. Atmosphere then works in one of two modes.

- **Mirror.** Atmosphere fetches from the upstream when the upstream sends a push webhook, when the author runs `atmos sync`, and every hour. It validates the fetched refs exactly as it validates a push. It publishes the refs that pass and records a diagnostic for each ref that fails, which the package page and `atmos status` show. The repository on `git.atmosp.here` holds the published refs.
- **Redirect.** Atmosphere fetches and validates in the same way, but it stores only the published commits. A clone of `git.atmosp.here/2.0/dates.git` receives a redirect to the upstream.

In both modes the upstream may contain anything. Atmosphere publishes only what passes its rules, so an unsigned tag or a forbidden version upstream is never served. A GitHub webhook is authenticated with HMAC-SHA256 over its body.

## The server

The server is one Lus program that answers both hosts, `atmosp.here` and `git.atmosp.here`, from one `network.serve` loop. A reverse proxy in front of it terminates TLS and forwards each request to the server on a local port. The server pledges `network:server` for that address, `fs` for its data directory, `exec` for the git binaries and `lus`, and `network:http` for upstreams and webhooks. It seals before it accepts the first request.

### Git

The server authenticates every git request itself. It then runs `git http-backend` for the request, with the environment that the CGI interface defines and `REMOTE_USER` set to the account. A push runs `git receive-pack` inside `git http-backend`, which runs the hooks of the bare repository. The `pre-receive` hook is a Lus script that runs the [signature checks](#signing), the [version rules](#versions), and the [quality checks](#quality-checks) on each ref. It refuses the push when one fails. The `post-receive` hook records the new releases, builds their bundles and documentation, and signs their release documents.

A process call blocks the whole program, as do reads of files and SQLite. The server therefore runs git and the checks in a pool of workers. The request handler waits for the worker's reply in its detached coroutine. The request body reaches git through a file, because `io.popen` connects only one direction. `network.serve` limits a request body to 16 MiB, which limits one push to 16 MiB. A package that needs a larger push is far larger than a Lus package is expected to be.

### State

The server keeps its state in one SQLite database. Its tables are `accounts`, `keys`, `tokens`, `invitations`, `packages`, `authors`, `releases`, `diagnostics`, `docs`, `fetches`, and `audit`. The audit table records every publish, yank, deprecation, key change, and token change with the account and the time. Repositories are bare git repositories under `repos/NAME.git`. Bundles are files under `bundles/SHA256.tar.zst`. A backup is a copy of the database made with SQLite's backup operation together with the two directories.

## First deployment

The first deployment stores git repositories and bundles on GitHub, so the server needs no durable storage apart from its SQLite database.

Each package has a repository `lus-lang/atmos-NAME` on GitHub. Only atmosphere writes to it, with a deploy credential of the `lus-lang` organization. A push to `git.atmosp.here` lands in a temporary bare repository that the server fetches from the GitHub repository first. The `pre-receive` hook validates it as usual. The `post-receive` hook pushes the accepted refs to GitHub, uploads each bundle as an asset of a GitHub release named after the version, and deletes the temporary repository. A clone of `git.atmosp.here/2.0/NAME.git` and a fetch of `/b/SHA256.tar.zst` receive a redirect to GitHub.

The release documents, the documentation, and every other part of the server stay on atmosphere, so the signature that the runtime verifies comes from atmosphere. A bundle that GitHub serves is verified by its hash, so the redirect requires no trust in GitHub. When atmosphere gains its own storage, the server copies each repository and bundle from GitHub and stops redirecting. No address changes.

## The `atmos` command

`atmos` is a Lus program, published on atmosphere as the package `atmos`. Its commands follow the shape `atmos NOUN VERB`, with the most frequent commands also available as a single word. It follows these rules, which the Cloudflare `cf` command also follows.

- Every command accepts `--json` and then prints one JSON value to standard output, with the same fields as the API.
- A command never prompts when standard input is not a terminal. It uses the defaults, or it exits with status 2 and names the option that it needed.
- The exit status is 0 on success, 1 when the command found a problem, such as a failed check, and 2 for a usage error, the statuses of the `lus` tools.
- `atmos help COMMAND` prints the reference of a command. `atmos help --json` prints every command and option.

### Commands

The commands are the following.

```
atmos init [DIR]                 create a package from the template
atmos check                      run the quality checks of atmosphere locally
atmos publish [--line LINE]      check, tag, sign, and push a release
atmos status                     show the releases and diagnostics of this package
atmos sync                       fetch from the upstream of a mirrored package
atmos yank VERSION --reason TEXT
atmos deprecate [VERSION] --message TEXT
atmos undeprecate [VERSION]
atmos search QUERY               search the registry
atmos info NAME                  show a package, its permissions, and its versions
atmos docs NAME [ENTRY]          print the documentation of a package as Markdown
atmos auth login | logout | status
atmos auth token create | list | revoke
atmos auth key add | list | remove
atmos package create NAME [--upstream URL --mode mirror|redirect]
atmos package author add | remove NAME USER
atmos cache list | verify | clean
atmos upgrade                    replace atmos with its newest release
```

`atmos publish` runs `atmos check`, reads the version from the header, and refuses a version that the line does not allow. It then signs the tag of the line, moves it, and pushes `main` and the tag. Each step is a git command that it prints, so an author can do the same by hand.

`atmos yank` and `atmos deprecate` push the [control tags](#publishing-with-git), so they work through git and leave a signed record.

`atmos cache` lists, verifies, and removes the release documents and bundles in the cache of the runtime. The runtime owns the cache and its layout, which `spec/design/modules.md` describes.

`atmos upgrade` fetches the release document of `atmos` for the line of the running `lus`, verifies it as `require` does, and rebuilds the executable with `lus build`.

### `atmos init`

`atmos init` clones the package template, `https://git.atmosp.here/template.git`, into `DIR`, then fills in the package name, the line, and the license. The line defaults to the line of the newest Lus release. The interactive license menu offers `0BSD`, the default, and `MIT`. With `--yes`, or when standard input is not a terminal, it chooses `0BSD`.

The template contains the following files.

- `NAME.lus` with a complete [package header](#the-package-header) and one documented function.
- `NAME_test.lus` with one test.
- `README.md`, `LICENSE`, and `AGENTS.md`, the last written by `lus agents init`.
- `.githooks/pre-commit`, which runs `lus fmt --check` and `lus check`, and `.githooks/pre-push`, which runs `atmos check` when `atmos` is installed and `lus check` and `lus test` otherwise.
- `.gitattributes`, which marks `.lus` files as text with LF line endings, and `.gitignore`.

`atmos init` then sets the local git configuration: `core.hooksPath` to `.githooks`, `commit.gpgsign` and `tag.gpgsign` to `true`, `gpg.format` to `ssh` with `user.signingkey` set to the first registered key it finds, and the remote `origin` to `https://git.atmosp.here/LINE/NAME.git`.

### Agents

Lus treats coding agents as first-class users, so `atmos` checks for `AGENTS.md` at the root of the project. When the file is missing, every command prints one line to standard error that says so and suggests `lus agents init`. `atmos check` reports it as the warning `agents-missing`.

## Work in other parts of Lus

This design needs the following from the runtime and the standard library.

1. **`lus doc` reads the header annotations** `@package`, `@version`, `@lus`, `@license`, `@permission`, `@flag`, `@repository`, and `@homepage` and writes them in its JSON output.
2. **A `flags` table per package**, as [Build flags of a package](#build-flags-of-a-package) describes, owned by `spec/design/modules.md`.
3. **Cryptography.** SHA-256, Ed25519 signing and verification, Argon2id, and UUIDs come from the cryptography work. The server also needs HMAC-SHA256 for webhooks and a source of secure random bytes for tokens and invitations.
4. **A process with two pipes**, whose reads and writes are suspension points like those of a socket. With it, git runs inside the request handler without a worker or a temporary file. The design works without it.
5. **TLS in `network.serve`.** With it, the server terminates TLS itself and needs no proxy. The design works without it.

## Questions for review

1. A line tag is named after the line, such as `2.0`. Moving it publishes the next patch. This note reads "replacing a tag publishes" that way. The other reading is a tag per package version, such as `v1.4.1`, with the line taken from `@lus`.
2. Only the tip of `main` must be signed, so contributors need no account. The stricter rule signs every commit on `main` by an author.
3. A stable package may require only atmosphere URLs, so that every byte a program loads is signed. Allowing other `https` URLs would make the registry useful sooner and weaken that guarantee.
4. Unstable skips the version rules and never blocks on quality. This note reads "unstable skips author checks" that way and still requires a signature.

## Decisions

| Decision | Reason |
| --- | --- |
| Metadata lives in a doc comment header of the main module. | The user chose it over a manifest file. One text serves `lus doc`, the registry, and the reader. |
| The server runs the git binaries for the wire protocol. | The user chose it over implementing git in Lus. The Lus code handles accounts, validation, documentation, and bundles. |
| Library versions are pegged to Lus lines, with patch releases only within a line. | The user chose Debian's model. A program on a line never sees a change of interface. |
| Release documents are signed. Bundles are verified by hash. | One signature covers every file. Bundles may therefore come from any host, including GitHub during the first deployment. |
| A root key signs the signing keys. | A signing key can change without a runtime release. |
| Bundles hold source code. | Build flags fold dead branches in package code. One bundle serves every runtime of the line. |
| Packages declare permissions and never restrict them. | The main program grants, loads, and then seals, so it controls its own permissions. |
| `atmos` is optional. | Everything that it does is a git command or an API call that a person can make by hand. |
