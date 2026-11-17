/** Every synchronous child a GUI test starts ends before the test does
 * (lib/sync-child-timeout.ts, installed by playwright.config.ts in every
 * worker).
 *
 * Real children, no mocks: `sleep 600` stands for a tool that hangs (on
 * 2026-11-13 `dotnet --version` deadlocked and held two full-suite runs for
 * 1.5 hours). The test's own timeout is short; the call must come back with
 * an error naming the command well before it, which is only possible if the
 * worker's `child_process` was wrapped. A positive control shows a call that
 * names its own timeout keeps Node's behaviour (a status, not a throw).
 */
import { test, expect } from "@playwright/test";
import * as childProcess from "node:child_process";

test.describe("synchronous children are bounded by the test", () => {
  for (const [name, run] of [
    ["spawnSync", () => childProcess.spawnSync("sleep", ["600"])],
    ["execSync", () => childProcess.execSync("sleep 600")],
    ["execFileSync", () => childProcess.execFileSync("sleep", ["600"])],
  ] as const) {
    test(`${name} of a hung tool ends, with a named error, before the test`, () => {
      test.setTimeout(10_000);
      const started = Date.now();
      expect(run).toThrow(/`sleep( 600)?` did not finish within \d+ ms and was killed/);
      const took = Date.now() - started;
      // The bound is the time left less a 5 s margin: about 5 s here, and
      // well before the test's 10 s.
      expect(took).toBeGreaterThan(3_000);
      expect(took).toBeLessThan(9_000);
    });
  }

  test("a call that names its own timeout keeps Node's behaviour", () => {
    test.setTimeout(30_000);
    const started = Date.now();
    const result = childProcess.spawnSync("sleep", ["600"], { timeout: 500 });
    expect(Date.now() - started).toBeLessThan(10_000);
    expect((result.error as NodeJS.ErrnoException | undefined)?.code).toBe("ETIMEDOUT");
    expect(result.signal).toBe("SIGTERM");
  });
});
