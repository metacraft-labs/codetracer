/**
 * `e2e_in_app_apply_edit_triggers_hcr_reload` — the GUI half.
 *
 * Milestone: `codetracer-specs/Marketing/Home-Demo-Screencast.milestones.org`, H4.
 * Command:   `codetracer-flame-demo/scripts/ct_hcr_apply_edit.py`
 * Document:  `codetracer-flame-demo/docs/In-App-Apply-Edit-Command.md`
 *
 * Two claims, and each is asserted against a different thing:
 *
 *   1. THE COMMAND IS SURFACED. "Apply Edit & Hot-Reload" is findable and
 *      clickable in the command palette, which the product builds by walking
 *      its own menu tree — so this also asserts the Build-menu entry, since
 *      there is one declaration behind both.
 *
 *   2. INVOKING IT HOT-RELOADS THE RUNNING FLAME. The UI action is the only
 *      thing in this test that publishes anything; the verdict is the flame
 *      demo's own frame-for-frame comparison of the patched run against a
 *      control run with no agent attached, graded on the magnitude the edit
 *      predicts. **The UI's own "applied" notification is asserted too, but it
 *      is not the verdict** — the agent reports `patchApplied` for a body that
 *      changes nothing, which is exactly what the headless sweep's
 *      `F1-noop-edit` arm demonstrates.
 *
 * The third claim — that a REFUSAL reaches the screen by name — is in
 * `apply_edit_unconfigured.spec.ts`, for the environment reason noted below.
 *
 * GATED, and it skips LOUDLY: it needs a patchable Godot engine, the patchable
 * GDExtension, an imported project and a prebuilt coordinator driver, and it
 * names whichever is missing rather than passing quietly without it.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  EDIT,
  MARKER,
  PATCH_AT,
  resolveFlamePaths,
  runFlame,
  runVerdict,
  waitForFile,
  type FlamePaths,
} from "./flame-hcr-driver";

const CODETRACER_REPO = path.resolve(__dirname, "../../../../..");
const PY_PROGRAM = "py_console_logs/main.py";

// The environment is prepared at MODULE SCOPE because `makeCleanEnv` in
// lib/fixtures.ts copies `process.env` into the Electron launch, and the
// `ctPage` fixture launches before a test body runs.
const resolved = resolveFlamePaths(CODETRACER_REPO);
const flameUnavailable = typeof resolved === "string" ? resolved : null;
const flame = typeof resolved === "string" ? null : (resolved as FlamePaths);

// Artifacts go under the flame demo's own `artifacts/`, in a directory named
// after THIS recipe and shared with nothing. Two reasons, both learned here:
// a nix dev shell recreates `TMPDIR` per invocation and deletes it on exit, so
// a report written there is gone before anyone can read it; and an output
// directory two recipes both resolve to is one where the second silently
// destroys the first's evidence.
const WORK =
  flame !== null
    ? path.join(flame.flameRepo, "artifacts", "h4-gui-e2e")
    : fs.mkdtempSync(path.join(os.tmpdir(), "ct-h4-"));
fs.mkdirSync(WORK, { recursive: true });
// The socket stays in /tmp: AF_UNIX caps a socket path at 108 bytes IN THE
// KERNEL, and a repo-relative artifacts path plus a name crosses it easily.
// That limit has already cost this campaign two arms recorded red for a reason
// unrelated to what they measured.
const SOCKET = path.join("/tmp", `ct-h4-${process.pid}.sock`);
const TICKS = path.join(WORK, "ticks-patched.log");
const CONTROL_LOG = path.join(WORK, "control.log");
const PATCHED_LOG = path.join(WORK, "patched.log");
const REPORT = path.join(WORK, "apply-edit-report.json");

if (flame !== null) {
  process.env.CODETRACER_HCR_APPLY_EDIT_CMD = flame.applyEdit;
  process.env.CODETRACER_HCR_DRIVER = flame.driver;
  process.env.CODETRACER_HCR_EDIT = EDIT;
  process.env.CODETRACER_HCR_WAIT_FOR = TICKS;
  process.env.CODETRACER_HCR_MARKER = MARKER;
  process.env.CODETRACER_HCR_MARKER_TIMEOUT_MS = "180000";
  process.env.CODETRACER_HCR_SOCKET = SOCKET;
  process.env.CODETRACER_HCR_REPORT = REPORT;
}
// EVERY ONE OF THOSE IS SET AT MODULE SCOPE, and it has to be: `makeCleanEnv`
// in lib/fixtures.ts snapshots `process.env` when it launches Electron, so a
// variable set inside a test body reaches nothing. The unconfigured-refusal
// claim therefore lives in its own spec file — `apply_edit_unconfigured.spec.ts`
// — rather than in a second test here, because "configured" and "not
// configured" are two different launches and cannot be two tests in one file.

const COMMAND_LABEL = "Apply Edit & Hot-Reload";

async function openPaletteAndFind(ctPage: import("@playwright/test").Page, query: string) {
  await ctPage.keyboard.press("Control+KeyP");
  const input = ctPage.locator("#command-query-text");
  await expect(input).toBeVisible({ timeout: 15_000 });
  await input.fill(query);
  return ctPage
    .locator(".command-results .command-result.command-command")
    .filter({ hasText: COMMAND_LABEL })
    .first();
}

test.describe("H4 — in-app apply-edit triggers the HCR reload path", () => {
  test.setTimeout(600_000);
  test.use({ sourcePath: PY_PROGRAM, launchMode: "trace" });

  test("invoking the command hot-reloads the running flame", async ({ ctPage }) => {
    test.skip(
      flameUnavailable !== null,
      `the flame HCR prerequisites are not present: ${flameUnavailable ?? ""}`,
    );
    const paths = flame as FlamePaths;

    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    // --- the CONTROL run: the same scene, the same engine, no agent ---------
    // Its purpose is not reassurance. FlameSim is seeded and fixed-timestep, so
    // this is the exact per-frame trajectory the patched run must reproduce
    // until the patch lands, which makes the verdict an identity test rather
    // than a threshold.
    const control = await runFlame(paths, path.join(WORK, "ticks-control.log"), null, 240_000);
    fs.writeFileSync(CONTROL_LOG, control.stdout);
    expect(control.code, `the control flame exited ${control.code}: ${control.stderr.slice(-400)}`).toBe(0);
    expect(control.stdout).toContain("CT_H2_DONE");

    // --- the UI action ------------------------------------------------------
    // The socket is published into the main process's environment the same way
    // every other setting reaches it. From here on nothing in this test
    // publishes anything: the command the user invoked does.
    fs.rmSync(SOCKET, { force: true });
    fs.rmSync(TICKS, { force: true });
    fs.writeFileSync(TICKS, "");

    const hit = await openPaletteAndFind(ctPage, ":Apply Edit");
    await expect(hit).toBeVisible({ timeout: 15_000 });
    await hit.click();

    // The command compiles the edit before it opens anything, so the socket
    // appearing is the witness that the UI action really reached the
    // coordinator — and a bound on it is a measurement rather than a hang.
    await waitForFile(SOCKET, 120_000, "the coordinator socket the in-app command opens");

    // --- the PATCHED run ----------------------------------------------------
    // NOT awaited yet, and the ordering is load-bearing rather than stylistic.
    // The coordinator publishes about two seconds in — as soon as it has READ
    // the flame's frame-120 line — and the flame then runs another four
    // hundred frames. A status notification auto-dismisses after a few seconds,
    // so awaiting the whole run before looking for it means looking after it is
    // gone. The first run of this test failed exactly that way, with the patch
    // demonstrably applied in the coordinator's own log.
    const patchedRun = runFlame(paths, TICKS, SOCKET, 300_000);

    // --- what the UI said ---------------------------------------------------
    // Asserted, and NOT the verdict. The agent reports `patchApplied` for a
    // body that changes nothing; the headless sweep's `F1-noop-edit` arm is
    // exactly that case going red. This assertion says the product told the
    // user the truth about what the provider answered; the next one says the
    // flame actually changed.
    await expect(
      ctPage.locator(".status-notification").filter({ hasText: "Apply Edit & Hot-Reload: applied" }),
    ).toBeVisible({ timeout: 180_000 });

    const patched = await patchedRun;
    fs.writeFileSync(PATCHED_LOG, patched.stdout);
    expect(patched.code, `the patched flame exited ${patched.code}: ${patched.stderr.slice(-400)}`).toBe(0);

    // The command's own report, read from disk rather than from the screen.
    // The notification above is what the USER was told; this is what the
    // command actually answered, and the two are asserted separately so that a
    // UI that displayed the wrong thing is a failure rather than a match.
    const report = JSON.parse(fs.readFileSync(REPORT, "utf8"));
    expect(report.status).toBe("applied");
    expect(report.predictedLiveRatio).toBeCloseTo(0.3333, 3);

    // --- the verdict, from the flame's own output ---------------------------
    const verdict = runVerdict(paths, CONTROL_LOG, PATCHED_LOG, path.join(WORK, "verdict.json"));
    const summary = `${verdict.stdout}\n${verdict.stderr}`;
    expect(summary, summary).toContain("control and patched agree EXACTLY");
    expect(verdict.code, `the flame verdict failed:\n${summary}`).toBe(0);
    expect(summary).toMatch(/steady-state live particles: control \d+ -> patched \d+/);
    // The publication landed in a RUNNING process: the coordinator waited to
    // READ the flame's own frame-120 line before it published anything.
    expect(fs.readFileSync(TICKS, "utf8")).toContain(`CT_H2 frame=${PATCH_AT} `);
  });
});
