#!/usr/bin/env node
// Builds the documentation that agents read from spec/stdlib, the manual,
// and .agents/. Run: node tools/build-llms.js [--out DIR] [--check]
//
// The outputs, by path below the site root:
//   llms.txt                 .agents/llms.txt, verbatim
//   llms-full.txt            the manual and the API reference in one file
//   llms-small.txt           the language notes and one line per function
//   manual/NAME.md           each manual page as Markdown
//   manual/api.md            the standard library reference
//   agents/skills/...        the skills, verbatim
//   agents.md                the agent entry page: prompts, skills, files
//   benchmarks.md            the cross-language benchmarks as tables
// With --out the files are written below DIR. With --check they are built
// and validated, and nothing is written.

const fs = require("fs");
const path = require("path");
const {parseFrontmatter, validateEntry} = require("./build-lsp.js");

const ROOT = path.join(__dirname, "..");
const SITE = "https://lus.dev";
const SMALL_TOKEN_BUDGET = 25000;

// The API sections of the site, in the order of packages/site/src/lib/api.ts.
const API_SECTIONS = [
  ["Environment Functions", (m) => m === "base"],
  ["Table Library", (m) => m === "table"],
  ["String Library", (m) => m === "string"],
  ["Math Library", (m) => m === "math"],
  ["IO Library", (m) => m === "io"],
  ["OS Library", (m) => m === "os"],
  ["Debug Library", (m) => m === "debug"],
  ["Coroutine Library", (m) => m === "coroutine"],
  ["Package Library", (m) => m === "package"],
  ["UTF-8 Library", (m) => m === "utf8"],
  ["Filesystem Library", (m) => m === "fs" || m === "fs.path"],
  ["Network Library", (m) => m === "network" || m === "network.tcp" || m === "network.udp"],
  ["Vector Library", (m) => m === "vector"],
  ["Archive Library", (m) => m.startsWith("vector.archive")],
  ["Worker Library", (m) => m === "worker"],
  ["Time Library", (m) => m === "time"],
];

// Manual pages in the order llms-full.txt reads them. Acquis follow in
// numeric order, then the API reference.
const LEAD_PAGES = ["introduction", "getting-started", "adapting", "guide", "cli"];

function compareText(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

function walk(dir, ext) {
  const out = [];
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full, ext));
    else if (entry.name.endsWith(ext)) out.push(full);
  }
  return out.sort(compareText);
}

// ---------------------------------------------------------------------
// Standard library

function loadStdlib(root = ROOT) {
  const dir = path.join(root, "spec", "stdlib");
  const entries = [];
  for (const file of walk(dir, ".md")) {
    const rel = path.relative(root, file).split(path.sep).join("/");
    const parsed = parseFrontmatter(fs.readFileSync(file, "utf8"), rel);
    const entry = validateEntry(parsed.frontmatter, rel);
    if (entry.stability === "removed" || entry.name.endsWith("._module")) continue;
    entries.push({...entry, body: parsed.body, source: rel});
  }
  return entries.sort((a, b) => compareText(a.name, b.name));
}

function typeText(t) {
  return String(t ?? "any").replace(/\|nil$/, "?");
}

function returnsText(returns) {
  if (returns === undefined) return "";
  if (typeof returns === "string") return typeText(returns);
  if (returns.length === 0) return "";
  return returns.map((r) => (r.name ? `${r.name}: ${typeText(r.type)}` : typeText(r.type))).join(", ");
}

function signature(e) {
  if (e.kind !== "function") return e.name;
  const params = (e.params || []).map((p) => (p.optional ? `${p.name}?` : p.name));
  if (e.vararg) params.push("...");
  const ret = returnsText(e.returns);
  return `${e.name}(${params.join(", ")})${ret ? ` -> ${ret}` : ""}`;
}

function firstSentence(body) {
  const text = body.split(/\n\s*\n/)[0].replace(/\s+/g, " ").trim();
  const match = text.match(/^(.+?[.!?])(\s|$)/);
  return match ? match[1] : text;
}

function tags(e) {
  const out = [];
  if (Array.isArray(e.pledges) && e.pledges.length > 0) out.push(`needs ${e.pledges.join(", ")}`);
  if (e.stability === "unstable") out.push("unstable");
  if (e.stability === "deprecated") out.push("deprecated");
  return out;
}

function sectionize(entries) {
  const used = new Set();
  const sections = [];
  for (const [title, match] of API_SECTIONS) {
    const list = entries.filter((e) => !used.has(e.name) && match(e.module));
    list.forEach((e) => used.add(e.name));
    if (list.length > 0) sections.push({title, entries: list});
  }
  const rest = entries.filter((e) => !used.has(e.name));
  if (rest.length > 0) sections.push({title: "Other", entries: rest});
  return sections;
}

function renderApi(entries) {
  const lines = [
    "# Standard library reference",
    "",
    "> Every function, constant, and type of the Lus standard library, with parameters, results, required permissions, and stability.",
    "",
  ];
  for (const section of sectionize(entries)) {
    lines.push(`## ${section.title}`, "");
    for (const e of section.entries) {
      lines.push(`### ${e.name}`, "", "```", signature(e), "```", "");
      const t = tags(e);
      if (t.length > 0) lines.push(`*${t.join(". ")}.*`, "");
      if (e.body) lines.push(rewriteLinks(e.body), "");
    }
  }
  return lines.join("\n").trimEnd() + "\n";
}

// ---------------------------------------------------------------------
// Manual pages

function loadManual(root = ROOT) {
  const dir = path.join(root, "packages", "site", "src", "manual");
  const pages = [];
  for (const file of walk(dir, ".mdx")) {
    const id = path.basename(file, ".mdx");
    const text = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
    const match = text.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
    if (!match) throw new Error(`${file}: missing frontmatter`);
    const meta = {};
    for (const line of match[1].split("\n")) {
      const kv = line.match(/^(\w+):\s*(.*)$/);
      if (kv) meta[kv[1]] = kv[2].replace(/^"(.*)"$/, "$1");
    }
    pages.push({id, meta, body: match[2]});
  }
  return pages;
}

// Links to manual pages become absolute links to their Markdown twins.
// Other site links, such as the playground and the C API reference,
// become absolute links to the HTML page.
function rewriteLinks(text) {
  return text
    .replace(/\]\(\/manual\/([\w.-]+)(#[^)]*)?\)/g, (_, page, hash) => `](${SITE}/manual/${page}.md${hash || ""})`)
    .replace(/\]\(\/([^)\s]*)\)/g, `](${SITE}/$1)`);
}

// Converts the MDX body of a manual page to plain Markdown: imports and
// components outside code fences go, code fences lose their test markers.
function mdxToMarkdown(body, ctx = {}) {
  const out = [];
  let fence = null;
  let skipping = null;
  for (const line of body.split("\n")) {
    const open = line.match(/^(\s*)(`{3,}|~{3,})(.*)$/);
    if (fence) {
      out.push(line);
      if (open && open[2].startsWith(fence) && open[3].trim() === "") fence = null;
      continue;
    }
    if (open) {
      fence = open[2];
      const info = open[3].trim().replace(/^lus\b.*$/, "lus");
      out.push(`${open[1]}${fence}${info}`);
      continue;
    }
    if (skipping) {
      if (new RegExp(`</${skipping}>`).test(line)) skipping = null;
      continue;
    }
    if (/^import\s.+\sfrom\s/.test(line)) continue;
    const component = line.match(/^\s*<([A-Z]\w*)\b[^>]*?(\/)?>\s*$/);
    if (component) {
      const [, name, selfClosing] = component;
      if (ctx.components && ctx.components[name]) out.push(ctx.components[name]);
      if (!selfClosing) skipping = name;
      continue;
    }
    out.push(rewriteLinks(line));
  }
  return out.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

function acquisNumber(id) {
  const m = id.match(/^acquis-(\d+)$/);
  return m ? Number(m[1]) : null;
}

function acquisIndex(pages) {
  return pages
    .filter((p) => acquisNumber(p.id) !== null)
    .sort((a, b) => acquisNumber(a.id) - acquisNumber(b.id))
    .map((p) => `- [${p.meta.title}](${SITE}/manual/${p.id}.md): ${p.meta.shortdesc}`)
    .join("\n");
}

function renderPage(page, components) {
  const lines = [`# ${page.meta.title}`, ""];
  if (page.meta.shortdesc) lines.push(`> ${page.meta.shortdesc}`, "");
  if (page.meta.draft === "true") {
    lines.push("This page documents the unstable channel, and its contents may change in any release.", "");
  }
  lines.push(mdxToMarkdown(page.body, {components}));
  return lines.join("\n").trimEnd() + "\n";
}

function shiftHeadings(markdown) {
  let fence = false;
  return markdown.split("\n").map((line) => {
    if (/^\s*(`{3,}|~{3,})/.test(line)) fence = !fence;
    return !fence && /^#{1,5} /.test(line) ? `#${line}` : line;
  }).join("\n");
}

// ---------------------------------------------------------------------
// The agent entry page and the benchmarks

// The prompts of .agents/prompt.md: one per second-level heading, with
// the text of its first fenced block.
function loadPrompts(root = ROOT) {
  const text = fs.readFileSync(path.join(root, ".agents", "prompt.md"), "utf8").replace(/\r\n/g, "\n");
  const prompts = [];
  for (const part of text.split(/^## /m).slice(1)) {
    const title = part.slice(0, part.indexOf("\n")).trim();
    const block = part.match(/```\w*\n([\s\S]*?)\n```/);
    if (block) prompts.push({title, text: block[1]});
  }
  return prompts;
}

function skillDescription(text) {
  const m = text.match(/^---\n[\s\S]*?^description:\s*(.+)$/m);
  return m ? m[1].trim() : "";
}

function renderAgents(prompts, skills) {
  const lines = [
    "# Lus for agents",
    "",
    "> Everything a coding agent needs to write, test, and port Lus: prompts to start from, skills to install, and the documentation in Markdown.",
    "",
    "## Prompts",
    "",
    "Paste one of these into a coding agent. Each prompt names every command and page it uses.",
    "",
  ];
  for (const p of prompts) lines.push(`### ${p.title}`, "", "```text", p.text, "```", "");
  lines.push(
    "## Skills",
    "",
    "In Claude Code, `claude plugin install lus --marketplace lus-lang/lus` installs the skills as a plugin. In any other agent, `lus agents init` writes the skills of the installed runtime into `.agents/skills/` of a project, links `.claude/skills` to them, and adds a Lus section to `AGENTS.md`. `lus help NAME` prints the reference for any standard library function from the same runtime.",
    "",
  );
  for (const [name, text] of skills) lines.push(`- [${name}](${SITE}/agents/skills/${name}/SKILL.md): ${skillDescription(text)}`);
  lines.push(
    "",
    "## Documentation",
    "",
    `- [llms.txt](${SITE}/llms.txt): The index of the documentation.`,
    `- [llms-small.txt](${SITE}/llms-small.txt): The differences from Lua and every function signature, sized for a small context.`,
    `- [llms-full.txt](${SITE}/llms-full.txt): The whole manual and the API reference in one file.`,
    `- Every manual page has a Markdown twin at the same address with \`.md\` appended, such as [the guide](${SITE}/manual/guide.md).`,
    "",
  );
  return lines.join("\n");
}

function listText(items) {
  if (items.length <= 2) return items.join(" and ");
  return `${items.slice(0, -1).join(", ")}, and ${items[items.length - 1]}`;
}

function renderBenchmarks(data) {
  const ids = ["lus", ...Object.keys(data.runtimes).filter((id) => id !== "lus")];
  const names = ids.map((id) => data.runtimes[id].name);
  const table = (key, fmt) => {
    const rows = [`| program | ${names.join(" | ")} |`, `| --- |${ids.map(() => " ---: |").join("")}`];
    for (const program of Object.keys(data.programs).sort(compareText)) {
      const cells = ids.map((id) => {
        const c = data.programs[program][id];
        return c && c.ok !== false && typeof c[key] === "number" ? fmt(c[key]) : "n/a";
      });
      rows.push(`| ${program} | ${cells.join(" | ")} |`);
    }
    return rows.join("\n");
  };
  return [
    "# Benchmarks",
    "",
    `> Lus against ${listText(names.slice(1))} on ${Object.keys(data.programs).length} programs of the cross-language suite in \`tests/bench/compare\`.`,
    "",
    `Measured on ${data.device.cpu} with ${data.device.cores} cores and ${data.device.memory_gb} GB under ${data.os}, best of ${data.runs} runs. Each program does the same work in every language, and the suite checks that every runtime prints the same output.`,
    "",
    "## Best wall time in seconds, lower is better",
    "",
    table("best_s", (v) => v.toFixed(2)),
    "",
    "## Peak memory in MB, lower is better",
    "",
    table("peak_rss_mb", (v) => String(Math.round(v))),
    "",
  ].join("\n");
}

// ---------------------------------------------------------------------
// Assembly

function build(root = ROOT) {
  const stdlib = loadStdlib(root);
  const pages = loadManual(root);
  const components = {AcquisList: acquisIndex(pages)};
  const files = new Map();

  const rendered = new Map();
  for (const page of pages) {
    const md = renderPage(page, components);
    rendered.set(page.id, md);
    files.set(`manual/${page.id}.md`, md);
  }
  const api = renderApi(stdlib);
  files.set("manual/api.md", api);

  const agents = path.join(root, ".agents");
  files.set("llms.txt", fs.readFileSync(path.join(agents, "llms.txt"), "utf8"));
  for (const file of walk(path.join(agents, "skills"), ".md")) {
    const rel = path.relative(agents, file).split(path.sep).join("/");
    files.set(`agents/${rel}`, fs.readFileSync(file, "utf8"));
  }

  const skills = [];
  for (const [name, text] of files) {
    const m = name.match(/^agents\/skills\/([^/]+)\/SKILL\.md$/);
    if (m) skills.push([m[1], text]);
  }
  files.set("agents.md", renderAgents(loadPrompts(root), skills));
  const bench = path.join(root, "packages", "site", "src", "data", "benchmarks.json");
  files.set("benchmarks.md", renderBenchmarks(JSON.parse(fs.readFileSync(bench, "utf8"))));

  const order = [
    ...LEAD_PAGES,
    ...pages.map((p) => p.id).filter((id) => acquisNumber(id) !== null)
      .sort((a, b) => acquisNumber(a) - acquisNumber(b)),
  ].filter((id) => rendered.has(id));
  const full = [
    "# Lus",
    "",
    "> The complete Lus documentation for one release: the manual, every acquis, and the standard library reference. Headings are one level deeper than on the site, so each page starts with a second-level heading.",
    "",
    ...order.map((id) => shiftHeadings(rendered.get(id))),
    shiftHeadings(api),
  ].join("\n");
  files.set("llms-full.txt", full);

  const language = fs.readFileSync(path.join(agents, "skills", "lus", "references", "language.md"), "utf8");
  const small = [
    "# Lus",
    "",
    "> Lus in brief: how it differs from Lua 5.5, and every standard library function with its signature, required permissions, and stability. The full reference is at https://lus.dev/llms-full.txt.",
    "",
    shiftHeadings(language.trim()),
    "",
    "## Standard library",
    "",
    "`x?` marks an optional parameter or a result that may be nil. `needs` lists the permissions a call requires.",
    "",
    ...sectionize(stdlib).flatMap((s) => [
      `### ${s.title}`,
      "",
      ...s.entries.map((e) => {
        const t = tags(e);
        const desc = e.body ? ` ${firstSentence(e.body)}` : "";
        return `- \`${signature(e)}\`${t.length ? ` (${t.join(", ")})` : ""}${desc}`;
      }),
      "",
    ]),
  ].join("\n").trimEnd() + "\n";
  files.set("llms-small.txt", small);

  return {files, stdlib, pages};
}

// ---------------------------------------------------------------------
// Validation

function estimateTokens(text) {
  return Math.ceil(text.length / 4);
}

function outsideFences(markdown) {
  let fence = false;
  return markdown.split("\n").filter((line) => {
    if (/^\s*(`{3,}|~{3,})/.test(line)) {
      fence = !fence;
      return false;
    }
    return !fence;
  });
}


function validate({files, stdlib}) {
  const problems = [];
  const small = files.get("llms-small.txt");
  for (const e of stdlib) {
    if (e.kind === "function" && !small.includes(`\`${signature(e)}\``)) {
      problems.push(`llms-small.txt: missing ${e.name}`);
    }
  }
  const tokens = estimateTokens(small);
  if (tokens > SMALL_TOKEN_BUDGET) {
    problems.push(`llms-small.txt: about ${tokens} tokens, over the budget of ${SMALL_TOKEN_BUDGET}`);
  }
  for (const [name, text] of files) {
    if (!name.endsWith(".md") && !name.endsWith(".txt")) continue;
    outsideFences(text).forEach((line) => {
      if (/^\s*import\s.+\sfrom\s/.test(line) || /<[A-Z]\w*[\s/>]/.test(line)) {
        problems.push(`${name}: MDX left in "${line.trim()}"`);
      }
    });
    for (const m of text.matchAll(/\]\((https:\/\/lus\.dev\/[^)#\s]+\.(?:md|txt))[)#]/g)) {
      const target = m[1].slice(SITE.length + 1);
      if (!files.has(target)) problems.push(`${name}: link to missing ${m[1]}`);
    }
  }
  return problems;
}

function main(argv = process.argv.slice(2)) {
  const outIndex = argv.indexOf("--out");
  const out = outIndex >= 0 ? argv[outIndex + 1] : null;
  const result = build();
  const problems = validate(result);
  if (problems.length > 0) {
    for (const p of problems) console.error(p);
    return 1;
  }
  if (out) {
    for (const [name, text] of result.files) {
      const target = path.join(out, name);
      fs.mkdirSync(path.dirname(target), {recursive: true});
      fs.writeFileSync(target, text);
    }
  }
  const small = estimateTokens(result.files.get("llms-small.txt"));
  const full = estimateTokens(result.files.get("llms-full.txt"));
  console.log(`${result.files.size} files, llms-small.txt about ${small} tokens, llms-full.txt about ${full} tokens`);
  return 0;
}

if (require.main === module) {
  process.exitCode = main();
}

module.exports = {build, validate, loadPrompts, signature, mdxToMarkdown, rewriteLinks, estimateTokens, SMALL_TOKEN_BUDGET};
