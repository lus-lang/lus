// Tests of the reading of bug reports. Run: mise run ci:test

import assert from "node:assert/strict";
import {test} from "node:test";
import fs from "node:fs";
import {fields, program} from "./issue.mjs";

// The version of the runtime, so the report reads like a current one.
const version = `lus ${fs.readFileSync(new URL("../../runtime/build.zig.zon", import.meta.url), "utf8").match(/\.version = "([^"]+)"/)[1]}`;
const body = "### Version\n\n" + version + "\n\n### Platform\n\nLinux x86-64\n\n### Reproduction\n\n```lus\nprint(1 // 0)\n```\n\n### Expected and actual behavior\n\n_No response_\n";

test("fields of the bug form", () => {
  const f = fields(body);
  assert.equal(f["version"], version);
  assert.equal(f["platform"], "Linux x86-64");
  assert.equal(f["expected and actual behavior"], "");
  assert.equal(program(f["reproduction"]), "print(1 // 0)");
  assert.equal(program("print(2)"), "print(2)");
});
