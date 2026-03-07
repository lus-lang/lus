---
name: table.zip
module: table
kind: function
since: 1.6.0
stability: unstable
origin: lus
vararg: true
returns: table
---

Combines multiple tables element-wise into a table of tuples. The result length equals the length of the shortest input table. Each tuple is a table `{table1[i], table2[i], ...}`.
