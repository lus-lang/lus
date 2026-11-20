# Rewrite rubric

Answer the hard stops first. One yes decides the verdict, and the scoring below only shapes the report.

## Hard stops

| Question | If yes |
| --- | --- |
| Do other programs link against this project or import it as a library in its own language? This covers C and C++ libraries, crates, npm and PyPI packages, gems, and plugins loaded by a host application. | **Fork or new major.** Users depend on the language and the binary interface. Offer a Lus companion, a fork under a new name, or a new major version announced as such, and list the improvements. |
| Is the language part of the contract, such as a Python SDK, a TypeScript type package, or a code generator whose output users edit? | **Fork or new major**, for the same reason. |
| Does the core depend on something only its current ecosystem provides, such as GPU kernels, a machine learning framework, a GUI toolkit, a browser DOM, or a mobile platform SDK? | **Partial or decline.** Lus can take over the scripting, tooling, or service layer around that core. A host program can embed Lus through `lus.h`. |
| Is a regulated or certified build in place that a rewrite would invalidate? | **Decline**, and list the improvements for a future major version. |

## Scoring

With no hard stop, score each line from 0 to 2 and add the results.

| Factor | 0 | 1 | 2 |
| --- | --- | --- | --- |
| Shape | GUI or platform app | library with few users | command line tool, service, script, batch job |
| Size | over 50,000 lines | 5,000 to 50,000 lines | under 5,000 lines |
| Observable interface | implicit, side effects everywhere | partly documented | clear inputs and outputs, easy to record |
| Existing tests | none | some | good coverage to start the corpus from |
| Dependencies | many with no Lus counterpart | a few to port | mostly covered by the Lus standard library |
| Gain | little | one clear improvement | several: speed, permissions, fewer dependencies, one binary |

A total of 9 or more suggests `rewrite`. From 5 to 8, suggest `partial`: port the slices with the most gain and leave the rest. Under 5, suggest `decline` and still deliver the improvement table, since the user asked for it.

## Examples

- A 3,000-line Python script that reads CSV, calls a JSON API, and writes SQLite scores 11. Verdict: rewrite. Improvements: one executable, three dependencies removed, `pledge("fs:read=./in/*", "fs:write=./out/*", "network:http=api.example.com")`.
- A Node.js HTTP service of 20,000 lines on Express with a Postgres driver scores 6. Verdict: partial. Port the request handlers that do the heavy text work onto `network.serve`, and keep the database layer behind an internal endpoint until a Postgres client exists in Lus.
- A C++ image codec library used by other projects meets the first hard stop. Verdict: fork or new major. Offer a Lus command line front end that embeds the codec through `lus.h`, which gives scripting and sandboxing without touching the library's interface.
- A Lua 5.4 game scripting layer embedded in a C engine meets no hard stop if the engine is the project's own. Verdict: rewrite, often in an afternoon. `lus check` reports the Lua idioms that have a Lus form, and the host switches from the Lua C API to `lus.h`.
