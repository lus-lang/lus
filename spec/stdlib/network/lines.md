---
name: network.lines
module: network
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: stream
    type: thread
  - name: max_bytes
    type: integer
    optional: true
returns: function
---

Returns an iterator over the lines of the text that a coroutine yields in parts, for a generic `for` or for calls of its own.

`stream` is a coroutine that yields strings or vectors, such as the body of a response that [`network.fetch`](/manual/api#network.fetch) streams or the `reader` of a request of [`network.serve`](/manual/api#network.serve). The iterator resumes `stream` whenever it needs more text, and a line may span several parts. Each call of the iterator returns one line as a vector without its line end, and `nil` once the lines ran out. The iterator holds its state, so `local nextline = network.lines(co)` works without a loop. A line ends with LF, and a CR before the LF goes too. The last line may lack a line end. The loop ends when the coroutine ends, and a part of `nil` that a coroutine yields without ending adds nothing.

`max_bytes` is a positive integer that limits a line and defaults to 1 MiB. A longer line raises `"line too long"`. An error that the coroutine raises comes out of the step that resumed it, and a part that is neither a string, a vector, nor `nil` raises an error that names its type. A `max_bytes` that is not positive raises a `bad argument` error. The function needs no permission.

The following example reads the events of a stream of server-sent events, where each event is a `data:` line and an empty line.

```lus
pledge("network")
local server = network.tcp.bind("127.0.0.1", 0)
local _, port = server:getsockname()

local serving = coroutine.detach(coroutine.create(network.serve), server, function(req)
    return 200, coroutine.create(function()
        for n = 1, 2 do
            coroutine.yield(`data: tick $n\n\n`)
        end
    end), { ["Content-Type"] = "text/event-stream" }
end)

local _, events = network.fetch(`http://127.0.0.1:$port/events`, "GET", nil, nil, { stream = true })

for line in network.lines(events) do
    local data = vector.tostring(line):match("^data: (.*)")

    if data then
        print(data)
    end
end

--> tick 1
--> tick 2
coroutine.close(serving)
server:close()
```
