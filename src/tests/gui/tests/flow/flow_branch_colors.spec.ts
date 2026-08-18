/**
 * Conditional branch colours — end-to-end coverage for issue #594 (M33).
 *
 * The reporter's follow-up reframed the bug: the `flow-taken` /
 * `flow-not-taken` line backgrounds ARE rendered, and are then lost again.
 * That makes it a redraw-lifecycle bug, not a missing-CSS bug:
 *
 *   * every completed move makes the editor reload the flow (the rrTicks
 *     always differ), and `loadFlow` installs a fresh `FlowComponent` whose
 *     `flow` field is nil;
 *   * `editorAfterRedraw` then runs synchronously while it is still nil, so
 *     the branch styles compute as an empty set and Monaco's
 *     `deltaDecorations` removes the colours;
 *   * nothing repainted them when the flow data finally arrived.
 *
 * Hence "it briefly shows the correct colouring, then loses it", and "the tab
 * I came from keeps the colours, the new one does not".
 *
 * The headless counterpart is
 * `src/tests/gui/tests/editor/editor_decorations_test.nim`, which pins the
 * retention rule itself. Only this layer can see that the colours actually
 * reach — and stay in — the DOM, which is what the previous, tautological
 * "test" for this issue (`check "flow-taken" == "flow-taken"`) could not.
 *
 * Fixture: a JavaScript program recorded with `codetracer-js-recorder`.  It
 * was `examples/fibonacci.py`, which made this spec unrunnable — and therefore
 * never once executed — wherever the Python recorder is not installed
 * (`codetracer_python_recorder` is a PyO3/maturin extension, not a
 * pure-Python package).  The JavaScript recorder is a *required* sibling of
 * this repository and the cheapest real recorder in the dev shell, so the spec
 * now records through it; `classify()` opens with a single unambiguous
 * `if (value % 2 === 0)` whose two branches are both exercised by the loop
 * that calls it.
 */

import { test, expect } from "../../lib/fixtures";
import type { Locator, Page } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import { recordJsTraceFixture } from "../../lib/js-trace-fixture";
import type { EditorPane } from "../../page-objects/panes/editor/editor-pane";

/**
 * `classify` is deliberately the FIRST declaration in the file so its line
 * numbers are stable, and its `if` has an explicit `else` so both a taken and
 * a not-taken branch exist on separate lines.
 *
 * `main` carries a conditional of its own on purpose.  "Branch colours survive
 * stepping" steps repeatedly, and step-over walks out of `classify` and back
 * into `main` after a few moves; without a conditional there, the decoration
 * count would legitimately drop to zero and the test would be measuring the
 * fixture's shape rather than the redraw lifecycle under test.
 */
const PROGRAM = `function classify(value) {
  if (value % 2 === 0) {
    return "even";
  } else {
    return "odd";
  }
}

function main() {
  let total = 0;
  const labels = [];
  for (let index = 0; index < 10; index++) {
    if (index > 0) {
      total += index;
    } else {
      total += 100;
    }
    labels.push(classify(index));
  }
  return total;
}

main();
`;

const fixture = recordJsTraceFixture("flow-branch-colors", PROGRAM);

/** Last line of `function classify(value)` in the fixture program. */
const CLASSIFY_LAST_LINE = 7;

/** Any Monaco whole-line decoration produced by `conditionStyleLines`. */
const BRANCH_DECORATION_SELECTOR = ".flow-taken, .flow-not-taken";

/** Where the debugger currently is, as the frontend sees it. */
async function debuggerLocation(
  ctPage: Page,
): Promise<{ line: number; functionName: string; rrTicks: number }> {
  return await ctPage.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const location = w.data?.services?.debugger?.location ?? {};
    return {
      line: Number(location.line ?? -1),
      functionName: String(location.functionName ?? ""),
      rrTicks: Number(location.rrTicks ?? -1),
    };
  });
}

/**
 * Open the fixture's editor and step until the debugger is inside
 * `classify()`, where the `if (value % 2 === 0)` branch decorations belong.
 */
async function stepIntoBranchingFunction(
  ctPage: Page,
): Promise<{ layout: LayoutPage; editor: EditorPane; decorations: Locator }> {
  const layout = new LayoutPage(ctPage);
  await layout.waitForTraceLoaded();
  await layout.waitForEditorLoaded();

  let editor: EditorPane | undefined;
  await retry(
    async () => {
      const tabs = await layout.editorTabs(true);
      editor = tabs.find((t) => t.fileName.toLowerCase().includes("program.js"));
      return Boolean(editor);
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
  expect(editor, "the program.js editor tab must be open").toBeDefined();
  if (!editor) throw new Error("program.js editor tab is not open");

  await editor.clickTab();
  await expect(editor.root.locator(".monaco-editor")).toBeVisible({ timeout: 30_000 });

  // Step in until the current function is `classify` — the flow (and with it
  // the branch decorations) is always computed for the function the debugger
  // is stopped in.
  await retry(
    async () => {
      const location = await debuggerLocation(ctPage);
      if (
        location.functionName.includes("classify") &&
        location.line > 0 &&
        location.line <= CLASSIFY_LAST_LINE
      ) {
        return true;
      }
      await layout.clickStepInButton();
      return false;
    },
    { maxAttempts: 40, delayMs: 700 },
  );

  const location = await debuggerLocation(ctPage);
  expect(
    location.functionName,
    "the fixture must let us reach classify() by stepping in",
  ).toContain("classify");

  const decorations = editor.root.locator(BRANCH_DECORATION_SELECTOR);

  // The colours must show up at all before we can assert that they stay.
  await expect
    .poll(async () => decorations.count(), {
      timeout: 60_000,
      message:
        "no .flow-taken / .flow-not-taken decoration was rendered for the " +
        "`if (value % 2 === 0)` conditional",
    })
    .toBeGreaterThan(0);

  return { layout, editor, decorations };
}

test.describe("Omniscience conditional branch colours (#594)", () => {
  test.setTimeout(240_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  test("branch colours survive stepping", async ({ ctPage }) => {
    const { layout, decorations } = await stepIntoBranchingFunction(ctPage);

    const initialCount = await decorations.count();
    expect(initialCount).toBeGreaterThan(0);

    // THE regression: each step reloads the flow, and the reload used to wipe
    // the decorations synchronously and never repaint them. Several steps,
    // because the reporter saw the colours flicker back on the occasional move
    // that happened not to trigger a reload.
    for (let step = 1; step <= 4; step++) {
      const before = await debuggerLocation(ctPage);
      await layout.clickNextButton();

      // Wait for the move to actually land, otherwise the assertion below
      // would race the very reload it is meant to observe.
      await expect
        .poll(async () => (await debuggerLocation(ctPage)).rrTicks, {
          timeout: 30_000,
        })
        .not.toBe(before.rrTicks);

      await expect
        .poll(async () => decorations.count(), {
          timeout: 30_000,
          message: `branch colours disappeared after step ${step}`,
        })
        .toBeGreaterThan(0);
    }
  });

  test("branch colours survive tab activation", async ({ ctPage }) => {
    const { layout, editor, decorations } = await stepIntoBranchingFunction(ctPage);

    expect(await decorations.count()).toBeGreaterThan(0);

    // Activating an editor tab runs `refreshFlowAfterActivation`, which
    // redrew the flow widgets but never repainted the line styles — so the
    // freshly activated tab came up without colours while the tab the user
    // came from kept them.
    await editor.clickTab();
    await expect
      .poll(async () => decorations.count(), {
        timeout: 30_000,
        message: "branch colours disappeared after re-activating the tab",
      })
      .toBeGreaterThan(0);

    // If the recording opened more than one source tab, do the full
    // away-and-back cycle the reporter described.
    const tabs = await layout.editorTabs(true);
    const other = tabs.find((t) => t.filePath !== editor.filePath);
    if (other) {
      await other.clickTab();
      await editor.clickTab();
      await expect
        .poll(async () => decorations.count(), {
          timeout: 30_000,
          message:
            "branch colours disappeared after switching to another editor " +
            "tab and back",
        })
        .toBeGreaterThan(0);
    }

    // One more step after the activation round trip: the retained layer must
    // not have become stale bookkeeping that the next reload drops.
    const before = await debuggerLocation(ctPage);
    await layout.clickNextButton();
    await expect
      .poll(async () => (await debuggerLocation(ctPage)).rrTicks, { timeout: 30_000 })
      .not.toBe(before.rrTicks);
    await expect
      .poll(async () => decorations.count(), {
        timeout: 30_000,
        message: "branch colours disappeared on the step after re-activation",
      })
      .toBeGreaterThan(0);
  });
});
