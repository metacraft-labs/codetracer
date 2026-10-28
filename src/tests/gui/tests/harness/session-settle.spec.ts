/**
 * Self-test for the capture lanes' entry settle, `lib/session-settle.ts`.
 *
 * The defect this pins (codetracer-pm issue
 * `2026-10-12-the-electron-capture-lanes-entry-shell-samples-the-debugger-location-before-the-session-settles.md`):
 * both capture lanes' `drive()` read the program's position ONCE before the
 * first operation, checked only `rrTicks >= 0`, and settled afterwards only
 * per operation. `entry-shell` has no operations, so its route record was that
 * one early read — `{line: 0, path: "", rrTicks: 0, busy: true}` — beside a
 * frame that showed line 1. And `editorSettledBetweenOperations: true` sat
 * next to it, vacuously true over zero operations.
 *
 * WHY THE STATE READER IS SCRIPTED, NOT THE REAL APP. The defect is a race
 * between the product's session start-up and the lane's first read, and its
 * outcome depends on host timing: a 2026-10-18 run of the same lane on the
 * same host sampled `entry=1@1, busy:false`, the 2026-10-12 run sampled
 * `entry=0@0, busy:true`. Launching Electron cannot force the losing
 * interleaving deterministically, so a test against the real app would pass
 * or fail by luck. The scripted reader replays the exact sample sequence the
 * failing run produced (busy, no path, line 0, then the settled entry), and
 * the injected clock and sleep let the bounded wait run to its deadline in
 * milliseconds. Everything else is the production code the lanes call.
 *
 * Pure functions only — no Electron, no app.
 */

import { test, expect } from "@playwright/test";
import {
  type ProgramState,
  awaitSettledEntry,
  assertSampledSettled,
  isSettled,
  settledBetweenOperations,
  unsettledReason,
} from "../../lib/session-settle";

/** What the 2026-10-12 run recorded for `entry-shell`. */
const STARTING_UP: ProgramState = {
  line: 0,
  path: "",
  rrTicks: 0,
  busy: true,
};
/** What the session holds once it has settled on `calc`'s entry. */
const ENTRY: ProgramState = {
  line: 1,
  path: "/recordings/calc/main.py",
  rrTicks: 1,
  busy: false,
};

interface ScriptedSession {
  reads: number;
  read: () => Promise<ProgramState>;
  sleep: (ms: number) => Promise<void>;
  now: () => number;
}

/**
 * A reader that returns `samples` in order and then repeats the last one,
 * plus a fake clock that only `sleep` advances. Counts reads so a test can
 * see how many polls were made.
 */
function scripted(samples: readonly ProgramState[]): ScriptedSession {
  let index = 0;
  let clock = 0;
  const harness: ScriptedSession = {
    reads: 0,
    read: async (): Promise<ProgramState> => {
      harness.reads++;
      const s = samples[Math.min(index, samples.length - 1)];
      index++;
      return { ...s };
    },
    sleep: async (ms: number): Promise<void> => {
      clock += ms;
    },
    now: (): number => clock,
  };
  return harness;
}

test.describe("harness: capture-lane entry settle", () => {
  test("(a) the issue's sequence returns the settled entry, not the busy first read", async () => {
    const h = scripted([
      STARTING_UP,
      STARTING_UP,
      STARTING_UP,
      STARTING_UP,
      ENTRY,
      ENTRY,
    ]);

    const got = await awaitSettledEntry(h.read, h.sleep, { now: h.now });

    expect(got.state).toEqual(ENTRY);
    expect(got.state.busy).toBe(false);
    expect(got.state.line).toBeGreaterThanOrEqual(1);
    // The evidence a route record carries: the race WOULD have happened.
    expect(got.firstSample).toEqual(STARTING_UP);
    expect(got.polls).toBe(6);
    expect(got.waitedMs).toBeGreaterThan(0);
  });

  test("an already-settled session still needs two identical reads", async () => {
    const h = scripted([ENTRY]);
    const got = await awaitSettledEntry(h.read, h.sleep, { now: h.now });
    expect(got.state).toEqual(ENTRY);
    expect(got.firstSample).toEqual(ENTRY);
    expect(got.polls).toBe(2);
  });

  test("(b) a session that never settles throws, naming busy", async () => {
    const h = scripted([STARTING_UP]);
    await expect(
      awaitSettledEntry(h.read, h.sleep, { now: h.now, budgetMs: 5_000 }),
    ).rejects.toThrow(/busy/);
    // Bounded: it polled until the budget, not forever.
    expect(h.now()).toBeGreaterThanOrEqual(5_000);
    expect(h.reads).toBeLessThan(200);
  });

  test("(c) an absent busy flag is NOT settled", async () => {
    const flagAbsent: ProgramState = { ...ENTRY, busy: null };
    expect(isSettled(flagAbsent)).toBe(false);
    expect(unsettledReason(flagAbsent)).toMatch(/busy flag absent/);
    const h = scripted([flagAbsent]);
    await expect(
      awaitSettledEntry(h.read, h.sleep, { now: h.now, budgetMs: 2_000 }),
    ).rejects.toThrow(/busy flag absent/);
  });

  test("(d) busy:false without a position or a path is not settled", () => {
    expect(unsettledReason({ ...ENTRY, rrTicks: -1 })).toMatch(/no position/);
    expect(unsettledReason({ ...ENTRY, line: 0 })).toMatch(/no position/);
    expect(unsettledReason({ ...ENTRY, path: "" })).toMatch(/no path/);
    expect(unsettledReason(ENTRY)).toBeNull();
    expect(isSettled(ENTRY)).toBe(true);
  });

  test("(d') a reader stuck without a path throws, naming the last sample", async () => {
    const h = scripted([{ ...ENTRY, path: "" }]);
    await expect(
      awaitSettledEntry(h.read, h.sleep, { now: h.now, budgetMs: 2_000 }),
    ).rejects.toThrow(/no path.*line 1 @ ticks 1|line 1 @ ticks 1.*no path/s);
  });

  test("(e) a location that is still moving is not taken", async () => {
    const moved: ProgramState = { ...ENTRY, line: 4, rrTicks: 2 };
    const h = scripted([STARTING_UP, ENTRY, moved, moved]);

    const got = await awaitSettledEntry(h.read, h.sleep, { now: h.now });

    expect(got.state).toEqual(moved);
    expect(got.polls).toBe(4);
  });

  test("(f) settledBetweenOperations is null over zero operations", () => {
    expect(settledBetweenOperations(0, true)).toBeNull();
    expect(settledBetweenOperations(0, false)).toBeNull();
    expect(settledBetweenOperations(5, true)).toBe(true);
    expect(settledBetweenOperations(5, false)).toBe(false);
  });

  test("(g) a final sample taken busy is a failure, not a value", () => {
    expect(() => {
      assertSampledSettled(STARTING_UP, "entry-shell");
    }).toThrow(/entry-shell.*busy/s);
    expect(() => {
      assertSampledSettled({ ...ENTRY, busy: null }, "entry-shell");
    }).toThrow(/busy flag absent/);
    expect(() => {
      assertSampledSettled(ENTRY, "entry-shell");
    }).not.toThrow();
  });
});
