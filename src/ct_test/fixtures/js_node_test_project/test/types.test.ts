import { test } from "node:test";
import assert from "node:assert/strict";

test("typescript needs loader", () => {
  assert.equal("ts".toUpperCase(), "TS");
});
