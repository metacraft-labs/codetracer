/**
 * visual-alignment-capture.spec.ts — PLAT-35. **The per-view capture harness
 * for the Electron front-end**, and the Electron half of the tier-3 answer
 * set.
 *
 * `Cross-Renderer-Visual-Alignment.md`'s status table said of this:
 * *"Does not exist. `src/tests/gui/playwright.config.ts:95` sets `screenshot:
 * "only-on-failure"`; there is no named-view capture tool, no viewport matrix
 * and no baseline directory."* This is that tool.
 *
 * ## What it produces, per scenario
 *
 *   `src/tests/visual/captures/electron/<scenario>.png`   the named view
 *   `src/tests/visual/answers/<scenario>.electron.json`   the eight answers
 *
 * Both paths are read by `src/frontend/gpui/tests/
 * test_cross_renderer_visual_alignment.nim`, which is where the comparison
 * lives. This file DOES NOT COMPARE ANYTHING against the GPUI front-end and
 * must not learn how: `Verification-Harness-Traps` §30a is the trap, and
 * `ci/test/plat35-answer-independence.sh` is what refuses it.
 *
 * ## The scenario definition is read, never restated
 *
 * `src/tests/visual/scenarios.json` names a recording, an operation sequence,
 * a viewport and a view — and names no renderer. The Nim side reads the same
 * file. A transcription here would be the second copy of one definition that
 * §30 is about.
 *
 * ## STEPPED BEFORE CAPTURE, AND THE STEP IS ASSERTED BY ITS EFFECT
 *
 * PLAT-23 measured why: a Python program at line 1 genuinely has no locals,
 * and its pane census moved from `locals=0` to `locals=8` on that one change.
 * Two empty screens compare equal. Five of the six scenarios drive the
 * product's own debug-toolbar buttons before anything is read; the sixth does
 * not, on purpose, and is the population control the Nim suite asserts
 * against.
 *
 * **EVERY OPERATION ASSERTS THAT THE PROGRAM MOVED** — see `waitForMove`. The
 * first version of this file asserted that the declared number of CLICKS had
 * been ISSUED, which an operation landing nowhere satisfies, and three runs of
 * the identical specification produced three different corpora. The corpus is
 * the thing every finding in this milestone is derived from, so a corpus that
 * does not reproduce makes every number in it a snapshot of one lucky run.
 *
 * ## THE VIEWPORT IS APPLIED AND THEN ASSERTED, IN THREE PLACES
 *
 * The page's CSS viewport, the device pixel ratio, and the captured PNG's own
 * IHDR dimensions — see `applyViewport` and the `pngSize` check. A matrix
 * whose only evidence is the declaration it was read from is not a matrix.
 * This lane must run under `Xvfb -dpi 96` (`just plat35-capture-electron`
 * starts one) so that dpr is 1 and a captured pixel is a CSS pixel.
 *
 * ## TIER 1 — the determinism canary, WITHIN this renderer only
 *
 * Its question is *"is the capture harness still deterministic"*, and that
 * question is well-posed per renderer and meaningless between two rasterisers
 * (§2). A canary scenario is captured TWICE in one run and the two PNGs must
 * be byte-identical. **Its failure invalidates tier 2**, so it is asserted
 * before any threshold is applied and the result is written into the manifest
 * the Nim suite reads.
 *
 * ## No mocks
 *
 * A real `.ct` trace, a real `ct` binary, a real `replay-server`, the real
 * Electron main process and the real renderer. The trace folder is the one
 * `just test-tui` records with the product's own `ct record`; its absence
 * FAILS BY NAME rather than skipping, which is the Silent-Self-Pass audit's
 * rule.
 */

import * as fs from "fs";
import * as path from "path";

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  debugToolbarSelector,
  type DebugToolbarButton,
} from "../../page-objects/debug-toolbar-ids";
import { extractLayoutAnswers } from "../../tools/layout-answers";

// `__dirname` is `<repo>/src/tests/gui/tests/visual`, so the repository root is
// five levels up. It was four for one run, which produced
// `<repo>/src/src/tests/visual/scenarios.json` and an ENOENT — recorded here
// because the failure mode of getting it wrong in the OTHER direction is
// silent: a `writeFileSync` to a path that happens to exist writes an artefact
// nobody reads.
const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const visualRoot = path.join(repoRoot, "src", "tests", "visual");
const capturesDir = path.join(visualRoot, "captures", "electron");
const answersDir = path.join(visualRoot, "answers");

interface ScenarioOp {
  kind: string;
  times?: number;
  line?: number;
}

/**
 * Where the program IS, read from the renderer's own debugger service.
 *
 * `rrTicks` is the only field that moves on EVERY operation. Measured
 * 2026-09-21 on the `calc` recording: the first step-in advances `rrTicks`
 * 0 -> 1 and leaves `line` at 1, so "the stopped line changed" is not a
 * postcondition — it is a postcondition that is false for a step that
 * genuinely happened. `real-tab-switching.spec.ts` reads the same field for
 * the same reason, and `stepping-through-views.spec.ts` records the rule:
 * *"the line may wrap back on loops, but ticks always advance forward"*.
 */
interface ProgramState {
  line: number;
  path: string;
  rrTicks: number;
  busy: boolean | null;
}

interface Scenario {
  id: string;
  view: string;
  recording: string;
  viewport: string;
  operations: ScenarioOp[];
  tier1Canary: boolean;
}

interface ScenarioFile {
  expectedScenarios: number;
  expectedViewports: number;
  expectedCanaries: number;
  operationKinds: string[];
  viewports: Record<string, { width: number; height: number }>;
  scenarios: Scenario[];
}

const definition: ScenarioFile = JSON.parse(
  fs.readFileSync(path.join(visualRoot, "scenarios.json"), "utf8"),
) as ScenarioFile;

// THE PARSE IS ASSERTED AT MODULE SCOPE. A reader that silently found fewer
// scenarios than the file declares would satisfy every check written over what
// it read (§4), and a Playwright file that generates zero `test` blocks exits
// 0 with "no tests found" looking exactly like a clean run.
if (definition.scenarios.length !== definition.expectedScenarios) {
  throw new Error(
    `scenarios.json declares expectedScenarios=${definition.expectedScenarios} ` +
      `and holds ${definition.scenarios.length}`,
  );
}
if (Object.keys(definition.viewports).length !== definition.expectedViewports) {
  throw new Error(
    `scenarios.json declares expectedViewports=${definition.expectedViewports} ` +
      `and holds ${Object.keys(definition.viewports).length}`,
  );
}
if (
  definition.scenarios.filter((s) => s.tier1Canary).length !==
  definition.expectedCanaries
) {
  throw new Error(
    `scenarios.json declares expectedCanaries=${definition.expectedCanaries} ` +
      `and marks ${definition.scenarios.filter((s) => s.tier1Canary).length}`,
  );
}
for (const s of definition.scenarios) {
  for (const op of s.operations) {
    if (!definition.operationKinds.includes(op.kind)) {
      throw new Error(
        `scenario '${s.id}' uses operation '${op.kind}', which is not in the ` +
          `closed vocabulary ${definition.operationKinds.join(", ")}`,
      );
    }
  }
}

/**
 * The recorded trace the scenarios name.
 *
 * FAILS BY NAME when it is absent. The Silent-Self-Pass audit is the reason: a
 * test that detects a missing prerequisite, returns early and is counted PASSED
 * is the defect. `src/frontend/gpui/tests/test_gpui_editing_surface.nim` raises
 * the same way with the same remedy.
 */
function resolveRecording(name: string): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  if (fs.existsSync(cache)) {
    const hit = fs
      .readdirSync(cache)
      .filter((e) => e.startsWith(`${name}-`))
      .sort();
    if (hit.length > 0) return path.join(cache, hit[hit.length - 1]);
  }
  throw new Error(
    `PLAT-35: the '${name}' recording is not in test-logs/tui-fixtures/. ` +
      `It is produced by the product's own 'ct record'; run 'just test-tui' ` +
      `once to record it. This FAILS rather than skipping on purpose.`,
  );
}

const recordingPath = resolveRecording(definition.scenarios[0].recording);

for (const dir of [capturesDir, answersDir]) {
  fs.mkdirSync(dir, { recursive: true });
}

/**
 * Read the program's position out of the renderer's own debugger service.
 *
 * READ, never driven: the operations below go through the product's own
 * toolbar. This is the postcondition side only.
 */
async function readProgramState(
  page: import("playwright").Page,
): Promise<ProgramState> {
  return page.evaluate(() => {
    const w = window as unknown as {
      data?: {
        status?: { stableBusy?: boolean };
        services?: {
          debugger?: {
            location?: { line?: number; path?: string; rrTicks?: number };
          };
        };
      };
    };
    const l = w.data?.services?.debugger?.location;
    return {
      line: l?.line ?? -1,
      path: l?.path ?? "",
      rrTicks: l?.rrTicks ?? -1,
      busy: w.data?.status?.stableBusy ?? null,
    };
  });
}

const fmtState = (s: ProgramState) =>
  `line ${s.line} @ ticks ${s.rrTicks}${s.busy === true ? " (busy)" : ""}`;

/**
 * **ONE SYNTHESIZED CLICK ON A DEBUG-TOOLBAR BUTTON. EXACTLY ONE.**
 *
 * `LayoutPage.clickDebugButton` is deliberately not used here, and the reason
 * is measured rather than stylistic. It tries `button.click({timeout: 5000})`
 * first and falls through to `dispatchEvent('click')` on ANY throw — including
 * a throw AFTER the pointer event has already been delivered, which
 * Playwright's post-click stability wait produces routinely on this surface
 * because the toolbar re-renders under the cursor. Both clicks then land and
 * the debugger takes TWO steps for one operation.
 *
 * Measured 2026-09-21, in the run that made this visible: `stepped-editor`
 * recorded `stepIn=34@4` followed by `stepIn=44@6` — tick 5 never appears, and
 * line 39, which every other run stops on, is stepped straight past.
 * `advanced-state` skipped tick 7 the same way in the same run. With a fixed
 * sleep and a click count this was invisible; with `rrTicks` it is a one-line
 * anomaly in the trajectory.
 *
 * The fallback chain exists for a real problem — under Xvfb the GoldenLayout
 * strip can intercept a pointer click — and `dispatchEvent` is its own
 * documented remedy for exactly that. So this lane goes straight to the
 * remedy: no OS pointer event, nothing to intercept, and no second click. It
 * is the same decision the `setBreakpoint` operation already makes on the
 * gutter, for the same reason.
 *
 * THIS IS A PLAT-35 DECISION AND NOT A REPAIR OF THE SHARED PAGE OBJECT.
 * Every stepping spec in the suite uses the chain and would have to be re-run
 * to change it (§32a); this milestone's lane is the one that has a
 * postcondition sharp enough to have noticed, and widening the change without
 * re-running the rest would be trading a measured defect for an unmeasured
 * one. It is filed rather than fixed in place.
 */
async function clickToolbar(
  page: import("playwright").Page,
  which: DebugToolbarButton,
): Promise<void> {
  // `debugToolbarSelector`, never a second spelling of the id: that helper
  // exists because two page objects once carried their own copies of the list
  // and drifted onto the pre-rename `*-debug` ids, after which every
  // toolbar click resolved to nothing and died on a 30s locator timeout.
  const selector = debugToolbarSelector(which);
  const button = page.locator(selector);
  await expect(button, `the '${which}' toolbar button (${selector}) is not in the DOM`)
    .toHaveCount(1, { timeout: 15_000 });
  await button.dispatchEvent("click");
}

/**
 * **WAIT FOR THE EFFECT, AND FAIL BY NAME WHEN THERE IS NONE.**
 *
 * This is the repair the whole capture rests on. The first spelling of `drive`
 * counted CLICKS ISSUED and asserted that count against the declared sequence,
 * so an operation that landed nowhere passed — and three runs of the identical
 * specification produced three different corpora:
 *
 *   scenario            run 1   run 2   run 3
 *   stepped-editor        34      29      29
 *   advanced-state        44      39      54
 *   returned-calltrace   113       2     113
 *   breakpoint-editor      2     8;29   timed out
 *
 * `returned-calltrace` sitting at line 2 is essentially the entry point, which
 * is PLAT-23's *"two empty screens compare equal"* trap firing INSIDE the
 * scenario set built against it.
 *
 * MEASURED, 2026-09-21, before any of this was written. A probe clicked
 * step-in six times with a fixed 2s sleep after each and read the location:
 * `1, 1, 2, 29, 34, 39` — one operation behind throughout. The same six clicks
 * waiting on `rrTicks` instead: every one moved, in 200ms, 235ms, 5195ms,
 * 3386ms, 4430ms and 2030ms, ending on line 44. So the variance was never a
 * swallowed click; it was a fixed sleep racing a backend round trip that takes
 * anywhere from a fifth of a second to five seconds. A 2s sleep lands on
 * whichever side of that the host happens to be on, which is exactly the shape
 * of a corpus that does not reproduce.
 *
 * `stableBusy` is required as well as the tick change: `ui/debug.nim`'s
 * `dapStep` gates a new request on it and the middleware clears it only on
 * `CtCompleteMove`, so it is the renderer's own "this move is finished".
 */
async function waitForMove(
  page: import("playwright").Page,
  before: ProgramState,
  what: string,
  exactlyOneTick: boolean,
): Promise<ProgramState> {
  const BUDGET_MS = 60_000;
  const t0 = Date.now();
  let last = before;
  let moved = false;
  while (Date.now() - t0 < BUDGET_MS) {
    last = await readProgramState(page);
    if (last.rrTicks !== before.rrTicks && last.busy !== true) {
      moved = true;
      break;
    }
    await page.waitForTimeout(100);
  }
  if (!moved) {
    throw new Error(
      `PLAT-35: '${what}' was performed on the product's own toolbar and the ` +
        `program did not move within ${BUDGET_MS}ms. Before: ${fmtState(before)}; ` +
        `still: ${fmtState(last)}. An operation that lands nowhere must fail ` +
        `here — a capture that counts clicks issued rather than moves made is ` +
        `how four of six scenarios reached a different program state on a ` +
        `re-run of the identical specification and the suite stayed green.`,
    );
  }
  // **AND IT MOVED BY THE RIGHT AMOUNT.** A step-in and a next advance the
  // recording by EXACTLY ONE tick — measured over all 21 step-ins of the
  // deepest scenario, 0 through 21 with no gap. So "it moved" is not the whole
  // postcondition: TWO steps for one operation satisfies it and puts the
  // corpus one stop further along, which is precisely what a doubled click
  // produced before `clickToolbar` replaced the fallback chain.
  //
  // `stepOut` and `continueForward` advance by however far the frame or the
  // program runs (16 and 171 ticks respectively on this recording), so for
  // those the claim is only that time moved FORWARD.
  if (exactlyOneTick && last.rrTicks !== before.rrTicks + 1) {
    throw new Error(
      `PLAT-35: '${what}' advanced the recording from tick ${before.rrTicks} ` +
        `to tick ${last.rrTicks}. A step is exactly one tick; more than one ` +
        `means the operation was delivered twice, and a corpus one stop ` +
        `further along than its definition says is a corpus every finding ` +
        `derived from it is wrong about.`,
    );
  }
  if (last.rrTicks < before.rrTicks) {
    throw new Error(
      `PLAT-35: '${what}' moved the recording BACKWARD, ${before.rrTicks} -> ` +
        `${last.rrTicks}. Every operation in the closed vocabulary is a ` +
        `forward one.`,
    );
  }
  return last;
}

/**
 * Drive one scenario's operation sequence through the PRODUCT's own controls.
 *
 * Never through `window.data.services.debugger` directly: the milestone asks
 * for captures *"taken from the shipped binaries, not from a harness-built
 * surface"*, and a step performed by calling into the renderer's service layer
 * is a step the user's toolbar never took.
 *
 * Answers the TRAJECTORY — every state the program passed through — which is
 * what the manifest records and what makes a shifted corpus visible at all.
 */
/**
 * Read the editor's rendered geometry as ONE signature string.
 *
 * Everything in it is a number the row-count answer depends on: the scroll
 * position, the content height Monaco derives the scroll bounds from, the
 * offset of the first rendered row, how many rows are rendered, and the view
 * zone's own laid-out box. Read together, in one `evaluate`, so two fields can
 * never come from two different frames.
 */
async function editorFrameSignature(
  page: import("playwright").Page,
): Promise<string> {
  return page.evaluate(() => {
    const root = document.querySelector<HTMLElement>(
      "div[id^='editorComponent']",
    );
    if (!root) return "no-editor-root";
    const m = (window as any).monaco;
    const eds =
      m && m.editor && m.editor.getEditors ? m.editor.getEditors() : [];
    if (!eds || eds.length === 0) return "no-editors";
    const e = eds[0];
    const lines = Array.from(
      root.querySelectorAll<HTMLElement>(
        ".monaco-editor .view-lines .view-line",
      ),
    ).map((l) => l.offsetTop);
    const zones = Array.from(
      root.querySelectorAll<HTMLElement>(".monaco-editor .view-zones > *"),
    )
      .map((z) => `${z.style.top || "?"}/${z.style.height || "?"}`)
      .join(",");
    return [
      `sT=${e.getScrollTop()}`,
      `cH=${e.getContentHeight ? e.getContentHeight() : -1}`,
      `lH=${e.getLayoutInfo().height}`,
      `rows=${lines.length}`,
      `top=${lines.length ? Math.min(...lines) : -1}`,
      `zones=[${zones}]`,
    ].join(";");
  });
}

/**
 * **WAIT FOR THE EDITOR TO FINISH REACTING TO THE MOVE THAT JUST HAPPENED.**
 *
 * MEASURED 2026-09-21. `returned-calltrace` at `laptop` was captured nine times
 * and its `editor-row-count` answer came back `rows=36;first=82;last=117` six
 * times and `rows=35;first=83;last=117` three times. The two states are 21px of
 * scroll apart — 1788 against 1809 — and the 21px was identified rather than
 * inferred: a **`flow-view-zone flow-content-widget`** at `top: 2354px;
 * height: 21px`, read off the live DOM, holding the flow overlay's
 * loop-iteration control (`flow-multiline-value-108-2`, reading
 * `iteration from 5`) for the loop at line 108. That puts the content height at
 * `117 x 22 + 21 + 12 = 2607` (the 12 is the horizontal scrollbar) and pushes
 * line 117's own offset to `116 x 22 + 21 = 2573`. Both figures were read off
 * the live DOM and both match exactly.
 *
 * `1809 = 2607 - 798` is the scroll bound WITH the zone counted;
 * `1788 = 2574 + 12 - 798` is the bound WITHOUT it. At 1788 the first rendered
 * row is line 82 and the editor draws 36 of them; at 1809 it is line 83 and 35.
 * **Which Monaco code path picks each is not established here and is not
 * claimed**: what is established is that the two resting positions are exactly
 * the two bounds, that they differ by exactly the zone's height, and that a
 * capture landed on one or the other depending on how far the previous move's
 * render had got — including one run that came to rest with the zone's box
 * never laid out at all (`top: 0px; height: 0px`) while the content height
 * still counted its 21px, which is a state no settled frame should be read in.
 *
 * TWO EARLIER READINGS WERE TESTED AND ARE FALSE, which is why they are named
 * here rather than left for the next person to re-run:
 *
 *   * *"the capture races the horizontal scrollbar's appearance"* — the
 *     scrollbar's 12px is in the content height of every one of the nine runs.
 *   * *"the capture races the resize"* — `waitForEditorRelayout` now holds the
 *     editor's box and Monaco's `layoutInfo` to agreement before the first
 *     operation, and five runs with it in place still split 4/1. That wait is
 *     KEPT, because it was fixing something real (two of four probed runs drove
 *     the debugger with a 1298px-tall editor inside a 900px-tall window), but
 *     it is not this.
 *
 * What was NOT waited for anywhere is the editor's reaction to a STEP.
 * `waitForMove` returns as soon as the program's reported position changes; the
 * reveal and the flow overlay's view zone follow asynchronously, and the next
 * of twenty-two clicks was being issued into the middle of them. This settles
 * the rendered frame between operations: the signature above, identical on two
 * consecutive reads, so the zone's box and the scroll bound are both in their
 * resting positions before anything else is asked of the editor.
 *
 * It is BOUNDED AND SOFT. A frame that will not settle is a finding about the
 * product, not a reason to abandon the capture mid-sequence — the operation
 * loop's own postconditions are what grade the run, and the final frame is
 * settled again, hard, by `captureSettled` before any pixel is read.
 */
async function waitForEditorFrameSettled(
  page: import("playwright").Page,
): Promise<void> {
  const DEADLINE_MS = 10_000;
  const INTERVAL_MS = 120;
  const started = Date.now();
  let previous = await editorFrameSignature(page);
  while (Date.now() - started < DEADLINE_MS) {
    await page.waitForTimeout(INTERVAL_MS);
    const current = await editorFrameSignature(page);
    if (current === previous) return;
    previous = current;
  }
}

async function drive(
  layout: LayoutPage,
  ops: ScenarioOp[],
): Promise<{ moves: number; trajectory: string[]; final: ProgramState }> {
  let moves = 0;
  const trajectory: string[] = [];
  // THE STARTING POINT IS ASSERTED, not assumed. A session that has not
  // finished opening reports `rrTicks: -1`, and driving from there would make
  // the first operation's postcondition true by arithmetic on a sentinel.
  let state = await readProgramState(layout.page);
  expect(
    state.rrTicks,
    "the session had no position before the first operation; the capture " +
      "would then be driving a window that has not opened",
  ).toBeGreaterThanOrEqual(0);
  trajectory.push(`entry=${state.line}@${state.rrTicks}`);

  for (const op of ops) {
    const times = op.times ?? 1;
    for (let i = 0; i < times; i++) {
      const before = state;
      const what = `${op.kind} #${i + 1}/${times}`;
      switch (op.kind) {
        case "stepIn":
          await clickToolbar(layout.page, "stepIn");
          state = await waitForMove(layout.page, before, what, true);
          moves++;
          break;
        case "next":
          await clickToolbar(layout.page, "next");
          state = await waitForMove(layout.page, before, what, true);
          moves++;
          break;
        case "stepOut":
          await clickToolbar(layout.page, "stepOut");
          state = await waitForMove(layout.page, before, what, false);
          moves++;
          break;
        case "continueForward":
          await clickToolbar(layout.page, "continue");
          state = await waitForMove(layout.page, before, what, false);
          moves++;
          break;
        case "setBreakpoint": {
          // Relative to the FIRST DRAWN ROW, resolved against the recording's
          // own source by clicking the gutter the product drew for it — the
          // same rule the GPUI driver applies, so the two arms aim at the same
          // line without either being told a number.
          //
          // ASSERTED, not hoped for. The first spelling of this used
          // `click({ force: true })` on a positional index and produced no
          // breakpoint at all; the capture went green and the gutter-marks
          // question answered `<stopped line>=execution` on every scenario,
          // which is a perfectly equal comparison about nothing. A scenario
          // that claims a mark and gets none must fail here.
          const gutters = layout.page.locator(
            "div[id^='editorComponent'] .margin-view-overlays .gutter",
          );
          const lines = await gutters.evaluateAll((els) =>
            els
              .map((e) => parseInt((e as HTMLElement).dataset.line || "-1", 10))
              .filter((n) => n > 0)
              .sort((a, b) => a - b),
          );
          expect(lines.length, "the editor drew no gutter rows").toBeGreaterThan(0);
          const target = lines[Math.min(op.line ?? 1, lines.length - 1)];
          const cell = layout.page.locator(
            `div[id^='editorComponent'] .margin-view-overlays .gutter[data-line='${target}']`,
          );
          // `dispatchEvent`, not `click`. Monaco rebuilds the margin overlays
          // on every render, so an actionability-checked click loses the race:
          // measured 2026-09-20 — *"element was detached from the DOM,
          // retrying"*, for the full 30 s budget, on an element the locator had
          // already resolved. `calltrace_move_sync.spec.ts` dispatches for the
          // same reason on the same kind of surface.
          await cell.dispatchEvent("click");
          await expect(
            layout.page.locator(
              `div[id^='editorComponent'] .margin-view-overlays ` +
                `.gutter[data-line='${target}'] .gutter-breakpoint-enabled`,
            ),
          ).toHaveCount(1, { timeout: 15_000 });
          // **ITS EFFECT IS THE MARK, AND ITS NON-EFFECT IS ALSO ASSERTED.**
          // Setting a breakpoint must not move the program: a gutter click
          // that stepped the debugger would give this scenario a different
          // stopped line from `stepped-editor`'s for a reason nothing in the
          // definition asks for.
          state = await readProgramState(layout.page);
          expect(
            state.rrTicks,
            `${what} moved the program from ${fmtState(before)} to ` +
              `${fmtState(state)}; setting a mark is not a step`,
          ).toBe(before.rrTicks);
          moves++;
          break;
        }
        default:
          throw new Error(`unknown operation kind '${op.kind}'`);
      }
      trajectory.push(`${op.kind}=${state.line}@${state.rrTicks}`);
      // **AND THEN WAIT FOR THE EDITOR TO FINISH DRAWING THE MOVE.**
      // `waitForMove` waits for the PROGRAM's position, which the renderer
      // reports as soon as the reply lands. The editor's own reaction — the
      // reveal, and the flow overlay's view zone — is asynchronous and was not
      // waited for anywhere, so the next click landed at a different point in
      // the previous move's render on every run. See
      // `waitForEditorFrameSettled` for what that cost.
      await waitForEditorFrameSettled(layout.page);
    }
  }
  return { moves, trajectory, final: state };
}

/**
 * **THE VIEWPORT MATRIX, RESIZED FOR REAL AND THEN ASSERTED.**
 *
 * The first spelling resized `BrowserWindow.getAllWindows()[0]` inside
 * `if (electronApp !== null)` and asserted nothing. All six committed captures
 * came out 1923x1082 — including the three declared `laptop` (1440x900) — and
 * the suite's `ck viewportsUsed.len == expectedViewports` counted the
 * DECLARATION, so `pane-rectangles`, `which-panes-are-present` and
 * `focus-order` were byte-identical across all six scenarios and nothing said
 * so.
 *
 * Two mechanisms, both measured 2026-09-21 rather than reasoned about:
 *
 *   * **`electronApp` was ALWAYS `null`.** Its fixture was
 *     `async ({}, use) => { await use(null); }`. The resize block never ran
 *     once. Repaired in `lib/fixtures.ts`; this function now takes the app and
 *     the caller fails by name when it is absent.
 *   * **The device scale factor was 1.046875**, from the X server's DPI, so a
 *     screenshot was 1.046875x the CSS viewport in each axis: 1837 x 1.046875
 *     = 1923, 1034 x 1.046875 = 1082. That is where the third and fourth
 *     digits came from, and it is why `just plat35-capture-electron` now runs
 *     its own `Xvfb -dpi 96`, at which dpr is exactly 1 and a captured pixel
 *     is a CSS pixel.
 *
 * The window is resized through the window that OWNS THE PAGE
 * (`electronApp.browserWindow(page)`), not through `getAllWindows()[0]`: they
 * happen to be the same window in this lane, and relying on that is how a
 * second window would silently make this a no-op again.
 */
async function applyViewport(
  page: import("playwright").Page,
  app: import("playwright").ElectronApplication,
  size: { width: number; height: number },
): Promise<void> {
  const win = await app.browserWindow(page);
  await win.evaluate((w, s) => {
    const bw = w as unknown as {
      setResizable: (b: boolean) => void;
      unmaximize: () => void;
      setFullScreen: (b: boolean) => void;
      setContentSize: (a: number, b: number) => void;
    };
    bw.setResizable(true);
    bw.setFullScreen(false);
    bw.unmaximize();
    bw.setContentSize(s.width, s.height);
  }, size);

  // ASSERTED AGAINST THE CSS VIEWPORT, which is what `layout-answers.ts`
  // normalises every rectangle against and what the screenshot is of. The
  // window's own `getContentSize` is in device-independent pixels and is NOT
  // the same number whenever dpr is not 1 — asserting that one instead would
  // be asserting the request rather than its effect, one more time.
  await expect
    .poll(
      async () =>
        page.evaluate(() => `${window.innerWidth}x${window.innerHeight}`),
      {
        timeout: 20_000,
        message:
          `the window was asked for a ${size.width}x${size.height} content ` +
          `area and the page's CSS viewport did not follow`,
      },
    )
    .toBe(`${size.width}x${size.height}`);

  // AND THE SCALE FACTOR, because the screenshot is in DEVICE pixels. A lane
  // that starts drifting off dpr 1 must fail here rather than silently writing
  // a PNG of a different size than the viewport it claims.
  const dpr = await page.evaluate(() => window.devicePixelRatio);
  expect(
    dpr,
    `device pixel ratio is ${dpr}, so a ${size.width}x${size.height} viewport ` +
      `would be captured at ${Math.round(size.width * dpr)}x` +
      `${Math.round(size.height * dpr)}. Run this lane under 'Xvfb -dpi 96'.`,
  ).toBe(1);
}

/**
 * **WAIT FOR THE PRODUCT'S EDITOR TO FINISH RE-LAYING-OUT AFTER THE RESIZE.**
 *
 * `applyViewport` asserts that the *window* reached the declared size. That is
 * a claim about the window and it was being read as a claim about the product:
 * the editor pane re-measures itself asynchronously, off a resize observer, and
 * nothing between `applyViewport` and `drive` waited for it.
 *
 * MEASURED 2026-09-21, four consecutive captures of `returned-calltrace` at
 * `laptop` (1440x900), probed immediately before the first debugger operation:
 *
 * | run | `window.innerHeight` | editor box height | Monaco `layoutInfo.height` | final row count |
 * |-----|---------------------|-------------------|----------------------------|-----------------|
 * | 1   | 900                 | 1298              | 1298                       | `rows=36` |
 * | 2   | 900                 | 1298              | 1298                       | `rows=36` |
 * | 3   | 900                 | 798               | 798                        | `rows=35` |
 * | 4   | 900                 | 798               | 798                        | `rows=35` |
 *
 * The window is 900 tall in all four and the editor is 1298 tall in two of
 * them — a pane taller than the window that holds it, which is not a state any
 * frame should be read in. The row count follows it exactly, 2/2 each way.
 *
 * WHY THE ROW COUNT FOLLOWS, arithmetic checked against the same probe. The
 * editor's content height is `117 lines x 22px + 21px + 12px = 2607`, where the
 * 21px is a **`flow-view-zone flow-content-widget`** measured at `top: 2354px;
 * height: 21px` and the 12px is the horizontal scrollbar. A scroll clamped to
 * the bottom with the zone installed gives `2607 - 798 = 1809`; clamped before
 * it was installed it gives `2574 + 12 - 798 = 1788`. Those are exactly the two
 * scroll positions the four runs recorded, 21px apart, and 1788 puts the first
 * rendered line at 82 (36 rows) where 1809 puts it at 83 (35 rows).
 *
 * So the flip is not the scrollbar and not the zone appearing late: both are
 * present in all four. It is that a capture which drives the debugger while the
 * editor still holds its pre-resize box lets the renderer reach the reveal at a
 * different point in its own relayout.
 *
 * THE SETTLE CONDITION IS AN INVARIANT, NOT A SLEEP. Two things must hold, and
 * then hold again on the next read:
 *
 *   * the editor's box fits inside the window's CSS viewport — the direct
 *     negation of the 1298-in-900 state above, and it needs no per-viewport
 *     constant;
 *   * Monaco's own `layoutInfo` agrees with that box, so a DOM that has
 *     resized and an editor that has not yet re-measured is not read as settled.
 *
 * It fails by name rather than proceeding, because a capture that reads a
 * half-laid-out frame is the thing this exists to prevent.
 */
async function waitForEditorRelayout(
  page: import("playwright").Page,
): Promise<void> {
  const read = async (): Promise<string> =>
    page.evaluate(() => {
      const root = document.querySelector<HTMLElement>(
        "div[id^='editorComponent']",
      );
      if (!root) return "no-editor-root";
      const ed = root.querySelector<HTMLElement>(".monaco-editor");
      if (!ed) return "no-monaco-editor";
      const box = ed.getBoundingClientRect();
      const m = (window as any).monaco;
      const eds =
        m && m.editor && m.editor.getEditors ? m.editor.getEditors() : [];
      if (!eds || eds.length === 0) return "no-editors";
      const info = eds[0].getLayoutInfo();
      const fits =
        box.top + box.height <= window.innerHeight + 1 &&
        box.left + box.width <= window.innerWidth + 1;
      const measured = Math.abs(info.height - box.height) <= 1;
      if (!fits) return `pane-overflows-window:${box.height}>${window.innerHeight - box.top}`;
      if (!measured) return `monaco-not-remeasured:${info.height}!=${box.height}`;
      return `settled:${Math.round(box.width)}x${Math.round(box.height)}:${info.height}:${eds[0].getContentHeight()}`;
    });

  const DEADLINE_MS = 20_000;
  const INTERVAL_MS = 250;
  const started = Date.now();
  let previous = "";
  let current = await read();
  while (Date.now() - started < DEADLINE_MS) {
    if (current.startsWith("settled:") && current === previous) return;
    previous = current;
    await page.waitForTimeout(INTERVAL_MS);
    current = await read();
  }
  throw new Error(
    "the editor pane did not finish re-laying-out within " +
      `${DEADLINE_MS}ms of the viewport change; last reading was '${current}'. ` +
      "Driving the debugger from here makes the editor's final scroll position " +
      "depend on how far the renderer had got, which moves the row count.",
  );
}

/** The pixel dimensions in a PNG's IHDR, which is always its first chunk. */
function pngSize(file: string): { width: number; height: number } {
  const buf = fs.readFileSync(file);
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

/**
 * Freeze everything that moves, then capture a SETTLED frame.
 *
 * ## Why the freeze is declared rather than done quietly
 *
 * It changes what is captured. A visual-regression capture that leaves CSS
 * animations, transitions and the text caret running is a capture whose bytes
 * depend on when the shutter opened.
 *
 * **WHETHER THIS FREEZE IS NECESSARY HERE IS NOT MEASURED, AND SAYING SO IS
 * THE POINT.** A run on 2026-09-20 reported all four tier-1 canaries red and
 * it was read as drift; it was not. The canary was writing its second
 * screenshot to a path ending `.canary`, Playwright derives the encoder from
 * the extension, and the call died with `path: unsupported mime type "null"`
 * before any second frame existed. The freeze and the settle loop were both
 * already in place by the time a canary first ran to completion, so no
 * measurement here distinguishes "the capture needed freezing" from "the
 * capture was always deterministic". What IS measured is that with them the
 * four canaries report `identical` and the settle loop converges in two or
 * three attempts.
 *
 * It is kept, unmeasured, for one reason that does not depend on this host: a
 * caret blinks on a timer and a CI runner is slower than a workstation, so the
 * first place this would fail is the place nobody can debug it. The methodology's
 * answer to a failing tier-1 is *fix the capture*, never *loosen the check*.
 *
 * What is stopped: CSS animations, transitions, `scroll-behavior` and the
 * caret. What is NOT stopped: anything the product draws from data. A freeze
 * that hid content would make every later tier agree about a screen no user
 * sees.
 *
 * ## The settle loop
 *
 * Capture until two consecutive frames are byte-identical, bounded. This is
 * `isonim-gpui/scripts/wayland-capture-frame.sh`'s phase 2, in the other
 * front-end: *"settled: two consecutive captures byte-identical, so a
 * half-mapped surface is not mistaken for a finished composition"*. It returns
 * how many attempts it took, which the manifest records — a capture that needs
 * the whole budget every time is a capture about to start flaking, and that is
 * visible only if the number is written down.
 */
async function captureSettled(
  page: import("playwright").Page,
  target: string,
): Promise<number> {
  // **TAKE THE POINTER OFF THE TOOLBAR FIRST.**
  //
  // Found by doing the tier-4 reading that had never been done: every
  // captured frame carried the tooltip of the LAST BUTTON THE HARNESS
  // CLICKED, drawn over the editor's tab title — `Step in (F11)` on
  // `stepped-editor`, obscuring `calc/main.py` into `alc/main.py`, and
  // `Next (F10)` on `advanced-state`. It is two defects at once:
  //
  //   * a REVIEW defect, because a reviewer reads an obscured tab title as a
  //     rendering fault in the product;
  //   * a DETERMINISM defect, because which tooltip is on screen depends on
  //     which operation the scenario happened to end with, and a tooltip
  //     fades on its own timer. The tier-1 canary compares three frames a few
  //     hundred milliseconds apart and would eventually catch a tooltip
  //     dismissing itself between two of them.
  //
  // Moving the mouse to the far corner and blurring is what a screenshot of
  // a resting window needs; the CSS freeze below cannot help, because the
  // tooltip's visibility is a hover state rather than an animation.
  await page.mouse.move(2, 2);
  await page.evaluate(() => {
    const el = document.activeElement as HTMLElement | null;
    if (el && typeof el.blur === "function") el.blur();
  });
  await page.waitForTimeout(1_200);
  await page.addStyleTag({
    content: `*, *::before, *::after {
      animation: none !important;
      transition: none !important;
      scroll-behavior: auto !important;
      caret-color: transparent !important;
    }
    .monaco-editor .cursors-layer > .cursor { visibility: hidden !important; }`,
  });
  const MAX_ATTEMPTS = 12;
  let previous: Buffer | null = null;
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    await page.screenshot({ path: target });
    const current = fs.readFileSync(target);
    if (previous !== null && previous.equals(current)) return attempt;
    previous = current;
    await page.waitForTimeout(250);
  }
  return MAX_ATTEMPTS;
}


for (const scenario of definition.scenarios) {
  test.describe(`PLAT-35 capture: ${scenario.id}`, () => {
    test.use({ sourcePath: recordingPath, launchMode: "trace-folder" });

    test(`captures the '${scenario.view}' view and its eight answers`, async ({
      ctPage,
      electronApp,
    }) => {
      test.setTimeout(240_000);
      const size = definition.viewports[scenario.viewport];
      expect(size, `scenario '${scenario.id}' names viewport '${scenario.viewport}'`)
        .toBeTruthy();

      // THE VIEWPORT MATRIX. Playwright's `viewport` option does not reach an
      // Electron window, so the window is resized through the main process —
      // which is the only thing that can do it, and is also what a user's
      // window manager does.
      //
      // **A NULL APP FAILS BY NAME.** It used to be `if (electronApp !== null)`,
      // and the fixture handed `null` to every test in the suite, so the block
      // never ran. A precondition that quietly turns a check into a no-op is
      // the Silent-Self-Pass shape; this is the same remedy `resolveRecording`
      // above applies to a missing trace.
      expect(
        electronApp,
        "PLAT-35 needs the Electron main process to resize the window to the " +
          "scenario's declared viewport. A null app here means the capture " +
          "would silently produce six images at one size, which is what it " +
          "did before 2026-09-21.",
      ).not.toBeNull();

      const layout = new LayoutPage(ctPage);
      await layout.waitForBaseComponentsLoaded();
      await layout.waitForStateLoaded();
      await applyViewport(
        ctPage,
        electronApp as import("playwright").ElectronApplication,
        size,
      );

      // THE RESIZE IS NOT FINISHED WHEN THE WINDOW REPORTS THE NEW SIZE.
      // See `waitForEditorRelayout` for the four-run measurement that made this
      // necessary; without it the row count flips 35/36 between runs.
      await waitForEditorRelayout(ctPage);

      const driven = await drive(layout, scenario.operations);
      const declared = scenario.operations.reduce(
        (n, op) => n + (op.times ?? 1),
        0,
      );
      // EXACT, not "at least": the sequence is written out in the definition,
      // so an operation that silently started being refused moves this number
      // rather than sliding under a bound (§4b).
      //
      // AND `moves` COUNTS EFFECTS, NOT CLICKS. That is the whole repair: the
      // number on the left is now incremented only after the program's own
      // position has been seen to change (or, for `setBreakpoint`, after the
      // mark has appeared and the position has been seen NOT to change).
      expect(driven.moves).toBe(declared);

      await layout.waitForStateLoaded();
      await waitForEditorFrameSettled(ctPage);
      await ctPage.waitForTimeout(1_500);

      // THE VIEWPORT IS RE-ASSERTED AFTER THE OPERATIONS. Stepping re-lays-out
      // the panes and a product that resized its own window in response would
      // otherwise be captured at a size nobody declared.
      await expect
        .poll(async () =>
          ctPage.evaluate(() => `${window.innerWidth}x${window.innerHeight}`),
        )
        .toBe(`${size.width}x${size.height}`);


      const shot = path.join(capturesDir, `${scenario.id}.png`);
      const settled = await captureSettled(ctPage, shot);
      expect(fs.existsSync(shot)).toBe(true);

      // **THE ANSWERS ARE READ OFF THE FRAME THE PNG IS OF, AND THAT ORDERING
      // IS THE POINT.**
      //
      // They used to be extracted BEFORE `captureSettled`, so the eight answers
      // and the image beside them could describe two different frames — a
      // harness publishing two readings of one screen that were never taken of
      // one screen. `captureSettled` is by far the strongest settle signal in
      // this file: two consecutive byte-identical screenshots of the whole
      // window, which no geometry signature can match.
      //
      // MEASURED 2026-09-21, and this is why it is not a tidy-up. With the
      // per-move settle in place but the answers still read first, two
      // consecutive full-corpus runs disagreed on `continued-event-log`:
      // `rows=45;first=73;last=117` against `rows=43;first=75;last=117`. That
      // scenario is ONE operation (`continueForward`), so a settle between
      // operations has almost nothing to do there; what it was still racing was
      // the pane fill that follows a run-to-completion.
      //
      // Nothing `captureSettled` does changes an answer. It freezes animations,
      // transitions, `scroll-behavior` and the caret, moves the pointer to the
      // corner and blurs — and the eight extractors read row offsets, `tabindex`
      // attributes, computed font metrics and theme token names, none of which
      // any of that touches. The one it would touch is the tooltip, and
      // removing that from the frame is the repair, not a side effect.
      await waitForEditorFrameSettled(ctPage);
      const answers = await extractLayoutAnswers(ctPage, scenario.id);
      // THE PROVENANCE TRAVELS WITH THE ANSWER. The Nim comparison suite reads
      // this file as a RECORDED CAPTURE: it was produced by a shipped binary,
      // but not in the run that reads it. `Editor-Model-Conformance-Suite.md`
      // §10.5 requires a case whose Electron side is not live to be labelled,
      // and a label with no date is a label nobody can age.
      const provenance = {
        capturedAt: new Date().toISOString(),
        uiBundleBytes: fs.existsSync(
          path.join(repoRoot, "src", "build-debug", "ui.js"),
        )
          ? fs.statSync(path.join(repoRoot, "src", "build-debug", "ui.js")).size
          : 0,
        uiBundleMtime: fs.existsSync(
          path.join(repoRoot, "src", "build-debug", "ui.js"),
        )
          ? fs
              .statSync(path.join(repoRoot, "src", "build-debug", "ui.js"))
              .mtime.toISOString()
          : "",
      };
      fs.writeFileSync(
        path.join(answersDir, `${scenario.id}.electron.json`),
        `${JSON.stringify({ ...answers, provenance }, null, 2)}\n`,
      );


      // **THE IMAGE'S OWN DIMENSIONS, AGAINST THE SCENARIO'S DECLARED
      // VIEWPORT.** Read out of the PNG's IHDR rather than from anything the
      // harness believes: `applyViewport` asserts the request took effect on
      // the page, and this asserts the artefact that reached the disk is the
      // size that page was. Without it the matrix is a declaration — and it
      // was one: six PNGs at 1923x1082, three of them labelled 1440x900.
      const actual = pngSize(shot);
      expect(
        `${actual.width}x${actual.height}`,
        `scenario '${scenario.id}' declares viewport '${scenario.viewport}' ` +
          `(${size.width}x${size.height}) and its capture is ` +
          `${actual.width}x${actual.height}`,
      ).toBe(`${size.width}x${size.height}`);

      // TIER 1 — the determinism canary, WITHIN this renderer. A THIRD capture,
      // after the settle loop has already seen two identical ones, must equal
      // them. Its failure invalidates every tier-2 baseline on this side, so
      // the verdict is recorded beside the capture rather than only printed.
      //
      // The third capture is what keeps this from being a tautology: the settle
      // loop stops at the first agreeing PAIR, and a surface that is still
      // animating on a period longer than the poll interval can produce one
      // agreeing pair and then move. Only an independent capture afterwards can
      // see that, which is the same reason `wayland-capture-frame.sh` waits for
      // a settled frame AND the test still asserts the pixels.
      let canary: string | null = null;
      if (scenario.tier1Canary) {
        // `.png`, NOT `.canary`: Playwright derives the encoder from the extension
        // and refuses an unknown one with `path: unsupported mime type "null"`.
        // That error was read as a drifted canary for one run — it is not; the
        // second screenshot was never taken. Isolate the variable before
        // concluding anything about a red.
        const second = `${shot}.canary.png`;
        await ctPage.screenshot({ path: second });
        const a = fs.readFileSync(shot);
        const b = fs.readFileSync(second);
        canary = a.equals(b) ? "identical" : "drifted";
        if (canary === "drifted") {
          // KEPT, under a different name. The caller reads the drift as a
          // failure; this is the evidence for it, and putting it at `shot`
          // would turn a non-deterministic capture into a picture the next
          // tier would happily analyse.
          fs.renameSync(second, `${shot}.drifted.png`);
        } else {
          fs.unlinkSync(second);
        }
      }

      fs.writeFileSync(
        path.join(answersDir, `${scenario.id}.electron.capture.json`),
        `${JSON.stringify(
          {
            scenario: scenario.id,
            view: scenario.view,
            viewport: scenario.viewport,
            frontEnd: "electron",
            // MOVES, not clicks. The name changed with the meaning on
            // purpose: a reader who greps for the old key gets nothing rather
            // than a number that means something else.
            operationsMoved: driven.moves,
            // **WHERE THE PROGRAM ACTUALLY ENDED UP.** This is what makes a
            // shifted corpus visible: the Nim gate pins it, so a re-run that
            // reaches a different state reddens instead of being absorbed by
            // a residual that only compares mark KINDS.
            stoppedLine: driven.final.line,
            stoppedPath: path.basename(driven.final.path),
            rrTicks: driven.final.rrTicks,
            trajectory: driven.trajectory,
            // The measured viewport and the captured image, so the two can be
            // checked against the declaration without re-running the lane.
            viewportCss: `${size.width}x${size.height}`,
            capturePixels: `${actual.width}x${actual.height}`,
            capture: path.relative(repoRoot, shot),
            settleAttempts: settled,
            tier1: canary,
          },
          null,
          2,
        )}\n`,
      );

      // A canary that DRIFTED is a failure of this run, not a note: §2.1 —
      // *"tier 1 runs first, per renderer, and its failure invalidates the
      // tier-2 result rather than being reported alongside it"*.
      if (canary !== null) expect(canary).toBe("identical");
    });
  });
}
