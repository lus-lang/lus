// Tests of the reading of bug reports. Run: mise run ci:test

import assert from "node:assert/strict";
import {test} from "node:test";
import {fields, program} from "./issue.mjs";

const body = "### Version\n\nlus 2.0.0\n\n### Platform\n\nLinux x86-64\n\n### Reproduction\n\n```lus\nprint(1 // 0)\n```\n\n### Expected and actual behavior\n\n_No response_\n";

test("fields of the bug form", () => {
  const f = fields(body);
  assert.equal(f["version"], "lus 2.0.0");
  assert.equal(f["platform"], "Linux x86-64");
  assert.equal(f["expected and actual behavior"], "");
  assert.equal(program(f["reproduction"]), "print(1 // 0)");
  assert.equal(program("print(2)"), "print(2)");
});
