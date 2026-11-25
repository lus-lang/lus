const assert = require("node:assert/strict");
const test = require("node:test");

const {
  baseName,
  failureLine,
  findTests,
  parseLcov,
  parseRecord,
} = require("../.test-out/testDiscovery.js");

test("finds top-level tests and benchmarks with their lines", () => {
  const found = findTests([
    "local m = require(\"m\")",
    "",
    "local function adds_test()",
    "    assert(m.add(1, 2) == 3)",
    "end",
    "function global_test() end",
    "local lambda_test = function() end",
    "local function sort_bench()",
    "    local function inner_test() end",
    "end",
    "local cases_test_data = {}",
  ].join("\n"));
  assert.deepEqual(found, [
    { name: "adds_test", line: 2, kind: "test" },
    { name: "global_test", line: 5, kind: "test" },
    { name: "lambda_test", line: 6, kind: "test" },
    { name: "sort_bench", line: 7, kind: "bench" },
  ]);
});

test("parses the records of lus test --json", () => {
  const rec = parseRecord('{"status":"fail","name":"adds_test[2]","file":"m_test.lus","line":3,"duration":0.25,"message":"m_test.lus:4: assertion failed: x"}');
  assert.equal(rec.status, "fail");
  assert.equal(baseName(rec.name), "adds_test");
  assert.equal(rec.duration, 0.25);
  assert.equal(failureLine(rec.message, "m_test.lus"), 3);
  assert.equal(failureLine("no position", "m_test.lus"), undefined);
  assert.equal(parseRecord("plain output"), undefined);
  assert.equal(parseRecord("{not json"), undefined);
  const bench = parseRecord('{"status":"bench","name":"sort_bench","file":"x","line":1,"duration":5,"message":"","ns":41.5}');
  assert.equal(bench.ns, 41.5);
});

test("parses an lcov tracefile", () => {
  const files = parseLcov("SF:/w/src/m.lus\nDA:1,1\nDA:4,0\nLF:2\nLH:1\nend_of_record\nSF:/w/b.lus\nDA:2,1\nend_of_record\n");
  assert.equal(files.length, 2);
  assert.equal(files[0].path, "/w/src/m.lus");
  assert.deepEqual([...files[0].lines], [[1, 1], [4, 0]]);
  assert.deepEqual([...files[1].lines], [[2, 1]]);
});
