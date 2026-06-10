import { describe, it, test } from "node:test";
import assert from "node:assert/strict";

const fake = "test('fake node string', () => {})";
const fakeTemplate = `describe("fake node template", () => {})`;
// it("fake node comment", () => {})

describe("node runner", () => {
  it("runs js", () => {
    assert.equal(1, 1);
  });

  test("runs async js", async () => {
    await Promise.resolve();
  });
});

test("top level node", () => {
  assert.ok(true);
});
