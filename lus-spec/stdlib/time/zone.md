---
name: time.zone
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: name
    type: string
returns: zone
---

Returns a `zone` for an IANA name such as `"America/New_York"` or `"Europe/Paris"`, resolved from an embedded, zstd-compressed copy of the IANA tzdata database (`time.tzdata_version()` reports the release). Raises if the name is unknown. No filesystem access or `fs` pledge is required: the database is compiled into the runtime, so named zones behave identically on every platform, including ones without a system tz database.

A `zone` supports `z:name()` and `z:offset(instant)` (the offset east of UTC, in seconds, that the zone observes at that instant, honouring historical DST transitions). Pass a zone to `instant:at(zone)` to render a civil time, or to `time.zoned(fields, zone)` to interpret wall-clock fields.

```lus
local ny = time.zone("America/New_York")
print(time.now():at(ny):iso())   -- current time as New York wall clock
```
