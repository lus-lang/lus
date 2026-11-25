---
name: lus
description: Write, run, test, and debug Lus code (.lus files), a Lua 5.5 derived language with permissions, JSON, CSV, SQLite, HTTP, workers, and a built-in test runner, formatter, and checker. Use when a project contains .lus files, when the user mentions Lus or lus.dev, or when asked to write a script, server, or command line tool in Lus.
---

# Writing Lus

Lus is a small language derived from Lua 5.5. One `lus` executable runs scripts and carries every tool a project needs. Lua knowledge transfers, with the differences listed in [references/language.md](references/language.md). Read that file before writing Lus for the first time in a session.

## The loop

Work in short cycles and let the tools judge the code. Every command below is fast enough to run after each edit.

1. `lus check --json FILE...` parses, lints, and compiles without running. Fix every error and every warning. Each diagnostic has a stable `code`. `lus check --explain CODE` explains one code with an example, and `lus check --list` lists them all. A diagnostic with severity `hint` suggests a faster or shorter form of correct code and never changes the exit status.
2. `lus fmt --write FILE...` formats in place with 4-space indentation. Run it before showing code to the user.
3. `lus test --json` runs every `*_test.lus` file below the current directory, each in its own process and temporary directory. Write tests alongside the code they cover.
4. `lus -P PERM FILE` runs a script with a permission granted from the command line. `lus --sandbox -P PERM FILE` also seals the grants, so the script can pledge nothing beyond them. Run a script you have not read this way. Real programs pledge in code.

`lus lsp` runs the language server over standard input and output, for an editor or a harness that validates code as it is written. `lus tree FILE` prints the modules a script requires, as a tree.

When a run fails, read the first line of the error. It carries `file:line:` and the message. Reproduce the failure in a test before fixing it.

## Every file starts the same way

A script declares the globals it uses at the top of the file, then pledges the permissions it needs, then seals them. A script runs with no permissions until it pledges, so an unpledged call to `fs`, `io`, `network`, `os.getenv`, `os.execute`, or `worker` raises an error that names the missing permission.

```lus nocheck
global fs, network, pledge, print, tojson

pledge("fs:read=./data/*", "network:http")
pledge("seal")
```

Grant the narrowest permission that works. `fs:read=./data/*` beats `fs:read`, which beats `fs`. A grant without a value covers every grant of the same permission with a value, in either order, so `pledge("fs", "fs:read=./data/*")` allows every file access. The permission names are `fs`, `fs:read`, `fs:write`, `fs:exec`, `network`, `network:http`, `network:tcp`, `network:udp`, `network:tls`, `network:server`, `exec`, `env`, `env:read`, `env:write`, `load`, and `worker`. Test files pledge exactly like scripts.

## Reach for the standard library first

Lus ships the libraries most programs pull from a package manager. Use them before writing or vendoring code.

| Need | Use |
| --- | --- |
| JSON | `fromjson(text)`, `tojson(value)` |
| CSV | `fromcsv(text)`, `tocsv(rows)` |
| Files and paths | `fs.list`, `fs.copy`, `fs.move`, `fs.remove`, `fs.path.join` |
| HTTP client | `network.fetch(url, method, headers, body)` returns `status, body, headers` |
| HTTP server | `network.serve(host, port, handler)` |
| Concurrency on one thread | `coroutine.detach(co)`. Sockets and waits suspend the coroutine while others run. |
| Sockets | `network.tcp.connect(host, port, { timeout = 5 })`, `sock:reader(max)`, `sock:starttls(options)` |
| Timers, processes, signals, file changes | `coroutine.sleep(seconds)`, `os.spawn(argv, options)`, `os.signal(name)`, `fs.watch(path, options)` |
| Parallelism | `worker.create(file, args)`, `worker.receive(w)` |
| Database | `io.sqlite(path)` and queries |
| Dates and zones | `time.now()`, `time.zone(name)` |
| Bytes and compression | `vector`, `vector.archive.zstd`, `gzip`, `brotli`, `lz4`, `deflate` |
| Hashing and signatures | `crypto.hash`, `crypto.hmac`, `crypto.sign`, `crypto.verify`, `crypto.hashpassword`, `crypto.uuid`. No permission needed. |
| Exact numbers | `123n` bigints, `1.50d` decimals |
| Standalone executable | `lus build app.lus -o app -P network` |

`lus help NAME` prints the signature, required permissions, stability, and description of any function, such as `lus help network.serve`, from documentation built into the installed runtime. `lus help MODULE` lists a module, and `lus help --search TEXT` finds an entry. Functions marked unstable may change between releases. Mention it when you depend on one.

## Failures and waits

Socket operations and file reads report failures by return value, as Lua files do, and raise only on misuse such as a bad argument or a missing permission. A socket call returns `nil` and an error object with the fields `code` and `message`, such as `"timeout"` or `"refused"`, whose `tostring` is the message. A file read returns `nil`, a message, and the error number. Check the first result before using it. `network.fetch` is the exception and raises its error object.

`coroutine.sleep`, `p.exit` of `os.spawn`, `os.signal`, and `fs.watch` each return a coroutine, and resuming it waits for the next event. Inside a detached coroutine the wait suspends only that coroutine. Closing a sleep wakes its waiter, whose resume returns `false` and `"closed"`, so `coroutine.sleep(math.huge)` parks a coroutine until another one closes the sleep. [references/language.md](references/language.md) shows this park and wake idiom.

## Idioms the checker expects

- `catch expr` replaces `pcall`. It returns `true` and the results, or `false` and the raw error.
- `local a, b from t` reads fields into locals of the same name, and `for a, b from iter() do` does the same for each table an iterator yields.
- `a?.b?.c` stops at the first nil.
- `if x = find() then ... end` and `while line = read() do ... end` scope a variable to the block.
- Backtick strings interpolate, as in `` `$name is $(age + 1)` ``, and take every escape of quoted strings plus `` \` `` and `\$`.
- `continue` skips to the next iteration of a loop.
- `for x in co do` loops over a coroutine: each pass resumes it and binds what it yields, and the loop closes it on `break` or error. `for line in conn.input do` reads a TCP connection line by line, and `for conn in server.accepted do` serves connections.
- `local T <meta> = expr` computes a constant value, such as a lookup table, when the file is compiled. An `if` on `flags`, literals, and `<meta>` locals keeps only the clause that is true, so `if flags.debug then` blocks vanish from builds without `-Fdebug`.
- `local x <lazy> = expensive()` runs the initializer on the first read of `x`, so declare costly values once at the top of the file. `<lazy, close>` opens a resource on first use.
- `local total <observe> = price * qty`, with `price` and `qty` also `<observe>`, recomputes `total` whenever the program assigns `price` or `qty`, from any function. Only assignment updates it, so assign a new table rather than writing a field.
- `local request_id <context> = "none"` gives each coroutine its own value. An assignment changes the value of the running coroutine only, and a new coroutine starts with the values of its creator. A worker starts from the defaults. `debug.getcontext` and `debug.setcontext` read and write the values of another coroutine.
- Strings are text indexed by character. Raw bytes are vectors, and network and binary file reads return vectors. Decode with `vector.tostring`.

## Making code faster

Start with the hints of `lus check`. Each speed hint comes from a measured case and fires only where the checker proves the faster form computes the same result, so apply it. `concat-in-loop` replaces a string grown in a loop with a list joined once by `table.concat`. `insert-front-in-loop` replaces `table.insert(t, 1, v)` in a loop with appends and one reverse. `pairs-over-list` replaces `pairs` with `ipairs` on a list. The other speed hints are `closure-in-loop`, `select-in-loop`, `table-to-group`, `format-to-interpolation`, and `redundant-tostring`. The concise hints, such as `use-for-from` and `use-interpolation`, name a shorter form that costs the same. Apply them when tidying code. A program can run the same check with `debug.check(source)`, which returns each diagnostic as a table with `line`, `column`, `severity`, `code`, and `message`.

Measure before and after a change that no hint suggests, with a test or a short script that times both forms through `os.clock()`.

## Testing

A test is a function whose name ends in `_test` in a file whose name ends in `_test.lus`. `assert` in a test file reports the values of the names and fields on both sides of a failed comparison. A function whose name ends in `_bench` is a benchmark, which `lus test --bench` runs to report its median time, the spread, and the bytes it allocates per call. `snapshot(value)` records a value the first time and compares later runs against the recording, and `lus test -u` accepts a new recording. `raises(fn, text)`, `same(a, b)`, and `skip(reason)` are available in every test file.

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
