#!/usr/bin/env node

const assert = require("assert/strict");
const path = require("path");

const {
  SpecError,
  buildGraph,
  parseFrontmatter,
  renderGraph,
  validateEntry,
} = require("./build-lsp.js");

const fixture = `---
name: time.instant.epoch
module: time
kind: function
since: 1.7.0
stability: stable
origin: lus
params: []
returns:
  - name: seconds
    type: integer
    flags: [exact]
  - name: nanos
    type: integer
    from: fraction
receiver: instant
flags: [method, pure]
from: time.instant
---

Returns the epoch components.
`;

const parsed = parseFrontmatter(fixture, "fixture.md");
assert.equal(parsed.frontmatter.name, "time.instant.epoch");
assert.deepEqual(parsed.frontmatter.params, []);
assert.deepEqual(parsed.frontmatter.flags, ["method", "pure"]);
assert.equal(parsed.frontmatter.from, "time.instant");
assert.deepEqual(parsed.frontmatter.returns, [
  {name: "seconds", type: "integer", flags: ["exact"]},
  {name: "nanos", type: "integer", from: "fraction"},
]);
assert.equal(parsed.body, "Returns the epoch components.");
validateEntry(parsed.frontmatter, "fixture.md");

assert.throws(
  () => validateEntry({...parsed.frontmatter, stability: "preview"}, "bad.md"),
  (error) => error instanceof SpecError && /invalid stability/.test(error.message),
);
assert.throws(
  () => parseFrontmatter(fixture.replace("kind: function", "kind: function\nkind: variable"), "bad.md"),
  (error) => error instanceof SpecError && /duplicate key kind/.test(error.message),
);
assert.throws(
  () => validateEntry({...parsed.frontmatter, typo: true}, "bad.md"),
  (error) => error instanceof SpecError && /unsupported frontmatter field typo/.test(error.message),
);
assert.throws(
  () => validateEntry({...parsed.frontmatter, receiver: "bad:receiver"}, "bad.md"),
  (error) => error instanceof SpecError && /invalid receiver/.test(error.message),
);

const graph = buildGraph(path.join(__dirname, "..", "spec", "stdlib"));
assert.equal(graph.get("time").source, "stdlib/time/_module.md");
assert.equal(graph.get("time.instant").returns[0].type, "instant");
assert.equal(graph.get("io.sqlite").returns[0].type, "database");
assert.deepEqual(graph.get("table.unzip").returns, [{type: "table", name: "..."}]);
assert.equal(graph.get("io.flush").params.length, 0);
assert.equal(graph.get("flags").type, "table");
assert.equal(graph.get("fs.path.join").vararg, true);
assert.equal(graph.get("vector.archive.gzip").kind, "module");
assert.ok(graph.get("vector.archive.gzip").children.includes("vector.archive.gzip.compress"));
assert.equal(graph.get("tcp_socket").kind, "type");
assert.equal(graph.get("tcp_socket").receiver_type, true);
assert.ok(graph.get("tcp_socket").children.includes("tcp_socket:receive"));
assert.equal(graph.get("tcp_socket:receive").parent, "tcp_socket");

const first = renderGraph(graph);
const second = renderGraph(graph);
assert.equal(first, second);
assert.match(first, /M\.symbols = \{/);
assert.doesNotMatch(first, /M\.signatures = \{/);

console.log(`Validated ${graph.size} standard library symbols`);
