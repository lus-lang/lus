// Diagnostics of one Lus file, from the language server or from `lus check`,
// in one shape for the model and for the screen.
import type { Theme } from "@earendil-works/pi-coding-agent";

export type Severity = "error" | "warning" | "info" | "hint";

export interface Diagnostic {
  line: number;
  column: number;
  severity: Severity;
  message: string;
  code?: string;
}

export interface LusFileReport {
  /** Where the diagnostics came from. */
  source: "lsp" | "check";
  path: string;
  diagnostics: Diagnostic[];
}

const LSP_SEVERITY: Record<number, Severity> = { 1: "error", 2: "warning", 3: "info", 4: "hint" };

export function fromLsp(raw: any[]): Diagnostic[] {
  return raw
    .map((d) => ({
      line: (d.range?.start?.line ?? 0) + 1,
      column: (d.range?.start?.character ?? 0) + 1,
      severity: LSP_SEVERITY[d.severity ?? 1] ?? "error",
      // Compile errors carry the chunk name of the document, which says nothing here.
      message: String(d.message ?? "").replace(/^\[string "[^"]*"\]:\d+:\s*/, ""),
      code: d.code === undefined ? undefined : String(d.code),
    }))
    .sort(order);
}

export function fromCheck(raw: any[]): Diagnostic[] {
  return raw
    .map((d) => ({
      line: d.line ?? 1,
      column: d.column ?? 1,
      severity: (["error", "warning", "info", "hint"].includes(d.severity) ? d.severity : "error") as Severity,
      message: String(d.message ?? ""),
      code: d.code,
    }))
    .sort(order);
}

const RANK: Record<Severity, number> = { error: 0, warning: 1, info: 2, hint: 3 };

function order(a: Diagnostic, b: Diagnostic) {
  return RANK[a.severity] - RANK[b.severity] || a.line - b.line || a.column - b.column;
}

/** Errors and warnings are worth the model's attention. Hints only count. */
export function serious(report: LusFileReport): Diagnostic[] {
  return report.diagnostics.filter((d) => d.severity === "error" || d.severity === "warning");
}

/** The text the model reads after an edit. */
export function forModel(report: LusFileReport): string {
  const found = serious(report);
  if (!found.length) return `Lus diagnostics for ${report.path}: none.`;
  const body = found.map((d) => `${report.path}:${d.line}:${d.column}: ${d.severity}: ${d.message}${d.code ? ` [${d.code}]` : ""}`);
  return `Lus diagnostics for ${report.path} (fix the errors before moving on):\n${body.join("\n")}`;
}

function tally(found: Diagnostic[]): { errors: number; warnings: number } {
  let errors = 0;
  let warnings = 0;
  for (const d of found) {
    if (d.severity === "error") errors++;
    else warnings++;
  }
  return { errors, warnings };
}

export function summary(theme: Theme, found: Diagnostic[]): string {
  const { errors, warnings } = tally(found);
  const parts: string[] = [];
  if (errors) parts.push(theme.fg("error", `${errors} error${errors === 1 ? "" : "s"}`));
  if (warnings) parts.push(theme.fg("warning", `${warnings} warning${warnings === 1 ? "" : "s"}`));
  return parts.join(theme.fg("dim", " · "));
}

/** One line per finding, or `lsp clean`. Collapsed rows show three findings. */
export function diagnosticLines(theme: Theme, report: LusFileReport, expanded: boolean): string[] {
  const label = theme.fg("dim", report.source === "lsp" ? "lsp" : "check");
  const found = serious(report);
  if (!found.length) return [`${label} ${theme.fg("dim", "clean")}`];
  const max = expanded ? found.length : 3;
  const out = [`${label} ${summary(theme, found)}`];
  for (const d of found.slice(0, max)) {
    const where = theme.fg("dim", `${d.line}:${d.column}`);
    const color = d.severity === "error" ? "error" : "warning";
    out.push(`${where} ${theme.fg(color, d.message)}${d.code ? theme.fg("dim", ` ${d.code}`) : ""}`);
  }
  if (found.length > max) out.push(theme.fg("dim", `${found.length - max} more`));
  return out;
}
