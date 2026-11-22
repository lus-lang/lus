---
name: raise
kind: module
---

# raise

## slurp

```lus
function slurp(path)
```

Reads a whole file.

**Parameters**

- `path` (`string`): The file to read.

**Returns**

- `string`: The contents.

**Raises**

- `"cannot open PATH"` when the file does not exist.
- `"permission denied"` when the program may not read the file, which the pledge of the program decides.
