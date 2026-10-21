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

    // ⏵ — OPEN THAT RECORDING, AND RUN NOTHING.
    const open = row.locator(".test-results-open-btn");
    await expect(open).toHaveAttribute("data-ct-open-mode", "open-existing");
    const containersBefore = recordedContainers();
    // The control for the "nothing recorded" check below: the ⟳ above made a
    // container, so a counter that cannot see recordings would read 0 here.
    expect(containersBefore).toBeGreaterThan(0);
    await open.click();

    // The window entered the recording the row carried — the same id…
    await expect.poll(async () => loadedRecordingId(ctPage), { timeout: 180_000 }).toBe(
      recordingId,
    );
    // …and nothing was recorded to get there.
    expect(recordedContainers()).toBe(containersBefore);
  });
});
