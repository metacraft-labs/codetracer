/**
 * Load the real fixtures in the collector and worker, including imports whose
 * test uses base Playwright and never runs the fixtures' worker teardown.
 * The finally block also records a partial setup rejected by the socket bound.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { test as baseTest, expect } from "@playwright/test";

const out = process.env.CT_FIXTURE_HOME_PROBE_OUT;
if (!out) throw new Error("CT_FIXTURE_HOME_PROBE_OUT is required");

const fixtureTest = (() => {
  try {
    return (require("../../../lib/fixtures") as typeof import("../../../lib/fixtures")).test;
  } finally {
    const home = process.env.CODETRACER_HOME;
    const xdg = process.env.XDG_CONFIG_HOME;
    fs.writeFileSync(path.join(out, `${process.pid}.json`), JSON.stringify({
      pid: process.pid,
      home,
      xdg,
      homeExists: home !== undefined && fs.existsSync(home),
      xdgExists: xdg !== undefined && fs.existsSync(xdg),
      markerExists: home !== undefined && fs.existsSync(path.join(home, ".codetracer-test-home")),
    }));
  }
})();

const test = process.env.CT_FIXTURE_HOME_PROBE_BASE === "1" ? baseTest : fixtureTest;
test("fixture home lifecycle probe", () => {
  // Import-time snapshots alone cannot detect cleanup that runs too early.
  // Both test bindings must retain the same live isolation through execution.
  const imported = JSON.parse(fs.readFileSync(path.join(out, `${process.pid}.json`), "utf8")) as {
    home: string;
    xdg: string;
    markerExists: boolean;
  };
  const home = process.env.CODETRACER_HOME;
  const xdg = process.env.XDG_CONFIG_HOME;
  expect(home).toBe(imported.home);
  expect(xdg).toBe(imported.xdg);
  if (!home || !xdg) throw new Error("fixtures must keep both homes set while tests run");
  expect(fs.existsSync(home), "CODETRACER_HOME must stay alive during the test").toBe(true);
  expect(fs.existsSync(xdg), "XDG_CONFIG_HOME must stay alive during the test").toBe(true);
  expect(fs.existsSync(path.join(home, ".codetracer-test-home"))).toBe(imported.markerExists);
  fs.writeFileSync(path.join(out, `${process.pid}.ran`), "ran");
  expect(process.env.CT_FIXTURE_HOME_PROBE_FAIL, "deliberate lifecycle probe failure").not.toBe("1");
});
