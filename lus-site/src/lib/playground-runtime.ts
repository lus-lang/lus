export const PLAYGROUND_EXECUTION_LIMIT_MS = 5_000
export const PLAYGROUND_OUTPUT_LIMIT_BYTES = 256 * 1024
export const PLAYGROUND_TRUNCATION_MARKER =
  "\n[Output truncated at 256 KiB.]\n"

export interface LimitedOutput {
  text: string
  truncated: boolean
}

export interface PlaygroundWorkerLike {
  postMessage(message: { type: "run"; id: number; code: string }): void
  terminate(): void
}

export interface PlaygroundTimers {
  setTimeout(callback: () => void, delay: number): unknown
  clearTimeout(handle: unknown): void
}

export function playgroundOutputLines(text: string): string[] {
  return text.split("\n")
}

export class PlaygroundRunController {
  private worker: PlaygroundWorkerLike | null = null
  private activeRun = 0
  private timer: unknown | null = null
  private readonly timers: PlaygroundTimers
  private readonly onTimeout: () => void
  private readonly executionLimitMs: number

  constructor(
    timers: PlaygroundTimers,
    onTimeout: () => void,
    executionLimitMs = PLAYGROUND_EXECUTION_LIMIT_MS,
  ) {
    this.timers = timers
    this.onTimeout = onTimeout
    this.executionLimitMs = executionLimitMs
  }

  attachWorker(worker: PlaygroundWorkerLike): void {
    this.terminateWorker()
    this.worker = worker
  }

  isCurrentWorker(worker: PlaygroundWorkerLike): boolean {
    return worker === this.worker
  }

  run(code: string): number | null {
    if (!this.worker || !code.trim()) return null
    this.clearTimer()
    const worker = this.worker
    const id = ++this.activeRun
    worker.postMessage({ type: "run", id, code })
    this.timer = this.timers.setTimeout(() => {
      if (worker !== this.worker || id !== this.activeRun) return
      this.timer = null
      this.onTimeout()
    }, this.executionLimitMs)
    return id
  }

  finishRun(worker: PlaygroundWorkerLike, id: number): boolean {
    if (worker !== this.worker || id !== this.activeRun) return false
    this.clearTimer()
    return true
  }

  failRun(worker: PlaygroundWorkerLike, id: number): boolean {
    if (worker !== this.worker || id !== this.activeRun) return false
    this.terminateWorker()
    return true
  }

  terminateWorker(): void {
    this.clearTimer()
    this.activeRun++
    const worker = this.worker
    this.worker = null
    worker?.terminate()
  }

  private clearTimer(): void {
    if (this.timer !== null) this.timers.clearTimeout(this.timer)
    this.timer = null
  }
}

export function limitPlaygroundOutput(
  text: string,
  limit = PLAYGROUND_OUTPUT_LIMIT_BYTES,
): LimitedOutput {
  const encoder = new TextEncoder()
  const bytes = encoder.encode(text)
  if (bytes.length <= limit) return { text, truncated: false }

  const markerBytes = encoder.encode(PLAYGROUND_TRUNCATION_MARKER)
  if (markerBytes.length > limit) {
    throw new RangeError("The output limit must fit the truncation marker")
  }

  let prefixBytes = limit - markerBytes.length
  let prefix = ""
  while (prefixBytes >= 0) {
    try {
      prefix = new TextDecoder("utf-8", { fatal: true }).decode(
        bytes.subarray(0, prefixBytes),
      )
      break
    } catch {
      prefixBytes--
    }
  }
  return {
    text: prefix + PLAYGROUND_TRUNCATION_MARKER,
    truncated: true,
  }
}
