# Remote modules and the atmosphere protocol

This page is the contract between `lus` and the servers it loads modules from. It covers module URLs, the way `require` resolves names inside remote modules, the client side of version 1 of the atmosphere protocol, the module cache, and the permissions a remote require needs. Every Lus release from 2.0 on implements it as written. `spec/design/modules.md` gives the reasons, `spec/design/atmosphere.md` in the atmosphere project is the server side, and `tests/remote/remote.test.mjs` checks this page against a real `lus`.

## Module URLs

A _remote module_ is a module that `require` names by URL. A module URL is an absolute `https` URL whose path ends in `.lus` and which has no query and no fragment. An `http` URL is accepted only when its host is `127.0.0.1`, `::1`, or `localhost`. Any other URL raises an error at the `require`.

`require` normalizes a URL before it uses it. The scheme and the host become lowercase, a default port is removed, and `.` and `..` segments of the path are resolved. The normalized URL is the key of the module in `package.loaded`, so two spellings of one URL load one module. Before it normalizes, `require` looks the URL up under its exact name in `package.loaded` and then in `package.preload`, as it does for any name. A module found there loads without the network and needs no network permission, so a host or a test can provide a remote module.

An atmosphere server serves two forms of URL.

- `https://HOST/LINE/NAME.lus` names the newest release of the package `NAME` for the Lus line `LINE`, such as `2.0`, or for `unstable`.
- `https://HOST/LINE/NAME@VERSION.lus` names one release.

## Names inside a remote module

`require` finds the module that calls it from the chunk of the calling function. A name that a remote module requires resolves in this order.

1. A URL loads that URL.
2. A name of a standard library module, such as `string`, loads that module.
3. In a module of an atmosphere bundle, the name `a.b` is the file `a/b.lus` or `a/b/init.lus` at the root of the bundle. Its key in `package.loaded` is the package URL followed by `#a.b`. This step comes before `package.loaded` and `package.preload`, so a module of the program never takes the place of a module of the package. A name that names no file of the bundle raises `module 'a.b' not found in URL`.
4. In a module from a generic server, the name `a.b` is the URL `a/b.lus` relative to the directory of the module's URL. Its key is that URL.

A remote module never loads a file of the local filesystem by name.

## Permissions

Every `require` of a remote module needs the `network:http` permission for the module URL, checked as `network.fetch` checks a URL, and the `load` permission. A module inside a bundle needs the same permissions for the URL of its package. These checks apply when the module comes from the cache too. The download of a bundle that a verified release document names needs no permission of its own, and it may follow redirects to any `https` host, because the digest in the signed document fixes its content.

## When fetching happens

Before the main chunk runs, `lus` fetches the remote modules of the program's require tree: every literal require of a URL, in the main chunk, in the local modules it reaches, and in remote modules from generic servers, together with the `requires` of atmosphere releases. A fetch that fails before the run raises nothing. The `require` of that module raises the error.

When the command line grants permissions with `-P`, `lus` fetches before the run only the URLs that those grants allow.

A `require` that must contact the network after the main chunk started prints one warning per URL to standard error and then fetches.

```
lus: warning: main.lus:12: fetched https://atmosp.here/2.0/csvx.lus during execution. A literal require lets lus fetch it before the program starts.
```

Three options of `lus` change fetching.

| Option | Effect |
| --- | --- |
| `--offline` | Never contact the network. A module that the cache lacks raises an error. |
| `--reload` | Revalidate every remote module with its server, fresh or not. |
| `--no-prefetch` | Fetch nothing before the run. Every remote module is fetched at its `require`. |

## Detection

`lus` requests a module URL with the header `Accept: application/vnd.atmos.release+json;v=1, text/plain;q=0.1`. It follows redirects only within the host of the URL.

A response with status 200 and the content type `application/vnd.atmos.release+json` is a release document, and the server is an atmosphere server. A response with status 200 and any other content type is the source of a module from a generic server. A binary chunk is refused. Any other status raises an error. An atmosphere server sends errors as a JSON object with the fields `error` and `message`, and the error that `require` raises quotes the message.

The cache records the kind of each host. A host that answered once with a release document must answer with release documents afterwards. A plain file from it raises an error, which stops an attacker on the network path from replacing a signed package with an unsigned file. `atmosp.here` is always an atmosphere host.

## Signed documents and keys

Release documents and key lists are signed documents, as `spec/tools/version.md` defines them: canonical JSON with a `key`, a `signed` time, and a base64 Ed25519 `signature` of the canonical JSON without the `signature` member.

The key list of a host is at `https://HOST/.well-known/atmos-keys.json`. It is a signed document with `"key": "root"`, which the root key of the host signs. Its `keys` field lists the signing keys, each with `id`, `public`, `not_before`, and `not_after`. The binary embeds the root key of `atmosp.here`. For any other host, the list carries the root public key in a `root` field, and `lus` pins it the first time it contacts the host. A later list that the pinned key did not sign raises an error that names the file to delete to accept a new root key. A list older than the cached one is refused.

`lus` verifies a release document under the cached key list, and fetches the list again when the document names a key that the cached list lacks. The `signed` time of the document must fall within the period of its key.

## Release documents

`lus` reads these fields of a release document and ignores the others.

| Field | Use |
| --- | --- |
| `name` | Must equal the `NAME` of the URL. |
| `version` | Must equal the `VERSION` of a pinned URL. |
| `lus`, `lus_min` | The Lus version check. |
| `main` | The path of the main module in the bundle. |
| `bundle`, `sha256`, `size` | The URL of the bundle, its SHA-256 digest in lowercase hexadecimal, and its size in bytes. |
| `files` | Each path of the bundle with the SHA-256 digest of the file. |
| `requires` | Atmosphere URLs to fetch before the run. |
| `flags` | The declared flags of the package with their defaults. |
| `yanked` | `true` for a withdrawn release. `require` prints a warning once per run. |
| `deprecated` | A message, or `null`. `require` prints it once per run. |
| `key`, `signed`, `signature` | The signature. |

A package loads only after every check below passes. A failed check raises an error at the `require` and leaves the cache as it was.

1. The document verifies.
2. `name` and, for a pinned URL, `version` match the URL.
3. The Lus version check: the major version of `lus` equals the major version of the running release, the minor version of `lus` is at most the minor version of the running release, and the running release is at least `lus_min`. Otherwise the error is `URL needs Lus VERSION, this is Lus VERSION`.
4. For a line URL of a stable line, the patch rule: a document whose major or minor version differs from the version that the URL resolved to before is refused, and so is a document whose `signed` time is older than that of the document accepted before. A lower patch number is accepted, since a withdrawn release moves the line back.
5. The bundle has the size and the digest of the document.
6. The unpacked bundle holds exactly the paths of `files`, each with its digest.

## Bundles

A bundle is a POSIX ustar archive compressed with Zstandard. It holds source files with paths relative to the root of the package. `lus` refuses a bundle that holds a link, a device, or any entry other than a regular file or a directory, a path that is absolute, holds a `.` or `..` segment, or holds a character outside `A-Z a-z 0-9 . _ - /`, more than 10000 entries, or more than 64 MiB of file data.

## The module cache

The module cache is the directory `cache` of the Lus home of `spec/tools/version.md`. Deleting it at any time is safe.

```
cache/hosts/HOST.json        the kind of the host and, for an atmosphere host, its pinned root key
cache/keys/HOST.json         the newest verified key list of the host
cache/modules/HASH/url       the normalized module URL
cache/modules/HASH/record.json
                             the resolution of the URL, its freshness, and its ETag
cache/modules/HASH/source.lus
                             the source of a module from a generic server
cache/releases/SHA256.json   a verified release document, named by the digest of its bytes
cache/bundles/SHA256/        an unpacked bundle, named by the digest of the compressed bundle
```

`HOST` is the host of the URL with its port, with `:` written as `_`. `HASH` is the first 32 hexadecimal digits of the SHA-256 digest of the normalized URL.

A record is fresh until its expiry time, which is the `max-age` of the response's `Cache-Control` header, at most seven days, or one day without it. A pinned URL stays fresh for seven days. A fresh record needs no request. A stale record is revalidated with a request that sends its ETag in `If-None-Match`, and a `304 Not Modified` response renews it. When the server cannot be reached, `require` uses the stale record and prints a warning.

## WebAssembly

The WebAssembly build has no network library, so a `require` of a URL that neither `package.loaded` nor `package.preload` holds raises `remote modules are unavailable in the WebAssembly build, which has no network library`. Every command of the `lus` binary that runs Lus code, including `lus test` and `lus debug`, loads remote modules. A host that embeds the native library gets an error that names the missing module store. A host that embeds `lus.wasm` and wants remote modules fetches them itself and stores their loaders in `package.preload`.
