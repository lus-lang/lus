import assert from "node:assert/strict"
import test from "node:test"

import {
  PLAYGROUND_EXECUTION_LIMIT_MS,
  PLAYGROUND_OUTPUT_LIMIT_BYTES,
  PLAYGROUND_TRUNCATION_MARKER,
  PlaygroundRunController,
  limitPlaygroundOutput,
  playgroundOutputLines,
} from "../src/lib/playground-runtime.ts"

const encodedLength = (value: string) => new TextEncoder().encode(value).length

test("keeps output through the byte limit", () => {
  const text = "x".repeat(PLAYGROUND_OUTPUT_LIMIT_BYTES)
  assert.deepEqual(limitPlaygroundOutput(text), { text, truncated: false })
})

test("caps oversized output at 256 KiB and exposes a visible DOM line", () => {
  const result = limitPlaygroundOutput(
    "x".repeat(PLAYGROUND_OUTPUT_LIMIT_BYTES + 1),
  )
  assert.equal(result.truncated, true)
  assert.equal(encodedLength(result.text), PLAYGROUND_OUTPUT_LIMIT_BYTES)
  assert.equal(result.text.endsWith(PLAYGROUND_TRUNCATION_MARKER), true)
  assert.equal(
    playgroundOutputLines(result.text.trimEnd()).at(-1),
    "[Output truncated at 256 KiB.]",
  )
})

test("keeps a valid UTF-8 boundary", () => {
  const result = limitPlaygroundOutput("🙂".repeat(80), 101)
  assert.equal(result.truncated, true)
  assert.ok(encodedLength(result.text) <= 101)
  assert.doesNotThrow(() =>
    new TextDecoder("utf-8", { fatal: true }).decode(
      new TextEncoder().encode(result.text),
    ),
  )
})

test("requires enough room for the visible marker", () => {
  assert.throws(() => limitPlaygroundOutput("oversized", 1), RangeError)
})

class FakeTimers {
  nextHandle = 1
  callbacks = new Map<number, () => void>()
  delays = new Map<number, number>()

  setTimeout(callback: () => void, delay: number): number {
    const handle = this.nextHandle++
    this.callbacks.set(handle, callback)
    this.delays.set(handle, delay)
    return handle
  }

  clearTimeout(handle: unknown): void {
    this.callbacks.delete(handle as number)
    this.delays.delete(handle as number)
  }

  fire(handle: number): void {
    const callback = this.callbacks.get(handle)
    assert.ok(callback)
    this.callbacks.delete(handle)
    this.delays.delete(handle)
    callback()
  }
}

class FakeWorker {
  messages: unknown[] = []
  terminated = false

  postMessage(message: unknown): void {
    this.messages.push(message)
  }

  terminate(): void {
    this.terminated = true
  }
}

test("attaching a worker does not autorun editor content", () => {
  const timers = new FakeTimers()
  const worker = new FakeWorker()
  const controller = new PlaygroundRunController(timers, () => {})

  controller.attachWorker(worker)

  assert.deepEqual(worker.messages, [])
  assert.equal(timers.callbacks.size, 0)
})

test("Stop terminates the isolated worker and rejects its stale result", () => {
  const timers = new FakeTimers()
  const worker = new FakeWorker()
  const controller = new PlaygroundRunController(timers, () => {})
  controller.attachWorker(worker)
  const id = controller.run("while true do end")
  assert.notEqual(id, null)

  controller.terminateWorker()

  assert.equal(worker.terminated, true)
  assert.equal(timers.callbacks.size, 0)
  assert.equal(controller.finishRun(worker, id!), false)
})

test("an execute failure terminates the poisoned worker before reload", () => {
  const timers = new FakeTimers()
  const worker = new FakeWorker()
  const controller = new PlaygroundRunController(timers, () => {})
  controller.attachWorker(worker)
  const id = controller.run("force a trap")
  assert.notEqual(id, null)

  assert.equal(controller.failRun(worker, id!), true)
  assert.equal(worker.terminated, true)
  assert.equal(timers.callbacks.size, 0)
  assert.equal(controller.finishRun(worker, id!), false)
})

test("the deterministic timeout fires at five seconds", () => {
  const timers = new FakeTimers()
  const worker = new FakeWorker()
  let timedOut = 0
  const controller = new PlaygroundRunController(timers, () => timedOut++)
  controller.attachWorker(worker)
  controller.run("print('slow')")
  const [handle] = timers.callbacks.keys()

  assert.equal(timers.delays.get(handle), PLAYGROUND_EXECUTION_LIMIT_MS)
  timers.fire(handle)
  assert.equal(timedOut, 1)
})
