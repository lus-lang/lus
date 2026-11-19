import assert from "node:assert/strict"
import test from "node:test"

import { callWasmUtf8 } from "../src/lib/wasm-loader.ts"

function mockModule(output: string | Uint8Array = "result") {
  const calls: unknown[][] = []
  const heap = new Uint8Array(512)
  const outputBytes =
    typeof output === "string" ? new TextEncoder().encode(output) : output
  heap.set(outputBytes, 128)
  return {
    calls,
    module: {
      HEAPU8: heap,
      _malloc(size: number) {
        calls.push(["malloc", size])
        return 64
      },
      _free(pointer: number) {
        calls.push(["free", pointer])
      },
      lengthBytesUTF8(value: string) {
        return Buffer.byteLength(value, "utf8")
      },
      stringToUTF8(value: string, pointer: number, capacity: number) {
        const length = Buffer.byteLength(value, "utf8")
        calls.push(["encode", pointer, capacity, length])
        return length
      },
    },
  }
}

test("marshals 2 MiB source through a caller-freed heap buffer", () => {
  const { calls, module } = mockModule()
  const source = "x".repeat(2 * 1024 * 1024)
  let callArgs: number[] | undefined

  const result = callWasmUtf8(
    module,
    (...args) => {
      callArgs = args
      return 128
    },
    () => 6,
    7,
    source,
  )

  assert.equal(result, "result")
  assert.deepEqual(callArgs, [7, 64, Buffer.byteLength(source)])
  assert.deepEqual(calls[0], ["malloc", Buffer.byteLength(source) + 1])
  assert.deepEqual(calls.at(-1), ["free", 64])
})

test("decodes the reported byte range without truncating embedded NUL", () => {
  const { module } = mockModule(new Uint8Array([65, 0, 66]))
  const result = callWasmUtf8(module, () => 128, () => 3, 7, "x")

  assert.equal(result, "A\0B")
  assert.equal(result.length, 3)
})

test("rejects malformed UTF-8 and output outside linear memory", () => {
  const malformed = mockModule(new Uint8Array([0xc0, 0x80]))
  assert.throws(
    () => callWasmUtf8(malformed.module, () => 128, () => 2, 7, "x"),
    /not valid UTF-8/,
  )

  const outside = mockModule()
  assert.throws(
    () => callWasmUtf8(outside.module, () => 510, () => 6, 7, "x"),
    /outside linear memory/,
  )
})

test("frees source after execution failure", () => {
  const { calls, module } = mockModule()
  assert.throws(
    () =>
      callWasmUtf8(
        module,
        () => {
          throw new Error("execution failed")
        },
        () => 0,
        7,
        "local =",
      ),
    /execution failed/,
  )
  assert.deepEqual(calls.at(-1), ["free", 64])
})

test("rejects only unrepresentable sizes and allocation failure", () => {
  const oversized = mockModule()
  oversized.module.lengthBytesUTF8 = () => 0xffff_ffff
  assert.throws(
    () => callWasmUtf8(oversized.module, () => 0, () => 0, 7, "x"),
    /not representable in wasm32/,
  )
  assert.deepEqual(oversized.calls, [])

  const exhausted = mockModule()
  exhausted.module._malloc = (size: number) => {
    exhausted.calls.push(["malloc", size])
    return 0
  }
  assert.throws(
    () => callWasmUtf8(exhausted.module, () => 0, () => 0, 7, "x"),
    /allocation failed/,
  )
  assert.deepEqual(exhausted.calls, [["malloc", 2]])
})
