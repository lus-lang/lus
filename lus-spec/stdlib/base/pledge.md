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

Grants or checks a permission. Returns `true` if the permission was granted, `false` if it was denied or the state is sealed.

The `name` arguments specify the permissions to grant or check.

Special permissions: `"all"` grants all permissions (CLI only), `"seal"` prevents future permission changes. The `~` prefix rejects a permission permanently.

```lus
pledge("fs")           -- grant filesystem access
pledge("fs:read=/tmp") -- grant read access to /tmp only
pledge("~network")     -- reject network permission
pledge("seal")         -- lock permissions
```
