# Compile-time values

_Status: implemented._

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

A meta variable whose value is `nil`, a boolean, an integer, a float, or a string is a compile-time constant in the sense of `<const>` (`grammar.md`, section 4.2), so it occupies no register. A meta variable that holds a table, a vector, a bigint, or a decimal occupies a register loaded with the constant. Under the debugger every meta variable occupies a register, so the debugger can show it, as it does for `<const>`.

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
- field reads from a meta table, a known string, or the constant fields `math.pi`, `math.huge`, `math.maxinteger`, `math.mininteger`, and `utf8.charpattern`,
- calls of pure library functions whose arguments are all known at compile time.

A _pure library function_ computes its result from its arguments alone, with no side effect and no dependence on the locale. The set is fixed:

- `string.byte`, `char`, `find`, `format`, `gsub`, `join`, `len`, `lower`, `ltrim`, `match`, `rep`, `reverse`, `rtrim`, `split`, `sub`, `trim`, and `upper`,
- `math.abs`, `acos`, `asin`, `atan`, `ceil`, `cos`, `deg`, `exp`, `floor`, `fmod`, `frexp`, `ldexp`, `log`, `max`, `min`, `modf`, `rad`, `sin`, `sqrt`, `tan`, `tointeger`, `type`, and `ult`,
- `utf8.char`, `codepoint`, `len`, and `offset`,
- `tonumber`, `tostring`, and `type`.

The library must be the global name, not a local that hides it. A method call on a known string, such as `("a,b"):split(",")`, calls the `string` function of the same name, so it is known when its arguments are. A call of any other function is never known at compile time.

```lus nocheck
if (flags.features or ""):find("sqlite", 1, true) then
    store = require("store.sqlite")
else
    store = require("store.memory")
end
```

A folded `if` compiles the block of the clause that is true and checks the other blocks without compiling them. A condition that is not known at compile time compiles as an ordinary `if`, with no error and no warning.

Folding keeps run-time behavior. A condition whose evaluation raises an error does not fold, so it raises when the program runs it. `and` and `or` fold when the left operand decides the result or when both operands fold. A condition that only literals and flags decide folds in the compiler itself. Any other known condition runs in the meta state, which evaluates it with the same operations as the running program.

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

A chunk that the command compiles before the program starts takes the `-P` grants: the main chunk, the modules of the require index, and every chunk of `lus build` and `lus compile`, which accepts `-P` for this purpose. A chunk compiled while the program runs takes the permissions of the program at that moment: a chunk of `load`, `loadfile`, or `dofile`, and a module that `require` compiles outside the index.

Paths in an initializer resolve against the current directory of the compiling process, as they do at run time.

## 6. Reproducibility

A meta value is a function of its source, the flags, the runtime version, and whatever its initializer reads. `math.random` in the meta state starts from a fixed seed, so an initializer that draws random numbers produces the same values on every build.

Lus caches compiled chunks only within a process: the require index compiles each module once per process (`modules.md`, section 2). A script run with `lus script.lus` therefore evaluates its meta initializers on every start, as it would evaluate the same code at run time. `lus build` and `lus compile` evaluate them once, at build time.

A later version may record each input that an initializer reads from outside the source, such as the path and digest of every file it opens, as the key of an on-disk cache of compiled chunks and as the list of files a build system watches.

## 7. Builds, binary chunks, and ahead-of-time compilation

`lus build` and `lus compile` evaluate meta initializers once, at build time. The executable or the binary chunk holds the values, so the program never runs the initializers.

Binary chunks have two constant kinds for meta values, the read-only table and the read-only vector, in format version 5. A table constant is stored as a graph of numbered tables, which keeps sharing and cycles between tables. A vector that a table graph holds twice loads as two vectors with the same bytes. `string.dump` writes the same constants, so a dumped function that reads `CRC32` loads with the table. A chunk of format version 4 still loads.

A future `lus build --aot` compiles the program ahead of time. Meta values are constants for that compiler, and read-only tables let it fold reads with constant keys. Meta initializers run in the interpreter of the build machine before ahead-of-time compilation starts, so both compilers see the same values.

## 8. Tools and errors

An error raised by an initializer is a compile error of the chunk. Its message carries the position of the failing line in the original file, the word `meta`, and the error message.

```
config.lus:14: meta: schema.json: No such file or directory
```

A name that is not known at compile time and a value that is not a meta value are compile errors with their own messages: `meta: 'x' is not known at compile time`, `meta value is a function`, and `meta value contains a function at [3].parse`.

An initializer that never ends runs until the user interrupts the compilation. On POSIX systems the meta state has a count hook that checks for SIGINT every 100000 instructions, so an interrupt stops the build with `config.lus:5: meta: interrupted`, the position of the line that was running.

A meta error in the main chunk stops `lus` before the program starts. A meta error in a module of the require tree is raised at the `require` of that module, as every other compile error of an indexed module is (`modules.md`, section 2).

The compiler never evaluates a meta initializer in a block that folding discards. It checks such code without running it. An `if` that selects code for one platform may therefore contain meta initializers that read files present only on that platform.

`lus check`, `lus fmt`, `lus ast`, `debug.parse`, `debug.format`, and the language server never run meta initializers or meta conditions, because opening or checking a file must not execute it. They check the initializer as ordinary code. `lus --dis` lists meta constants with the other constants.

Each chunk that evaluates something at compile time gets a fresh meta state, and the evaluations of one chunk share it in source order. One chunk's initializers therefore never see globals that another chunk's initializers left behind. The order in which the require index compiles modules cannot change a result either. A load of a short chunk took 1.2 µs without compile-time evaluation and 25 µs with one meta local or one folded call, in a ReleaseFast build on an Apple silicon Mac, and the difference is the creation of the meta state. A chunk without either creates no state and compiles as fast as before.
