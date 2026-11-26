// Tests tools/build-cli.js on the repository as it is.
const assert = require("node:assert/strict");
const cli = require("./build-cli.js");

const spec = cli.loadSpec();
const command = (name) => spec.commands.find((c) => c.name === name);

// The source, the parsers, and the manual agree.
assert.deepEqual(cli.checks(), []);

// The parser of `lus fmt` recognizes its options, and those of main.zig
// come from its option table.
assert.deepEqual([...cli.parsedOptions(require("path").join(__dirname, ".."), command("fmt"))].sort(), ["--check", "--indent", "--strict", "--write"]);
assert.ok(cli.parsedOptions(require("path").join(__dirname, ".."), command("run")).has("--sandbox"));

// The usage text lists the visible options and leaves the hidden ones out.
const testUsage = cli.usageText(spec, command("test"));
assert.match(testUsage, /^usage: lus test \[options\] \[path \.\.\.\]\n/);
assert.match(testUsage, /--file-timeout S/);
assert.doesNotMatch(testUsage, /--run-one/);
assert.match(cli.usageText(spec, command("run")), /\n {2}completions {2}print a shell completion script\n/);

// Inline Markdown becomes roff, with the dashes of code escaped.
assert.equal(cli.roffInline("Use `--json` with [`lus test`](/manual/testing)."), "Use \\fB\\-\\-json\\fR with \\fBlus test\\fR.");

// A table cell keeps an escaped pipe.
const [table] = cli.blocks(["| A | B |", "| --- | --- |", "| `a\\|b` | c |"]);
assert.deepEqual(table.rows, [["`a|b`", "c"]]);

// Every output is generated, and every man page names its command.
const outputs = new Map(cli.outputs());
for (const c of spec.commands) {
  const page = c.default ? "lus" : `lus-${c.name}`;
  const text = outputs.get(`packaging/share/man/man1/${page}.1`);
  assert.ok(text, page);
  assert.match(text, new RegExp(`^\\.TH ${page.toUpperCase()} 1 `, "m"));
}
const dashes = new RegExp(`[${String.fromCharCode(0x2013, 0x2014)}]`);
for (const text of outputs.values()) assert.doesNotMatch(text, dashes);
console.log("build-cli: all checks passed");
