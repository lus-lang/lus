# Compile-time evaluation

_Status: proposal for review. Nothing in this note is implemented yet. The open questions at the end each list choices with a recommendation._

A _comptime expression_ is an expression that the compiler evaluates while it compiles the chunk. Its value goes into the compiled chunk as a constant. Compile-time evaluation moves work that depends only on the source, the build flags, and files known at build time out of every run and into the compilation. It builds lookup tables once, embeds data files in a chunk or an executable, and selects code by conditions that a flag alone cannot express.

## 1. Syntax

The keyword `comptime` has two forms.

The expression form `comptime EXP` is a simple expression, with the priority of a unary operator. Its operand is evaluated at compile time. A do expression gives the expression form a body of statements, so `comptime do ... provide v end` computes a value with loops and temporary variables. The expression form is also a statement when its operand is a call, which makes compile-time assertions possible.

```lus nocheck
local CRC32 <const> = comptime do
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
comptime assert(#CRC32 == 255)
```

The statement form `comptime if COND then ... elseif COND then ... else ... end` evaluates each condition at compile time, in order, until one is true. The compiler compiles the block of that clause alone. Every other block is parsed and checked, then discarded, as a folded flag condition already is (`grammar.md`, section 5.11).

```lus nocheck
comptime if (flags.features or ""):find("sqlite", 1, true) then
    store = require("store.sqlite")
else
    store = require("store.memory")
end
```

`comptime` becomes a reserved word. No Lus file, manual page, or note in the repository uses it as an identifier.

We chose a keyword over an attribute such as `local x <comptime> = ...` because conditional code and assertions are statements, which an attribute on a variable cannot express. The expression form also composes with every place an expression goes, such as a table constructor field or an argument.

## 2. What comptime code can see

Comptime code runs before the chunk runs, so it sees none of the chunk's run-time values. A name inside comptime code resolves to one of the following.

- A local of the comptime code itself, such as `t` and `c` in the CRC example.
- A `<const>` local of the enclosing chunk whose value is known at compile time. A `<const>` local is known at compile time when its initializer is a literal, a comptime expression, or an arithmetic or concatenation of known values.
- `flags`, the build flags of the compilation.
- A global of the _comptime environment_, a fresh global table holding the standard library.

A name that resolves to any other local of the enclosing chunk is a compile error, `'x' is not known at compile time`. A comptime expression nested inside comptime code adds nothing and compiles as its operand.

## 3. What comptime code may produce

The value of a comptime expression becomes a constant of the compiled chunk, so it must have a representation in a binary chunk. A _comptime value_ is one of the following.

- `nil`, a boolean, a number of any subtype, or a string.
- A vector, which the chunk holds as a read-only vector. This carries binary files, which strings cannot hold.
- A table whose keys and values are comptime values. The chunk holds it as a read-only table, the same kind of table that `flags` is. Two references to one table stay one table, and cycles are kept.

Any other value, including a function, a coroutine, userdata, an enum value, and a table with a metatable, is a compile error that names its type and the path to it, such as `comptime value contains a function at [3].parse`.

A constant table is built once, when the chunk loads, and every evaluation of the expression returns that same table. A function containing `CRC32[i]` in a hot loop therefore reads a table that no code can change, which lets the optimizing tier and a future ahead-of-time compiler fold a read with a constant key to its value. Workers and states each load the chunk and build their own copy, so no table crosses a state.

## 4. Permissions

Comptime code runs in a _comptime state_, a fresh state with the standard library and a pledge store of its own. The comptime code calls `pledge` like any chunk. The limit is the set of grants for the compilation. A `pledge` of anything outside it returns `false`. With no grants for the compilation, every `pledge` returns `false`, so comptime code computes from its source and its flags only.

The following chunk embeds a JSON schema. The comptime code pledges `fs:read` for the schema.

```lus nocheck
local SCHEMA <const> = comptime do
    pledge("fs:read=schema.json")
    local f <close> = assert(io.open("schema.json"))
    provide fromjson(f:read("a"))
end
```

The build command line grants that permission to the compilation. The option name follows the recommendation of question Q1.

```bash
lus build --comptime-pledge fs:read=./schema.json -o validate validate.lus
```

Paths in comptime code resolve against the current directory of the compiling process, as they do at run time. The executable carries the parsed schema, so it needs no permission and no file to run.

Section 9 asks where the grants for the compilation come from. The decision affects `lus build`, whose `-P` options become the run-time limit of the executable.

## 5. Relation to build flags

Comptime code reads `flags` as a read-only table. Flag folding becomes one case of compile-time evaluation: a plain `if` whose condition the flags decide alone compiles as `comptime if` would. A plain `if` folds silently when it can and compiles normally when it cannot. `comptime if` requires its condition to be known at compile time and reports an error otherwise. It is therefore the form for conditions that must fold, and for conditions that call functions, such as the feature list above.

Flags stay the only input from the command line. Comptime code that needs a setting reads a flag, which keeps every input of a build visible on its command line.

## 6. Reproducibility and caching

A comptime expression is a function of its source, the flags, the runtime version, and whatever its I/O reads. The comptime state records each input that comes from outside the source: every file it opens with its path, length, and SHA-256 digest, every environment variable it reads, and every network request. Reading the clock, seeding `math.random` from the clock, and a network request mark the result as unrepeatable.

`math.random` in the comptime state starts from a fixed seed, so a comptime expression that draws random numbers produces the same table on every build.

Lus caches compiled chunks only within a process: the require index compiles each module once per process (`modules.md`, section 2). A script run with `lus script.lus` therefore evaluates its comptime expressions on every start, as it would evaluate the same code at run time. The input record is the key that a future on-disk cache of compiled chunks needs. Such a cache reuses a chunk when its source, flags, runtime version, and every recorded input are unchanged. It never caches an unrepeatable result.

`lus build --inputs` prints the record of a build, one input per line, so a build system can rebuild an executable when an embedded file changes.

## 7. Builds, binary chunks, and ahead-of-time compilation

`lus build` and `lus compile` evaluate comptime code once, at build time. The executable or the binary chunk holds the values, so the program never runs its comptime code and never needs the permissions that the comptime code pledged.

Binary chunks gain two constant kinds, the read-only table and the read-only vector. A table constant is stored as a graph of numbered nodes, which keeps sharing and cycles. `string.dump` writes the same constants, so a dumped function that reads `CRC32` loads with the table. The format version of binary chunks increases by one. A chunk of the earlier version still loads.

A future `lus build --aot` compiles the program ahead of time. Comptime values are constants for that compiler. Read-only tables let it fold reads with constant keys. Comptime evaluation runs in the interpreter of the build machine before ahead-of-time compilation starts, so both compilers see the same values.

## 8. Tools and errors

An error raised by comptime code is a compile error of the chunk. Its message carries the position of the failing line in the original file, the word `comptime`, and the error object, followed by the traceback of the comptime state.

```
config.lus:14: comptime: schema.json: No such file or directory
stack traceback:
    config.lus:14: in comptime expression
```

A comptime error in the main chunk stops `lus` before the program starts. A comptime error in a module of the require tree is raised at the `require` of that module, as every other compile error of an indexed module is (`modules.md`, section 2). A value that is not a comptime value, and a name that is not known at compile time, are compile errors with their own messages (sections 2 and 3).

The compiler never evaluates comptime code in a block that folding discards. It compiles such code for checking only. A `comptime if` that selects code for one platform may therefore read files that exist only on that platform.

The language server, `lus check`, `lus fmt`, `lus doc`, `lus ast`, and `debug.parse` never run comptime code, because opening or checking a file must not execute it. The language server treats the value of a comptime expression as unknown and checks the comptime code as ordinary code in the comptime environment. `lus --dis` lists comptime constants with the other constants.

A comptime state starts in about 16 µs (`snapshot.md` measured 1.8 µs for a later `lus_newstate` and 14.5 µs for `lus_openlibs`), so each chunk with comptime code gets a fresh state. One chunk's comptime code therefore never sees globals that another chunk's comptime code left behind. The order in which the require index compiles modules cannot change a result either. A chunk without comptime code creates no state and compiles as fast as before.

## 9. Open questions

**Q1. Where do the grants for compile-time code come from?**

- **(a) A separate option, `--comptime-pledge PERM`, on `lus`, `lus build`, and `lus compile` (recommended).** `-P` keeps its meaning as the run-time limit. A build that reads a schema at compile time does not hand `fs:read` to the executable it produces.
- (b) The `-P` options of the compiling command. `lus script.lus` uses one set for both phases. For `lus build`, `-P` grants both the comptime code and the executable, so the executable keeps every permission its build needed.
- (c) `-P` with a phase prefix, such as `-P comptime:fs:read=./schema.json`.

**Q2. What may comptime code do with no grants at all?**

- **(a) Pure computation only (recommended).** Every `pledge` returns `false`. A build without grants is a function of its source and flags.
- (b) Read files under the directory of the compiled chunk. Embedding a neighbouring file then needs no option, at the cost of builds that read files nobody granted.

**Q3. What do comptime expressions get inside `load` at run time?**

- **(a) No grants (recommended).** A chunk compiled by a running program evaluates its comptime code as pure computation, whatever the program's own permissions are.
- (b) The current permissions of the program that calls `load`.
- (c) `load` rejects a chunk that contains comptime code unless an option of `load` allows it.

**Q4. Which values may comptime code produce?**

- **(a) The values of section 3: nil, booleans, numbers, strings, read-only vectors, and read-only tables of these (recommended).**
- (b) Section 3 without vectors. Binary files then travel as strings, which hold only valid WTF-8.
- (c) Section 3 plus functions without upvalues, compiled into the chunk as nested functions. Comptime code could then generate code, which brings a code generator into the language and makes an error in generated code hard to trace to its source.

**Q5. How does comptime code end when it does not terminate?**

- **(a) It runs until it ends or the user stops the build (recommended).** Interrupting `lus build` reports the position of the comptime code that was running.
- (b) A budget of executed instructions, one billion by default, that an option raises. A build stops with an error instead of hanging, at the cost of another option.

**Q6. Which syntax?**

- **(a) The keyword `comptime` with the expression form and `comptime if` (recommended).** Section 1 describes both.
- (b) The expression form only. Conditional code uses `if comptime COND then`, which folds because its condition is a constant. An `if` that fails to fold then compiles silently as a run-time test, which hides mistakes.
- (c) An attribute, `local x <comptime> = EXP`, plus `comptime if`. Values computed at compile time can only initialize locals.
