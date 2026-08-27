import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

function makeFixtureDir(prefix: string, content: string): { dir: string; file: string } {
  const baseDir = path.join(process.cwd(), "non-nix-build", "tmp");
  fs.mkdirSync(baseDir, { recursive: true });
  const dir = fs.mkdtempSync(path.join(baseDir, prefix));
  const file = path.join(dir, "main.py");
  fs.writeFileSync(file, content, "utf8");
  return { dir, file };
}

async function activeEditorValue(ctPage: any): Promise<string> {
  return await ctPage.evaluate(() => {
    return Array.from(document.querySelectorAll(".monaco-editor .view-lines"))
      .map((node) => (node as HTMLElement).innerText.replace(/\u00a0/g, " "))
      .join("\n");
  });
}

async function setActiveEditorValue(ctPage: any, value: string): Promise<void> {
  // Column 0, for the reason spelled out on `enterEditMode` below: an inline
  // omniscience value chip covers the middle of the line and would swallow an
  // unpositioned click.
  await ctPage
    .locator(".monaco-editor .view-line")
    .first()
    .click({ position: { x: 2, y: 2 } });
  await ctPage.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await ctPage.keyboard.type(value);
}

/**
 * Accumulate every notification that ever appears in `#active-notifications`.
 *
 * Polling the DOM at assertion time is not enough: notifications auto-dismiss,
 * so the one message that proves the recorder was actually dispatched
 * ("Building/recording a new trace…") can come and go between two polls.  The
 * observer keeps a de-duplicated log of `<kind-class>|<message>` entries for
 * the rest of the test.
 *
 * It ALSO records the *instantaneous* multiset of notifications at every tick,
 * which the de-duplicated log cannot express and which issue #603 turns on: the
 * reporter saw a *stack* of identical messages, and the toast stack is capped
 * at three by `NOTIFICATION_LIMIT` (`src/frontend/ui/status.nim`), so "how
 * many" is answered by the largest number of matching toasts ever on screen at
 * the same moment.  Consecutive identical snapshots are collapsed, so the array
 * stays short over a five-minute test.
 *
 * This used to mark each element with `data-ct-counted` the first time it was
 * seen and accumulate, which over-counts and cannot be repaired by polling
 * less: `renderStatusInto`
 * (`src/frontend/viewmodel/views/isonim_status_view.nim`) removes *every* child
 * of `#status` and rebuilds the subtree whenever `statusStructureSignature`
 * changes, and that signature folds in each active notification's `index` and
 * `text`.  So every notification that appears or disappears destroys and
 * re-creates the elements of the toasts still on screen, taking their
 * `data-ct-counted` attribute with them, and the same single toast is counted
 * again.  A peak-concurrency measure is immune to that — a rebuild reproduces
 * the same instantaneous set — and it is a closer reading of the evidence than
 * the cumulative count was: what the reporter photographed is three identical
 * toasts stacked *at once*, not three dispatches spread over time.
 */
async function recordNotifications(ctPage: any): Promise<void> {
  await ctPage.evaluate(() => {
    const w = window as any;
    if (w.__ctNotificationLog) return;
    w.__ctNotificationLog = [];
    w.__ctNotificationTicks = [];
    let previousTick = "";
    const capture = () => {
      const host = document.querySelector("#active-notifications");
      if (!host) return;
      const present: Record<string, number> = {};
      host.querySelectorAll(".ct-notification").forEach((node: Element) => {
        const message =
          (node.querySelector(".notification-message") as HTMLElement | null)
            ?.innerText ?? "";
        const kind =
          Array.from(node.classList).find(
            (name) => name.startsWith("ct-notification-") && name.length > "ct-notification-".length,
          ) ?? "ct-notification-unknown";
        const entry = `${kind}|${message}`;
        if (!w.__ctNotificationLog.includes(entry)) {
          w.__ctNotificationLog.push(entry);
        }
        present[entry] = (present[entry] ?? 0) + 1;
      });
      const tick = JSON.stringify(present);
      if (tick !== previousTick) {
        previousTick = tick;
        w.__ctNotificationTicks.push(present);
      }
    };
    capture();
    new MutationObserver(capture).observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true,
    });
    w.__ctNotificationTimer = setInterval(capture, 100);
  });
}

async function seenNotifications(ctPage: any): Promise<string[]> {
  return await ctPage.evaluate(
    () => ((window as any).__ctNotificationLog ?? []) as string[],
  );
}

/**
 * The largest number of notification elements carrying a message containing
 * `substring` that were ever on screen *at the same moment*.  One per live
 * dispatch — `renderer.launchReRecord` emits "Building/recording a new trace…"
 * exactly once per `CODETRACER::new-record`, and three concurrent dispatches
 * are what the reporter photographed.
 *
 * Peak concurrency rather than a running total, because the status bar's DOM
 * is rebuilt from scratch whenever its structure signature changes — see the
 * note on `recordNotifications`.
 */
async function notificationCount(ctPage: any, substring: string): Promise<number> {
  return await ctPage.evaluate((needle: string) => {
    const ticks = ((window as any).__ctNotificationTicks ?? []) as Record<string, number>[];
    let peak = 0;
    for (const tick of ticks) {
      let concurrent = 0;
      for (const entry of Object.keys(tick)) {
        if (entry.includes(needle)) concurrent += tick[entry];
      }
      if (concurrent > peak) peak = concurrent;
    }
    return peak;
  }, substring);
}

async function seenErrors(ctPage: any): Promise<string[]> {
  return (await seenNotifications(ctPage)).filter((entry) =>
    entry.startsWith("ct-notification-error"),
  );
}

/**
 * The identity of the trace the window is currently replaying.
 *
 * `data.trace` is a Nim *template* over `sessions[activeSessionIndex].trace`,
 * so it does not exist as a JS property — the session array has to be read
 * directly.  A change of `recordingId` is the only observable that proves a
 * new recording was produced and loaded; the re-record queue being empty
 * proves nothing, because it is emptied by success, by an early return and by
 * a throw alike.
 */
async function currentRecordingId(ctPage: any): Promise<string | null> {
  return await ctPage.evaluate(() => {
    const data = (window as any).__CODETRACER_DATA__;
    if (!data || !data.sessions) return null;
    const session = data.sessions[data.activeSessionIndex];
    if (!session || !session.trace) return null;
    return String(session.trace.recordingId ?? "");
  });
}

async function pendingReRecordIsSet(ctPage: any): Promise<boolean> {
  return await ctPage.evaluate(() => {
    const data = (window as any).__CODETRACER_DATA__;
    return Boolean(data && data.pendingReRecord);
  });
}

/**
 * Leave replay's read-only editors so the buffer can be edited (Ctrl+E).
 *
 * Clicks the *start* of the first code line rather than its centre.  Once a
 * replay has inline omniscience values, a `span.ct-omni-name-std` content
 * widget sits over the middle of the line — that is where the values are
 * drawn — and an unpositioned click lands on it, so Playwright's actionability
 * check reports *"subtree intercepts pointer events"* and retries for the full
 * 30s before failing.  Those spans are deliberately clickable
 * (`page-objects/panes/editor/flow-value.ts` clicks them), so the widget is
 * not what should change; where in the line the helper aims is.  Column 0 of
 * the line is code, never a value chip.
 *
 * NOTE (2026-08-27): getting past this reveals the next blocker rather than a
 * green test — the three re-record cases now fail on the assertion that the
 * typed text reached the buffer (`activeEditorValue` still reads
 * `print("initial")`), i.e. the editor does not actually leave read-only mode.
 * Dropping the click entirely and sending the shortcut to `document.body`
 * — on the theory that Mousetrap ignores keys raised inside a focused editable
 * element — was tried and changes nothing, so that is not the explanation.
 * These cases had never been executed anywhere before the renderer startup
 * crash was fixed, so this is a first observation, not a regression.
 */
async function enterEditMode(ctPage: any): Promise<void> {
  await ctPage
    .locator(".monaco-editor .view-line")
    .first()
    .click({ position: { x: 2, y: 2 } });
  await ctPage.keyboard.press("Control+E");
}

const cleanFixture = makeFixtureDir("ct-file-watch-clean-", 'print("initial")\n');
const dirtyFixture = makeFixtureDir("ct-file-watch-dirty-", 'print("initial")\n');
const reRecordFixture = makeFixtureDir(
  "ct-re-record-", 'print("initial")\n');
const readOnlyFixture = makeFixtureDir(
  "ct-re-record-readonly-", 'print("initial")\n');
const burstFixture = makeFixtureDir(
  "ct-re-record-burst-", 'print("initial")\n');

test.describe("External File Changes - clean buffers", () => {
  test.use({ launchMode: "edit", editFolderPath: cleanFixture.dir });

  test("clean open files reload after external disk changes", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("initial");

    fs.writeFileSync(cleanFixture.file, 'print("external clean reload")\n', "utf8");

    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("external clean reload");
  });
});

test.describe("External File Changes - dirty buffers", () => {
  test.use({ launchMode: "edit", editFolderPath: dirtyFixture.dir });

  test("dirty open files prompt before reloading external disk changes", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("initial");

    await setActiveEditorValue(ctPage, 'print("ours in memory")\n');
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("ours in memory");

    fs.writeFileSync(dirtyFixture.file, 'print("theirs on disk")\n', "utf8");

    const dialog = ctPage.locator(".file-conflict-dialog", { hasText: "changed on disk" });
    await expect(dialog).toBeVisible({ timeout: 10_000 });
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("ours in memory");
  });

});

/**
 * Issue #603.  The previous version of this test could not pass and would not
 * have proved anything if it had:
 *
 *   * it called `data.reRecordCurrent(...)`, which is not a property of the
 *     data object — Nim emits a free function;
 *   * it assigned `data.trace`, which is a Nim template and therefore inert;
 *   * it ran in `launchMode: "edit"`, where `reRecordCurrent` returns before
 *     the dirty check ever runs;
 *   * and its success condition was `pendingReRecord == null`, which is
 *     equally true after a successful dispatch, an early return and a throw.
 *
 * The rewrite drives the real Ctrl+R shortcut against a real loaded trace and
 * asserts the only thing that means "the program was launched": the recording
 * id changes.
 */
test.describe("Re-record after edits", () => {
  test.use({ launchMode: "trace", sourcePath: reRecordFixture.file });

  test("Ctrl+R saves the dirty buffer and records a new trace", async ({ ctPage }) => {
    test.setTimeout(300_000);

    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15_000 });
    await recordNotifications(ctPage);

    const originalRecordingId = await currentRecordingId(ctPage);
    expect(originalRecordingId).toBeTruthy();

    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 20_000 })
      .toContain("initial");

    // Replay mode mounts Monaco read-only; Ctrl+E is the user-facing way out.
    await enterEditMode(ctPage);
    await setActiveEditorValue(ctPage, 'print("re-recorded marker")\n');
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("re-recorded marker");

    await ctPage.keyboard.press("Control+R");

    // The queue was armed and drained: the dispatch notification only exists
    // on the far side of the save round-trip (`renderer.launchReRecord`).
    await expect.poll(async () => seenNotifications(ctPage), { timeout: 60_000 })
      .toEqual(expect.arrayContaining([
        expect.stringContaining("Building/recording a new trace"),
      ]));

    // The program actually ran and its trace replaced the old one.
    await expect.poll(async () => currentRecordingId(ctPage), { timeout: 180_000 })
      .not.toBe(originalRecordingId);

    // The edit reached disk and the new recording sees it.
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 30_000 })
      .toContain("re-recorded marker");
    expect(fs.readFileSync(reRecordFixture.file, "utf8"))
      .toContain("re-recorded marker");

    expect(await seenErrors(ctPage)).toEqual([]);
    expect(await pendingReRecordIsSet(ctPage)).toBe(false);
  });
});

/**
 * Issue #603, second defect — the rendering half of the headless suite
 * "Re-record is single-flight" in `re_record_queue_vm_test.nim`.
 *
 * The reporter's two screenshots two months apart both show exactly three
 * stacked identical notifications.  Three is `NOTIFICATION_LIMIT`
 * (`src/frontend/ui/status.nim`) — the toast stack's ceiling — so the count
 * they show is a floor, not a total: the recorder was launched *at least*
 * three times for one user action.  Concurrent `ct record` runs share the
 * project build directory and the index's single `data.recordProcess` slot,
 * so they fight and the program never starts.
 *
 * This test counts notification ELEMENTS rather than distinct messages,
 * because the de-duplicated log the other cases use cannot tell one dispatch
 * from ten.
 */
test.describe("Re-record while one is already running", () => {
  test.use({ launchMode: "trace", sourcePath: burstFixture.file });

  test("a burst of Ctrl+R presses starts one recorder and says why", async ({ ctPage }) => {
    test.setTimeout(300_000);

    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15_000 });
    await recordNotifications(ctPage);

    const originalRecordingId = await currentRecordingId(ctPage);
    expect(originalRecordingId).toBeTruthy();

    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 20_000 })
      .toContain("initial");

    await enterEditMode(ctPage);
    await setActiveEditorValue(ctPage, 'print("burst marker")\n');
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("burst marker");

    // Three presses, no waiting between them: key auto-repeat and an
    // impatient user both look exactly like this.
    await ctPage.keyboard.press("Control+R");
    await ctPage.keyboard.press("Control+R");
    await ctPage.keyboard.press("Control+R");

    // One recorder was launched...
    await expect.poll(
      async () => notificationCount(ctPage, "Building/recording a new trace"),
      { timeout: 60_000 },
    ).toBe(1);

    // ...and the presses that were refused said so, rather than going quiet.
    await expect.poll(async () => seenNotifications(ctPage), { timeout: 60_000 })
      .toEqual(expect.arrayContaining([
        expect.stringContaining("already"),
      ]));

    // The single recording still completes and replaces the trace: refusing
    // the extra presses must not cost the user the one they meant.
    await expect.poll(async () => currentRecordingId(ctPage), { timeout: 180_000 })
      .not.toBe(originalRecordingId);
    expect(await notificationCount(ctPage, "Building/recording a new trace")).toBe(1);
    expect(await notificationCount(ctPage, "ct record process started")).toBeLessThanOrEqual(1);

    // And the gate reopens afterwards, so re-recording is not a one-shot.
    await expect.poll(async () => pendingReRecordIsSet(ctPage), { timeout: 30_000 })
      .toBe(false);
  });
});

test.describe("Re-record when the save fails", () => {
  test.use({ launchMode: "trace", sourcePath: readOnlyFixture.file });

  test("a failed save aborts loudly instead of hanging", async ({ ctPage }) => {
    test.setTimeout(180_000);
    // A root-owned run can write to a 0444 file, so the failure cannot be
    // provoked; skipping is honest, silently passing would not be.
    const uid = typeof process.getuid === "function" ? process.getuid() : -1;
    test.skip(uid === 0, "cannot make a file unwritable as root");

    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15_000 });
    await recordNotifications(ctPage);

    const originalRecordingId = await currentRecordingId(ctPage);
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 20_000 })
      .toContain("initial");

    await enterEditMode(ctPage);
    await setActiveEditorValue(ctPage, 'print("never reaches disk")\n');
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("never reaches disk");

    fs.chmodSync(readOnlyFixture.file, 0o444);
    try {
      await ctPage.keyboard.press("Control+R");

      // The save fails, so the re-record must fail *visibly* rather than
      // leave the queue armed with nothing left to drain it.
      await expect.poll(async () => seenErrors(ctPage), { timeout: 30_000 })
        .not.toEqual([]);
      await expect.poll(async () => pendingReRecordIsSet(ctPage), { timeout: 30_000 })
        .toBe(false);

      const seen = await seenNotifications(ctPage);
      expect(seen.filter((entry) => entry.includes("Building/recording a new trace")))
        .toEqual([]);
      expect(await currentRecordingId(ctPage)).toBe(originalRecordingId);
    } finally {
      fs.chmodSync(readOnlyFixture.file, 0o644);
    }
  });
});
