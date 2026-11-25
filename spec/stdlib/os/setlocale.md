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

Queries or sets the locale of the program and returns the name of the locale, or `nil` when the requested locale is unavailable.

`locale` is an optional string. `category` is a string that defaults to `"all"` and must be one of `"all"`, `"collate"`, `"ctype"`, `"monetary"`, `"numeric"`, and `"time"`. Any other category raises `bad argument #2 to 'setlocale' (invalid option 'NAME')`.

The runtime has one locale, `"C"`, because every conversion it performs is locale independent. A call without `locale` returns `"C"`. A call with `"C"`, `"POSIX"`, or the empty string, which asks for the locale of the environment, returns `"C"`. Any other name returns `nil`. The function requires no permission.

```lus
print(os.setlocale())  --> C
print(os.setlocale("", "numeric"))  --> C
print(os.setlocale("fr_FR.UTF-8"))  --> nil
```

[`os.date`](/manual/api#os.date) formats dates in the "C" locale, and `tostring` writes numbers with a `.` decimal point.
