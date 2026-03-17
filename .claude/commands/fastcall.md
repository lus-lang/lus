Add the following stdlib function(s) as VM-intrinsified fastcall(s): $ARGUMENTS

Follow these steps precisely for each function listed. If multiple functions are requested, repeat steps 3-10 for each one.

## 1. Parse the request

Identify from `$ARGUMENTS`:
- **Function name** (e.g. `floor` from `math.floor(x)`)
- **Module** (e.g. `math`, `string`, `table`, or base lib if no module prefix)
- **Argument count** (count the parameters in the signature)
- **C function pointer name** — look it up in the corresponding `luaopen_*` function in `lus/src/l{module}lib.c` (or `lbaselib.c` for base lib). Find the function in the `luaL_Reg` array to get the C name.

## 2. Read current state

Read `lus/src/lfastcall.h` to find:
- The current `FC_COUNT` position
- The existing enum values (to determine where to insert the new one)

Also read `lus/src/lfastcall.c`, the relevant `lus/src/l{module}lib.c`, and the OP_FASTCALL switch in `lus/src/lvm.c` to understand the existing patterns.

## 3. Add enum value to `lus/src/lfastcall.h`

Add a new enum value **before** `FC_COUNT` in the `FastCallId` enum:
- For base lib functions: `FC_{NAME}` (e.g. `FC_TOSTRING`)
- For module functions: `FC_{MODULE}_{NAME}` (e.g. `FC_MATH_FLOOR`)

Group it with other entries from the same module.

## 4. Initialize strings in `lus/src/lfastcall.c`

Add string initialization in `luaF_initfastcalls()`:

**For base lib functions** — add in the base library block:
```c
s = luaS_new(L, "funcname");
luaC_fix(L, obj2gco(s));
g->fastcall_table[FC_NAME].func_name = s;
```

**For module functions** — add in the appropriate module block. Reuse the existing `mod` TString if the module already has fastcalls. If this is the first fastcall for a new module, create a new block:
```c
/* {Module} library functions */
{
  TString *mod = luaS_new(L, "modulename");
  TString *s;
  luaC_fix(L, obj2gco(mod));

  g->fastcall_table[FC_MODULE_NAME].module_name = mod;

  s = luaS_new(L, "funcname");
  luaC_fix(L, obj2gco(s));
  g->fastcall_table[FC_MODULE_NAME].func_name = s;
}
```

For existing modules, just add the `module_name` assignment and the `func_name` init alongside the existing entries.

## 5. Enable for compiler in `lus/src/lfastcall.c`

Add a line in `luaF_enablefastcalls()`:
```c
g->fastcall_table[FC_NEW].nargs = N;
```

The argument count **must** match what you use in step 7's `luaF_registerfastcall()` call and the number of args the VM case expects.

## 6. Add VM inline case in `lus/src/lvm.c`

Add a `case FC_NEW:` in the OP_FASTCALL switch (before the `default:` case). Follow these rules strictly:

- Extract arguments from stack: `TValue *arg = s2v(ra + 1);` (first arg), `s2v(ra + 2)` (second), etc.
- Type-check inputs. Use `goto fc_fallback;` on type errors so the original C function handles the error message.
- Implement the operation inline, matching the semantics of the original C function exactly.
- **CRITICAL: Always wrap if/else bodies containing macros in `{}` braces.** Macros like `setivalue`, `setfltvalue`, `setbfvalue`, `setbtvalue` expand to compound statements `{ ... }` — bare if/else with these will miscompile.
- Use `Protect()` around any operation that can trigger GC (e.g. `luaS_new`, `luaH_set`, `luaH_getstr`).
- Use `luaC_barrierback(L, obj2gco(hvalue(table_tvalue)), value)` after mutating table contents.
- Write the result to `s2v(ra)`.
- End the case with `vmbreak;`.

Example pattern for a numeric function:
```c
case FC_MATH_FLOOR: {
  TValue *arg = s2v(ra + 1);
  if (ttisinteger(arg)) {
    setivalue(s2v(ra), ivalue(arg));
  } else if (ttisfloat(arg)) {
    lua_Number f = l_mathop(floor)(fltvalue(arg));
    lua_Integer i;
    if (luaV_flttointeger(f, &i, F2Ieq)) {
      setivalue(s2v(ra), i);
    } else {
      setfltvalue(s2v(ra), f);
    }
  } else {
    goto fc_fallback;
  }
  vmbreak;
}
```

## 7. Register in library open function

In the appropriate `luaopen_*` function (`lus/src/lbaselib.c`, `lus/src/lmathlib.c`, `lus/src/lstrlib.c`, etc.), add a `luaF_registerfastcall()` call alongside the existing ones:
```c
luaF_registerfastcall(L, FC_NEW, c_function_name, nargs);
```

Also ensure the file includes `#include "lfastcall.h"` (it should already if the module has existing fastcalls).

## 8. Add tests to `lus-tests/h1/fastcall.lus`

Append tests **before** the final `tests:finish()` line. Add three categories of tests:

**Correctness test** — representative inputs and edge cases:
```lus
-- ==== Correctness: module.func() ====
tests:it("module.func correctness", function()
    assert(module.func(input1) == expected1)
    assert(module.func(input2) == expected2)
    -- edge cases...
end)
```

**Environment tainting fallback test** — verifies the VM falls back when the function is replaced:
```lus
-- ==== Environment tainting: module.func ====
tests:it("tainted module.func fallback", function()
    local custom_called = false
    local env = setmetatable({
        module = {
            func = function(...)
                custom_called = true
                return "custom"
            end,
        },
    }, {__index = _G})
    local chunk = load("return module.func(arg)", "test", "t", env)
    local result = chunk()
    assert(result == "custom")
    assert(custom_called)
end)
```

For base lib functions, replace the module table with a direct function binding in the env table.

**Type-error fallback test** (if the function can receive wrong types):
```lus
tests:it("module.func type error fallback", function()
    local ok, err = catch(function() return module.func({}) end)()
    assert(not ok, "module.func({}) should error")
end)
```

Make sure any new globals needed (like `catch`) are declared in the `global` line at the top of the file.

## 9. Mark spec file

Edit `lus-spec/stdlib/{module}/{function}.md` and add `fastcall: true` to the YAML frontmatter (after the `origin:` line). If the spec file doesn't exist, warn the user.

## 10. Update changelog

In `CHANGELOG.md`, find the fastcalls bullet list under the current version's `### Fastcalls` section. Add the new function to the list in the appropriate position (base lib functions first, then by module alphabetically):
```markdown
  - `module.func(args)`
```

## 11. Build and test

Run:
```sh
meson compile -C lus/build && meson test -C lus/build --suite h1
```

If the build fails, read the errors carefully and fix. Common issues:
- Missing `{}` braces around macro-containing if/else bodies
- Wrong argument count mismatch between `enablefastcalls`, `registerfastcall`, and the VM case
- Missing `#include "lfastcall.h"` in the library file
- Forgetting `Protect()` around GC-allocating calls

If tests fail, run the specific test to see output:
```sh
meson test -C lus/build h1/fastcall
```

## 12. Report

List all files modified and summarize what was added.
