// Checks a built `lus` against spec/tools/cli.json, the source of its
// command line: the usage text of every command, the rejection of an
// unknown option, the acceptance of every option by the parsers that read
// `--help` after other options, and the completion scripts that
// `lus completions` prints. The bash script also runs under bash. The
// static checks of tools/build-cli.js, which compare the source with the
// parsers and the manual, run first.
//
//   node tests/cli/cli.test.mjs runtime/zig-out/bin/lus

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const cli = createRequire(import.meta.url)("../../tools/build-cli.js");
const lus = path.resolve(process.argv[2] ?? process.env.LUS_BIN ?? "runtime/zig-out/bin/lus");
const spec = cli.loadSpec();

function run(args, options = {}) {
  const r = spawnSync(lus, args, { encoding: "utf8", timeout: 20000, cwd: root, ...options });
  assert.equal(r.error, undefined, `lus ${args.join(" ")}: ${r.error}`);
  return r;
}

const commandArgs = (c) => (c.default ? [] : [c.name]);

/// A value for an option of the given kind that every parser accepts.
function sample(v) {
  if (v.kind === "enum") return v.values[0];
  if (v.kind === "number") return "1";
  if (v.kind === "permission") return "fs:read";
  if (v.kind === "dir") return ".";
  return "x";
}

test("the source agrees with the parsers and the manual", () => {
  assert.deepEqual(cli.checks(), []);
});

test("every command prints its usage text for --help", () => {
  for (const c of spec.commands) {
    if (c.help === false) continue;
    const r = run([...commandArgs(c), "--help"]);
    assert.equal(r.status, 0, `lus ${c.name} --help: ${r.stderr}`);
    assert.equal(r.stdout, cli.usageText(spec, c), `lus ${c.name} --help`);
  }
});

test("every command rejects an unknown option", () => {
  for (const c of spec.commands) {
    if (c.name === "lsp") continue;
    const r = run([...commandArgs(c), "--no-such-option"], { input: "" });
    assert.notEqual(r.status, 0, `lus ${c.name} --no-such-option exited with 0`);
    assert.match(r.stderr, /usage: lus/, `lus ${c.name} --no-such-option printed no usage`);
  }
});

// These parsers read every argument before they act, so an option followed
// by --help prints the usage and exits with status 0 exactly when the
// parser accepts the option.
const READS_ALL = new Set(["run", "fmt", "check", "doc", "debug", "tree", "version"]);
// Options that act at once, before the parser reaches --help.
const ACTS_AT_ONCE = new Set(["check --list", "check --explain"]);

test("the parsers that read every argument accept every option", () => {
  for (const c of spec.commands) {
    if (!READS_ALL.has(c.name)) continue;
    for (const o of c.options ?? []) {
      if (o.hidden || o.names.includes("--help")) continue;
      for (const name of o.names) {
        if (ACTS_AT_ONCE.has(`${c.name} ${name}`)) continue;
        const args = [...commandArgs(c), name, ...(o.value ? [sample(o.value)] : []), "--help"];
        const r = run(args, { input: "" });
        assert.equal(r.status, 0, `lus ${args.join(" ")}: ${r.stderr}`);
        assert.match(r.stdout, /^usage: lus/, `lus ${args.join(" ")}`);
      }
    }
  }
});

const SCRIPTS = {
  bash: "packaging/share/bash-completion/completions/lus",
  zsh: "packaging/share/zsh/site-functions/_lus",
  fish: "packaging/share/fish/vendor_completions.d/lus.fish",
  powershell: "packaging/share/powershell/lus.ps1",
};

test("lus completions prints the generated scripts", () => {
  for (const [shell, file] of Object.entries(SCRIPTS)) {
    const r = run(["completions", shell]);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, readFileSync(path.join(root, file), "utf8"), `lus completions ${shell}`);
  }
  assert.equal(run(["completions", "tcsh"]).status, 2);
  assert.equal(run(["completions"]).status, 2);
});

const hasShell = (name) => process.platform !== "win32" && spawnSync(name, ["-c", "exit 0"]).status === 0;

test("the bash script completes commands, options, and values", { skip: !hasShell("bash") }, () => {
  const complete = (...words) => {
    const program = `source "$1"
shift
COMP_WORDS=("$@")
COMP_CWORD=$((\${#COMP_WORDS[@]} - 1))
COMPREPLY=()
_lus
printf '%s\\n' "\${COMPREPLY[@]}"`;
    const r = spawnSync("bash", ["-c", program, "bash", path.join(root, SCRIPTS.bash), ...words], { encoding: "utf8", cwd: root });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout.split("\n").filter(Boolean);
  };
  assert.deepEqual(complete("lus", "doc", "--format", ""), ["md", "json", "html"]);
  assert.deepEqual(complete("lus", "version", ""), ["list", "install", "use", "remove", "which"]);
  assert.deepEqual(complete("lus", "version", "list", "--remote", ""), ["stable", "unstable"]);
  assert.deepEqual(complete("lus", "completions", ""), ["bash", "zsh", "fish", "powershell"]);
  assert.deepEqual(complete("lus", "test", "--jo"), ["--jobs"]);
  assert.ok(complete("lus", "fmt", "--").includes("--strict"));
  assert.ok(complete("lus", "-P", "fs").includes("fs:read"));
  assert.ok(complete("lus", "").includes("completions"));
  assert.ok(complete("lus", "--s").includes("--sandbox"));
});

test("the zsh script parses", { skip: !hasShell("zsh") }, () => {
  const r = spawnSync("zsh", ["-n", path.join(root, SCRIPTS.zsh)], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
});

test("the fish script parses", { skip: !hasShell("fish") }, () => {
  const r = spawnSync("fish", ["-n", path.join(root, SCRIPTS.fish)], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
});
