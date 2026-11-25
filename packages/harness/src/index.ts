// The Lus harness for Pi. It adds the Lus language server, the lus command
// line as tools, permission-aware runs of Lus scripts, the Lus skills as
// context, and, inside the Lus repository, the tools for working on Lus.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerBuiltinRenderers } from "./builtins.ts";
import { registerChrome } from "./chrome.ts";
import { findLusRepo } from "./env.ts";
import { registerLusTools } from "./lustools.ts";
import { registerPermissions } from "./permissions.ts";
import { registerRepo } from "./repo.ts";
import { registerContext, registerEditHooks, Session } from "./session.ts";

export default function lusHarness(pi: ExtensionAPI) {
  const session = new Session();

  registerBuiltinRenderers(pi);
  registerLusTools(pi, session);
  registerPermissions(pi, session);
  registerEditHooks(pi, session);
  registerContext(pi, session);
  registerChrome(pi, session);
  if (findLusRepo(process.cwd())) registerRepo(pi, session);

  pi.on("session_start", async (_event, ctx) => {
    session.init(ctx.cwd);
  });

  pi.on("session_shutdown", async () => {
    await session.shutdown();
  });

  pi.registerCommand("grants", {
    description: "List or clear the permissions approved for Lus scripts in this session",
    handler: async (args, ctx) => {
      if (args.trim() === "clear") {
        session.grants.clear();
        session.changed();
        ctx.ui.notify("Cleared every approved grant.", "info");
        return;
      }
      const n = session.grants.count();
      ctx.ui.notify(n ? `${n} grant${n === 1 ? "" : "s"} approved. Run /grants clear to drop them.` : "No grants approved yet.", "info");
    },
  });
}
