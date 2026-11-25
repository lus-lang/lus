#!/usr/bin/env node
// Rewrites the version of the repository for a release, which
// .github/workflows/ship.yml runs.
//
//   node tools/release-version.mjs release --version X.Y.Z --date YYYY-MM-DD
//       Turns X.Y.Z-dev into X.Y.Z. It sets the version of
//       runtime/build.zig.zon, packages/wasm, and packages/vscode, dates the
//       section of X.Y.Z in CHANGELOG.md, and writes that section as the
//       news page packages/site/src/news/changelog-X.Y.Z.md.
//
//   node tools/release-version.mjs next --version X.Y.Z
//       Starts the version after the release X.Y.Z, which raises the minor
//       number: build.zig.zon and packages/wasm hold X.(Y+1).0-dev, and
//       CHANGELOG.md opens an undated section for X.(Y+1).0.
//
//   node tools/release-version.mjs notes --version X.Y.Z
//       Prints the section of X.Y.Z in CHANGELOG.md without its date line.
//
// Each command takes --root DIR, the root of the checkout, which defaults
// to the current directory.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

export function parseVersion(text) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(text ?? "");
  if (!m) throw new Error(`a release version is X.Y.Z, and ${text} is not one`);
  return m.slice(1).map(Number);
}

export function nextVersion(version) {
  const [major, minor] = parseVersion(version);
  return `${major}.${minor + 1}.0`;
}

/** The written date of `date`, YYYY-MM-DD, as CHANGELOG.md gives it. */
export function longDate(date) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date ?? "");
  if (!m || Number(m[2]) < 1 || Number(m[2]) > 12) throw new Error(`a date is YYYY-MM-DD, and ${date} is not one`);
  return `${months[Number(m[2]) - 1]} ${Number(m[3])}, ${m[1]}`;
}

export function zonVersion(zon) {
  const m = /^ *\.version = "([^"]*)",$/m.exec(zon);
  if (!m) throw new Error("build.zig.zon has no .version line");
  return m[1];
}

export function setZonVersion(zon, version) {
  return zon.replace(/^( *\.version = ")[^"]*(",)$/m, `$1${version}$2`);
}

export function setPackageVersion(json, version) {
  const value = JSON.parse(json);
  if (typeof value.version !== "string") throw new Error(`package ${value.name} has no version`);
  // Rewriting only the version line keeps the layout of the file.
  return json.replace(/^(  "version": ")[^"]*(",?)$/m, `$1${version}$2`);
}

/** The lines of the section `version` of `changelog` and where it starts and ends. */
function section(changelog, version) {
  const lines = changelog.split("\n");
  const start = lines.findIndex((l) => l === `## ${version}` || l.startsWith(`## ${version} `));
  if (start < 0) throw new Error(`CHANGELOG.md has no section for ${version}`);
  let end = lines.findIndex((l, i) => i > start && l.startsWith("## "));
  if (end < 0) end = lines.length;
  return { lines, start, end };
}

export function changelogNotes(changelog, version) {
  const { lines, start, end } = section(changelog, version);
  const body = lines.slice(start + 1, end).filter((l) => !l.startsWith("**Release date:**"));
  const text = body.join("\n").trim();
  if (text === "") throw new Error(`the section for ${version} in CHANGELOG.md is empty`);
  return text + "\n";
}

export function dateChangelog(changelog, version, date) {
  const { lines, start, end } = section(changelog, version);
  lines[start] = `## ${version}`;
  const at = lines.slice(start + 1, end).findIndex((l) => l.startsWith("**Release date:**"));
  if (at < 0) throw new Error(`the section for ${version} in CHANGELOG.md has no release date line`);
  lines[start + 1 + at] = `**Release date:** ${longDate(date)}`;
  return lines.join("\n");
}

export function openChangelog(changelog, version) {
  const head = "# Changelog\n\n";
  if (!changelog.startsWith(head)) throw new Error("CHANGELOG.md does not start with its title");
  if (changelog.split("\n").some((l) => l.startsWith(`## ${version}`))) throw new Error(`CHANGELOG.md already has a section for ${version}`);
  return `${head}## ${version} (**WIP**)\n\n**Release date:** TBD\n\n${changelog.slice(head.length)}`;
}

export function newsPage(changelog, version, date) {
  longDate(date);
  return `---\ntitle: Lus ${version}\ndate: ${date}\n---\n\n${changelogNotes(changelog, version)}`;
}

const files = {
  zon: "runtime/build.zig.zon",
  wasm: "packages/wasm/package.json",
  vscode: "packages/vscode/package.json",
  changelog: "CHANGELOG.md",
};

function release(root, version, date) {
  parseVersion(version);
  const read = (f) => readFileSync(join(root, f), "utf8");
  const zon = read(files.zon);
  const current = zonVersion(zon);
  if (current !== `${version}-dev`) throw new Error(`build.zig.zon holds ${current}, and the release ${version} needs ${version}-dev`);
  const changelog = dateChangelog(read(files.changelog), version, date);
  writeFileSync(join(root, files.zon), setZonVersion(zon, version));
  writeFileSync(join(root, files.wasm), setPackageVersion(read(files.wasm), version));
  writeFileSync(join(root, files.vscode), setPackageVersion(read(files.vscode), version));
  writeFileSync(join(root, files.changelog), changelog);
  writeFileSync(join(root, `packages/site/src/news/changelog-${version}.md`), newsPage(changelog, version, date));
}

function next(root, version) {
  const read = (f) => readFileSync(join(root, f), "utf8");
  const zon = read(files.zon);
  const current = zonVersion(zon);
  if (current !== version) throw new Error(`build.zig.zon holds ${current}, and the version after ${version} starts from ${version}`);
  const following = nextVersion(version);
  writeFileSync(join(root, files.zon), setZonVersion(zon, `${following}-dev`));
  writeFileSync(join(root, files.wasm), setPackageVersion(read(files.wasm), `${following}-dev`));
  writeFileSync(join(root, files.changelog), openChangelog(read(files.changelog), following));
  return following;
}

function main(argv) {
  const [command, ...rest] = argv;
  const a = {};
  for (let i = 0; i < rest.length; i += 2) {
    if (!rest[i].startsWith("--") || rest[i + 1] === undefined) throw new Error(`unexpected argument ${rest[i]}`);
    a[rest[i].slice(2)] = rest[i + 1];
  }
  const root = a.root ?? ".";
  switch (command) {
    case "release":
      release(root, a.version, a.date);
      break;
    case "next":
      process.stdout.write(`${next(root, a.version)}-dev\n`);
      break;
    case "notes":
      process.stdout.write(changelogNotes(readFileSync(join(root, files.changelog), "utf8"), a.version));
      break;
    default:
      throw new Error(`unknown command ${command}, expected release, next, or notes`);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    console.error(`release-version: ${e.message}`);
    process.exit(1);
  }
}
