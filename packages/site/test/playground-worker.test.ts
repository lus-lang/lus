import assert from "node:assert/strict"
import test from "node:test"

import { installPlaygroundWorker } from "../src/workers/playground-worker.ts"

class FakeWorkerScope {
  messages: unknown[] = []
  listener:
    | ((event: MessageEvent<any>) => void | Promise<void>)
    | undefined

  addEventListener(
    type: "message",
    listener: (event: MessageEvent<any>) => void | Promise<void>,
  ): void {
    assert.equal(type, "message")
    this.listener = listener
  }

  postMessage(message: unknown): void {
    this.messages.push(message)
  }

  async dispatch(data: unknown): Promise<void> {
    assert.ok(this.listener)
    await this.listener({ data } as MessageEvent<any>)
  }
}

const release = (version: string) => ({
  version,
  jsUrl: `/wasm/${version}/lus.js`,
  wasmUrl: `/wasm/${version}/lus.wasm`,
  isStable: true,
})

test("dedicated worker scopes keep runtime execution isolated", async () => {
  const first = new FakeWorkerScope()
  const second = new FakeWorkerScope()
  const firstCalls: string[] = []
  const secondCalls: string[] = []
  installPlaygroundWorker(first, async () => ({
    execute(code) {
      firstCalls.push(code)
      return `first:${code}`
    },
    destroy() {},
  }))
  installPlaygroundWorker(second, async () => ({
    execute(code) {
      secondCalls.push(code)
      return `second:${code}`
    },
    destroy() {},
  }))

  await first.dispatch({ type: "initialize", release: release("v1") })
  await second.dispatch({ type: "initialize", release: release("v2") })
  await first.dispatch({ type: "run", id: 1, code: "A" })
  await second.dispatch({ type: "run", id: 2, code: "B" })

  assert.deepEqual(firstCalls, ["A"])
  assert.deepEqual(secondCalls, ["B"])
  assert.deepEqual(first.messages.at(-1), {
    type: "result",
    id: 1,
    text: "first:A",
    truncated: false,
  })
  assert.deepEqual(second.messages.at(-1), {
    type: "result",
    id: 2,
    text: "second:B",
    truncated: false,
  })
})

test("initializing the worker prepares a runtime without autorun", async () => {
  const scope = new FakeWorkerScope()
  let executions = 0
  installPlaygroundWorker(scope, async () => ({
    execute() {
      executions++
      return "unexpected"
    },
    destroy() {},
  }))

  await scope.dispatch({ type: "initialize", release: release("v1") })

  assert.equal(executions, 0)
  assert.deepEqual(scope.messages, [{ type: "ready" }])
})

test("an execute trap destroys and retires the runtime before recovery", async () => {
  const scope = new FakeWorkerScope()
  let loads = 0
  let destroyed = 0
  installPlaygroundWorker(scope, async () => {
    loads++
    if (loads === 1) {
      return {
        execute() {
          throw new WebAssembly.RuntimeError("forced execute trap")
        },
        destroy() {
          destroyed++
        },
      }
    }
    return {
      execute(code) {
        return `recovered:${code}`
      },
      destroy() {
        destroyed++
      },
    }
  })

  await scope.dispatch({ type: "initialize", release: release("v1") })
  await scope.dispatch({ type: "run", id: 1, code: "trap" })

  assert.equal(destroyed, 1)
  assert.deepEqual(scope.messages.at(-1), {
    type: "runtime-error",
    id: 1,
    error: "RuntimeError: forced execute trap",
  })

  await scope.dispatch({ type: "run", id: 2, code: "must not run" })
  assert.deepEqual(scope.messages.at(-1), {
    type: "run-error",
    id: 2,
    error: "The Lus runtime is still loading",
  })

  await scope.dispatch({ type: "initialize", release: release("v1") })
  await scope.dispatch({ type: "run", id: 3, code: "ok" })
  assert.deepEqual(scope.messages.at(-1), {
    type: "result",
    id: 3,
    text: "recovered:ok",
    truncated: false,
  })
})
