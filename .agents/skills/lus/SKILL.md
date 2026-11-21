---
name: lus
description: Write, run, test, and debug Lus code (.lus files), a Lua 5.5 derived language with permissions, JSON, CSV, SQLite, HTTP, workers, and a built-in test runner, formatter, and checker. Use when a project contains .lus files, when the user mentions Lus or lus.dev, or when asked to write a script, server, or command line tool in Lus.
---

# Writing Lus

Lus is a small language derived from Lua 5.5. One `lus` executable runs scripts and carries every tool a project needs. Lua knowledge transfers, with the differences listed in [references/language.md](references/language.md). Read that file before writing Lus for the first time in a session.

## The loop

Work in short cycles and let the tools judge the code. Every command below is fast enough to run after each edit.

1. `lus check --json FILE...` parses, lints, and compiles without running. Fix every error and every warning. Each diagnostic has a stable `code`, and `lus check --list` explains all of them.
2. `lus fmt --write FILE...` formats in place with 4-space indentation. Run it before showing code to the user.
3. `lus test --json` runs every `*_test.lus` file below the current directory, each in its own process and temporary directory. Write tests alongside the code they cover.
4. `lus -P PERM FILE` runs a script with a permission granted from the command line, which is handy for a quick trial. Real programs pledge in code.

When a run fails, read the first line of the error. It carries `file:line:` and the message. Reproduce the failure in a test before fixing it.

## Every file starts the same way

A script declares the globals it uses at the top of the file, then pledges the permissions it needs, then seals them. A script runs with no permissions until it pledges, so an unpledged call to `fs`, `io`, `network`, `os.getenv`, `os.execute`, or `worker` raises an error that names the missing permission.

```lus nocheck
global fs, network, pledge, print, tojson

pledge("fs:read=./data/*", "network:http")
pledge("seal")
```

Grant the narrowest permission that works. `fs:read=./data/*` beats `fs:read`, which beats `fs`. The permission names are `fs`, `fs:read`, `fs:write`, `fs:exec`, `network`, `network:http`, `network:tcp`, `network:udp`, `network:tls`, `network:server`, `exec`, `env`, `load`, and `worker`. Test files pledge exactly like scripts.

## Reach for the standard library first

Lus ships the libraries most programs pull from a package manager. Use them before writing or vendoring code.

| Need | Use |
| --- | --- |
| JSON | `fromjson(text)`, `tojson(value)` |
| CSV | `fromcsv(text)`, `tocsv(rows)` |
| Files and paths | `fs.list`, `fs.copy`, `fs.move`, `fs.remove`, `fs.path.join` |
| HTTP client | `network.fetch(url, method, headers, body)` returns `status, body, headers` |
| HTTP server | `network.serve(host, port, handler)` |
| Concurrency on one thread | `coroutine.detach(co)`. Sockets suspend the coroutine while others run. |
| Parallelism | `worker.create(file, args)`, `worker.receive(w)` |
| Database | `io.sqlite(path)` and queries |
| Dates and zones | `time.now()`, `time.zone(name)` |
| Bytes and compression | `vector`, `vector.archive.zstd`, `gzip`, `brotli`, `lz4`, `deflate` |
| Hashing and signatures | `crypto.hash`, `crypto.hmac`, `crypto.sign`, `crypto.verify`, `crypto.hashpassword`, `crypto.uuid`. No permission needed. |
| Exact numbers | `123n` bigints, `1.50d` decimals |
| Standalone executable | `lus build app.lus -o app -P network` |

`lus help NAME` prints the signature, required permissions, stability, and description of any function, such as `lus help network.serve`, from documentation built into the installed runtime. `lus help MODULE` lists a module, and `lus help --search TEXT` finds an entry. Functions marked unstable may change between releases. Mention it when you depend on one.

## Idioms the checker expects

- `catch expr` replaces `pcall`. It returns `true` and the results, or `false` and the raw error.
- `local a, b from t` reads fields into locals of the same name.
- `a?.b?.c` stops at the first nil.
- `if x = find() then ... end` and `while line = read() do ... end` scope a variable to the block.
- Backtick strings interpolate: `` `$name is $(age + 1)` ``.
- `continue` skips to the next iteration of a loop.
- Strings are text indexed by character. Raw bytes are vectors, and network and binary file reads return vectors. Decode with `vector.tostring`.

## Testing

A test is a function whose name ends in `_test` in a file whose name ends in `_test.lus`. `assert` in a test file reports the values on both sides of a failed comparison. `snapshot(value)` records a value the first time and compares later runs against the recording, and `lus test -u` accepts a new recording. `raises(fn, text)`, `same(a, b)`, and `skip(reason)` are available in every test file.

```lus
local function slugify(s)
    return (s:lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", ""))
end

function slugify_test()
    assert(slugify("Hello, World!") == "hello-world")
end

function snapshot_test()
    snapshot({ slugify("A b"), slugify("  x  ") })
end
```

## When something is unclear

Prefer the documentation shipped with the installed runtime over memory, since Lus changes between releases. `lus help` answers from that documentation, and `lus --version` prints the version. The full manual is at https://lus.dev/llms-full.txt. `lus agents init` refreshes these skills to match the installed runtime.
