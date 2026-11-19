import * as path from "node:path";

export interface WorkspaceFileIdentity {
  rootUri: string;
  relativePath: string;
  uri: string;
}

export function identifyWorkspaceFile(
  rootUri: string,
  rootPath: string,
  sourceUri: string,
  sourcePath: string,
): WorkspaceFileIdentity | undefined {
  const relativePath = path.posix.relative(rootPath, sourcePath);
  if (
    relativePath.length === 0 ||
    relativePath === ".." ||
    relativePath.startsWith("../") ||
    path.posix.isAbsolute(relativePath)
  ) {
    return undefined;
  }
  return { rootUri, relativePath, uri: sourceUri };
}

export function workspaceResetParams(roots: string[]): { roots: string[] } {
  return { roots: [...roots] };
}

export function workspaceUpsertParams(
  identity: WorkspaceFileIdentity,
  version: number,
  text: string,
): WorkspaceFileIdentity & { version: number; text: string } {
  return { ...identity, version, text };
}

export function workspaceDeleteParams(
  identity: WorkspaceFileIdentity,
  version: number,
): WorkspaceFileIdentity & { version: number } {
  return { ...identity, version };
}
