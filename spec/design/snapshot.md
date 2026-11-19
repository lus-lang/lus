# Startup snapshots

## Designs measured and kept out

### A heap snapshot of the standard library

A startup snapshot serializes the state that `lus_openlibs` builds, embeds it in the binary, and copies it into each new state in place of running the library setup. Workers would clone their state from the same image. The format has to relocate every pointer, because the heap places objects at addresses chosen at run time, natives point into the binary, interned strings live in the string table of their state, and library modules keep hooks to their tables in the `ext` map of the state. It also has to stay correct under pledge state, `--readonly-env`, and `-F` flags, which shape a state after the libraries open.

Before building it, the time it could save was measured. The numbers below come from a ReleaseFast build on an Apple silicon Mac. Process times are the best of 300 to 400 runs, and in-process times are averages over thousands of states.

| what | time |
| --- | ---: |
| `lus -e ''`, start to exit | 2.2 ms |
| an empty C program | 1.45 ms |
| a C program linked with `liblus.a` that exits before creating a state | 2.0 ms |
| the same program after `lus_newstate` and `lus_openlibs` | 2.0 to 2.2 ms |
| `lus_newstate`, first state of a process | 17 µs |
| `lus_openlibs`, first state of a process | 53 µs |
| `lus_newstate`, later states | 1.8 µs |
| `lus_openlibs`, later states | 14.5 µs |
| `lus_close` | 2.2 µs |
| heap after `lus_openlibs` | 82 KB |

The library setup of the first state takes 70 µs, about 3 percent of the start of the process. The rest is process creation and the loading of the binary. A 6 MB binary that exits before its first instruction of Lus work takes 0.55 ms longer than an empty program, and the kernel takes the 1.45 ms that the empty program shows. A snapshot replaces the 70 µs with a copy of 82 KB and a relocation pass over it, so it could save at most about 50 µs, which is within the run to run variation of process startup.

Workers start inside a running process, where the state is warm. Creating a worker with an empty body and waiting for it to finish takes 65 µs (`tests/bench/startup.lus` runs 2000 of them). A thread that only starts and joins takes 12 µs, and a thread that creates, opens, and closes a state takes 32 µs, of which `lus_openlibs` is 16 µs. The rest of the 65 µs goes to reading and compiling the script, copying the arguments and the pledge store, and the handshake between the threads. A clone from a snapshot would still copy and relocate the 82 KB image, which leaves a saving of about 10 µs per worker.

Neither saving pays for a relocating snapshot format that every change to a library would have to keep in step with. Lus therefore opens its libraries by running their setup code, and `tests/bench/startup.lus` keeps watching how fast a state starts.
