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
 * same proc's contract. Debug mode is entered with `Ctrl+F5` and left with a
 * real click on Stop (`lib/mode-switch.ts`): this is an Electron edit session,
 * where Run does not leave Edit mode. Stop, the subject here, is still the
 * control that is pressed.
 */

import * as path from "node:path";

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { enterDebugMode, stopToEditMode } from "../../lib/mode-switch";

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
    // The `edit` launch is always Electron (`ct edit`); `lib/mode-switch.ts`.
    deploymentMode: "electron",
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
    await enterDebugMode(ctPage);

    // Leave it again.
    await stopToEditMode(ctPage);

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

  test("Stop repairs an editor that is read-only while the flag says otherwise", async ({
    ctPage,
  }) => {
    // THE EXACT HOLE THE CHANGE GUARD LEFT, and the case the ordinary
    // Run/Stop test above cannot reach.
    //
    // On the plain path `data.ui.readOnly` goes true at Run and false at Stop,
    // so the flag CHANGED and the guarded call fired. The defect needs the flag
    // and the editors to disagree, and `Mode-Transitions.md` §4.4 makes that
    // reachable on purpose: CTRL+E (`aToggleReadOnly`) clears `data.ui.readOnly`
    // mid-session and deliberately does not touch `data.ui.mode`. Stop then
    // asked for `readOnly = false` against a flag already reading `false`,
    // `beginReadOnlyTransition` returned `changed = false`, and BOTH halves of
    // the transition were skipped: no `setEditorsEditable`, and no
    // `disableDebugShortcuts` loop to reset Monaco's `readOnly` context key.
    //
    // The disagreement is then FORCED rather than hoped for. Clearing the flag
    // with CTRL+E and putting the visible editor back to `readOnly: true`
    // underneath it reproduces the state in one step, instead of relying on a
    // particular sequence of pane teardowns to produce it. What is asserted is
    // still the user's own property — a typed character reaching the buffer —
    // and Stop is still the only thing between the two readings.
    //
    // TWO THINGS REPAIR IT ON THIS ROUTE, and this test pins only that one of
    // them does. The Debug layout an edit session toggles into does not carry
    // the editor tab, so the Monaco instance is detached in Debug, and Stop
    // re-attaches it through `reattachMonacoIfDetached` (`ui/editor.nim`),
    // which applies `data.ui.readOnly` itself. Measured against `839457a1d`:
    // with the change guard put back (`readOnlyTransitionAppliesEditability`
    // returning `flagChanged`), this test stayed GREEN; with the guard put
    // back AND the re-attach's `monacoEditorSetReadOnly` removed, it went RED
    // here. The guard on its own is the subject of the headless
    // `read_only_transition_test.nim`.
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 90_000 });

    const writableBefore = await typeIntoEditor(ctPage, "CT_GUARD_CONTROL");
    expect(
      writableBefore,
      "control failed: the editor did not accept a keystroke before any debug " +
        "session, so this run proves nothing about Stop",
    ).toBe(true);

    await enterDebugMode(ctPage);

    // Construct the disagreement: model flag false, visible editor read-only.
    const staged = await ctPage.evaluate(() => {
      const w = globalThis as any;
      const data = w.data;
      const editor =
        data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor ??
        w.monaco.editor.getEditors()[0];
      data.ui.readOnly = false;
      editor.updateOptions({ readOnly: true });
      // Marked so the editor typed into after Stop can be shown to be THIS
      // instance. A Stop that built a fresh Monaco would make it writable
      // without repairing anything, and the test would pass vacuously.
      editor.__ctStagedReadOnly = true;
      return {
        flag: data.ui.readOnly,
        editorReadOnly: editor.getOption(
          w.monaco.editor.EditorOption.readOnly,
        ) as boolean,
      };
    });
    // The precondition is asserted, not assumed. If the two do not actually
    // disagree at this point the test below would pass for the wrong reason.
    expect(
      staged,
      "could not stage the disagreement the change guard is blind to",
    ).toEqual({ flag: false, editorReadOnly: true });

    await stopToEditMode(ctPage);

    const sameInstance = await ctPage.evaluate(() => {
      const w = globalThis as any;
      const data = w.data;
      const editor =
        data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor ??
        w.monaco.editor.getEditors()[0];
      return editor.__ctStagedReadOnly === true;
    });
    expect(
      sameInstance,
      "the editor shown after Stop is not the one staged read-only, so this " +
        "run says nothing about whether Stop repairs it",
    ).toBe(true);

    const stateAfter = await readEditorState(ctPage);
    const writableAfter = await typeIntoEditor(ctPage, "CT_AFTER_GUARDED_STOP");
    expect(
      writableAfter,
      "the editor did not accept a keystroke after Stop, in the one case the " +
        "transition could not see: `data.ui.readOnly` already read false while " +
        "the editor was read-only, so the guarded `setEditorsEditable` made " +
        `zero calls. The active editor's readOnly reads ${stateAfter.readOnly}; ` +
        `across the page the flags are ${JSON.stringify(stateAfter.readOnlyFlags)}. ` +
        "§5a states the transition as an arrival, not a difference.",
    ).toBe(true);
  });

  test("CTRL+E still takes and gives back editability after Stop", async ({ ctPage }) => {
    // A narrowing measurement, not a duplicate. CTRL+E dispatches
    // `toggleReadOnly` from the config (`aToggleReadOnly` in
    // default_config.yaml), which drives the SAME `setEditorsEditable`. If the
    // chord restores typing after Stop failed to, the editable state is
    // reachable and only the Stop path is at fault — a much narrower defect
    // than "the editor cannot be made writable at all".
    //
    // CTRL+E IS A TOGGLE (Mode-Transitions.md §4.4), so on a build where Stop
    // works, one press makes the editor READ-ONLY. A single press followed by
    // "typing works" can only pass when Stop is broken, which is how this test
    // was written and why it cannot stand as-is beside the two above. It
    // drives the chord twice instead: the first press must take editability
    // away (proof the chord reached `setEditorsEditable` at all, and not a
    // keystroke lost to focus), the second must give it back.
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 90_000 });

    await enterDebugMode(ctPage);
    await stopToEditMode(ctPage);

    const afterStop = await typeIntoEditor(ctPage, "CT_AFTER_STOP_2");

    await ctPage.evaluate(() => {
      const m = (globalThis as any).monaco;
      m.editor.getEditors()[0].focus();
    });
    await ctPage.keyboard.press("Control+e");
    await ctPage.waitForTimeout(1000);
    const afterFirstChord = await typeIntoEditor(ctPage, "CT_AFTER_CHORD_1");

    await ctPage.evaluate(() => {
      const m = (globalThis as any).monaco;
      m.editor.getEditors()[0].focus();
    });
    await ctPage.keyboard.press("Control+e");
    await ctPage.waitForTimeout(1000);
    const afterSecondChord = await typeIntoEditor(ctPage, "CT_AFTER_CHORD_2");

    // Recorded as a single combined claim so the failure message names which
    // of the three states held.
    expect(
      { afterStop, afterFirstChord, afterSecondChord },
      "measurement of where editability becomes reachable",
    ).toEqual({ afterStop: true, afterFirstChord: false, afterSecondChord: true });
  });
});
