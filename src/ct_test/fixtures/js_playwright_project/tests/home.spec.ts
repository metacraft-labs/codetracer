import { test, expect } from "@playwright/test";

test.describe("home page", () => {
  test("renders greeting", async ({ page }) => {
    await page.setContent("<main><h1>Hello CodeTracer</h1></main>");
    await expect(
      page.getByRole("heading", { name: "Hello CodeTracer" }),
    ).toBeVisible();
  });

  test("updates counter", async ({ page }) => {
    await page.setContent("<button>Count 0</button>");
    await page.getByRole("button").evaluate((button) => {
      button.textContent = "Count 1";
    });
    await expect(page.getByRole("button")).toHaveText("Count 1");
  });
});
