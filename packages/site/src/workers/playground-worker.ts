import { limitPlaygroundOutput } from "../lib/playground-runtime.ts"
import { loadLusWasm } from "../lib/wasm-loader.ts"
import type { LusModule, WasmRelease } from "../lib/wasm-loader.ts"

type PlaygroundRequest =
  | { type: "initialize"; release: WasmRelease }
  | { type: "run"; id: number; code: string }

interface PlaygroundWorkerScope {
  addEventListener(
    type: "message",
    listener: (event: MessageEvent<PlaygroundRequest>) => void | Promise<void>,
  ): void
  postMessage(message: unknown): void
}

export function installPlaygroundWorker(
  scope: PlaygroundWorkerScope,
  loadRuntime: (release: WasmRelease) => Promise<LusModule> = loadLusWasm,
): void {
  let runtime: LusModule | null = null

  scope.addEventListener(
    "message",
    async (event: MessageEvent<PlaygroundRequest>) => {
      const request = event.data
      if (request.type === "initialize") {
        try {
          runtime?.destroy()
          runtime = await loadRuntime(request.release)
          scope.postMessage({ type: "ready" })
        } catch (error) {
          runtime = null
          scope.postMessage({ type: "load-error", error: String(error) })
        }
        return
      }

      if (!runtime) {
        scope.postMessage({
          type: "run-error",
          id: request.id,
          error: "The Lus runtime is still loading",
        })
        return
      }
      try {
        const result = limitPlaygroundOutput(runtime.execute(request.code))
        scope.postMessage({ type: "result", id: request.id, ...result })
      } catch (error) {
        const failedRuntime = runtime
        runtime = null
        try {
          failedRuntime.destroy()
        } catch {
          // A trapped WASM module can reject teardown too.
        }
        scope.postMessage({
          type: "runtime-error",
          id: request.id,
          error: String(error),
        })
      }
    },
  )
}

const workerScope = globalThis as unknown as Partial<PlaygroundWorkerScope>
if (
  typeof workerScope.addEventListener === "function" &&
  typeof workerScope.postMessage === "function"
) {
  installPlaygroundWorker(workerScope as PlaygroundWorkerScope)
}
