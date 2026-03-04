---
name: os.setlocale
module: os
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: locale
    type: string
    optional: true
  - name: category
    type: string
    optional: true
returns: string|nil
---

Sets the program's current locale. The `category` selects which category to set (e.g., `"all"`, `"collate"`, `"ctype"`, `"monetary"`, `"numeric"`, `"time"`). If `locale` is `nil`, returns the current locale for the given category. Returns the locale name, or `nil` on failure.
