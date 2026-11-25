// Repository mode: tools for working on Lus itself. It turns on when the
// working directory is inside the Lus monorepo.
import { execFileSync, spawn } from "node:child_process";
import { cpus } from "node:os";
import { statSync } from "node:fs";
import { join, relative } from "node:path";
import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readText } from "./env.ts";
import { parseTestSummary, testFailures, type TestTally } from "./parse.ts";
import { lockZigBuild, type MiseTask, miseLockPolicy, semicolons } from "./policy.ts";
import { clip, EMPTY, head, lines, rowState, seconds, tree, waiting } from "./render.ts";
import type { Session } from "./session.ts";

export const JIT_MODES = ["on", "off", "eager", "opt-eager"] as const;

/**
 * Checks one file of the repository. The dash and name rules come from
 * tools/lint-repo.js, which checks the whole tree in a fraction of a second,
 * so its findings are filtered to the file. Prose files also get the
 * semicolon rule of spec/design/style.md, outside code. Returns undefined for
 * a file outside the repository.
 */
export function lintProse(repo: string, path: string, prose: boolean): string[] | undefined {
  const rel = relative(repo, path);
  if (rel.startsWith("..")) return undefined;
  const problems: string[] = [];
  try {
    execFileSync("node", [join(repo, "tools", "lint-repo.js")], { cwd: repo, stdio: ["ignore", "pipe", "pipe"], timeout: 20000 });
  } catch (error) {
    const out = String((error as { stderr?: Buffer }).stderr ?? "");
    for (const line of out.split("\n")) if (line.startsWith(`${rel}:`)) problems.push(line);
  }
  if (prose) problems.push(...semicolons(rel, readText(path) ?? ""));
  return problems;
}

function miseTasks(repo: string): MiseTask[] {
  try {
    return JSON.parse(execFileSync("mise", ["tasks", "ls", "--json"], { cwd: repo, encoding: "utf8", timeout: 20000 }));
  } catch {
    return [];
  }
}

/** Runs a command and reports output lines as they arrive. */
function stream(
  command: string,
  args: string[],
  options: { cwd: string; env?: NodeJS.ProcessEnv; signal?: AbortSignal; timeout: number; onLine?: (line: string) => void },
): Promise<{ code: number | null; output: string }> {
  return new Promise((resolve) => {
    const child = spawn(command, args, { cwd: options.cwd, env: options.env ?? process.env, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    let partial = "";
    const take = (chunk: Buffer) => {
      const text = chunk.toString();
      output += text;
      partial += text;
      const parts = partial.split("\n");
      partial = parts.pop() ?? "";
      for (const line of parts) options.onLine?.(line);
    };
    child.stdout.on("data", take);
    child.stderr.on("data", take);
    const stop = () => child.kill("SIGTERM");
    options.signal?.addEventListener("abort", stop, { once: true });
    const timer = setTimeout(stop, options.timeout);
    child.on("close", (code) => {
      clearTimeout(timer);
      options.signal?.removeEventListener("abort", stop);
      if (partial) options.onLine?.(partial);
      resolve({ code, output });
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      resolve({ code: 127, output: output + error.message });
    });
  });
}

function age(path: string): string | undefined {
  try {
    const ms = Date.now() - statSync(path).mtimeMs;
    const min = Math.round(ms / 60000);
    if (min < 1) return "just built";
    if (min < 60) return `built ${min}m ago`;
    return `built ${Math.round(min / 60)}h ago`;
  } catch {
    return undefined;
  }
}

function tail(output: string, n: number): string[] {
  return output.replace(/\s+$/, "").split("\n").slice(-n);
}

interface ModeResult {
  mode: string;
  code: number | null;
  tally?: TestTally;
  failures: string[];
}

function renderModes(theme: Theme, modes: ModeResult[], pending: string[]): string {
  const parts = modes.map((m) => {
    const bad = (m.tally?.failed ?? 0) + (m.tally?.fileErrors ?? 0);
    if (m.code === 0 && m.tally) return theme.fg("accent", `${m.mode} ✓`);
    return theme.fg("error", `${m.mode} ✗${bad ? ` ${bad}` : ""}`);
  });
  for (const p of pending) parts.push(theme.fg("dim", `${p} ·`));
  return parts.join("  ");
}

export function registerRepo(pi: ExtensionAPI, session: Session) {
  const repo = () => {
    if (!session.repo) throw new Error("This tool works only inside the Lus repository.");
    return session.repo;
  };

  pi.registerTool({
    name: "lus_build",
    label: "Build",
    description:
      "Build the Lus runtime with zig build under the machine-wide build lock and -j2. Waits while another checkout holds the lock. " +
      "Extra arguments go to zig build, for example -Dgc-stress=97 or --prefix zig-out-stress.",
    promptSnippet: "Build the Lus runtime under the build lock",
    promptGuidelines: ["Build the Lus runtime only with lus_build or mise_task, never with a bare zig build."],
    parameters: Type.Object({
      optimize: Type.Optional(StringEnum(["ReleaseSafe", "Debug", "ReleaseFast", "ReleaseSmall"] as const)),
      steps: Type.Optional(Type.Array(Type.String(), { description: "Build steps such as test or test-embed. Defaults to install." })),
      args: Type.Optional(Type.Array(Type.String(), { description: "More zig build arguments." })),
    }),
    executionMode: "sequential",
    async execute(_id, params, signal, onUpdate, _ctx) {
      const root = repo();
      const zigArgs = ["build", ...(params.steps ?? []), "-j2", `-Doptimize=${params.optimize ?? "ReleaseSafe"}`, ...(params.args ?? []).filter((a) => !/^-j\d*$/.test(a))];
      const start = Date.now();
      let holder: string | undefined;
      const res = await stream("sh", [join(root, "tools", "with-build-lock.sh"), "zig", ...zigArgs], {
        cwd: join(root, "runtime"),
        signal,
        timeout: 60 * 60000,
        onLine(line) {
          const match = /^waiting for the build lock, held by: (.*)$/.exec(line);
          if (match) {
            holder = match[1];
            session.lockHolder = holder;
            session.changed();
            onUpdate?.({ content: [{ type: "text", text: line }], details: { holder, since: Date.now(), command: `zig ${zigArgs.join(" ")}` } });
          } else if (holder) {
            holder = undefined;
            session.lockHolder = undefined;
            session.changed();
            onUpdate?.({ content: [{ type: "text", text: "building" }], details: { command: `zig ${zigArgs.join(" ")}` } });
          }
        },
      });
      session.lockHolder = undefined;
      session.refresh();
      const details = { code: res.code, ms: Date.now() - start, command: `zig ${zigArgs.join(" ")}`, tail: tail(res.output, 30) };
      if (res.code !== 0) {
        return { content: [{ type: "text", text: `zig build failed (exit ${res.code}):\n${tail(res.output, 80).join("\n")}` }], details, isError: true };
      }
      return { content: [{ type: "text", text: `Built in ${seconds(details.ms)}.\n${tail(res.output, 10).join("\n")}` }], details };
    },
    renderShell: "self",
    renderCall(args: any, theme: Theme, context: any) {
      return lines(() => {
        const zig = ["zig build", ...(args?.steps ?? []), "-j2", `-Doptimize=${args?.optimize ?? "ReleaseSafe"}`, ...(args?.args ?? [])].join(" ");
        return [head(theme, rowState(context.state.done ?? context), "Build", zig)];
      });
    },
    renderResult(result: any, options, theme: Theme, context: any) {
      const d = result.details ?? {};
      if (options.isPartial) {
        if (!d.holder) return lines(() => waiting(theme, ["building"]));
        return lines(() => waiting(theme, [`waiting for the build lock, held by ${d.holder} · ${seconds(Date.now() - d.since)}`]));
      }
      context.state.done = { isError: context.isError || d.code !== 0, isPartial: false, executionStarted: true, durationMs: d.ms ?? 0 };
      if (d.code === 0) return lines(() => tree(theme, [`${theme.fg("accent", "built")} ${theme.fg("dim", `in ${seconds(d.ms)}`)}`]));
      const body = [theme.fg("error", `failed, exit ${d.code ?? "killed"}`), ...clip(theme, (d.tail ?? []).map((l: string) => theme.fg("toolOutput", l)), options.expanded ? 30 : 8)];
      return lines(() => tree(theme, body));
    },
  });

  pi.registerTool({
    name: "mise_task",
    label: "mise",
    description:
      "List or run the mise tasks of the Lus repository (mise.toml). Leave task empty to list them. A task that starts zig build outside the lock runs inside it.",
    promptSnippet: "List and run the mise tasks of the Lus repository",
    parameters: Type.Object({
      task: Type.Optional(Type.String()),
      args: Type.Optional(Type.Array(Type.String())),
    }),
    executionMode: "sequential",
    async execute(_id, params, signal, onUpdate, _ctx) {
      const root = repo();
      const tasks = miseTasks(root);
      if (!params.task) {
        const list = tasks.map((t) => `${t.name}: ${t.description ?? ""}`);
        return { content: [{ type: "text", text: list.join("\n") || "No tasks found." }], details: { listed: tasks.length } };
      }
      if (!tasks.some((t) => t.name === params.task)) throw new Error(`no mise task named ${params.task}`);
      const policy = miseLockPolicy(tasks, params.task);
      const mise = ["mise", "run", params.task, ...(params.args?.length ? ["--", ...params.args] : [])];
      const [cmd, ...args] = policy === "wrap" ? ["sh", join(root, "tools", "with-build-lock.sh"), ...mise] : mise;
      const start = Date.now();
      let last = "";
      const res = await stream(cmd, args, {
        cwd: root,
        signal,
        timeout: 4 * 60 * 60000,
        onLine(line) {
          if (!line.trim()) return;
          last = line;
          onUpdate?.({ content: [{ type: "text", text: last }], details: { last, policy } });
        },
      });
      session.refresh();
      const details = { code: res.code, ms: Date.now() - start, policy, tail: tail(res.output, 30) };
      const note = policy === "unsafe" ? "\nNote: this task starts zig build outside the build lock." : "";
      return {
        content: [{ type: "text", text: `mise run ${params.task} exited ${res.code}.${note}\n${tail(res.output, 80).join("\n")}` }],
        details,
        isError: res.code !== 0,
      };
    },
    renderShell: "self",
    renderCall(args: any, theme: Theme, context: any) {
      return lines(() => [head(theme, rowState(context.state.done ?? context), args?.task ? "mise" : "Listed", args?.task ? `run ${args.task} ${(args.args ?? []).join(" ")}`.trim() : "mise tasks")]);
    },
    renderResult(result: any, options, theme: Theme, context: any) {
      const d = result.details ?? {};
      if (options.isPartial) return lines(() => waiting(theme, [d.last ?? "running"]));
      context.state.done = { isError: context.isError, isPartial: false, executionStarted: true, durationMs: d.ms ?? 0 };
      if (d.listed !== undefined) {
        const body = (result.content?.[0]?.text ?? "").split("\n").map((l: string) => theme.fg("dim", l));
        return options.expanded ? lines(() => tree(theme, body)) : lines(() => tree(theme, [theme.fg("dim", `${d.listed} tasks`)]));
      }
      const status = d.code === 0 ? theme.fg("accent", "done") : theme.fg("error", `exit ${d.code ?? "killed"}`);
      const lock = d.policy === "wrap" ? theme.fg("dim", " · held the build lock") : d.policy === "unsafe" ? theme.fg("warning", " · built outside the lock") : "";
      const body = [`${status}${lock} ${theme.fg("dim", seconds(d.ms))}`];
      if (d.code !== 0 || options.expanded) body.push(...clip(theme, (d.tail ?? []).map((l: string) => theme.fg("toolOutput", l)), options.expanded ? 30 : 8));
      return lines(() => tree(theme, body));
    },
  });

  pi.registerTool({
    name: "lus_conformance",
    label: "Conformance",
    description:
      "Run the conformance suite (tests/conformance and the language server tests) with the built runtime under each JIT mode: on, off, eager, and opt-eager. " +
      "Build first with lus_build when the runtime changed.",
    promptSnippet: "Run the conformance suite under every JIT mode",
    promptGuidelines: ["After a runtime change, prove it with lus_conformance under all four JIT modes before calling it done."],
    parameters: Type.Object({
      modes: Type.Optional(Type.Array(StringEnum(JIT_MODES), { description: "Defaults to all four." })),
      filter: Type.Optional(Type.String({ description: "Run only tests whose names contain this text." })),
      paths: Type.Optional(Type.Array(Type.String(), { description: "Test files or directories. Defaults to the full suite." })),
    }),
    executionMode: "sequential",
    async execute(_id, params, signal, onUpdate, _ctx) {
      const root = repo();
      const bin = join(root, "runtime", "zig-out", "bin", "lus");
      const built = age(bin);
      if (!built) throw new Error("runtime/zig-out/bin/lus is missing. Build it with lus_build first.");
      const modes = (params.modes?.length ? params.modes : [...JIT_MODES]) as string[];
      const targets = params.paths?.length ? params.paths : ["tests/conformance", "packages/language-server/tests"];
      const jobs = String(Math.max(2, Math.floor(cpus().length / 2)));
      const done: ModeResult[] = [];
      const start = Date.now();
      for (const mode of modes) {
        onUpdate?.({ content: [{ type: "text", text: `running ${mode}` }], details: { modes: [...done], pending: modes.slice(done.length), built } });
        const args = ["test", "--jobs", jobs, ...(params.filter ? ["--filter", params.filter] : []), ...targets];
        const res = await stream(bin, args, { cwd: root, env: { ...process.env, LUS_JIT: mode }, signal, timeout: 60 * 60000 });
        done.push({ mode, code: res.code, tally: parseTestSummary(res.output), failures: testFailures(res.output) });
        if (signal?.aborted) break;
      }
      const report = done.map((m) => {
        const t = m.tally;
        return t ? `${m.mode}: ${t.passed} passed, ${t.failed} failed, ${t.fileErrors} file errors` : `${m.mode}: exit ${m.code}, no report`;
      });
      const seen = new Map<string, string[]>();
      for (const m of done) if (m.failures.length) seen.set(m.failures.slice(0, 40).join("\n"), [...(seen.get(m.failures.slice(0, 40).join("\n")) ?? []), m.mode]);
      for (const [failures, modes] of seen) report.push(`Failures under ${modes.join(", ")}:\n${failures}`);
      const ok = done.every((m) => m.code === 0);
      return {
        content: [{ type: "text", text: `${report.join("\n\n")}\n(${built}, ${seconds(Date.now() - start)})` }],
        details: { modes: done, pending: [], built, ms: Date.now() - start },
        isError: !ok,
      };
    },
    renderShell: "self",
    renderCall(args: any, theme: Theme, context: any) {
      const what = [...(args?.paths ?? ["tests/conformance"]), args?.filter ? `--filter ${args.filter}` : ""].filter(Boolean).join(" ");
      return lines(() => [head(theme, rowState(context.state.done ?? context), "Conformance", what)]);
    },
    renderResult(result: any, options, theme: Theme, context: any) {
      const d = result.details ?? {};
      if (!d.modes) return EMPTY;
      if (!options.isPartial) context.state.done = { isError: context.isError, isPartial: false, executionStarted: true, durationMs: d.ms ?? 0 };
      const total = (d.modes as ModeResult[])[0]?.tally;
      const count = total ? theme.fg("dim", ` · ${total.passed + total.failed} tests`) : "";
      const body = [renderModes(theme, d.modes, d.pending ?? []) + count];
      // Modes that fail the same way share one block, labeled with every mode.
      const groups = new Map<string, string[]>();
      for (const m of d.modes as ModeResult[]) {
        if (!m.failures.length) continue;
        const key = m.failures.join("\n");
        groups.set(key, [...(groups.get(key) ?? []), m.mode]);
      }
      const all = (d.modes as ModeResult[]).length;
      const failures = [...groups].flatMap(([key, modes]) => [
        theme.fg("muted", modes.length === all && all > 1 ? "every mode:" : `${modes.join(", ")}:`),
        ...key.split("\n").map((f) => (f.startsWith("FAIL") || f.startsWith("file error") ? theme.fg("error", f) : theme.fg("dim", f))),
      ]);
      body.push(...clip(theme, failures, options.expanded ? 400 : 6));
      if (!options.isPartial && d.built) body.push(theme.fg("dim", `${d.built} · ${seconds(d.ms)}`));
      return lines(() => tree(theme, body));
    },
  });

  // Every zig build in a bash command goes through the build lock with -j2.
  pi.on("tool_call", async (event) => {
    if (!session.repo || event.toolName !== "bash") return;
    const input = event.input as { command?: string };
    const command = String(input.command ?? "");
    const locked = lockZigBuild(command, session.repo);
    if (locked) input.command = locked;
    const mise = /(^|&&|;)\s*mise run ([\w:.-]+)/.exec(input.command ?? "");
    if (mise && miseLockPolicy(miseTasks(session.repo), mise[2]) === "wrap" && !/with-build-lock/.test(input.command ?? "")) {
      input.command = (input.command ?? "").replace(/mise run ([\w:.-]+)/, `sh ${join(session.repo, "tools", "with-build-lock.sh")} mise run $1`);
    }
  });

  const run = (name: string, prompt: string, hint: string) =>
    pi.registerCommand(name, {
      description: hint,
      handler: async (args) => {
        if (!session.repo) return;
        pi.sendUserMessage(prompt.replace("$ARGS", args.trim()).trim());
      },
    });
  run("build", "Build the runtime with lus_build $ARGS and report the result.", "Build the runtime under the build lock");
  run("conformance", "Run lus_conformance $ARGS and summarize every failure by JIT mode.", "Run the conformance suite under every JIT mode");
  run("mise", "Run mise_task $ARGS and report the result. With no task, list the tasks.", "List or run mise tasks");
  run("lint", "Run node tools/lint-repo.js and fix every finding it reports.", "Run the repository prose lint");
}
