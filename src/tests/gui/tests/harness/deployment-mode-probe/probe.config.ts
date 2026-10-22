/**
 * Playwright config for the deployment-mode probe, run as a child process by
 * `tests/harness/deployment-mode-env.spec.ts`.
 *
 * It is the suite's own `playwright.config.ts` with only what a child run
 * needs changed: the probe as the sole test, a scratch output directory, a
 * plain reporter, and no retries. Everything else, including any `use:`
 * default the real config might set, stays as the suite runs it, so the
 * probe observes the same deployment-mode default a real spec gets.
 *
 * The probe is named `*.probe.ts`, not `*.spec.ts`, so the regular suite
 * never collects it; only this config matches it.
 */

import * as path from "node:path";
import { defineConfig } from "@playwright/test";
import base from "../../../playwright.config";

const probeOut = process.env.CT_DEPLOYMENT_MODE_PROBE_OUT;
if (!probeOut) {
  throw new Error(
    "CT_DEPLOYMENT_MODE_PROBE_OUT is not set; this config is run by deployment-mode-env.spec.ts",
  );
}

export default defineConfig(base, {
  testDir: __dirname,
  testMatch: /deployment-mode\.probe\.ts$/,
  testIgnore: [],
  // A subdirectory: Playwright empties its outputDir when a run starts.
  outputDir: path.join(probeOut, "playwright-output"),
  reporter: [["line"]],
  retries: 0,
  workers: 1,
  globalTimeout: 0,
});
