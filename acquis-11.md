
# Acquis 11: Permission system

## Description

  - [**Project goal(s):**](https://lus.dev/manual/introduction/#goals) Sovereignty, solving real-world problems
  - Constraints: *none*
  - Dependencies: *none*

## Contents

Lus currently does not have a permission system, which is a problem for sandboxing or safely executing scripts.

To resolve this, the function `pledge` allows the interpreter to request specific permissions from Lus, returning booleans for each permission requested. Permissions can also be globally granted through commandline arguments passed through `--pledge` or `-P`. Granting permissions globally still allows the interpreter to request specific permissions from Lus unless `-Pseal` is passed.

`pledge` returns multiple booleans, one for each permission requested. If a permission is not granted, the corresponding boolean is `false`. Invalid or malformed permissions error.

Permissions are stored in the runtime state. When permissions are granted through commandline arguments, they are given to *all* states created by the runtime. When permissions are requested through `pledge` from within a script, they are only given to the state that requested them and its future substates.

The permission format is `[~]permission[:subpermission]=<value>`, where `permission` is the permission type, `subpermission` is an optional subpermission, and `value` is an optional value.

The optional `~` prefix rejects the permission and bars it from being granted **at any point** (unless `lus_pledge` is used from C). This is useful when you want to prevent a user from accidentally granting an unsafe permission—rejected permissions error immediately instead of returning false when requested. Rejecting permissions always returns `true` when requested.

Barring all permissions with `~all` will revoke everything *including* existing permissions. If you want to block what hasn't been granted **yet** without revoking current access, use the special semantic `pledge("seal")`. Seal renders all permissions immutable, meaning existing permissions become **unrevokable**.

The following permissions are available:

### Generic

  - `all`: Grants all permissions. **Not requestable from scripts.**
  - `exec`: Allows use of `io.popen` and `os.execute`.
  - `load`: Allows use of `require`, `load`, `loadfile`, and `dofile`.
      - *Note: `require`, `loadfile`, and `dofile` also require the `fs` permission to access files on disk.*
      - *Rationale: `require` is grouped with `load` because `load`+`fs` can be used to reimplement `require` logic, making them functionally equivalent in terms of security capability.*

### Filesystem

> **Security Note:** The `fs` glob implementation canonicalizes all paths (resolving symlinks and `..` segments) before permission checks are performed.

  - `fs`: Global permission to do anything with the filesystem. This also impacts some `io.*` functions.
  - `fs:read`: Permission to read files (global).
  - `fs:read=<path/glob>`: Permission to read files at a specific path.
  - `fs:write`: Permission to write files (global). This also allows files to be removed.
  - `fs:write=<path/glob>`: Permission to write files at a specific path. This also allows the file to be removed.

### Network

  - `network`: Global permission to do anything with the network.
  - `network:tcp`: Permission to do anything with TCP.
  - `network:udp`: Permission to do anything with UDP.
  - `network:tcp=<host>:<port>`: Permission to do anything with TCP at a specific host and port.
  - `network:udp=<host>:<port>`: Permission to do anything with UDP at a specific host and port.
  - `network:http`: Permission to make network requests.
  - `network:http=<url>`: Permission to make network requests to a specific URL. URLs can have wildcards, e.g. `example.com/*` or `*.example.com`.

## Example usage

### Lua

Granting permissions through commandline arguments:

```sh
# Both commands are equivalent.
lus --pledge fs:read=/home/user/* --pledge network --pledge seal
lus -Pfs:read=/home/user/* -Pnetwork -Pseal

# May want to authorize your deps folder.
lus --pledge load --pledge fs:read=deps/* --pledge seal
lus -Pload -Pfs:read=deps/* -Pseal

# You can also grant all permissions.
# The "all" permission cannot be requested from a script.
lus --pledge all
lus -Pall
```

Requesting permissions through a prompt:

```lua
global pledge, fs

if can_read = pledge("fs:read") then
    print("We can read!", fs.list("."))
end
```

A good pattern to employ is to `pledge` the permissions you want first, then pledge `seal` to block everything else:

```lua
if pledge("fs:read=/home/user/*", "seal") then
    -- This is a mostly safe environment to operate in.
end
```

When loading libraries, you might want to pledge some initial permissions first, `require` what you need, then pledge `seal` to block everything else:

```lua
-- These are necessary for loading libraries.
-- load: For evaluating code at runtime.
-- fs:read: For reading files.
pledge("load", "fs:read=deps/*")

-- Require what we need.
require("deps.fancy-math-library")
require("deps.fancy-prompt-library")

-- Lock down code evaluation and other permissions,
-- but preserve reading from deps/*.
pledge("~load", "seal")
```

### C API

You can grant permissions to a state using `lus_pledge`, revoke permissions with `lus_revokepledge`, check existing permissions with `lus_haspledge`, get a pledge's value with `lus_getpledgeval`, and define your own with `lus_registerpledge`.

`lus_confirmpledge` is used in custom granters to confirm when a permission was granted or to overwrite an existing permission value. Unlike `lus_pledge`, `lus_confirmpledge` does not trigger validation callbacks, preventing infinite recursion loops inside checks.

```c
int main() {
    lua_State* L = luaL_newstate();
    
    /* Grant permissions. */
    lus_pledge(L, "fs:read", "/home/user/*");

    /* Check if we have permission. */
    if (lus_haspledge(L, "fs:read", "/home/user/*")) {
        printf("We have permission to read files in /home/user/*\n");

        /* This will work too. */
        if (lus_haspledge(L, "fs:read", "/home/user/a.txt")) {
            printf("We have permission to read /home/user/a.txt\n");
        }
    }

    /* Get a pledge's value. */
    const char* value = lus_getpledgeval(L, "fs:read");
    printf("The value of fs:read is %s\n", value); /* "home/user/*" */

    /* Revoke permissions. */
    lus_revokepledge(L, "fs:read");

    /* Bar all permissions. */
    lus_pledge(L, "seal", NULL);
}
```

`lus_registerpledge` is used to define your own permissions. It accepts a name for the permission and a callback function. The callback will receive two arguments: the `lua_State` pointer, and a boolean `is_checking`.

**If `is_checking` is true (1), an already-granted permission is being checked.** This is useful when a granted permission may be conditional on a side-effect or a glob. A check will be performed each time `lus_haspledge` is called. You can use `lus_confirmpledge` to overwrite an existing permission value (e.g. updating a cache or narrowing a wildcard) or do nothing to preserve the existing value.

**If `is_checking` is false (0), a permission is being granted.** You can either grant the permission with `lus_confirmpledge` or reject it by not doing anything.

In either case, the callback should return a boolean indicating whether the permissions requested were valid (recognized by the granter). Returning `false` (0) will error and tell the user that the permissions were not recognized.

The callback passed to this function will receive a subpermission and a value on the stack. If no subpermission or value is specified, they will be nil at their respective positions.

```c
static int duck_granter(lua_State* L, int is_checking) {
    /* Read the subpermission and value. */
    const char* subpermission = luaL_optstring(L, 1, NULL);
    const char* value = luaL_optstring(L, 2, "Saxony duck");

    /* Is the permission being checked? */
    if (is_checking) {
        if (strstr(value, "duck") == NULL) {
            /* There's no duck! Deny the check. */
            return 1;
        } else {
            /* * Update the duck:quack permission value.
             * We use lus_confirmpledge here to update state safely
             * without triggering a recursive validation loop.
             */
            lus_confirmpledge(L, "duck:quack", value);
            return 0; /* Success */
        }
    } else {
        /* Granting Phase */
        if (subpermission == NULL) {
            /* Assume they want to grant all permissions. */
            lus_confirmpledge(L, "duck", NULL);
            lus_confirmpledge(L, "duck:quack", value);
        } else if (strcmp(subpermission, "quack") == 0) {
            /* Grant only the duck:quack permission. */
            lus_confirmpledge(L, "duck:quack", value);
        } else {
            /* This is not a valid permission name. */
            return 0;
        }
    }
    
    return 1; /* Valid permission name */
}

int main() {
    lua_State* L = luaL_newstate();
    
    /* Register two permissions. */
    lus_registerpledge(L, "duck", duck_granter);
    lus_registerpledge(L, "duck:quack", duck_granter);
}
```

To check your pledge in a C function, you can use `lus_haspledge`:

```c
static int duck_granter(lua_State* L, int is_checking);

static int my_duck_function(lua_State* L) {
    if (lus_haspledge(L, "duck:quack", NULL)) {
        printf("My lord duck %s!\n", lus_getpledgeval(L, "duck:quack"));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int main() {
    lua_State* L = luaL_newstate();
    
    /* Register permissions. */
    lus_registerpledge(L, "duck", duck_granter);
    lus_registerpledge(L, "duck:quack", duck_granter);

    /* Register the function. */
    lua_register(L, "my_duck_function", my_duck_function);

    /* Run the script. */
    luaL_dofile(L, "script.lua");
}
```

### Coroutines

Since permissions are stored in the state, you can use coroutines to specialize permissions or sandbox.

New coroutines receive a **copy** of the creating thread's permissions at the moment of `coroutine.create`. Subsequent changes to the parent's permissions do not affect the coroutine, and changes in the coroutine do not affect the parent.

```lua
global pledge, fs, coroutine, print

local function sandbox_function()
    -- This will error.
    print(fs.list("/etc"))
end

-- Main state has access to /etc.
pledge("fs:read=/etc")

-- But sandbox_coroutine won't.
local sandbox_coroutine = coroutine.create(function()
    -- Drop permissions immediately inside the coroutine.
    pledge("~fs")
    sandbox_function()
end)

-- false, 'permission "fs:read" denied'
print(catch coroutine.resume(sandbox_coroutine))

-- But main thread still retains access to /etc because
-- the coroutine modified its own COPY of the permissions.
print(fs.list("/etc"))
```