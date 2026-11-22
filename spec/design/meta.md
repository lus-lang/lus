# Compile-time values

_Status: design accepted, implementation pending._

A _meta variable_ is a local declared with the `<meta>` attribute. The compiler evaluates its initializer while it compiles the chunk and puts the value into the compiled chunk as a constant. Compile-time evaluation moves work that depends only on the source, the build flags, and files known at build time out of every run and into the compilation. It builds lookup tables once, embeds data files in a chunk or an executable, and computes conditions that select code.

## 1. Syntax

`<meta>` is an attribute of a local declaration, like `<const>` and `<close>`. A do expression gives the initializer a body of statements.

```lus nocheck
local CRC32 <meta> = do
    local t = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
        end
        t[i] = c
    end
    provide t
end
```

A `<meta>` declaration names one variable and has one initializer. A meta variable is read-only, so `<meta>` implies `<const>`. Writing `<const, meta>` is accepted and means the same. An assignment to a meta variable raises `attempt to assign to const variable 'CRC32'` at compile time. `<meta>` cannot be combined with `<close>`, `<group>`, or a runtime attribute, because each of those acts when the program runs. Each combination is a compile error. A global cannot be `<meta>`.

A meta variable whose value is `nil`, a boolean, a number, or a string is a compile-time constant in the sense of `<const>` (`grammar.md`, section 4.2), so it occupies no register. A meta variable that holds a table or a vector occupies a register loaded with the constant.

## 2. What the initializer can see

The initializer runs before the chunk runs, so it sees none of the chunk's run-time values. A name inside the initializer resolves to one of the following.

- A local of the initializer itself, such as `t` and `c` in the CRC example.
- A meta variable declared earlier.
- A `<const>` local of the enclosing chunk that is a compile-time constant.
- `flags`, the build flags of the compilation.
- A global of the _meta environment_, a fresh global table holding the standard library.

A name that resolves to any other local of the enclosing chunk is a compile error, `'x' is not known at compile time`.

## 3. What a meta variable may hold

The value of the initializer becomes a constant of the compiled chunk, so it must be data that a binary chunk can store. A _meta value_ is one of the following.

- `nil`, a boolean, a number of any subtype, or a string.
- A vector, which the chunk holds as a read-only vector. This carries binary files, which strings cannot hold.
- A table whose keys and values are meta values. The chunk holds it as a read-only table, the same kind of table that `flags` is. Two references to one table stay one table, and cycles are kept.

Any other value, including a function, a coroutine, userdata, an enum value, and a table with a metatable, is a compile error that names its type and the path to it, such as `meta value contains a function at [3].parse`.

A table constant is built once, when the chunk loads, and every evaluation of the variable reads that same table. A function containing `CRC32[i]` in a hot loop therefore reads a table that no code can change, which lets the optimizing tier and a future ahead-of-time compiler fold a read with a constant key to its value. Workers and states each load the chunk and build their own copy, so no table crosses a state.

## 4. Conditional code

A plain `if` folds when its condition is known at compile time, which extends the folding of build flags (`grammar.md`, section 5.11). A condition is known at compile time when it is built from the following, combined with comparisons, `and`, `or`, `not`, arithmetic, concatenation, `#`, and parentheses:

- literals,
- flag reads,
- meta variables and `<const>` locals that are compile-time constants,
- field reads with a constant key from a meta table, such as `CONFIG.mode`.

A folded `if` compiles the block of the clause that is true and checks the other blocks without compiling them. A condition that is not known at compile time compiles as an ordinary `if`, with no error and no warning. A call is never known at compile time, so a condition that needs one computes it in a meta variable first.

```lus nocheck
local SQLITE <meta> = (flags.features or ""):find("sqlite", 1, true) ~= nil

if SQLITE then
    store = require("store.sqlite")
else
    store = require("store.memory")
end
```

Folding keeps run-time behavior. A comparison or an arithmetic operation that would raise an error at run time does not fold, so it raises when the program runs it. `and` and `or` fold when the left operand decides the result or when both operands fold.

## 5. Permissions

The initializer runs in a _meta state_, a fresh state with the standard library and a pledge store of its own. It calls `pledge` like any chunk. The limit is the set of `-P` grants of the command that compiles the chunk, which is the same set that limits the program when it runs. A `pledge` of anything outside the grants returns `false`. Without any `-P` grant, every `pledge` in the initializer returns `false`, so the initializer computes from its source and its flags only.

The following chunk embeds a JSON schema. The initializer pledges `fs:read` for the schema.

```lus nocheck
local SCHEMA <meta> = do
    pledge("fs:read=schema.json")
    local f <close> = assert(io.open("schema.json"))
    provide fromjson(f:read("a"))
end
```

The build command line grants that permission.

```bash
lus build -Pfs:read=./schema.json -o validate validate.lus
```

`lus build` stores its `-P` grants in the executable as the limit of every run, so the executable keeps every permission that its build needed. The executable above can therefore read `schema.json` when it runs, although it carries the parsed schema and never reads the file. A program that must not keep a permission its build needed reads the file in a separate build step and embeds the result.

`load` at run time evaluates the meta initializers of the chunk it compiles with the permissions of the program at the call of `load`.

Paths in an initializer resolve against the current directory of the compiling process, as they do at run time.

## 6. Reproducibility and caching

A meta value is a function of its source, the flags, the runtime version, and whatever its I/O reads. The meta state records each input that comes from outside the source: every file it opens with its path, length, and SHA-256 digest, every environment variable it reads, and every network request. Reading the clock, seeding `math.random` from the clock, and a network request mark the result as unrepeatable.

`math.random` in the meta state starts from a fixed seed, so an initializer that draws random numbers produces the same table on every build.

Lus caches compiled chunks only within a process: the require index compiles each module once per process (`modules.md`, section 2). A script run with `lus script.lus` therefore evaluates its meta initializers on every start, as it would evaluate the same code at run time. The input record is the key that a future on-disk cache of compiled chunks needs. Such a cache reuses a chunk when its source, flags, runtime version, and every recorded input are unchanged. It never caches an unrepeatable result.

`lus build --inputs` prints the record of a build, one input per line, so a build system can rebuild an executable when an embedded file changes.

## 7. Builds, binary chunks, and ahead-of-time compilation

`lus build` and `lus compile` evaluate meta initializers once, at build time. The executable or the binary chunk holds the values, so the program never runs the initializers.

Binary chunks gain two constant kinds, the read-only table and the read-only vector. A table constant is stored as a graph of numbered nodes, which keeps sharing and cycles. `string.dump` writes the same constants, so a dumped function that reads `CRC32` loads with the table. The format version of binary chunks increases by one, and a chunk of the earlier version still loads.

A future `lus build --aot` compiles the program ahead of time. Meta values are constants for that compiler, and read-only tables let it fold reads with constant keys. Meta initializers run in the interpreter of the build machine before ahead-of-time compilation starts, so both compilers see the same values.

## 8. Tools and errors

An error raised by an initializer is a compile error of the chunk. Its message carries the position of the failing line in the original file, the word `meta`, and the error object, followed by the traceback of the meta state.

```
config.lus:14: meta: schema.json: No such file or directory
stack traceback:
    config.lus:14: in meta initializer of 'SCHEMA'
```

An initializer that never ends runs until the user interrupts the compilation. The interrupt stops the build with an error that gives the position the initializer was running, in the same form.

A meta error in the main chunk stops `lus` before the program starts. A meta error in a module of the require tree is raised at the `require` of that module, as every other compile error of an indexed module is (`modules.md`, section 2). A value that is not a meta value, and a name that is not known at compile time, are compile errors with their own messages (sections 2 and 3).

The compiler never evaluates a meta initializer in a block that folding discards. It checks such code without running it. An `if` that selects code for one platform may therefore contain meta initializers that read files present only on that platform.

The language server, `lus check`, `lus fmt`, `lus doc`, `lus ast`, and `debug.parse` never run meta initializers, because opening or checking a file must not execute it. The language server treats a meta value as unknown and checks the initializer as ordinary code in the meta environment. `lus --dis` lists meta constants with the other constants.

A meta state starts in about 16 µs (`snapshot.md` measured 1.8 µs for a later `lus_newstate` and 14.5 µs for `lus_openlibs`), so each chunk with meta variables gets a fresh state, and the initializers of one chunk share it in declaration order. One chunk's initializers therefore never see globals that another chunk's initializers left behind. The order in which the require index compiles modules cannot change a result either. A chunk without meta variables creates no state and compiles as fast as before.
