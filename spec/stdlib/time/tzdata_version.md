---
name: time.tzdata_version
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
returns: string
---

Returns the release of the IANA time zone database embedded in the runtime, as a string such as `"2026c"`.

The function takes no arguments and raises no errors. The release names a year and a letter, and it changes only when the runtime is built with a newer database.

The following example checks the shape of the release name.

```lus
local v = time.tzdata_version()
print(type(v), #v)  --> string  5
print(v:match("^%d%d%d%d%l$") ~= nil)  --> true
```

Every named zone from [`time.zone`](/manual/api#time.zone) and [`time.localzone`](/manual/api#time.localzone) comes from this database. The script `scripts/update-tzdata.sh` in the repository regenerates the embedded copy.
