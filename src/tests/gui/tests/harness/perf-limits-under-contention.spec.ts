/**
 * Self-test for `lib/performance-limits.timed`: a performance limit's verdict
 * must depend on the work under test, not on the host's load.
 *
 * Why: `timed` graded raw wall clock, so on the shared host at load average
 * 33-48 a clean tree failed its own `tests/build/` specs on `first window`
 * (10.3 s against 10 s) and `base components loaded` (61 s against 45 s) —
 * codetracer-pm issue
 * `2026-10-17-electron-build-specs-fail-on-clean-agents-under-host-load`.
 *
 * How the load is produced without disturbing anyone else on the host: the
 * subject and a few busy-loop "neighbours" are pinned with `taskset` to ONE
 * CPU, so the subject gets a fraction of it and its wall clock stretches by
 * the number of runnable tasks sharing it — what a loaded host does, on a
 * single core. The neighbours are deliberately NOT descendants of this
 * process (they are orphaned at spawn), exactly as the other tenants of a
 * loaded host are not descendants of the test runner.
 *
 * The pair of assertions that matters:
 *  - a fixed amount of work, slowed only by the neighbours, passes a limit its
 *    stretched wall clock exceeds (the defect: it used to fail);
 *  - FOUR TIMES that work, on the same CPU, still fails the same limit with
 *    and without neighbours — the adjustment forgives waiting, not work.
 *
 * No mocks: real processes, real kernel scheduler accounting. Linux only —
 * elsewhere `timed` keeps grading wall clock, which the last test pins.
 */

import { test, expect } from "@playwright/test";
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import { timed } from "../../lib/performance-limits";
import {
  contentionAdjustedMs,
  contentionBetween,
  sampleProcessTree,
} from "../../lib/process-contention";

/**
 * The factor `timed` multiplies every limit by, read the way
 * `lib/performance-limits.ts` reads it, so this test's effective limits do not
 * depend on whether the lane sets `CODETRACER_PERF_LIMIT_SCALE`.
 */
const PERF_LIMIT_SCALE = (() => {
  const v = Number(process.env.CODETRACER_PERF_LIMIT_SCALE ?? "1");
  return Number.isFinite(v) && v >= 1 ? v : 1;
})();

/** Runnable neighbours sharing the subject's CPU: a ~4x wall-clock stretch. */
const NEIGHBOURS = 3;

/** The CPU everything is pinned to: the highest one this process may use. */
function pinnedCpu(): number {
  const status = fs.readFileSync("/proc/self/status", "utf8");
  const list = /^Cpus_allowed_list:\s*(.+)$/m.exec(status)?.[1] ?? "0";
  const cpus = list.split(",").flatMap((range) => {
    const [lo, hi] = range.split("-").map(Number);
    return hi === undefined ? [lo] : Array.from({ length: hi - lo + 1 }, (_, i) => lo + i);
  });
  return Math.max(...cpus);
}

/**
 * A pinned node process that does `iterations` of arithmetic, prints `done`
 * and then stays alive (sleeping, not spinning) until killed — the shape of
 * an Electron launch, whose processes are still running when the operation
 * being timed completes.
 */
async function runPinnedWork(cpu: number, iterations: number): Promise<{ wallMs: number; kill: () => void }> {
  const script =
    `let x = 0; for (let i = 0; i < ${iterations}; i++) x += Math.sqrt(i);` +
    `process.stdout.write("done " + (x > 0) + "\\n"); setInterval(() => {}, 1 << 30);`;
  const child = childProcess.spawn("taskset", ["-c", String(cpu), process.execPath, "-e", script], {
    stdio: ["ignore", "pipe", "inherit"],
  });
  const t0 = Date.now();
  await new Promise<void>((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", (code) => reject(new Error(`subject exited early (code ${code})`)));
    child.stdout!.on("data", (chunk: Buffer) => {
      if (chunk.toString().includes("done")) resolve();
    });
  });
  const wallMs = Date.now() - t0;
  return { wallMs, kill: () => child.kill("SIGKILL") };
}

/**
 * The contention-adjusted duration of one pinned run, which is killed after.
 */
async function uncontendedMs(
  run: () => Promise<{ wallMs: number; kill: () => void }>,
): Promise<number> {
  const before = sampleProcessTree();
  const r = await run();
  const c = contentionBetween(before, sampleProcessTree());
  r.kill();
  return contentionAdjustedMs(r.wallMs, c);
}

/**
 * Start `count` busy loops pinned to `cpu` that are NOT our descendants:
 * `sh` backgrounds each one and exits, so the kernel reparents it away.
 */
function startNeighbours(cpu: number, count: number): number[] {
  const pids: number[] = [];
  for (let i = 0; i < count; i++) {
    const out = childProcess.execFileSync("sh", [
      "-c",
      `taskset -c ${cpu} "${process.execPath}" -e 'for(;;){}' </dev/null >/dev/null 2>&1 & echo $!`,
    ]);
    pids.push(Number(out.toString().trim()));
  }
  return pids;
}

function stopNeighbours(pids: number[]): void {
  for (const pid of pids) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      /* already gone */
    }
  }
}

test.describe("harness: performance limits under host contention", () => {
  test.skip(process.platform !== "linux", "schedstat accounting is Linux-only");
  test.setTimeout(180_000);

  test("contention stretches wall clock but not the graded duration; extra work still fails", async () => {
    const cpu = pinnedCpu();
    // Calibrate the work so that, alone on the CPU, it takes ~600 ms. The
    // host may itself be loaded, so the calibration runs are graded the way
    // `timed` grades (run-queue wait taken out): a baseline inflated by other
    // tenants would raise the limit and let the 4x cases below slip under it.
    let iterations = 20_000_000;
    {
      const probe = await uncontendedMs(() => runPinnedWork(cpu, iterations));
      iterations = Math.max(1_000_000, Math.round((iterations * 600) / Math.max(1, probe)));
    }
    const baseMs = Math.round(await uncontendedMs(() => runPinnedWork(cpu, iterations)));
    // A limit twice what the work needs alone. The raw value handed to `timed`
    // is divided by the scale `timed` multiplies it by, so the effective limit
    // is this regardless of `CODETRACER_PERF_LIMIT_SCALE`.
    const limitMs = 2 * baseMs;
    const rawLimit = limitMs / PERF_LIMIT_SCALE;
    console.log(`# cpu ${cpu}, ${iterations} iterations, alone ${baseMs} ms, limit ${limitMs} ms`);

    const neighbours = startNeighbours(cpu, NEIGHBOURS);
    const kills: Array<() => void> = [];
    try {
      // 1. The same work among neighbours: wall clock well over the limit...
      let contendedWallMs = 0;
      await timed("work among neighbours", rawLimit, async () => {
        const run = await runPinnedWork(cpu, iterations);
        kills.push(run.kill);
        contendedWallMs = run.wallMs;
      });
      // ...which is what makes step 1 a test of the defect and not a no-op.
      expect(contendedWallMs, "the neighbours must actually stretch the wall clock past the limit").toBeGreaterThan(limitMs);

      // 2. Four times the work among the same neighbours: still a failure.
      await expect(
        timed("4x work among neighbours", rawLimit, async () => {
          const run = await runPinnedWork(cpu, 4 * iterations);
          kills.push(run.kill);
        }),
      ).rejects.toThrow(/Performance limit exceeded: "4x work among neighbours"/);
    } finally {
      stopNeighbours(neighbours);
      for (const kill of kills) kill();
    }

    // 3. Four times the work alone: a failure, graded exactly as wall clock.
    try {
      await expect(
        timed("4x work alone", rawLimit, async () => {
          const run = await runPinnedWork(cpu, 4 * iterations);
          kills.push(run.kill);
        }),
      ).rejects.toThrow(/Performance limit exceeded: "4x work alone"/);
    } finally {
      for (const kill of kills) kill();
    }
  });

  test("the adjustment never takes off more than the measured wait", () => {
    for (const [wall, cpu, wait] of [[1000, 10, 5], [1000, 100, 50], [1000, 3000, 9000], [500, 0, 400]]) {
      const graded = contentionAdjustedMs(wall, { supported: true, cpuMs: cpu, waitMs: wait });
      expect(graded).toBeGreaterThanOrEqual(wall - wait);
      expect(graded).toBeLessThanOrEqual(wall);
    }
  });

  test("a thread without a baseline counts only if it started inside the interval", () => {
    const t = (cpuNs: number, waitNs: number, startTicks: number) => ({ cpuNs, waitNs, startTicks });
    const before = {
      supported: true,
      takenAtTicks: 1000,
      threads: new Map([
        ["10/10/500", t(5e9, 1e9, 500)],
        ["10/11/600", t(1e9, 1e9, 600)],
      ]),
    };
    const after = {
      supported: true,
      takenAtTicks: 1100,
      threads: new Map([
        // Seen in both: only the growth counts.
        ["10/10/500", t(6e9, 3e9, 500)],
        // tid 11 reused by a thread that started inside the interval: new.
        ["10/11/1050", t(1e8, 2e8, 1050)],
        // Started long before the interval but missing from `before`: its
        // lifetime totals would credit wait from outside the interval.
        ["20/20/100", t(50e9, 90e9, 100)],
      ]),
    };
    const c = contentionBetween(before, after);
    expect(c.cpuMs).toBeCloseTo(1000 + 100);
    expect(c.waitMs).toBeCloseTo(2000 + 200);
  });

  test("the adjustment is the identity without run-queue wait", () => {
    expect(contentionAdjustedMs(1234, { supported: true, cpuMs: 900, waitMs: 0 })).toBe(1234);
    expect(contentionAdjustedMs(1234, { supported: false, cpuMs: 0, waitMs: 0 })).toBe(1234);
    expect(contentionAdjustedMs(1234, { supported: true, cpuMs: 0, waitMs: 0 })).toBe(1234);
  });

  test("the adjustment takes the larger of the serial and parallel estimates", () => {
    // One thread: 3 s on CPU, 1 s waiting, 1 s asleep. Serial is exact (4 s).
    expect(contentionAdjustedMs(5000, { supported: true, cpuMs: 3000, waitMs: 1000 })).toBe(4000);
    // Four threads each 1 s on CPU and 3 s waiting in a 4 s interval: every
    // one was slowed 4x, so the work alone takes 1 s. Serial is negative.
    expect(contentionAdjustedMs(4000, { supported: true, cpuMs: 4000, waitMs: 12000 })).toBe(1000);
  });

  test("a sample of this process sees its own threads", () => {
    const before = sampleProcessTree();
    let x = 0;
    const until = Date.now() + 50;
    while (Date.now() < until) x += Math.sqrt(x + 1);
    const c = contentionBetween(before, sampleProcessTree());
    expect(c.supported).toBe(true);
    expect(c.cpuMs).toBeGreaterThan(20);
    expect(x).toBeGreaterThan(0);
  });
});
