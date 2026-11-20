#!/usr/bin/env node

const assert = require("assert/strict");

const {
  build,
  validate,
  signature,
  mdxToMarkdown,
  rewriteLinks,
  estimateTokens,
  SMALL_TOKEN_BUDGET,
} = require("./build-llms.js");

// Signatures mark optional parameters, varargs, and nil results.
assert.equal(
  signature({
    name: "string.find",
    kind: "function",
    params: [{name: "s"}, {name: "pattern"}, {name: "init", optional: true}],
    returns: "integer|nil",
  }),
  "string.find(s, pattern, init?) -> integer?",
);
assert.equal(
  signature({name: "print", kind: "function", params: [], vararg: true}),
  "print(...)",
);
assert.equal(
  signature({
    name: "sock:getsockname",
    kind: "function",
    returns: [{name: "address", type: "string"}, {name: "port", type: "integer"}],
  }),
  "sock:getsockname() -> address: string, port: integer",
);
assert.equal(signature({name: "math.pi", kind: "constant"}), "math.pi");

// Manual links point at Markdown twins, other site links at HTML pages.
assert.equal(rewriteLinks("[g](/manual/guide#scope)"), "[g](https://lus.dev/manual/guide.md#scope)");
assert.equal(rewriteLinks("[a](/manual/api#string.find)"), "[a](https://lus.dev/manual/api.md#string.find)");
assert.equal(rewriteLinks("[p](/playground)"), "[p](https://lus.dev/playground)");
assert.equal(rewriteLinks("[c](/manual/api/c)"), "[c](https://lus.dev/manual/api/c)");
assert.equal(rewriteLinks("[x](https://example.com/a)"), "[x](https://example.com/a)");

// MDX imports and components go, code inside fences stays verbatim, and
// test markers leave the fence info.
const mdx = [
  'import Thing from "../components/Thing.astro"',
  "",
  "Text.",
  "",
  "<Thing count={3} />",
  "",
  "```lus nocheck",
  'import x from "y"',
  "<Tag />",
  "```",
  "",
  "<Box>",
  "inside",
  "</Box>",
  "",
  "<List />",
].join("\n");
assert.equal(
  mdxToMarkdown(mdx, {components: {List: "- one"}}),
  ["Text.", "", "```lus", 'import x from "y"', "<Tag />", "```", "", "- one"].join("\n"),
);

// The real tree builds, validates, and stays within budget.
const result = build();
assert.deepEqual(validate(result), []);
for (const name of ["llms.txt", "llms-full.txt", "llms-small.txt", "manual/api.md", "manual/guide.md", "agents/skills/lus/SKILL.md"]) {
  assert.ok(result.files.has(name), `missing ${name}`);
}
assert.ok(estimateTokens(result.files.get("llms-small.txt")) <= SMALL_TOKEN_BUDGET);
const full = result.files.get("llms-full.txt");
for (const id of ["guide", "permissions", "network", "testing"]) {
  const page = result.pages.find((p) => p.id === id);
  assert.ok(page && full.includes(`## ${page.meta.title}\n`), `llms-full.txt lacks ${id}`);
}
for (const e of result.stdlib) {
  assert.ok(result.files.get("manual/api.md").includes(`### ${e.name}\n`), `api.md lacks ${e.name}`);
}

// Validation reports leftovers and broken links.
const broken = new Map([
  ["llms-small.txt", ""],
  ["manual/x.md", "<Widget />\n[y](https://lus.dev/manual/missing.md)\n"],
]);
const problems = validate({files: broken, stdlib: []});
assert.ok(problems.some((p) => p.includes("MDX left")));
assert.ok(problems.some((p) => p.includes("missing https://lus.dev/manual/missing.md")));

console.log("build-llms tests passed");
