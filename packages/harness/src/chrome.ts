// The frame around the conversation: a one-line header and a one-line
// footer. The footer carries the Lus state on the left and the model state on
// the right.
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { shortPath } from "./render.ts";
import type { Session } from "./session.ts";

function tokens(n: number): string {
  if (n < 1000) return `${n}`;
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)}k`;
  return `${(n / 1_000_000).toFixed(1)}m`;
}

function lusState(theme: Theme, session: Session): string[] {
  const parts: string[] = [];
  const lus = session.lus;
  if (!lus) parts.push(theme.fg("error", "no lus found"));
  else if (!lus.supported) parts.push(theme.fg("warning", `lus ${lus.version} is too old`));
  else parts.push(`lus ${lus.version}`);
  if (session.lspStatus === "ready") parts.push("lsp ready");
  else if (session.lspStatus === "starting") parts.push("lsp starting");
  else if (session.lspStatus === "failed") parts.push(theme.fg("warning", "lsp failed"));
  const grants = session.grants.count();
  if (grants) parts.push(`${grants} grant${grants === 1 ? "" : "s"}`);
  if (session.repo) {
    parts.push(theme.fg("accent", "repo"));
    if (session.lockHolder) parts.push(theme.fg("warning", `lock held by ${session.lockHolder}`));
  }
  return parts;
}

export function registerChrome(pi: ExtensionAPI, session: Session) {
  pi.on("session_start", async (_event, ctx: ExtensionContext) => {
    if (!ctx.hasUI) return;

    ctx.ui.setHeader((_tui, theme) => ({
      render(width: number) {
        const where = shortPath(ctx.cwd, "\0");
        const parts = [theme.fg("dim", where)];
        if (session.lus?.supported) parts.push(theme.fg("dim", `lus ${session.lus.version}`));
        if (session.repo) parts.push(theme.fg("accent", "repo"));
        const line = `${theme.fg("accent", theme.bold("lus"))} ${parts.join(theme.fg("dim", " · "))}`;
        return [truncateToWidth(line, width), ""];
      },
      invalidate() {},
    }));

    ctx.ui.setWorkingIndicator({
      frames: ["·", "•", "●", "•"].map((f) => ctx.ui.theme.fg("accent", f)),
      intervalMs: 140,
    });

    ctx.ui.setFooter((tui, theme, footerData) => {
      const unsubscribe = [session.onChange(() => tui.requestRender()), footerData.onBranchChange(() => tui.requestRender())];
      return {
        dispose() {
          for (const u of unsubscribe) u();
        },
        invalidate() {},
        render(width: number): string[] {
          const sep = theme.fg("dim", " · ");
          const left = lusState(theme, session);
          const branch = footerData.getGitBranch();
          if (branch) left.push(branch);
          for (const status of footerData.getExtensionStatuses().values()) if (status) left.push(status);

          let input = 0;
          let output = 0;
          let cost = 0;
          for (const entry of ctx.sessionManager.getBranch()) {
            if (entry.type === "message" && entry.message.role === "assistant") {
              const usage = (entry.message as AssistantMessage).usage;
              input += usage?.input ?? 0;
              output += usage?.output ?? 0;
              cost += usage?.cost?.total ?? 0;
            }
          }
          const right: string[] = [];
          if (ctx.model) {
            const level = pi.getThinkingLevel();
            right.push(level && level !== "off" ? `${ctx.model.id} ${level}` : ctx.model.id);
          }
          const usage = ctx.getContextUsage();
          if (usage?.percent != null) {
            const pct = Math.round(usage.percent);
            right.push(pct >= 80 ? theme.fg("warning", `ctx ${pct}%`) : `ctx ${pct}%`);
          }
          if (input || output) right.push(`↑${tokens(input)} ↓${tokens(output)}`);
          if (cost) right.push(`$${cost.toFixed(2)}`);

          const l = theme.fg("dim", left.join(sep));
          const r = theme.fg("dim", right.join(sep));
          const gap = width - visibleWidth(l) - visibleWidth(r);
          if (gap >= 2) return [l + " ".repeat(gap) + r];
          return [truncateToWidth(l, width), truncateToWidth(r, width)];
        },
      };
    });
  });
}
