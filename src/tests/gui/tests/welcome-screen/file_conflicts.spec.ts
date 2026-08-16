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
  await ctPage.locator(".monaco-editor .view-line").first().click();
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
 */
async function recordNotifications(ctPage: any): Promise<void> {
  await ctPage.evaluate(() => {
    const w = window as any;
    if (w.__ctNotificationLog) return;
    w.__ctNotificationLog = [];
    const capture = () => {
      const host = document.querySelector("#active-notifications");
      if (!host) return;
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
      });
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

/** Leave replay's read-only editors so the buffer can be edited (Ctrl+E). */
async function enterEditMode(ctPage: any): Promise<void> {
  await ctPage.locator(".monaco-editor .view-line").first().click();
  await ctPage.keyboard.press("Control+E");
}

const cleanFixture = makeFixtureDir("ct-file-watch-clean-", 'print("initial")\n');
const dirtyFixture = makeFixtureDir("ct-file-watch-dirty-", 'print("initial")\n');
const reRecordFixture = makeFixtureDir(
  "ct-re-record-", 'print("initial")\n');
const readOnlyFixture = makeFixtureDir(
  "ct-re-record-readonly-", 'print("initial")\n');

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
