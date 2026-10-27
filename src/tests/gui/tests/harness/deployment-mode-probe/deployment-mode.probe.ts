/**
 * Probe run by `tests/harness/deployment-mode-env.spec.ts` in a child
 * Playwright process (config: `probe.config.ts` beside this file).
 *
 * Each test only reads the real `deploymentMode` option fixture from
 * `lib/fixtures` and writes the value it got to
 * `$CT_DEPLOYMENT_MODE_PROBE_OUT/<name>.txt`; the parent spec asserts on it.
 * No other fixture is requested, so nothing launches Electron or `ct`.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { test } from "../../../lib/fixtures";

function record(name: string, mode: string): void {
  const outDir = process.env.CT_DEPLOYMENT_MODE_PROBE_OUT;
  if (!outDir) {
    throw new Error(
      "CT_DEPLOYMENT_MODE_PROBE_OUT is not set; this probe is run by deployment-mode-env.spec.ts",
    );
  }
  fs.writeFileSync(path.join(outDir, `${name}.txt`), mode);
}

test("default", ({ deploymentMode }) => {
  record("default", deploymentMode);
});

test.describe("per-spec electron", () => {
  test.use({ deploymentMode: "electron" });
  test("electron override", ({ deploymentMode }) => {
    record("electron-override", deploymentMode);
  });
});

test.describe("per-spec web", () => {
  test.use({ deploymentMode: "web" });
  test("web override", ({ deploymentMode }) => {
    record("web-override", deploymentMode);
  });
});
