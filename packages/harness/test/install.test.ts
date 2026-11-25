// Runs install.sh against stub `pi` and `lus` commands in a temporary home.
// Run: node --experimental-strip-types --test test/*.test.ts
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const HARNESS = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const ROOT = resolve(HARNESS, "..", "..");
const INSTALL = join(HARNESS, "install.sh");

function sandbox() {
  const dir = mkdtempSync(join(tmpdir(), "lus-harness-install-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  // The stub pi prints its arguments, one per line.
  writeFileSync(join(bin, "pi"), '#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done\n');
  writeFileSync(join(bin, "lus"), "#!/bin/sh\necho 'Lus 2.0.0' >&2\n");
  chmodSync(join(bin, "pi"), 0o755);
  chmodSync(join(bin, "lus"), 0o755);
  const env = { ...process.env, HOME: dir, LUS_HOME: join(dir, "home"), PATH: `${bin}:/usr/bin:/bin` };
  return { dir, bin, env };
}

function run(script: string, args: string[], env: NodeJS.ProcessEnv) {
  return spawnSync("sh", [script, ...args], { env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

test("a checkout installs a launcher that points at the checkout", () => {
  const { env } = sandbox();
  const res = run(INSTALL, [], env);
  assert.equal(res.status, 0, res.stderr);
  const launcher = join(env.LUS_HOME!, "bin", "lush");
  assert.match(readFileSync(launcher, "utf8"), new RegExp(`harness='${HARNESS}'`));
  const out = execFileSync(launcher, ["-p", "hi"], { env, encoding: "utf8" }).trim().split("\n");
  assert.deepEqual(out, ["-e", HARNESS, "--use-theme", "lus-light/lus", "-p", "hi"]);
});

test("the launcher keeps a theme named on the command line", () => {
  const { env } = sandbox();
  assert.equal(run(INSTALL, ["--name", "lpi"], env).status, 0);
  const out = execFileSync(join(env.LUS_HOME!, "bin", "lpi"), ["--use-theme", "dark"], { env, encoding: "utf8" }).trim().split("\n");
  assert.deepEqual(out, ["-e", HARNESS, "--use-theme", "dark"]);
});

test("outside a checkout the harness comes from the source archive", () => {
  const { dir, env } = sandbox();
  const copy = join(dir, "install.sh");
  copyFileSync(INSTALL, copy);
  const archive = join(dir, "src.tar.gz");
  // GitHub archives hold one top directory, named after the repository and the ref.
  const tree = join(dir, "lus-main");
  mkdirSync(join(tree, "packages"), { recursive: true });
  for (const part of ["packages/harness", "packages/language-server", ".agents"]) cpSync(join(ROOT, part), join(tree, part), { recursive: true });
  execFileSync("tar", ["-czf", archive, "lus-main"], { cwd: dir });
  const res = run(copy, ["--ref", "main"], { ...env, LUS_HARNESS_ARCHIVE: archive });
  assert.equal(res.status, 0, res.stderr);
  const installed = join(env.LUS_HOME!, "harness", "main");
  for (const part of ["packages/harness/src/index.ts", "packages/language-server/main.lus", ".agents/skills/lus/SKILL.md"]) {
    assert.ok(existsSync(join(installed, part)), part);
  }
  assert.match(readFileSync(join(env.LUS_HOME!, "bin", "lush"), "utf8"), /harness\/main\/packages\/harness'/);
});

test("a missing pi stops the install when --no-pi is given", () => {
  const { env } = sandbox();
  const res = run(INSTALL, ["--no-pi"], { ...env, PATH: "/usr/bin:/bin" });
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /pi is not installed/);
});

test("the installer leaves a launcher it did not write alone", () => {
  const { env } = sandbox();
  mkdirSync(join(env.LUS_HOME!, "bin"), { recursive: true });
  writeFileSync(join(env.LUS_HOME!, "bin", "lush"), "#!/bin/sh\necho mine\n");
  const res = run(INSTALL, [], env);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /was not written by this installer/);
});

test("--uninstall removes the launcher and the downloaded harness", () => {
  const { env } = sandbox();
  assert.equal(run(INSTALL, [], env).status, 0);
  mkdirSync(join(env.LUS_HOME!, "harness", "v2.0.0"), { recursive: true });
  assert.equal(run(INSTALL, ["--uninstall"], env).status, 0);
  assert.ok(!existsSync(join(env.LUS_HOME!, "bin", "lush")));
  assert.ok(!existsSync(join(env.LUS_HOME!, "harness")));
});
