# Worker messages

Every worker owns a complete state with its own heap and collector, so no collection stops more than one thread. A message moves a value from one heap to another in three ways, chosen per value (`runtime/src/lib/worker.zig`).

- Tables, numbers, booleans, and short strings are copied. The sender walks the value once and builds a packet in memory that no heap owns. A forwarding table records every table it meets, so shared references and cycles keep their shape. The receiver rebuilds the graph in its own heap.
- Vectors move. The sender's vector is detached and the receiver takes over its buffer.
- Strings longer than 64 bytes travel as shared immutable blobs (`runtime/src/vm/blob.zig`).

## Shared strings

A blob holds the bytes of a string once, in memory that no heap owns, with an atomic reference count. A heap refers to a blob in two ways.

- A string created from a message is a shared string. Its cell holds the pointer to the blob where a plain string holds its bytes, and `String.bytes` reads through the pointer when the `shared` flag is set. Every other part of the runtime sees an ordinary string.
- A string of the heap itself that was sent keeps its own bytes and records its blob in the cache of the heap, a map from the string to its blob, so sending it again reuses the blob.

Each heap keeps its own collector. When a heap sweeps a shared or cached string, it releases the reference of that string, and the blob is freed when the last reference in any heap and any packet in transit is gone. Every reference charges the length of the blob to the heap that holds it, so the pacer of a heap counts the bytes it keeps alive.

The hash of a string survives the trip. A blob records the hash of its bytes and the seed it was computed with, and every worker takes the hash seed of its creator, so the whole tree of workers in a process hashes alike and a received string takes its hash from the blob without reading its bytes. A heap with another seed hashes the bytes itself.

A string goes into a message by one of these rules.

1. A shared string, or a string with a blob in the cache, passes its blob. Forwarding a received string to a further worker copies no bytes.
2. A string that was sent before gets a blob, which the cache keeps for every later send.
3. A string sent for the first time is copied, unless it is longer than 2 KB, where it gets a blob that only the message holds.

The third rule comes from measuring strings that are sent once. For a 100 byte string, allocating a blob and freeing it from another thread costs more than copying the bytes into the packet and again into the receiving heap, and most strings in messages are sent once. Above 2 KB, where the receiver would allocate a large object, the blob wins.

## Measurements

The numbers come from a ReleaseFast build on an Apple silicon Mac and are the best of several runs. Each round trip sends a value to a worker that replies with its length, so one message is in flight at a time.

| workload | copied | shared |
| --- | ---: | ---: |
| one 1 MB string, 10,000 round trips | 1.17 s | 0.054 s |
| one table of 10,000 strings of 100 bytes, 1,000 round trips | 0.687 s | 0.541 s |

The 1 MB string costs 117 µs per round trip when it is copied, for two copies, a hash of the whole string in the receiver, and a fresh large allocation that the receiver's collector frees later. Shared, a round trip costs 5 µs, the cost of the handshake between the threads. The table of short strings gains less, because each string still costs a lookup in the cache of the sender, a new cell in the receiver, and two atomic updates of the count.

Strings sent once were measured with tables of fresh strings built for every send, 2 MB of strings per message, 1,000 messages. The table gives the time spent sending, which is the run less the run that builds the same tables without sending them.

| string length | copied | blob for every string |
| ---: | ---: | ---: |
| 80 bytes | 140 ms | 214 ms |
| 160 bytes | 106 ms | 135 ms |
| 320 bytes | 72 ms | 68 ms |
| 1,000 bytes | 53 ms | 57 ms |
| 4,000 bytes | 42 ms | 37 ms |

A second run with the rules above measured 80 byte strings at 163 ms against 159 ms copied, which is within the noise of these runs, and 4,000 byte strings at 37 ms against 45 ms. `tests/bench/messages.lus` keeps the repeated workload in the bench suite.

Vectors are mutable buffers, and a message moves their payload without a copy, so they travel without blobs.
