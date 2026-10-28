import { test, expect } from "../../lib/fixtures";
import type { Page } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  debugToolbarSelector,
  type DebugToolbarButton,
} from "../../page-objects/debug-toolbar-ids";

/**
 * A flow window that is REPLACED leaves nothing behind in the editor.
 *
 * What went wrong
 * ---------------
 * Every `FlowComponent` an editor created registered its per-line Monaco
 * content widget as `ct-flow-<editor id>-<line>`, so two successive windows
 * of one file used the SAME id for the same line. Monaco's content-widget
 * registry is keyed by `getId()`
 * (https://github.com/microsoft/vscode/blob/main/src/vs/editor/browser/viewParts/contentWidgets/contentWidgets.ts,
 * `addWidget` / `removeWidget`): the new window's widget overwrote the old
 * one's entry while the old DOM node stayed attached, and the hand-off's
 * `removeContentWidget(old)` then removed the NEW entry by that id. The old
 * window's node was left orphaned — drawn, but no longer positioned by the
 * editor, so it stayed at whatever pixel offset it had and drifted onto
 * unrelated rows as the editor scrolled.
 *
 * On `calc` this is the PLAT-37 `returned-calltrace` stop (step in 21 times,
 * step out once: `main` at line 110). The walk passes through the module's
 * own window, whose step for the `def main():` statement records the module
 * globals (`EXPRESSIONS`, `OPERATIONS`, `__builtins__`, …); `main`'s window
 * records only `return` on that line. The desktop kept painting the module's
 * chips under `main`'s, and the GPUI editor — which draws `main`'s window
 * only — was reported as the one missing a chip (codetracer-pm issue
 * `2026-10-23-gpui-omits-an-inline-value-chip-the-desktop-renders-in-the-editor.md`).
 *
 * No mocks: the real `calc` recording, the real replay server, the product's
 * own toolbar.
 */

/** `def main():` in `test-programs/calc/main.py`. */
const DefLine = 99;
/** The module-level `main()` call in `test-programs/calc/main.py`. */
const ModuleCallLine = 116;

interface ProgramState {
  line: number;
  rrTicks: number;
  busy: boolean | null;
}

async function readProgramState(page: Page): Promise<ProgramState> {
  return page.evaluate(() => {
    const w = window as unknown as {
      data?: {
        status?: { stableBusy?: boolean };
        services?: { debugger?: { location?: { line?: number; rrTicks?: number } } };
      };
    };
    const l = w.data?.services?.debugger?.location;
    return {
      line: l?.line ?? -1,
      rrTicks: l?.rrTicks ?? -1,
      busy: w.data?.status?.stableBusy ?? null,
    };
  });
}

/**
 * One toolbar operation, and wait for the recording to MOVE. Dispatched
 * rather than clicked: a Playwright click retries on a toolbar that
 * re-rendered under the cursor and can deliver the step twice.
 */
async function operate(page: Page, which: DebugToolbarButton): Promise<ProgramState> {
  const before = await readProgramState(page);
  const button = page.locator(debugToolbarSelector(which));
  await expect(button).toHaveCount(1, { timeout: 15_000 });
  await button.dispatchEvent("click");
  let now = before;
  await expect
    .poll(
      async () => {
        now = await readProgramState(page);
        return now.rrTicks !== before.rrTicks && now.busy !== true;
      },
      { timeout: 60_000, message: `'${which}' did not move the recording` },
    )
    .toBe(true);
  return now;
}

interface FlowLineWidget {
  widgetId: string;
  line: number;
  names: string[];
}

/** Every flow line widget in the editor, with the chip names it draws. */
async function flowLineWidgets(page: Page): Promise<FlowLineWidget[]> {
  return page.evaluate(() => {
    const out: { widgetId: string; line: number; names: string[] }[] = [];
    document
      .querySelectorAll<HTMLElement>(".monaco-editor .contentWidgets [widgetid^='ct-flow-']")
      .forEach((w) => {
        const widgetId = w.getAttribute("widgetid") ?? "";
        const line = Number(widgetId.slice(widgetId.lastIndexOf("-") + 1));
        const names = Array.from(w.querySelectorAll<HTMLElement>(".ct-omni-name")).map(
          (n) => (n.textContent ?? "").trim(),
        );
        out.push({ widgetId, line, names });
      });
    return out;
  });
}

test.describe("flow window hand-off", () => {
  test.use({ sourcePath: "calc/main.py", launchMode: "trace" });

  test("stepping from the module's window into main's leaves no module chip behind", async ({
    ctPage,
  }) => {
    test.setTimeout(300_000);
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();
    await layout.waitForEditorLoaded();

    // The module's window must actually have drawn on the `def` line first,
    // or the hand-off below has nothing to leave behind and the test proves
    // nothing. Step-ins 1..15 stay in `<__main__>` and end on its `main()`
    // call; #16 enters `main` (at its `def` line). Check the module chips
    // HERE, before that step: once `main`'s window has been requested, a
    // poll could see either window depending on when it arrives.
    let state = await readProgramState(ctPage);
    for (let i = 0; i < 15; i++) state = await operate(ctPage, "stepIn");
    expect(state.line, "still in the module, on its main() call").toBe(ModuleCallLine);
    await expect
      .poll(async () => (await flowLineWidgets(ctPage)).filter((w) => w.line === DefLine)
        .flatMap((w) => w.names), { timeout: 30_000 })
      .toContain("EXPRESSIONS");

    for (let i = 15; i < 21; i++) state = await operate(ctPage, "stepIn");
    state = await operate(ctPage, "stepOut");
    expect(state.line, "the PLAT-37 returned-calltrace stop").toBe(110);

    // `main`'s window draws `return` on its `def` line and nothing else.
    await expect
      .poll(async () => (await flowLineWidgets(ctPage)).filter((w) => w.line === DefLine)
        .flatMap((w) => w.names), { timeout: 30_000 })
      .toContain("return");
    // Give the deferred redraws (`scheduleFlowRedraw(100)` and the loop
    // iteration timers) time to run, so a late leftover is caught too.
    await ctPage.waitForTimeout(2_000);

    const widgets = await flowLineWidgets(ctPage);
    const onDef = widgets.filter((w) => w.line === DefLine);
    expect(
      onDef.flatMap((w) => w.names),
      "the def line carries main's window's values only — not the module's globals",
    ).toEqual(["return"]);

    // No line is drawn by two widgets: each id is registered once, so none
    // is an orphan Monaco no longer positions.
    const ids = widgets.map((w) => w.widgetId);
    expect(ids.length, "no flow widget was found at all").toBeGreaterThan(0);
    expect(new Set(ids).size, `duplicate flow widget ids: ${ids.join(", ")}`).toBe(ids.length);
    const lines = widgets.map((w) => w.line);
    expect(new Set(lines).size, `two flow widgets on one line: ${lines.join(", ")}`).toBe(
      lines.length,
    );
  });
});
