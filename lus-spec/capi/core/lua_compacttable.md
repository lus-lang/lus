---
name: lua_compacttable
header: lua.h
kind: function
since: 1.6.0
stability: stable
origin: lus
signature: "void lua_compacttable (lua_State *L, int idx)"
params:
  - name: L
    type: "lua_State*"
  - name: idx
    type: int
---

Shrinks the internal storage of the table at the given index to fit its current contents. Removing keys never shrinks a table's array or hash parts on its own; this releases the unused capacity. Raises an error if the table is readonly. Exposed to Lus code as `table.compact`.
