// Flat, one-line rows for Pi's built-in tools. Execution stays with Pi. Only
// the drawing changes, through a tool renderer resolver.
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import { diffStats } from "./parse.ts";
import { clip, counts, EMPTY, head, lines, renderDiff, type RowContext, rowState, shortPath, tree } from "./render.ts";
import { diagnosticLines, type LusFileReport } from "./diagnostics.ts";

type Content = { type: string; text?: string }[];
interface Result {
  content: Content;
  details?: any;
}

/** State shared by the call and result slots of one row. */
interface RowShared {
  verb?: string;
  extra?: string;
  done?: RowContext;
}

function textOf(result: Result): string {
  return result.content
    .filter((part) => part.type === "text")
    .map((part) => part.text ?? "")
    .join("\n");
}

/**
 * Builds a call renderer whose head reads the shared state when it paints,
 * so the result can still change the verb, the counts, and the bullet.
 */
function callRow(describe: (args: any, cwd: string) => { verb: string; arg: string }) {
  return (args: any, theme: Theme, context: any) => {
    const state = context.state as RowShared;
    return lines(() => {
      const { verb, arg } = describe(args ?? {}, context.cwd);
      const now = state.done ?? context;
      return [head(theme, rowState(now), state.verb ?? verb, arg, state.extra ?? "")];
    });
  };
}

function settle(context: any, isError = context.isError) {
  (context.state as RowShared).done = {
    isError,
    isPartial: context.isPartial,
    executionStarted: true,
    durationMs: context.durationMs ?? (context.isPartial ? undefined : 0),
  };
}

function errorBody(theme: Theme, result: Result, max = 6): string[] {
  const text = textOf(result).trim();
  return clip(theme, text.split("\n").map((line) => theme.fg("error", line)), max);
}

function lusReport(result: Result): LusFileReport | undefined {
  return result.details?.lus;
}

/** The findings that hang under an edit: diagnostics, then the prose lint. */
function findings(theme: Theme, result: Result, path: string, expanded: boolean): string[] {
  const out: string[] = [];
  const report = lusReport(result);
  if (report) out.push(...diagnosticLines(theme, report, expanded));
  const prose: string[] | undefined = result.details?.prose;
  if (prose?.length) {
    out.push(`${theme.fg("dim", "prose")} ${theme.fg("error", `${prose.length}`)}`);
    out.push(...clip(theme, prose.map((p) => theme.fg("error", p.replace(/^[^:]*:/, ""))), expanded ? 100 : 3));
  } else if (prose && /\.mdx?$/.test(path)) {
    out.push(`${theme.fg("dim", "prose clean")}`);
  }
  return out;
}

function range(args: { offset?: number; limit?: number }): string {
  if (!args.offset && !args.limit) return "";
  const start = args.offset ?? 1;
  return args.limit ? ` ${start}-${start + args.limit - 1}` : ` from ${start}`;
}

const READ = {
  renderShell: "self" as const,
  renderCall: callRow((args, cwd) => ({ verb: "Read", arg: shortPath(args.path ?? "", cwd) + range(args) })),
  renderResult(result: Result, options: { expanded: boolean; isPartial: boolean }, theme: Theme, context: any) {
    settle(context);
    if (options.isPartial) return EMPTY;
    if (context.isError) return lines(() => tree(theme, errorBody(theme, result)));
    if (!options.expanded) return EMPTY;
    const body = textOf(result).split("\n").map((line) => theme.fg("toolOutput", line));
    return lines(() => tree(theme, clip(theme, body, 20)));
  },
};

const EDIT = {
  renderShell: "self" as const,
  renderCall: callRow((args, cwd) => ({ verb: "Edit", arg: shortPath(args.path ?? "", cwd) })),
  renderResult(result: Result, options: { expanded: boolean; isPartial: boolean }, theme: Theme, context: any) {
    const state = context.state as RowShared;
    settle(context);
    if (options.isPartial) return EMPTY;
    if (context.isError) {
      state.verb = "Edit failed";
      return lines(() => tree(theme, errorBody(theme, result)));
    }
    const diff: string = result.details?.diff ?? "";
    const { added, removed } = diffStats(diff);
    state.verb = "Edited";
    state.extra = counts(theme, added, removed);
    const path: string = context.args?.path ?? "";
    const below = findings(theme, result, path, options.expanded);
    return lines((width) => [...renderDiff(theme, diff, path, width, options.expanded ? 400 : 12), ...tree(theme, below)]);
  },
};

const WRITE = {
  renderShell: "self" as const,
  renderCall: callRow((args, cwd) => ({ verb: "Write", arg: shortPath(args.path ?? "", cwd) })),
  renderResult(result: Result, options: { expanded: boolean; isPartial: boolean }, theme: Theme, context: any) {
    const state = context.state as RowShared;
    settle(context);
    if (options.isPartial) return EMPTY;
    if (context.isError) return lines(() => tree(theme, errorBody(theme, result)));
    const content: string = context.args?.content ?? "";
    const count = content ? content.split("\n").length - (content.endsWith("\n") ? 1 : 0) : 0;
    state.verb = "Wrote";
    state.extra = counts(theme, count, 0);
    const path: string = context.args?.path ?? "";
    const below = findings(theme, result, path, options.expanded);
    return lines((width) => {
      const out: string[] = [];
      if (options.expanded && content) {
        const diff = content.replace(/\n$/, "").split("\n").map((line, i) => `+${String(i + 1).padStart(4)} ${line}`).join("\n");
        out.push(...renderDiff(theme, diff, path, width, 400));
      }
      return [...out, ...tree(theme, below)];
    });
  },
};

function firstLine(command: string): string {
  const [first, ...rest] = command.trim().split("\n");
  return rest.length ? `${first} …` : first;
}

const BASH = {
  renderShell: "self" as const,
  renderCall: callRow((args) => ({ verb: "Ran", arg: firstLine(args.command ?? "") })),
  renderResult(result: Result, options: { expanded: boolean; isPartial: boolean }, theme: Theme, context: any) {
    settle(context);
    const text = textOf(result).replace(/\s+$/, "");
    if (!text) return EMPTY;
    const color = context.isError ? "error" : "toolOutput";
    const all = text.split("\n");
    if (options.isPartial) {
      const tail = all.slice(-3).map((line) => theme.fg("dim", line));
      return lines(() => tree(theme, tail));
    }
    const max = options.expanded ? 200 : 5;
    const shown = context.isError ? all.slice(-max) : all.slice(0, max);
    const body = shown.map((line) => theme.fg(color, line));
    if (all.length > max) {
      const more = theme.fg("dim", `${all.length - max} more lines · ${context.keyText?.("app.tools.expand") || "ctrl+o"} to expand`);
      if (context.isError) body.unshift(more);
      else body.push(more);
    }
    return lines(() => tree(theme, body));
  },
};

function summarize(verb: string, describe: (args: any, cwd: string) => string, noun: string, nouns: string) {
  return {
    renderShell: "self" as const,
    renderCall: callRow((args, cwd) => ({ verb, arg: describe(args, cwd) })),
    renderResult(result: Result, options: { expanded: boolean; isPartial: boolean }, theme: Theme, context: any) {
      settle(context);
      if (options.isPartial) return EMPTY;
      if (context.isError) return lines(() => tree(theme, errorBody(theme, result)));
      const text = textOf(result).trim();
      const all = text ? text.split("\n") : [];
      const state = context.state as RowShared;
      state.extra = theme.fg("dim", `· ${all.length} ${all.length === 1 ? noun : nouns}`);
      if (!options.expanded) return EMPTY;
      return lines(() => tree(theme, clip(theme, all.map((line) => theme.fg("toolOutput", line)), 40)));
    },
  };
}

const RENDERERS: Record<string, unknown> = {
  read: READ,
  edit: EDIT,
  write: WRITE,
  bash: BASH,
  grep: summarize("Searched", (args, cwd) => `${args.pattern ?? ""}${args.path ? ` in ${shortPath(args.path, cwd)}` : ""}`, "line", "lines"),
  find: summarize("Found", (args, cwd) => `${args.pattern ?? ""}${args.path ? ` in ${shortPath(args.path, cwd)}` : ""}`, "path", "paths"),
  ls: summarize("Listed", (args, cwd) => shortPath(args.path ?? ".", cwd), "entry", "entries"),
};

export function registerBuiltinRenderers(pi: ExtensionAPI) {
  pi.registerToolRenderer((name, next) => (RENDERERS[name] as any) ?? next());
}
