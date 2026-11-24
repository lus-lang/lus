# The version manager

This page is the contract of `lus version` and `lus +REQUEST`. Every Lus release from 2.0 on implements it exactly as written, so a script that uses it works with every release. A later release may add a subcommand, an option, a JSON field, a target, or an exit status. It never removes or changes one. `spec/design/modules.md` gives the reasons for the design, and `tests/version/version.test.mjs` checks this page against a real `lus`.

## Versions and requests

A _version_ is `MAJOR.MINOR.PATCH`, optionally followed by `-` and a prerelease label of dot-separated identifiers, such as `2.0.3` or `2.1.0-unstable.7`. Each number is decimal without a leading zero. Versions order as Semantic Versioning 2.0.0 orders them.

A _channel_ is `stable` or `unstable`. The stable channel holds the releases tagged `vMAJOR.MINOR.PATCH`. The unstable channel holds builds of the development branch, whose versions carry the label `unstable.N`. An installed version belongs to the channel it was installed from.

A _request_ selects a version. The forms are the following.

| Request | Selects |
| --- | --- |
| `2.0.3` | Exactly that version. |
| `2.0` | The highest version `2.0.x` without a prerelease label. |
| `2` | The highest version `2.x.y` without a prerelease label. |
| `stable`, `unstable` | For installing, the version that the release index names for the channel. For selecting, the highest installed version of the channel. |

Any other text is a malformed request, which exits with status 2.

## Commands

Every subcommand accepts `--json`. With it, the command prints exactly one JSON object followed by a newline on standard output, with nothing else on standard output. Warnings and progress go to standard error in both forms.

| Command | Effect |
| --- | --- |
| `lus version` | Prints the version of the running binary. |
| `lus version list` | Lists the installed versions in ascending order. |
| `lus version list --remote [CHANNEL]` | Lists the versions of a channel in the release index, `stable` by default. |
| `lus version install REQUEST` | Installs the version that the request selects from the release index. If no default is set, the installed version becomes the default. |
| `lus version use REQUEST` | Makes an installed version the default. |
| `lus version remove VERSION` | Deletes an installed version. `VERSION` must be exact. |
| `lus version which [REQUEST]` | Prints the path of the executable of an installed version, by default the default version. |

The human output of `lus version` is the line that `lus -v` prints, such as `Lus 2.0.3`. The human output of `which` is the path alone on one line. The human output of every other subcommand may change between releases.

`use` and `which` without a request print a warning to standard error when the first `lus` on `PATH` is another file than `bin/lus` of the Lus home.

## `lus +REQUEST`

`lus +REQUEST ARGS...` runs the installed version that the request selects with the arguments `ARGS`. The form applies only when `+REQUEST` is the first argument. Anywhere else `+REQUEST` is an ordinary argument.

On POSIX systems, `lus` replaces its own process with the selected executable, so the exit status, the signals, and the standard streams are those of the selected release. On Windows, `lus` starts the selected executable, waits for it, and exits with its status.

`lus +REQUEST` reads only the Lus home and never contacts the network. A malformed request exits with status 2. A request that selects no installed version prints the command that installs it and exits with status 3.

## JSON output

Every object has `"schema": 1`. The objects below are the output of each subcommand, in order: `lus version`, `list`, `list --remote`, `install`, `use`, `remove`, and `which`.

```json
{"schema":1,"version":"2.0.3","path":"/home/ana/.lus/versions/2.0.3/bin/lus"}
{"schema":1,"default":"2.0.3","versions":[{"version":"2.0.3","channel":"stable","default":true,"path":"/home/ana/.lus/versions/2.0.3/bin/lus"}]}
{"schema":1,"channel":"stable","versions":[{"version":"2.0.3","published":"2027-02-01T12:00:00Z","installed":true}]}
{"schema":1,"version":"2.0.3","path":"/home/ana/.lus/versions/2.0.3/bin/lus","already":false}
{"schema":1,"version":"2.0.3","path":"/home/ana/.lus/bin/lus","previous":"2.0.2"}
{"schema":1,"version":"2.0.2","removed":true}
{"schema":1,"version":"2.0.3","path":"/home/ana/.lus/versions/2.0.3/bin/lus"}
```

- `default` and `previous` are `null` when no default is set. `channel` of an installed version is `null` when its `channel` file is missing.
- `already` is `true` when the version was installed before the command ran, which is a success.
- The `path` of `lus version` is the path of the running executable, or `null` when the system does not report it.

A failure prints an object with the field `error`, which holds a `code` and a `message`.

```json
{"schema":1,"error":{"code":"not-installed","message":"lus 2.1 is not installed. Run `lus version install 2.1`"}}
```

## Exit statuses

| Status | Codes | Meaning |
| --- | --- | --- |
| 0 | | Success. |
| 1 | `network`, `io` | A download failed, or a file of the Lus home could not be read or written. |
| 2 | `usage` | The arguments are malformed. |
| 3 | `not-installed`, `not-found` | No installed version matches the request, or no release in the index matches it. |
| 4 | `verify` | A signature, a key list, a digest, or a size did not verify, the index is older than one accepted before, or the binary trusts no release key. Nothing was installed. |
| 5 | `in-use` | `remove` named the default version. |

## The Lus home

The _Lus home_ is the value of `LUS_HOME` when that variable is set and not empty. Otherwise it is `$HOME/.lus` on POSIX systems and `%LOCALAPPDATA%\lus` on Windows. The layout is the following.

```
bin/lus               the default version: a symbolic link to ../versions/VERSION/bin/lus,
                      a hard link or a copy of versions\VERSION\bin\lus.exe on Windows
default               one line: the exact default version
versions/VERSION/     the release archive of VERSION, unpacked as published
versions/VERSION/channel
                      one line: stable or unstable
index/seen            the signed time of the newest release index accepted
cache/                the module cache (spec/tools/atmosphere.md)
lock                  locked exclusively while a command changes the home
```

Every change ends in a rename. `install` unpacks into a directory under `versions/` whose name starts with a dot, then renames it to `versions/VERSION`. `use` creates the new `bin/lus` under a temporary name and renames it over the old one. A directory under `versions/` whose name starts with a dot is never a version. `install`, `use`, and `remove` hold an exclusive lock on `lock` while they run.

The official installers lay a fresh installation out the same way, so `lus version` manages it.

## The release index

The release index is at `https://lus.dev/releases/index.json`. Its key list is at `https://lus.dev/releases/keys.json`. The environment variable `LUS_RELEASE_URL` replaces `https://lus.dev/releases/` with another base URL. Both addresses may redirect to any `https` URL.

Both files are signed documents. A _signed document_ is canonical JSON, which is UTF-8 with keys sorted by byte value and no insignificant whitespace. It has a `key` field that names the signing key, a `signed` field with the time of signing as `YYYY-MM-DDTHH:MM:SSZ`, and a `signature` field. The signature is the Ed25519 signature, in base64, of the canonical JSON of the document without its `signature` member. A client verifies it over the bytes it received after removing the top-level `signature` member and the comma before it.

The key list has `"key": "root"`. The root key of the Lus release process signs it. Each binary embeds the public half of that root key. Its `keys` field lists the signing keys, each an object with `id`, `public` (the base64 of the 32-byte Ed25519 public key), `not_before`, and `not_after`.

A key of the list signs the index. The `signed` time of the index must fall within that key's period. Its payload has these fields.

```json
{"channels":{"stable":"2.0.3","unstable":"2.1.0-unstable.7"},"key":"lus-release-1","releases":[{"assets":{"aarch64-macos":{"sha256":"9f2c...","size":4194304,"url":"https://github.com/lus-lang/lus/releases/download/v2.0.3/lus-v2.0.3-aarch64-macos.tar.gz"}},"channel":"stable","published":"2027-02-01T12:00:00Z","version":"2.0.3"}],"schema":1,"signature":"...","signed":"2027-02-01T12:05:00Z"}
```

- `channels` names the newest version of each channel.
- `releases` lists every release with its version, its channel, its time of publication, and its archives by target. An archive has a URL, the lowercase hexadecimal SHA-256 digest of its bytes, and its size in bytes.
- The targets are `aarch64-macos`, `x86_64-macos`, `aarch64-linux-musl`, `x86_64-linux-musl`, `arm-linux-musleabihf`, `riscv64-linux-musl`, `loongarch64-linux-musl`, `powerpc64le-linux-musl`, `s390x-linux-musl`, `x86_64-freebsd`, `aarch64-freebsd`, `x86_64-windows`, and `aarch64-windows`. The Linux builds are static, so every Linux system uses the `linux-musl` archive. An archive for Windows is a zip file. Every other archive is a gzip-compressed tar file.

`install` installs nothing unless every check below passes.

1. The key list verifies under the embedded root key.
2. The index verifies under a key of the list, within that key's period.
3. The `signed` time of the index is not older than the time in `index/seen`. The client then records the new time. This refuses an old index that an attacker replays to hold a user on a release with a known flaw.
4. The downloaded archive has the size and the SHA-256 digest that the index gives.
5. The unpacked archive holds `bin/lus`, or `bin\lus.exe` on Windows.

For a release URL whose host is `127.0.0.1`, `::1`, or `localhost`, the variable `LUS_RELEASE_KEY` replaces the embedded root key with the base64 public key it holds. Such a URL may use `http`. Tests use this. A release URL on any other host ignores `LUS_RELEASE_KEY`.
