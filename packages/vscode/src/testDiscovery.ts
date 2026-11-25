/**
 * Pure helpers of the test explorer: finding the tests of a test file,
 * reading the JSON records of `lus test --json`, and reading the lcov
 * tracefile of `lus test --coverage-out`. They import nothing from VS Code,
 * so the unit tests run them under Node.
 */

/** A test or a benchmark that `lus test` runs from a test file. */
export interface FoundTest {
  name: string;
  /** Zero-based line of the definition. */
  line: number;
  kind: "test" | "bench";
}

const DEFINITIONS = [
  // function NAME_test(...)  and  local function NAME_test(...)
  /^(?:local\s+)?function\s+([A-Za-z_][A-Za-z0-9_]*_(test|bench))\s*\(/,
  // local NAME_test = function(...)
  /^local\s+([A-Za-z_][A-Za-z0-9_]*_(test|bench))\s*=\s*function\b/,
];

/**
 * The tests and benchmarks that `lus test` reads from a test file: the
 * top-level functions whose names end in `_test` or `_bench`. A top-level
 * definition starts at the first column, which is how the formatter writes
 * one.
 */
export function findTests(text: string): FoundTest[] {
  const found: FoundTest[] = [];
  const seen = new Set<string>();
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    for (const re of DEFINITIONS) {
      const m = re.exec(lines[i]);
      if (m && !seen.has(m[1])) {
        seen.add(m[1]);
        found.push({ name: m[1], line: i, kind: m[2] === "bench" ? "bench" : "test" });
        break;
      }
    }
  }
  return found;
}

/** One result record of `lus test --json`. */
export interface TestRecord {
  status: "pass" | "fail" | "skip" | "bench" | "coverage";
  name: string;
  file: string;
  line: number;
  duration: number;
  message: string;
  ns?: number;
}

/** Parses a line of `lus test --json` output, or returns undefined. */
export function parseRecord(line: string): TestRecord | undefined {
  const trimmed = line.trim();
  if (!trimmed.startsWith("{")) return undefined;
  try {
    const value = JSON.parse(trimmed);
    if (typeof value !== "object" || value === null || typeof value.status !== "string" || typeof value.name !== "string") {
      return undefined;
    }
    return {
      status: value.status,
      name: value.name,
      file: typeof value.file === "string" ? value.file : "",
      line: typeof value.line === "number" ? value.line : 0,
      duration: typeof value.duration === "number" ? value.duration : 0,
      message: typeof value.message === "string" ? value.message : "",
      ns: typeof value.ns === "number" ? value.ns : undefined,
    };
  } catch {
    return undefined;
  }
}

/**
 * The test that a record reports: a case of a table-driven test is named
 * `NAME_test[KEY]`, and it belongs to `NAME_test`.
 */
export function baseName(recordName: string): string {
  const bracket = recordName.indexOf("[");
  return bracket < 0 ? recordName : recordName.slice(0, bracket);
}

/**
 * The position that a failure message names, as `FILE:LINE:` at its start,
 * with a zero-based line, or undefined.
 */
export function failureLine(message: string, fileName: string): number | undefined {
  const escaped = fileName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const m = new RegExp(`(?:^|\\s)${escaped}:(\\d+):`).exec(message);
  return m ? Number(m[1]) - 1 : undefined;
}

/** The coverage of one file in an lcov tracefile. */
export interface FileLines {
  path: string;
  /** Each line with code, one-based, mapped to its hit count. */
  lines: Map<number, number>;
}

/** Parses an lcov tracefile into the lines of each source file. */
export function parseLcov(text: string): FileLines[] {
  const files: FileLines[] = [];
  let current: FileLines | undefined;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("SF:")) {
      current = { path: line.slice(3), lines: new Map() };
      files.push(current);
    } else if (line.startsWith("DA:") && current) {
      const [n, hits] = line.slice(3).split(",");
      const lineNo = Number(n);
      if (Number.isInteger(lineNo)) current.lines.set(lineNo, Number(hits) || 0);
    } else if (line === "end_of_record") {
      current = undefined;
    }
  }
  return files;
}
