// Permission-aware runs of Lus scripts. Every run passes explicit `-P`
// grants, which cap what the script may pledge. Reading the project and
// loading code are granted without asking. Everything else is approved by the
// person, once or for the rest of the session.
import { relative, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readText } from "./env.ts";
import { baseGrants, grantFor, isBase, lusInvocation, parseDenial, scanPledges } from "./policy.ts";
import { clip, EMPTY, head, lines, rowState, seconds, tree } from "./render.ts";
import type { Session } from "./session.ts";

export class Grants {
  /** Grants approved for the rest of the session, keyed by script path. */
  private approved = new Map<string, Set<string>>();

  forScript(script: string): string[] {
    return [...(this.approved.get(script) ?? [])];
  }

  add(script: string, grants: string[]) {
    const set = this.approved.get(script) ?? new Set<string>();
    for (const g of grants) set.add(g);
    this.approved.set(script, set);
  }

  count(): number {
    let n = 0;
    for (const set of this.approved.values()) n += set.size;
    return n;
  }

  clear() {
    this.approved.clear();
  }
}

type Answer = "once" | "session" | "deny";

/** Asks the person about grants. Without a UI, every request is denied. */
async function ask(ctx: ExtensionContext, script: string, wanted: string[], reason: string): Promise<Answer> {
  if (!ctx.hasUI) return "deny";
  const choice = await ctx.ui.select(`${script} ${reason}\n  ${wanted.join("\n  ")}`, [
    "Allow once",
    "Allow for this session",
    "Deny",
  ]);
  if (choice === "Allow once") return "once";
  if (choice === "Allow for this session") return "session";
  return "deny";
}

function flags(grants: string[]): string[] {
  return grants.map((g) => `-P${g}`);
}

export function registerPermissions(pi: ExtensionAPI, session: Session) {
  pi.registerTool({
    name: "lus_run",
    label: "Run",
    description:
      "Run a Lus script under explicit permission grants. Reading the project directory and loading modules are always granted. " +
      "List any other permission the script needs in permissions (for example network:http=api.example.com or fs:write=./out/*). " +
      "The person approves those, and a run that is denied a permission asks the person and runs again.",
    promptSnippet: "Run a Lus script with permissions the person approves",
    promptGuidelines: [
      "Run Lus scripts with lus_run, not with bash, so their permissions are approved by the person.",
      "In lus_run, request the narrowest permission values that work, such as fs:write=./out/* rather than fs.",
    ],
    parameters: Type.Object({
      path: Type.String({ description: "The script to run." }),
      args: Type.Optional(Type.Array(Type.String(), { description: "Arguments passed to the script." })),
      permissions: Type.Optional(Type.Array(Type.String(), { description: "Permissions beyond reading the project, in -P syntax." })),
      timeout: Type.Optional(Type.Number({ description: "Seconds before the run is stopped. Default 120." })),
    }),
    executionMode: "sequential",
    async execute(_id, params, signal, onUpdate, ctx) {
      const bin = session.lus;
      if (!bin?.supported) throw new Error("lus_run needs a Lus 2 binary. Install it from https://lus.dev or set LUS_BIN.");
      const root = ctx.cwd;
      const script = resolve(root, params.path.replace(/^@/, ""));
      const name = relative(root, script) || params.path;
      const source = readText(script);
      if (source === undefined) throw new Error(`cannot read ${name}`);

      const once = new Set<string>();
      const wanted = [...new Set([...(params.permissions ?? []), ...scanPledges(source)])]
        .map((g) => (g.startsWith("fs") && /=\./.test(g) ? g.replace(/=\.(\/|$)/, `=${root}$1`) : g))
        .filter((g) => !isBase(g, root) && !session.grants.forScript(script).includes(g));
      if (wanted.length) {
        const answer = await ask(ctx, name, wanted, "asks for");
        if (answer === "deny") {
          return {
            content: [{ type: "text", text: `The person denied ${wanted.join(", ")}. The script did not run.` }],
            details: { code: null, grants: [], denied: wanted, output: "" },
          };
        }
        if (answer === "session") session.grants.add(script, wanted);
        else for (const g of wanted) once.add(g);
      }

      let output = "";
      let code: number | null = null;
      let ms = 0;
      const asked = new Set<string>();
      for (let attempt = 0; attempt < 6; attempt++) {
        const grants = [...new Set([...baseGrants(root), ...session.grants.forScript(script), ...once])];
        onUpdate?.({ content: [{ type: "text", text: "running" }], details: { code: null, grants, denied: [], output: "" } });
        const started = Date.now();
        const res = await pi.exec(bin.path, [...flags(grants), script, ...(params.args ?? [])], {
          cwd: root,
          signal,
          timeout: (params.timeout ?? 120) * 1000,
        });
        output = [res.stdout, res.stderr].filter(Boolean).join(res.stdout && !res.stdout.endsWith("\n") ? "\n" : "");
        code = res.killed ? null : res.code;
        ms = Date.now() - started;
        session.refresh();
        const denial = res.code !== 0 ? parseDenial(res.stderr) : undefined;
        if (!denial) {
          return {
            content: [{ type: "text", text: `${output}\n[exit ${code ?? "killed"} · grants ${grants.join(" ")}]` }],
            details: { code, grants, denied: [], output, ms },
          };
        }
        const grant = grantFor(denial, root);
        if (asked.has(grant)) break;
        asked.add(grant);
        const answer = await ask(ctx, name, [grant], "stopped without");
        if (answer === "deny") {
          return {
            content: [{ type: "text", text: `${output}\nThe person denied ${grant}. Do not retry it without asking them.` }],
            details: { code, grants, denied: [grant], output },
          };
        }
        if (answer === "session") session.grants.add(script, [grant]);
        else once.add(grant);
      }
      return { content: [{ type: "text", text: output }], details: { code, grants: [], denied: [], output } };
    },
    renderShell: "self",
    renderCall(args: any, theme: Theme, context: any) {
      return lines(() => [head(theme, rowState(context.state.done ?? context), "Run", [args?.path ?? "", ...(args?.args ?? [])].join(" "))]);
    },
    renderResult(result: any, options, theme: Theme, context: any) {
      context.state.done = { isError: context.isError || (result.details?.code ?? 0) !== 0, isPartial: false, executionStarted: true, durationMs: context.durationMs ?? 0 };
      if (options.isPartial) return EMPTY;
      const d = result.details ?? {};
      if (context.isError) return lines(() => tree(theme, [theme.fg("error", result.content?.[0]?.text ?? "failed")]));
      const extra = (d.grants ?? []).filter((g: string) => !isBase(g, context.cwd));
      const status: string[] = [];
      if (d.denied?.length) status.push(theme.fg("error", `denied ${d.denied.join(" ")}`));
      else status.push(d.code === 0 ? theme.fg("accent", "exit 0") : theme.fg("error", `exit ${d.code ?? "killed"}`));
      if (extra.length) status.push(theme.fg("muted", extra.join(" ")));
      // The time the script ran, without the time the person spent approving it.
      if (d.ms !== undefined) status.push(theme.fg("dim", seconds(d.ms)));
      const out: string[] = (d.output ?? "").replace(/\s+$/, "").split("\n").filter((l: string, i: number, all: string[]) => l || all.length > 1);
      const body = [status.join(theme.fg("dim", " · ")), ...clip(theme, out.map((l) => theme.fg("toolOutput", l)), options.expanded ? 300 : 6)];
      return lines(() => tree(theme, body));
    },
  });

  // `lus script.lus` typed into bash bypasses the approvals, so it goes
  // through the same policy.
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return;
    const command = String((event.input as { command?: string }).command ?? "");
    const run = lusInvocation(command);
    if (!run) return;
    if (!run.grants.length) {
      return {
        block: true,
        reason:
          "A lus script started from bash without -P grants may pledge any permission. Run it with the lus_run tool, which asks the person for the permissions it needs.",
      };
    }
    const script = run.script ? resolve(ctx.cwd, run.script) : "-e";
    const wanted = run.grants.filter((g) => !g.startsWith("~") && !isBase(g, ctx.cwd) && !session.grants.forScript(script).includes(g));
    if (!wanted.length) return;
    const answer = await ask(ctx, run.script ?? "lus -e", wanted, "asks for");
    if (answer === "deny") return { block: true, reason: `The person denied ${wanted.join(", ")}.` };
    if (answer === "session") session.grants.add(script, wanted);
  });
}
