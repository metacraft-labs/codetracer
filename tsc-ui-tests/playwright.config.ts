import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: Number(process.env.PLAYWRIGHT_RETRIES ?? (process.env.CI ? 2 : 0)),
  workers: process.env.CI ? 1 : undefined,
  globalTimeout: process.env.CI ? 7_200_000 : 0,
  timeout: 120_000,
  expect: { timeout: 10_000 },
  reporter: process.env.CI ? "github" : "html",
  use: {
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  // Deployment mode (electron vs web) is controlled per-test via
  // test.use({ deploymentMode: "web" }) or defaults to "electron".
  // To run all tests in web mode, set CODETRACER_TEST_IN_BROWSER=1.
});
