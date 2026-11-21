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

Returns the `zone` with an IANA name such as `"America/New_York"` or `"Europe/Paris"`.

- `name` is the IANA name of the zone. Names are case sensitive, and the database aliases such as `"US/Eastern"` are accepted under their own names.

The function returns one `zone`. A name that the database lacks raises `unknown time zone 'Mars/Base'`, quoting the name.

Names resolve from a copy of the IANA tzdata database that is compiled into the runtime and decompressed on first use. A zone therefore needs no filesystem access and no `fs` permission, and it behaves the same on every platform. [`time.tzdata_version`](/manual/api#time.tzdata_version) returns the release of the database.

A zone has two methods:

- `z:name()` returns the IANA name. `tostring(z)` returns the same text.
- `z:offset(instant)` returns the offset east of UTC, in seconds, that the zone observes at that instant, following its history of daylight saving transitions. An argument that is not an instant raises `bad argument #1 to 'offset' (time.instant expected)`.

The following example reads the summer and winter offsets of New York and renders an instant there.

```lus
local ny = time.zone("America/New_York")
local summer = time.instant(1782998100)
local winter = time.instant(1767355200)
print(ny:name(), ny:offset(summer), ny:offset(winter))    --> America/New_York  -14400  -18000
print(winter:at(ny):iso())                                --> 2026-01-02T07:00:00-05:00
print(catch time.zone("europe/paris"))                    --> false  ...: unknown time zone 'europe/paris'
```

The zones under `Etc/` follow the POSIX sign convention, so `"Etc/GMT+5"` lies five hours west of UTC. Pass a zone to `instant:at(zone)` to render a civil time, or to [`time.zoned`](/manual/api#time.zoned) to read wall-clock fields in it. [`time.offset`](/manual/api#time.offset) returns a fixed offset, and [`time.localzone`](/manual/api#time.localzone) returns the zone of the system.
