# Atmosphere

Atmosphere is the package registry of Lus 2.0, served at `atmosp.here`. A program loads a package by its URL, as in `require("https://atmosp.here/2.0/dates.lus")`. The runtime downloads the package, verifies it, and caches it. Authors publish by pushing to a git repository on `git.atmosp.here`. `atmos`, the command line tool for authors, wraps git and the registry API. It is optional, because a package can be published, installed, and used with git, `lus`, and an account alone.

The design has a server half and a runtime half. The runtime half, which covers how `require` fetches, verifies, and caches a URL, is `spec/design/modules.md`. Both halves describe one wire protocol, given in [Release documents and bundles](#release-documents-and-bundles).

## Goals

1. **The URL is the dependency.** A program names a package by URL and needs no manifest, lockfile, or installer. A pinned address such as `dates@1.4.1.lus` names one release when a program needs exactly that release.
2. **A package is pegged to a Lus release line.** A _line_ is a Lus major and minor version, such as `2.0`. A package that works on `2.0` keeps working on every `2.0` patch release of Lus, because within a line an author may publish only patch versions of the package.
3. **Everything is signed.** Authors sign what they publish with keys registered to their account. The runtime loads only releases that carry the signature of atmosphere, which signs every release it serves.
4. **Quality is measured and shown.** Every push runs the checker, a permission analysis, and a compilation report, whose failures block a stable release. The measurements also rank search results, so the poorest packages stay out of prominent places.
5. **Documentation serves people and agents equally.** Every package has rendered pages, Markdown and JSON twins of each page, and an `llms.txt`. A search API covers the whole registry.
6. **The server is a Lus program.** It runs on `network.serve`, keeps its state in SQLite, and runs the git binaries for the git wire protocol.

## Names and addresses

A package name is 2 to 40 characters from `a` to `z`, `0` to `9`, and `_`, starting with a letter. The name is a valid Lus identifier, so a package that a program stores in a local of the same name reads naturally. Names are global to the registry and belong to the account that created them. Atmosphere reserves the names of the standard library modules, `lus`, `atmos`, `atmosphere`, `std`, and `test`.

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

A package has one git repository, shared by all its lines. The line in the address of the repository is the line that `atmos` prints and that the template configures as the remote. `git.atmosp.here/dates.git` and `git.atmosp.here/2.1/dates.git` name the same repository. A push publishes to the lines that its release tags name, whatever line the remote address contains.

## Versions

A package version is a strict semantic version, `MAJOR.MINOR.PATCH`, with no build metadata.

### Release tags

A _release tag_ publishes one release. Its name is the package version, `@`, and the line, such as `1.4.0@2.0`. The tag must be an annotated tag signed by the owner of the package. The `@version` annotation of the package header at the tagged commit must equal the version in the tag name. A release is immutable: a push that moves an existing release tag to another commit is refused.

### Lines and patches

The first release of a package on a line may have any version whose major version is at least `1`. Every later release on the line must keep that major and minor version and raise the patch number. A tag that breaks this rule is refused with an error that names the versions the line allows next, so the release it names is never published. For example, once `dates` publishes `1.4.0@2.0`, the next release for `2.0` must be `1.4.1@2.0` or a higher patch, while the first release for `2.1` may be `1.5.0@2.1` or `2.0.0@2.1`. The runtime enforces the same rule for each line URL: it accepts a release document only with the major and minor version it saw first for that URL and a patch number that never decreases. The rule therefore also stops a replay of an older release document.

The rule follows how Debian treats a stable release. A program that runs on Lus 2.0 receives fixes to its dependencies and never a change of their interface, so it keeps running as its dependencies publish new releases. A change of interface goes to the next line of Lus, which is the point at which a program changes anyway. The cost is that the users of an existing line get a new feature only from `unstable` or from the next line.

A package version may run ahead of or behind the Lus version. The two numbers are independent apart from the patch rule.

### Zero versions

A version with major version `0` may appear only on `unstable`, so a release tag with a zero version is refused. Before any program on a stable line can depend on a package, the package must state a stable interface with a major version of at least `1`.

### Unstable

The newest commit on `main` is published to the `unstable` line on every push, whether or not a tag names it. Its version is the header version followed by `-unstable.N`, where `N` is the number of pushes to `main` since the package was created, such as `0.3.0-unstable.42`. The version rules, the line rules, and the quality rules do not apply to `unstable`, although the quality checks still run and are reported. The tip commit must still be signed by the owner.

### Removing a release tag

Deleting a release tag removes that release from the index of its line: from search, from the package page, and from the resolution of the line address, which then serves the newest release of the line that still has a tag. The release stays downloadable at its pinned address, where its release document carries `"yanked": true`, which makes the runtime print a warning. The server signs the release that the line address now serves again, because the runtime accepts a lower patch on a line only from a document signed later than the one it cached. A program therefore never breaks because a tag was deleted. Pushing the same tag again restores the release, provided it points to the same commit.

Only an administrator of the registry removes a release from download. Its addresses then answer 410.

### Deprecation

The owner deprecates a package on a line, or one release, with a message such as the name of a replacement, on the account page or with `atmos deprecate`. The release document carries the message in its `deprecated` field, which the runtime prints once per run. Deprecation changes nothing else.

## Publishing with git

A push to `git.atmosp.here` publishes. The server reads two kinds of ref.

- **`main`.** The newest commit, which must be signed by the owner of the package, is published to `unstable`. The commits before it may have any author and need no signature, so a package accepts contributions from people without an account.
- **Release tags**, named `VERSION@LINE`. Each new tag publishes one release, as [Release tags](#release-tags) describes. A deleted tag [removes its release from the index](#removing-a-release-tag). The server keeps every published commit under `refs/atmos/2.0/1.4.1`, which pushes cannot change, so deleting a tag never loses a release.

Branches other than `main` and tags of any other name are stored and never published. A push that changes nothing published runs no checks.

The server validates a push before git accepts it and refuses the whole push if any ref fails, so a push either publishes everything it contains or changes nothing. Git prints each reason on the pusher's terminal as a line that starts with `remote:`.

The following commands publish the first release of `dates` for `2.0` with git alone.

```sh
git tag -s 1.4.0@2.0 -m "dates 1.4.0"
git push origin main 1.4.0@2.0
```

## Signing

### Owner signatures

An account registers public keys: SSH keys of type `ssh-ed25519`, or OpenPGP public keys in ASCII armor. Git signs commits and tags with either kind. Exactly two things must be signed by a key of the owner of the package: the tip commit of `main` that a push publishes and each release tag. For each push, the server writes the owner's SSH keys to an allowed signers file and imports the owner's OpenPGP keys into a fresh keyring in a temporary directory. It then runs `git verify-commit` or `git verify-tag` for each ref it publishes, which uses `ssh-keygen` or `gpg` as the signature requires. The server implements no signature format itself. An OpenPGP key that the keyring holds counts whatever its trust level in the web of trust, because registering the key is the act of trust. A signature by any other key, by a revoked key, or by a key registered after the signature was made refuses the ref.

A commit that a web interface creates, such as a merge on GitHub, carries the signature of that service. Its key belongs to no account, so such a commit is refused as the tip of `main`. The owner publishes by pushing a signed commit on top of it, which `atmos publish` does.

### Atmosphere signatures

Atmosphere signs every release document with Ed25519. The runtime embeds the public half of the atmosphere _root key_. The root key signs only the list of _signing keys_ at `https://atmosp.here/.well-known/atmos-keys.json`, a signed document whose `keys` field lists each key with `id`, `public`, `not_before`, and `not_after`. A release document names the signing key that signed it in `key` and the time of signing in `signed`. The runtime accepts a signature when the root key signed the list, the list holds that key, and `signed` falls within the key's period.

Another server that implements this protocol publishes its root public key in the `root` field of its key list. The runtime pins that key the first time it contacts the host, so a private registry needs no release of Lus.

The split lets atmosphere replace a signing key without a release of the runtime. The root key stays offline and signs a new key list only when a signing key changes.

## Release documents and bundles

A _release document_ describes one release. A _bundle_ holds its files. The runtime fetches the release document first, verifies it, and then fetches the bundle that it names.

### Release documents

A request for `https://atmosp.here/LINE/NAME.lus` or `https://atmosp.here/LINE/NAME@VERSION.lus` returns status 200 with the content type `application/vnd.atmos.release+json`. The body is canonical JSON: keys sorted by byte value, no insignificant whitespace, and UTF-8. The runtime verifies the signature over the bytes it received after it removes the `signature` member and the comma before it, so the server must emit exactly the canonical bytes it signed. Sorting never puts `signature` first, because `bundle` always precedes it. The fields of the document are the following.

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

The line in the URL only selects which document the server returns, so the runtime decides compatibility from the document alone. It accepts the document when its own major version equals the major version in `lus`, its own minor version is at least the minor version in `lus`, and its own version is at least `lus_min`. Otherwise `require` raises an error that names both versions. A package for `2.0` therefore runs on Lus 2.1, while a package for `2.1` fails on Lus 2.0. Together with the patch rule, this rule keeps a package from running on a line older than the one it was published for.

### Bundles

A bundle is a ustar archive compressed with `vector.archive.zstd`, served at `https://atmosp.here/b/SHA256.tar.zst`. Its address is its hash, so a bundle never changes and every cache may keep it forever. It holds the main module and every module that the main module loads with a literal `require` name, as `lus build` does, together with `LICENSE`, `README.md`, and `AGENTS.md` when they exist. Tools, tests, and other programs in the repository therefore stay out of the bundle. A require with a computed name makes the bundle hold every `.lus` file except test files, since any of them may be loaded. Every path is relative to the root of the repository. A push whose bundle would break a limit of the runtime, such as a path with a character outside `A-Z a-z 0-9 . _ - /` or more than 10000 entries, is refused.

A package keeps its other modules in a directory named after it, such as `dates/zones.lus`. Inside the bundle, `require("dates.zones")` resolves against the root of the bundle, so the same name works in the package's own repository.

A bundle holds source code only. The runtime compiles each file with the build flags of the program, so a `-F` flag removes dead branches inside packages as it does in the program.

### Self-contained bundles

The server setting `self_contained` requires every bundle to hold all the code it loads. It is on for `atmosp.here` and off by default for other servers that run this software. A self-contained package makes no network request for code when it runs, so a program that loads it depends on one download, one signature, and one host.

A package may take its dependencies from anywhere, such as another atmosphere package, a URL on another server, or a file copied by hand, provided its repository contains them at the tagged commit. A copied dependency is a module of its own at the root of the package, such as `strings.lus` and `strings/`. The package loads it with `require("strings")`, which resolves inside the bundle. The annotation `@includes NAME URL VERSION` in the header records where each dependency came from, so the package page lists it and `atmos add` can update it.

With `self_contained` on, the checks report the following as errors on a stable line.

| Code | Reports |
| --- | --- |
| `bundle-remote-require` | A `require` whose argument is a literal `http` or `https` URL. |
| `bundle-missing-module` | A `require` of a literal name that no file of the bundle provides and that is not a standard library module. |
| `bundle-dynamic-load` | A call of `loadfile` or `dofile`, or a `require` whose argument is not a literal, so the bundle cannot be shown to be complete. |

A call of `load` compiles text that the package already holds or receives, so it is reported as the warning `package-load` on every server.

`atmos check` runs the same checks before a push. `atmos add` copies a dependency in the required form. The `requires` field of every release document on such a server is the empty list.

### Errors

An error is a JSON object with two fields: `error` holds a stable code and `message` describes the error. An unknown name and a package with no release for the requested line both return 404. A release that an administrator removed from download returns 410. A release withheld for a legal reason returns 451.

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

- `@package NAME` names the package. It must equal the name of the main module file and the name of the repository on atmosphere, `git.atmosp.here/LINE/NAME.git`. The repository of an official package on GitHub is named after the package by a fixed mapping: the prefix `atmos-`, then the package name with every `_` written as `-`. The package `html_template` therefore has the repository `lus-lang/atmos-html-template`. The server derives the package name from such a repository by removing the prefix and writing every `-` as `_`. Any other upstream repository may have any name.
- `@version VERSION` gives the package version. At a tagged commit it must equal the version in the release tag.
- `@lus LINE` gives the line. At a tagged commit it must equal the line in the release tag. `@lus 2.0.3` also sets `lus_min` to `2.0.3`.
- `@license SPDX` gives the license as an SPDX identifier, such as `0BSD` or `MIT`.
- `@permission PLEDGE DESCRIPTION` declares one permission that the package needs, in the form that `pledge` accepts, with the reason. It repeats for each permission.
- `@flag NAME TYPE DEFAULT DESCRIPTION` declares one build flag. `TYPE` is `boolean`, `number`, `string`, or a list of strings such as `"fast"|"small"`. `DEFAULT` is optional.
- `@includes NAME URL VERSION` records a dependency copied into the package, as [Self-contained bundles](#self-contained-bundles) describes. It repeats for each dependency.
- `@repository URL` and `@homepage URL` link to other places.

### Build flags of a package

A program passes a flag to a package by prefixing the flag with the package name, as in `lus -F dates.tzdata=/opt/tz main.lus`. Inside the files of `dates`, `flags.tzdata` holds `"/opt/tz"`. A package sees only its own flags, which never appear as unprefixed names, so the flags of two packages never collide with each other or with the program's own flags. The checker reports a read of a flag that the header does not declare. The package page lists every declared flag with its type, default, and description.

A dependency copied into a package keeps its own header, so the files of `dates` copied into `app` read the flags that the header of `dates` declares. The checker checks them against that header. `-F dates.tzdata` sets them whether `dates` is loaded by its URL or copied into another package.

The runtime compiles each bundle with a `flags` table filtered by the package prefix, which also holds the declared defaults, as `spec/design/modules.md` records.

## Quality checks

The same checks run on every push and on the author's machine with `atmos check`. Each check produces diagnostics with stable codes in the format of `lus check --json`. On a stable line an error refuses the push, while on `unstable` nothing does. Every diagnostic is stored and shown on the package page.

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

Restricting permissions is the job of the main program. A program grants the permissions that its dependencies declare, loads them, and then seals, as in `pledge("fs:read=/usr/share/zoneinfo/*", "seal")` after its last `require`. A package that seals or rejects permits nothing more to the program that loads it, so the program loses permissions that it may still need and fails far from the cause. A package that grants itself a permission defeats the program's choice in the same way, which is why `package-pledge` is reported. The push is refused when the granted permission is not declared.

The package page shows the declared permissions of the package and, separately, the union of the permissions of all its dependencies. A user sees the permissions that a dependency needs before adding it.

### Compilation

A package whose code the JIT compiles poorly makes every program that uses it slower, so two measurements report how well a package compiles.

The first is a set of static warnings for constructs that keep a hot loop in the interpreter or out of the optimizing tier, such as a global read inside a loop, `select` over varargs inside a loop, string concatenation that grows a string inside a loop, `debug.sethook` and `debug.setlocal`, and `setmetatable` with a `__gc` metamethod on a table made inside a loop. Each warning has a code that starts with `perf-`. A warning enters this set only after a benchmark in `tests/bench` shows the construct costing at least 10 percent against its alternative on the same build. The measurement is then recorded in this note.

The second runs the package's tests under `LUS_JIT=opt-eager` and reads the number of exits that `debug.jit()` reports. A package whose tests leave optimized code far more often than the median package is marked on its page. This measurement never refuses a push, because exits depend on the tests as much as on the code.

### Documentation and hygiene

The checks also record the fraction of public entries that carry a doc comment, whether the repository has tests that `lus test` runs and passes, whether `lus fmt --check` passes, and whether the repository has `README.md`, `LICENSE`, and `AGENTS.md`. A missing `LICENSE` refuses a stable release. The other measures only affect the score.

## Ranking

Each release receives a quality score from 0 to 100 from its diagnostics, its documentation fraction, its tests, and its compilation report. Search ranks packages by relevance to the query, then by the quality score, then by the number of distinct programs that fetched the package in the last 90 days. The page of every package shows its score and the diagnostics that lowered it, so an author can see how to raise it.

A package with a score below 30, or one whose latest release on a line has an error, is _hidden_. A hidden package is missing from the front page, from category listings, and from search results unless the query matches its name exactly, although its addresses and pages keep working. The thresholds are settings of the server and are tuned on the first hundred packages.

## Documentation for people and agents

On every release, the server runs `lus doc --format json` over the package and stores the result. Each package page is rendered three ways from that one source.

- **HTML** for a browser, at `https://atmosp.here/2.0/dates`. It shows the description, the entries, the permissions, the flags, the score, and the versions.
- **Markdown** at the same address with `.md` appended or in answer to `Accept: text/markdown`.
- **JSON** at the same address with `.json` appended or in answer to `Accept: application/json`. It contains the fields of the release document and the `lus doc` output.

`https://atmosp.here/2.0/dates/llms.txt` lists the package's entries with one line each, in the format of the `llms.txt` that Lus builds for itself. `llms-full.txt` beside it holds the complete Markdown documentation of the package in one file. `https://atmosp.here/llms.txt` describes the registry, its addresses, and the search API, so an agent that knows only the domain finds everything else.

The search API is `GET https://atmosp.here/api/v1/search?q=QUERY&lus=2.0`, which returns a JSON array with one object per package. Each object has the fields `url`, `name`, `version`, and `description`, which the language server reads with `atmos search --json`, followed by the quality score, the declared permissions, `updated`, `owner`, `official`, and `deprecated`. The following optional parameters narrow or order the results.

- `permission` keeps only packages whose declared permissions the given `pledge` string covers, so an agent can search for "a JSON schema validator that needs no permissions".
- `hidden=1` includes hidden packages.
- `owner` keeps the packages of one account.
- `official=1` keeps the official packages.
- `sort` orders the results by `updated`, `fetches`, `score`, or `name` in place of relevance.
- `limit` keeps the first results, at most 100.

`GET https://atmosp.here/api/v1/registry` lists the lines that have releases, the default line, and the score below which a package is hidden.

Reading the registry needs no account.

## Accounts and authentication

Accounts are by invitation. An administrator creates an invitation, which is a single-use link valid for 7 days. The person who opens it chooses a user name and a password and registers at least one signing key. The server stores the password as an Argon2id hash.

A program authenticates with a _token_: 32 random bytes, encoded in base32 with the prefix `atmos_`. The server stores only the SHA-256 of each token. A token has a name, an optional expiry, and a scope, which is `publish`, `read`, or `admin`. Git uses a token as the password of HTTP basic authentication, with the user name as the user. A person without `atmos` creates a token on the account page and stores it with any git credential helper.

`atmos auth login` creates a token without prompting for a password in the terminal. It requests a short code from the server and opens `https://atmosp.here/device?code=CODE` in a browser, where the signed-in user confirms the code with `POST /api/v1/device/confirm`, then receives the token and stores it.

A browser signs in with `POST /api/v1/session`, which sets the cookie `atmos_session` with the attributes `HttpOnly`, `SameSite=Strict`, `Path=/api/v1/`, and a lifetime of 14 days, adding `Secure` when the public address of the server is https. `DELETE /api/v1/session` ends the session. The session is a token of scope `session` that only the cookie carries. The server stores its SHA-256, refuses it as a bearer token, and leaves it out of the token list. The cookie authenticates only the routes under `/api/v1/`, never git or a document. A write that the cookie authenticates must be JSON and, when the browser sends an `Origin`, must come from the public address of the server. A request that the browser marks `Sec-Fetch-Site: cross-site` is refused, so a cross-site form cannot act for a signed-in user. A wrong name and a wrong password receive the same answer after the same work, so a login never reveals whether an account exists. The website reads and accepts an invitation with `GET` and `POST /api/v1/invitations/CODE`.

A package has one owner, the account that created it, which alone signs its releases. An administrator assigns a new owner when a package changes hands.

## Mirrors and redirects

An author who keeps a package's main repository elsewhere, such as on GitHub, registers it as the package's _upstream_. Atmosphere then works in one of two modes.

- **Mirror.** Atmosphere fetches from the upstream when the upstream sends a push webhook, when the author runs `atmos sync`, and every hour. It validates the fetched refs exactly as it validates a push, publishes the refs that pass, and records a diagnostic for each ref that fails, which the package page and `atmos status` show. The repository on `git.atmosp.here` holds the published refs.
- **Redirect.** Atmosphere fetches and validates in the same way, but it stores only the published commits. A clone of `git.atmosp.here/2.0/dates.git` receives a redirect to the upstream.

In both modes the upstream may contain anything, because atmosphere publishes only what passes its rules. An unsigned tag or a refused version upstream is never served. A GitHub webhook is authenticated with HMAC-SHA256 over its body.

## The server

The server is one Lus program that answers both hosts, `atmosp.here` and `git.atmosp.here`, from one `network.serve` loop. A reverse proxy or a [Cloudflare Tunnel](#other-cloudflare-services) in front of it terminates TLS and forwards each request to the server on a local port. The server pledges `network:server` for that address, `fs` for its data directory, `exec` for the git binaries and `lus`, and `network:http` for upstreams and webhooks, then seals before it accepts the first request.

### Git

The server authenticates every git request itself, then runs `git http-backend` for it with the environment that the CGI interface defines and `REMOTE_USER` set to the account. A push runs `git receive-pack` inside `git http-backend`, which runs the hooks of the bare repository. The `pre-receive` hook is a Lus script that runs the [signature checks](#signing), the [version rules](#versions), and the [quality checks](#quality-checks) on each ref and refuses the push when one fails. The `post-receive` hook records the new releases, builds their bundles and documentation, and signs their release documents.

A process call blocks the whole program, as do reads of files and SQLite, so the server runs git and the checks in a pool of workers. The request handler waits for the worker's reply in its detached coroutine. The server passes the request body to git in a file, because `io.popen` connects only one direction. `network.serve` limits a request body to 16 MiB, which limits one push to 16 MiB, far more than a Lus package is expected to need.

### State

The server keeps its state in one SQLite database with the tables `accounts`, `keys`, `tokens`, `invitations`, `packages`, `releases`, `diagnostics`, `docs`, `fetches`, and `audit`. The audit table records every publish, removal of a tag, deprecation, key change, and token change with the account and the time. Repositories are bare git repositories under `repos/NAME.git`. Bundles are files under `bundles/SHA256.tar.zst`. A backup is a copy of the database made with SQLite's backup operation together with the two directories.

## First deployment

The first deployment serves only the packages that the Lus project maintains. Each of them has a repository `lus-lang/atmos-NAME` on GitHub, which the Lus maintainers create and push to. The registry records that repository as the package's upstream in [redirect mode](#mirrors-and-redirects). The server fetches it when GitHub sends a push webhook and every hour, validates the fetched refs exactly as it validates a push, and stores the bundles, documents, and documentation of the releases that pass on its own disk. A clone of `git.atmosp.here/2.0/NAME.git` receives a redirect to GitHub. The repositories are public, so the server fetches them without credentials. The optional setting `upstream_token` authenticates those fetches when the rate limit of GitHub requires it.

Packages by other authors arrive when the registry opens accounts and are hosted on `git.atmosp.here` as [Publishing with git](#publishing-with-git) describes. The release documents, the documentation, and every address stay the same.

## Integrations

The server serves every address itself. An _integration_ moves the read path of the registry to the edge of a provider, with the server as its origin. The first integration is Cloudflare, which `atmosp.here` uses. The setting `driver` selects the integration and is `local`, the default, or `cloudflare`. Every feature of the registry works under the local driver, so a server without a provider account is a complete registry.

### Drivers

The server uses one driver module under `server/drivers/` for storage and the edge. A driver is a table of the following functions.

| Function | Local driver | Cloudflare driver |
| --- | --- | --- |
| `check()` | Returns at once. | Reads the credentials and names a missing one. The server calls it at start. |
| `put(key, data, type)` | Returns at once, because the disk holds the bundle. | Puts the bytes of a bundle in R2. |
| `get(key)` | Returns nothing. | Reads an object from R2. The server calls it for a bundle that its disk lacks. |
| `delete(key)` | Returns at once. | Deletes an object from R2. |
| `purge(urls, tags)` | Returns at once. | Purges URLs or cache tags from the Cloudflare cache. |
| `headers(class, name)` | Adds no header. | Adds `Cloudflare-CDN-Cache-Control` and `Cache-Tag`. |
| `client(req)` | Reads `X-Forwarded-For`. | Reads `CF-Connecting-IP`. |
| `fetches(since)` | Returns no rows. | Reads the fetches that the edge counted from Analytics Engine. |

The `post-receive` hook and the administrator's actions write the work for a driver to the `outbox` table, which a loop of the server sends, as [Caching and purging](#caching-and-purging) describes. The rest of the server runs the same code under both drivers. The git hooks open the driver with an empty environment, so the Cloudflare driver reads its credentials on first use and the hooks never hold them. A release document holds the same addresses under both drivers, so a change of driver never re-signs a document. The bundle address stays `https://atmosp.here/b/SHA.tar.zst` whichever host stores the bytes.

The Cloudflare driver uses the S3 interface of R2. `server/drivers/s3.lus` signs each request with AWS Signature Version 4, which `crypto.hmac` and `crypto.hash` compute. A unit test checks the signer against the example request of the AWS documentation. The same module works with any S3 store, which the tests use. The local disk keeps every bundle, so a backup of the server stays complete and the server can serve a bundle when R2 cannot.

### Caching and purging

Each address class has its own headers. `Cache-Control` applies to the client and every cache between it and the edge. `Cloudflare-CDN-Cache-Control` applies to the Cloudflare cache alone, so the edge keeps a response far longer than a client does and drops it on a purge.

| Addresses | `Cache-Control` | Edge lifetime | Purged when |
| --- | --- | --- | --- |
| `/b/SHA.tar.zst` | `public, max-age=31536000, immutable, no-transform` | One year | An administrator removes the last release that serves the bundle, which also deletes it from the disk and from R2. |
| `/LINE/NAME@VERSION.lus` | `public, max-age=300, no-transform, stale-if-error=604800` | One year | The document is signed again, after a yank, a deprecation, or a removal. |
| `/LINE/NAME.lus`, `/unstable/NAME.lus` | `public, max-age=60, no-transform, stale-if-error=604800` | One year | A release, a deleted tag, a deprecation, or a removal changes the newest release of the line. |
| `/LINE/NAME`, its `.md` and `.json` twins, its `llms.txt` and `llms-full.txt` | `public, max-age=300` | One day | Any change to a release of the package on the line. |
| `/.well-known/atmos-keys.json` | `public, max-age=3600` | One day | A signing key is added or retired. |
| `/`, `/search`, `/llms.txt`, `/api/v1/search`, `/api/v1/packages` | `public, max-age=60` | One minute | They expire. |
| A document or page that answers with an error | `public, max-age=60` | Never cached past a minute | They expire. |
| Every other `/api/v1/` route, `/device`, `/invite/`, git, and every write | `private, no-store` | Never cached | |

A purge follows the commit of the change in the database. The server writes each path to purge to the `outbox` table in the same transaction as the change, along with the bundles to copy to R2 or delete from it and a call of the deploy hook of the website. A loop sends the items in batches within the limit of the API and removes an item when the provider accepts it. A failed item is sent again on the next pass, so a document never stays stale past a failed purge. A change that arrives while its item is in flight increments the `seq` of the item, which keeps the item for the next pass. Each response of a package also carries `Cache-Tag: atmos-NAME`, so the setting `purge_by = "tag"` purges a whole package with one tag in place of its list of URLs.

A page answers `Accept: text/markdown` and `Accept: application/json` at the address of its HTML with `Vary: Accept`. Cloudflare keys its cache by URL, so the edge worker rewrites such a request to the `.md` or `.json` twin before it reaches the cache.

### Signatures from end to end

The client trusts nothing at the edge. It verifies each release document under the keys that the root key signs and verifies each bundle against the SHA-256 in its document, so a response that a cache altered fails those checks. The client also refuses a cached document older than the one it holds, because it accepts only a newer `signed` time. The `no-transform` directive keeps every intermediary from changing the bytes that a signature or a hash covers. The signing keys stay on the server, so nothing at Cloudflare can sign.

The `stale-if-error` directive lets the edge serve the documents it holds while the origin is unreachable, so programs keep loading their packages, with the same signatures, during an outage of the server.

### The edge worker

One Cloudflare Worker, `atmos-edge`, serves the route `atmosp.here/*`. Its source and its `wrangler.toml` are in `edge/` of the atmosphere repository. It has the built website as static assets, a binding to the R2 bucket of bundles, and a binding to an Analytics Engine dataset. It classifies each path with the rules of `server/routes.lus`. The cases in `edge/routes.json` are the ones on which the worker and the server must agree. It handles each read in the following order.

1. `/b/SHA.tar.zst` comes from R2 with the headers of the class. A missing object falls through to the origin.
2. For a release document, the worker records one data point with the package, the line, and the client hash in Analytics Engine, then fetches the document from the origin through the cache. The client hash is the first 16 hex digits of the SHA-256 of the client address, as the server computes it, so the two counts join.
3. A page request with an `Accept` header for Markdown or JSON is rewritten to its twin and fetched through the cache.
4. A page, `/`, `/search`, and every path of no other kind come from the files of the website. A package page without a file of its own comes from the file that the variable `PAGE_SHELL` names, when it names one. A page, `/`, or `/search` without a file goes to the origin, whose HTML pages answer it. Any other path without a file answers with the 404 page of the website.
5. Every other read and every write go to the origin.

A release document that misses the cache comes from the server, so the newest release has one source, the database of the server. The worker resolves no address itself.

Ranking counts the distinct programs that fetch a package. Because the edge answers most fetches before they reach the server, the Cloudflare driver reads the Analytics Engine dataset once a day with its SQL interface and merges the counts into the `fetches` table. The local driver counts fetches at the server.

`git.atmosp.here` is proxied by Cloudflare without the worker, for the WAF and the rate limits. A push is one HTTP request that stays open during the `pre-receive` and `post-receive` hooks, so it meets two limits of the proxy. The first is the size of the request body, which Cloudflare limits to 100 MB on its smaller plans and more on larger ones. The server accepts 16 MiB, so its own limit is the one a push meets. Git reports a larger push as HTTP 413 and sends a pack larger than its `http.postBuffer` of 1 MiB with chunked encoding, which the server accepts. The second limit is the 100 seconds that the proxy waits for an answer before it reports a timeout. A push of 14 MB validated and published in 2 seconds in a local test, so the 16 MiB limit keeps every push far inside that timeout.

### The website

The website of the registry is an Astro project in `site/` of the atmosphere repository that reads the JSON interface of the server. Its build output is the set of static assets of `atmos-edge`, so the site and the API share the origin `atmosp.here` and need no CORS. When the repository variable `EDGE_DEPLOY` is `true`, the workflow `deploy-edge.yml` builds the site and runs `wrangler deploy` from `edge/` after each push to `main` that changes `site/` or `edge/`. Its API token is a secret of the repository.

The settings `site` and `site_shell` name a directory of built site files and the file that answers a package page without a file of its own. The server answers from them exactly as the edge worker does, so a server without Cloudflare serves the same website. A server without a built site serves its own HTML pages. The setting `site_hook` names a URL that the server calls with `POST` after each change to a release, so a site that builds its pages ahead of time rebuilds them.

`GET /api/v1/packages?name=NAME` reports the number of distinct programs that fetched the package in the last 90 days as `fetches`, which joins the counts of the server and the edge.

### Other Cloudflare services

- **DNS and TLS.** The zone `atmosp.here` is on Cloudflare DNS. Its universal certificate covers `atmosp.here` and `git.atmosp.here`.
- **Tunnel.** `cloudflared` on the server machine connects out to Cloudflare and forwards requests to the port of the server, so the machine opens no inbound port and needs no certificate of its own. The tunnel replaces the reverse proxy. The Cloudflare driver trusts `CF-Connecting-IP` because requests reach the server only through the tunnel.
- **WAF and rate limiting.** Rate limiting rules cover `POST /api/v1/device/token`, `/device`, `/invite/`, `POST /api/v1/tokens`, and `git-receive-pack`. The server keeps its own limits per client in windows of one minute as well, so the local driver is as safe. The setting `limits` gives them as `auth` for the forms and token creation, `poll` for the polling of a device login, and `push` for git pushes. Bot Fight Mode and the Browser Integrity Check stay off for the zone, because the runtime, git, and `atmos` are programs that a browser challenge would stop.
- **Turnstile.** A later change can add a Turnstile challenge to the invitation and device forms.

Git hosting, push validation, quality checks, documentation builds, signing, accounts, search, and the database stay on the Lus server.

### Configuration of the Cloudflare driver

The configuration names the Cloudflare account, zone, bucket, and dataset. Credentials come from environment variables, which the configuration file names.

```json
{
    "driver": "cloudflare",
    "cloudflare": {
        "account_id": "0123456789abcdef0123456789abcdef",
        "zone_id": "fedcba9876543210fedcba9876543210",
        "bucket": "atmosphere-bundles",
        "dataset": "atmos_fetches",
        "purge_by": "url",
        "token_env": "ATMOS_CF_TOKEN",
        "r2_key_env": "ATMOS_R2_KEY",
        "r2_secret_env": "ATMOS_R2_SECRET"
    }
}
```

The API token carries the permissions Zone Cache Purge and Account Analytics Read for the one zone and account. The R2 key reads and writes objects in the one bucket. The settings `api_url` and `r2_url` replace the Cloudflare endpoints for the tests.

### Testing without an account

`tests/e2e-cloudflare.sh` runs the server with `driver` set to `cloudflare` against `tests/standin.lus`, a Lus server that stands in for the Cloudflare API, an S3 store, and the deploy hook, recording each call. In CI the bundles go to the MinIO store that the variable `S3_URL` names. The test checks that a release copies its bundle to the store, purges its addresses, and calls the site hook. It also checks the headers of each address class, the purges of a deprecation and of a deleted tag, a bundle read from the store when the disk lacks it, a failed purge sent again, the deletion of a bundle whose last release is removed, the merge of the fetch counts of the edge, the site files, and the request limits.

`edge/test/run.sh` runs `atmos-edge` under `wrangler dev` in its local mode, which needs no Cloudflare account, in front of a stand-in server with a bundle in the local bucket. It checks the routing, the `Accept` rewrite, the bundle reads, the page shell, and the 404 page of the website.

## The `atmos` command

`atmos` is a Lus program, published on atmosphere as the package `atmos`. Its commands follow the shape `atmos NOUN VERB`, with the most frequent commands also available as a single word. It follows the following rules, which it shares with the Cloudflare `cf` command.

- Every command accepts `--json` and then prints one JSON value to standard output, with the same fields as the API.
- A command never prompts when standard input is not a terminal. It uses the defaults, or it exits with status 2 and names the option that it needed.
- The exit status is 0 on success, 1 when the command found a problem, such as a failed check, and 2 for a usage error, as with the `lus` tools.
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

`atmos init` clones the package template, `https://git.atmosp.here/template.git`, into `DIR`, then fills in the package name, the line, and the license. The line defaults to the line of the newest Lus release. The interactive license menu offers `MIT` and the default, `0BSD`. With `--yes`, or when standard input is not a terminal, it chooses `0BSD`.

The template contains the following files.

- `NAME.lus` with a complete [package header](#the-package-header) and one documented function.
- `NAME_test.lus` with one test.
- `README.md`, `LICENSE`, and `AGENTS.md`, the last written by `lus agents init`.
- `.githooks/pre-commit`, which runs `lus fmt --check` and `lus check`.
- `.githooks/pre-push`, which runs `atmos check` when `atmos` is installed and `lus check` and `lus test` otherwise.
- `.gitignore` and a `.gitattributes` that marks `.lus` files as text with LF line endings.

`atmos init` then sets the local git configuration: `core.hooksPath` to `.githooks`, `commit.gpgsign` and `tag.gpgsign` to `true`, `gpg.format` to `ssh` with `user.signingkey` set to the first registered key it finds, and the remote `origin` to `https://git.atmosp.here/LINE/NAME.git`.

### Agents

Lus treats coding agents as first-class users, so `atmos` checks for `AGENTS.md` at the root of the project. When the file is missing, every command prints a line to standard error that suggests `lus agents init`. `atmos check` also reports it as the warning `agents-missing`.

## Work in other parts of Lus

This design needs the following from the runtime and the standard library.

1. **`lus doc` reads the package header** and writes it as a `package` object in its JSON output. `spec/design/modules.md` describes the object.
2. **A `flags` table per package**, as [Build flags of a package](#build-flags-of-a-package) describes, owned by `spec/design/modules.md`.
3. **Cryptography.** SHA-256, Ed25519 signing and verification, Argon2id, and UUIDs come from the cryptography work. The server also needs HMAC-SHA256 for webhooks and a source of secure random bytes for tokens and invitations.
4. **A process with two pipes**, whose reads and writes are suspension points like those of a socket. It would let git run inside the request handler without a worker or a temporary file, although the design works without it.
5. **TLS in `network.serve`.** It would let the server terminate TLS itself with no proxy, although the design works without it.

## Questions for review

1. The `@includes` annotation records where a copied dependency came from. `spec/design/modules.md` owns the header, so the annotation needs the agreement of the owner of that note.
2. Deprecation is an action on the account page or with `atmos deprecate`, which needs no tag. A signed tag such as `deprecate@2.0` would keep deprecation inside git at the cost of a third kind of ref.

## Decisions

| Decision | Reason |
| --- | --- |
| Metadata is a doc comment header of the main module. | One text serves `lus doc`, the registry, and the reader, with no manifest file to keep in step. |
| The server runs the git binaries for the wire protocol. | Git stays the implementation of its own protocol, so the Lus code handles only accounts, validation, documentation, and bundles. |
| Library versions are pegged to Lus lines, with patch releases only within a line. | It follows Debian's model of a stable release, so a program on a line never sees a change of interface. |
| A release tag is named `VERSION@LINE`. A deleted tag removes the release from the index and keeps it downloadable. | One ref names both the version and the line. A deleted tag never breaks a program. |
| Only the tip of `main` and release tags must be signed, by the owner. | Contributors need no account, because the commits before the tip need no signature. |
| `atmosp.here` requires self-contained bundles. | A program depends on one download, one signature, and one host per package. |
| The `lus-lang` organization holds only packages that the Lus project maintains. | A repository in `lus-lang` is always an official package. Other packages are hosted on `git.atmosp.here`. |
| Release documents are signed. Bundles are verified by hash. | One signature covers every file. Bundles may therefore come from any host, including GitHub during the first deployment. |
| A root key signs the signing keys. | A signing key can change without a runtime release. |
| Bundles hold source code. | Build flags fold dead branches in package code. One bundle serves every runtime of the line. |
| Packages declare permissions and never restrict them. | The main program grants, loads, and then seals, so it controls its own permissions. |
| `atmos` is optional. | Everything that it does is a git command or an API call that a person can make by hand. |
| Integrations are drivers that the configuration selects, with the local driver as the default. | Cloudflare support is complete and optional, so every feature works without a provider account. |
| Signed documents name the same addresses under every driver. | A change of provider never signs a document again. |
| The edge caches release documents and purges them on change. | The newest release has one source, the database of the server, while the edge still answers most reads. |
| `git.atmosp.here` goes through the Cloudflare proxy. | The proxy adds the WAF and the rate limits. The 16 MiB limit of the server keeps pushes far inside the limits of the proxy. |
| The website renders package pages in the browser from one shell, `package/index.html`. | Pages stay current without a rebuild, so the server calls no deploy hook on `atmosp.here`. |
