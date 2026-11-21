---
name: fs.createdirectory
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lus
params:
  - name: path
    type: string
  - name: recursive
    type: boolean
    optional: true
returns: []
---

Creates a directory at `path` and returns no values.

`path` is the string path of the new directory. `recursive` is a boolean that defaults to `false`. Without it, the parent of `path` must exist and `path` itself must not. With `recursive` set to `true`, the call creates every missing directory along `path` in order, and it succeeds when the whole path already exists.

On success the call returns nothing. Every failure raises an error. Without `recursive`, an existing `path` raises `"cannot create directory 'PATH': already exists"` and a missing parent raises `"cannot create directory 'PATH': parent does not exist"`. In recursive mode, a component of `path` that exists as a file raises an error that ends in `Not a directory`, and a `path` with a `..` component raises `"cannot create directory 'PATH': '..' is denied"`. The call requires `fs:write` for `path`, and in recursive mode every directory it creates must also be covered by `fs:write`.

The following example creates a nested directory in one call, repeats the call, and then shows that a plain call on an existing directory fails.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-mkdir-example")
local nested = fs.path.join(dir, "a", "b", "c")
fs.createdirectory(nested, true)
fs.createdirectory(nested, true)
print(fs.type(nested))                      --> directory  false
print((catch fs.createdirectory(nested)))   --> false
fs.remove(dir, true)
```

[`fs.remove`](/manual/api#fs.remove) removes a directory, and [`fs.type`](/manual/api#fs.type) tells whether one exists.
