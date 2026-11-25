const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..", "..");
const grammarFile = path.join(root, "textmate", "lus.tmLanguage.json");
const fixtureDirectory = path.join(root, "textmate", "test", "fixtures");

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

function hasScope(lines, lineNumber, scope) {
  return lines[lineNumber - 1].some((token) => token.scopes.includes(scope));
}

test("the grammar tokenizes generated builtins", async () => {
  const tokenizer = await createTokenizer();
  try {
    const lines = tokenizer.tokenize(readFixture("builtins.lus"));
    const expected = [
      [1, "fromjson", "support.function.lus"],
      [2, "decimal", "support.function.lus"],
      [3, "crypto.hash", "support.function.library.lus"],
      [4, "vector.archive.zstd.compress", "support.function.library.lus"],
      [5, "os.spawn", "support.function.library.lus"],
      [6, "table.clone", "support.function.library.lus"],
      [7, "time.weekday", "constant.language.lus"],
      [8, "math.pi", "constant.language.lus"],
    ];
    for (const [line, content, scope] of expected) {
      assertScope(lines, line, content, scope);
    }
    assert.equal(
      hasScope(lines, 9, "support.function.library.lus"),
      false,
      "assignment targets should not be highlighted as builtin calls",
    );
    assert.equal(
      hasScope(lines, 10, "support.function.library.lus"),
      false,
      "qualified user fields should not match a builtin suffix",
    );
  } finally {
    tokenizer.dispose();
  }
});

test("the grammar tokenizes every construct of the language", async () => {
  const tokenizer = await createTokenizer();
  try {
    const lines = tokenizer.tokenize(readFixture("syntax.lus"));
    const expected = [
      [1, "#!", "comment.line.shebang.lus"],
      [2, "global", "keyword.global.lus"],
      [2, "<const>", "storage.type.attribute.lus"],
      [3, "*", "keyword.operator.lus"],
      [4, "pledge", "support.function.lus"],
      [6, "--", "comment.line.double-dash.lus"],
      [7, "--[[", "comment.block.lus"],
      [9, " A long comment ]] with a level. ", "comment.block.lus"],
      [11, "42", "constant.numeric.integer.lus"],
      [11, "1_000_000", "constant.numeric.integer.lus"],
      [11, "3.25", "constant.numeric.float.lus"],
      [11, "1.5e-3", "constant.numeric.float.lus"],
      [12, "0xff_ff", "constant.numeric.integer.hexadecimal.lus"],
      [12, "0x1.8p1", "constant.numeric.float.hexadecimal.lus"],
      [12, "12345678901234567890n", "constant.numeric.integer.bigint.lus"],
      [12, "0xffn", "constant.numeric.integer.bigint.lus"],
      [12, "1.25d", "constant.numeric.decimal.lus"],
      [14, "\\'", "constant.character.escape.lus"],
      [14, "\\x41", "constant.character.escape.byte.lus"],
      [14, "\\u{e9}", "constant.character.escape.unicode.lus"],
      [14, "\\065", "constant.character.escape.byte.lus"],
      [15, "raw ]] text", "string.quoted.other.multiline.lus"],
      [17, "$name", "variable.other.interpolated.lus"],
      [17, "$(", "punctuation.section.interpolation.begin.lus"],
      [17, "$$", "constant.character.escape.lus"],
      [17, "\\`", "constant.character.escape.lus"],
      [17, "\\$", "constant.character.escape.lus"],
      [18, "inner ", "string.quoted.template.lus"],
      [20, "second line ", "string.quoted.template.lus"],
      [22, "enum", "keyword.control.lus"],
      [22, "North", "variable.other.enummember.lus"],
      [23, "from", "keyword.control.lus"],
      [24, "from", "keyword.control.lus"],
      [28, "<close>", "storage.type.attribute.lus"],
      [29, "<group>", "storage.type.attribute.lus"],
      [30, "<lazy>", "storage.type.attribute.lus"],
      [31, "<observe>", "storage.type.attribute.lus"],
      [32, "<context>", "storage.type.attribute.lus"],
      [33, "only", "storage.type.attribute.lus"],
      [35, "catch", "keyword.control.lus"],
      [36, "[", "punctuation.section.brackets.begin.lus"],
      [37, "catch", "keyword.control.lus"],
      [39, "?.", "keyword.operator.lus"],
      [40, "?", "keyword.operator.lus"],
      [41, "?", "keyword.operator.lus"],
      [45, "if", "keyword.control.lus"],
      [47, "<const>", "storage.type.attribute.lus"],
      [51, "while", "keyword.control.lus"],
      [53, "continue", "keyword.control.lus"],
      [57, "do", "keyword.control.lus"],
      [58, "//", "keyword.operator.lus"],
      [59, "provide", "keyword.control.lus"],
      [59, "..", "keyword.operator.lus"],
      [62, "<<", "keyword.operator.lus"],
      [62, ">>", "keyword.operator.lus"],
      [62, "|", "keyword.operator.lus"],
      [62, "&", "keyword.operator.lus"],
      [62, "~", "keyword.operator.lus"],
      [63, "~=", "keyword.operator.lus"],
      [65, "@", "keyword.operator.query.lus"],
      [65, "as", "keyword.control.query.lus"],
      [66, "where", "keyword.control.query.lus"],
      [66, "nil", "keyword.operator.query.lus"],
      [67, "group", "keyword.control.query.lus"],
      [67, "by", "keyword.control.query.lus"],
      [68, "having", "keyword.control.query.lus"],
      [68, "count", "support.function.query.lus"],
      [69, "select", "keyword.control.query.lus"],
      [69, "distinct", "keyword.control.query.lus"],
      [69, "avg", "support.function.query.lus"],
      [70, "order", "keyword.control.query.lus"],
      [70, "desc", "keyword.control.query.lus"],
      [71, "limit", "keyword.control.query.lus"],
      [72, "offset", "keyword.control.query.lus"],
      [74, "load", "entity.name.function.lus"],
      [74, "...", "constant.language.lus"],
      [76, "self", "variable.language.self.lus"],
      [79, "Config", "entity.name.class.lus"],
      [79, "rest", "variable.parameter.function.lus"],
      [83, "helper", "entity.name.function.lus"],
      [84, "goto", "keyword.control.goto.lus"],
      [85, "done", "string.tag.lus"],
      [89, "global", "keyword.global.lus"],
      [89, "exported", "entity.name.function.lus"],
      [90, "flags", "constant.language.lus"],
      [90, "_ENV", "constant.language.lus"],
      [93, "repeat", "keyword.control.lus"],
      [95, "until", "keyword.control.lus"],
    ];
    for (const [line, content, scope] of expected) {
      assertScope(lines, line, content, scope);
    }
    assert.equal(
      hasScope(lines, 69, "support.function.lus"),
      false,
      "a query clause keyword should not be highlighted as a builtin",
    );
    assert.equal(
      hasScope(lines, 74, "meta.query.lus"),
      false,
      "a query should end at the blank line after it",
    );
  } finally {
    tokenizer.dispose();
  }
});
