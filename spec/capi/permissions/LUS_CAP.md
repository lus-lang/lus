---
name: "LUS_CAP_*"
header: lus.h
kind: constant
since: "2.0.0"
stability: stable
origin: lus
signature: |
  #define LUS_CAP_NONE 0
  #define LUS_CAP_PATH 1
  #define LUS_CAP_HOST 2
  #define LUS_CAP_PATTERN 3
  #define LUS_CAP_CUSTOM 4
---

The value kinds of a capability, which decide how a granted value matches a requested one.

- `LUS_CAP_NONE` takes no value. A grant allows every check of the capability.
- `LUS_CAP_PATH` matches file system paths. Granted values are globs over canonical paths, and requested paths are resolved before they are matched, so symbolic links cannot escape a grant.
- `LUS_CAP_HOST` matches `host[:port][/path-glob]` against URLs and host names, with `*.` as a subdomain wildcard.
- `LUS_CAP_PATTERN` matches a glob over an opaque string, where `*` matches any run of bytes and `?` matches one byte.
- `LUS_CAP_CUSTOM` calls the [`lus_CapMatch`](#lus_CapMatch) function of the capability.
