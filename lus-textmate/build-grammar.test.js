#!/usr/bin/env node

const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");

const {buildGraph} = require("../lus-spec/build-lsp.js");
const {
  buildBuiltinPatterns,
  collectBuiltinNames,
  renderGrammar,
} = require("./build-grammar.js");

const symbols = buildGraph();
const names = collectBuiltinNames(symbols);

assert.ok(names.globalFunctions.includes("fromcsv"));
assert.ok(names.globalFunctions.includes("query"));
assert.ok(names.globalFunctions.includes("tocsv"));
assert.ok(names.qualifiedFunctions.includes("io.sqlite"));
assert.ok(names.qualifiedFunctions.includes("string.join"));
assert.ok(names.qualifiedFunctions.includes("table.reshape"));
assert.ok(names.qualifiedFunctions.includes("time.instant"));
assert.ok(
  names.qualifiedFunctions.includes("vector.archive.gzip.compress"),
);
assert.ok(names.constants.includes("time.month"));
assert.ok(names.constants.includes("time.weekday"));

for (const symbol of symbols.values()) {
  if (symbol.kind === "function") {
    const list = symbol.name.includes(".") || symbol.name.includes(":")
      ? names.qualifiedFunctions
      : names.globalFunctions;
    assert.equal(
      list.filter((name) => name === symbol.name).length,
      1,
      `${symbol.name} should occur exactly once`,
    );
  } else if (symbol.kind === "constant" || symbol.kind === "variable") {
    assert.equal(
      names.constants.filter((name) => name === symbol.name).length,
      1,
      `${symbol.name} should occur exactly once`,
    );
  }
}
for (const literal of ["false", "nil", "true"]) {
  assert.equal(
    names.constants.filter((name) => name === literal).length,
    1,
    `${literal} should occur exactly once`,
  );
}

const patterns = buildBuiltinPatterns(symbols);
for (const pattern of Object.values(patterns)) {
  assert.doesNotThrow(() => new RegExp(pattern, "u"));
}

const prefixGraph = new Map([
  ["call", {name: "call", kind: "function"}],
  ["package.call", {name: "package.call", kind: "function"}],
  ["package.call.deep", {name: "package.call.deep", kind: "function"}],
]);
const prefixPattern = new RegExp(
  buildBuiltinPatterns(prefixGraph).qualifiedFunctions,
  "u",
);
assert.equal(prefixPattern.exec("package.call.deep(value)")[0], "package.call.deep");

const template = fs.readFileSync(
  path.join(__dirname, "lus.tmLanguage.template.json"),
  "utf8",
);
const first = renderGrammar(symbols, template);
const second = renderGrammar(symbols, template);
assert.equal(first, second);
assert.doesNotMatch(first, /@@LUS_BUILTIN_/);

const grammar = JSON.parse(first);
assert.equal(grammar.name, "lus");
assert.equal(grammar.scopeName, "source.lus");
const generatedScopes = new Map(
  grammar.patterns
    .filter((pattern) => [
      "constant.language.lus",
      "support.function.lus",
      "support.function.library.lus",
    ].includes(pattern.name))
    .map((pattern) => [pattern.name, pattern.match]),
);
assert.equal(generatedScopes.get("constant.language.lus"), patterns.constants);
assert.equal(
  generatedScopes.get("support.function.lus"),
  patterns.globalFunctions,
);
assert.equal(
  generatedScopes.get("support.function.library.lus"),
  patterns.qualifiedFunctions,
);

console.log(`Validated ${symbols.size} symbols in the TextMate generator`);
