// Parsers for the output of the tools the harness wraps. They import nothing
// from Pi, so the tests run them under plain Node.

// lus test prints "N files, P passed, F failed, S skipped" last.
export interface TestTally {
  files: number;
  passed: number;
  failed: number;
  skipped: number;
  fileErrors: number;
}

export function parseTestSummary(output: string): TestTally | undefined {
  const match = /(\d+) files?, (\d+) passed, (\d+) failed, (\d+) skipped(?:, (\d+) files? with errors)?/.exec(output);
  if (!match) return undefined;
  return {
    files: Number(match[1]),
    passed: Number(match[2]),
    failed: Number(match[3]),
    skipped: Number(match[4]),
    fileErrors: Number(match[5] ?? 0),
  };
}

/** The failing tests and file errors of a `lus test` report, one block each. */
export function testFailures(output: string): string[] {
  const out: string[] = [];
  for (const line of output.split("\n")) {
    if (/^\s+FAIL /.test(line) || /^\s+file error:/.test(line)) out.push(line.trim());
    else if (/^\s{7}\S/.test(line) && out.length) out.push("  " + line.trim());
  }
  return out;
}

// Diff rendering. The display diff from the built-in edit tool numbers each
// line: "+12 text", "-12 text", " 12 text", and "    ..." for a gap.

export interface DiffLine {
  kind: "add" | "del" | "ctx" | "gap";
  num: string;
  text: string;
}

export function parseDiff(diff: string): DiffLine[] {
  const out: DiffLine[] = [];
  for (const raw of diff.split("\n")) {
    if (!raw) continue;
    const sign = raw[0];
    const match = /^[+\- ](\s*\d*) ?(.*)$/.exec(raw);
    if (!match) continue;
    const num = match[1];
    const text = match[2];
    if (sign === " " && num.trim() === "" && text.trim() === "...") {
      out.push({ kind: "gap", num, text });
    } else {
      out.push({ kind: sign === "+" ? "add" : sign === "-" ? "del" : "ctx", num, text });
    }
  }
  return out;
}

export function diffStats(diff: string): { added: number; removed: number } {
  let added = 0;
  let removed = 0;
  for (const line of parseDiff(diff)) {
    if (line.kind === "add") added++;
    else if (line.kind === "del") removed++;
  }
  return { added, removed };
}

