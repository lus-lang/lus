import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const extensionDirectory = path.resolve(scriptDirectory, "..");
const repositoryDirectory = path.resolve(extensionDirectory, "..", "..");
const configurationPath = path.join(
  extensionDirectory,
  "test",
  "devcontainer",
  ".devcontainer",
  "devcontainer.json",
);
const cliPackagePath = require.resolve("@devcontainers/cli/package.json");
const cliPackage = JSON.parse(fs.readFileSync(cliPackagePath, "utf8"));
const cliPath = path.join(path.dirname(cliPackagePath), cliPackage.bin.devcontainer);
const qualificationLabel = `lus.release.qual=${process.pid}-${Date.now()}`;
let containerId;

assert.equal(cliPackage.version, "0.88.0", "Dev Containers CLI pin drifted");
const configuration = JSON.parse(fs.readFileSync(configurationPath, "utf8"));
assert.equal(
  configuration.image,
  "emscripten/emsdk@sha256:af45409f3199d88db4b1b03af0098532c8fb33a375ac257463eeb0a622870d06",
  "Dev Container image must remain pinned by digest",
);
assert.equal(configuration.remoteUser, "root");
assert.equal(configuration.containerEnv.LUS_DEVCONTAINER_QUALIFICATION, "1");

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: extensionDirectory,
    encoding: "utf8",
    env: process.env,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n");
    throw new Error(`${command} exited with ${result.status}\n${detail}`);
  }
  return result.stdout;
}

function devcontainer(args) {
  return run(process.execPath, [cliPath, ...args]);
}

function parseUpResult(output) {
  for (const line of output.trim().split("\n").reverse()) {
    try {
      const value = JSON.parse(line);
      if (value.outcome) return value;
    } catch {
      // Structured CLI logs can include non-JSON output from Docker.
    }
  }
  throw new Error("Dev Containers CLI did not return a provisioning result");
}

try {
  run("docker", ["version", "--format", "{{.Server.Version}}"]);
  const up = parseUpResult(
    devcontainer([
      "up",
      "--workspace-folder",
      repositoryDirectory,
      "--config",
      configurationPath,
      "--id-label",
      qualificationLabel,
      "--frozen-lockfile",
      "--log-format",
      "json",
    ]),
  );
  assert.equal(up.outcome, "success", "Dev Container provisioning failed");
  assert.match(up.containerId, /^[0-9a-f]{64}$/);
  assert.equal(up.remoteWorkspaceFolder, "/workspaces/lus");
  containerId = up.containerId;

  const remoteSmoke = devcontainer([
    "exec",
    "--container-id",
    containerId,
    "node",
    "/workspaces/lus/packages/vscode/scripts/smoke-wasm.mjs",
    "/workspaces/lus/packages/vscode/wasm",
  ]);
  assert.match(remoteSmoke, /WASM extension smoke passed/);
  process.stdout.write(remoteSmoke);
  console.log("Dev Container remote workspace smoke passed");
} finally {
  const containerIds = containerId
    ? [containerId]
    : run("docker", [
        "ps",
        "--all",
        "--quiet",
        "--filter",
        `label=${qualificationLabel}`,
      ])
        .trim()
        .split("\n")
        .filter(Boolean);
  for (const id of containerIds) {
    const cleanup = spawnSync("docker", ["rm", "--force", id], {
      cwd: extensionDirectory,
      encoding: "utf8",
    });
    if (cleanup.status !== 0) {
      const detail = [cleanup.stdout, cleanup.stderr]
        .filter(Boolean)
        .join("\n");
      throw new Error(`temporary Dev Container cleanup failed\n${detail}`);
    }
  }
}
