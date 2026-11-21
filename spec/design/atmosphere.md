# Atmosphere

Atmosphere is the package registry of Lus 2.0, served at `atmosp.here`. A program loads a package by its URL, as in `require("https://atmosp.here/2.0/dates.lus")`. The runtime downloads the package, verifies it, and caches it. Authors publish by pushing to a git repository on `git.atmosp.here`. `atmos` is the command line tool for authors. It wraps git and the registry API. Nothing requires it, because a package can be published, installed, and used with git, `lus`, and an account alone.

This note is the server half of the design. The runtime half, which covers how `require` fetches, verifies, and caches a URL, is `spec/design/modules.md`. Both notes describe one wire protocol, given in [Release documents and bundles](#release-documents-and-bundles).

## Goals

1. **The URL is the dependency.** A program names a package by URL. It needs no manifest, no lockfile, and no installer. A pinned address such as `dates@1.4.1.lus` names one release when a program needs exactly that release.
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
| `https://atmosp.here/2.0/dates@1.4.1.lus` | The release document of release `1.4.1`. Only its `yanked` and `deprecated` fields ever change. |
| `https://atmosp.here/unstable/dates.lus` | The release document of the newest commit on `main`. |
| `https://atmosp.here/2.0/dates` | The documentation page of the package for the line. |
| `https://atmosp.here/2.0/dates.md`, `.json` | The Markdown and JSON twins of that page. |
| `https://atmosp.here/2.0/dates/llms.txt` | The agent documentation of the package. |
| `https://git.atmosp.here/2.0/dates.git` | The git repository of the package. |

The git repository is one repository for every line. The line in its address is the line that `atmos` prints and that the template configures as the remote. `git.atmosp.here/dates.git` and `git.atmosp.here/2.1/dates.git` name the same repository. A push publishes to the lines that its release tags name, whatever line the remote address contains.

## Versions

A package version is a strict semantic version, `MAJOR.MINOR.PATCH`, with no build metadata.

### Release tags

A _release tag_ publishes one release. Its name is the package version, `@`, and the line, such as `1.4.0@2.0`. The tag must be an annotated tag signed by the owner of the package, and the `@version` annotation of the package header at the tagged commit must equal the version in the tag name. A release is immutable: a push that moves an existing release tag to another commit is refused.

### Lines and patches

The first release of a package on a line may have any version whose major version is at least `1`. Every later release on the line must keep that major and minor version and raise the patch number. A tag that breaks this rule is refused with an error that names the versions the line allows next, and the release it names is never published. For example, once `dates` publishes `1.4.0@2.0`, the next release for `2.0` must be `1.4.1@2.0` or a higher patch. The first release for `2.1` may be `1.5.0@2.1` or `2.0.0@2.1`. The runtime enforces the same rule for each line URL: it accepts a release document only with the major and minor version it saw first for that URL and a patch number that never decreases. The rule therefore also stops a replay of an older release document.

The rule follows how Debian treats a stable release. A program that runs on Lus 2.0 receives fixes to its dependencies and never a change of their interface, so a program written today still runs when its dependencies publish new releases. A change of interface waits for the next line of Lus, which is the point at which a program changes anyway. The cost is that a feature reaches the users of an existing line only through `unstable` or through the next line.

A package version may run ahead of or behind the Lus version. The two numbers are independent apart from the patch rule.

### Zero versions

A version with major version `0` may appear only on `unstable`. A release tag with a zero version is refused. A package therefore states a stable interface, with a major version of at least `1`, before any program on a stable line can depend on it.

### Unstable

The newest commit on `main` is published to the `unstable` line on every push, whether or not a tag names it. Its version is the header version followed by `-unstable.N`, where `N` is the number of pushes to `main` since the package was created, such as `0.3.0-unstable.42`. The version rules, the line rules, and the quality rules do not apply to `unstable`. The quality checks still run and are reported. The tip commit must be signed by the owner.

### Removing a release tag

Deleting a release tag removes that release from the index of its line. The release disappears from search, from the package page, and from the resolution of the line address, which then serves the newest release of the line that still has a tag. The release stays downloadable at its pinned address, where its release document carries `"yanked": true` and the runtime prints a warning. A program therefore never breaks because a tag was deleted. Pushing the same tag again restores the release, provided it points to the same commit.

Only an administrator of the registry removes a release from download. Its addresses then answer 410.

### Deprecation

The owner deprecates a package on a line, or one release, with a message such as the name of a replacement, through the account page or `atmos deprecate`. The release document carries the message in its `deprecated` field. The runtime prints it once per run. Deprecation changes nothing else.

## Publishing with git

A push to `git.atmosp.here` publishes. The server reads two kinds of ref.

- **`main`.** The newest commit is published to `unstable`. The tip commit must be signed by the owner of the package. The commits before it may have any author and need no signature, so a package accepts contributions from people without an account.
- **Release tags**, named `VERSION@LINE`. Each new tag publishes one release, as [Release tags](#release-tags) describes. A deleted tag [removes its release from the index](#removing-a-release-tag). The server keeps every published commit under `refs/atmos/2.0/1.4.1`, which pushes cannot change, so deleting a tag never loses a release.

Branches other than `main` and tags of any other name are stored and never published. A push that changes nothing published passes no checks.

The server validates a push before git accepts it. If any ref fails, the whole push is refused. Git prints each reason on the pusher's terminal as a line that starts with `remote:`. A push therefore either publishes everything it contains or changes nothing.

The following commands publish the first release of `dates` for `2.0` with git alone.

```sh
git tag -s 1.4.0@2.0 -m "dates 1.4.0"
git push origin main 1.4.0@2.0
```

## Signing

### Owner signatures

An account registers public keys: SSH keys of type `ssh-ed25519`, or OpenPGP public keys in ASCII armor. Git signs commits and tags with either kind. Exactly two things must be signed by a key of the owner of the package: the tip commit of `main` that a push publishes, and each release tag. For each push, the server writes the owner's SSH keys to an allowed signers file and imports the owner's OpenPGP keys into a keyring of their own in a temporary directory. It then runs `git verify-commit` or `git verify-tag` for each ref it publishes, which uses `ssh-keygen` or `gpg` as the signature requires. The server implements no signature format itself. An OpenPGP key that the keyring holds counts whatever its trust level in the web of trust, because the registration of the key is the trust. A signature by any other key, by a revoked key, or by a key registered after the signature was made refuses the ref.

A commit that a web interface creates, such as a merge on GitHub, carries the signature of that service. Its key belongs to no account, so such a commit is refused as the tip of `main`. The owner publishes by pushing a signed commit on top of it, which `atmos publish` does.

### Atmosphere signatures

Atmosphere signs every release document with Ed25519. The runtime embeds the public half of the atmosphere _root key_. The root key signs only the list of _signing keys_ at `https://atmosp.here/.well-known/atmos-keys.json`, a signed document whose `keys` field lists each key with `id`, `public`, `not_before`, and `not_after`. A release document names the signing key that signed it in `key` and the time of signing in `signed`. The runtime accepts a signature when the root key signed the list, the list holds that key, and `signed` falls within the key's period.

Another server that implements this protocol publishes its root public key in the `root` field of its key list. The runtime pins that key the first time it contacts the host, so a private registry needs no release of Lus.

The split lets atmosphere replace a signing key without a release of the runtime. The root key stays offline. It signs a new key list only when a signing key changes.

## Release documents and bundles

A _release document_ describes one release. A _bundle_ holds its files. The runtime fetches the release document first, verifies it, and then fetches the bundle that it names.

### Release documents

A request for `https://atmosp.here/LINE/NAME.lus` or `https://atmosp.here/LINE/NAME@VERSION.lus` returns status 200 with the content type `application/vnd.atmos.release+json`. The body is canonical JSON: keys sorted by byte value, no insignificant whitespace, and UTF-8. The runtime verifies the signature over the bytes it received after it removes the `signature` member and the comma before it, so the server must emit exactly the canonical bytes it signed. Sorting never puts `signature` first, because `bundle` always precedes it. Its fields are the following.

| Field | Value |
| --- | --- |
| `name` | The package name. |
| `version` | The package version. |
| `lus` | The line the release runs on, such as `"2.0"`. |
| `lus_min` | The oldest Lus release that the release runs on, such as `"2.0.0"`. |
| `main` | The path of the main module inside the bundle. |
| `bundle` | The URL of the bundle. |
| `sha256` | The SHA-256 of the bundle, in lowercase hexadecimal. |
| `size` | The size of the bundle in bytes. |
| `files` | A table from each path in the bundle to the SHA-256 of that file. |
| `permissions` | The permissions that the package declares, as `pledge` strings. |
| `flags` | The build flags that the package declares, each with `name`, `type`, and `default`. |
| `requires` | The URLs that the package requires at run time. It is empty on a server that requires [self-contained bundles](#self-contained-bundles). |
| `commit` | The git commit of the release. |
| `yanked` | `true` for a release whose tag was deleted, otherwise `false`. |
| `deprecated` | The deprecation message, or `null`. |
| `key` | The identifier of the signing key. |
| `signed` | The time of signing, in RFC 3339 form in UTC, such as `"2027-02-01T12:00:00Z"`. |
| `signature` | The Ed25519 signature, in base64, of the canonical JSON of the document without its `signature` field. |

The document for a line address may change with every release, so it is served with `Cache-Control: max-age=300`. The document for a pinned address is served with `Cache-Control: immutable` apart from its `yanked` and `deprecated` fields, which the runtime reads again when it revalidates.

The runtime decides compatibility from the document alone. The line in the URL selects which document the server returns. The runtime never trusts it. The runtime accepts the document when its own major version equals the major version in `lus`, its own minor version is at least the minor version in `lus`, and its own version is at least `lus_min`. Otherwise `require` raises an error that names both versions. A package for `2.0` therefore runs on Lus 2.1. A package for `2.1` fails on Lus 2.0. The user chose this rule together with the patch rule, so a package never runs on a line older than the one it was published for.

### Bundles

A bundle is a ustar archive compressed with `vector.archive.zstd`, served at `https://atmosp.here/b/SHA256.tar.zst`. Its address is its hash, so a bundle never changes and every cache may keep it forever. It holds the main module and every module that the main module reaches through requires with literal names, as `lus build` does, together with `LICENSE`, `README.md`, and `AGENTS.md` when they exist. A require with a computed name makes the bundle hold every `.lus` file except test files, since any of them may be loaded. Tools, tests, and other programs in the repository therefore stay out of the bundle. Every path is relative to the root of the repository. A push whose bundle would break a limit of the runtime, such as a path with a character outside `A-Z a-z 0-9 . _ - /` or more than 10000 entries, is refused.

A package keeps its other modules in a directory named after it, such as `dates/zones.lus`. Inside the bundle, `require("dates.zones")` resolves against the root of the bundle, so the same name works in the package's own repository.

A bundle holds source code only. The runtime compiles each file with the build flags of the program, so a `-F` flag removes dead branches inside packages as it does in the program.

### Self-contained bundles

The server setting `self_contained` requires every bundle to hold all the code it loads. It is on for `atmosp.here` and off by default for other servers that run this software. A self-contained package makes no network request for code when it runs, so a program that loads it depends on one download, one signature, and one host.

A package may take its dependencies from anywhere, such as another atmosphere package, a URL on another server, or a file copied by hand. Its repository must contain them at the tagged commit. A dependency lives at the root of the package as a module of its own, such as `strings.lus` and `strings/`, and the package loads it with `require("strings")`, which resolves inside the bundle. The annotation `@includes NAME URL VERSION` in the header records where each dependency came from, so the package page lists it and `atmos add` can update it.

With `self_contained` on, the checks report the following as errors on a stable line.

| Code | Reports |
| --- | --- |
| `bundle-remote-require` | A `require` whose argument is a literal `http` or `https` URL. |
| `bundle-missing-module` | A `require` of a literal name that no file of the bundle provides and that is not a standard library module. |
| `bundle-dynamic-load` | A call of `loadfile` or `dofile`, or a `require` whose argument is not a literal, so the bundle cannot be shown to be complete. |

A call of `load` compiles text that the package already holds or receives, so it is reported as the warning `package-load` on every server.

`atmos check` runs the same checks before a push, and `atmos add` copies a dependency in the required form. The `requires` field of every release document on such a server is the empty list.

### Errors

An error is a JSON object with the fields `error`, a stable code, and `message`. A name that atmosphere does not know, and a package with no release for the requested line, return 404. A release that an administrator removed from download returns 410. A release withheld for a legal reason returns 451.

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

- `@package NAME` names the package. It must equal the name of the main module file and the name of the repository on atmosphere, `git.atmosp.here/LINE/NAME.git`. The repository of an official package on GitHub is named after the package by a fixed mapping: the prefix `atmos-`, then the package name with every `_` written as `-`. The package `html_template` therefore lives in `lus-lang/atmos-html-template`, and the server derives the package name from such a repository by removing the prefix and writing every `-` as `_`. Any other upstream repository may have any name.
- `@version VERSION` gives the package version. At a tagged commit it must equal the version in the release tag.
- `@lus LINE` gives the line. At a tagged commit it must equal the line in the release tag. `@lus 2.0.3` also sets `lus_min` to `2.0.3`.
- `@license SPDX` gives the license as an SPDX identifier, such as `0BSD` or `MIT`.
- `@permission PLEDGE DESCRIPTION` declares one permission that the package needs, in the form that `pledge` accepts, with the reason. It repeats for each permission.
- `@flag NAME TYPE DEFAULT DESCRIPTION` declares one build flag. `TYPE` is `boolean`, `number`, `string`, or a list of strings such as `"fast"|"small"`. `DEFAULT` is optional.
- `@includes NAME URL VERSION` records a dependency copied into the package, as [Self-contained bundles](#self-contained-bundles) describes. It repeats for each dependency.
- `@repository URL` and `@homepage URL` link to other places.

### Build flags of a package

A program passes a flag to a package by prefixing the flag with the package name, as in `lus -F dates.tzdata=/opt/tz main.lus`. Inside the files of `dates`, `flags.tzdata` holds `"/opt/tz"`. A package sees only its own flags. Its flags never appear as unprefixed names, so the flags of two packages never collide with each other or with the program's own flags. The checker reports a read of a flag that the header does not declare. The package page lists every declared flag with its type, default, and description.

A dependency copied into a package keeps its own header, so the files of `dates` copied into `app` read the flags that the header of `dates` declares. The checker checks them against that header, and `-F dates.tzdata` sets them whether `dates` is loaded by its URL or copied into another package.

The runtime compiles each bundle with a `flags` table filtered by the package prefix, which also holds the declared defaults. `spec/design/modules.md` records that part.

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
| `package-pledge` | warning | A module with a package header calls `pledge` at its top level. `lus check` reports it. |
| `package-load` | warning | A package calls `load` or `require` with a name that is not a literal string, so its permissions cannot be analyzed. |
| `package-flag` | error | A package reads a field of `flags` that no `@flag` declares. `lus check` reports it. |
| `package-header` | error | The package header lacks a required annotation. `lus check` reports it. |

Restricting permissions is the job of the main program. A program grants the permissions that its dependencies declare, loads them, and then seals, as in `pledge("fs:read=/usr/share/zoneinfo/*", "seal")` after its last `require`. A package that seals or rejects permits nothing more to the program that loads it, so the program loses permissions that it may still need. The failure then appears far from its cause. A package that grants itself a permission defeats the program's choice in the same way, which is why `package-pledge` is reported. The push is refused when the granted permission is not declared.

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
- **JSON** at the same address with `.json` appended, and in answer to `Accept: application/json`. It contains the fields of the release document and the `lus doc` output.

`https://atmosp.here/2.0/dates/llms.txt` lists the package's entries with one line each, in the format of the `llms.txt` that Lus builds for itself. `llms-full.txt` beside it holds the complete Markdown documentation of the package in one file. `https://atmosp.here/llms.txt` describes the registry, its addresses, and the search API, so an agent that knows only the domain finds everything else.

The search API is `GET https://atmosp.here/api/v1/search?q=QUERY&lus=2.0`. It returns a JSON array with one object per package. Each object has the fields `url`, `name`, `version`, and `description`, which the language server reads through `atmos search --json`, followed by the quality score and the declared permissions. The optional parameter `permission` keeps only packages whose declared permissions are covered by the given `pledge` string, so an agent can ask for "a JSON schema validator that needs no permissions". The parameter `hidden=1` includes hidden packages.

Nothing requires an account to read.

## Accounts and authentication

Accounts are by invitation. An administrator creates an invitation, which is a single-use link valid for 7 days. The person who opens it chooses a user name and a password and registers at least one signing key. The server stores the password as an Argon2id hash.

A program authenticates with a _token_: 32 random bytes, encoded in base32 with the prefix `atmos_`. The server stores the SHA-256 of each token, never the token. A token has a name, an optional expiry, and a scope, which is `publish`, `read`, or `admin`. Git uses a token as the password of HTTP basic authentication, with the user name as the user. A person without `atmos` creates a token on the account page and stores it with any git credential helper.

`atmos auth login` creates a token without a password prompt in the terminal. It requests a short code from the server and opens `https://atmosp.here/device` in a browser, where the signed-in user confirms the code. The command then receives the token and stores it.

A package has one owner, the account that created it. Only the owner signs its releases. A package that changes hands receives a new owner from an administrator.

## Mirrors and redirects

An author who keeps a package's main repository elsewhere, such as on GitHub, registers it as the package's _upstream_. Atmosphere then works in one of two modes.

- **Mirror.** Atmosphere fetches from the upstream when the upstream sends a push webhook, when the author runs `atmos sync`, and every hour. It validates the fetched refs exactly as it validates a push. It publishes the refs that pass and records a diagnostic for each ref that fails, which the package page and `atmos status` show. The repository on `git.atmosp.here` holds the published refs.
- **Redirect.** Atmosphere fetches and validates in the same way, but it stores only the published commits. A clone of `git.atmosp.here/2.0/dates.git` receives a redirect to the upstream.

In both modes the upstream may contain anything. Atmosphere publishes only what passes its rules, so an unsigned tag or a refused version upstream is never served. A GitHub webhook is authenticated with HMAC-SHA256 over its body.

## The server

The server is one Lus program that answers both hosts, `atmosp.here` and `git.atmosp.here`, from one `network.serve` loop. A reverse proxy in front of it terminates TLS and forwards each request to the server on a local port. The server pledges `network:server` for that address, `fs` for its data directory, `exec` for the git binaries and `lus`, and `network:http` for upstreams and webhooks. It seals before it accepts the first request.

### Git

The server authenticates every git request itself. It then runs `git http-backend` for the request, with the environment that the CGI interface defines and `REMOTE_USER` set to the account. A push runs `git receive-pack` inside `git http-backend`, which runs the hooks of the bare repository. The `pre-receive` hook is a Lus script that runs the [signature checks](#signing), the [version rules](#versions), and the [quality checks](#quality-checks) on each ref. It refuses the push when one fails. The `post-receive` hook records the new releases, builds their bundles and documentation, and signs their release documents.

A process call blocks the whole program, as do reads of files and SQLite. The server therefore runs git and the checks in a pool of workers. The request handler waits for the worker's reply in its detached coroutine. The request body reaches git through a file, because `io.popen` connects only one direction. `network.serve` limits a request body to 16 MiB, which limits one push to 16 MiB. A package that needs a larger push is far larger than a Lus package is expected to be.

### State

The server keeps its state in one SQLite database. Its tables are `accounts`, `keys`, `tokens`, `invitations`, `packages`, `releases`, `diagnostics`, `docs`, `fetches`, and `audit`. The audit table records every publish, removal of a tag, deprecation, key change, and token change with the account and the time. Repositories are bare git repositories under `repos/NAME.git`. Bundles are files under `bundles/SHA256.tar.zst`. A backup is a copy of the database made with SQLite's backup operation together with the two directories.

## First deployment

The first deployment serves only the packages that the Lus project maintains. Each of them lives in a repository `lus-lang/atmos-NAME` on GitHub, which the Lus maintainers create and push to. The registry records that repository as the package's upstream in [redirect mode](#mirrors-and-redirects). The server fetches it when GitHub sends a push webhook and every hour, validates the fetched refs exactly as it validates a push, and stores the bundles, documents, and documentation of the releases that pass on its own disk. A clone of `git.atmosp.here/2.0/NAME.git` receives a redirect to GitHub. The repositories are public, so the server fetches them without credentials. The optional setting `upstream_token` authenticates those fetches when the rate limit of GitHub requires it.

Packages by other authors arrive when the registry opens accounts. They live on `git.atmosp.here` as [Publishing with git](#publishing-with-git) describes. The release documents, the documentation, and every address stay the same.

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
atmos add URL                    copy a dependency into the package
atmos publish [--line LINE]      check, tag, sign, and push a release
atmos status                     show the releases and diagnostics of this package
atmos sync                       fetch from the upstream of a mirrored package
atmos unpublish VERSION@LINE     delete a release tag, which removes it from the index
atmos deprecate [VERSION] --message TEXT
atmos undeprecate [VERSION]
atmos search [--server URL] QUERY search the registry
atmos info NAME                  show a package, its permissions, and its versions
atmos docs NAME [ENTRY]          print the documentation of a package as Markdown
atmos auth login | logout | status
atmos auth token create | list | revoke
atmos auth key add | list | remove
atmos package create NAME [--upstream URL --mode mirror|redirect]
atmos cache list | verify | clean
atmos upgrade                    replace atmos with its newest release
```

`atmos publish` runs `atmos check`, reads the version from the header, and refuses a version that the line does not allow. It then creates the signed release tag `VERSION@LINE` and pushes `main` and the tag. Each step is a git command that it prints, so an author can do the same by hand. `atmos unpublish` deletes the tag locally and on the remote with git in the same way.

`atmos add URL` downloads the bundle of a dependency, verifies it as `require` does, and copies its files into the root of the package, as [Self-contained bundles](#self-contained-bundles) describes. It records the source in a `@includes` annotation of the header and replaces the `require` of the URL with a `require` of the module name.

`atmos cache` lists, verifies, and removes the release documents and bundles in the cache of the runtime, which is `$LUS_HOME/cache`. The runtime owns the cache and its layout, which `spec/design/modules.md` describes.

`atmos search --json` prints an array of objects with the fields `url`, `name`, `version`, and `description`, which the language server reads to complete URLs inside `require`. `--server URL` searches another atmosphere server.

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

1. **`lus doc` reads the package header** and writes it as a `package` object in its JSON output. `spec/design/modules.md` section 6 describes it.
2. **A `flags` table per package**, as [Build flags of a package](#build-flags-of-a-package) describes, owned by `spec/design/modules.md`.
3. **Cryptography.** SHA-256, Ed25519 signing and verification, Argon2id, and UUIDs come from the cryptography work. The server also needs HMAC-SHA256 for webhooks and a source of secure random bytes for tokens and invitations.
4. **A process with two pipes**, whose reads and writes are suspension points like those of a socket. With it, git runs inside the request handler without a worker or a temporary file. The design works without it.
5. **TLS in `network.serve`.** With it, the server terminates TLS itself and needs no proxy. The design works without it.

## Questions for review

1. The `@includes` annotation records where a copied dependency came from. `spec/design/modules.md` owns the header, so it needs the agreement of its owner.
2. Deprecation is an action on the account page and through `atmos deprecate`. It needs no tag. The alternative is a signed tag such as `deprecate@2.0`, which keeps deprecation inside git at the cost of a third kind of ref.

## Decisions

| Decision | Reason |
| --- | --- |
| Metadata lives in a doc comment header of the main module. | The user chose it over a manifest file. One text serves `lus doc`, the registry, and the reader. |
| The server runs the git binaries for the wire protocol. | The user chose it over implementing git in Lus. The Lus code handles accounts, validation, documentation, and bundles. |
| Library versions are pegged to Lus lines, with patch releases only within a line. | The user chose Debian's model. A program on a line never sees a change of interface. |
| A release tag is named `VERSION@LINE`. A deleted tag removes the release from the index and keeps it downloadable. | The user chose this form. A deleted tag never breaks a program. |
| Only the tip of `main` and release tags must be signed, by the owner. | The user chose it. Contributors need no account. |
| `atmosp.here` requires self-contained bundles. | The user chose it. A program depends on one download, one signature, and one host per package. |
| The `lus-lang` organization holds only packages that the Lus project maintains. | The user chose it. Other packages live on `git.atmosp.here`. |
| Release documents are signed. Bundles are verified by hash. | One signature covers every file. Bundles may therefore come from any host, including GitHub during the first deployment. |
| A root key signs the signing keys. | A signing key can change without a runtime release. |
| Bundles hold source code. | Build flags fold dead branches in package code. One bundle serves every runtime of the line. |
| Packages declare permissions and never restrict them. | The main program grants, loads, and then seals, so it controls its own permissions. |
| `atmos` is optional. | Everything that it does is a git command or an API call that a person can make by hand. |
