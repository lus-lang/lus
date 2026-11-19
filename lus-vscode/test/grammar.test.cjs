const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..", "..");
const grammarFile = path.join(root, "lus-textmate", "lus.tmLanguage.json");
const fixtureDirectory = path.join(root, "lus-textmate", "test", "fixtures");

async function createTokenizer() {
  const textmate = await import("@shikijs/vscode-textmate");
  const {createJavaScriptRegexEngine} = await import(
    "@shikijs/engine-javascript"
  );
  const rawGrammar = JSON.parse(fs.readFileSync(grammarFile, "utf8"));
  const engine = createJavaScriptRegexEngine();
  const registry = new textmate.Registry({
    onigLib: {
      createOnigScanner(sources) {
        return engine.createScanner(sources);
      },
      createOnigString(value) {
        return engine.createString(value);
      },
    },
    loadGrammar(scopeName) {
      return scopeName === rawGrammar.scopeName ? rawGrammar : null;
    },
  });
  const grammar = registry.loadGrammar(rawGrammar.scopeName);
  assert.ok(grammar, "the Lus grammar should load");

  return {
    tokenize(source) {
      let ruleStack = textmate.INITIAL;
      return source.split("\n").map((line) => {
        const result = grammar.tokenizeLine(line, ruleStack);
        ruleStack = result.ruleStack;
        return result.tokens.map((token) => ({
          content: line.slice(token.startIndex, token.endIndex),
          scopes: token.scopes,
        }));
      });
    },
    dispose() {
      registry.dispose();
    },
  };
}

function readFixture(name) {
  return fs.readFileSync(path.join(fixtureDirectory, name), "utf8").trimEnd();
}

function assertScope(lines, lineNumber, content, scope) {
  const token = lines[lineNumber - 1].find((candidate) => (
    candidate.content === content && candidate.scopes.includes(scope)
  ));
  assert.ok(
    token,
    `line ${lineNumber} should tokenize ${JSON.stringify(content)} as ${scope}`,
  );
}

test("the grammar tokenizes generated 1.7 builtins", async () => {
  const tokenizer = await createTokenizer();
  try {
    const lines = tokenizer.tokenize(readFixture("builtins-1.7.lus"));
    assertScope(lines, 1, "fromcsv", "support.function.lus");
    assertScope(lines, 2, "io.sqlite", "support.function.library.lus");
    assertScope(lines, 3, "table.reshape", "support.function.library.lus");
    assertScope(
      lines,
      4,
      "vector.archive.gzip.compress",
      "support.function.library.lus",
    );
    assertScope(lines, 5, "time.instant", "support.function.library.lus");
    assertScope(lines, 6, "time.month", "constant.language.lus");

    assert.equal(
      lines[6].some((token) => token.scopes.includes("support.function.library.lus")),
      false,
      "assignment targets should not be highlighted as builtin calls",
    );
    assert.equal(
      lines[7].some((token) => token.scopes.includes("support.function.library.lus")),
      false,
      "qualified user fields should not match a builtin suffix",
    );
  } finally {
    tokenizer.dispose();
  }
});

test("the grammar tokenizes representative 1.7 syntax", async () => {
  const tokenizer = await createTokenizer();
  try {
    const lines = tokenizer.tokenize(readFixture("syntax-1.7.lus"));
    assertScope(lines, 1, "enum", "keyword.control.lus");
    assertScope(lines, 2, "catch", "keyword.control.lus");
    assertScope(lines, 2, "network.fetch", "support.function.library.lus");
    assertScope(lines, 3, "?.", "keyword.operator.lus");
    assertScope(lines, 4, "from", "keyword.control.lus");
    assertScope(lines, 6, "provide", "keyword.control.lus");
    assertScope(
      lines,
      8,
      "$(",
      "punctuation.section.interpolation.begin.lus",
    );
    assertScope(lines, 9, "where", "keyword.control.query.lus");
    assertScope(lines, 9, "select", "keyword.control.query.lus");
  } finally {
    tokenizer.dispose();
  }
});
