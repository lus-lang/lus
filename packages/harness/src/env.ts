// Locates the pieces the harness runs: the `lus` binary, the language
// server, the agent skills, and the Lus repository when the working
// directory is inside it.
import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** The directory of the harness package. */
export const HARNESS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * The root that holds `packages/language-server` and `.agents`. In a checkout
 * it is the repository. An installed harness keeps the same layout below its
 * version directory, so one rule covers both.
 */
export const SOURCE_ROOT = resolve(HARNESS_DIR, "..", "..");

export const LANGUAGE_SERVER_DIR = join(SOURCE_ROOT, "packages", "language-server");
export const AGENTS_DIR = join(SOURCE_ROOT, ".agents");

/** Walks up from `start` and returns the first directory that `test` accepts. */
export function findUp(start: string, test: (dir: string) => boolean): string | undefined {
  let dir = resolve(start);
  for (;;) {
    if (test(dir)) return dir;
    const parent = dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}

/**
 * The root of the Lus monorepo that contains `cwd`, recognized by the build
 * lock script and the runtime build file.
 */
export function findLusRepo(cwd: string): string | undefined {
  return findUp(cwd, (dir) =>
    existsSync(join(dir, "tools", "with-build-lock.sh")) &&
    existsSync(join(dir, "runtime", "build.zig")) &&
    existsSync(join(dir, "mise.toml")),
  );
}

export interface LusBinary {
  path: string;
  version: string;
  /** True for a 2.x runtime, which has `check`, `fmt`, `test`, and `doc`. */
  supported: boolean;
}

function probe(path: string): LusBinary | undefined {
  // `lus -v` prints the version to standard error.
  const res = spawnSync(path, ["-v"], { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "pipe"] });
  const match = /Lus\s+(\S+)/.exec(`${res.stdout ?? ""}${res.stderr ?? ""}`);
  if (!match) return undefined;
  const version = match[1];
  return { path, version, supported: /^[2-9]\./.test(version) };
}

/**
 * Finds the `lus` to run. `LUS_BIN` wins. Inside the Lus repository the
 * freshly built runtime comes next, then the `lus` that `install.sh` manages,
 * then the first `lus` on PATH.
 */
export function findLus(cwd: string): LusBinary | undefined {
  const candidates: string[] = [];
  if (process.env.LUS_BIN) candidates.push(process.env.LUS_BIN);
  const repo = findLusRepo(cwd);
  if (repo) candidates.push(join(repo, "runtime", "zig-out", "bin", "lus"));
  const home = process.env.LUS_HOME ?? join(process.env.HOME ?? "", ".lus");
  candidates.push(join(home, "bin", "lus"));
  candidates.push("lus");
  let fallback: LusBinary | undefined;
  for (const path of candidates) {
    if (path !== "lus" && !existsSync(path)) continue;
    const found = probe(path);
    if (found?.supported) return found;
    fallback ??= found;
  }
  return fallback;
}

/** Reads a text file, or returns undefined when it is missing. */
export function readText(path: string): string | undefined {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
}

/** Appends a line to the file named by LUS_HARNESS_DEBUG, when it is set. */
export function debug(message: string) {
  const file = process.env.LUS_HARNESS_DEBUG;
  if (!file) return;
  try {
    appendFileSync(file, `${new Date().toISOString().slice(11, 23)} ${message}\n`);
  } catch {}
}
