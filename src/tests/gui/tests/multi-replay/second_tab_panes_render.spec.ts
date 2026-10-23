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
 * And each tab shows ITS OWN session's data (rules 1, 2 and 6; Multi-Replay-
 * Window-Architecture M12's two Verification items, named after them below):
 *
 *   (d) `test_open_second_trace` — after (b), tab 1's Call Trace, State and
 *       Event Log show basics.py's run (`demo_1_literals`, "1. literals", its
 *       module docstring) and none of py_console_logs' (`MaxLevelFilter`,
 *       `setup_logging`, "print using", main.py's docstring); so does its
 *       Terminal once brought to the front of its stack (a hidden Terminal
 *       loads nothing and reads "Loading record output..." in every tab);
 *       switching back, tab 0 shows py_console_logs' again and none of
 *       basics.py's. The data is asserted from the same poll that checks the
 *       panes mounted, before anything else is asked of the renderer;
 *   (e) `test_step_independent_tabs` — a step in tab 1 moves tab 1 only; a step
 *       in tab 0 moves tab 0 only; each tab, shown again, is where it was left;
 *   (f) `test_load_answers_reach_their_tab` — a load asked for in tab 1 and
 *       answered while tab 0 is on screen goes to tab 1: tab 0 keeps
 *       py_console_logs' recording and data, tab 1's answers wait for it
 *       (`ReplaySession.pendingTabAnswers`), and shown, tab 1 has basics.py's.
 *       The main process names the asking tab on each answer
 *       (`index/tab_answers.nim`) and the renderer gives it to that tab
 *       (`ui/tab_answer_routing.deliverTabAnswer`); before that, every answer of
 *       the load — `trace-loaded`, `filesystem-loaded`, … — went to whichever
 *       tab was shown.
 *
 * (d) and (e) are issue `2026-10-21-a-second-replay-tab-shows-the-first-tabs-
 * data-because-the-window-builds-one-session-viewmodel.md`. Before its fix the
 * window built ONE `SessionViewModel` (`ui_js.configureMiddleware`, once per
 * window) over the first tab's DAP API, so tab 1's Call Trace listed
 * py_console_logs' functions, its Terminal read "Loading record output..." and
 * the toolbar stepped tab 0's replay whichever tab was shown. Each
 * `ReplaySession` now owns its ViewModels, and a tab switch rebinds the
 * window's pane bridges to the shown tab's (`ui/session_viewmodels.nim`).
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
 * `src/tests/gui/tests/layout/pane_host_lookup_test.nim`, and which
 * session's ViewModels a tab's pane host renders, and which session a tagged
 * event updates, in `src/frontend/tests/session_viewmodels_test.nim`.
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
 * `page.evaluate`, failing with what was being read when the renderer does
 * not answer within `ms` — a renderer busy in a loop would otherwise hold the
 * test until its overall timeout and say nothing about where it stopped.
 */
async function answered<T>(what: string, read: Promise<T>, ms = 20_000): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`the renderer did not answer within ${ms} ms: ${what}`)), ms);
  });
  try {
    return await Promise.race([read, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Read the panes `labels` inside `#session-container-<index>` ONLY. Uses
 * `textContent`, not `innerText`, so a pane sitting in a background
 * GoldenLayout tab (display: none) is still read.
 */
async function readPanes(page: Page, index: number, labels: string[]): Promise<Record<string, PaneReading>> {
  return answered(`reading ${labels.join(", ")} in session-container-${index}`, page.evaluate(
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
  ));
}

/** Every `<x>Component-<id>` host in a container, with its text length —
 *  printed on failure so a red run names every blank pane at once. */
async function inventory(page: Page, index: number): Promise<string> {
  return answered(`the inventory of session-container-${index}`, page.evaluate((index) => {
    const container = document.getElementById(`session-container-${index}`);
    if (!container) return `session-container-${index} is missing`;
    return Array.from(container.querySelectorAll("[id*='Component']"))
      .filter((el) => /Component(-\d+)?$/.test(el.id))
      .map((el) => `${el.id}=${(el.textContent ?? "").replace(/\s+/g, " ").trim().length}`)
      .join(" ");
  }, index)).catch((e) => `<${(e as Error).message}>`);
}

/**
 * Poll until every listed pane in the container is present and passes
 * `ok`, then return the last reading (passing or not) for the assertions.
 *
 * THE LAST READING THE RENDERER ANSWERED is what comes back, also when it
 * stops answering mid-poll (`answered` throws, the poll ends): the
 * assertions then state what the panes held, rather than the test timing out
 * with nothing said about them.
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
  return answered("the active tab", page.evaluate(() => (window as any).data?.activeSessionIndex ?? -1));
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
 * What that behaviour must BE is the no-folder case itself, and is asserted
 * separately by `expectFolderlessPanes` in both tests: measured 2026-10-22 on
 * m1 at codetracer `c716405c0`, the VCS pane of both listed 50 commits of the
 * Electron process's directory (git ran with the empty working directory a
 * folderless session hands it) and Files showed "No filesystem loaded yet."
 * (codetracer-pm issue 2026-10-21-new-file-session-shows-a-loading-files-pane-…).
 */
let noReplayNewFileBaseline: Record<string, string> | null = null;

/**
 * What a folderless session's Files and VCS panes SHOW, read from the overlay
 * classes rather than from text: each Files host always carries every overlay
 * (empty, loading, error) and only hides the ones that do not apply, so its
 * `textContent` reads "No filesystem loaded yet. Loading..." whichever state
 * it is in, and cannot tell "loading" from "empty".
 */
interface FolderlessReading {
  /** Files hosts whose loading overlay is shown (not `.hidden`). */
  filesLoadingShown: number;
  /** Texts of the Files empty-state overlays that are shown. */
  filesEmptyShown: string[];
  /** Tree rows drawn in Files. */
  filesEntries: number;
  /** The VCS host's no-repository message ("" when absent). */
  vcsNoRepoText: string;
  /** Commit rows drawn in VCS. */
  vcsCommitRows: number;
}

async function readFolderlessPanes(page: Page, index: number): Promise<FolderlessReading> {
  return page.evaluate((index) => {
    const container = document.getElementById(`session-container-${index}`);
    if (!container) throw new Error(`session-container-${index} is missing`);
    const files = Array.from(container.querySelectorAll('[id="filesystemComponent"]'));
    const shown = (sel: string) =>
      files.flatMap((h) => Array.from(h.querySelectorAll(sel))).filter((el) => !el.classList.contains("hidden"));
    const vcs = container.querySelector('[id="vCSComponent-0"]');
    return {
      filesLoadingShown: shown(".filesystem-loading-overlay").length,
      filesEmptyShown: shown(".filesystem-empty-overlay").map((el) => (el.textContent ?? "").trim()),
      filesEntries: files.reduce((n, h) => n + h.querySelectorAll(".filesystem-entry").length, 0),
      vcsNoRepoText: (vcs?.querySelector(".vcs-no-repo")?.textContent ?? "").replace(/\s+/g, " ").trim(),
      vcsCommitRows: vcs ? vcs.querySelectorAll(".vcs-commit-entry").length : 0,
    };
  }, index);
}

/**
 * codetracer-pm issue 2026-10-21 "A New File session's Files pane never
 * leaves Loading…, and its VCS pane shows the launch directory's
 * repository", against `Welcome-Screen.md` §"New file, and what it creates":
 * the session has no project folder, so Files shows an EMPTY PROJECT (no
 * tree, not loading) and VCS shows the same "No project folder is open."
 * absence as Test Results and Constraints — never the history of the
 * repository the app was launched from.
 */
async function expectFolderlessPanes(page: Page, index: number, where: string): Promise<void> {
  let reading = await readFolderlessPanes(page, index);
  // Polled: the panes settle asynchronously after New File.
  await retry(
    async () => {
      reading = await readFolderlessPanes(page, index);
      return (
        reading.filesLoadingShown === 0 &&
        reading.filesEmptyShown.length > 0 &&
        /no project folder is open/i.test(reading.vcsNoRepoText)
      );
    },
    { maxAttempts: 30, delayMs: 500 },
  ).catch(() => undefined);
  console.log(`# ${where} folderless panes: ${JSON.stringify(reading)}`);
  expect(reading.filesLoadingShown, `${where}: Files must not stay "Loading..."`).toBe(0);
  expect(reading.filesEntries, `${where}: Files must draw no tree`).toBe(0);
  expect(reading.filesEmptyShown.length, `${where}: Files must show its empty project`).toBeGreaterThan(0);
  for (const text of reading.filesEmptyShown) {
    expect(text, `${where}: the Files empty project`).toMatch(/no project folder is open/i);
  }
  expect(reading.vcsNoRepoText, `${where}: VCS with no project folder`).toMatch(/no project folder is open/i);
  expect(reading.vcsCommitRows, `${where}: VCS must list no commits`).toBe(0);
}

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
      await expectFolderlessPanes(ctPage, index, "New File with no replay open");
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
      await expectFolderlessPanes(ctPage, 1, "the New File tab beside a replay");
    });
  });
});

/**
 * What each recording's own panes say, and what they must never say. The
 * markers are the programs' own: basics.py's first demo function and the
 * first line it prints (`py_checklist/basics.py`), py_console_logs' logging
 * filter class, its setup function and the words every one of its numbered
 * prints carries (`py_console_logs/main.py`). Each is unique to its program.
 */
const BASICS = /demo_1_literals|1\. literals/;
const CONSOLE_LOGS = /MaxLevelFilter|setup_logging|print using/;
/** The docstring each program opens with — what the State pane's source line
 *  shows while the replay stands at the program's entry. */
const BASICS_SOURCE = /Baseline language probes|basics\.py/;
const CONSOLE_LOGS_SOURCE = /Demonstrate a variety of Python console output|main\.py/;

/** A pane shows `own` and nothing of `other`. */
function showsOnly(own: RegExp, other: RegExp): (text: string) => boolean {
  return (t) => own.test(t) && !other.test(t);
}

type Recording = "basics" | "consoleLogs";

function markers(own: Recording): [RegExp, RegExp, RegExp, RegExp] {
  return own === "basics"
    ? [BASICS, CONSOLE_LOGS, BASICS_SOURCE, CONSOLE_LOGS_SOURCE]
    : [CONSOLE_LOGS, BASICS, CONSOLE_LOGS_SOURCE, BASICS_SOURCE];
}

/**
 * The replay panes of one tab that show its recording without being brought
 * to the front — Call Trace, State, Event Log — each expected to show `own`'s
 * recording and nothing of the other's. These are the panes the issue reads.
 */
function ownDataPanes(own: Recording): Record<string, (text: string) => boolean> {
  const [mine, theirs, mySource, theirSource] = markers(own);
  return {
    "calltraceComponent-0": showsOnly(mine, theirs),
    "stateComponent-0": showsOnly(mySource, theirSource),
    "eventLogComponent-0": showsOnly(mine, theirs),
  };
}

/**
 * The Terminal of one tab, once shown (`showTerminal`): `own`'s output, and no
 * longer "Loading record output…" — what a hidden pane, or one over a
 * ViewModel that never received the recording's output, says.
 */
function ownTerminal(own: Recording): Record<string, (text: string) => boolean> {
  const [mine, theirs] = markers(own);
  return {
    "terminalComponent-0": (t) => showsOnly(mine, theirs)(t) && !/Loading record output/.test(t),
  };
}

/**
 * Bring tab `index`'s own Terminal to the front of its GoldenLayout stack. The
 * Terminal pane asks for the lines it shows and nothing while it is hidden
 * (Viewport-Driven-Loading Q3: a hidden pane reports no rows), so in the
 * default layout, where it shares a stack, it reads "Loading record output..."
 * in EVERY tab until it is shown — tab 0's as much as tab 1's.
 */
async function showTerminal(page: Page, index: number): Promise<void> {
  const tab = page
    .locator(`#session-container-${index} .lm_tab`)
    .filter({ has: page.locator(".lm_title", { hasText: /terminal/i }) })
    .first();
  await expect(tab, `tab ${index}'s Terminal stack item`).toHaveCount(1, { timeout: 30_000 });
  await tab.click();
}

/** Print each pane's opening text from a reading already taken, so a red run
 *  shows whose data it held without asking the renderer again. */
function printPanes(reading: Record<string, PaneReading>, what: string): void {
  for (const label of Object.keys(reading)) {
    console.log(`# ${what} ${label}: ${JSON.stringify((reading[label]?.text ?? "").slice(0, 200))}`);
  }
}

/**
 * From a launched py_console_logs replay in tab 0: "+", record basics.py and
 * load it into the new tab through the product's own
 * `CODETRACER::load-recent-trace`, and wait until tab 1's session holds it.
 */
async function openSecondRecordingInNewTab(page: Page): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForTraceLoaded();
  await layout.waitForAllComponentsLoaded();
  expect(await activeSessionIndex(page)).toBe(0);

  // A DIFFERENT program, so "shows the second tab's own data" is
  // distinguishable from "shows a copy of tab 0".
  const secondTraceId = recordTestProgram(path.join(testProgramsPath, "py_checklist", "basics.py"));

  await page.locator(".session-tab-add").click();
  await retry(async () => (await activeSessionIndex(page)) === 1, { maxAttempts: 40, delayMs: 250 });
  expect(await activeSessionIndex(page)).toBe(1);
  await page.evaluate((id) => {
    (window as any).data.ipc.send("CODETRACER::load-recent-trace", { traceId: id });
  }, secondTraceId);
  await retry(
    async () =>
      page.evaluate(() => {
        const t = (window as any).data?.sessions?.[1]?.trace;
        return !!t && String(t.program ?? "").includes("basics.py");
      }),
    { maxAttempts: 90, delayMs: 1000 },
  );
}

async function switchToTab(page: Page, index: number): Promise<void> {
  await page.locator(".session-tab").nth(index).click();
  await retry(async () => (await activeSessionIndex(page)) === index, { maxAttempts: 40, delayMs: 250 });
  expect(await activeSessionIndex(page)).toBe(index);
}

interface TabLocation {
  path: string;
  line: number;
  rrTicks: number;
}

/**
 * Where tab `index`'s replay stands, as its OWN status bar holds it — each tab
 * has one (`StatusComponent`), updated by the moves of that tab's session
 * whether or not the tab is shown (`middleware.setupMiddlewareApis`).
 */
async function tabLocation(page: Page, index: number): Promise<TabLocation | null> {
  return answered(`tab ${index}'s location`, page.evaluate((index) => {
    const loc = (window as any).data?.sessions?.[index]?.ui?.status?.location;
    if (!loc || loc.path == null) return null;
    return { path: String(loc.path), line: Number(loc.line), rrTicks: Number(loc.rrTicks) };
  }, index));
}

/**
 * Poll tab `index`'s location until `ok` holds, and return the last value the
 * renderer answered with (null if it never answered, or answered that the tab
 * has no location) — the caller asserts on it, so a failure names where the
 * tab stood. Which of the two a null means is logged, since an unanswering
 * renderer and a tab with no position are different failures.
 */
async function lastLocation(page: Page, index: number,
                            ok: (l: TabLocation) => boolean, attempts: number): Promise<TabLocation | null> {
  let last: TabLocation | null = null;
  let answers = 0;
  let lastError = "";
  await retry(
    async () => {
      try {
        last = await tabLocation(page, index);
        answers += 1;
      } catch (e) {
        lastError = String(e);
        throw e;
      }
      return !!last && ok(last);
    },
    { maxAttempts: attempts, delayMs: 1000 },
  ).catch(() => undefined);
  console.log(`# tab ${index} location: ${JSON.stringify(last)} after ${answers} answer(s)` +
    (lastError ? `; last unanswered read: ${lastError}` : ""));
  return last;
}

/**
 * Wait until tab `index` has no step in flight: its own run state
 * (`ReplaySession.status.stableBusy`), which a step sets and that tab's next
 * move clears (`middleware.setupMiddlewareApis`).
 */
async function waitForStepSettled(page: Page, index: number): Promise<void> {
  await retry(
    async () =>
      answered(`tab ${index}'s run state`, page.evaluate(
        (index) => (window as any).data?.sessions?.[index]?.status?.stableBusy === false, index)),
    { maxAttempts: 60, delayMs: 500 },
  );
}

/**
 * Step over once in the tab on screen and return where that tab moved to;
 * fails when the shown tab's location did not change.
 */
async function stepOverInShownTab(page: Page, index: number): Promise<TabLocation> {
  const before = await tabLocation(page, index);
  expect(before, `tab ${index} has a location before the step`).not.toBeNull();
  await waitForStepSettled(page, index);
  await new LayoutPage(page).clickNextButton();
  let after: TabLocation | null = before;
  await retry(
    async () => {
      after = await tabLocation(page, index);
      return !!after && (after.line !== before!.line || after.rrTicks !== before!.rrTicks);
    },
    { maxAttempts: 60, delayMs: 500 },
  ).catch(() => undefined);
  await waitForStepSettled(page, index);
  // WHERE THE STEP ENDED, not the first move seen: a step can report more
  // than one position before it settles (line 7, then 10, measured), and the
  // first one seen is not where the tab stands. Read until two reads 500 ms
  // apart agree, and return that.
  let settled: TabLocation | null = await tabLocation(page, index);
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(500);
    const again = await tabLocation(page, index);
    if (JSON.stringify(again) === JSON.stringify(settled)) break;
    settled = again;
  }
  if (JSON.stringify(settled) !== JSON.stringify(after)) {
    console.log(`# tab ${index}'s step: first seen ${JSON.stringify(after)}, settled ${JSON.stringify(settled)}`);
  }
  expect(settled, `a step in the shown tab ${index} moves tab ${index} (from ${JSON.stringify(before)})`)
    .not.toEqual(before);
  return settled!;
}

test.describe("IsoNim panes render in every tab, not only the first", () => {
  test.setTimeout(300_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("test_open_second_trace: a second recording opened in a + tab shows its own panes and its own data", async ({ ctPage }) => {
    await openSecondRecordingInNewTab(ctPage);

    // (b) Mounted: each host carries a view; and (d) the replay panes show
    // basics.py's run, not py_console_logs'. Read in ONE poll, so whatever
    // the renderer last answered is what is judged — the data first.
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
    const basicsPanes = ownDataPanes("basics");
    const reading = await settledPanes(ctPage, 1, { ...secondTab, ...basicsPanes }, 90);
    printPanes(reading, "tab 1");
    const inv1 = await inventory(ctPage, 1);
    console.log(`# session-container-1 after loading basics.py: ${inv1}`);
    expectPanes(reading, basicsPanes,
      "the second replay tab (session-container-1) must show basics.py's data, not py_console_logs'", inv1);
    expectPanes(reading, secondTab, "the second replay tab (session-container-1)", inv1);
    await showTerminal(ctPage, 1);
    const terminal1 = await settledPanes(ctPage, 1, ownTerminal("basics"), 60);
    printPanes(terminal1, "tab 1");
    expectPanes(terminal1, ownTerminal("basics"),
      "the second replay tab's Terminal, shown, must show basics.py's output", await inventory(ctPage, 1));

    // (c) The first tab still renders its panes after the round trip, and
    // (d) they are still py_console_logs', not basics.py's.
    await switchToTab(ctPage, 0);
    const firstTab = {
      "stateComponent-0": nonEmpty,
      "calltraceComponent-0": nonEmpty,
      "eventLogComponent-0": nonEmpty,
      "terminalComponent-0": nonEmpty,
      "vCSComponent-0": nonEmpty,
      "testResultsComponent-0": nonEmpty,
    };
    const consolePanes = ownDataPanes("consoleLogs");
    const first = await settledPanes(ctPage, 0, { ...firstTab, ...consolePanes }, 30);
    printPanes(first, "tab 0");
    const inv0 = await inventory(ctPage, 0);
    expectPanes(first, consolePanes,
      "the first replay tab (session-container-0) must show py_console_logs' data after switching back", inv0);
    expectPanes(first, firstTab, "the first replay tab (session-container-0) after switching back", inv0);
    await showTerminal(ctPage, 0);
    const terminal0 = await settledPanes(ctPage, 0, ownTerminal("consoleLogs"), 30);
    printPanes(terminal0, "tab 0");
    expectPanes(terminal0, ownTerminal("consoleLogs"),
      "the first replay tab's Terminal, shown, must show py_console_logs' output", await inventory(ctPage, 0));
  });

  test("test_step_independent_tabs: stepping one tab moves that tab only", async ({ ctPage }) => {
    await openSecondRecordingInNewTab(ctPage);
    // Tab 1's own data first, read while the replay has just loaded: what it
    // shows decides whether there is a tab 1 position to step from at all,
    // and it is the reading the issue is about (tab 1 showing the first
    // tab's recording), so a failure is named by it rather than by whatever
    // stops answering afterwards.
    const tab1Data = { "calltraceComponent-0": showsOnly(BASICS, CONSOLE_LOGS) };
    const tab1Loaded = await settledPanes(ctPage, 1, tab1Data, 90);
    printPanes(tab1Loaded, "tab 1 before stepping");
    expectPanes(tab1Loaded, tab1Data,
      "the second replay tab (session-container-1) must show basics.py's data before it is stepped",
      await inventory(ctPage, 1));
    // Both replays have reached a stop before anything is stepped — each in
    // its own tab's status bar. Polled, then asserted, so a run that never
    // gets there says where each tab's status bar stood.
    const tab1Start = await lastLocation(ctPage, 1, (l) => l.path.includes("basics.py"), 90);
    const tab0Start = await lastLocation(ctPage, 0, (l) => l.path.includes("main.py"), 30);
    console.log(`# start: tab 0 ${JSON.stringify(tab0Start)} tab 1 ${JSON.stringify(tab1Start)}`);
    expect(tab1Start?.path ?? null, "tab 1's own status bar stands in basics.py, the recording tab 1 loaded")
      .toContain("basics.py");
    expect(tab0Start?.path ?? null, "tab 0's own status bar stands in main.py").toContain("main.py");

    // Step in tab 1 (on screen): tab 1 moves, within basics.py; tab 0 does not.
    const tab1Stepped = await stepOverInShownTab(ctPage, 1);
    expect(tab1Stepped.path).toContain("basics.py");
    expect(await tabLocation(ctPage, 0), "tab 0 after a step in tab 1").toEqual(tab0Start);

    // Switch to tab 0 and step there: tab 0 moves, within main.py; tab 1 does not.
    await switchToTab(ctPage, 0);
    const tab0Stepped = await stepOverInShownTab(ctPage, 0);
    expect(tab0Stepped.path).toContain("main.py");
    expect(await tabLocation(ctPage, 1), "tab 1 after a step in tab 0").toEqual(tab1Stepped);

    // Back to tab 1: it is where it was left, and its panes are still its own.
    await switchToTab(ctPage, 1);
    expect(await tabLocation(ctPage, 1), "tab 1 shown again").toEqual(tab1Stepped);
    expect(await tabLocation(ctPage, 0), "tab 0 while tab 1 is shown again").toEqual(tab0Stepped);
    const calltrace = { "calltraceComponent-0": showsOnly(BASICS, CONSOLE_LOGS) };
    const shownAgain = await settledPanes(ctPage, 1, calltrace, 30);
    expectPanes(shownAgain, calltrace, "tab 1's Call Trace after the round trip", await inventory(ctPage, 1));
  });

  test("test_load_answers_reach_their_tab: a load answered while another tab is shown reaches the tab that asked", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();
    const secondTraceId = recordTestProgram(path.join(testProgramsPath, "py_checklist", "basics.py"));
    await ctPage.locator(".session-tab-add").click();
    await retry(async () => (await activeSessionIndex(ctPage)) === 1, { maxAttempts: 40, delayMs: 250 });

    // Ask from tab 1, and show tab 0 before any answer can arrive: one
    // evaluate, so no IPC message is handled between the two.
    await answered("asking from tab 1, then showing tab 0", ctPage.evaluate((id) => {
      (window as any).data.ipc.send("CODETRACER::load-recent-trace", { traceId: id });
      (document.querySelectorAll(".session-tab")[0] as HTMLElement).click();
    }, secondTraceId));
    expect(await activeSessionIndex(ctPage)).toBe(0);

    // Wait for the load to have answered: its `trace-loaded` either waits on
    // tab 1 or (the defect) has been applied to the tab on screen.
    const readTabs = () => answered("both tabs' recordings and queues", ctPage.evaluate(() => {
      const sessions = (window as any).data?.sessions ?? [];
      const program = (i: number) => String(sessions[i]?.trace?.program ?? "");
      const queued = (sessions[1]?.pendingTabAnswers ?? []).map((a: any) => String(a?.message ?? ""));
      return { tab0: program(0), tab1: program(1), queued };
    }));
    let tabs = await readTabs();
    await retry(async () => {
      tabs = await readTabs();
      return tabs.queued.includes("CODETRACER::trace-loaded") || tabs.tab0.includes("basics.py");
    }, { maxAttempts: 90, delayMs: 1000 }).catch(() => undefined);
    console.log(`# while tab 0 is shown: ${JSON.stringify(tabs)}`);
    expect(tabs.tab0, "tab 0 keeps its own recording while tab 1's load is answered").toContain("main.py");
    expect(tabs.tab0).not.toContain("basics.py");
    expect(tabs.queued, "tab 1's load answers wait for tab 1").toContain("CODETRACER::trace-loaded");
    const tab0Data = { "calltraceComponent-0": showsOnly(CONSOLE_LOGS, BASICS) };
    const tab0Reading = await settledPanes(ctPage, 0, tab0Data, 10);
    expectPanes(tab0Reading, tab0Data, "tab 0's Call Trace while tab 1's load is answered", await inventory(ctPage, 0));

    // Shown, tab 1 gets what waited for it: basics.py, in its own panes.
    await switchToTab(ctPage, 1);
    const tab1Data = { "calltraceComponent-0": showsOnly(BASICS, CONSOLE_LOGS) };
    const tab1Reading = await settledPanes(ctPage, 1, tab1Data, 90);
    printPanes(tab1Reading, "tab 1 after it is shown");
    expectPanes(tab1Reading, tab1Data, "tab 1's Call Trace once it is shown", await inventory(ctPage, 1));
    tabs = await readTabs();
    expect(tabs.tab1).toContain("basics.py");
    expect(tabs.queued).toEqual([]);
    expect(tabs.tab0, "tab 0 still holds its own recording").toContain("main.py");
  });
});
