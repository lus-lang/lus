// Tests tools/build-facts.js on the repository as it is.
const assert = require("node:assert/strict");
const facts = require("./build-facts.js");

assert.match(facts.readVersion(), /^\d+\.\d+\.\d+/);
assert.equal(facts.release("2.0.0-dev"), "2.0.0");
assert.equal(facts.release("2.0.1"), "2.0.1");
assert.ok(facts.readKeywords().includes("provide"));
assert.ok(facts.readPermissions().includes("network:server"));
assert.equal(facts.withVersion('{\n  "name": "x",\n  "version": "1.0.0"\n}\n', "2.0.0"), '{\n  "name": "x",\n  "version": "2.0.0"\n}\n');
assert.deepEqual(facts.checks(), []);
console.log("build-facts: all checks passed");
