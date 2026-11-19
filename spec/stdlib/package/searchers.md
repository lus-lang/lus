---
name: package.searchers
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: table
---

A table holding the sequence of searcher functions used by `require`. The default order is `package.preload`, modules preincluded with `--include`, modules bundled by `lus build`, source modules from `package.path`, and two searchers over `package.cpath` that report native modules as unavailable.
