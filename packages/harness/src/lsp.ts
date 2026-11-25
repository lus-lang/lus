// A small Language Server Protocol client for the Lus language server. The
// server is a Lus program, started with the local `lus` on the first request.
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readlinkSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { debug, LANGUAGE_SERVER_DIR } from "./env.ts";

export type LspStatus = "off" | "starting" | "ready" | "failed";

interface Pending {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

/**
 * The server loads its modules with `require("lus-language.…")`, so it must
 * run from a directory of that name. A link in the temporary directory gives
 * the checkout or the installed copy that name without moving it.
 */
function serverDir(): string {
  const base = join(tmpdir(), `lus-harness-${process.getuid?.() ?? "user"}`);
  const link = join(base, "lus-language");
  mkdirSync(base, { recursive: true });
  let current: string | undefined;
  try {
    current = readlinkSync(link);
  } catch {}
  if (current !== LANGUAGE_SERVER_DIR) {
    if (current !== undefined) rmSync(link, { force: true });
    symlinkSync(LANGUAGE_SERVER_DIR, link, "dir");
  }
  return link;
}

export class LusLsp {
  status: LspStatus = "off";
  error?: string;
  private proc?: ChildProcessWithoutNullStreams;
  private buffer = Buffer.alloc(0);
  private nextId = 0;
  private pending = new Map<number, Pending>();
  private versions = new Map<string, number>();
  private diagnostics = new Map<string, { version?: number; items: any[] }>();
  private waiters = new Map<string, ((items: any[]) => void)[]>();
  private starting?: Promise<boolean>;

  private lus: string;
  private root: string;
  private onStatus: (status: LspStatus) => void;

  constructor(lus: string, root: string, onStatus: (status: LspStatus) => void = () => {}) {
    this.lus = lus;
    this.root = root;
    this.onStatus = onStatus;
  }

  static available(): boolean {
    return existsSync(join(LANGUAGE_SERVER_DIR, "main.lus"));
  }

  private setStatus(status: LspStatus, error?: string) {
    debug(`lsp ${status}${error ? ` ${error}` : ""}`);
    this.status = status;
    this.error = error;
    this.onStatus(status);
  }

  /** Starts the server once. Resolves to false when it cannot run. */
  start(): Promise<boolean> {
    if (this.status === "ready") return Promise.resolve(true);
    if (this.status === "failed") return Promise.resolve(false);
    this.starting ??= this.launch();
    return this.starting;
  }

  private async launch(): Promise<boolean> {
    this.setStatus("starting");
    try {
      const dir = serverDir();
      const proc = spawn(this.lus, ["--include", dir, join(dir, "main.lus")], { cwd: this.root, stdio: ["pipe", "pipe", "pipe"] });
      this.proc = proc;
      // The server must never keep Pi running after its session ends.
      proc.unref();
      for (const stream of [proc.stdin, proc.stdout, proc.stderr]) (stream as unknown as { unref?: () => void }).unref?.();
      proc.stdout.on("data", (chunk: Buffer) => this.receive(chunk));
      proc.stderr.on("data", () => {});
      proc.on("exit", (code) => {
        this.proc = undefined;
        for (const p of this.pending.values()) {
          clearTimeout(p.timer);
          p.reject(new Error("language server exited"));
        }
        this.pending.clear();
        if (this.status !== "off") this.setStatus("failed", `exited with status ${code}`);
      });
      proc.on("error", (error) => this.setStatus("failed", error.message));
      await this.request("initialize", {
        processId: process.pid,
        rootUri: pathToFileURL(this.root).href,
        capabilities: { textDocument: { publishDiagnostics: {} } },
      }, 15000);
      this.notify("initialized", {});
      this.setStatus("ready");
      return true;
    } catch (error) {
      this.setStatus("failed", (error as Error).message);
      this.proc?.kill();
      return false;
    }
  }

  private receive(chunk: Buffer) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const split = this.buffer.indexOf("\r\n\r\n");
      if (split < 0) return;
      const header = this.buffer.subarray(0, split).toString();
      const match = /Content-Length:\s*(\d+)/i.exec(header);
      if (!match) {
        this.buffer = this.buffer.subarray(split + 4);
        continue;
      }
      const length = Number(match[1]);
      if (this.buffer.length < split + 4 + length) return;
      const body = this.buffer.subarray(split + 4, split + 4 + length).toString();
      this.buffer = this.buffer.subarray(split + 4 + length);
      try {
        this.dispatch(JSON.parse(body));
      } catch {}
    }
  }

  private dispatch(message: any) {
    if (message.id !== undefined && this.pending.has(message.id)) {
      const p = this.pending.get(message.id)!;
      this.pending.delete(message.id);
      clearTimeout(p.timer);
      if (message.error) p.reject(new Error(message.error.message ?? "request failed"));
      else p.resolve(message.result);
      return;
    }
    if (message.method === "textDocument/publishDiagnostics") {
      const { uri, diagnostics, version } = message.params ?? {};
      this.diagnostics.set(uri, { version, items: diagnostics ?? [] });
      const waiting = this.waiters.get(uri);
      if (waiting) {
        this.waiters.delete(uri);
        for (const done of waiting) done(diagnostics ?? []);
      }
    }
  }

  private write(message: object) {
    const body = JSON.stringify({ jsonrpc: "2.0", ...message });
    this.proc?.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
  }

  private notify(method: string, params: unknown) {
    this.write({ method, params });
  }

  request(method: string, params: unknown, timeout = 10000): Promise<any> {
    if (!this.proc) return Promise.reject(new Error("language server is not running"));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.write({ id, method, params });
    });
  }

  /** Sends the current text of a file and waits for its diagnostics. */
  async diagnose(path: string, timeout = 5000): Promise<any[] | undefined> {
    if (!(await this.start())) return undefined;
    const uri = pathToFileURL(path).href;
    const text = readFileSync(path, "utf8");
    const wait = new Promise<any[] | undefined>((resolve) => {
      const timer = setTimeout(() => resolve(undefined), timeout);
      const list = this.waiters.get(uri) ?? [];
      list.push((items) => {
        clearTimeout(timer);
        resolve(items);
      });
      this.waiters.set(uri, list);
    });
    this.sync(uri, text);
    return wait;
  }

  /** Opens a file or replaces its whole text. */
  sync(uri: string, text: string) {
    const version = (this.versions.get(uri) ?? 0) + 1;
    this.versions.set(uri, version);
    if (version === 1) {
      this.notify("textDocument/didOpen", { textDocument: { uri, languageId: "lus", version, text } });
    } else {
      this.notify("textDocument/didChange", { textDocument: { uri, version }, contentChanges: [{ text }] });
    }
  }

  /** Opens a file if needed, then sends a request about a position in it. */
  async at(method: string, path: string, line: number, column: number, extra: object = {}): Promise<any> {
    if (!(await this.start())) throw new Error(this.error ?? "language server unavailable");
    const uri = pathToFileURL(path).href;
    this.sync(uri, readFileSync(path, "utf8"));
    return this.request(method, { textDocument: { uri }, position: { line: line - 1, character: column - 1 }, ...extra });
  }

  async symbols(path: string): Promise<any[]> {
    if (!(await this.start())) throw new Error(this.error ?? "language server unavailable");
    const uri = pathToFileURL(path).href;
    this.sync(uri, readFileSync(path, "utf8"));
    return (await this.request("textDocument/documentSymbol", { textDocument: { uri } })) ?? [];
  }

  async stop() {
    if (!this.proc) {
      this.setStatus("off");
      return;
    }
    const proc = this.proc;
    this.status = "off";
    try {
      await this.request("shutdown", null, 2000);
      this.notify("exit", null);
    } catch {}
    setTimeout(() => proc.kill(), 500).unref();
    this.proc = undefined;
    this.starting = undefined;
    this.versions.clear();
    this.onStatus("off");
  }
}
