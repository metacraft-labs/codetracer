/** Only the lifecycle self-test collects this probe; the ordinary suite does not. */
import * as path from "node:path";
import { defineConfig } from "@playwright/test";
import base from "../../../playwright.config";

const out = process.env.CT_FIXTURE_HOME_PROBE_OUT;
if (!out) throw new Error("CT_FIXTURE_HOME_PROBE_OUT is required");

export default defineConfig(base, {
  testDir: __dirname,
  testMatch: /fixture-home\.probe\.ts$/,
  testIgnore: [],
  outputDir: path.join(out, "playwright-output"),
  reporter: [["line"]],
  retries: 0,
  workers: 1,
  globalTimeout: 0,
});
