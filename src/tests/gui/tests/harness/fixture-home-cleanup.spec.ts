/**
 * Real Playwright subprocesses and real directories, with no mocks or product
 * build. Record the exact homes while each collector/worker is alive, then
 * check those paths after it exits. A host-wide /tmp census would confuse
 * concurrent runs with this test's own resources. The finally block removes
 * only this probe's homes, including when the regression is run against a leak.
 */
import { test, expect } from "@playwright/test";
import * as fs from "node:fs";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { scratchBase } from "../../lib/socket-path-bound";

interface Snapshot {
  pid: number;
  home?: string;
  xdg: string;
  homeExists: boolean;
  xdgExists: boolean;
  markerExists: boolean;
}

interface Options {
  base?: boolean;
  fail?: boolean;
  list?: boolean;
  overrides?: boolean;
  rejectHome?: boolean;
}

function probe(options: Options): void {
  const root = fs.mkdtempSync(path.join(scratchBase(), "ct-gh-"));
  const snapshots: Snapshot[] = [];
  const env = { ...process.env };
  // Start an independent run, without the parent's Playwright worker identity
  // or its own isolation overrides. No test launches ct or Electron.
  for (const key of Object.keys(env)) {
    if (key.startsWith("PW_") || key.startsWith("TEST_") || [
      "CODETRACER_HOME", "XDG_CONFIG_HOME", "PLAYWRIGHT_RETRIES",
      "CODETRACER_GUI_TEST_CODETRACER_HOME", "CODETRACER_GUI_TEST_XDG_CONFIG_HOME",
    ].includes(key)) delete env[key];
  }
  env.CT_FIXTURE_HOME_PROBE_OUT = root;
  env.CT_FIXTURE_HOME_PROBE_BASE = options.base ? "1" : "0";
  env.CT_FIXTURE_HOME_PROBE_FAIL = options.fail ? "1" : "0";
  env.FORCE_COLOR = "0";
  const overrideHome = path.join(root, options.rejectHome ? "deep-".repeat(30) : "home");
  const overrideXdg = path.join(root, "xdg");
  if (options.overrides || options.rejectHome) {
    fs.mkdirSync(overrideHome);
    env.CODETRACER_GUI_TEST_CODETRACER_HOME = overrideHome;
  }
  if (options.overrides) {
    fs.mkdirSync(overrideXdg);
    env.CODETRACER_GUI_TEST_XDG_CONFIG_HOME = overrideXdg;
  }
  try {
    const child = spawnSync(process.execPath, [
      require.resolve("@playwright/test/cli"), "test", "--config",
      path.join(__dirname, "fixture-home-probe", "probe.config.ts"),
      "--workers=1", ...(options.list ? ["--list"] : []),
    ], { cwd: path.resolve(__dirname, "../.."), env, encoding: "utf8" });
    const output = `${child.stdout}\n${child.stderr}`;
    for (const file of fs.readdirSync(root).filter((name) => /^\d+\.json$/.test(name))) {
      snapshots.push(JSON.parse(fs.readFileSync(path.join(root, file), "utf8")) as Snapshot);
    }
    expect(child.error, output).toBeUndefined();
    expect(child.status, output).toBe(options.fail || options.rejectHome ? 1 : 0);
    expect(snapshots.length, output).toBe(options.list || options.rejectHome ? 1 : 2);
    const ran = fs.readdirSync(root).filter((name) => name.endsWith(".ran"));
    expect(ran.length, output).toBe(options.list || options.rejectHome ? 0 : 1);
    if (options.rejectHome) expect(output).toContain("sun_path");
    if (options.fail) expect(output).toContain("deliberate lifecycle probe failure");
    for (const snapshot of snapshots) {
      expect(snapshot.xdgExists, JSON.stringify(snapshot)).toBe(true);
      expect(fs.existsSync(snapshot.xdg), `leaked XDG_CONFIG_HOME: ${snapshot.xdg}`).toBe(!!options.overrides);
      if (!options.rejectHome) {
        expect(snapshot.homeExists, JSON.stringify(snapshot)).toBe(true);
        expect(snapshot.markerExists).toBe(!options.overrides);
        expect(snapshot.home).toBeDefined();
        expect(fs.existsSync(snapshot.home!), `leaked CODETRACER_HOME: ${snapshot.home}`).toBe(!!options.overrides);
      }
      if (options.overrides) {
        expect(snapshot.home).toBe(overrideHome);
        expect(snapshot.xdg).toBe(overrideXdg);
      }
    }
  } finally {
    for (const snapshot of snapshots) {
      if (!options.overrides) {
        fs.rmSync(snapshot.xdg, { recursive: true, force: true });
        if (snapshot.home) fs.rmSync(snapshot.home, { recursive: true, force: true });
      }
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test.describe("harness: owned GUI homes are removed in every importing process", () => {
  test.setTimeout(0);
  test("a base Playwright test never runs worker cleanup", () => probe({ base: true }));
  test("the fixture-aware runner and worker both clean up", () => probe({}));
  test("a failed test still cleans up", () => probe({ fail: true }));
  test("listing tests cleans up without starting a worker", () => probe({ list: true }));
  test("caller-owned override homes are preserved", () => probe({ overrides: true }));
  test("socket-bound setup rejection removes the already-created XDG home", () => {
    test.skip(process.platform === "win32", "Windows has no Unix socket bound");
    probe({ rejectHome: true });
  });
});
