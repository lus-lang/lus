// The Lus command line as tools: check, fmt, test, doc, and questions to the
// language server. Each tool calls `lus` and draws a compact row.
import { isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { type Diagnostic, fromCheck, summary } from "./diagnostics.ts";
import { parseTestSummary, testFailures, type TestTally } from "./parse.ts";
import type { LusLsp } from "./lsp.ts";
import { clip, EMPTY, head, lines, rowState, seconds, shortPath, tree } from "./render.ts";
import type { Session } from "./session.ts";

export function resolvePath(cwd: string, path: string): string {
  const clean = path.replace(/^@/, "");
  return isAbsolute(clean) ? clean : resolve(cwd, clean);
}

function paths(cwd: string, given: string[] | undefined): string[] {
  const list = given?.length ? given : ["."];
  return list.map((p) => {
    const abs = resolvePath(cwd, p);
    const rel = relative(cwd, abs);
    return rel === "" ? "." : rel.startsWith("..") ? abs : rel;
  });
}

function text(value: string) {
  return [{ type: "text" as const, text: value }];
}

interface CheckFile {
  file: string;
  diagnostics: Diagnostic[];
}

function groupCheck(raw: any[]): CheckFile[] {
  const byFile = new Map<string, any[]>();
  for (const d of raw) {
    const list = byFile.get(d.file) ?? [];
    list.push(d);
    byFile.set(d.file, list);
  }
  return [...byFile].map(([file, list]) => ({ file, diagnostics: fromCheck(list) }));
}

function renderCheck(theme: Theme, files: CheckFile[], expanded: boolean): string[] {
  const all = files.flatMap((f) => f.diagnostics.filter((d) => d.severity === "error" || d.severity === "warning"));
  if (!all.length) return [theme.fg("accent", "clean")];
  const out = [summary(theme, all)];
  let shown = 0;
  const max = expanded ? Infinity : 6;
  for (const f of files) {
    for (const d of f.diagnostics) {
      if (d.severity !== "error" && d.severity !== "warning") continue;
      if (shown++ >= max) continue;
      const color = d.severity === "error" ? "error" : "warning";
      out.push(`${theme.fg("dim", `${f.file}:${d.line}:${d.column}`)} ${theme.fg(color, d.message)}${d.code ? theme.fg("dim", ` ${d.code}`) : ""}`);
    }
  }
  if (shown > max) out.push(theme.fg("dim", `${shown - max} more`));
  return out;
}

function renderTally(theme: Theme, tally: TestTally | undefined, durationMs: number | undefined): string {
  if (!tally) return theme.fg("error", "no report");
  const parts = [theme.fg(tally.failed || tally.fileErrors ? "muted" : "accent", `${tally.passed} passed`)];
  parts.push(tally.failed ? theme.fg("error", `${tally.failed} failed`) : theme.fg("dim", "0 failed"));
  if (tally.fileErrors) parts.push(theme.fg("error", `${tally.fileErrors} file error${tally.fileErrors === 1 ? "" : "s"}`));
  if (tally.skipped) parts.push(theme.fg("warning", `${tally.skipped} skipped`));
  if (durationMs !== undefined) parts.push(theme.fg("dim", seconds(durationMs)));
  return parts.join(theme.fg("dim", " · "));
}

function call(verb: string, describe: (args: any) => string) {
  return (args: any, theme: Theme, context: any) =>
    lines(() => [head(theme, rowState(context.state.done ?? context), verb, describe(args ?? {}))]);
}

function settle(context: any) {
  context.state.done = { isError: context.isError, isPartial: context.isPartial, executionStarted: true, durationMs: context.durationMs ?? 0 };
}

function lspLocation(cwd: string, loc: any): string {
  const uri: string = loc?.uri ?? loc?.targetUri ?? "";
  const range = loc?.range ?? loc?.targetSelectionRange ?? loc?.targetRange;
  const file = uri.startsWith("file:") ? shortPath(fileURLToPath(uri), cwd) : uri;
  return `${file}:${(range?.start?.line ?? 0) + 1}:${(range?.start?.character ?? 0) + 1}`;
}

function flattenSymbols(symbols: any[], depth = 0): string[] {
  const out: string[] = [];
  for (const s of symbols) {
    const line = (s.range?.start?.line ?? s.location?.range?.start?.line ?? 0) + 1;
    out.push(`${"  ".repeat(depth)}${s.name} (line ${line})`);
    if (s.children?.length) out.push(...flattenSymbols(s.children, depth + 1));
  }
  return out;
}

function hoverText(result: any): string {
  const contents = result?.contents;
  if (!contents) return "";
  if (typeof contents === "string") return contents;
  if (Array.isArray(contents)) return contents.map((c) => (typeof c === "string" ? c : c.value)).join("\n\n");
  return contents.value ?? "";
}

export function registerLusTools(pi: ExtensionAPI, session: Session) {
  const lus = () => {
    const bin = session.lus;
    if (!bin) throw new Error("No lus binary found. Install Lus 2 from https://lus.dev or set LUS_BIN.");
    if (!bin.supported) throw new Error(`${bin.path} is Lus ${bin.version}. These tools need Lus 2. Set LUS_BIN to a Lus 2 binary.`);
    return bin.path;
  };

  pi.registerTool({
    name: "lus_check",
    label: "Check",
    description: "Find errors and likely mistakes in Lus files without running them (lus check). Accepts files and directories.",
    promptSnippet: "Lint and compile-check Lus files without running them",
    promptGuidelines: ["Run lus_check on the Lus files you changed before you report a task as done."],
    parameters: Type.Object({
      paths: Type.Optional(Type.Array(Type.String(), { description: "Files or directories. Defaults to the working directory." })),
    }),
    async execute(_id, params, signal, _update, ctx) {
      const args = paths(ctx.cwd, params.paths);
      const res = await pi.exec(lus(), ["check", "--json", ...args], { cwd: ctx.cwd, signal, timeout: 120000 });
      let raw: any[] = [];
      try {
        raw = JSON.parse(res.stdout || "[]");
      } catch {
        throw new Error((res.stderr || res.stdout).trim() || `lus check exited with status ${res.code}`);
      }
      const files = groupCheck(raw);
      const body = raw.length
        ? raw.map((d) => `${d.file}:${d.line}:${d.column}: ${d.severity}: ${d.message} [${d.code}]`).join("\n")
        : "No problems found.";
      return { content: text(body), details: { files, paths: args } };
    },
    renderShell: "self",
    renderCall: call("Check", (a) => (a.paths?.length ? a.paths.join(" ") : ".")),
    renderResult(result: any, options, theme, context: any) {
      settle(context);
      if (options.isPartial) return EMPTY;
      if (context.isError) return lines(() => tree(theme, [theme.fg("error", result.content?.[0]?.text ?? "failed")]));
      return lines(() => tree(theme, renderCheck(theme, result.details?.files ?? [], options.expanded)));
    },
  });

  pi.registerTool({
    name: "lus_fmt",
    label: "Format",
    description: "Format Lus files in place with the standard layout (lus fmt --write), or list the files that need it with check set.",
    promptSnippet: "Format Lus files with the standard layout",
    promptGuidelines: ["Use lus_fmt on Lus files you wrote, and never format Lus by hand."],
    parameters: Type.Object({
      paths: Type.Optional(Type.Array(Type.String(), { description: "Files or directories. Defaults to the working directory." })),
      check: Type.Optional(Type.Boolean({ description: "List unformatted files and change nothing." })),
    }),
    async execute(_id, params, signal, _update, ctx) {
      const args = paths(ctx.cwd, params.paths);
      const listed = await pi.exec(lus(), ["fmt", "--check", ...args], { cwd: ctx.cwd, signal, timeout: 120000 });
      const files = listed.stdout
        .split("\n")
        .map((line) => /^(.*): not formatted$/.exec(line.trim())?.[1])
        .filter((f): f is string => !!f);
      if (listed.code !== 0 && !files.length) throw new Error((listed.stderr || listed.stdout).trim() || "lus fmt failed");
      if (params.check || !files.length) {
        const body = files.length ? `Not formatted:\n${files.join("\n")}` : "Every file is formatted.";
        return { content: text(body), details: { files, wrote: false } };
      }
      const res = await pi.exec(lus(), ["fmt", "--write", ...files], { cwd: ctx.cwd, signal, timeout: 120000 });
      if (res.code !== 0) throw new Error((res.stderr || res.stdout).trim() || "lus fmt --write failed");
      return { content: text(`Formatted:\n${files.join("\n")}`), details: { files, wrote: true } };
    },
    renderShell: "self",
    renderCall: call("Format", (a) => (a.paths?.length ? a.paths.join(" ") : ".") + (a.check ? " --check" : "")),
    renderResult(result: any, options, theme, context: any) {
      settle(context);
      if (options.isPartial) return EMPTY;
      if (context.isError) return lines(() => tree(theme, [theme.fg("error", result.content?.[0]?.text ?? "failed")]));
      const files: string[] = result.details?.files ?? [];
      if (!files.length) return lines(() => tree(theme, [theme.fg("dim", "already formatted")]));
      const verb = result.details?.wrote ? "formatted" : "need formatting";
      const body = [theme.fg(result.details?.wrote ? "accent" : "warning", `${files.length} file${files.length === 1 ? "" : "s"} ${verb}`)];
      body.push(...clip(theme, files.map((f) => theme.fg("dim", f)), options.expanded ? 200 : 4));
      return lines(() => tree(theme, body));
    },
  });

  pi.registerTool({
    name: "lus_test",
    label: "Test",
    description: "Run Lus tests (lus test): every *_test.lus file below the given directories, or the named files.",
    promptSnippet: "Run Lus tests and snapshot updates",
    promptGuidelines: ["Use lus_test to run Lus tests. Set update only when a snapshot change is intended."],
    parameters: Type.Object({
      paths: Type.Optional(Type.Array(Type.String(), { description: "Test files or directories. Defaults to the working directory." })),
      filter: Type.Optional(Type.String({ description: "Run only the tests whose names contain this text." })),
      update: Type.Optional(Type.Boolean({ description: "Rewrite snapshots that no longer match." })),
      doc: Type.Optional(Type.Boolean({ description: "Run the lus code blocks of Markdown files instead of test files." })),
    }),
    async execute(_id, params, signal, onUpdate, ctx) {
      const args = ["test"];
      if (params.filter) args.push("--filter", params.filter);
      if (params.update) args.push("--update");
      if (params.doc) args.push("--doc");
      args.push(...paths(ctx.cwd, params.paths));
      onUpdate?.({ content: text("running"), details: undefined });
      const res = await pi.exec(lus(), args, { cwd: ctx.cwd, signal, timeout: 30 * 60000 });
      const output = (res.stdout + (res.stderr ? `\n${res.stderr}` : "")).trim();
      const tally = parseTestSummary(output);
      const result = { content: text(output || `lus test exited with status ${res.code}`), details: { tally, failures: testFailures(output) } };
      if (res.code === 2) throw new Error(output || "a named path does not exist");
      return result;
    },
    renderShell: "self",
    renderCall: call("Test", (a) => [...(a.paths ?? []), a.filter ? `--filter ${a.filter}` : "", a.doc ? "--doc" : ""].filter(Boolean).join(" ") || "."),
    renderResult(result: any, options, theme, context: any) {
      settle(context);
      if (options.isPartial) return EMPTY;
      if (context.isError && !result.details) return lines(() => tree(theme, [theme.fg("error", result.content?.[0]?.text ?? "failed")]));
      const body = [renderTally(theme, result.details?.tally, context.durationMs)];
      const failures: string[] = result.details?.failures ?? [];
      body.push(...clip(theme, failures.map((line) => (line.startsWith("FAIL") || line.startsWith("file error") ? theme.fg("error", line) : theme.fg("dim", line))), options.expanded ? 400 : 6));
      return lines(() => tree(theme, body));
    },
  });

  pi.registerTool({
    name: "lus_doc",
    label: "Doc",
    description: "Generate the API reference of a Lus module from its --- doc comments (lus doc), as Markdown.",
    promptSnippet: "Show the API reference generated from a Lus module's doc comments",
    parameters: Type.Object({ path: Type.String({ description: "The module file." }) }),
    async execute(_id, params, signal, _update, ctx) {
      const file = paths(ctx.cwd, [params.path])[0];
      const res = await pi.exec(lus(), ["doc", file], { cwd: ctx.cwd, signal, timeout: 60000 });
      if (res.code !== 0) throw new Error((res.stderr || res.stdout).trim() || "lus doc failed");
      return { content: text(res.stdout), details: { lines: res.stdout.split("\n").length } };
    },
    renderShell: "self",
    renderCall: call("Doc", (a) => a.path ?? ""),
    renderResult(result: any, options, theme, context: any) {
      settle(context);
      if (options.isPartial) return EMPTY;
      const body = (result.content?.[0]?.text ?? "").split("\n");
      if (context.isError) return lines(() => tree(theme, [theme.fg("error", body[0])]));
      if (!options.expanded) return lines(() => tree(theme, [theme.fg("dim", `${body.length} lines of reference`)]));
      return lines(() => tree(theme, clip(theme, body.map((l: string) => theme.fg("toolOutput", l)), 60)));
    },
  });

  pi.registerTool({
    name: "lus_lsp",
    label: "Lus LSP",
    description:
      "Ask the Lus language server about code: hover (type and documentation at a position), definition, references, or symbols (outline of a file). Lines and columns start at 1.",
    promptSnippet: "Look up definitions, references, hover docs, and outlines in Lus code",
    promptGuidelines: ["Use lus_lsp definition and references to navigate Lus code before guessing from grep results."],
    parameters: Type.Object({
      action: StringEnum(["hover", "definition", "references", "symbols"] as const),
      path: Type.String(),
      line: Type.Optional(Type.Number()),
      column: Type.Optional(Type.Number()),
    }),
    async execute(_id, params, _signal, _update, ctx) {
      const lsp: LusLsp | undefined = session.lspFor(ctx);
      if (!lsp) throw new Error("The Lus language server is unavailable.");
      const file = resolvePath(ctx.cwd, params.path);
      let out: string[] = [];
      if (params.action === "symbols") {
        out = flattenSymbols(await lsp.symbols(file));
      } else {
        if (!params.line || !params.column) throw new Error(`${params.action} needs line and column`);
        if (params.action === "hover") {
          out = [hoverText(await lsp.at("textDocument/hover", file, params.line, params.column))];
        } else if (params.action === "definition") {
          const res = await lsp.at("textDocument/definition", file, params.line, params.column);
          out = (Array.isArray(res) ? res : res ? [res] : []).map((loc: any) => lspLocation(ctx.cwd, loc));
        } else {
          const res = await lsp.at("textDocument/references", file, params.line, params.column, { context: { includeDeclaration: true } });
          out = (res ?? []).map((loc: any) => lspLocation(ctx.cwd, loc));
        }
      }
      out = out.filter((l) => l.trim());
      return { content: text(out.length ? out.join("\n") : "No result."), details: { count: out.length } };
    },
    renderShell: "self",
    renderCall: call("Looked up", (a) => `${a.action ?? ""} ${a.path ?? ""}${a.line ? `:${a.line}:${a.column ?? 1}` : ""}`),
    renderResult(result: any, options, theme, context: any) {
      settle(context);
      if (options.isPartial) return EMPTY;
      const body = (result.content?.[0]?.text ?? "").split("\n");
      if (context.isError) return lines(() => tree(theme, [theme.fg("error", body[0])]));
      return lines(() => tree(theme, clip(theme, body.map((l: string) => theme.fg("toolOutput", l)), options.expanded ? 200 : 4)));
    },
  });

  // Slash commands ask the agent to run the matching tool, so the result
  // lands in the conversation where the next prompt can refer to it.
  const direct: Record<string, { tool: string; ask: string; hint: string }> = {
    check: { tool: "lus_check", ask: "and list what it finds. Change nothing yet.", hint: "[paths]" },
    fmt: { tool: "lus_fmt", ask: "and say which files changed.", hint: "[paths]" },
    test: { tool: "lus_test", ask: "and summarize the failures. Change nothing yet.", hint: "[paths]" },
    doc: { tool: "lus_doc", ask: "and summarize the public API it documents.", hint: "<file>" },
  };
  for (const [name, { tool, ask, hint }] of Object.entries(direct)) {
    pi.registerCommand(name, {
      description: `Run lus ${name} ${hint}`,
      handler: async (args) => {
        const list = args.trim() ? args.trim().split(/\s+/) : [];
        if (name === "doc" && !list.length) return;
        pi.sendUserMessage(`Run ${tool}${list.length ? ` on ${list.join(" ")}` : ""} ${ask}`);
      },
    });
  }
}
