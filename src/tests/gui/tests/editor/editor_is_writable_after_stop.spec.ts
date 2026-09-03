/**
 * THE EDITOR IS WRITABLE AGAIN AFTER STOP.
 *
 * Reported: "After stopping a debug session, the editor remains read-only I
 * think."
 *
 * The user's own specification of Stop is the standard this asserts against:
 * "stop should behave in a similar way to Visual Studio Ultimate ... When you
 * stop the debugging session you get back to the edit mode and you can start a
 * new debugging session in the usual way." An editor you cannot type in is not
 * edit mode.
 *
 * THE ASSERTION IS A KEYSTROKE, NOT A FLAG. `readOnly` reading `false` is not
 * the claim — this campaign has repeatedly found the register right and the
 * screen wrong, and the specific trap in this file's neighbourhood is that
 * `setEditorsEditable` once handed Monaco a Nim object literal, so a call that
 * meant "readOnly: false" also said `fontSize: 0, fontFamily: ""`. A flag
 * check would have passed on that build. So the test types a character and
 * requires it to arrive in the model.
 *
 * THE CONTROL IS THE SAME KEYSTROKE BEFORE RUN. Without it the test could pass
 * vacuously on a build where typing never works anywhere, or fail for a reason
 * that has nothing to do with Stop (an unfocused editor, a modal, a missing
 * fixture). The before-Run sample proves the instrument reaches the buffer on
 * this build; the after-Stop sample is then the only variable.
 *
 * See `editor_font_survives_mode_switch.spec.ts` for the other half of the
 * same proc's contract, and for the Run/Stop driving used here.
 */

import * as path from "node:path";

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";

const testFolder = path.join(codetracerInstallDir, "test-programs");

/**
 * The state of THE SOURCE EDITOR THE USER IS LOOKING AT.
 *
 * Resolved through `data.ui.editors[data.services.editor.active]` rather than
 * `monaco.editor.getEditors()[0]`, and the difference is not cosmetic.
 * `getEditors()` returns every Monaco instance on the page, including two that
 * are constructed with a hard-coded flag and never follow the mode: the
 * tracepoint editor is built `readOnly: false` unconditionally
 * (`ui/trace.nim:1671-1680`) and the inline diff editor `readOnly: true`
 * (`ui/editor.nim:1938`). So "some editor is editable" — which is what
 * `ci/test/noir_mode_roundtrip_probe.mjs:147` computes as `anyEditable`, and
 * what the three-round-trip gate asserts after every Stop — is satisfied by a
 * tracepoint editor alone, with the source editor read-only.
 *
 * `readOnlyFlags` is carried along for the failure message: it is the reading
 * the existing gate would have taken, so a failure here shows both what the
 * user experiences and what the weaker instrument would have said.
 */
async function readEditorState(page: any): Promise<{
  text: string;
  readOnly: boolean;
  readOnlyFlags: boolean[];
}> {
  await page.waitForFunction(
    () =>
      typeof (globalThis as any).monaco !== "undefined" &&
      (globalThis as any).monaco.editor.getEditors().length > 0,
    { timeout: 60_000 },
  );

  return page.evaluate(() => {
    const w = globalThis as any;
    const m = w.monaco;
    const data = w.data;
    const editor =
      data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor ??
      m.editor.getEditors()[0];
    return {
      text: editor.getModel().getValue() as string,
      readOnly: editor.getOption(m.editor.EditorOption.readOnly) as boolean,
      readOnlyFlags: m.editor
        .getEditors()
        .map((e: any) => e.getOption(m.editor.EditorOption.readOnly) as boolean),
    };
  });
}

/**
 * Put the caret in the editor and type `marker`, then report whether the model
 * changed. Focus is taken through Monaco's own `focus()` rather than a click,
 * so a decoration or view zone sitting over the text cannot swallow the
 * gesture and make a writable editor look read-only.
 */
async function typeIntoEditor(page: any, marker: string): Promise<boolean> {
  const before = (await readEditorState(page)).text;

  await page.evaluate(() => {
    const w = globalThis as any;
    const data = w.data;
    const editor =
      data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor ??
      w.monaco.editor.getEditors()[0];
    editor.setPosition({ lineNumber: 1, column: 1 });
    editor.focus();
  });
  await page.keyboard.type(marker);

  const after = (await readEditorState(page)).text;
  return after !== before && after.includes(marker);
}

test.describe("The editor after a debug session is stopped", () => {
  test.setTimeout(300_000);
  test.use({
    launchMode: "edit",
    editFolderPath: testFolder,
    deploymentMode: "web",
  });

  test("a keystroke reaches the buffer after Stop", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 90_000 });

    // CONTROL. If this fails the instrument is broken, not the Stop path.
    const writableBefore = await typeIntoEditor(ctPage, "CT_BEFORE_RUN");
    expect(
      writableBefore,
      "control failed: the editor did not accept a keystroke even before " +
        "any debug session, so this run proves nothing about Stop",
    ).toBe(true);

    // Enter debug mode.
    await ctPage.locator("#run-image").click({ timeout: 30_000 });
    await ctPage.waitForSelector(".isonim-debug-controls", { timeout: 180_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 60_000 });

    // Leave it again.
    await ctPage.locator("#stop-image").click({ timeout: 30_000 });
    await ctPage.waitForSelector(".edit-mode-toolbar", { timeout: 180_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 60_000 });

    const stateAfter = await readEditorState(ctPage);
    const writableAfter = await typeIntoEditor(ctPage, "CT_AFTER_STOP");
    expect(
      writableAfter,
      "the editor did not accept a keystroke after Stop. The ACTIVE source " +
        `editor's readOnly option reads ${stateAfter.readOnly}; across every ` +
        `Monaco instance on the page the flags are ` +
        `${JSON.stringify(stateAfter.readOnlyFlags)}, so the existing gate's ` +
        `anyEditable would report ` +
        `${stateAfter.readOnlyFlags.some((f) => f === false)}. Stop is ` +
        "specified to return to edit mode, where a new debugging session can " +
        "be started in the usual way (Mode-Transitions.md §5a).",
    ).toBe(true);
  });

  test("CTRL+E restores editability if Stop did not", async ({ ctPage }) => {
    // A narrowing measurement, not a duplicate. CTRL+E dispatches
    // `toggleReadOnly` from the config (`aToggleReadOnly` in
    // default_config.yaml), which drives the SAME `setEditorsEditable`. If the
    // chord restores typing after Stop failed to, the editable state is
    // reachable and only the Stop path is at fault — a much narrower defect
    // than "the editor cannot be made writable at all".
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 90_000 });

    await ctPage.locator("#run-image").click({ timeout: 30_000 });
    await ctPage.waitForSelector(".isonim-debug-controls", { timeout: 180_000 });
    await ctPage.locator("#stop-image").click({ timeout: 30_000 });
    await ctPage.waitForSelector(".edit-mode-toolbar", { timeout: 180_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 60_000 });

    const afterStop = await typeIntoEditor(ctPage, "CT_AFTER_STOP_2");

    await ctPage.evaluate(() => {
      const m = (globalThis as any).monaco;
      m.editor.getEditors()[0].focus();
    });
    await ctPage.keyboard.press("Control+e");
    await ctPage.waitForTimeout(1000);
    const afterChord = await typeIntoEditor(ctPage, "CT_AFTER_CHORD");

    // Recorded as a single combined claim so the failure message names which
    // of the two states held.
    expect(
      { afterStop, afterChord },
      "measurement of where editability becomes reachable",
    ).toEqual({ afterStop: true, afterChord: true });
  });
});
