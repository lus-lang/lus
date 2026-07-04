---
title: How tiny can Lua get?
date: 2026-07-03
---

Lua is known for being quite the tiny language. It has a small interpreter, a small standard library, a small grammar, and requires small effort to learn and use. Yet, I have always felt that Lua's size (in its artifacts and memory usage) contradicts its syntax, that for a language with such a small specification, the runtime is quite large. This is why I've worked on an experiment, a subproject of Lus, to bring about the smallest possible Lua runtime while preserving most of the language's features. Out of it came [MicroLua](https://micro.lus.dev).

It is quite possible indeed to cut down on Lua's program without impacting too many of its features. Most of the size comes from Lua's straightforward program design, which surprisingly does not always translate to reductions in weight. If you let yourself be tricky in implementing language internals, such as using [alignment tags with boxed numbers](https://github.com/lus-lang/microlua/blob/8b0018e1f09fa1aaf35b232056eb8cd813036b2c/src/MLuaValue.h#L95) for value representation instead of [Lua's big TValue](https://github.com/lua/lua/blob/40b76de2d77e66b70a9d4bf989c3f5340919973f/lobject.h#L49), or shortening the ISA to 1/2-bytes and feeding that to a [stack machine](https://github.com/lus-lang/microlua/blob/8b0018e1f09fa1aaf35b232056eb8cd813036b2c/src/MLuaVM.c#L848), then you can shave a surprising amount of memory without impacting functionality. _All_ of Lua 5.1's core libraries are implemented, with select extensions from later versions.

A few sacrifices, however, had to be made. A few were _obligatory_ sacrifices because it would otherwise make MicroLua unusable on embedded systems, such as:
- Continuous array enforcement. You cannot have arrays with holes in them.
- Mark-compact garbage collection. It's not as performant as Lua's generational GC and you cannot control it from scripts but it's necessary to avoid heap fragmentation.
- C upvalues. They increased the complexity of the virtual machine and so they are gone.
- Freestanding core. The interpreter and core libraries do not depend on `libc`.

Some others were _voluntary_ sacrifices that were made in the spirit of tightening language semantics, and not because we faced some kind of blocker, such as:

- Metatables. They're gone. I've always found metatables, especially as providers of operator overloading, ugly and unbecoming of Lua. They're good when they exist as adjuvants to the runtime (e.g., `__gc` to finalize objects when they get collected) but feel wrong as sources of hidden control flow.
    - That said, usage of `__index` is such an important Lua pattern it receives a Walmart implementation as `table.forward` in MicroLua. That I will allow out of necessity and importance.
- `package`. I do not think embedded systems require a module import system with loaders and environment variables to find local libraries. Otherwise, `require` is in but its behavior is defined by the embedder.

The gains of these sacrifices show up in the benchmarks. You can view some of them at the [website](https://micro.lus.dev) but the short story is that MicroLua cuts down a lot on memory pressure, sometimes saving up to _half_ of all memory for the same job and also  significantly _faster_ at code execution. In embedded environments, MicroLua's stack machine is a _beast_; when ported to the TI-84 CE, [MicroLua can be up to _8.1x times faster_ than the default TI-BASIC interpreter](https://micro.lus.dev/#ti84ce).

The binary size itself is also much smaller. In a local macOS size build with similar build flags, MicroLua's compiler/parser-less runtime artifacts total 218 KiB, or 259 KiB with the parser. That is about 2.8x smaller than Lua 5.5.0's runtime artifacts at 612 KiB. And it achieves this while preserving most of Lua's functionality, which proves that **yes, Lua's size contradicts its syntax. The runtime is meant to be _much_ smaller.**

You can view MicroLua's source code [here](https://github.com/lus-lang/microlua). It should also be mentioned that MicroLua was entirely vibe-coded and all human intervention was solely for dictating language specification and internal runtime design.