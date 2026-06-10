const fakeLine = "test('from string', () => {})";
const fakeTemplate = `describe('from template', () => {
  it('from template child', () => {});
})`;

// test('from comment', () => {})
/*
describe('from block comment', () => {
  it('from block comment child', () => {});
});
*/

describe("calculator", () => {
  test("adds numbers", () => {
    expect(1 + 2).toBe(3);
  });

  it.only("subtracts numbers", () => {
    expect(3 - 1).toBe(2);
  });

  describe("async operations", () => {
    test.skip("waits for promise", async () => {
      await Promise.resolve();
    });
  });
});

test("top level js", () => {
  expect(true).toBe(true);
});
