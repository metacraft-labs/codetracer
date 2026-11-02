/* eslint-disable @typescript-eslint/no-magic-numbers -- the bounds and lengths are the subject */

/**
 * Self-test for the GUI fixtures' `CODETRACER_HOME`: it is short enough for
 * every Unix socket the product binds under it (`lib/socket-path-bound.ts`).
 *
 * The property: the per-worker home `lib/fixtures.ts` hands every CodeTracer
 * it launches leaves room, under `sockaddr_un.sun_path`, for the longest
 * socket path the product derives from it (a replay's,
 * `<home>/tmp/session-manager/<pid>/<id>.sock`). When the home was made in
 * macOS's default `TMPDIR` it did not: the session manager refused the
 * socket and every Electron spec drove a product with no replay backend, or
 * waited for a session manager that had already exited. The other cases pin
 * the bound itself and the refusal's wording, which must name the path, its
 * length and the limit.
 *
 * No mocks and no Electron: the first case reads the home the real fixture
 * module chose when it was imported (it sets `CODETRACER_HOME` at import,
 * for the whole worker), the rest call the bound with literal paths.
 */

import { test, expect } from "@playwright/test";
import * as fs from "node:fs";
import * as path from "node:path";

// Imported for its import-time effect: the worker's scratch homes.
import "../../lib/fixtures";
import {
  assertHomeFitsSocketBound,
  longestSocketPathUnder,
  maxUnixSocketPathBytes,
  scratchBase,
  socketBoundViolation,
} from "../../lib/socket-path-bound";

/** A home whose longest socket path is exactly `length` bytes on `platform`. */
function homeWithSocketPathOf(length: number, platform: NodeJS.Platform): string {
  const tail = longestSocketPathUnder("/h", platform).length - "/h".length;
  const home = "/" + "h".repeat(length - tail - 1);
  expect(longestSocketPathUnder(home, platform).length).toBe(length);
  return home;
}

test.describe("harness: CODETRACER_HOME fits the Unix socket bound", () => {
  test("the fixture's per-worker home leaves room for every socket under it", () => {
    const home = process.env.CODETRACER_HOME ?? "";
    expect(home.length, "lib/fixtures.ts set no CODETRACER_HOME").toBeGreaterThan(0);
    expect(fs.existsSync(home), `the fixture's home ${home} does not exist`).toBe(true);
    // `undefined`, or the refusal naming the path, its length and the limit.
    expect(socketBoundViolation(home, "lib/fixtures.ts")).toBeUndefined();
    if (process.platform !== "win32" && process.env.CODETRACER_GUI_TEST_CODETRACER_HOME === undefined) {
      expect(path.dirname(home)).toBe(scratchBase());
    }
  });

  test("the bound is sun_path less its NUL, and Windows has none", () => {
    expect(maxUnixSocketPathBytes("darwin")).toBe(103);
    expect(maxUnixSocketPathBytes("freebsd")).toBe(103);
    expect(maxUnixSocketPathBytes("linux")).toBe(107);
    expect(maxUnixSocketPathBytes("win32")).toBeUndefined();
    expect(socketBoundViolation("C:\\" + "x".repeat(300), "a test", "win32")).toBeUndefined();
    expect(scratchBase("darwin")).toBe("/tmp");
    expect(scratchBase("linux")).toBe("/tmp");
  });

  test("the longest socket path is a replay's, with the largest pid", () => {
    expect(longestSocketPathUnder("/tmp/h", "darwin")).toBe(
      "/tmp/h/tmp/session-manager/99999/9999.sock",
    );
    expect(longestSocketPathUnder("/tmp/h", "linux")).toBe(
      "/tmp/h/tmp/session-manager/9999999/9999.sock",
    );
  });

  for (const platform of ["darwin", "linux"] as NodeJS.Platform[]) {
    test(`on ${platform} a home is refused one byte past the bound, naming it`, () => {
      const max = maxUnixSocketPathBytes(platform) ?? 0;
      const fits = homeWithSocketPathOf(max, platform);
      expect(socketBoundViolation(fits, "a test", platform)).toBeUndefined();
      expect(() => {
        assertHomeFitsSocketBound(fits, "a test", platform);
      }).not.toThrow();

      const tooLong = homeWithSocketPathOf(max + 1, platform);
      const violation = socketBoundViolation(tooLong, "CODETRACER_GUI_TEST_CODETRACER_HOME", platform) ?? "";
      expect(violation).toContain(longestSocketPathUnder(tooLong, platform));
      expect(violation).toContain(`is ${max + 1} bytes`);
      expect(violation).toContain(`holds ${max} on ${platform}`);
      expect(violation).toContain("sun_path");
      expect(violation).toContain("CODETRACER_GUI_TEST_CODETRACER_HOME");
      expect(violation).toContain(`at most ${fits.length} bytes`);
      expect(() => {
        assertHomeFitsSocketBound(tooLong, "a test", platform);
      }).toThrow(violation.slice(0, 40));
    });
  }

  test("the home's real path is measured too", () => {
    test.skip(process.platform === "win32", "Windows binds no Unix socket");
    const max = maxUnixSocketPathBytes() ?? 0;
    const root = fs.mkdtempSync(path.join(scratchBase(), "ct-sb-"));
    try {
      // A short link to a deep directory: the link fits, the target does not.
      const deep = path.join(root, "d".repeat(Math.max(1, max - root.length - 20)));
      fs.mkdirSync(deep);
      const link = path.join(root, "l");
      fs.symlinkSync(deep, link);
      expect(longestSocketPathUnder(link).length).toBeLessThanOrEqual(max);
      expect(socketBoundViolation(link, "a test") ?? "").toContain(fs.realpathSync(deep));
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});
