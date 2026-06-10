import { describe, test, it } from "@jest/globals";

const fake = 'it("fake ts string", () => {})';
const fakeTemplate = `test("fake ts template", () => {})`;

describe("typescript calculator", () => {
  test("multiplies numbers", () => {
    expect(2 * 3).toBe(6);
  });

  it("handles async types", async () => {
    await Promise.resolve(42);
  });
});
