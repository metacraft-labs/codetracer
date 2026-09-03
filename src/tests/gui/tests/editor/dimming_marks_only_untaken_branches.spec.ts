/**
 * DIMMING MARKS UNTAKEN BRANCHES, NOT EVERYTHING ABOVE THE CURSOR.
 *
 * Reported: "Sometimes the dimming after a jump works in surprising ways. I
 * jump into a function and all of its lines before the current line get
 * dimmed. To remind you, my expectation is that dimming should be applied only
 * to lines that represent non-taken if/switch/case/etc branches."
 *
 * WHAT DIMMING IS. `opacity: 0.5`, applied by the inline Monaco decoration
 * classes `line-flow-skip` and `line-flow-unknown`
 * (`styles/components/flow.styl:659-671`). Its counterpart `line-flow-hit` is
 * `opacity: 1`. The two dimmed classes are visually identical, so the reader
 * sees one state, not two, and this test treats them as one.
 *
 * WHAT IT IS KEYED ON TODAY. Membership of the line number in
 * `FlowViewUpdate.relevantStepCount` — the lines the omniscience flow walker
 * recorded a step for in the current window (`ui/flow_line_styles.nim:96-104`,
 * `ui/editor.nim:812-843`). Not "this line is in a branch the run declined to
 * enter". The two answers coincide often enough to hide the difference,
 * because code above the cursor in a function you just entered frequently has
 * not run yet — which is presumably how it survived.
 *
 * THE GROUND TRUTH IS THE PROGRAM, NOT THE WALKER. Asking the flow window
 * which lines ran and then checking the dimming against it would be circular:
 * that set is the very thing under test. So the reference line is chosen from
 * `test-programs/noir_space_ship/src/shield.nr` by reading the source.
 * `calculate_damage` (lines 22-38) opens with
 *
 *     26 |     let shield_pct = calculate_remaining_shield_pct(...);
 *     27 |     let mut damage = 0;
 *     28 |     if(shield_pct == 100){
 *
 * Line 26 is unconditional and is the first statement of the function: any
 * position inside `calculate_damage` below line 26 is reachable ONLY by
 * having executed line 26 first. It is also not a conditional, not an arm of
 * one, and not inside one. Under the stated rule it must never be dimmed. That
 * claim depends on the shape of the fixture and on nothing the debugger
 * reports, so it stays falsifiable however the flow window is computed.
 *
 * THE CONTROL is the same reading taken at the same moment for the untaken
 * arm. Exactly one of lines 29 and 32 runs on any pass through
 * `calculate_damage`; the other is a genuine non-taken branch and SHOULD be
 * dimmed. If neither is dimmed the run produced no dimming at all and the
 * absence of dimming on line 26 would prove nothing.
 */

import { test, expect, readyOnEntryTest as readyOnEntry } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout_page";

test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });
test.setTimeout(300_000);

/** The first statement of `calculate_damage`; unconditional, never a branch. */
const UNCONDITIONAL_FIRST_STATEMENT = 26;
/** The `if` arm's body. */
const IF_ARM_BODY = 29;
/** The `else` arm's body. Exactly one of these two runs per call. */
const ELSE_ARM_BODY = 32;
/** Where we stop: below all of the above, still inside `calculate_damage`. */
const STOP_LINE = 34;

type Reading = {
  currentLine: number;
  dimmed: number[];
  hit: number[];
};

/**
 * Read, by line number, which lines Monaco is currently dimming.
 *
 * Taken from the decorations themselves rather than from the DOM: Monaco does
 * not annotate `.view-line` with a line number, and a virtualised editor only
 * renders what is on screen, so a DOM sweep would silently report "not dimmed"
 * for a line that is merely scrolled out of view.
 */
async function readDimming(page: any): Promise<Reading> {
  await page.waitForFunction(
    () =>
      typeof (globalThis as any).monaco !== "undefined" &&
      (globalThis as any).monaco.editor.getEditors().length > 0,
    { timeout: 60_000 },
  );

  return page.evaluate(() => {
    const w = globalThis as any;
    const data = w.data;
    const editor =
      data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor ??
      w.monaco.editor.getEditors()[0];
    const model = editor.getModel();

    const dimmed: number[] = [];
    const hit: number[] = [];
    for (const d of model.getAllDecorations()) {
      const cls: string = d.options?.inlineClassName ?? "";
      if (cls.includes("line-flow-skip") || cls.includes("line-flow-unknown")) {
        dimmed.push(d.range.startLineNumber);
      } else if (cls.includes("line-flow-hit")) {
        hit.push(d.range.startLineNumber);
      }
    }
    const uniqSorted = (xs: number[]) =>
      [...new Set(xs)].sort((a, b) => a - b);
    return {
      currentLine: data?.services?.debugger?.location?.line ?? -1,
      dimmed: uniqSorted(dimmed),
      hit: uniqSorted(hit),
    };
  });
}

/** Toggle a breakpoint by clicking the CodeTracer gutter for `line`. */
async function toggleBreakpoint(page: any, line: number): Promise<void> {
  const coords = await page.evaluate((lineNumber: number) => {
    const gutter = document.querySelector(
      `.monaco-editor .margin-view-overlays .gutter[data-line='${lineNumber}']`,
    );
    if (!gutter) return null;
    const r = gutter.getBoundingClientRect();
    if (r.height === 0) return null;
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }, line);
  if (!coords) {
    throw new Error(`gutter row for line ${line} is not laid out`);
  }
  await page.mouse.click(coords.x, coords.y);
}

test("a line that already ran is not dimmed just for being above the cursor", async ({
  ctPage,
}) => {
  await readyOnEntry(ctPage);
  await ctPage.waitForSelector(".view-line", { timeout: 90_000 });

  // Jump into `calculate_damage` and stop below its opening statements —
  // the exact situation the report describes.
  await toggleBreakpoint(ctPage, STOP_LINE);
  await new LayoutPage(ctPage).continueButton().click({ timeout: 30_000 });
  await ctPage.waitForFunction(
    (line: number) =>
      (globalThis as any).data?.services?.debugger?.location?.line === line,
    STOP_LINE,
    { timeout: 120_000 },
  );
  // Let the flow window for the new position arrive and repaint.
  await ctPage.waitForTimeout(4000);

  const reading = await readDimming(ctPage);

  // CONTROL: this run must be producing dimming at all, and it must be
  // producing it on a real untaken arm. Exactly one of 29/32 runs.
  const armsDimmed = [IF_ARM_BODY, ELSE_ARM_BODY].filter((l) =>
    reading.dimmed.includes(l),
  );
  expect(
    armsDimmed.length,
    `control failed: neither arm body (${IF_ARM_BODY}/${ELSE_ARM_BODY}) of ` +
      `calculate_damage's if/else is dimmed, so this run shows no branch ` +
      `dimming and proves nothing. reading=${JSON.stringify(reading)}`,
  ).toBe(1);

  // THE CLAIM. Line 26 is the function's first statement, unconditional, and
  // sits above the cursor. Reaching line 34 required running it.
  expect(
    reading.dimmed,
    `line ${UNCONDITIONAL_FIRST_STATEMENT} is dimmed at line ` +
      `${reading.currentLine}, but it is the unconditional first statement ` +
      `of calculate_damage and had to have executed to get here. Dimming is ` +
      `for lines in branches the run did not take. ` +
      `dimmed=${JSON.stringify(reading.dimmed)} ` +
      `hit=${JSON.stringify(reading.hit)}`,
  ).not.toContain(UNCONDITIONAL_FIRST_STATEMENT);
});
