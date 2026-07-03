---
name: time.tzdata_version
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
returns: string
---

Returns the IANA tzdata release string embedded in this build, e.g. `"2026b"`. Regenerate the embedded database with `scripts/update-tzdata.sh`.
