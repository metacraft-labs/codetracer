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
    // And the pane is not left on "running…" either.
    await expect(ctPage.locator(".test-results-headline").first()).not.toHaveText(/running/, {
      timeout: 30_000,
    });
    // What the run ended with, kept in the report: a recording, or the
    // recorder's sentence in the pane's failure block.
    const outcome = (await ctPage.locator(".test-results-failure").first().innerText()).trim();
    test.info().annotations.push({ type: "ct record-test outcome", description: outcome });
    console.log(`ct record-test outcome: ${outcome || "(no failure sentence)"}`);
    // A run that made no recording says why IN THE RECORDER'S WORDS, under the
    // `ct record-test error:` stem — not the bare "Exit with code 1" the main
    // process used to keep. (A run that DID record has no failure sentence.)
    if (outcome.length > 0) {
      expect(outcome).toMatch(/^ct record-test error: /);
      expect(outcome).not.toMatch(/Exit with code/);
      expect(outcome).toMatch(/\(exit code \d+\)|ended by signal|could not be started/);
    }
  });
});
