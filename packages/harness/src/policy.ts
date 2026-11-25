// The rules of the harness as pure functions: which permissions a script
// asks for, which grants cover a denial, which commands go through the build
// lock, and which prose breaks the style guide. They import nothing from Pi,
// so the tests run them under plain Node.
import { isAbsolute, join, relative, resolve } from "node:path";

/** Pledges written as string literals: `pledge("fs:read", 'network:http')`. */
export function scanPledges(source: string): string[] {
  const found = new Set<string>();
  const code = source.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, "").replace(/--[^\n]*/g, "");
  for (const call of code.matchAll(/\bpledge\s*\(([^)]*)\)/g)) {
    for (const lit of call[1].matchAll(/"([^"\\]*)"|'([^'\\]*)'/g)) {
      const name = (lit[1] ?? lit[2]).trim();
      if (/^~?[a-z]+(:[a-z]+)?(=.*)?$/.test(name) && !name.startsWith("~") && name !== "seal") found.add(name);
    }
  }
  return [...found];
}

export interface Denial {
  name: string;
  value?: string;
}

/** Reads `permission "network:http" denied for 'https://…'` from an error. */
export function parseDenial(output: string): Denial | undefined {
  const match = /permission "([^"]+)" denied(?: for '([^']*)')?/.exec(output);
  if (!match) return undefined;
  return { name: match[1], value: match[2] };
}

/** The grant that would cover a denial: the same name, with its value when it has one. */
export function grantFor(denial: Denial, cwd: string): string {
  if (!denial.value) return denial.name;
  if (denial.name.startsWith("fs")) {
    const abs = isAbsolute(denial.value) ? denial.value : resolve(cwd, denial.value);
    return `${denial.name}=${abs}`;
  }
  if (denial.name.startsWith("network")) {
    try {
      const url = new URL(denial.value);
      return `${denial.name}=${url.host}`;
    } catch {}
  }
  return `${denial.name}=${denial.value}`;
}

/** The grants every run gets: reading the project and loading its modules. */
export function baseGrants(root: string): string[] {
  return [`fs:read=${root}`, `fs:read=${root}/*`, "load"];
}

/** True when a grant is no wider than the base grants. */
export function isBase(grant: string, root: string): boolean {
  if (grant === "load") return true;
  const match = /^fs:read=(.*)$/.exec(grant);
  if (!match) return false;
  const value = match[1].startsWith(".") ? resolve(root, match[1]) : match[1];
  const rel = relative(root, value.replace(/\/\*$/, ""));
  return !rel.startsWith("..") && !isAbsolute(rel);
}

const LUS_SUBCOMMANDS = new Set(["test", "fmt", "check", "doc", "ast", "build", "compile", "debug", "help", "agents", "version"]);

/**
 * Finds a direct `lus` invocation that runs code: `lus script.lus`,
 * `lus run script.lus`, or `lus -e …`. Returns its `-P` grants.
 */
export function lusInvocation(command: string): { grants: string[]; script?: string } | undefined {
  for (const segment of command.split(/&&|\|\||;|\|/)) {
    const words = segment.trim().match(/'[^']*'|"[^"]*"|\S+/g) ?? [];
    let i = 0;
    while (i < words.length && /^[A-Z_][A-Z0-9_]*=/.test(words[i])) i++;
    if (!/(^|\/)lus$/.test(words[i] ?? "")) continue;
    const rest = words.slice(i + 1).map((w) => w.replace(/^['"]|['"]$/g, ""));
    if (rest[0] && LUS_SUBCOMMANDS.has(rest[0])) continue;
    if (rest[0] === "run") rest.shift();
    const grants: string[] = [];
    let script: string | undefined;
    let runs = false;
    for (let j = 0; j < rest.length; j++) {
      const w = rest[j];
      if (w === "-P" || w === "--pledge") grants.push(rest[++j] ?? "");
      else if (w.startsWith("--pledge=")) grants.push(w.slice(9));
      else if (w.startsWith("-P")) grants.push(w.slice(2));
      else if (w === "-e") {
        runs = true;
        j++;
      } else if (w === "-l" || w === "--include" || w === "-F" || w === "--flag" || w === "--gc-pause") j++;
      else if (w === "-") {
        runs = true;
        break;
      } else if (!w.startsWith("-")) {
        script = w;
        runs = true;
        break;
      }
    }
    if (runs) return { grants, script };
  }
  return undefined;
}

export interface MiseTask {
  name: string;
  description?: string;
  run?: string[] | string;
  depends?: string[];
}

function runText(task: MiseTask | undefined): string {
  if (!task?.run) return "";
  return Array.isArray(task.run) ? task.run.join("\n") : task.run;
}

/**
 * Decides whether a mise task runs inside the build lock. A task whose own
 * commands start an unlocked `zig build` is wrapped, unless it or a task it
 * depends on takes the lock itself, which would wait on the outer lock.
 */
export function miseLockPolicy(tasks: MiseTask[], name: string): "wrap" | "self" | "none" | "unsafe" {
  const byName = new Map(tasks.map((t) => [t.name, t]));
  const locks = (n: string, seen = new Set<string>()): boolean => {
    if (seen.has(n)) return false;
    seen.add(n);
    const t = byName.get(n);
    if (/with-build-lock/.test(runText(t))) return true;
    return (t?.depends ?? []).some((d) => locks(d, seen));
  };
  const own = runText(byName.get(name));
  const unlocked = own.split("\n").some((cmd) => /\bzig build\b/.test(cmd) && !/with-build-lock/.test(cmd));
  const takes = locks(name);
  if (!unlocked) return takes ? "self" : "none";
  return takes ? "unsafe" : "wrap";
}

/**
 * Routes `zig build` in a bash command through the build lock and caps its
 * jobs at two. Returns the rewritten command, or undefined when nothing
 * changes.
 */
export function lockZigBuild(command: string, repo: string): string | undefined {
  if (!/\bzig build\b/.test(command) || /with-build-lock/.test(command)) return undefined;
  const lock = `sh ${join(repo, "tools", "with-build-lock.sh")}`;
  const out = command.replace(/(^|&&|\|\||;|\n|\(|\bthen\b|\bdo\b)(\s*)((?:[A-Z_][A-Z0-9_]*=\S*\s+)*)zig build\b([^\n;&|)]*)/g, (_m, sep, space, env, rest) => {
    let args = rest.replace(/(^|\s)-j\s*(\d+)/g, (_x: string, s: string, n: string) => `${s}-j${Math.min(Number(n), 2)}`);
    if (!/(^|\s)-j\d/.test(args)) args = ` -j2${args}`;
    return `${sep}${space}${env}${lock} zig build${args}`;
  });
  return out === command ? undefined : out;
}

/** Semicolons in prose, ignoring fenced code, inline code, HTML entities, and front matter. */
export function semicolons(name: string, text: string): string[] {
  const out: string[] = [];
  let fence = false;
  let front = false;
  text.split("\n").forEach((line, index) => {
    if (index === 0 && line === "---") {
      front = true;
      return;
    }
    if (front) {
      if (line === "---") front = false;
      return;
    }
    if (/^\s*(```|~~~)/.test(line)) {
      fence = !fence;
      return;
    }
    if (fence || /^\s*(import|export) /.test(line) || /^\s{4,}\S/.test(line)) return;
    const plain = line.replace(/`[^`]*`/g, "").replace(/&[#a-zA-Z0-9]+;/g, "").replace(/<[^>]*>/g, "").replace(/\{[^}]*\}/g, "");
    if (plain.includes(";")) out.push(`${name}:${index + 1}: semicolon in prose`);
  });
  return out;
}

