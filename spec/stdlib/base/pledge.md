---
name: pledge
module: base
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: name...
    type: string
returns: boolean
---

`pledge(...)` grants, rejects, or seals permissions for the running coroutine and returns one boolean for each permission name, in order.

Each argument is a permission name, such as `"fs"`, `"fs:read"`, or `"network:http"`, optionally followed by `=` and a value that limits it to matching paths, hosts, or names, as in `"fs:read=./data/*"`. Two forms have a special meaning:

- A name with the prefix `~` rejects that permission permanently, as in `"~exec"`.
- The name `"seal"` freezes the permission set, so that every later grant and rejection fails.

A result is `true` when `pledge` applied the name and `false` when it refused it. A grant is refused after `"seal"` and when the command line or the host granted a narrower set that does not allow the permission. A call with no arguments returns no values.

`pledge` raises an error for a name it does not know, as in `unknown permission: 'bogus'`, and for a subcapability that the base capability lacks, as in `invalid fs subpermission 'nope'`. Granting a permission that was rejected raises `permission "NAME" was rejected`. The name `"all"` raises `permission "all" cannot be requested from scripts`, because only the command line and the embedding API may grant every permission.

```lus
print(pledge("fs:read"))  --> true
print(pledge("network:http", "env"))  --> true  true
pledge("~exec")
print((catch pledge("exec")))  --> false
pledge("seal")
print(pledge("fs:write"))  --> false
```

A coroutine starts with the permissions of the coroutine that created it, and its later changes stay inside it. [Permissions](/manual/permissions) lists every permission name, the form of values, and the `-P` option of `lus`.
