/**
 * Self-test for the run-wide deployment-mode switch,
 * `CODETRACER_TEST_IN_BROWSER`.
 *
 * The property pinned here: setting `CODETRACER_TEST_IN_BROWSER=1` makes the
 * `deploymentMode` fixture of every spec that does not choose for itself
 * `"web"`; unset, `""` or `"0"` leave it `"electron"`; any other value fails
 * the run with an error naming the variable; and a per-spec
 * `test.use({ deploymentMode })` still wins over the variable. The config has
 * documented the switch all along, but nothing read it after the move from
 * `ct_helpers` to `lib/fixtures`, so setting it silently ran Electron.
 *
 * Two layers are checked:
 *
 * - `deploymentModeFromEnv` itself, called on literal environments;
 * - the wiring, end to end: a child `playwright test` run of
 *   `deployment-mode-probe/deployment-mode.probe.ts` under the suite's own
 *   config, which reads the real `deploymentMode` option fixture from
 *   `lib/fixtures` and writes what it got to a scratch directory.
 *
 * No mocks: the child is the real Playwright runner loading the real
 * fixtures module and the real config. It requests no fixture that launches
 * anything, and runs with `CODETRACER_E2E_CT_PATH` pointing at a path that
 * does not exist, so it needs no build and proves it launches no `ct`.
 */

import { test, expect } from "@playwright/test";
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  deploymentModeFromEnv,
  TEST_IN_BROWSER_ENV,
} from "../../lib/deployment-mode";

// src/tests/gui: the child must run from here, as every recipe does, because
// lib/fixtures resolves the repository root from the working directory.
const guiDir = path.resolve(__dirname, "..", "..");
const probeConfig = path.join(
  __dirname,
  "deployment-mode-probe",
  "probe.config.ts",
);
const playwrightCli = path.join(
  guiDir,
  "node_modules",
  "@playwright",
  "test",
  "cli.js",
);

test.describe("harness: deploymentModeFromEnv", () => {
  test('"1" selects web', () => {
    expect(deploymentModeFromEnv({ [TEST_IN_BROWSER_ENV]: "1" })).toBe("web");
  });

  test('unset, "" and "0" select electron', () => {
    expect(deploymentModeFromEnv({})).toBe("electron");
    expect(deploymentModeFromEnv({ [TEST_IN_BROWSER_ENV]: undefined })).toBe(
      "electron",
    );
    expect(deploymentModeFromEnv({ [TEST_IN_BROWSER_ENV]: "" })).toBe(
      "electron",
    );
    expect(deploymentModeFromEnv({ [TEST_IN_BROWSER_ENV]: "0" })).toBe(
      "electron",
    );
  });

  test("any other value throws, naming the variable, the value and the accepted values", () => {
    for (const bad of ["true", "yes", "web", " 1", "2"]) {
      let message = "";
      try {
        deploymentModeFromEnv({ [TEST_IN_BROWSER_ENV]: bad });
      } catch (ex) {
        message = (ex as Error).message;
      }
      expect(message, `value ${JSON.stringify(bad)} must throw`).toContain(
        TEST_IN_BROWSER_ENV,
      );
      expect(message).toContain(JSON.stringify(bad));
      expect(message).toContain('"1"');
      expect(message).toContain('"0"');
    }
  });
});

interface ProbeRun {
  status: number | null;
  output: string;
  /** Recorded `deploymentMode` per probe test, e.g. `{ default: "web" }`. */
  modes: Record<string, string>;
}

/**
 * Run the probe in a child Playwright process with `CODETRACER_TEST_IN_BROWSER`
 * set to `value` (`undefined` removes it).
 */
function runProbe(value: string | undefined): ProbeRun {
  const out = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-deployment-mode-probe-"),
  );
  try {
    const env: Record<string, string | undefined> = { ...process.env };
    // Drop what this (parent) Playwright worker exports for itself, so the
    // child is an ordinary top-level run.
    for (const key of Object.keys(env)) {
      if (
        key.startsWith("PW_") ||
        key.startsWith("TEST_") ||
        key === "PLAYWRIGHT_RETRIES"
      ) {
        delete env[key];
      }
    }
    delete env[TEST_IN_BROWSER_ENV];
    if (value !== undefined) env[TEST_IN_BROWSER_ENV] = value;
    env.CT_DEPLOYMENT_MODE_PROBE_OUT = out;
    env.CODETRACER_E2E_CT_PATH = path.join(out, "no-ct-here", "ct");
    env.FORCE_COLOR = "0";

    const child = childProcess.spawnSync(
      process.execPath,
      [playwrightCli, "test", "--config", probeConfig, "--workers=1"],
      { cwd: guiDir, env, encoding: "utf-8", timeout: 120_000 },
    );
    const modes: Record<string, string> = {};
    for (const name of fs.readdirSync(out)) {
      if (name.endsWith(".txt")) {
        modes[name.slice(0, -".txt".length)] = fs.readFileSync(
          path.join(out, name),
          "utf-8",
        );
      }
    }
    return {
      status: child.status,
      output: `${child.stdout ?? ""}\n${child.stderr ?? ""}\n${child.error ?? ""}`,
      modes,
    };
  } finally {
    fs.rmSync(out, { recursive: true, force: true });
  }
}

test.describe("harness: CODETRACER_TEST_IN_BROWSER reaches the deploymentMode fixture", () => {
  test.setTimeout(150_000);

  test("=1: the default is web, and a per-spec choice still wins", () => {
    const run = runProbe("1");
    expect(run.status, run.output).toBe(0);
    expect(run.modes).toEqual({
      default: "web",
      "electron-override": "electron",
      "web-override": "web",
    });
  });

  test("unset: the default is electron, and a per-spec choice still wins", () => {
    const run = runProbe(undefined);
    expect(run.status, run.output).toBe(0);
    expect(run.modes).toEqual({
      default: "electron",
      "electron-override": "electron",
      "web-override": "web",
    });
  });

  test("=0: the default is electron", () => {
    const run = runProbe("0");
    expect(run.status, run.output).toBe(0);
    expect(run.modes.default).toBe("electron");
  });

  test("an invalid value fails the run with an error naming the variable", () => {
    const run = runProbe("true");
    expect(run.status, run.output).not.toBe(0);
    expect(run.output).toContain(
      `${TEST_IN_BROWSER_ENV}="true" is not a valid value`,
    );
    expect(run.modes).toEqual({});
  });
});
