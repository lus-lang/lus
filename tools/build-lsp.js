#!/usr/bin/env node
// Builds the language server standard library graph from spec/stdlib.
// Run: node tools/build-lsp.js [--check]

const fs = require("fs");
const path = require("path");

const SPEC_DIR = path.join(__dirname, "..", "spec", "stdlib");
const OUT_FILE = path.join(
  __dirname,
  "..",
  "packages",
  "language-server",
  "analysis",
  "stdlib_data.lus",
);

const TOP_LEVEL_FIELDS = new Set([
  "name",
  "module",
  "kind",
  "since",
  "stability",
  "origin",
  "params",
  "vararg",
  "returns",
  "type",
  "generic",
  "fastcall",
  "pledges",
  "flags",
  "from",
  "receiver",
  "deprecated_by",
  "removed_in",
]);

const KINDS = new Set(["function", "constant", "variable", "module", "type"]);
const STABILITIES = new Set(["stable", "unstable", "deprecated", "removed"]);
const ORIGINS = new Set(["lua", "lus"]);

class SpecError extends Error {}

function compareText(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function parseError(source, line, message) {
  throw new SpecError(`${source}:${line}: ${message}`);
}

function splitFlow(value, source, line) {
  const values = [];
  let start = 0;
  let quote = null;
  let depth = 0;
  for (let i = 0; i < value.length; i += 1) {
    const char = value[i];
    if (quote) {
      if (char === quote && value[i - 1] !== "\\") quote = null;
    } else if (char === '"' || char === "'") {
      quote = char;
    } else if (char === "[" || char === "{") {
      depth += 1;
    } else if (char === "]" || char === "}") {
      depth -= 1;
    } else if (char === "," && depth === 0) {
      values.push(value.slice(start, i).trim());
      start = i + 1;
    }
  }
  if (quote || depth !== 0) parseError(source, line, "unterminated flow value");
  values.push(value.slice(start).trim());
  return values;
}

function parseScalar(raw, source, line) {
  const value = raw.trim();
  if (value === "") parseError(source, line, "missing scalar value");
  if (value === "true") return true;
  if (value === "false") return false;
  if (value === "null" || value === "~") return null;
  if (/^-?(?:0|[1-9]\d*)(?:\.\d+)?$/.test(value)) return Number(value);
  if (value.startsWith('"')) {
    try {
      return JSON.parse(value);
    } catch (error) {
      parseError(source, line, `invalid quoted string: ${error.message}`);
    }
  }
  if (value.startsWith("'")) {
    if (!value.endsWith("'") || value.length < 2) {
      parseError(source, line, "unterminated quoted string");
    }
    return value.slice(1, -1).replace(/''/g, "'");
  }
  if (value.startsWith("[") || value.startsWith("{")) {
    const open = value[0];
    const close = open === "[" ? "]" : "}";
    if (!value.endsWith(close)) parseError(source, line, "unterminated flow value");
    const inner = value.slice(1, -1).trim();
    if (inner === "") return open === "[" ? [] : {};
    const parts = splitFlow(inner, source, line);
    if (open === "[") {
      return parts.map((part) => parseScalar(part, source, line));
    }
    const result = {};
    for (const part of parts) {
      const match = part.match(/^([A-Za-z_][A-Za-z0-9_]*):\s*(.+)$/);
      if (!match) parseError(source, line, `invalid flow mapping entry ${part}`);
      if (Object.hasOwn(result, match[1])) {
        parseError(source, line, `duplicate key ${match[1]}`);
      }
      result[match[1]] = parseScalar(match[2], source, line);
    }
    return result;
  }
  if (/^[>|]/.test(value)) {
    parseError(source, line, "block scalar frontmatter is unsupported");
  }
  return value;
}

function tokenizeFrontmatter(frontmatter, source, lineOffset) {
  const tokens = [];
  const lines = frontmatter.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    if (/\t/.test(raw)) parseError(source, i + lineOffset, "tabs are unsupported");
    if (/^\s*$/.test(raw) || /^\s*#/.test(raw)) continue;
    const indent = raw.match(/^ */)[0].length;
    if (indent % 2 !== 0) {
      parseError(source, i + lineOffset, "indentation must use pairs of spaces");
    }
    tokens.push({indent, text: raw.slice(indent), line: i + lineOffset});
  }
  return tokens;
}

function parseMappingEntry(text, source, line) {
  const match = text.match(/^([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$/);
  if (!match) parseError(source, line, `invalid mapping entry ${text}`);
  return {key: match[1], rawValue: match[2]};
}

function parseBlock(tokens, index, indent, source) {
  if (index >= tokens.length || tokens[index].indent < indent) {
    return {value: null, next: index};
  }
  if (tokens[index].indent !== indent) {
    parseError(source, tokens[index].line, "unexpected indentation");
  }

  if (tokens[index].text.startsWith("- ") || tokens[index].text === "-") {
    const result = [];
    while (index < tokens.length && tokens[index].indent === indent) {
      const token = tokens[index];
      if (!(token.text.startsWith("- ") || token.text === "-")) {
        parseError(source, token.line, "mixed sequence and mapping entries");
      }
      const item = token.text.slice(1).trim();
      index += 1;
      if (item === "") {
        if (index >= tokens.length || tokens[index].indent <= indent) {
          parseError(source, token.line, "empty sequence entry");
        }
        const nested = parseBlock(tokens, index, indent + 2, source);
        result.push(nested.value);
        index = nested.next;
      } else if (/^[A-Za-z_][A-Za-z0-9_]*:/.test(item)) {
        const first = parseMappingEntry(item, source, token.line);
        const object = {};
        if (first.rawValue === undefined) {
          if (index >= tokens.length || tokens[index].indent <= indent) {
            parseError(source, token.line, `missing value for ${first.key}`);
          }
          const nested = parseBlock(tokens, index, indent + 2, source);
          object[first.key] = nested.value;
          index = nested.next;
        } else {
          object[first.key] = parseScalar(first.rawValue, source, token.line);
        }
        while (index < tokens.length && tokens[index].indent === indent + 2
               && !tokens[index].text.startsWith("- ")) {
          const propertyToken = tokens[index];
          const property = parseMappingEntry(
            propertyToken.text,
            source,
            propertyToken.line,
          );
          if (Object.hasOwn(object, property.key)) {
            parseError(source, propertyToken.line, `duplicate key ${property.key}`);
          }
          index += 1;
          if (property.rawValue === undefined) {
            if (index >= tokens.length || tokens[index].indent <= indent + 2) {
              parseError(source, propertyToken.line, `missing value for ${property.key}`);
            }
            const nested = parseBlock(tokens, index, indent + 4, source);
            object[property.key] = nested.value;
            index = nested.next;
          } else {
            object[property.key] = parseScalar(
              property.rawValue,
              source,
              propertyToken.line,
            );
          }
        }
        result.push(object);
      } else {
        result.push(parseScalar(item, source, token.line));
      }
    }
    return {value: result, next: index};
  }

  const result = {};
  while (index < tokens.length && tokens[index].indent === indent) {
    const token = tokens[index];
    const entry = parseMappingEntry(token.text, source, token.line);
    if (Object.hasOwn(result, entry.key)) {
      parseError(source, token.line, `duplicate key ${entry.key}`);
    }
    index += 1;
    if (entry.rawValue === undefined) {
      if (index >= tokens.length || tokens[index].indent <= indent) {
        parseError(source, token.line, `missing value for ${entry.key}`);
      }
      const nested = parseBlock(tokens, index, indent + 2, source);
      result[entry.key] = nested.value;
      index = nested.next;
    } else {
      result[entry.key] = parseScalar(entry.rawValue, source, token.line);
    }
  }
  return {value: result, next: index};
}

function parseFrontmatter(content, source = "<input>") {
  const normalized = content.replace(/\r\n/g, "\n");
  const match = normalized.match(/^---\n([\s\S]*?)\n---(?:\n|$)([\s\S]*)$/);
  if (!match) throw new SpecError(`${source}: missing YAML frontmatter`);
  const tokens = tokenizeFrontmatter(match[1], source, 2);
  if (tokens.length === 0) throw new SpecError(`${source}: empty YAML frontmatter`);
  const parsed = parseBlock(tokens, 0, 0, source);
  if (parsed.next !== tokens.length) {
    parseError(source, tokens[parsed.next].line, "unparsed frontmatter content");
  }
  return {frontmatter: parsed.value, body: match[2].trim()};
}

function requireString(entry, key, source) {
  if (typeof entry[key] !== "string" || entry[key] === "") {
    throw new SpecError(`${source}: ${key} must be a nonempty string`);
  }
}

function validateNamedValues(values, field, source) {
  if (!Array.isArray(values)) {
    throw new SpecError(`${source}: ${field} must be an array`);
  }
  for (let i = 0; i < values.length; i += 1) {
    const value = values[i];
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new SpecError(`${source}: ${field}[${i}] must be an object`);
    }
    const allowed = field === "params"
      ? new Set(["name", "type", "optional", "flags", "from"])
      : new Set(["name", "type", "flags", "from"]);
    for (const key of Object.keys(value)) {
      if (!allowed.has(key)) {
        throw new SpecError(`${source}: ${field}[${i}] has unsupported field ${key}`);
      }
    }
    if (field === "params") requireString(value, "name", `${source}: ${field}[${i}]`);
    requireString(value, "type", `${source}: ${field}[${i}]`);
    if (Object.hasOwn(value, "optional") && typeof value.optional !== "boolean") {
      throw new SpecError(`${source}: ${field}[${i}].optional must be boolean`);
    }
    if (Object.hasOwn(value, "flags")
        && (!Array.isArray(value.flags)
          || value.flags.some((flag) => typeof flag !== "string"))) {
      throw new SpecError(`${source}: ${field}[${i}].flags must be an array of strings`);
    }
    if (Object.hasOwn(value, "from") && typeof value.from !== "string") {
      throw new SpecError(`${source}: ${field}[${i}].from must be a string`);
    }
  }
}

function validateEntry(entry, source = "<input>") {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    throw new SpecError(`${source}: frontmatter must be a mapping`);
  }
  for (const key of Object.keys(entry)) {
    if (!TOP_LEVEL_FIELDS.has(key)) {
      throw new SpecError(`${source}: unsupported frontmatter field ${key}`);
    }
  }
  for (const key of ["name", "module", "kind", "since", "stability", "origin"]) {
    requireString(entry, key, source);
  }
  if (!/^[A-Za-z_][A-Za-z0-9_]*(?:[.:][A-Za-z_][A-Za-z0-9_]*)*$/.test(entry.name)) {
    throw new SpecError(`${source}: invalid qualified name ${entry.name}`);
  }
  if (!/^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(entry.module)) {
    throw new SpecError(`${source}: invalid module name ${entry.module}`);
  }
  if (!KINDS.has(entry.kind)) throw new SpecError(`${source}: invalid kind ${entry.kind}`);
  if (!/^\d+\.\d+\.\d+$/.test(entry.since)) {
    throw new SpecError(`${source}: since must be a semantic version`);
  }
  if (!STABILITIES.has(entry.stability)) {
    throw new SpecError(`${source}: invalid stability ${entry.stability}`);
  }
  if (!ORIGINS.has(entry.origin)) {
    throw new SpecError(`${source}: invalid origin ${entry.origin}`);
  }
  if (Object.hasOwn(entry, "params")) validateNamedValues(entry.params, "params", source);
  if (Object.hasOwn(entry, "returns")) {
    if (typeof entry.returns === "string") {
      if (entry.returns === "") {
        throw new SpecError(`${source}: returns must be nonempty`);
      }
    } else {
      validateNamedValues(entry.returns, "returns", source);
    }
  }
  for (const key of ["vararg", "fastcall"]) {
    if (Object.hasOwn(entry, key) && typeof entry[key] !== "boolean") {
      throw new SpecError(`${source}: ${key} must be boolean`);
    }
  }
  if (Object.hasOwn(entry, "pledges")) {
    if (!Array.isArray(entry.pledges)
        || entry.pledges.some((pledge) => typeof pledge !== "string")) {
      throw new SpecError(`${source}: pledges must be an array of strings`);
    }
  }
  if (Object.hasOwn(entry, "flags")
      && (!Array.isArray(entry.flags)
        || entry.flags.some((flag) => typeof flag !== "string"))) {
    throw new SpecError(`${source}: flags must be an array of strings`);
  }
  for (const key of ["from", "receiver", "deprecated_by", "removed_in"]) {
    if (Object.hasOwn(entry, key) && typeof entry[key] !== "string") {
      throw new SpecError(`${source}: ${key} must be a string`);
    }
  }
  if (Object.hasOwn(entry, "receiver")
      && !/^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(entry.receiver)) {
    throw new SpecError(`${source}: invalid receiver ${entry.receiver}`);
  }
  for (const key of ["type", "generic"]) {
    if (Object.hasOwn(entry, key) && typeof entry[key] !== "string") {
      throw new SpecError(`${source}: ${key} must be a string`);
    }
  }
  if (entry.kind !== "function") {
    for (const key of ["params", "returns", "vararg", "generic", "fastcall"]) {
      if (Object.hasOwn(entry, key)) {
        throw new SpecError(`${source}: ${key} is valid only for functions`);
      }
    }
  }
  if ((entry.kind === "constant" || entry.kind === "variable")
      && typeof entry.type !== "string") {
    throw new SpecError(`${source}: ${entry.kind} entries require a type`);
  }
  return entry;
}

function findMarkdown(dir) {
  const results = [];
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) results.push(...findMarkdown(full));
    else if (entry.name.endsWith(".md")) results.push(full);
  }
  return results.sort(compareText);
}

function parentName(name) {
  const dot = name.lastIndexOf(".");
  return dot < 0 ? null : name.slice(0, dot);
}

function shortName(name) {
  const separator = Math.max(name.lastIndexOf("."), name.lastIndexOf(":"));
  return separator < 0 ? name : name.slice(separator + 1);
}

function normalizeReturns(value) {
  if (value === undefined) return [];
  if (typeof value === "string") return [{type: value}];
  return value.map((result) => ({...result}));
}

function normalizeEntry(frontmatter, body, source) {
  const symbol = {...frontmatter};
  symbol.short_name = shortName(symbol.name);
  symbol.parent = symbol.receiver
    || (symbol.module === "base" ? null : parentName(symbol.name));
  symbol.params = symbol.kind === "function"
    ? (symbol.params || []).map((param) => ({...param}))
    : undefined;
  symbol.returns = symbol.kind === "function"
    ? normalizeReturns(symbol.returns)
    : undefined;
  symbol.source = source;
  if (body) {
    symbol.description = body;
    if (Array.isArray(symbol.pledges) && symbol.pledges.length > 0) {
      const list = symbol.pledges.map((pledge) => `\`${pledge}\``).join(", ");
      symbol.description += `\n\n**Requires pledge${symbol.pledges.length > 1 ? "s" : ""}:** ${list}`;
    }
  }
  return symbol;
}

function syntheticModule(name) {
  return {
    name,
    short_name: shortName(name),
    parent: parentName(name),
    module: name.split(".")[0],
    kind: "module",
    synthetic: true,
    children: [],
  };
}

function syntheticReceiver(name, module) {
  return {
    name,
    short_name: shortName(name),
    parent: parentName(name),
    module,
    kind: "type",
    synthetic: true,
    receiver_type: true,
    children: [],
  };
}

function buildGraph(specDir = SPEC_DIR) {
  const symbols = new Map();
  for (const file of findMarkdown(specDir)) {
    const relative = path.relative(path.dirname(specDir), file).split(path.sep).join("/");
    const parsed = parseFrontmatter(fs.readFileSync(file, "utf8"), relative);
    const entry = validateEntry(parsed.frontmatter, relative);
    if (entry.stability === "removed") continue;
    if (symbols.has(entry.name)) {
      throw new SpecError(`${relative}: duplicate symbol ${entry.name}`);
    }
    symbols.set(entry.name, normalizeEntry(entry, parsed.body, relative));
  }

  for (const symbol of [...symbols.values()]) {
    if (symbol.receiver && !symbols.has(symbol.receiver)) {
      symbols.set(
        symbol.receiver,
        syntheticReceiver(symbol.receiver, symbol.module),
      );
    }
  }

  for (const symbol of [...symbols.values()]) {
    let parent = symbol.parent;
    while (parent) {
      if (!symbols.has(parent)) symbols.set(parent, syntheticModule(parent));
      parent = parentName(parent);
    }
  }
  if (!symbols.has("_ENV")) {
    symbols.set("_ENV", {
      name: "_ENV",
      short_name: "_ENV",
      parent: null,
      module: "base",
      kind: "variable",
      type: "table",
      synthetic: true,
      children: [],
    });
  }
  if (!symbols.has("flags")) {
    symbols.set("flags", {
      name: "flags",
      short_name: "flags",
      parent: null,
      module: "base",
      kind: "variable",
      type: "table",
      synthetic: true,
      children: [],
    });
  }

  for (const symbol of symbols.values()) symbol.children = [];
  for (const symbol of symbols.values()) {
    if (symbol.parent) {
      const parent = symbols.get(symbol.parent);
      if (!parent) throw new SpecError(`missing parent symbol ${symbol.parent}`);
      parent.children.push(symbol.name);
    }
  }
  for (const symbol of symbols.values()) {
    symbol.children.sort(compareText);
  }
  return new Map([...symbols.entries()].sort(([a], [b]) => compareText(a, b)));
}

function luaString(value) {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n")}"`;
}

function luaLongString(value) {
  let level = 0;
  while (value.includes(`]${"=".repeat(level)}]`)) level += 1;
  const equals = "=".repeat(level);
  return `[${equals}[\n${value}]${equals}]`;
}

function luaKey(key) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) ? key : `[${luaString(key)}]`;
}

function luaValue(value, indent = 0, key = null) {
  if (typeof value === "string") {
    return key === "description" ? luaLongString(value) : luaString(value);
  }
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  if (value === null) return "nil";
  const padding = " ".repeat(indent);
  const childPadding = " ".repeat(indent + 2);
  if (Array.isArray(value)) {
    if (value.length === 0) return "{}";
    let output = "{\n";
    for (const item of value) {
      output += `${childPadding}${luaValue(item, indent + 2)},\n`;
    }
    return `${output}${padding}}`;
  }
  const keys = Object.keys(value).filter((field) => value[field] !== undefined).sort();
  if (keys.length === 0) return "{}";
  let output = "{\n";
  for (const field of keys) {
    output += `${childPadding}${luaKey(field)} = ${luaValue(value[field], indent + 2, field)},\n`;
  }
  return `${output}${padding}}`;
}

function renderGraph(symbols) {
  let output = `-- AUTO-GENERATED by tools/build-lsp.js. DO NOT EDIT\n`;
  output += `-- Source: spec/stdlib/**/*.md\n\n`;
  output += `global ipairs, pairs, table, type\n\n`;
  output += `local M = {}\n\n`;
  output += `M.symbols = {\n`;
  for (const [name, symbol] of symbols) {
    output += `  [${luaString(name)}] = ${luaValue(symbol, 2)},\n`;
  }
  output += `}\n\n`;
  output += `function M.resolve(name)\n`;
  output += `  if type(name) ~= "string" then return nil end\n`;
  output += `  return M.symbols[name]\n`;
  output += `end\n\n`;
  output += `function M.resolve_member(parent, child)\n`;
  output += `  if type(parent) ~= "string" or type(child) ~= "string" then\n`;
  output += `    return nil\n`;
  output += `  end\n`;
  output += "  if direct = M.symbols[`$parent.$child`] then return direct end\n";
  output += `  for _, child_name in ipairs(M.symbols[parent]?.children or {}) do\n`;
  output += `    local symbol = M.symbols[child_name]\n`;
  output += `    if symbol?.short_name == child then return symbol end\n`;
  output += `  end\n`;
  output += `  return nil\n`;
  output += `end\n\n`;
  output += `function M.children(name)\n`;
  output += `  local result = {}\n`;
  output += `  for _, child_name in ipairs(M.resolve(name)?.children or {}) do\n`;
  output += `    result[#result + 1] = M.symbols[child_name]\n`;
  output += `  end\n`;
  output += `  return result\n`;
  output += `end\n\n`;
  output += `function M.expression_name(node)\n`;
  output += `  if not node or type(node) ~= "table" then return nil end\n`;
  output += `  if node.type == "name" then return node.value end\n`;
  output += `  if node.type ~= "field" or not node.key then return nil end\n`;
  output += `  local parent = M.expression_name(node.table)\n`;
  output += `  local child = node.key.value or node.key.name\n`;
  output += `  if not parent or not child then return nil end\n`;
  output += "  return `$parent.$child`\n";
  output += `end\n\n`;
  output += `function M.first_return(symbol_or_name)\n`;
  output += `  local symbol = symbol_or_name\n`;
  output += `  if type(symbol) == "string" then symbol = M.resolve(symbol) end\n`;
  output += `  return symbol?.returns?[1]?.type\n`;
  output += `end\n\n`;
  output += `function M.format_returns(symbol_or_name)\n`;
  output += `  local symbol = symbol_or_name\n`;
  output += `  if type(symbol) == "string" then symbol = M.resolve(symbol) end\n`;
  output += `  local result = {}\n`;
  output += `  for _, value in ipairs(symbol?.returns or {}) do\n`;
  output += `    result[#result + 1] = value.type or "any"\n`;
  output += `  end\n`;
  output += `  return table.concat(result, ", ")\n`;
  output += `end\n\n`;
  output += `M.globals = {}\n`;
  output += `M.tables = {}\n`;
  output += `for name, symbol in pairs(M.symbols) do\n`;
  output += `  if not symbol.parent and symbol.module == "base"\n`;
  output += `     and not symbol.receiver_type then\n`;
  output += `    M.globals[#M.globals + 1] = name\n`;
  output += `  elseif not symbol.parent and symbol.kind == "module" then\n`;
  output += `    M.tables[#M.tables + 1] = name\n`;
  output += `  end\n`;
  output += `end\n`;
  output += `table.sort(M.globals)\n`;
  output += `table.sort(M.tables)\n\n`;
  output += `return M\n`;
  return output;
}

function main(argv = process.argv.slice(2)) {
  const unknown = argv.filter((arg) => arg !== "--check");
  if (unknown.length > 0) throw new SpecError(`unknown option ${unknown[0]}`);
  const check = argv.includes("--check");
  const symbols = buildGraph();
  const output = renderGraph(symbols);
  if (check) {
    let current;
    try {
      current = fs.readFileSync(OUT_FILE, "utf8");
    } catch (error) {
      if (error.code === "ENOENT") {
        throw new SpecError(`${OUT_FILE} is missing. Run node tools/build-lsp.js`);
      }
      throw error;
    }
    if (current !== output) {
      throw new SpecError(`${OUT_FILE} is stale. Run node tools/build-lsp.js`);
    }
    console.log(`Checked ${symbols.size} standard library symbols`);
    return;
  }
  fs.mkdirSync(path.dirname(OUT_FILE), {recursive: true});
  fs.writeFileSync(OUT_FILE, output);
  console.log(`Generated ${OUT_FILE}`);
  console.log(`  ${symbols.size} symbols`);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof SpecError ? error.message : error.stack);
    process.exitCode = 1;
  }
}

module.exports = {
  SpecError,
  buildGraph,
  main,
  parseFrontmatter,
  renderGraph,
  validateEntry,
};
