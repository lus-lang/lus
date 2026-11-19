import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const extensionDirectory = path.resolve(scriptDirectory, "..");
const packagePath = path.join(extensionDirectory, "package.json");
const lockPath = path.join(extensionDirectory, "pnpm-lock.yaml");
const require = createRequire(packagePath);
const packageMetadata = JSON.parse(await readFile(packagePath, "utf8"));
const lockText = await readFile(lockPath, "utf8");
export const publisherExternalBuiltins = [
  "assert",
  "crypto",
  "fs",
  "http",
  "https",
  "os",
  "path",
  "querystring",
  "readline",
  "stream",
  "tty",
  "url",
  "util",
];

function escapePattern(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function lockedDevelopmentDependency(name) {
  const version = packageMetadata.devDependencies?.[name];
  assert.match(
    version ?? "",
    /^[0-9]+\.[0-9]+\.[0-9]+$/,
    `${name} must use an exact version`,
  );
  const importer = new RegExp(
    `^      ${escapePattern(name)}:\\n` +
      `        specifier: ${escapePattern(version)}\\n` +
      `        version: ${escapePattern(version)}$`,
    "m",
  );
  assert.match(lockText, importer, `${name} importer pin is missing from pnpm-lock.yaml`);
  const resolution = new RegExp(
    `^  ${escapePattern(name)}@${escapePattern(version)}:\\n` +
      "    resolution: \\{integrity: sha512-[A-Za-z0-9+/]+={0,2}\\}$",
    "m",
  );
  assert.match(
    lockText,
    resolution,
    `${name} integrity is missing from pnpm-lock.yaml`,
  );
  return version;
}

const ovsxVersion = lockedDevelopmentDependency("ovsx");
const esbuildVersion = lockedDevelopmentDependency("esbuild");
const installedOvsx = require("ovsx/package.json");
const installedEsbuild = require("esbuild/package.json");
assert.equal(installedOvsx.version, ovsxVersion, "installed ovsx differs from the lock");
assert.equal(
  installedEsbuild.version,
  esbuildVersion,
  "installed esbuild differs from the lock",
);
const esbuild = require("esbuild");

const entrySource = `
const fs = require("node:fs");
const path = require("node:path");
const { publish } = require("ovsx/lib/publish.js");

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--version") {
    console.log(${JSON.stringify(ovsxVersion)});
    return;
  }
  if (
    args.length !== 1 ||
    !path.isAbsolute(args[0]) ||
    path.extname(args[0]) !== ".vsix"
  ) {
    throw new Error("usage: publisher <absolute-extension.vsix>");
  }
  const vsix = args[0];
  const stat = fs.lstatSync(vsix);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) {
    throw new Error("verified VSIX must be a nonempty regular file");
  }
  const pat = process.env.OVSX_PAT;
  if (typeof pat !== "string" || pat.length === 0) {
    throw new Error("OVSX_PAT is required");
  }
  const results = await publish({ extensionFile: vsix, pat });
  if (!Array.isArray(results) || results.length !== 1) {
    throw new Error("Open VSX publisher returned an unexpected result count");
  }
  const failure = results.find((result) => result.status === "rejected");
  if (failure !== undefined) throw failure.reason;
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
`;

const stubSources = {
  "@vscode/vsce":
    'exports.createVSIX = async function () { throw new Error("publisher bundle accepts only a prebuilt VSIX"); };',
  keytar:
    'throw new Error("credential stores are disabled in the release publisher bundle");',
  "ovsx-zip":
    'exports.readVSIXPackage = async function () { throw new Error("publisher bundle requires OVSX_PAT"); };',
};

const constrainedPublisherPlugin = {
  name: "constrained-open-vsx-publisher",
  setup(build) {
    build.onResolve(
      { filter: /^(?:@vscode\/vsce|keytar)$/ },
      ({ path: requested }) => ({
        path: requested,
        namespace: "publisher-stub",
      }),
    );
    build.onResolve({ filter: /^\.\/zip$/ }, ({ importer }) =>
      importer.replaceAll("\\", "/").endsWith("/ovsx/lib/publish.js")
        ? { path: "ovsx-zip", namespace: "publisher-stub" }
        : undefined,
    );
    build.onLoad(
      { filter: /.*/, namespace: "publisher-stub" },
      ({ path: requested }) => ({
        contents: stubSources[requested],
        loader: "js",
      }),
    );
  },
};

function externalBuiltins(metafile) {
  const values = new Set();
  for (const output of Object.values(metafile.outputs)) {
    for (const imported of output.imports) {
      if (imported.external) values.add(imported.path.replace(/^node:/, ""));
    }
  }
  return [...values].sort();
}

function packageRootForInput(input) {
  let current = path.dirname(path.resolve(extensionDirectory, input));
  const dependencyRoot = path.join(extensionDirectory, "node_modules");
  while (current.startsWith(dependencyRoot)) {
    if (existsSync(path.join(current, "package.json"))) return current;
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error(`publisher input has no package metadata: ${input}`);
}

function bundledPackages(metafile) {
  const packages = new Map();
  for (const input of Object.keys(metafile.inputs)) {
    const normalized = input.replaceAll("\\", "/");
    if (
      normalized === "open-vsx-publisher-entry.cjs" ||
      normalized.startsWith("publisher-stub:")
    ) {
      continue;
    }
    const root = packageRootForInput(input);
    const metadata = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
    assert.equal(typeof metadata.name, "string", `package name is missing in ${root}`);
    assert.match(
      metadata.version ?? "",
      /^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/,
      `package version is invalid in ${root}`,
    );
    assert.equal(typeof metadata.license, "string", `package license is missing in ${root}`);
    const licenseFiles = readdirSync(root, { withFileTypes: true })
      .filter(
        (entry) =>
          entry.isFile() && /^licen[cs]e(?:[._-].*)?$/i.test(entry.name),
      )
      .map((entry) => entry.name)
      .sort();
    assert.ok(licenseFiles.length > 0, `package license text is missing in ${root}`);
    const key = `${metadata.name}@${metadata.version}`;
    const value = {
      license: metadata.license,
      licenseFiles: licenseFiles.map((name) => {
        const text = readFileSync(path.join(root, name), "utf8")
          .replaceAll("\r\n", "\n")
          .trimEnd();
        return {
          name,
          sha256: createHash("sha256").update(`${text}\n`).digest("hex"),
          text,
        };
      }),
      name: metadata.name,
      version: metadata.version,
    };
    const previous = packages.get(key);
    if (previous !== undefined) assert.deepEqual(value, previous);
    packages.set(key, value);
  }
  return [...packages.values()].sort((left, right) =>
    `${left.name}@${left.version}`.localeCompare(`${right.name}@${right.version}`),
  );
}

function publisherNotice(packages) {
  const lines = [
    "Third-party notices for the bundled Open VSX publisher",
    "",
    "The release build generated this inventory from the frozen pnpm dependency tree.",
    "The bundle is used only to publish the separately verified VSIX.",
  ];
  for (const dependency of packages) {
    lines.push(
      "",
      `Package: ${dependency.name}@${dependency.version}`,
      `License: ${dependency.license}`,
    );
    for (const license of dependency.licenseFiles) {
      lines.push("", `License file: ${license.name}`, "", ...license.text.split("\n"));
    }
  }
  return `${lines.join("\n")}\n`;
}

function publicPackageInventory(packages) {
  return packages.map((dependency) => ({
    license: dependency.license,
    licenseFiles: dependency.licenseFiles.map(({ name, sha256 }) => ({
      name,
      sha256,
    })),
    name: dependency.name,
    version: dependency.version,
  }));
}

function noticeBanner(metadata, notice) {
  return [
    `// LUS_OPEN_VSX_PUBLISHER_METADATA ${JSON.stringify(metadata)}`,
    "// LUS_OPEN_VSX_PUBLISHER_NOTICE_BEGIN",
    ...notice
      .slice(0, -1)
      .split("\n")
      .map((line) => `// ${line}`),
    "// LUS_OPEN_VSX_PUBLISHER_NOTICE_END",
  ].join("\n");
}

async function buildOnce(banner = "") {
  const result = await esbuild.build({
    absWorkingDir: extensionDirectory,
    stdin: {
      contents: entrySource,
      loader: "js",
      resolveDir: extensionDirectory,
      sourcefile: "open-vsx-publisher-entry.cjs",
    },
    bundle: true,
    banner: banner ? { js: banner } : undefined,
    format: "cjs",
    legalComments: "eof",
    metafile: true,
    packages: "bundle",
    platform: "node",
    target: "node24",
    write: false,
    plugins: [constrainedPublisherPlugin],
  });
  assert.equal(result.outputFiles.length, 1, "publisher build emitted extra files");
  for (const input of Object.keys(result.metafile.inputs)) {
    const normalized = input.replaceAll("\\", "/");
    assert.ok(
      normalized === "open-vsx-publisher-entry.cjs" ||
        normalized.startsWith("publisher-stub:") ||
        normalized.includes("/node_modules/") ||
        normalized.startsWith("node_modules/"),
      `publisher build consumed an unexpected input: ${input}`,
    );
  }
  assert.deepEqual(
    externalBuiltins(result.metafile),
    publisherExternalBuiltins,
    "publisher external builtin inventory changed",
  );
  const contents = Buffer.from(result.outputFiles[0].contents);
  const text = contents.toString("utf8");
  for (const forbidden of [
    'require("keytar")',
    'require("@vscode/vsce")',
    "@node-rs/crc32",
  ]) {
    assert.ok(!text.includes(forbidden), `publisher retained ${forbidden}`);
  }
  return { contents, metafile: result.metafile };
}

export async function buildPublisher(output) {
  const destination = path.resolve(output);
  assert.equal(path.extname(destination), ".cjs", "publisher output must be .cjs");
  const analysis = await buildOnce();
  const packages = bundledPackages(analysis.metafile);
  const inventory = publicPackageInventory(packages);
  assert.ok(
    inventory.some(
      (dependency) =>
        dependency.name === "ovsx" && dependency.version === ovsxVersion,
    ),
    "publisher bundle omits the pinned ovsx package",
  );
  const notice = publisherNotice(packages);
  const metadata = {
    externalBuiltins: publisherExternalBuiltins,
    noticeSha256: createHash("sha256").update(notice).digest("hex"),
    ovsxVersion,
    packages: inventory,
    schemaVersion: 1,
  };
  const banner = noticeBanner(metadata, notice);
  const first = await buildOnce(banner);
  const second = await buildOnce(banner);
  assert.ok(
    first.contents.equals(second.contents),
    "publisher bundle is not deterministic",
  );
  await mkdir(path.dirname(destination), { recursive: true });
  await writeFile(destination, first.contents, { mode: 0o755 });
  await chmod(destination, 0o755);
  return {
    path: destination,
    externalBuiltins: publisherExternalBuiltins,
    noticeSha256: metadata.noticeSha256,
    packages: inventory,
    sha256: createHash("sha256").update(first.contents).digest("hex"),
    size: first.contents.length,
    version: ovsxVersion,
  };
}

export const publisherVersion = ovsxVersion;

if (
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  assert.equal(process.argv.length, 3, "usage: build-open-vsx-publisher.mjs OUTPUT.cjs");
  console.log(JSON.stringify(await buildPublisher(process.argv[2])));
}
