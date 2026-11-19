import * as vscode from "vscode";
import {
  identifyWorkspaceFile,
  WorkspaceFileIdentity,
  workspaceDeleteParams,
  workspaceResetParams,
  workspaceUpsertParams,
} from "./workspaceProtocol";

export type WorkspaceMessageSender = (
  method: string,
  params: unknown,
) => Promise<void>;

type PendingFileOperation = "upsert" | "delete";

const SOURCE_GLOB = "**/*.{lus,lua}";
const SOURCE_EXCLUDE = "**/{.git,node_modules,build,dist,out}/**";

export class WorkspaceMirror implements vscode.Disposable {
  private readonly disposables: vscode.Disposable[] = [];
  private readonly pendingFiles = new Map<string, PendingFileOperation>();
  private readonly versions = new Map<string, number>();
  private tail: Promise<void> = Promise.resolve();
  private sender: WorkspaceMessageSender | undefined;
  private pendingReset = false;
  private active = false;

  constructor(private readonly reportError: (error: Error) => void) {
    const watcher = vscode.workspace.createFileSystemWatcher(SOURCE_GLOB);
    this.disposables.push(
      watcher,
      watcher.onDidCreate((uri) => this.onFileEvent(uri, "upsert")),
      watcher.onDidChange((uri) => this.onFileEvent(uri, "upsert")),
      watcher.onDidDelete((uri) => this.onFileEvent(uri, "delete")),
      vscode.workspace.onDidChangeWorkspaceFolders(() => {
        if (!this.active) {
          this.pendingReset = true;
          this.pendingFiles.clear();
          return;
        }
        this.run(this.enqueue(() => this.resetAndSnapshot(this.requireSender())));
      }),
    );
  }

  async seed(sender: WorkspaceMessageSender): Promise<void> {
    await this.enqueue(() => this.resetAndSnapshot(sender));
  }

  async activate(sender: WorkspaceMessageSender): Promise<void> {
    this.sender = sender;
    this.active = true;
    await this.enqueue(async () => {
      if (this.pendingReset) {
        this.pendingReset = false;
        this.pendingFiles.clear();
        await this.resetAndSnapshot(sender);
        return;
      }

      const pending = [...this.pendingFiles.entries()].sort(([left], [right]) =>
        left.localeCompare(right),
      );
      this.pendingFiles.clear();
      for (const [rawUri, operation] of pending) {
        await this.performFileOperation(
          vscode.Uri.parse(rawUri),
          operation,
          sender,
        );
      }
    });
  }

  dispose(): void {
    this.active = false;
    this.sender = undefined;
    for (const disposable of this.disposables.splice(0)) {
      disposable.dispose();
    }
  }

  async shutdown(): Promise<void> {
    this.dispose();
    await this.tail;
  }

  private onFileEvent(uri: vscode.Uri, operation: PendingFileOperation): void {
    if (!this.active) {
      this.pendingFiles.set(uri.toString(), operation);
      return;
    }
    this.run(this.sendFileOperation(uri, operation, this.requireSender()));
  }

  private run(operation: Promise<void>): void {
    void operation.catch((cause) => {
      this.reportError(
        cause instanceof Error ? cause : new Error("Workspace mirror update failed"),
      );
    });
  }

  private enqueue(operation: () => Promise<void>): Promise<void> {
    const result = this.tail.then(operation);
    this.tail = result.catch(() => undefined);
    return result;
  }

  private sendFileOperation(
    uri: vscode.Uri,
    operation: PendingFileOperation,
    sender: WorkspaceMessageSender,
  ): Promise<void> {
    return this.enqueue(() => this.performFileOperation(uri, operation, sender));
  }

  private async performFileOperation(
    uri: vscode.Uri,
    operation: PendingFileOperation,
    sender: WorkspaceMessageSender,
  ): Promise<void> {
    const identity = this.identify(uri);
    if (!identity) {
      return;
    }

    const version = this.nextVersion(identity.uri);
    if (operation === "delete") {
      await sender(
        "lus/workspace/delete",
        workspaceDeleteParams(identity, version),
      );
      return;
    }

    let data: Uint8Array;
    try {
      data = await vscode.workspace.fs.readFile(uri);
    } catch (cause) {
      if (
        cause instanceof vscode.FileSystemError &&
        cause.code === "FileNotFound"
      ) {
        await sender(
          "lus/workspace/delete",
          workspaceDeleteParams(identity, version),
        );
        return;
      }
      throw cause;
    }

    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(data);
    } catch {
      throw new Error("A workspace source file is not valid UTF-8");
    }
    await sender(
      "lus/workspace/upsert",
      workspaceUpsertParams(identity, version, text),
    );
  }

  private async resetAndSnapshot(sender: WorkspaceMessageSender): Promise<void> {
    this.versions.clear();
    const roots = (vscode.workspace.workspaceFolders ?? []).map((folder) =>
      folder.uri.toString(),
    );
    await sender("lus/workspace/reset", workspaceResetParams(roots));

    const uris = await vscode.workspace.findFiles(SOURCE_GLOB, SOURCE_EXCLUDE);
    uris.sort((left, right) => left.toString().localeCompare(right.toString()));
    for (const uri of uris) {
      await this.sendSnapshotFile(uri, sender);
    }
  }

  private async sendSnapshotFile(
    uri: vscode.Uri,
    sender: WorkspaceMessageSender,
  ): Promise<void> {
    const identity = this.identify(uri);
    if (!identity) {
      return;
    }

    let data: Uint8Array;
    try {
      data = await vscode.workspace.fs.readFile(uri);
    } catch (cause) {
      if (cause instanceof vscode.FileSystemError && cause.code === "FileNotFound") {
        return;
      }
      throw cause;
    }

    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(data);
    } catch {
      throw new Error("A workspace source file is not valid UTF-8");
    }
    const version = this.nextVersion(identity.uri);
    await sender(
      "lus/workspace/upsert",
      workspaceUpsertParams(identity, version, text),
    );
  }

  private identify(uri: vscode.Uri): WorkspaceFileIdentity | undefined {
    const folder = vscode.workspace.getWorkspaceFolder(uri);
    if (!folder) {
      return undefined;
    }
    return identifyWorkspaceFile(
      folder.uri.toString(),
      folder.uri.path,
      uri.toString(),
      uri.path,
    );
  }

  private nextVersion(uri: string): number {
    const version = (this.versions.get(uri) ?? 0) + 1;
    this.versions.set(uri, version);
    return version;
  }

  private requireSender(): WorkspaceMessageSender {
    if (!this.sender) {
      throw new Error("The workspace mirror is not active");
    }
    return this.sender;
  }
}
