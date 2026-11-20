# Porting map

Common dependencies and idioms, with the Lus feature that covers each. Check a row against the reference before relying on it, since behavior details differ.

| Original | Lus |
| --- | --- |
| Python `json`, Node `JSON`, Go `encoding/json` | `fromjson`, `tojson`. JSON null maps to `nil`. Pass `{ exact = true }` for big integers and exact decimals. |
| Python `csv`, `csv-parse` | `fromcsv`, `tocsv` |
| `sqlite3`, `better-sqlite3` | `io.sqlite(path)`, `db:run(sql, ...)`, and queries over database tables |
| `requests`, `fetch`, `axios`, `net/http` client | `network.fetch(url, method, headers, body)`. The body is a vector, decoded with `vector.tostring`. |
| Express, Flask, `net/http` server | `network.serve(host, port, handler)`. The handler returns `status, body, headers`. |
| `asyncio`, promises, callbacks around sockets | sequential code in `coroutine.detach`. Socket calls suspend only the calling coroutine. |
| `multiprocessing`, worker threads | `worker.create(file, args)`, `worker.send`, `worker.receive` |
| `gzip`, `zlib`, `zstandard`, `brotli` | `vector.archive.gzip`, `deflate`, `zstd`, `brotli`, `lz4` |
| `datetime` with `zoneinfo`, Luxon, `time` | `time.now()`, `time.zone(name)`, durations such as `time.hours(n)` |
| `decimal.Decimal`, big integers | `1.50d` decimals, `123n` bigints |
| `os.path`, `pathlib`, `fs` | `fs.path.join`, `fs.path.name`, `fs.path.parent`, `fs.list`, `fs.type` |
| `subprocess` | `io.popen(cmd)` and `os.execute(cmd)` under the `exec` permission |
| environment variables | `os.getenv(name)` under the `env` permission |
| `pytest`, Jest, `go test` | `lus test` with `*_test.lus` files, case tables, and snapshots |
| Black, Prettier, `gofmt` | `lus fmt --write` |
| flake8, ESLint, `go vet` | `lus check` |
| PyInstaller, `pkg`, a container image for one tool | `lus build app.lus -o app -P PERM` |
| a sandbox, a seccomp profile, a review checklist for file and network access | `pledge(...)` then `pledge("seal")` |

## Idioms that change shape

- Exceptions become values at the boundary. `try` blocks become `local ok, err = catch f()`. Raise with `error(value)`, where the value can be a table that carries fields.
- Classes become tables with metatables, as in Lua. Keep the original class boundaries so the harness maps onto familiar units.
- Zero-based indexing becomes one-based. Port index arithmetic carefully and give it its own unit tests.
- Byte strings become vectors and text strings stay strings. Decide the type of every value that crosses an I/O boundary.
- Integer division is `//`, and `/` always produces a float.
