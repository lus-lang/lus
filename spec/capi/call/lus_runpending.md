---
name: "lus_runpending"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_runpending(lus_State *L, int wait)"
params:
  - name: L
    type: "lus_State*"
  - name: wait
    type: "int"
returns:
  - type: "int"
    name: status
---

Runs the coroutines that `coroutine.detach` handed to the runtime and returns a status. `L` must be the main state, outside any call.

If `wait` is nonzero, the call runs the detached coroutines until none is left, as the `lus` command does after the main chunk. If `wait` is zero, the call gives every coroutine that is ready one turn and returns, so a host with an event loop of its own calls it whenever it has time.

On success the call returns `LUS_OK` and leaves the stack unchanged. If a detached coroutine fails and nothing collects its error, the call pushes the error object and returns its status, and `lus_traceback` then returns the traceback of that coroutine.

The following host runs a chunk that detaches a coroutine, then runs it to its end.

```c
lus_dostring(L, "coroutine.detach(coroutine.create(function() print('ran') end))");
if (lus_runpending(L, 1) != LUS_OK) {
  fprintf(stderr, "%s\n", lus_tostring(L, -1, NULL));
  lus_pop(L, 1);
}
```

`lus_pending` returns the number of detached coroutines that have not ended.
