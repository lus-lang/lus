#!/usr/bin/env node
// The contribution gate, the labels of a pull request, and the comments
// that the workflows post. .github/workflows/contributions.yml runs it
// from the default branch with the event of GitHub, and it reads the pull
// request or the issue only through the API, never by checking out its
// code.
//
//   node tools/ci/gate.mjs gate          check the author, the commits, the fields, and the paths
//   node tools/ci/gate.mjs labels        set the area and kind labels of a pull request
//   node tools/ci/gate.mjs comment N FILE MARKER   create or update one comment
//   node tools/ci/gate.mjs close N FILE LABEL      comment, label, and close an issue
//   node tools/ci/gate.mjs perf N SHA FILE         label a pull request from a measurement of ci.yml
//   node tools/ci/gate.mjs discuss N CATEGORY FILE move an issue to Discussions, then close and lock it
//
// GITHUB_TOKEN, GITHUB_REPOSITORY, and GITHUB_EVENT_PATH come from the
// workflow. NUMBER names the pull request or issue when the event has
// none, as a manual run does. With DRY_RUN set to 1 the script prints each
// write instead of making it.
//
// The owner, members, and collaborators of the repository, the logins of
// .github/known-authors, and the Lus app itself (APP_SLUG), whose pull
// requests carry the fixes of the agent, skip the gate. Everyone else needs an account
// at least two years old. A pull request needs every commit verified by
// GitHub, which also shows that the account has a verified email bound to
// its signing key, a valid Kind and agent disclosure (tools/ci/pr.mjs),
// and only paths that contributors may change (tools/ci/areas.json). An
// issue needs a GPG or SSH signing key on the account.
//
// A pull request that touches an egregious path is closed and locked. One
// whose Kind asks for a feature or a design change is closed, and the
// idea belongs in Discussions. Any other failure gets the label gate-failed and one
// comment that lists what to fix, which the next run updates.

import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {loadMap, plan, trackedFiles} from "./areas.mjs";
import {benches, compare, table} from "./perf.mjs";
import {checkPr} from "./pr.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const API = process.env.GITHUB_API_URL ?? "https://api.github.com";
const REPO = process.env.GITHUB_REPOSITORY;
const DRY = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
const EXEMPT_ASSOCIATIONS = ["OWNER", "MEMBER", "COLLABORATOR"];
const MIN_AGE_DAYS = 730;
const GATE_MARKER = "<!-- lus-gate -->";

async function api(method, route, body) {
  const res = await fetch(`${API}${route}`, {
    method,
    headers: {
      authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      ...(body ? {"content-type": "application/json"} : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 204) return null;
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    const error = new Error(`${method} ${route}: ${res.status} ${data?.message ?? ""}`);
    error.status = res.status;
    throw error;
  }
  return data;
}

async function pages(route, limit = 10) {
  const all = [];
  for (let page = 1; page <= limit; page++) {
    const sep = route.includes("?") ? "&" : "?";
    const batch = await api("GET", `${route}${sep}per_page=100&page=${page}`);
    all.push(...batch);
    if (batch.length < 100) break;
  }
  return all;
}

// A write to GitHub, which a dry run prints.
async function write(method, route, body) {
  if (DRY) {
    console.log(`dry run: ${method} ${route}${body ? " " + JSON.stringify(body).slice(0, 300) : ""}`);
    return null;
  }
  return api(method, route, body);
}

function output(values) {
  const lines = Object.entries(values).map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`);
  console.log(lines.join("\n"));
  if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, lines.join("\n") + "\n");
}

export function knownAuthors(text) {
  return new Set(
    text
      .split("\n")
      .map((l) => l.replace(/#.*/, "").trim().toLowerCase())
      .filter(Boolean),
  );
}

// Loads the pull request or the issue of the event, as {kind, item}.
async function subject() {
  const event = process.env.GITHUB_EVENT_PATH ? JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, "utf8")) : {};
  if (event.pull_request) return {kind: "pr", item: event.pull_request};
  if (event.issue && !event.issue.pull_request) return {kind: "issue", item: event.issue};
  const number = process.env.NUMBER ?? event.inputs?.number;
  if (!number) throw new Error("no pull request or issue in the event, and NUMBER is unset");
  const issue = await api("GET", `/repos/${REPO}/issues/${number}`);
  if (issue.pull_request) return {kind: "pr", item: await api("GET", `/repos/${REPO}/pulls/${number}`)};
  return {kind: "issue", item: issue};
}

// Decides the gate from what the API returned. Kept apart from the calls
// so the tests can drive it.
export function decide({kind, item, user, commits, files, keys, known, now = Date.now()}) {
  const login = item.user.login;
  const failures = [];
  let action = "pass";
  const app = process.env.APP_SLUG ? `${process.env.APP_SLUG}[bot]`.toLowerCase() : null;
  if (EXEMPT_ASSOCIATIONS.includes(item.author_association) || known.has(login.toLowerCase()) || login.toLowerCase() === app) {
    return {exempt: true, passed: true, action, failures, labels: [], verdict: "allowed"};
  }
  const days = (now - Date.parse(user.created_at)) / 86400000;
  if (days < MIN_AGE_DAYS) failures.push(`The account @${login} is ${Math.floor(days)} days old, and the gate needs an account at least two years old.`);

  let verdict = "allowed";
  let fields = null;
  if (kind === "issue") {
    if (keys === 0) failures.push(`The account @${login} has no GPG or SSH signing key, which is how the gate checks that an account is verified.`);
  } else {
    const unsigned = commits.filter((c) => !c.commit.verification?.verified).map((c) => `${c.sha.slice(0, 10)} (${c.commit.verification?.reason ?? "unsigned"})`);
    if (unsigned.length) failures.push(`GitHub does not verify the signature of these commits: ${unsigned.join(", ")}. CONTRIBUTING.md explains how to sign them.`);
    fields = checkPr(item.body ?? "", commits.map((c) => ({sha: c.sha, message: c.commit.message})));
    for (const p of fields.problems) failures.push(`The pull request description: ${p}.`);
    const result = plan({map: loadMap(), changed: files, tracked: trackedFiles()});
    verdict = result.contributor.verdict;
    if (result.contributor.egregious.length) failures.push(`These paths are closed to contributors: ${result.contributor.egregious.join(", ")}.`);
    if (result.contributor.denied.length) failures.push(`Contributors leave these paths to the maintainer: ${result.contributor.denied.join(", ")}.`);
    if (verdict === "egregious") action = "lock";
    else if (fields.rejected) action = "reject";
  }
  if (failures.length && action === "pass") action = "fail";
  const labels = action === "reject" ? ["rejected"] : failures.length ? ["gate-failed"] : [];
  return {exempt: false, passed: failures.length === 0, action, failures, labels, verdict, fields};
}

function gateComment(decision, kind) {
  const what = kind === "pr" ? "pull request" : "issue";
  const lines = [GATE_MARKER];
  if (decision.action === "lock") {
    lines.push(`This ${what} changes paths that only the maintainer changes, so it is closed and locked.`);
  } else if (decision.action === "reject") {
    lines.push("Pull requests that add a feature or change the design of the language are closed. Bring your idea to Discussions instead.");
  } else if (decision.passed) {
    lines.push(`This ${what} passes the contribution gate.`);
    return lines.join("\n\n");
  } else {
    lines.push(`This ${what} does not pass the contribution gate yet. No review or test runs until it does. Each fix below runs the gate again, as an edit of the description or a push of new commits does.`);
  }
  lines.push(decision.failures.map((f) => `- ${f}`).join("\n"));
  lines.push(`[CONTRIBUTING.md](https://github.com/${REPO}/blob/main/CONTRIBUTING.md) describes each rule.`);
  return lines.join("\n\n");
}

// Creates or updates the comment that holds the marker. With onlyUpdate
// set, a missing comment stays missing.
async function upsertComment(number, body, marker, onlyUpdate = false) {
  const comments = await pages(`/repos/${REPO}/issues/${number}/comments`);
  const mine = comments.find((c) => c.user?.type === "Bot" && c.body?.includes(marker));
  if (!mine && onlyUpdate) return false;
  if (mine) {
    if (mine.body !== body) await write("PATCH", `/repos/${REPO}/issues/comments/${mine.id}`, {body});
  } else {
    await write("POST", `/repos/${REPO}/issues/${number}/comments`, {body});
  }
  return Boolean(mine);
}

// Creates each label of tools/ci/areas.json that the repository lacks.
async function ensureLabels(names) {
  const map = JSON.parse(fs.readFileSync(path.join(ROOT, "tools/ci/areas.json"), "utf8"));
  const described = {...map.labels, ...map.status_labels};
  const existing = new Set((await pages(`/repos/${REPO}/labels`)).map((l) => l.name));
  for (const name of names) {
    if (existing.has(name)) continue;
    try {
      await write("POST", `/repos/${REPO}/labels`, {name, description: (described[name] ?? "").slice(0, 100), color: name.startsWith("kind:") ? "1d76db" : map.labels[name] ? "c5def5" : "d93f0b"});
    } catch (error) {
      if (error.status !== 422) throw error;
    }
  }
}

async function setLabels(number, add, removable) {
  const current = new Set((await api("GET", `/repos/${REPO}/issues/${number}`)).labels.map((l) => l.name));
  const adding = add.filter((l) => !current.has(l));
  if (adding.length) {
    await ensureLabels(adding);
    await write("POST", `/repos/${REPO}/issues/${number}/labels`, {labels: adding});
  }
  for (const name of removable) {
    if (current.has(name) && !add.includes(name)) await write("DELETE", `/repos/${REPO}/issues/${number}/labels/${encodeURIComponent(name)}`);
  }
}

async function prFiles(number) {
  const files = await pages(`/repos/${REPO}/pulls/${number}/files`, 30);
  return [...new Set(files.flatMap((f) => [f.filename, f.previous_filename].filter(Boolean)))];
}

async function runGate() {
  const {kind, item} = await subject();
  const number = item.number;
  const known = knownAuthors(fs.readFileSync(path.join(ROOT, ".github/known-authors"), "utf8"));
  const user = await api("GET", `/users/${item.user.login}`);
  let commits = [];
  let files = [];
  let keys = null;
  if (kind === "pr") {
    commits = await pages(`/repos/${REPO}/pulls/${number}/commits`, 3);
    files = await prFiles(number);
  } else {
    const gpg = await api("GET", `/users/${item.user.login}/gpg_keys`);
    const ssh = await api("GET", `/users/${item.user.login}/ssh_signing_keys`);
    keys = gpg.length + ssh.length;
  }
  const decision = decide({kind, item, user, commits, files, keys, known});
  console.log(JSON.stringify({kind, number, login: item.user.login, ...decision, fields: undefined}, null, 2));

  if (!decision.exempt) {
    // A contribution that passes on its first run gets no comment. One
    // that failed before sees its comment turn into a pass.
    await upsertComment(number, gateComment(decision, kind), GATE_MARKER, decision.passed);
    await setLabels(number, decision.labels, ["gate-failed"]);
    const route = kind === "pr" ? `/repos/${REPO}/pulls/${number}` : `/repos/${REPO}/issues/${number}`;
    if (decision.action === "reject" || decision.action === "lock") await write("PATCH", route, {state: "closed"});
    if (decision.action === "lock") await write("PUT", `/repos/${REPO}/issues/${number}/lock`, {lock_reason: "resolved"});
  }
  // The agents run once per contribution, and once more when it starts
  // passing after a failure.
  const hadFailed = (item.labels ?? []).some((l) => l.name === "gate-failed");
  output({
    kind,
    number: String(number),
    exempt: String(decision.exempt),
    passed: String(decision.passed),
    newly_passed: String(decision.passed && hadFailed),
    action: decision.action,
    draft: String(Boolean(item.draft)),
  });
}

async function runLabels() {
  const {kind, item} = await subject();
  if (kind !== "pr") return;
  const map = loadMap();
  const result = plan({map, changed: await prFiles(item.number), tracked: trackedFiles()});
  const kinds = ["bug", "perf", "test", "docs"].map((k) => `kind:${k}`);
  const fields = checkPr(item.body ?? "", []);
  const add = [...result.labels, ...(fields.kind ? [`kind:${fields.kind}`] : [])];
  const areaLabels = [...Object.keys(map.labels).filter((k) => k !== "about"), "triage"];
  await setLabels(item.number, add, [...areaLabels, ...kinds]);
  output({labels: add, benches: result.benches});
}

// Labels a pull request from the measurement that the perf job of ci.yml
// uploaded. The file came from a run of the pull request, so it is read as
// data: the pull request must still have the head that was measured, the
// names must be benchmarks of tests/bench, and the table is built here
// from the numbers.
async function runPerf(number, sha, file) {
  const pr = await api("GET", `/repos/${REPO}/pulls/${number}`);
  if (pr.head.sha !== sha) {
    console.log(`pull request ${number} has moved on from ${sha}, so its labels stay`);
    return;
  }
  const data = JSON.parse(fs.readFileSync(file, "utf8"));
  const known = new Set(benches());
  const clean = (side) => ({
    benches: Object.fromEntries(
      Object.entries(side?.benches ?? {})
        .filter(([name, v]) => known.has(name) && ["time", "rss"].every((k) => Number.isFinite(v?.[k]?.median) && Number.isFinite(v?.[k]?.mad)))
        .map(([name, v]) => [name, {time: {median: v.time.median, mad: v.time.mad}, rss: {median: v.rss.median, mad: v.rss.mad}}]),
    ),
  });
  const result = compare(clean(data.head), clean(data.base));
  const body = `<!-- lus-perf -->\n\n${table(result, "Benchmarks of this change against its base")}\n\nThe benchmarks ran on one runner, the base and the head in turn. tools/ci/perf.json holds the thresholds.`;
  const marker = "<!-- lus-perf -->";
  await upsertComment(number, body, marker, result.regressions.length === 0);
  await setLabels(number, result.regressions.length ? ["perf-regression"] : [], ["perf-regression"]);
}

async function graphql(query, variables) {
  const data = await api("POST", "/graphql", {query, variables});
  if (data?.errors?.length) throw new Error(`graphql: ${data.errors.map((e) => e.message).join("; ")}`);
  return data.data;
}

// Moves an issue to Discussions. The API offers no transfer, so the script
// opens a discussion in the category that holds the title, the text, and
// the author of the issue, comments the link on the issue with the text of
// FILE, then closes and locks the issue.
async function runDiscuss(number, category, file) {
  const issue = await api("GET", `/repos/${REPO}/issues/${number}`);
  const [owner, name] = REPO.split("/");
  const repo = await graphql(
    "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id discussionCategories(first: 25) { nodes { id name } } } }",
    {owner, name},
  );
  const categories = repo.repository.discussionCategories.nodes;
  const chosen = categories.find((c) => c.name.toLowerCase() === category.toLowerCase()) ?? categories[0];
  if (!chosen) throw new Error("the repository has no discussion category");
  const body = `@${issue.user.login} opened this as issue #${number}.\n\n${issue.body ?? ""}`.slice(0, 60000);
  let url = "(dry run)";
  if (DRY) {
    console.log(`dry run: create a discussion in ${chosen.name}: ${issue.title}`);
  } else {
    const made = await graphql(
      "mutation($repo: ID!, $cat: ID!, $title: String!, $body: String!) { createDiscussion(input: {repositoryId: $repo, categoryId: $cat, title: $title, body: $body}) { discussion { url } } }",
      {repo: repo.repository.id, cat: chosen.id, title: issue.title, body},
    );
    url = made.createDiscussion.discussion.url;
  }
  const text = fs.readFileSync(file, "utf8").replaceAll("DISCUSSION_URL", url);
  await write("POST", `/repos/${REPO}/issues/${number}/comments`, {body: text.slice(0, 60000)});
  await setLabels(number, ["rejected"], []);
  await write("PATCH", `/repos/${REPO}/issues/${number}`, {state: "closed", state_reason: "not_planned"});
  await write("PUT", `/repos/${REPO}/issues/${number}/lock`, {lock_reason: "resolved"});
  output({discussion: url});
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (command === "gate") return runGate();
  if (command === "labels") return runLabels();
  if (command === "comment" && rest.length === 3) {
    const [number, file, marker] = rest;
    const body = `${marker}\n\n${fs.readFileSync(file, "utf8").slice(0, 60000)}`;
    await upsertComment(number, body, marker);
    return;
  }
  if (command === "close" && rest.length === 3) {
    const [number, file, label] = rest;
    await write("POST", `/repos/${REPO}/issues/${number}/comments`, {body: fs.readFileSync(file, "utf8").slice(0, 60000)});
    await setLabels(number, [label], []);
    await write("PATCH", `/repos/${REPO}/issues/${number}`, {state: "closed", state_reason: "not_planned"});
    return;
  }
  if (command === "perf" && rest.length === 3) return runPerf(...rest);
  if (command === "discuss" && rest.length === 3) return runDiscuss(...rest);
  console.error("usage: gate.mjs gate | labels | comment NUMBER FILE MARKER | close NUMBER FILE LABEL | perf NUMBER SHA FILE | discuss NUMBER CATEGORY FILE");
  process.exit(2);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
