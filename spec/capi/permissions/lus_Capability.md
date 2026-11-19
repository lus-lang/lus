---
name: "lus_Capability"
header: lus.h
kind: type
since: "2.0.0"
stability: stable
origin: lus
signature: |
  typedef struct lus_Capability {
    const char *name;
    const char *const *subcapabilities;
    int kind;
    lus_CapMatch match;
    void *ud;
  } lus_Capability;
---

The declaration of a capability for `lus_defcapability`.

- `name` is the base name, such as `"store"`. It is 1 to 63 bytes long and contains no `:`, `=`, `~`, or space.
- `subcapabilities` lists the subcapability names and ends with `NULL`, or is `NULL` when there are none.
- `kind` is one of the [`LUS_CAP_` kinds](#LUS_CAP_*).
- `match` is the matcher of a `LUS_CAP_CUSTOM` capability, and is ignored for the other kinds.
- `ud` is passed to `match` unchanged.

Zero initialization leaves every optional field empty, so a declaration sets only the fields it needs.
