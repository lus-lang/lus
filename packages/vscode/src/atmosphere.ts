// Completion of atmosphere URLs inside the string of a `require`
// (spec/design/modules.md, section 7). The language server runs as
// WebAssembly and cannot start processes, so the extension asks the
// `atmos` command itself. It queries https://atmosp.here and every server
// of the setting `lus.atmosphere.servers`. Without `atmos` on PATH it
// completes nothing.

import { execFile } from "node:child_process";
import * as vscode from "vscode";

const DEFAULT_SERVER = "https://atmosp.here";

interface Package {
  url: string;
  name?: string;
  version?: string;
  description?: string;
}

/** The servers to query: the official one and the configured ones. */
export function configuredServers(setting: unknown): string[] {
  const servers = [DEFAULT_SERVER];
  if (Array.isArray(setting)) {
    for (const s of setting) {
      if (typeof s === "string" && /^https?:\/\/[\w.:-]+/.test(s)) {
        const trimmed = s.replace(/\/+$/, "");
        if (!servers.includes(trimmed)) servers.push(trimmed);
      }
    }
  }
  return servers;
}

/** The text of the require string before the cursor, or undefined. */
export function requireString(before: string): string | undefined {
  const m = before.match(/require\s*\(?\s*["']([^"']*)$/);
  return m ? m[1] : undefined;
}

/** The search query for `typed` on `server`, or undefined when the typed
 * text does not lead to that server. */
export function queryFor(server: string, typed: string): string | undefined {
  if (server.startsWith(typed)) return "";
  if (!typed.startsWith(server)) return undefined;
  const rest = typed.slice(server.length + 1);
  const slash = rest.indexOf("/");
  return slash < 0 ? "" : rest.slice(slash + 1);
}

function search(server: string, query: string): Promise<Package[]> {
  return new Promise((resolve) => {
    execFile(
      "atmos",
      ["search", "--json", "--server", server, query],
      { timeout: 5000 },
      (err, stdout) => {
        if (err) return resolve([]);
        try {
          const list = JSON.parse(stdout);
          resolve(Array.isArray(list) ? list.filter((p) => p && typeof p.url === "string") : []);
        } catch {
          resolve([]);
        }
      },
    );
  });
}

export function registerAtmosphereCompletion(context: vscode.ExtensionContext): void {
  const cache = new Map<string, Promise<Package[]>>();
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("lus.atmosphere.servers")) cache.clear();
    }),
    vscode.languages.registerCompletionItemProvider(
      { language: "lus" },
      {
        async provideCompletionItems(document, position) {
          const before = document.lineAt(position.line).text.slice(0, position.character);
          const typed = requireString(before);
          if (typed === undefined || /[^\w./:@-]/.test(typed)) return undefined;
          const servers = configuredServers(vscode.workspace.getConfiguration("lus").get("atmosphere.servers"));
          const range = new vscode.Range(position.line, position.character - typed.length, position.line, position.character);
          const items: vscode.CompletionItem[] = [];
          for (const server of servers) {
            const query = queryFor(server, typed);
            if (query === undefined) continue;
            const key = `${server}\0${query}`;
            if (!cache.has(key)) cache.set(key, search(server, query));
            for (const pkg of await cache.get(key)!) {
              if (!pkg.url.startsWith(typed)) continue;
              const item = new vscode.CompletionItem(pkg.url, vscode.CompletionItemKind.Module);
              item.detail = [pkg.name, pkg.version].filter(Boolean).join(" ");
              if (pkg.description) item.documentation = pkg.description;
              item.range = range;
              item.filterText = pkg.url;
              items.push(item);
            }
          }
          return items;
        },
      },
      "/",
      '"',
    ),
  );
}
