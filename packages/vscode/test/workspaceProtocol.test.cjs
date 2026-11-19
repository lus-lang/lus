const assert = require("node:assert/strict");
const test = require("node:test");

const {
  identifyWorkspaceFile,
  workspaceDeleteParams,
  workspaceResetParams,
  workspaceUpsertParams,
} = require("../.test-out/workspaceProtocol.js");

test("preserves remote URI scheme and authority", () => {
  const identity = identifyWorkspaceFile(
    "vscode-remote://ssh-remote+host/workspace",
    "/workspace",
    "vscode-remote://ssh-remote+host/workspace/lib/main.lus",
    "/workspace/lib/main.lus",
  );
  assert.deepEqual(identity, {
    rootUri: "vscode-remote://ssh-remote+host/workspace",
    relativePath: "lib/main.lus",
    uri: "vscode-remote://ssh-remote+host/workspace/lib/main.lus",
  });
});

test("rejects paths outside the selected workspace root", () => {
  assert.equal(
    identifyWorkspaceFile(
      "file:///workspace/a",
      "/workspace/a",
      "file:///workspace/b/main.lus",
      "/workspace/b/main.lus",
    ),
    undefined,
  );
});

test("builds the exact reset, upsert, and delete contracts", () => {
  const identity = {
    rootUri: "file:///workspace",
    relativePath: "src/main.lus",
    uri: "file:///workspace/src/main.lus",
  };
  assert.deepEqual(workspaceResetParams([identity.rootUri]), {
    roots: [identity.rootUri],
  });
  assert.deepEqual(workspaceUpsertParams(identity, 3, "print(1)"), {
    ...identity,
    version: 3,
    text: "print(1)",
  });
  assert.deepEqual(workspaceDeleteParams(identity, 4), {
    ...identity,
    version: 4,
  });
});
