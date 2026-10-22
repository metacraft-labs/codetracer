/**
 * The IsoNim panes of every desktop tab after the first must render.
 *
 * Issue (codetracer-pm): `issues/2026-10-21-isonim-panes-stay-blank-in-every-desktop-tab-but-the-first.md`,
 * the residual of #835.
 *
 * Every tab of the window keeps its DOM in one document: tab <n> lives in
 * `#ROOT > .session-container#session-container-<n>` and a tab switch only
 * hides and shows those containers (`ui/session_switch.nim`). The singleton
 * panes keep component id 0 in every tab, so tab 0 and tab 1 both carry a
 * `stateComponent-0`, a `vCSComponent-0`, and so on. Before the fix each
 * `tryMountIsoNim*Panel` found its host with a document-wide
 * `getElementById`, which returns tab 0's host whether or not it is hidden;
 * the mount then declined (the host already carried the mount mark, or a
 * module latch keyed by the bare id said "mounted") and the later tab's own
 * host stayed empty.
 *
 * What the specs require — `GUI/Multi-Window-Tab-Management.md` §Tab
 * Behavior: rule 1, "Each tab represents an independent session"; rule 2,
 * "Clicking a tab switches all panels to that session's data". So:
 *
 *   (a) "+" → New File with a replay open: the new edit tab's VCS, Files,
 *       Test Results and Constraints panes show exactly what New File shows
 *       with NO replay open (captured in the same run as a baseline) — not
 *       nothing, and not the replay tab's project (the flow #835 was
 *       reported on; `Welcome-Screen.md` §"New file, and what it creates");
 *   (b) "+" → open a SECOND, DIFFERENT recording: the second tab's State,
 *       Call Trace, Event Log, Terminal, Scratchpad, Agent Activity, VCS and
 *       Test Results panes are mounted — their hosts are not empty. No
 *       Constraints pane: a replay opens on the Debug mode's default, which
 *       does not place one (`frontend.modeDefaultOmittedContentIds`); the
 *       launch fixture opens the first tab on that default too, as a user's
 *       first run does. The Constraints pane's mount in a later tab is (a)'s;
 *   (c) the first tab's panes still render after all of that.
 *
 * WHAT (b) DOES NOT YET ASSERT, AND WHY. Rule 2 also wants those panes to show
 * the SECOND recording's data. They do not, for a reason that is not this
 * defect: the replay panes' ViewModels are one per WINDOW. `ui_js.nim`'s
 * `configureMiddleware` runs once (`middlewareConfigured`) and builds one
 * `SessionViewModel` (`if activeSessionVM.isNil`) over the DapApi / views
 * mediator of the tab that was active at that moment, so a later tab's
 * components get no middleware, and its Call Trace / State / Event Log /
 * Terminal panes read tab 0's ViewModels. Measured with this spec after the
 * mount fix: tab 1's Call Trace lists `py_console_logs`' functions
 * (`MaxLevelFilter`, `setup_logging`), its Terminal reads "Loading record
 * output..." and its Event Log "0 Rows". Making those per tab is a redesign
 * of the ViewModel layer; the spec PRINTS each pane's opening text (the
 * `# tab 1 <pane>:` lines) so the gap stays measured until that lands.
 *
 * Every read is scoped to one `#session-container-<n>`. A document-wide
 * selector would find tab 0's rows and pass over a blank tab — that is how
 * `multi-trace-load.spec.ts` missed this.
 *
 * No mocks: the real Electron app, real recorded Python traces
 * (`py_console_logs/main.py` launched; `py_checklist/basics.py` recorded by
 * the test and loaded through the product's own
 * `CODETRACER::load-recent-trace`). Which host a pane mounts into is a
 * property of the real GoldenLayout DOM of two live tabs, which no headless
 * ViewModel owns; the lookup rule itself is unit-tested headless in
 * `src/tests/gui/tests/layout/isonim_panel_mount_test.nim`.
 */

import * as path from "node:path";

import type { Page } from "@playwright/test";
import { test, expect, recordTestProgram, testProgramsPath } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

interface PaneReading {
  /** Whether a host with this exact id exists inside the container. */
  present: boolean;
  /** The host's text, whitespace collapsed ("" when absent). */
  text: string;
}

/**
 * Read the panes `labels` inside `#session-container-<index>` ONLY. Uses
 * `textContent`, not `innerText`, so a pane sitting in a background
 * GoldenLayout tab (display: none) is still read.
 */
async function readPanes(page: Page, index: number, labels: string[]): Promise<Record<string, PaneReading>> {
  return page.evaluate(
    ({ index, labels }) => {
      const container = document.getElementById(`session-container-${index}`);
      if (!container) throw new Error(`session-container-${index} is missing`);
      const out: Record<string, { present: boolean; text: string }> = {};
      for (const label of labels) {
        const host = container.querySelector(`[id="${label}"]`);
        out[label] = {
          present: !!host,
          text: (host?.textContent ?? "").replace(/\s+/g, " ").trim(),
        };
      }
      return out;
    },
    { index, labels },
  );
}

/** Every `<x>Component-<id>` host in a container, with its text length —
 *  printed on failure so a red run names every blank pane at once. */
async function inventory(page: Page, index: number): Promise<string> {
  return page.evaluate((index) => {
    const container = document.getElementById(`session-container-${index}`);
    if (!container) return `session-container-${index} is missing`;
    return Array.from(container.querySelectorAll("[id*='Component']"))
      .filter((el) => /Component(-\d+)?$/.test(el.id))
      .map((el) => `${el.id}=${(el.textContent ?? "").replace(/\s+/g, " ").trim().length}`)
      .join(" ");
  }, index);
}

/**
 * Poll until every listed pane in the container is present and passes
 * `ok`, then return the last reading (passing or not) for the assertions.
 */
async function settledPanes(
  page: Page,
  index: number,
  expected: Record<string, (text: string) => boolean>,
  attempts = 60,
): Promise<Record<string, PaneReading>> {
  const labels = Object.keys(expected);
  let reading: Record<string, PaneReading> = {};
  await retry(
    async () => {
      reading = await readPanes(page, index, labels);
      return labels.every((l) => reading[l].present && expected[l](reading[l].text));
    },
    { maxAttempts: attempts, delayMs: 500 },
  ).catch(() => undefined);
  return reading;
}

function expectPanes(
  reading: Record<string, PaneReading>,
  expected: Record<string, (text: string) => boolean>,
  where: string,
  inv: string,
): void {
  const failures = Object.keys(expected)
    .filter((l) => !reading[l]?.present || !expected[l](reading[l].text))
    .map((l) => `${l}: ${reading[l]?.present ? JSON.stringify(reading[l].text.slice(0, 120)) : "<absent>"}`);
  expect(failures, `${where}: panes that did not render.\nAll hosts (id=text length): ${inv}`).toEqual([]);
}

async function activeSessionIndex(page: Page): Promise<number> {
  return page.evaluate(() => (window as any).data?.activeSessionIndex ?? -1);
}

const nonEmpty = (t: string) => t.length > 0;

/**
 * The panes a New File session shows. `GUI/Welcome-And-Sessions/Welcome-Screen.md`
 * §"New file, and what it creates": the session has NO project folder, so
 * Files shows an empty project and Test Results / Constraints say no folder
 * is open.
 */
const NEW_FILE_PANES = ["vCSComponent-0", "filesystemComponent", "testResultsComponent-0", "constraintsComponent-0"];

/**
 * Each pane's text inside one container, every host carrying the label
 * joined (Files has two `filesystemComponent` nodes per tab). Relative commit
 * ages in the VCS pane ("9h" before "View Commit") are wall-clock readings
 * that roll over between two launches, so they are normalised away.
 */
async function newFilePaneTexts(page: Page, index: number): Promise<Record<string, string>> {
  return page.evaluate(
    ({ index, labels }) => {
      const container = document.getElementById(`session-container-${index}`);
      if (!container) throw new Error(`session-container-${index} is missing`);
      const out: Record<string, string> = {};
      for (const label of labels) {
        out[label] = Array.from(container.querySelectorAll(`[id="${label}"]`))
          .map((h) =>
            (h.textContent ?? "")
              .replace(/\s+/g, " ")
              .replace(/\d+(?:s|m|h|d|w|mo|y)(?= ?View Commit)/g, "<age>")
              .trim(),
          )
          .join(" || ");
      }
      return out;
    },
    { index, labels: NEW_FILE_PANES },
  );
}

/** Poll until two consecutive readings agree, so mounts still arriving are
 *  not mistaken for content. */
async function settledNewFilePanes(page: Page, index: number): Promise<Record<string, string>> {
  let previous = JSON.stringify(await newFilePaneTexts(page, index));
  for (let i = 0; i < 30; i++) {
    await page.waitForTimeout(1000);
    const current = JSON.stringify(await newFilePaneTexts(page, index));
    if (current === previous && !Object.values(JSON.parse(current)).some((t) => t === "")) {
      return JSON.parse(current);
    }
    previous = current;
  }
  return JSON.parse(previous);
}

/**
 * What New File shows with NO replay open — the path the issue reports as
 * working — captured by the first test of the serial block below and
 * compared against by the second. A New File tab opened beside a replay is
 * the same kind of session (rule 1 of §Tab Behavior: tabs are independent),
 * so it must show exactly this: not blank (this issue), and not the replay
 * tab's project either.
 *
 * Measured 2026-10-21 on m1: the VCS pane of BOTH shows the repository of
 * the Electron process's directory, because `ui/git_cli.gitWorkingDirectory`
 * returns "" for a session with no folder and git then runs in the process
 * cwd. That is a separate question about the no-folder case itself (it
 * holds without any replay open), not this one, so the baseline is the
 * product's no-replay behaviour, whatever it is, rather than a literal.
 */
let noReplayNewFileBaseline: Record<string, string> | null = null;

async function openNewFileFromWelcome(page: Page): Promise<void> {
  const newFileOption = page.locator(".start-option.new-file");
  await expect(newFileOption).toBeVisible({ timeout: 30_000 });
  await newFileOption.click();
  await expect(page.locator(".welcome-screen")).toBeHidden({ timeout: 15_000 });
}

test.describe.serial("a New File tab beside a replay is the same as New File alone", () => {
  test.setTimeout(300_000);

  test.describe("baseline", () => {
    test.use({ launchMode: "welcome" });

    test("New File with no replay open (the baseline)", async ({ ctPage }) => {
      await openNewFileFromWelcome(ctPage);
      const index = await activeSessionIndex(ctPage);
      noReplayNewFileBaseline = await settledNewFilePanes(ctPage, index);
      console.log(`# no-replay New File baseline: ${JSON.stringify(noReplayNewFileBaseline).slice(0, 400)}`);
      for (const label of NEW_FILE_PANES) {
        expect(noReplayNewFileBaseline[label], `${label} in the no-replay New File session`).not.toBe("");
      }
    });
  });

  test.describe("beside a replay", () => {
    test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

    test("a New File tab opened beside a replay shows what New File alone shows", async ({ ctPage }) => {
      expect(
        noReplayNewFileBaseline,
        "the baseline test of this serial block must run first (do not select this case alone with -g)",
      ).not.toBeNull();
      const layout = new LayoutPage(ctPage);
      await layout.waitForTraceLoaded();
      await layout.waitForAllComponentsLoaded();
      expect(await activeSessionIndex(ctPage)).toBe(0);
      const replayTab = await newFilePaneTexts(ctPage, 0);

      await ctPage.locator(".session-tab-add").click();
      await retry(async () => (await activeSessionIndex(ctPage)) === 1, { maxAttempts: 40, delayMs: 250 });
      await openNewFileFromWelcome(ctPage);
      expect(await activeSessionIndex(ctPage)).toBe(1);

      const newFileTab = await settledNewFilePanes(ctPage, 1);
      console.log(`# session-container-1 after New File: ${await inventory(ctPage, 1)}`);
      for (const label of NEW_FILE_PANES) {
        console.log(`# ${label}: equalsBaseline=${newFileTab[label] === noReplayNewFileBaseline![label]} ` +
          `equalsReplayTab=${newFileTab[label] === replayTab[label]}`);
      }
      expect(newFileTab, "the New File tab (session-container-1) against New File with no replay open")
        .toEqual(noReplayNewFileBaseline);
      // And concretely what the spec names for a folderless session.
      expect(newFileTab["testResultsComponent-0"]).toMatch(/no project folder is open/i);
      expect(newFileTab["constraintsComponent-0"]).toMatch(/no project folder is open/i);
      expect(newFileTab["filesystemComponent"]).not.toMatch(/py_console_logs|main\.py/);
    });
  });
});

test.describe("IsoNim panes render in every tab, not only the first", () => {
  test.setTimeout(300_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("a second recording opened in a + tab shows its own panes", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();
    expect(await activeSessionIndex(ctPage)).toBe(0);

    // A DIFFERENT program, so "shows the second tab's own data" is
    // distinguishable from "shows a copy of tab 0".
    const secondTraceId = recordTestProgram(path.join(testProgramsPath, "py_checklist", "basics.py"));

    await ctPage.locator(".session-tab-add").click();
    await retry(async () => (await activeSessionIndex(ctPage)) === 1, { maxAttempts: 40, delayMs: 250 });
    expect(await activeSessionIndex(ctPage)).toBe(1);
    await ctPage.evaluate((id) => {
      (window as any).data.ipc.send("CODETRACER::load-recent-trace", { traceId: id });
    }, secondTraceId);
    await retry(
      async () =>
        ctPage.evaluate(() => {
          const t = (window as any).data?.sessions?.[1]?.trace;
          return !!t && String(t.program ?? "").includes("basics.py");
        }),
      { maxAttempts: 90, delayMs: 1000 },
    );

    // Mounted: each host carries a view. (Whose DATA it shows is the
    // per-window ViewModel gap described in the header; printed below.)
    const secondTab = {
      "stateComponent-0": nonEmpty,
      "calltraceComponent-0": nonEmpty,
      "eventLogComponent-0": nonEmpty,
      "terminalComponent-0": nonEmpty,
      "scratchpadComponent-0": nonEmpty,
      "agentActivityComponent-0": nonEmpty,
      "vCSComponent-0": nonEmpty,
      "testResultsComponent-0": nonEmpty,
    };
    const reading = await settledPanes(ctPage, 1, secondTab, 90);
    console.log(`# session-container-1 after loading basics.py: ${await inventory(ctPage, 1)}`);
    // The measurement of the residual: does tab 1 show basics.py's own data
    // ("1. literals", `demo_1_literals`) or tab 0's?
    for (const label of ["calltraceComponent-0", "eventLogComponent-0", "terminalComponent-0", "stateComponent-0"]) {
      const text = reading[label]?.text ?? "";
      const own = /1\. literals|demo_1_literals/.test(text);
      console.log(`# tab 1 ${label}: ownData=${own} ${JSON.stringify(text.slice(0, 160))}`);
    }
    expectPanes(reading, secondTab, "the second replay tab (session-container-1)", await inventory(ctPage, 1));

    // (c) The first tab still renders its panes after the round trip.
    await ctPage.locator(".session-tab").first().click();
    await retry(async () => (await activeSessionIndex(ctPage)) === 0, { maxAttempts: 40, delayMs: 250 });
    const firstTab = {
      "stateComponent-0": nonEmpty,
      "calltraceComponent-0": nonEmpty,
      "eventLogComponent-0": nonEmpty,
      "terminalComponent-0": nonEmpty,
      "vCSComponent-0": nonEmpty,
      "testResultsComponent-0": nonEmpty,
    };
    const first = await settledPanes(ctPage, 0, firstTab, 20);
    expectPanes(first, firstTab, "the first replay tab (session-container-0) after switching back", await inventory(ctPage, 0));
  });
});
