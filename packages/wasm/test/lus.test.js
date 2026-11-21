// Tests for the lus.wasm host. Build the module first with `mise run wasm`.

import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { before, describe, test } from "node:test";
import { defaultWasmPath, loadLus, mountLanguageServer } from "../src/node.js";

if (!existsSync(defaultWasmPath)) {
  throw new Error(`${defaultWasmPath} is missing. Run \`mise run wasm\` first.`);
}

let lus;
before(async () => {
  lus = await loadLus(defaultWasmPath, { env: { HOME: "/home/lus" } });
});

describe("run", () => {
  test("prints hello world", () => {
    const r = lus.run('print("hello, world")');
    assert.equal(r.ok, true);
    assert.equal(r.stdout, "hello, world\n");
    assert.equal(r.stderr, "");
    assert.equal(r.error, null);
  });

  test("reports an error with its traceback", () => {
    const r = lus.run('local function inner()\n  error("boom")\nend\ninner()\n');
    assert.equal(r.ok, false);
    assert.equal(r.exitCode, 1);
    assert.equal(r.error, "(playground):2: boom");
    assert.match(r.traceback, /^stack traceback:/);
    assert.match(r.traceback, /\(playground\):2: in local 'inner'/);
    assert.match(r.traceback, /\(playground\):4: in main chunk/);
  });

  test("runs detached coroutines after the main chunk", () => {
    const r = lus.run(
      'local function body(name)\n  for i = 1, 2 do\n    print(name, i)\n    coroutine.yield()\n  end\nend\n' +
        'coroutine.detach(coroutine.create(body), "a")\ncoroutine.detach(coroutine.create(body), "b")\nprint("main ends")\n',
    );
    assert.equal(r.ok, true);
    assert.equal(r.stdout, "main ends\na\t1\nb\t1\na\t2\nb\t2\n");
  });

  test("reports the error of a detached coroutine that nothing collected", () => {
    const r = lus.run('coroutine.detach(coroutine.create(function()\n  error("lost")\nend))\nprint("main ends")\n');
    assert.equal(r.ok, false);
    assert.equal(r.stdout, "main ends\n");
    assert.equal(r.error, "(playground):2: lost");
    assert.match(r.traceback, /^stack traceback:/);
  });

  test("reports a syntax error", () => {
    const r = lus.run("local = 1");
    assert.equal(r.ok, false);
    assert.match(r.error, /^\(playground\):1: /);
  });

  test("denies permissions that were not pledged", () => {
    const r = lus.run('print(catch io.open("/notes.txt", "w"))\nprint(catch os.getenv("HOME"))');
    assert.equal(r.ok, true);
    assert.equal(
      r.stdout,
      "false\t(playground):1: permission \"fs:write\" denied for '/notes.txt'\n" +
        "false\t(playground):2: permission \"env:read\" denied for 'HOME'\n",
    );
    assert.equal(lus.fs.exists("/notes.txt"), false);
  });

  test("refuses a pledge after the script seals its permissions", () => {
    const r = lus.run('pledge("seal")\nprint(pledge("fs:read"))\nprint(catch io.open("/x"))');
    assert.equal(r.ok, true);
    assert.equal(r.stdout, "false\nfalse\t(playground):3: permission \"fs:read\" denied for '/x'\n");
  });

  test("uses the in-memory file system with host pledges", () => {
    const r = lus.run(
      'local f = io.open("/data/out.txt", "w")\nf:write("from lus")\nf:close()\nprint(io.open("/data/in.txt"):read("a"))\nprint(os.getenv("HOME"))',
      { pledges: ["fs", "env"], files: { "/data/in.txt": "from the host" } },
    );
    assert.equal(r.error, null);
    assert.equal(r.stdout, "from the host\n/home/lus\n");
    assert.equal(lus.fs.readFile("/data/out.txt", { encoding: "utf8" }), "from lus");
  });

  test("runs string, vector, and json functions", () => {
    const r = lus.run(
      [
        'print(("héllo"):upper(), #"héllo", ("héllo"):sub(2, 2))',
        'print(table.concat(("a,b,c"):split(","), "|"), string.format("%5.2f", 3.14159))',
        'local v = vector.create(4)',
        'vector.pack(v, 0, "I4", 7)',
        "print(#v, (vector.unpack(v, 0, \"I4\")))",
        "print(tojson({1, 2, {k = true}}), fromjson('{\"a\": [1, 2]}').a[2])",
      ].join("\n"),
    );
    assert.equal(r.error, null);
    assert.equal(r.stdout, "HéLLO\t5\té\na|b|c\t 3.14\n4\t7\n[1,2,{\"k\":true}]\t2\n");
  });

  test("passes arguments and standard input", () => {
    const r = lus.run("print(select(\"#\", ...), arg[2], ...)\nprint(io.read(\"l\"))", {
      args: ["one", "two"],
      stdin: "a line\nmore\n",
    });
    assert.equal(r.stdout, "2\ttwo\tone\ttwo\na line\n");
  });

  test("raises a clear error for process creation", () => {
    const r = lus.run('print(os.execute())\nprint(catch io.popen("ls"))\nprint(catch os.execute("ls"))');
    assert.equal(
      r.stdout,
      "false\n" +
        "false\t(playground):2: io.popen is not available on this platform\n" +
        "false\t(playground):3: os.execute is not available on this platform\n",
    );
  });

  test("leaves out the network and worker libraries", () => {
    assert.equal(lus.run("print(network, worker)").stdout, "nil\tnil\n");
  });

  test("includes SQLite and the archive codecs", () => {
    const r = lus.run(
      [
        'local db = io.sqlite(":memory:")',
        'db:exec("create table t(a)")',
        'db:run("insert into t values (?)", 42)',
        'for row in db:query("select a from t") do print(row.a) end',
        'local z = vector.archive.zstd.compress("hello hello hello")',
        "print(vector.tostring(vector.archive.zstd.decompress(z)))",
      ].join("\n"),
    );
    assert.equal(r.error, null);
    assert.equal(r.stdout, "42\nhello hello hello\n");
  });

  test("turns os.exit into an exit code and recovers", () => {
    const r = lus.run('print("before")\nos.exit(3)\nprint("after")');
    assert.equal(r.exitCode, 3);
    assert.equal(r.ok, false);
    assert.equal(r.stdout, "before\n");
    assert.equal(lus.run('print("again")').stdout, "again\n");
  });

  test("reports a stack overflow as an error", () => {
    const r = lus.run("local function f() return f() + 1 end\nprint(catch f())");
    assert.equal(r.stdout, "false\tstack overflow\n");
  });

  test("keeps standard output and standard error in order", () => {
    const r = lus.run('io.write("a")\nio.stderr:write("b")\nio.write("c")');
    assert.equal(r.output, "abc");
    assert.equal(r.stdout, "ac");
    assert.equal(r.stderr, "b");
  });
});

describe("the playground interface", () => {
  test("prints expressions and keeps globals between calls", () => {
    const s = lus.create();
    try {
      assert.equal(lus.execute(s, "1 + 1"), "2\n");
      assert.equal(lus.execute(s, "x = 21"), "");
      assert.equal(lus.execute(s, "x * 2"), "42\n");
      assert.equal(lus.execute(s, 'print("out") error("bad")'), "out\n(playground):1: bad");
    } finally {
      lus.destroy(s);
    }
  });

  test("truncates long output", () => {
    const s = lus.create();
    try {
      const out = lus.execute(s, 'for i = 1, 100000 do print("0123456789") end');
      assert.ok(out.endsWith("[Output truncated at 256 KiB.]\n"));
      assert.ok(new TextEncoder().encode(out).length <= 256 * 1024);
    } finally {
      lus.destroy(s);
    }
  });
});

describe("the language server", () => {
  test("answers initialize, diagnostics, and hover", async () => {
    await mountLanguageServer(lus);
    const s = lus.create();
    try {
      assert.equal(lus.loadLsp(s), "");
      const send = (message) => lus.handleMessage(s, JSON.stringify({ jsonrpc: "2.0", ...message }));
      const frames = (raw) => {
        const out = [];
        let rest = raw;
        while (rest.length > 0) {
          const m = /^Content-Length: (\d+)\r\n\r\n/.exec(rest);
          assert.ok(m, `bad frame: ${rest.slice(0, 80)}`);
          const start = m[0].length;
          const body = Buffer.from(rest.slice(start)).subarray(0, Number(m[1])).toString();
          out.push(JSON.parse(body));
          rest = rest.slice(start + body.length);
        }
        return out;
      };

      const [init] = frames(send({ id: 1, method: "initialize", params: { capabilities: {} } }));
      assert.equal(init.id, 1);
      assert.ok(init.result.capabilities.hoverProvider);
      send({ method: "initialized", params: {} });

      const uri = "file:///main.lus";
      const opened = frames(
        send({
          method: "textDocument/didOpen",
          params: { textDocument: { uri, languageId: "lus", version: 1, text: "local x = 1\nprint(x +)\n" } },
        }),
      );
      const diagnostics = opened.find((m) => m.method === "textDocument/publishDiagnostics");
      assert.ok(diagnostics.params.diagnostics.some((d) => /unexpected symbol/.test(d.message)));

      const [hover] = frames(
        send({ id: 2, method: "textDocument/hover", params: { textDocument: { uri }, position: { line: 0, character: 6 } } }),
      );
      assert.match(hover.result.contents.value, /local x/);

      const [bad] = frames(lus.handleMessage(s, "{not json"));
      assert.ok(bad.error);
    } finally {
      lus.destroy(s);
    }
  });
});
