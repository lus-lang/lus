// What the harness knows about the current session: the `lus` binary, the
// language server, approved grants, and whether the working directory is the
// Lus repository.
import { existsSync } from "node:fs";
import { extname, join, relative } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { fromCheck, fromLsp, forModel, type LusFileReport } from "./diagnostics.ts";
import { AGENTS_DIR, debug, findLus, findLusRepo, findUp, type LusBinary, readText } from "./env.ts";
import { LusLsp, type LspStatus } from "./lsp.ts";
import { Grants } from "./permissions.ts";
import { lintProse } from "./repo.ts";
import { resolvePath } from "./lustools.ts";

export class Session {
  lus?: LusBinary;
  repo?: string;
  grants = new Grants();
  lsp?: LusLsp;
  lspStatus: LspStatus = "off";
  /** Text of the build lock owner while a build waits, for the footer. */
  lockHolder?: string;
  private cwd = process.cwd();
  private listeners = new Set<() => void>();

  init(cwd: string) {
    debug(`init ${cwd}`);
    this.cwd = cwd;
    this.lus = findLus(cwd);
    this.repo = findLusRepo(cwd);
    this.changed();
  }

  /** Looks for a rebuilt runtime after a build or a run. */
  refresh() {
    if (this.repo || !this.lus?.supported) this.lus = findLus(this.cwd);
    this.changed();
  }

  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  changed() {
    for (const l of this.listeners) l();
  }

  lspFor(ctx: ExtensionContext): LusLsp | undefined {
    if (!this.lus?.supported || !LusLsp.available()) return undefined;
    this.lsp ??= new LusLsp(this.lus.path, ctx.cwd, (status) => {
      this.lspStatus = status;
      this.changed();
    });
    return this.lsp;
  }

  async shutdown() {
    await this.lsp?.stop();
    this.lsp = undefined;
  }

  /**
   * Diagnostics of one file. `lus check` is the authority, because it is the
   * compiler the person runs in CI and it reports syntax errors at their
   * exact column with a hint. The language server adds what it finds on
   * lines that check left alone.
   */
  async diagnose(pi: ExtensionAPI, ctx: ExtensionContext, path: string): Promise<LusFileReport | undefined> {
    if (!this.lus?.supported) return undefined;
    const shown = relative(ctx.cwd, path) || path;
    const lsp = this.lspFor(ctx);
    const [checked, served] = await Promise.all([
      pi.exec(this.lus.path, ["check", "--json", path], { cwd: ctx.cwd, timeout: 30000 }).then(
        (res) => {
          try {
            return fromCheck(JSON.parse(res.stdout || "[]"));
          } catch {
            return undefined;
          }
        },
        () => undefined,
      ),
      lsp ? lsp.diagnose(path).catch(() => undefined) : Promise.resolve(undefined),
    ]);
    if (!checked && !served) return undefined;
    const base = checked ?? [];
    const lines = new Set(base.map((d) => d.line));
    const syntax = base.some((d) => d.code === "syntax");
    const extra = served && !syntax ? fromLsp(served).filter((d) => !lines.has(d.line)) : [];
    return { source: served ? "lsp" : "check", path: shown, diagnostics: [...base, ...extra] };
  }
}

const PROSE = new Set([".md", ".mdx", ".txt"]);

/**
 * After every edit or write of a Lus file, its diagnostics join the tool
 * result. In the Lus repository, an edited text file also gets the prose lint.
 */
export function registerEditHooks(pi: ExtensionAPI, session: Session) {
  pi.on("tool_result", async (event, ctx) => {
    debug(`tool_result ${event.toolName}`);
    if (event.toolName !== "edit" && event.toolName !== "write") return;
    if (event.isError) return;
    const input = event.input as { path?: string };
    if (!input.path) return;
    const path = resolvePath(ctx.cwd, input.path);
    const extra: string[] = [];
    const details: Record<string, unknown> = { ...(event.details as object) };
    if (extname(path) === ".lus") {
      debug(`diagnose ${path}`);
      const report = await session.diagnose(pi, ctx, path);
      debug(`report ${JSON.stringify(report)}`);
      if (report) {
        details.lus = report;
        extra.push(forModel(report));
      }
    }
    if (session.repo) {
      const problems = lintProse(session.repo, path, PROSE.has(extname(path)));
      if (problems) {
        details.prose = problems;
        if (problems.length) extra.push(`Prose lint for ${relative(session.repo, path)} (fix these):\n${problems.join("\n")}`);
      }
    }
    if (!extra.length && !details.lus && !details.prose) return;
    return {
      content: [...event.content, ...extra.map((text) => ({ type: "text" as const, text: `\n${text}` }))],
      details,
    };
  });
}

/** True when the project carries its own copy of the Lus skills. */
function projectHasSkills(cwd: string): boolean {
  return !!findUp(cwd, (dir) => existsSync(join(dir, ".agents", "skills", "lus", "SKILL.md")));
}

const GUIDANCE = `This session runs in the Lus harness. Lus is a Lua 5.5 derived language with permissions (pledge), JSON, CSV, SQLite, HTTP, workers, and a test runner built into the lus command.
- Load the lus skill before writing Lus code. Load lus-writing before writing prose for a Lus project.
- Edits and writes of .lus files return their language server diagnostics. Fix every error and warning they report before you continue.
- Use lus_check, lus_fmt, lus_test, and lus_doc rather than calling lus through bash. Use lus_lsp to find definitions and references.
- Run Lus scripts with lus_run. It runs them under explicit permission grants that the person approves.
- The index below lists the Lus documentation. Fetch a page when a question goes beyond the skills.`;

const REPO_GUIDANCE = `Repository mode is on: the working directory is the Lus monorepo.
- Build the runtime with lus_build. Every Zig build holds the machine-wide build lock (tools/with-build-lock.sh) and uses -j2. Bash commands that start zig build are routed through the lock.
- Run mise tasks with mise_task. Run the conformance suite with lus_conformance, which covers every JIT mode.
- Edits return the findings of the prose lint. Prose follows spec/design/style.md, which the lus-writing skill carries.
- runtime/HACKING.md, below, explains how the runtime is put together.`;

export function registerContext(pi: ExtensionAPI, session: Session) {
  pi.on("resources_discover", async (event) => {
    if (projectHasSkills(event.cwd)) return;
    const skills = join(AGENTS_DIR, "skills");
    if (!existsSync(skills)) return;
    return { skillPaths: [skills] };
  });

  pi.on("before_agent_start", async (event) => {
    const sections = event.systemPromptOptions.sections;
    const llms = readText(join(AGENTS_DIR, "llms.txt"));
    sections["lus"] = llms ? `${GUIDANCE}\n\n${llms.trim()}` : GUIDANCE;
    if (session.repo) {
      const hacking = readText(join(session.repo, "runtime", "HACKING.md"));
      sections["lus-repository"] = hacking ? `${REPO_GUIDANCE}\n\n${hacking.trim()}` : REPO_GUIDANCE;
    }
  });
}
