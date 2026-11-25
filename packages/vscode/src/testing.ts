import { spawn } from "node:child_process";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";
import { lusExecutable } from "./debugAdapter";
import {
  baseName,
  failureLine,
  findTests,
  parseLcov,
  parseRecord,
  type TestRecord,
} from "./testDiscovery";

/**
 * Registers the test controller. Every `*_test.lus` file of the workspace
 * is an item, and its top-level `NAME_test` and `NAME_bench` functions are
 * its children, which puts a run button beside each definition. A run
 * starts `lus test --json` once per file, with `--filter` when it runs one
 * test, and maps each record to its item. The coverage profile adds
 * `--coverage-out` and shows the lines of the code under test that ran.
 */
export function registerTesting(context: vscode.ExtensionContext): void {
  const controller = vscode.tests.createTestController("lus", "Lus");
  context.subscriptions.push(controller);

  const refreshFile = (uri: vscode.Uri, text: string): void => {
    let file = controller.items.get(uri.toString());
    const tests = findTests(text);
    if (tests.length === 0) {
      if (file) controller.items.delete(file.id);
      return;
    }
    if (!file) {
      file = controller.createTestItem(uri.toString(), path.basename(uri.fsPath), uri);
      controller.items.add(file);
    }
    const children: vscode.TestItem[] = [];
    for (const t of tests) {
      const item = controller.createTestItem(`${uri.toString()}#${t.name}`, t.name, uri);
      item.range = new vscode.Range(t.line, 0, t.line, 0);
      if (t.kind === "bench") item.tags = [benchTag];
      children.push(item);
    }
    file.children.replace(children);
  };

  const readFile = async (uri: vscode.Uri): Promise<void> => {
    try {
      const bytes = await vscode.workspace.fs.readFile(uri);
      refreshFile(uri, Buffer.from(bytes).toString("utf8"));
    } catch {
      const file = controller.items.get(uri.toString());
      if (file) controller.items.delete(file.id);
    }
  };

  controller.resolveHandler = async (item) => {
    if (item) return;
    const uris = await vscode.workspace.findFiles("**/*_test.lus", "**/{node_modules,.git,zig-out}/**");
    await Promise.all(uris.map(readFile));
  };
  controller.refreshHandler = async () => {
    controller.items.replace([]);
    await controller.resolveHandler?.(undefined);
  };

  const watcher = vscode.workspace.createFileSystemWatcher("**/*_test.lus");
  context.subscriptions.push(
    watcher,
    watcher.onDidCreate(readFile),
    watcher.onDidChange(readFile),
    watcher.onDidDelete((uri) => controller.items.delete(uri.toString())),
    vscode.workspace.onDidChangeTextDocument((e) => {
      if (e.document.uri.fsPath.endsWith("_test.lus")) refreshFile(e.document.uri, e.document.getText());
    }),
  );

  const run = (coverage: boolean) => async (request: vscode.TestRunRequest, token: vscode.CancellationToken) => {
    const testRun = controller.createTestRun(request);
    try {
      for (const [file, only] of selection(controller, request)) {
        if (token.isCancellationRequested) break;
        await runFile(testRun, file, only, coverage, token);
      }
    } finally {
      testRun.end();
    }
  };

  controller.createRunProfile("Run", vscode.TestRunProfileKind.Run, run(false), true);
  const coverageProfile = controller.createRunProfile("Run with Coverage", vscode.TestRunProfileKind.Coverage, run(true), true);
  coverageProfile.loadDetailedCoverage = async (_run, fileCoverage) => {
    const lines = detail.get(fileCoverage) ?? new Map<number, number>();
    return [...lines].map(
      ([line, hits]) => new vscode.StatementCoverage(hits, new vscode.Position(line - 1, 0)),
    );
  };
}

const benchTag = new vscode.TestTag("bench");

/** The detailed lines of each file coverage this session reported. */
const detail = new WeakMap<vscode.FileCoverage, Map<number, number>>();

/**
 * The files to run and, for each, the tests to keep, or null for all of
 * them. A request for a file, or for no item at all, runs whole files.
 */
function selection(
  controller: vscode.TestController,
  request: vscode.TestRunRequest,
): Map<vscode.TestItem, Set<vscode.TestItem> | null> {
  const files = new Map<vscode.TestItem, Set<vscode.TestItem> | null>();
  const excluded = new Set(request.exclude ?? []);
  const add = (item: vscode.TestItem): void => {
    if (excluded.has(item)) return;
    if (!item.parent) {
      files.set(item, null);
      return;
    }
    const current = files.get(item.parent);
    if (current === null) return;
    const set = current ?? new Set<vscode.TestItem>();
    set.add(item);
    files.set(item.parent, set);
  };
  if (request.include) request.include.forEach(add);
  else controller.items.forEach(add);
  return files;
}

async function runFile(
  run: vscode.TestRun,
  file: vscode.TestItem,
  only: Set<vscode.TestItem> | null,
  coverage: boolean,
  token: vscode.CancellationToken,
): Promise<void> {
  const uri = file.uri!;
  const folder = vscode.workspace.getWorkspaceFolder(uri);
  const cwd = folder?.uri.fsPath ?? path.dirname(uri.fsPath);
  const items = new Map<string, vscode.TestItem>();
  file.children.forEach((child) => items.set(child.label, child));
  const wanted = only ? [...only] : [...items.values()];
  wanted.forEach((item) => run.started(item));

  const args = ["test", "--json"];
  // One test runs alone through the name filter, which matches by
  // substring, so the records of other matches are ignored below.
  if (only && only.size === 1) args.push("--filter", [...only][0].label);
  let lcovPath: string | undefined;
  if (coverage) {
    lcovPath = path.join(os.tmpdir(), `lus-coverage-${process.pid}-${Date.now()}.info`);
    args.push("--coverage-out", lcovPath);
  }
  args.push(uri.fsPath);

  const reported = new Set<vscode.TestItem>();
  const failed = new Set<vscode.TestItem>();
  const output: string[] = [];
  const exitCode = await new Promise<number | null>((resolve) => {
    const child = spawn(lusExecutable(folder), args, { cwd });
    token.onCancellationRequested(() => child.kill());
    let pending = "";
    child.stdout.on("data", (chunk: Buffer) => {
      pending += chunk.toString("utf8");
      let nl: number;
      while ((nl = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, nl);
        pending = pending.slice(nl + 1);
        const record = parseRecord(line);
        if (!record) {
          output.push(line);
          continue;
        }
        const item = items.get(baseName(record.name));
        if (item && wanted.includes(item)) report(run, item, record, reported, failed);
      }
    });
    child.stderr.on("data", (chunk: Buffer) => output.push(chunk.toString("utf8")));
    child.on("error", (cause) => {
      output.push(`cannot start ${lusExecutable(folder)}: ${cause.message}`);
      resolve(null);
    });
    child.on("close", (code) => resolve(code));
  });
  if (output.length > 0) run.appendOutput(output.join("\r\n").replace(/\r?\n/g, "\r\n") + "\r\n");

  // A test without a record did not run, such as every test of a file that
  // fails to load. Its file's output says why.
  for (const item of wanted) {
    if (reported.has(item)) continue;
    if (exitCode === 0) run.skipped(item);
    else run.errored(item, new vscode.TestMessage(output.join("\n") || "the test did not run"));
  }

  if (lcovPath) {
    try {
      for (const f of parseLcov(await fs.readFile(lcovPath, "utf8"))) {
        const fileUri = vscode.Uri.file(path.isAbsolute(f.path) ? f.path : path.join(cwd, f.path));
        let covered = 0;
        for (const hits of f.lines.values()) if (hits > 0) covered++;
        const fc = new vscode.FileCoverage(fileUri, new vscode.TestCoverageCount(covered, f.lines.size));
        detail.set(fc, f.lines);
        run.addCoverage(fc);
      }
    } catch {
      // No tracefile means no code under test ran.
    } finally {
      await fs.rm(lcovPath, { force: true });
    }
  }
}

/**
 * Reports one record. A table-driven test passes when every case passes,
 * so a failed case fails its test, and a later passing case keeps it
 * failed.
 */
function report(
  run: vscode.TestRun,
  item: vscode.TestItem,
  record: TestRecord,
  reported: Set<vscode.TestItem>,
  failed: Set<vscode.TestItem>,
): void {
  switch (record.status) {
    case "pass":
      if (!failed.has(item)) run.passed(item, record.duration);
      break;
    case "bench":
      run.passed(item, record.duration);
      if (record.ns !== undefined) run.appendOutput(`${record.name}: ${formatNs(record.ns)} per call\r\n`, undefined, item);
      break;
    case "skip":
      if (!reported.has(item)) run.skipped(item);
      break;
    case "fail": {
      const message = new vscode.TestMessage(record.message);
      const uri = item.uri!;
      const line = failureLine(record.message, path.basename(uri.fsPath));
      if (line !== undefined) message.location = new vscode.Location(uri, new vscode.Position(line, 0));
      run.failed(item, message, record.duration);
      failed.add(item);
      break;
    }
    default:
      return;
  }
  reported.add(item);
}

function formatNs(ns: number): string {
  if (ns < 1e3) return `${ns.toFixed(1)} ns`;
  if (ns < 1e6) return `${(ns / 1e3).toFixed(2)} us`;
  if (ns < 1e9) return `${(ns / 1e6).toFixed(2)} ms`;
  return `${(ns / 1e9).toFixed(3)} s`;
}
