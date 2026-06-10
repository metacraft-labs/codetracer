import { describe, expect, it, test } from "vitest";

// describe("fake vitest comment", () => {})
const fake = "test('fake vitest string', () => {})";
const fakeTemplate = `it("fake vitest template", () => {})`;

describe("math", () => {
  it("adds", () => {
    expect(1 + 1).toBe(2);
  });

  describe("nested", () => {
    test.concurrent("async square", async () => {
      expect(3 * 3).toBe(9);
    });
  });
});

test.todo("documents todo support");
