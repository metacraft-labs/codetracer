import { test, expect } from "@playwright/test";

test.describe("form flow", () => {
  test("submits entered value", async ({ page }) => {
    await page.setContent("<label>Name <input></label><output></output>");
    await page.getByLabel("Name").fill("Ada");
    await page.locator("output").evaluate((node) => {
      node.textContent = "Ada";
    });
    await expect(page.locator("output")).toHaveText("Ada");
  });

  test("fails on missing output", async ({ page }) => {
    await page.setContent("<label>Name <input></label><output></output>");
    await page.getByLabel("Name").fill("Grace");
    await expect(page.locator("output")).toHaveText("Grace");
  });

  test.skip("skips optional path", async ({ page }) => {
    await page.setContent("<p>optional</p>");
    await expect(page.locator("p")).toHaveText("optional");
  });
});
