// Tests of the reading of coverage exports. Run: mise run ci:test

import assert from "node:assert/strict";
import {test} from "node:test";
import {sourceOf} from "./testmap.mjs";

test("positions map to paths from the root", () => {
  assert.equal(sourceOf("/home/runner/work/lus/lus/runtime/src/lib/json.zig:10:5"), "runtime/src/lib/json.zig");
  assert.equal(sourceOf("src/vm/gc.zig:1:1"), "runtime/src/vm/gc.zig");
  assert.equal(sourceOf("vm/gc.zig:1:1"), "runtime/src/vm/gc.zig");
  assert.equal(sourceOf("C:\\a\\runtime\\src\\lib\\fs.zig:3:4"), "runtime/src/lib/fs.zig");
  assert.equal(sourceOf("/usr/lib/zig/std/mem.zig:1:1"), null);
});
