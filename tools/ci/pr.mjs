#!/usr/bin/env node
// Reads the two required fields of a pull request, Kind and Agent
// disclosure (.github/PULL_REQUEST_TEMPLATE.md), and checks the disclosure
// against the trailers of the commits.
//
//   node tools/ci/pr.mjs check --body-file FILE --base SHA --head SHA
//
// It prints the result as JSON and fails when a field is missing or wrong,
// or when the commits and the disclosure disagree. A disclosure that names
// a harness of tools/ci/harnesses.json needs that harness's trailer on at
// least one commit. A trailer of a known harness on any commit needs the
// harness in the disclosure. Other harnesses are recorded as written.

import {execFileSync} from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const KINDS = ["bug", "perf", "test", "docs"];
// A kind that asks for a change of the language or a new feature. The
// gate closes such a pull request, and the idea belongs in Discussions.
export const REJECTED_KINDS = ["feature", "feat", "design", "language", "proposal", "rfc", "idea", "suggestion"];
export const HARNESSES = JSON.parse(fs.readFileSync(path.join(ROOT, "tools/ci/harnesses.json"), "utf8")).harnesses;

// Splits a body into its sections by level-two heading, without the HTML
// comments of the template.
export function sections(body) {
  const text = (body ?? "").replace(/\r\n/g, "\n").replace(/<!--[\s\S]*?-->/g, "");
  const out = {};
  let current = null;
  for (const line of text.split("\n")) {
    const h = /^##\s+(.+?)\s*#*\s*$/.exec(line);
    if (h) {
      current = h[1].toLowerCase();
      out[current] = [];
    } else if (current) {
      out[current].push(line);
    }
  }
  for (const k of Object.keys(out)) out[k] = out[k].map((l) => l.trim()).filter(Boolean);
  return out;
}

function harnessOf(name) {
  const n = name.toLowerCase().trim();
  return HARNESSES.find((h) => h.name.toLowerCase() === n || h.names.includes(n)) ?? null;
}

export function parseBody(body) {
  const s = sections(body);
  const problems = [];
  let kind = null;
  let rejected = false;
  const kindLines = s["kind"];
  if (!kindLines) {
    problems.push("add the Kind section of the template");
  } else if (kindLines.length !== 1) {
    problems.push(`write exactly one of ${KINDS.join(", ")} under Kind, on a single line`);
  } else {
    const word = kindLines[0].replace(/[`*_]/g, "").toLowerCase().trim();
    if (KINDS.includes(word)) kind = word;
    else {
      if (REJECTED_KINDS.some((r) => word.includes(r))) rejected = true;
      problems.push(`write exactly one of ${KINDS.join(", ")} under Kind, in place of "${kindLines[0]}"`);
    }
  }

  let agents = null;
  const agentLines = s["agent disclosure"];
  if (!agentLines || agentLines.length === 0) {
    problems.push('write "none" under Agent disclosure, or name the agent, the model, and the harness');
  } else if (agentLines.length === 1 && /^"?none"?\.?$/i.test(agentLines[0])) {
    agents = [];
  } else {
    agents = [];
    let group = null;
    for (const line of agentLines) {
      const m = /^[-*]?\s*(agent|model|harness)\s*:\s*(.*)$/i.exec(line);
      if (!m) {
        problems.push(`start the Agent disclosure line "${line}" with Agent:, Model:, or Harness:`);
        continue;
      }
      const key = m[1].toLowerCase();
      if (key === "agent" || !group) {
        group = {agent: "", model: "", harness: ""};
        agents.push(group);
      }
      group[key] = m[2].trim();
    }
    for (const [i, a] of agents.entries()) {
      for (const key of ["agent", "model", "harness"]) {
        if (!a[key]) problems.push(`add the ${key} of agent ${i + 1} to the disclosure`);
      }
    }
  }
  return {kind, rejected, agents, problems};
}

// Checks the disclosure against the commits, each {sha, message}.
export function checkPr(body, commits) {
  const result = parseBody(body);
  const notes = [];
  if (result.agents) {
    const disclosed = new Set();
    for (const a of result.agents) {
      const h = harnessOf(a.harness);
      if (!h) {
        notes.push(`your disclosure of ${a.agent} through ${a.harness} stands as you wrote it, since ${a.harness} adds no trailer that CI can check`);
        continue;
      }
      disclosed.add(h.name);
      const re = new RegExp(h.trailer, "im");
      if (!commits.some((c) => re.test(c.message))) {
        result.problems.push(`keep the trailer of ${h.name} (${h.trailer.replace(/^\^|\\b$/g, "")}) on the commits it helped write, since your disclosure names it`);
      }
    }
    for (const h of HARNESSES) {
      if (disclosed.has(h.name)) continue;
      const re = new RegExp(h.trailer, "im");
      const marked = commits.filter((c) => re.test(c.message)).map((c) => c.sha.slice(0, 10));
      if (marked.length) result.problems.push(`name ${h.name} in your Agent disclosure, since commits ${marked.join(", ")} carry its trailer`);
    }
  }
  return {...result, notes};
}

function main() {
  const args = {};
  const argv = process.argv.slice(2);
  for (let i = 1; i < argv.length; i += 2) args[argv[i].replace(/^--/, "")] = argv[i + 1];
  if (argv[0] !== "check" || !args["body-file"] || !args.base || !args.head) {
    console.error("usage: pr.mjs check --body-file FILE --base SHA --head SHA");
    process.exit(2);
  }
  const body = fs.readFileSync(args["body-file"], "utf8");
  const shas = execFileSync("git", ["rev-list", "--no-merges", `${args.base}..${args.head}`], {cwd: ROOT, encoding: "utf8"}).split("\n").filter(Boolean);
  const commits = shas.map((sha) => ({sha, message: execFileSync("git", ["log", "-1", "--format=%B", sha], {cwd: ROOT, encoding: "utf8"})}));
  const result = checkPr(body, commits);
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.problems.length ? 1 : 0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
