/**
 * Edit ↔ Debug transitions for specs that start in a DESKTOP edit session.
 *
 * WHY NOT `#run-image`. The `edit` launch mode (`launchEditMode` in
 * `fixtures.ts`) always starts Electron through `ct edit`, whatever
 * `deploymentMode` says, and the desktop has no Run that leaves Edit mode:
 * the edit-mode toolbar hides its command group for a folder it recognises
 * no project in (Edit-Mode-Toolbar.md §8, EMT-D13) and DISABLES Build and Run
 * for one it does recognise, because the Electron host has no route that
 * runs a toolbar command yet (§8.2, EMT-D30). A spec that clicked
 * `#run-image` there timed out on a button that is correctly absent, and
 * never reached a single assertion (EMT-D31).
 *
 * WHAT IS DRIVEN INSTEAD, and why it reaches the code under test. The way in
 * is the product's own mode toggle, `Ctrl+F5` (`session.toggle-product-mode`,
 * Mode-Transitions.md §1), which calls `switchToDebug` — the transition a Run
 * reaches once its trace exists, so the same `beginReadOnlyTransition` /
 * `setEditorsEditable` calls run. The way out is a real pointer click on
 * *Stop* (`#stop-image`), which goes through `stopReplaySession` to
 * `switchToEdit`: Stop is the control a user presses, and it is the subject of
 * `editor_is_writable_after_stop.spec.ts`, so it is not replaced by the chord.
 *
 * Both helpers wait for `data.ui.mode` to report the mode they asked for and
 * for that mode's topbar surface to be mounted, so an assertion that follows
 * cannot run against the mode the session is leaving.
 *
 * NO SOURCE TAB IS AWAITED IN DEBUG MODE. The Debug layout an edit session
 * toggles into carries no editor tab today, which Mode-Transitions.md §5 ("the
 * set of open editor tabs") does not allow; that is recorded as its own
 * defect. The Monaco instance is not destroyed: it is detached, still answers
 * `getOption`, and is the instance the Edit layout shows again after Stop. So
 * a caller samples it through Monaco rather than waiting for `.view-line`, and
 * `stopToEditMode` waits for the visible editor on the way back.
 */

import { expect } from "@playwright/test";

/** `LayoutMode` ordinals, as `data.ui.mode` carries them. */
export const DEBUG_MODE = 0;
export const EDIT_MODE = 1;

/** The session's current `LayoutMode` ordinal. */
export async function layoutMode(page: any): Promise<number> {
  return await page.evaluate(() => Number((globalThis as any).data?.ui?.mode));
}

/**
 * Enter Debug mode from an edit session with `Ctrl+F5`.
 *
 * Refuses to toggle from anything but Edit mode: `Ctrl+F5` switches to
 * whichever mode the session is NOT in, so pressing it from Debug would
 * silently do the opposite of what the caller asked.
 */
export async function enterDebugMode(page: any): Promise<void> {
  expect(
    await layoutMode(page),
    "enterDebugMode was called outside Edit mode, where Ctrl+F5 would leave Debug instead",
  ).toBe(EDIT_MODE);
  await page.keyboard.press("Control+F5");
  await expect
    .poll(async () => layoutMode(page), {
      timeout: 30_000,
      message: "Ctrl+F5 did not switch data.ui.mode to Debug",
    })
    .toBe(DEBUG_MODE);
  await page.waitForSelector(".isonim-debug-controls", { timeout: 60_000 });
  await page.locator("#stop-image").waitFor({ state: "visible", timeout: 60_000 });
}

/** Leave Debug mode by clicking *Stop*, and wait for Edit mode to be back. */
export async function stopToEditMode(page: any): Promise<void> {
  await page.locator("#stop-image").click({ timeout: 30_000 });
  await expect
    .poll(async () => layoutMode(page), {
      timeout: 60_000,
      message: "Stop did not return data.ui.mode to Edit",
    })
    .toBe(EDIT_MODE);
  await page.waitForSelector(".edit-mode-toolbar", { timeout: 60_000 });
  await page.waitForSelector(".view-line", { timeout: 60_000 });
}
