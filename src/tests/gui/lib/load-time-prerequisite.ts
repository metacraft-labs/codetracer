/**
 * Resolve a prerequisite AT MODULE LOAD without letting its failure
 * delete the entire suite.
 *
 * WHAT THIS EXISTS TO STOP. Playwright collects a run by importing every
 * spec file. If any one of those imports THROWS, the run is not "that
 * file minus its tests" -- collection aborts and Playwright reports
 *
 *     Total: 0 tests in 0 files
 *
 * for the whole `testDir`. Five spec files resolved a heavy prerequisite
 * at top level -- `resolveRealVisualTracePath()`, which requires a built
 * `ct_gfx_player`, and `threeTraceRecordingRoot()`, which RECORDS the
 * cross-process demo through the real recorders -- so on any leg where
 * one of those was unavailable, all 152 spec files discovered zero tests
 * and the job's Playwright step executed nothing. Measured on
 * `origin/dev` 009ac5d9f: scoped to `tests/event-log` the suite lists 2
 * tests; unscoped it lists 0.
 *
 * That failure mode is silent in exactly the wrong way: a step that
 * exits non-zero having run nothing looks the same in a log as a step
 * that ran the suite and hit one red. The CI comment on the macOS-only
 * "Build ct_gfx_player" step already says these specs
 * `requireExecutable(...)` "at module-load time" -- the coupling was
 * known; what was not known is that the cost is the OTHER 147 files.
 *
 * WHAT THIS DOES NOT DO. It does not skip, soften or hide the failure.
 * The original error is re-thrown from a `beforeAll` registered on the
 * calling file's own `test` object, so every test in THAT file fails,
 * loudly, with the original message and stack as `cause`. The only thing
 * that changes is the blast radius: one unbuilt binary now costs the
 * tests that need it, not the run.
 *
 * A file that wants to SKIP rather than fail when a fixture is
 * unavailable already has a way to say so -- `threeTraceFixtureSkipReason()`
 * in `beforeAll`, which three of these five files already call. That path
 * was simply unreachable, because the throw happened first.
 */

/**
 * The subset of Playwright's `test` object this needs. Passed in rather
 * than imported so the helper cannot introduce an import cycle with
 * `lib/fixtures.ts`, and so the hook is registered on the SAME extended
 * `test` instance the calling file uses -- Playwright rejects hooks
 * mixed across test instances.
 */
export interface HookRegistrar {
  beforeAll(fn: () => void | Promise<void>): void;
}

/**
 * @param test        the spec file's own `test` object (from `lib/fixtures`)
 * @param description what is being resolved, for the deferred message
 * @param resolve     the load-time resolution that may throw
 * @param fallback    a value of the right shape for `test.use()` etc. to
 *                    hold until the deferred `beforeAll` fails the file
 */
export function loadTimePrerequisite<T>(
  test: HookRegistrar,
  description: string,
  resolve: () => T,
  fallback: T,
): T {
  try {
    return resolve();
  } catch (ex) {
    const original = ex instanceof Error ? ex : new Error(String(ex));
    test.beforeAll(() => {
      throw new Error(
        `unavailable at load time: ${description}\n`
          + `\n`
          + `${original.message}\n`
          + `\n`
          + `This was raised while the spec file was being imported. It is `
          + `re-thrown here so it fails the tests that need it instead of `
          + `aborting Playwright's collection of every other spec file.`,
        { cause: original },
      );
    });
    return fallback;
  }
}
