// Drawing primitives for tool rows. Every row has the same shape: a bullet,
// a bold verb, a dim argument, and result lines that hang from a `└`.
//
//   • Edited forecast.lus +3 -1
//     12 -local units = "metric"
//     12 +local units = args.units or "metric"
//     └ lsp clean
import type { Theme } from "@earendil-works/pi-coding-agent";
import { highlightCode, getLanguageFromPath } from "@earendil-works/pi-coding-agent";
import { type Component, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { parseDiff } from "./parse.ts";

/** A component whose lines are computed from the width at render time. */
export class Lines implements Component {
  private draw: (width: number) => string[];
  constructor(draw: (width: number) => string[]) {
    this.draw = draw;
  }
  setDraw(draw: (width: number) => string[]) {
    this.draw = draw;
  }
  render(width: number): string[] {
    return this.draw(width).map((line) => truncateToWidth(line, width));
  }
  invalidate() {}
}

export function lines(draw: (width: number) => string[]): Lines {
  return new Lines(draw);
}

export const EMPTY = lines(() => []);

export type RowState = "running" | "ok" | "error";

export interface RowContext {
  isError: boolean;
  isPartial: boolean;
  executionStarted: boolean;
  durationMs: number | undefined;
}

export function rowState(context: RowContext): RowState {
  if (context.isError) return "error";
  if (context.durationMs === undefined && (context.isPartial || context.executionStarted)) return "running";
  return "ok";
}

/** `• Verb argument`, with the bullet colored by state. */
export function head(theme: Theme, state: RowState, verb: string, arg = "", extra = ""): string {
  const bullet = state === "error" ? theme.fg("error", "•") : state === "running" ? theme.fg("dim", "•") : theme.fg("accent", "•");
  let text = `${bullet} ${theme.bold(verb)}`;
  if (arg) text += ` ${theme.fg("muted", arg)}`;
  if (extra) text += ` ${extra}`;
  return text;
}

/** Hangs result lines under a row: the first gets `└`, the rest align with it. */
export function tree(theme: Theme, body: string[]): string[] {
  return body.map((line, index) => (index === 0 ? `  ${theme.fg("dim", "└")} ${line}` : `    ${line}`));
}

/** Lines that hang under a row while it waits, such as a lock holder. */
export function waiting(theme: Theme, body: string[]): string[] {
  return body.map((line) => `  ${theme.fg("dim", "│")} ${theme.fg("dim", line)}`);
}

export function counts(theme: Theme, added: number, removed: number): string {
  const parts: string[] = [];
  if (added) parts.push(theme.fg("toolDiffAdded", `+${added}`));
  if (removed) parts.push(theme.fg("toolDiffRemoved", `-${removed}`));
  return parts.join(" ");
}

export function seconds(ms: number | undefined): string {
  if (ms === undefined) return "";
  if (ms < 1000) return `${ms}ms`;
  const s = ms / 1000;
  if (s < 60) return `${s.toFixed(s < 10 ? 2 : 1)}s`;
  return `${Math.floor(s / 60)}m ${String(Math.round(s % 60)).padStart(2, "0")}s`;
}

/** Shortens a path for display: relative to cwd, and `~` for home. */
export function shortPath(path: string, cwd: string): string {
  if (!path) return path;
  if (path.startsWith(cwd + "/")) return path.slice(cwd.length + 1);
  const home = process.env.HOME;
  if (home && path.startsWith(home + "/")) return "~" + path.slice(home.length);
  return path;
}

/** Keeps the first `max` lines and says how many were left out. */
export function clip(theme: Theme, body: string[], max: number, hint?: string): string[] {
  if (body.length <= max) return body;
  const rest = body.length - max;
  const more = `${rest} more line${rest === 1 ? "" : "s"}`;
  return [...body.slice(0, max), theme.fg("dim", hint ? `${more} · ${hint}` : more)];
}

const TINTS = {
  dark: { add: [28, 43, 11], del: [42, 21, 18] },
  light: { add: [236, 247, 214], del: [251, 231, 228] },
} as const;

function tint(appearance: string, kind: "add" | "del"): string {
  const [r, g, b] = TINTS[appearance === "light" ? "light" : "dark"][kind];
  return `\x1b[48;2;${r};${g};${b}m`;
}

/** Paints a full-width background under a line that may carry its own colors. */
function paint(line: string, bg: string, width: number): string {
  const kept = line.replace(/\x1b\[(0|49)?m/g, (reset) => reset + bg);
  const pad = Math.max(0, width - visibleWidth(line));
  return bg + kept + " ".repeat(pad) + "\x1b[49m";
}

function highlightLine(text: string, lang: string | undefined): string {
  if (!lang) return text;
  try {
    return highlightCode(text, lang)[0] ?? text;
  } catch {
    return text;
  }
}

/**
 * Renders a display diff with line numbers and tinted rows. Lus files use the
 * Lua grammar, which colors most Lus code correctly.
 */
export function renderDiff(theme: Theme, diff: string, path: string, width: number, max: number): string[] {
  const lang = path.endsWith(".lus") ? "lua" : getLanguageFromPath(path);
  const parsed = parseDiff(diff);
  const shown = parsed.slice(0, max);
  const out = shown.map((line) => {
    const num = theme.fg("dim", line.num.padStart(4));
    if (line.kind === "gap") return `    ${theme.fg("dim", "  ⋮")}`;
    if (line.kind === "ctx") return `${num}  ${theme.fg("toolDiffContext", line.text)}`;
    const sign = line.kind === "add" ? theme.fg("toolDiffAdded", "+") : theme.fg("toolDiffRemoved", "-");
    const body = line.kind === "add" ? highlightLine(line.text, lang) : theme.fg("toolDiffRemoved", line.text);
    return paint(`${num} ${sign}${body}`, tint(theme.appearance, line.kind), width);
  });
  const rest = parsed.length - max;
  if (rest > 0) out.push(theme.fg("dim", `    ${rest} more line${rest === 1 ? "" : "s"}`));
  return out;
}
