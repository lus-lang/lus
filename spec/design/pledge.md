# Pledge

Pledge is the capability system of Lus. A script states the capabilities it needs, and every sensitive operation checks them. The script and command line syntax of 1.7 carries over unchanged. Lus 2.0 replaces the host and extension API with a declarative capability registry.

## Script syntax

The script syntax is the one documented in acquis 10:

```lus
pledge("fs:read=/tmp/*")   -- grant a capability with a value
pledge("network")          -- grant a capability and all of its subcapabilities
pledge("~exec")            -- reject a capability permanently
pledge("seal")             -- forbid any further change
```

`pledge` accepts several strings in one call and returns `true` when every grant succeeds. A coroutine starts with the permission set of its creator, and changes inside it stay local to it. On the command line, `-P` and `--pledge` grant capabilities before the script runs.

## Capabilities

A capability has a name, a list of subcapabilities, and a value kind. The value kind decides how a granted value such as `/tmp/*` matches a requested value such as `/tmp/a.txt`.

| Value kind | Granted value | Matching |
|---|---|---|
| `none` | no value allowed | presence of the grant |
| `path` | a path glob | both sides are made absolute and canonical, then matched with the linear time glob matcher |
| `host` | `host[:port][/path-glob]`, with `*` allowed in the host | host labels, port, and path are matched separately |
| `pattern` | a glob over an opaque string | the linear time glob matcher |
| `custom` | any string | a matcher function supplied at registration |

The runtime registers its own capabilities through the same registry that extensions use: `fs` (with `read`, `write`, `exec`), `network` (with `tcp`, `udp`, `http`, `tls`), `exec`, `env`, `load`, `ffi`, `worker`, and `seal`.

## Path values

A path value is an absolute path or a path that starts with `.`, which resolves against the working directory. The directory part of a granted value, up to its first wildcard, resolves through its deepest existing ancestor when the grant is made. A requested path resolves through its symbolic links, or through its parent directory when the file does not exist yet. Both sides then use `/` as their only separator.

On Windows a path value may also start with a drive (`C:\` or `C:/`), a UNC share (`\\server\share`), or a single separator, and `\` and `/` are both separators, so a value such as `D:\a\tests/fixtures/*` that joins a native directory with `/` is valid. A walk up the directory part stops at the drive or the share. Windows paths match without regard to ASCII case, because NTFS compares names that way by default. The resolved parts of both sides carry the case stored on disk, so the rule only decides components that do not exist yet. A non ASCII name that differs from the grant only in case is denied.

## Registering a capability

An extension module registers a capability from Zig or from C. The C form is:

```c
static const char *const fs_subs[] = { "read", "write", NULL };

lus_defcapability(L, &(lus_Capability){
  .name = "myfs",
  .subcapabilities = fs_subs,
  .kind = LUS_CAP_PATH,
});
```

A `LUS_CAP_CUSTOM` capability also supplies `.match`, a function that receives the granted value and the requested value and returns whether the grant covers the request. Registration happens once per state, before scripts run.

## Checking a capability

An operation checks a capability with one call:

```c
lus_require(L, "myfs:read", path);   /* raises the standard permission error */
if (lus_allowed(L, "myfs:read", path)) { ... }   /* returns a boolean */
```

Builtins written in Zig declare the capability in their descriptor, and the call site check is generated from it. The same descriptor produces the `pledges` list in the stdlib specification, so the documentation always matches the code.

The standard permission error reads `permission denied: myfs:read=<value>`, and its error value is a table with the fields `capability`, `value`, and `message`.

## Host policy

The embedding host controls the starting permission set of a state with `lus_grant`, `lus_reject`, and `lus_seal`. A host that wants interactive approval installs a request hook with `lus_onrequest`. When a script calls `pledge` for a capability the host has neither granted nor rejected, the hook decides, for example by asking the user.

## Representation

A permission set is an immutable persistent structure. Coroutines and workers share their creator's set and copy only the parts they change, so creating a coroutine never copies permissions. Canonical paths are computed once per grant, and requested paths are canonicalized once per check by a single shared path module.
