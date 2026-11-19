import { cp, mkdir, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"

export async function stageLocalWasmPublic({
  sourcePublicDirectory,
  stagedPublicDirectory,
  version,
  wasm,
}) {
  await cp(sourcePublicDirectory, stagedPublicDirectory, { recursive: true })

  const outputDirectory = join(stagedPublicDirectory, "wasm")
  await rm(outputDirectory, { recursive: true, force: true })
  const versionDirectory = join(outputDirectory, version)
  await mkdir(versionDirectory, { recursive: true })
  await writeFile(join(versionDirectory, "lus.wasm"), wasm)
  await writeFile(
    join(outputDirectory, "manifest.json"),
    `${JSON.stringify(
      { stable: { version }, unstable: null },
      null,
      2,
    )}\n`,
  )
}
