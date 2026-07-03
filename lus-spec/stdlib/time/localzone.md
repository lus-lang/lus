---
name: time.localzone
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
returns: zone
---

Returns the system's local `zone`, detected from the environment: `$TZ`, then `/etc/localtime`/`/etc/timezone` on Unix, or the current Windows time-zone mapped to its IANA name. Falls back to UTC when detection fails. The resolved zone is looked up in the embedded tzdata, so it carries full DST history.

```lus
print(time.now():at(time.localzone()):iso())
```
