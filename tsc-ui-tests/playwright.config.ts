import { defineConfig } from "@playwright/test";

export default defineConfig({
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: Number(process.env.PLAYWRIGHT_RETRIES ?? (process.env.CI ? 2 : 0)),
  workers: process.env.CI ? 1 : undefined,
  globalTimeout: Number(
    process.env.PLAYWRIGHT_GLOBAL_TIMEOUT ?? (process.env.CI ? 7_200_000 : 0),
  ),
  // Default timeout covers Electron launch (~20s) + simple UI interactions.
  // Tests involving trace recording override via test.setTimeout().
  timeout: 45_000,
  expect: { timeout: 10_000 },
  reporter: [
    [process.env.CI ? "github" : "list"],
    ["./lib/stats-reporter.ts"],
  ],
  use: {
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  // Deployment mode (electron vs web) is controlled per-test via
  // test.use({ deploymentMode: "web" }) or defaults to "electron".
  // To run all tests in web mode, set CODETRACER_TEST_IN_BROWSER=1.

  // Projects split tests into "default" (no rr required) and "rr"
  // (requires ct-rr-support). CI runs them in separate jobs to avoid
  // duplicating the non-rr tests. Running without --project executes both.
  //
  // Python and Ruby sudoku tests use DB-based recorders (not RR), so they
  // belong in the default project despite living under tests/sudoku/.
  projects: [
    {
      name: "default",
      testDir: "./tests",
      testIgnore: "**/sudoku/!(python-*|ruby-*)*.spec.ts",
    },
    {
      name: "rr",
      testDir: "./tests/sudoku",
      testIgnore: ["**/python-*", "**/ruby-*"],
      timeout: 120_000,
    },
  ],
});
