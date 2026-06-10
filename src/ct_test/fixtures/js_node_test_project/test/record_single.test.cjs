const { test } = require("node:test");
const assert = require("node:assert/strict");

function double(value) {
  return value * 2;
}

test("records single cjs node test", () => {
  assert.equal(double(21), 42);
});
