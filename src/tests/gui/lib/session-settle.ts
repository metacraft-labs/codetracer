/**
 * The capture lanes' ENTRY SETTLE: wait for the debugger session to come to
 * rest before the first sample of the program's position is taken.
 *
 * Why this exists (codetracer-pm issue
 * `2026-10-12-the-electron-capture-lanes-entry-shell-samples-the-debugger-location-before-the-session-settles.md`):
 * `plat37-electron-window-capture.spec.ts` and `visual-alignment-capture.spec.ts`
 * both read the position ONCE before the first operation and settled only per
 * operation, inside `waitForMove`. The population-control scenario,
 * `entry-shell`, has no operations by design, so nothing ever forced a settle
 * and its route record was the first read of a session still coming up:
 * `{line: 0, path: "", rrTicks: 0, busy: true}`, beside a frame that drew
 * line 1. Whether that read loses the race depends on host timing, which is
 * why the predicate below is the product's own busy flag and not an
 * operation count.
 *
 * Kept in its own module, with the state reader, the sleep and the clock
 * injected, so it can be exercised without launching Electron; see
 * `tests/harness/session-settle.spec.ts`.
 */

/**
 * The program's position as the renderer's own debugger service reports it.
 * `busy` is `window.data.status.stableBusy`; `null` means the flag is ABSENT,
 * which is not the same as "not busy" and is never treated as settled.
 */
export interface ProgramState {
  line: number;
  path: string;
  rrTicks: number;
  busy: boolean | null;
}

export interface SettleOptions {
  /** Total wait before giving up. Default 60 s, `waitForMove`'s budget. */
  budgetMs?: number;
  /** Pause between polls. Default 100 ms, `waitForMove`'s interval. */
  intervalMs?: number;
  /** Injected clock; defaults to `Date.now`. */
  now?: () => number;
  /** Names the lane in a thrown message. */
  what?: string;
}

/** The settled state plus the evidence a route record carries about it. */
export interface SettledEntry {
  /** The sample that held settled on two consecutive polls. */
  state: ProgramState;
  /** The very first read — what the pre-fix lane would have recorded. */
  firstSample: ProgramState;
  /** Reads made, including the two that agreed. */
  polls: number;
  /** Wall time from the first read to the return. */
  waitedMs: number;
}

export const formatProgramState = (s: ProgramState): string =>
  `line ${s.line} @ ticks ${s.rrTicks} in '${s.path}' (busy: ${s.busy})`;

/**
 * Why `s` is not a settled session, or `null` when it is.
 *
 * Settled means ALL of: the product says it is not busy (`busy === false`,
 * strictly — an absent flag is not an answer), it has a position
 * (`rrTicks >= 0`, `line >= 1`) and it has a source (`path !== ""`). Every
 * failing condition is named, so a timeout says which half never arrived.
 */
export function unsettledReason(s: ProgramState): string | null {
  const reasons: string[] = [];
  if (s.busy === true) {
    reasons.push("busy (window.data.status.stableBusy is true)");
  } else if (s.busy !== false) {
    reasons.push("busy flag absent (window.data.status.stableBusy is not set)");
  }
  if (s.rrTicks < 0 || s.line < 1) {
    reasons.push(`no position (line ${s.line}, rrTicks ${s.rrTicks})`);
  }
  if (s.path === "") reasons.push("no path");
  return reasons.length === 0 ? null : reasons.join("; ");
}

export function isSettled(s: ProgramState): boolean {
  return unsettledReason(s) === null;
}

const samePosition = (a: ProgramState, b: ProgramState): boolean =>
  a.line === b.line && a.path === b.path && a.rrTicks === b.rrTicks;

/**
 * Poll `read` until the session is settled on TWO CONSECUTIVE reads at the
 * same (line, path, rrTicks), and return that state with the evidence.
 *
 * Two reads, because a session finishing its start-up can report `busy:
 * false` at an intermediate stop and then move on; taking the first settled
 * read would trade one race for another. Bounded: on timeout this THROWS,
 * naming the last sample and why it is unsettled. It never returns an
 * unsettled sample.
 */
export async function awaitSettledEntry(
  read: () => Promise<ProgramState>,
  sleep: (ms: number) => Promise<void>,
  opts: SettleOptions = {},
): Promise<SettledEntry> {
  const budgetMs = opts.budgetMs ?? 60_000;
  const intervalMs = opts.intervalMs ?? 100;
  const now = opts.now ?? Date.now;
  const what = opts.what ?? "the capture lane";
  const t0 = now();
  let polls = 0;
  let firstSample: ProgramState | null = null;
  let previous: ProgramState | null = null;
  for (;;) {
    const sample = await read();
    polls++;
    firstSample ??= sample;
    if (
      previous !== null &&
      isSettled(previous) &&
      isSettled(sample) &&
      samePosition(previous, sample)
    ) {
      return { state: sample, firstSample, polls, waitedMs: now() - t0 };
    }
    previous = sample;
    if (now() - t0 >= budgetMs) {
      throw settleTimeout({
        what,
        budgetMs,
        polls,
        last: sample,
        first: firstSample,
      });
    }
    await sleep(intervalMs);
  }
}

/** The bounded wait's failure: the last sample, and why it is unsettled. */
function settleTimeout({
  what,
  budgetMs,
  polls,
  last,
  first,
}: {
  what: string;
  budgetMs: number;
  polls: number;
  last: ProgramState;
  first: ProgramState;
}): Error {
  const reason =
    unsettledReason(last) ??
    "still moving (settled reads never agreed twice in a row)";
  return new Error(
    `${what}: the debugger session did not settle within ${budgetMs}ms ` +
      `(${polls} polls). Last sample: ${formatProgramState(last)}; ` +
      `unsettled because: ${reason}. First sample: ` +
      `${formatProgramState(first)}. Sampling it anyway is how ` +
      `entry-shell recorded line 0 beside a frame that drew line 1.`,
  );
}

/**
 * A FINAL SAMPLE TAKEN UNSETTLED IS A LANE FAILURE, NOT A RECORDED VALUE.
 *
 * Called on the state a lane is about to write as its answer. A busy sample
 * is the lane saying it measured too early; writing it into an artefact as
 * though it were an answer is what let a wrong line sit beside five right
 * ones. Covers paths that read without waiting, e.g. `setBreakpoint`'s
 * non-effect check.
 */
export function assertSampledSettled(s: ProgramState, what: string): void {
  const reason = unsettledReason(s);
  if (reason !== null) {
    throw new Error(
      `${what}: the final program state was sampled unsettled — ${reason}: ` +
        `${formatProgramState(s)}. A lane that samples a session still ` +
        `starting up or still moving must fail rather than record it.`,
    );
  }
}

/**
 * `editorSettledBetweenOperations` as a route record reports it: `null` when
 * the scenario performed no operations, because "settled between operations"
 * is vacuously true over none and a vacuous `true` reads as green.
 */
export function settledBetweenOperations(
  moves: number,
  settled: boolean,
): boolean | null {
  return moves === 0 ? null : settled;
}
