/*
** Canonical install commands, imported by the homepage and
** getting-started.mdx so the surfaces can never drift.
*/
// @ts-expect-error vite ?raw import
import runtimeManifest from "../../../../runtime/build.zig.zon?raw"
import project from "../../../../packaging/project.json"

/*
** The one-line installer for Linux and macOS. Serves
** packaging/install/install.sh (repo root) via src/pages/install.sh.ts.
** On platforms without prebuilt archives it prints build-from-source
** guidance instead of installing.
*/
export const INSTALL_SH = `curl -fsSL ${project.site}/install.sh | sh`

/*
** The Windows installer. It installs per user by default, with no admin
** prompt, and puts lus on PATH. /ALLUSERS from an elevated prompt
** installs machine-wide.
*/
export const WINDOWS_INSTALLER_URL =
  `${project.repository}/releases/latest/download/lus-setup.exe`

/*
** The release the manual download commands name. The site documents the
** runtime of its checkout, so the tag is the version in build.zig.zon
** without its prerelease suffix.
*/
const version = /^\s*\.version = "([0-9]+\.[0-9]+\.[0-9]+)[^"]*",/m.exec(
  runtimeManifest as string,
)?.[1]
if (version === undefined) {
  throw new Error("runtime/build.zig.zon has no version")
}
export const RELEASE_TAG = `v${version}`

const DOWNLOAD = `${project.repository}/releases/download`

/*
** Manual downloads: the release archive for one target, unpacked into
** ./lus with the interpreter at lus/bin/lus.
*/
function unixCommands(comment: string, target: string): string {
  return `${comment}
tag=${RELEASE_TAG}
curl -LO ${DOWNLOAD}/$tag/lus-$tag-${target}.tar.gz
mkdir lus && tar -xzf lus-$tag-${target}.tar.gz -C lus
./lus/bin/lus -v`
}

export const INSTALL_LINUX = unixCommands(
  "# x86_64. Use the archive of the architecture, such as aarch64-linux-musl or riscv64-linux-musl.",
  "x86_64-linux-musl",
)

export const INSTALL_MACOS = unixCommands(
  "# Apple Silicon. Use x86_64-macos on Intel Macs.",
  "aarch64-macos",
)

export const INSTALL_WINDOWS = `# x86_64. Use aarch64-windows on 64-bit Arm.
$tag = "${RELEASE_TAG}"
curl.exe -LO ${DOWNLOAD}/$tag/lus-$tag-x86_64-windows.zip
Expand-Archive lus-$tag-x86_64-windows.zip lus
.\\lus\\bin\\lus.exe -v`

/*
** The prompt the homepage offers beside the installer, for readers who
** work through a coding agent. It installs Lus and its skills, as a
** plugin in Claude Code and with `lus agents init` in any other agent,
** links the skill to read first, and ends on an assessment, the first
** phase of the lus-rewrite skill. It is the first prompt of
** .agents/prompt.md, which also holds the other prompts of /agents.
*/
export const AGENT_PROMPT = `Install Lus with \`${INSTALL_SH}\`. Then add the Lus skills. In Claude Code, run \`claude plugin install lus --marketplace lus-lang/lus\`. In any other agent, run \`lus agents init\` in this project. Use one method. You can read the skill first at https://lus.dev/agents/skills/lus/SKILL.md. Then use the lus skill to look at this project and tell me where Lus would help. Change nothing yet.`
