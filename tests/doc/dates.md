---
name: dates
kind: module
package: dates
version: 1.4.1
lus: 2.0
license: 0BSD
repository: https://github.com/example/dates
---

# dates

Parses, formats, and compares dates in ISO 8601.

**Permissions**

- `fs:read=/usr/share/zoneinfo/*`: Reads the system time zone database.

**Flags**

- `tzdata` (`string`): Path of a time zone database to use in place of the system one.
- `strict` (`boolean`, default `false`): Reject fields that ISO 8601 does not define.

**Includes**

- `strings` 1.0.0 from https://atmosp.here/2.0/strings.lus

## dates.parse

```lus
function dates.parse(text)
```

Parses a date.

**Parameters**

- `text` (`string`): The date in ISO 8601.

**Returns**

- `table`: The date.
