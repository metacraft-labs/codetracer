/**
 * THE DESKTOP RUNS TESTS AND SAYS WHICH PASSED — issue #748, observed in a
 * real Electron window.
 *
 * Spec: codetracer-pm `spec/GUI/Core-Panes/Test-Results-Pane.md` §4.3 (the
 * desktop's header ▶ and row controls) and §5 (a run settles, however it
 * ended). The host's state machine is asserted headlessly by
 * `src/frontend/viewmodel/tests/unit/test_desktop_suite_run_gives_verdicts.nim`
 * and `test_desktop_test_run_settles.nim`; this spec is the Electron half the
 * front-end bug-fix protocol asks for — the IPC round trips, the main
 * process's `ct test run` / `ct record-test` spawns and the painted pane, none
 * of which a headless lane can reach.
 *
 * NO MOCKS. The project is a real Noir crate written to a scratch directory,
 * the app is the built `ct` in edit mode over it, and the runner is the real
 * `ct test run`, which hands the run to the `ct-test` built beside `ct` and
 * runs the real `nargo`. One test passes and one fails, so a pane that
 * painted every row green — or every row red — fails here.
 *
 * The `nargo` is the one the app itself resolves: the dev shell's, which is
 * the flake's pinned noir, or `CODETRACER_NOIR_EXE_PATH` when the run exports
 * it (the app inherits the runner's environment). A noir sibling's build is
 * never picked up implicitly, for the reason `scripts/detect-siblings.sh`
 * gives: a stale one records on one machine only.
 *
 * Isolation: the fixtures give the app a scratch `CODETRACER_HOME`; the test
 * certificate store is pointed at a scratch `TEST_CERTIFICATES_DIR`, because a
 * passing `ct test run` publishes a certificate there.
 *
 * WHICH TAB A RECORDING OPENS IN (`Test-Results-Pane.md` §9): the editor's Run
 * test, a row's `⏵` and record-and-open each open the recording in a NEW
 * SESSION TAB and leave the edit session in its own tab (rule 3); the same
 * test's `⏵` again shows the tab it already has (rule 4) rather than a second
 * one; the palette's **Tests: Open Recordings in the Current Tab** writes the
 * workspace's `replay-open-in` document. Until 2026-10-25 the desktop loaded
 * the recording INTO the edit session's window (codetracer-pm
 * `issues/2026-10-24-desktop-test-results-opens-a-recording-in-place-not-in-a-new-tab.md`).
 */
import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const project = fs.mkdtempSync(path.join(os.tmpdir(), "ct-desktop-suite-"));
fs.mkdirSync(path.join(project, "src"), { recursive: true });
fs.writeFileSync(
  path.join(project, "Nargo.toml"),
  '[package]\nname = "desktop_suite"\ntype = "bin"\nauthors = [""]\n\n[dependencies]\n',
);
fs.writeFileSync(
  path.join(project, "src", "main.nr"),
  [
    "fn main(x: Field, y: pub Field) {",
    "    assert(x != y);",
    "}",
    "",
    "#[test]",
    "fn test_passes() {",
    "    main(1, 2);",
    "}",
    "",
    "#[test]",
    "fn test_fails() {",
    "    main(1, 1);",
    "}",
    "",
  ].join("\n"),
);
const certificates = fs.mkdtempSync(path.join(os.tmpdir(), "ct-desktop-suite-certs-"));

async function showTestsPane(ctPage: any) {
  await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
  // The pane is a tab in the default layout; bring it forward if it is not
  // the active one in its stack.
  const tab = ctPage.locator(".lm_tab", { hasText: "TESTS" }).first();
  if (await tab.count()) {
    await tab.click();
  }
  await expect(ctPage.locator(".test-results-headline").first()).toBeVisible({
    timeout: 30_000,
  });
}

function rowFor(ctPage: any, name: string) {
  return ctPage.locator(`.test-results-row[data-ct-test-id$="::${name}"]`).first();
}

/** The recording loaded into this window, or "" when none is. */
async function loadedRecordingId(ctPage: any): Promise<string> {
  return await ctPage.evaluate(() => {
    const data = (window as any).__CODETRACER_DATA__;
    const id = data && data.trace ? data.trace.recordingId : "";
    return id ? String(id) : "";
  });
}

/**
 * How a dispatched `ct record-test` run ended: `recording:<id>` once the
 * window has entered the recording, or `failure:<sentence>` once the pane's
 * failure block states why there is none. Waits for whichever comes first.
 */
async function waitForRunOutcome(ctPage: any): Promise<string> {
  let outcome = "";
  await expect
    .poll(
      async () => {
        const id = await loadedRecordingId(ctPage);
        if (id) {
          outcome = `recording:${id}`;
          return true;
        }
        const failure = await ctPage.evaluate(() => {
          const node = document.querySelector(".test-results-failure") as HTMLElement | null;
          return node && !node.classList.contains("hidden") ? (node.innerText || "").trim() : "";
        });
        if (failure) {
          outcome = `failure:${failure}`;
          return true;
        }
        return false;
      },
      { timeout: 300_000, intervals: [1_000] },
    )
    .toBe(true);
  return outcome;
}

/** The window's session tabs, and which is shown (`window.data`). */
async function sessionTabs(ctPage: any): Promise<{ count: number; active: number; first: string }> {
  return await ctPage.evaluate(() => {
    const d = (window as any).data;
    const sessions = d?.sessions ?? [];
    const first = sessions[0]?.trace?.recordingId;
    return {
      count: sessions.length,
      active: d?.activeSessionIndex ?? -1,
      first: first ? String(first) : "",
    };
  });
}

/** Back to the edit session's tab (the first), by clicking it. */
async function showEditTab(ctPage: any) {
  await ctPage.locator(".session-tab").first().click();
  await expect.poll(async () => (await sessionTabs(ctPage)).active, { timeout: 30_000 }).toBe(0);
  // The edit session's container is shown again, its Tests pane as it was.
  await expect(ctPage.locator("#session-container-0 .test-results-row").first()).toBeVisible({
    timeout: 30_000,
  });
}

/** Every `.ct` container under this worker's scratch `CODETRACER_HOME`. */
function recordedContainers(): number {
  const home = process.env.CODETRACER_HOME;
  if (!home || !fs.existsSync(home)) return 0;
  let count = 0;
  const walk = (dir: string) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".ct")) count++;
    }
  };
  walk(home);
  return count;
}

test.describe("the desktop Test Results pane runs the suite through ct test run", () => {
  test.use({
    launchMode: "edit",
    editFolderPath: project,
    // BOTH store roots, absolute scratch paths: `ct test run` issues and
    // PUBLISHES a certificate on a passing run, and this must never be the
    // developer's own store.
    launchEnv: {
      TEST_CERTIFICATES_DIR: path.join(certificates, "user-root"),
      TEST_CERTIFICATES_SYSTEM_DIR: path.join(certificates, "system"),
    },
  });
  test.setTimeout(600_000);

  test("the header ▶ is live, and a run paints one pass and one fail", async ({ ctPage }) => {
    await showTestsPane(ctPage);

    // The catalog arrived (two rows, neither run yet) and the ▶ is LIVE — it
    // rendered disabled ("No host in this build can run the tests") before.
    await expect(ctPage.locator(".test-results-row")).toHaveCount(2, { timeout: 60_000 });
    await expect(ctPage.locator(".test-results-headline").first()).toHaveText(
      "2 tests, not run yet",
    );
    const run = ctPage.locator(".test-results-run-btn").first();
    await expect(run).not.toHaveClass(/disabled/, { timeout: 30_000 });

    await run.click();

    // The verdicts are the runner's: one passed, one failed, on the catalog's
    // own rows (still two — nargo's names joined onto the catalog ids).
    await expect(rowFor(ctPage, "test_passes")).toHaveClass(/\bpassed\b/, {
      timeout: 300_000,
    });
    await expect(rowFor(ctPage, "test_fails")).toHaveClass(/\bfailed\b/);
    await expect(ctPage.locator(".test-results-row")).toHaveCount(2);
    await expect(ctPage.locator(".test-results-headline").first()).toHaveText(
      /^1 passed, 1 failed/,
    );
    // Settled: the ▶ is live again and nothing claims to be running.
    await expect(run).not.toHaveClass(/disabled/);
    await expect(ctPage.locator(".test-results-headline").first()).not.toHaveText(/running/);
  });

  test("the editor's Run test settles in a real window", async ({ ctPage }) => {
    // Issue #748's first question: does the editor's Run-test control still
    // spin for ever on the desktop? Open the test file and press it.
    await showTestsPane(ctPage);
    // Edit mode opens `src/main.nr` as an editor tab; bring it forward.
    const editorTab = ctPage.locator(".lm_tab", { hasText: "main.nr" }).first();
    await expect(editorTab).toBeVisible({ timeout: 60_000 });
    await editorTab.click();

    const action = ctPage.locator(".editor-test-action").first();
    await expect(action).toBeVisible({ timeout: 60_000 });
    await action.click();

    // SETTLED: no control is left in the running state, and the editor's own
    // two-minute deadline did not have to end it.
    await expect
      .poll(
        async () =>
          await ctPage.evaluate(() => ({
            running: document.querySelectorAll(".editor-test-action.active-test-button").length,
            timedOut: Array.from(document.querySelectorAll(".editor-test-action")).some((n) =>
              (n.textContent || "").includes("timed out"),
            ),
          })),
        { timeout: 110_000, intervals: [1_000] },
      )
      .toEqual({ running: 0, timedOut: false });
    // HOW IT ENDED. Two answers settle a run, and both are checked rather than
    // either being taken on trust: the recording was made and the window entered
    // it, or the recorder said why it could not, in its own words under the
    // `ct record-test error:` stem — never the bare "Exit with code 1" the main
    // process used to keep.
    const ended = await waitForRunOutcome(ctPage);
    test.info().annotations.push({ type: "ct record-test outcome", description: ended });
    console.log(`ct record-test outcome: ${ended}`);
    if (ended.startsWith("failure:")) {
      const sentence = ended.slice("failure:".length);
      expect(sentence).toMatch(/^ct record-test error: /);
      expect(sentence).not.toMatch(/Exit with code/);
      expect(sentence).toMatch(/\(exit code \d+\)|ended by signal|could not be started/);
    }
    // With a `nargo` that knows `trace --test-name`, the Noir test RECORDS.
    expect(ended).toMatch(/^recording:/);
    // …AND IT OPENED IN A NEW SESSION TAB (§9): the edit session is the first
    // tab still, holding no recording, and the recording is the second's.
    const tabs = await sessionTabs(ctPage);
    expect(tabs.count).toBe(2);
    expect(tabs.active).toBe(1);
    expect(tabs.first).toBe("");
  });

  test("a row's ⟳ records the test and stays; ⏵ then opens that recording without re-running", async ({ ctPage }) => {
    await showTestsPane(ctPage);
    await expect(ctPage.locator(".test-results-row")).toHaveCount(2, { timeout: 60_000 });
    const row = rowFor(ctPage, "test_passes");
    await expect(row).toHaveAttribute("data-ct-recording-id", "");

    // ⟳ — RECORD, AND STAY IN THE PANE.
    const refresh = row.locator(".test-results-refresh-btn");
    await expect(refresh).not.toHaveClass(/disabled/, { timeout: 30_000 });
    await refresh.click();

    // Settled with a recording on the row…
    await expect(row).not.toHaveAttribute("data-ct-recording-id", "", { timeout: 300_000 });
    const recordingId = (await row.getAttribute("data-ct-recording-id")) ?? "";
    expect(recordingId.length).toBeGreaterThan(0);
    await expect(ctPage.locator(".test-results-headline").first()).not.toHaveText(/running/);
    await expect(ctPage.locator(".test-results-failure").first()).toHaveClass(/hidden/);
    // …and the window STAYED: still the edit session, still this pane, no
    // trace loaded into it.
    await expect(ctPage.locator(".test-results-row")).toHaveCount(2);
    expect(await loadedRecordingId(ctPage)).toBe("");

    // ⏵ — OPEN THAT RECORDING, AND RUN NOTHING. Its title says where.
    const open = row.locator(".test-results-open-btn");
    await expect(open).toHaveAttribute("data-ct-open-mode", "open-existing");
    await expect(open).toHaveAttribute("title", /Opens in a new tab\.$/);
    const containersBefore = recordedContainers();
    // The control for the "nothing recorded" check below: the ⟳ above made a
    // container, so a counter that cannot see recordings would read 0 here.
    expect(containersBefore).toBeGreaterThan(0);
    const tabsBefore = await sessionTabs(ctPage);
    expect(tabsBefore.count).toBe(1);
    await open.click();

    // The recording the row carried — the same id — is shown…
    await expect.poll(async () => loadedRecordingId(ctPage), { timeout: 180_000 }).toBe(
      recordingId,
    );
    // …IN A NEW SESSION TAB (§9.1 arm 4), the edit session left in the first…
    const opened = await sessionTabs(ctPage);
    expect(opened.count).toBe(2);
    expect(opened.active).toBe(1);
    expect(opened.first).toBe("");
    // …and nothing was recorded to get there.
    expect(recordedContainers()).toBe(containersBefore);

    // ⏵ AGAIN, from the edit session: the test's own tab is SHOWN (rule 4),
    // not a second tab for the same recording — and the title said so.
    await showEditTab(ctPage);
    await expect(open).toHaveAttribute("title", /Opens in the tab it already has\.$/);
    await open.click();
    await expect.poll(async () => (await sessionTabs(ctPage)).active, { timeout: 60_000 }).toBe(1);
    expect((await sessionTabs(ctPage)).count).toBe(2);
    expect(await loadedRecordingId(ctPage)).toBe(recordingId);
    expect(recordedContainers()).toBe(containersBefore);
  });

  test("a row's ⏵ with no recording yet records the test and enters the recording", async ({ ctPage }) => {
    // RECORD-AND-OPEN: `openButtonMode` answers `obmRecordAndOpen` for a row with
    // no recording (that arm is checked before Shift is consulted), and
    // `triggerOpen` then calls the host's `recordAndOpenRecording` — on the
    // desktop, the editor's own opening dispatch: `ct record-test`, then the
    // recording loaded into this window.
    await showTestsPane(ctPage);
    await expect(ctPage.locator(".test-results-row")).toHaveCount(2, { timeout: 60_000 });
    const row = rowFor(ctPage, "test_fails");
    await expect(row).toHaveAttribute("data-ct-recording-id", "");
    const open = row.locator(".test-results-open-btn");
    await expect(open).toHaveAttribute("data-ct-open-mode", "record-and-open");
    await expect(open).not.toHaveClass(/disabled/, { timeout: 30_000 });
    const containersBefore = recordedContainers();
    // Nothing is loaded yet, so a `recording:` outcome below can only be the
    // one this click produced.
    expect(await loadedRecordingId(ctPage)).toBe("");

    await open.click();

    // The same evidence case 2 uses: the run settled with the recording entered
    // into the window, or with the recorder's stated reason — and it must be the
    // former. A FAILING test still records (tracing records the execution up to
    // the failure), which is why this row is `test_fails`.
    const ended = await waitForRunOutcome(ctPage);
    test.info().annotations.push({ type: "record-and-open outcome", description: ended });
    console.log(`record-and-open outcome: ${ended}`);
    expect(ended).toMatch(/^recording:/);
    // And it was RECORDED to get there, unlike ⏵ over an existing recording.
    expect(recordedContainers()).toBe(containersBefore + 1);
    // In a NEW SESSION TAB; the edit session stays where it was.
    const tabs = await sessionTabs(ctPage);
    expect(tabs.count).toBe(2);
    expect(tabs.active).toBe(1);
    expect(tabs.first).toBe("");
  });

  test("the palette's Tests: Open Recordings in the Current Tab writes the workspace's setting", async ({ ctPage }) => {
    // §9.3: the setting is one document every front-end reads, in the native
    // state root; the desktop's main process writes it for the edit
    // session's folder.
    await showTestsPane(ctPage);
    await expect(ctPage.locator(".test-results-row")).toHaveCount(2, { timeout: 60_000 });
    await ctPage.keyboard.press("Control+KeyP");
    const box = ctPage.locator("#command-query-text");
    await expect(box).toBeVisible({ timeout: 30_000 });
    await box.fill(":Open Recordings in the Current");
    const hit = ctPage
      .locator(".command-results .command-result.command-command")
      .filter({ hasText: "Tests: Open Recordings in the Current Tab" })
      .first();
    await expect(hit).toBeVisible({ timeout: 30_000 });
    await hit.click();
    const home = process.env.CODETRACER_HOME ?? "";
    const stateRoot = process.env.CODETRACER_TUI_LAYOUT_DIR || path.join(home, "state");
    const doc = path.join(stateRoot, "replay-open-in");
    await expect
      .poll(() => (fs.existsSync(doc) ? fs.readFileSync(doc, "utf8") : ""), { timeout: 30_000 })
      .toContain(`${project.replace(/\/+$/, "")}\tcurrent-tab`);
  });
});
