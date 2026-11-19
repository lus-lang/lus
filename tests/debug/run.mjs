// A scripted Debug Adapter Protocol client for `lus debug`.
//
// Usage: node tests/debug/run.mjs [path/to/lus]
//
// The first scenario drives tests/debug/fixture.lus through a breakpoint,
// locals and the stack, expressions, step in, step out, step over, a
// conditional breakpoint, a hit count, an uncaught error, and the end of
// the program. The second runs tests/debug/coroutine.lus, an endless loop
// around a coroutine, to check the entry stop, a breakpoint inside the
// coroutine, a log point, pausing a running program, and terminating it.
// `zig build test-debug` in runtime/ runs it with the freshly built binary.

import { spawn } from "node:child_process";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const lus = path.resolve(process.argv[2] ?? path.join(here, "../../runtime/zig-out/bin/lus"));
const fixture = path.join(here, "fixture.lus");
const coroutineFixture = path.join(here, "coroutine.lus");

class Client {
    constructor(proc) {
        this.proc = proc;
        this.buffer = Buffer.alloc(0);
        this.seq = 1;
        this.pending = new Map();
        this.events = [];
        this.waiters = [];
        this.output = { stdout: "", stderr: "", console: "" };
        proc.stdout.on("data", (chunk) => this.receive(chunk));
    }

    receive(chunk) {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        for (;;) {
            const end = this.buffer.indexOf("\r\n\r\n");
            if (end < 0) return;
            const header = this.buffer.subarray(0, end).toString();
            const length = Number(/Content-Length: (\d+)/i.exec(header)[1]);
            if (this.buffer.length < end + 4 + length) return;
            const body = this.buffer.subarray(end + 4, end + 4 + length).toString();
            this.buffer = this.buffer.subarray(end + 4 + length);
            this.dispatch(JSON.parse(body));
        }
    }

    dispatch(msg) {
        if (msg.type === "response") {
            const p = this.pending.get(msg.request_seq);
            this.pending.delete(msg.request_seq);
            p?.(msg);
            return;
        }
        if (msg.event === "output") this.output[msg.body.category] += msg.body.output;
        this.events.push(msg);
        this.waiters = this.waiters.filter((w) => !w(msg));
    }

    request(command, args = {}) {
        const seq = this.seq++;
        const body = JSON.stringify({ seq, type: "request", command, arguments: args });
        this.proc.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
        return new Promise((resolve) => this.pending.set(seq, resolve));
    }

    async ok(command, args) {
        const r = await this.request(command, args);
        assert.ok(r.success, `${command} failed: ${r.message}`);
        return r.body ?? {};
    }

    /// Resolves with the first event named `name` not consumed yet.
    event(name, pred = () => true) {
        const i = this.events.findIndex((e) => e.event === name && pred(e));
        if (i >= 0) return Promise.resolve(this.events.splice(i, 1)[0]);
        return new Promise((resolve) => {
            this.waiters.push((e) => {
                if (e.event !== name || !pred(e)) return false;
                this.events.splice(this.events.indexOf(e), 1);
                resolve(e);
                return true;
            });
        });
    }
}

async function stopped(c, reason) {
    const e = await c.event("stopped");
    assert.equal(e.body.reason, reason, `expected a stop for ${reason}, got ${JSON.stringify(e.body)}`);
    const { stackFrames } = await c.ok("stackTrace", { threadId: 1 });
    return { event: e, frames: stackFrames };
}

async function locals(c, frameId) {
    const { scopes } = await c.ok("scopes", { frameId });
    const scope = scopes.find((s) => s.name === "Locals");
    const { variables } = await c.ok("variables", { variablesReference: scope.variablesReference });
    return Object.fromEntries(variables.map((v) => [v.name, v]));
}

function start() {
    const proc = spawn(lus, ["debug"], { stdio: ["pipe", "pipe", "inherit"] });
    const c = new Client(proc);
    const exited = new Promise((resolve) => proc.on("exit", resolve));
    return { c, exited };
}

async function basics() {
    const { c, exited } = start();
    const caps = await c.ok("initialize", { adapterID: "lus", linesStartAt1: true, columnsStartAt1: true });
    assert.ok(caps.supportsConditionalBreakpoints);
    await c.event("initialized");

    let bps = await c.ok("setBreakpoints", { source: { path: fixture }, breakpoints: [{ line: 10 }] });
    assert.equal(bps.breakpoints[0].verified, true);
    await c.ok("setExceptionBreakpoints", { filters: ["uncaught"] });
    await c.ok("launch", { program: fixture, cwd: here });
    await c.ok("configurationDone");

    // Breakpoint inside compute(1).
    let s = await stopped(c, "breakpoint");
    assert.equal(s.frames[0].name, "compute");
    assert.equal(s.frames[0].line, 10);
    assert.equal(s.frames[0].source.path, fixture);
    assert.equal(s.frames[1].name, "main chunk");
    assert.equal(s.frames[1].line, 16);
    let vars = await locals(c, s.frames[0].id);
    assert.equal(vars.n.value, "1");
    // The constant stays visible because the debugger compiles without folding it.
    assert.equal(vars.total.value, "10");

    // Expressions in the frame's environment, and read-only assignment.
    let r = await c.ok("evaluate", { expression: "n + total", frameId: s.frames[0].id, context: "watch" });
    assert.equal(r.result, "11");
    r = await c.ok("evaluate", { expression: "items", frameId: s.frames[1].id, context: "watch" });
    assert.match(r.result, /name = "fixture"/);
    assert.ok(r.variablesReference > 0);
    const { variables: fields } = await c.ok("variables", { variablesReference: r.variablesReference });
    assert.deepEqual(fields.map((v) => v.name), ["[1]", "[2]", "[3]", "name"]);
    assert.equal(fields[3].evaluateName, "items.name");
    const denied = await c.request("evaluate", { expression: "n = 5", frameId: s.frames[0].id, context: "repl" });
    assert.equal(denied.success, false);
    assert.match(denied.message, /read-only/);

    // Step in to add, then out to the next line of compute.
    await c.ok("stepIn", { threadId: 1 });
    s = await stopped(c, "step");
    assert.equal(s.frames[0].name, "add");
    assert.equal(s.frames[0].line, 4);
    assert.equal(s.frames.length, 3);
    vars = await locals(c, s.frames[0].id);
    assert.equal(vars.a.value, "1");
    assert.equal(vars.b.value, "10");

    await c.ok("stepOut", { threadId: 1 });
    s = await stopped(c, "step");
    assert.equal(s.frames[0].name, "compute");
    assert.equal(s.frames[0].line, 11);
    vars = await locals(c, s.frames[0].id);
    assert.equal(vars.result.value, "11");

    // Step over the return, back into the loop body.
    await c.ok("next", { threadId: 1 });
    s = await stopped(c, "step");
    assert.equal(s.frames[0].name, "main chunk");
    assert.equal(s.frames[0].line, 17);

    // A conditional breakpoint and a hit count.
    bps = await c.ok("setBreakpoints", {
        source: { path: fixture },
        breakpoints: [{ line: 16, condition: "i == 4" }, { line: 17, hitCondition: "4" }],
    });
    assert.equal(bps.breakpoints.length, 2);
    await c.ok("continue", { threadId: 1 });
    s = await stopped(c, "breakpoint");
    assert.equal(s.frames[0].line, 16);
    r = await c.ok("evaluate", { expression: "i", frameId: s.frames[0].id, context: "hover" });
    assert.equal(r.result, "4");

    await c.ok("continue", { threadId: 1 });
    s = await stopped(c, "breakpoint");
    assert.equal(s.frames[0].line, 17);
    r = await c.ok("evaluate", { expression: "i", frameId: s.frames[0].id, context: "watch" });
    assert.equal(r.result, "5");

    // The uncaught error stops where it is raised.
    await c.ok("setBreakpoints", { source: { path: fixture }, breakpoints: [] });
    await c.ok("continue", { threadId: 1 });
    s = await stopped(c, "exception");
    assert.match(s.event.body.text, /boom/);
    assert.equal(s.frames[1].name, "main chunk");
    assert.equal(s.frames[1].line, 20);
    const info = await c.ok("exceptionInfo", { threadId: 1 });
    assert.match(info.description, /fixture\.lus:20: boom/);

    // The program ends with the error reported and status 1.
    await c.ok("continue", { threadId: 1 });
    const ex = await c.event("exited");
    assert.equal(ex.body.exitCode, 1);
    await c.event("terminated");
    assert.match(c.output.stdout, /value\t11\tfixture\n/);
    assert.match(c.output.stdout, /value\t15\tfixture\n/);
    assert.match(c.output.stderr, /boom/);

    await c.ok("disconnect");
    const code = await exited;
    assert.equal(code, 0);
}

async function coroutines() {
    const { c, exited } = start();
    await c.ok("initialize", { adapterID: "lus" });
    await c.event("initialized");
    await c.ok("launch", { program: coroutineFixture, stopOnEntry: true });
    await c.ok("configurationDone");
    let s = await stopped(c, "entry");
    assert.equal(s.frames[0].name, "main chunk");

    // A breakpoint inside the coroutine shows the resumer below it.
    await c.ok("setBreakpoints", { source: { path: coroutineFixture }, breakpoints: [{ line: 7 }] });
    await c.ok("continue", { threadId: 1 });
    s = await stopped(c, "breakpoint");
    assert.equal(s.frames[0].line, 7);
    const label = s.frames.findIndex((f) => f.presentationHint === "label");
    assert.ok(label > 0, "a label separates the coroutine from its resumer");
    const main = s.frames[s.frames.length - 1];
    assert.equal(main.name, "main chunk");
    assert.equal(main.line, 15);
    let r = await c.ok("evaluate", { expression: "count", frameId: s.frames[0].id, context: "watch" });
    assert.equal(r.result, "1");
    r = await c.ok("evaluate", { expression: "spins", frameId: main.id, context: "watch" });
    assert.equal(r.result, "0");

    // A log point with a hit count prints once and never stops.
    await c.ok("setBreakpoints", {
        source: { path: coroutineFixture },
        breakpoints: [{ line: 16, logMessage: "spins={spins}", hitCondition: "3" }],
    });
    await c.ok("continue", { threadId: 1 });
    await c.event("output", (e) => e.body.category === "console");
    assert.equal(c.output.console, "spins=2\n");

    // Pausing stops the endless loop wherever it is.
    await c.ok("pause", { threadId: 1 });
    s = await stopped(c, "pause");
    assert.ok(s.frames.length >= 1);

    await c.ok("terminate");
    await c.event("terminated");
    await exited;
}

async function main() {
    await basics();
    await coroutines();
}

const timer = setTimeout(() => {
    console.error("lus debug test: timed out");
    process.exit(1);
}, 30000);

main().then(
    () => {
        clearTimeout(timer);
        console.log("lus debug: all checks passed");
        process.exit(0);
    },
    (e) => {
        console.error(e);
        process.exit(1);
    },
);
