#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const {buildGraph, SpecError} = require("../lus-spec/build-lsp.js");

const TEMPLATE_FILE = path.join(__dirname, "lus.tmLanguage.template.json");
const CANONICAL_FILE = path.join(__dirname, "lus.tmLanguage.json");
const EXTENSION_FILE = path.join(
  __dirname,
  "..",
  "lus-vscode",
  "syntaxes",
  "lus.tmLanguage.json",
);

const PLACEHOLDERS = {
  "@@LUS_BUILTIN_CONSTANTS@@": "constants",
  "@@LUS_BUILTIN_GLOBAL_FUNCTIONS@@": "globalFunctions",
  "@@LUS_BUILTIN_QUALIFIED_FUNCTIONS@@": "qualifiedFunctions",
};

class GrammarError extends Error {}

function compareText(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function compareRegexAlternatives(left, right) {
  const lengthOrder = right.length - left.length;
  return lengthOrder || compareText(left, right);
}

function escapeRegex(value) {
  return value.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
}

function collectBuiltinNames(symbols) {
  const constants = new Set(["false", "nil", "true"]);
  const globalFunctions = [];
  const qualifiedFunctions = [];

  for (const symbol of symbols.values()) {
    if (symbol.kind === "constant" || symbol.kind === "variable") {
      constants.add(symbol.name);
    } else if (symbol.kind === "function") {
      if (symbol.name.includes(".") || symbol.name.includes(":")) {
        qualifiedFunctions.push(symbol.name);
      } else {
        globalFunctions.push(symbol.name);
      }
    }
  }

  return {
    constants: [...constants].sort(compareRegexAlternatives),
    globalFunctions: globalFunctions.sort(compareRegexAlternatives),
    qualifiedFunctions: qualifiedFunctions.sort(compareRegexAlternatives),
  };
}

function alternation(names) {
  if (names.length === 0) throw new GrammarError("builtin list is empty");
  return `(?:${alternationSource(names)})`;
}

function alternationSource(names) {
  return names.map(escapeRegex).join("|");
}

function buildBuiltinPatterns(symbols) {
  const names = collectBuiltinNames(symbols);
  const constantNames = names.constants.filter((name) => name !== "nil");

  return {
    constants: `(?<![^.]\\.|:)\\b(?:${alternationSource(constantNames)}|nil(?!:))\\b|(?<![.])\\.{3}(?!\\.)`,
    globalFunctions: `(?<![^.]\\.|:)\\b${alternation(names.globalFunctions)}\\b(?!\\s*=(?!=))`,
    qualifiedFunctions: `(?<![^.]\\.|:)\\b${alternation(names.qualifiedFunctions)}\\b(?!\\s*=(?!=))`,
  };
}

function replacePlaceholders(value, patterns, counts) {
  if (Array.isArray(value)) {
    return value.map((entry) => replacePlaceholders(entry, patterns, counts));
  }
  if (value && typeof value === "object") {
    const result = {};
    for (const [key, entry] of Object.entries(value)) {
      result[key] = replacePlaceholders(entry, patterns, counts);
    }
    return result;
  }
  if (typeof value === "string" && Object.hasOwn(PLACEHOLDERS, value)) {
    counts[value] += 1;
    return patterns[PLACEHOLDERS[value]];
  }
  return value;
}

function renderGrammar(symbols, templateText) {
  let template;
  try {
    template = JSON.parse(templateText);
  } catch (error) {
    throw new GrammarError(`${TEMPLATE_FILE}: ${error.message}`);
  }

  const counts = Object.fromEntries(
    Object.keys(PLACEHOLDERS).map((placeholder) => [placeholder, 0]),
  );
  const grammar = replacePlaceholders(
    template,
    buildBuiltinPatterns(symbols),
    counts,
  );
  for (const [placeholder, count] of Object.entries(counts)) {
    if (count !== 1) {
      throw new GrammarError(
        `${TEMPLATE_FILE}: expected one ${placeholder} placeholder, found ${count}`,
      );
    }
  }
  return `${JSON.stringify(grammar, null, 2)}\n`;
}

function checkFile(file, expected) {
  let current;
  try {
    current = fs.readFileSync(file, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") {
      throw new GrammarError(`${file} is missing. Run node lus-textmate/build-grammar.js`);
    }
    throw error;
  }
  if (current !== expected) {
    throw new GrammarError(`${file} is stale. Run node lus-textmate/build-grammar.js`);
  }
}

function main(argv = process.argv.slice(2)) {
  const unknown = argv.filter((argument) => argument !== "--check");
  if (unknown.length > 0) throw new GrammarError(`unknown option ${unknown[0]}`);

  const symbols = buildGraph();
  const template = fs.readFileSync(TEMPLATE_FILE, "utf8");
  const output = renderGrammar(symbols, template);
  if (argv.includes("--check")) {
    checkFile(CANONICAL_FILE, output);
    checkFile(EXTENSION_FILE, output);
    console.log(`Checked ${symbols.size} symbols in both TextMate grammars`);
    return;
  }

  fs.writeFileSync(CANONICAL_FILE, output);
  fs.writeFileSync(EXTENSION_FILE, output);
  console.log(`Generated ${CANONICAL_FILE}`);
  console.log(`Generated ${EXTENSION_FILE}`);
  console.log(`  ${symbols.size} symbols`);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    if (error instanceof GrammarError || error instanceof SpecError) {
      console.error(error.message);
    } else {
      console.error(error.stack);
    }
    process.exitCode = 1;
  }
}

module.exports = {
  GrammarError,
  buildBuiltinPatterns,
  collectBuiltinNames,
  main,
  renderGrammar,
};
