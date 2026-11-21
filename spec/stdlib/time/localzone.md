---
name: time.localzone
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
returns: zone
---

Returns the time zone of the system as a `zone` from the embedded IANA database.

The function takes no arguments. It reads the environment variable `TZ` first, and a leading `:` in its value is ignored. When `TZ` is unset or empty, it reads `/etc/localtime` and `/etc/timezone` on Unix, and on Windows it maps the current Windows time zone to its IANA name. When `TZ` names a zone that the database lacks, or detection finds nothing, the function returns UTC. It raises no errors and requires no permission.

The returned zone comes from the embedded database, so its offsets follow the full history of daylight saving transitions, and `z:name()` returns its IANA name such as `"Europe/Paris"`.

The following example reads the local zone. Its name depends on the system, so the example prints only its type.

```lus
local here = time.localzone()
print(type(here:name()))                          --> string
local z = time.instant(0):at(here)
print(z.offset == here:offset(time.instant(0)))   --> true
```

[`time.zone`](/manual/api#time.zone) returns a zone by name, and [`time.offset`](/manual/api#time.offset) returns a fixed offset.
