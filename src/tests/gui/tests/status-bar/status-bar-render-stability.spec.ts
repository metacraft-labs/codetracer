/**
 * Status-bar render stability, bottom-strip contract, and console
 * cleanliness on a trace open.
 *
 * Covers the verification tests of Value-Origin-Tracking milestones M46,
 * M47 and M48.  All three are about the same thing from different angles:
 * whether what the GUI suite observes during a trace open is trustworthy.
 *
 * **M46.**  `StatusComponent.requestStatusRender` used to call
 * `renderStatusInto`, which removed *every* child of `#status` and rebuilt
 * the whole subtree — on each of the 60+ redraws a single trace open
 * triggers.  `.location-path`, `#copy-path-image`, `#file-info-status` and
 * both auto-hide hosts were therefore destroyed and re-created dozens of
 * times per second while the app was still loading, and each pass also
 * emitted an ERROR-level log line.
 *
 * The failure that motivated this is worth recording, because the obvious
 * story about it is wrong.  When `readyOnEntryTest` timed out waiting for
 * `.location-path`, the captured DOM showed the element present, in the
 * page Playwright held (the same page whose console the run captured),
 * carrying the correct `path:line#ticks` text — and Playwright's call log
 * contained no `locator resolved to …` line at all.  A poll cannot land
 * "between children removed and children re-appended": the renderer is
 * single-threaded and `renderStatusInto` tore down and rebuilt inside one
 * task.  What it can do is never run — Playwright's locator poll is driven
 * from the page, and during the open the renderer was executing hundreds of
 * status rebuilds and 700+ `console.error` round-trips in a few seconds.
 * So the fix is to stop generating the work, not to wait more leniently:
 * the shell is now patched in place unless its *structure* changes, the
 * redraws are coalesced to one pass per task turn, and the per-render ERROR
 * log is gone.
 *
 * **M47.**  The strip's tabs are direct children of
 * `#auto-hide-bottom-strip`.  This file is the runnable evidence for that
 * shape; the eight specs that assert against the strip use the same
 * selectors through `page-objects/auto-hide-strip.ts`.
 *
 * **M48.**  `datatable.nim:306` logged
 * `Cannot read properties of null (reading 'scroller')` four times on every
 * launch.
 *
 * No mocks: a real JavaScript recording opened by the real Electron app.
 */
import {
  test,
  expect,
  readyOnEntryTest as readyOnEntry,
} from "../../lib/fixtures";
import { recordJsTraceFixture } from "../../lib/js-trace-fixture";
import {
  BOTTOM_STRIP_IN_FOOTER_SELECTOR,
  BOTTOM_STRIP_SELECTOR,
  DEFAULT_BOTTOM_TAB_COUNT,
  DEFAULT_BOTTOM_TAB_TITLES,
  RETIRED_BOTTOM_TABS_SELECTOR,
  bottomStripTabs,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

/**
 * Two statements on line 1 and one on line 2, so a single step-over moves
 * the status bar's location text without changing anything structural.
 */
const PROGRAM = "var a = 1; var b = 2;\nvar c = a + b;\n";

const fixture = recordJsTraceFixture("status-render-stability", PROGRAM);

test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

/**
 * Upper bound on the number of *render passes* a trace open may cost.
 *
 * The requests themselves are not bounded here — they come from six
 * independent and individually legitimate sources (see the comment above
 * `requestStatusRender` in `src/frontend/ui/status.nim`) and a future
 * feature is allowed to add a seventh.  What must stay bounded is the work:
 * one coalesced pass per task turn, and a *rebuild* only when the bar's
 * structure actually changes.
 *
 * The structural transitions on a clean open are: empty shell → shell with
 * a location, plus the connection/finished toggles the session may pass
 * through.  Eight leaves room for those without leaving room for the old
 * "rebuild on every redraw" behaviour, which produced 60+.
 */
const MAX_SHELL_REBUILDS = 8;

interface StatusRenderStats {
  requests: number;
  passes: number;
  rebuilds: number;
}

async function statusRenderStats(
  page: import("@playwright/test").Page,
): Promise<StatusRenderStats> {
  return page.evaluate(() => {
    const read = (window as unknown as {
      __ctStatusRenderStats?: () => StatusRenderStats;
    }).__ctStatusRenderStats;
    if (!read) {
      throw new Error(
        "window.__ctStatusRenderStats is missing — the renderer's status " +
          "bookkeeping (src/frontend/ui/status.nim) did not load",
      );
    }
    return read();
  }) as Promise<StatusRenderStats>;
}

test.describe("status bar render stability", () => {
  test.setTimeout(180_000);

  test("verify_status_bar_nodes_survive_a_redraw", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    // Tag the nodes whose identity the milestone cares about.  A tag set
    // from the page survives only as long as the element object does: if
    // the status bar rebuilds its subtree, the tagged nodes are discarded
    // and the freshly created replacements carry no tag.
    const tagged = await ctPage.evaluate(() => {
      const ids = [
        ".location-path",
        "#copy-path-image",
        "#file-info-status",
        "#auto-hide-bottom-strip",
        "#auto-hide-collapsed-icon-zone",
      ];
      const missing: string[] = [];
      for (const selector of ids) {
        const el = document.querySelector(selector);
        if (!el) {
          missing.push(selector);
          continue;
        }
        el.setAttribute("data-ct-identity-probe", selector);
      }
      return { missing };
    });
    expect(
      tagged.missing,
      "every status-bar node under test must exist before the step",
    ).toEqual([]);

    const locationBefore = await ctPage
      .locator(".location-path")
      .textContent();
    expect(locationBefore ?? "").not.toBe("");

    // Step, which changes `StatusBaseModel.locationText` (the text is
    // `path:line#rrTicks`, so even a same-line hop moves it) and therefore
    // forces the status bar to redraw with new content.  Driven through the
    // same statement-granularity surface `statement_step_over.spec.ts`
    // uses, and asserted to exist rather than optional-chained away, so a
    // missing wiring fails here instead of silently making this test a
    // no-op.
    await ctPage.evaluate(() => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const fn = w?.data?.services?.debugger?.stepOverStatement;
      if (typeof fn !== "function") {
        throw new Error(
          "data.services.debugger.stepOverStatement is not a function; " +
            "cannot drive a step to redraw the status bar",
        );
      }
      fn.call(w.data.services.debugger);
    });

    await expect
      .poll(async () => ctPage.locator(".location-path").textContent(), {
        timeout: 30_000,
        intervals: [100, 250, 500],
      })
      .not.toBe(locationBefore);

    // The text moved; the elements did not.
    const survivors = await ctPage.evaluate(() =>
      Array.from(document.querySelectorAll("[data-ct-identity-probe]")).map(
        (el) => el.getAttribute("data-ct-identity-probe"),
      ),
    );
    expect(
      survivors.sort(),
      "a location change must patch the status bar, not rebuild it",
    ).toEqual(
      [
        ".location-path",
        "#copy-path-image",
        "#file-info-status",
        "#auto-hide-bottom-strip",
        "#auto-hide-collapsed-icon-zone",
      ].sort(),
    );
  });

  test("verify_status_render_count_is_bounded_on_trace_open", async ({
    ctPage,
  }) => {
    await readyOnEntry(ctPage);

    // Give the startup bursts (`refreshStatusFromDebugger` polls ten times
    // at 500ms, and the replay backend settles the entry location over a
    // second or so) time to finish before reading the counters, so the
    // measurement covers the whole open rather than a prefix of it.
    await ctPage.waitForTimeout(8_000);

    const stats = await statusRenderStats(ctPage);
    console.log(
      `# status renders: requests=${stats.requests} passes=${stats.passes} ` +
        `rebuilds=${stats.rebuilds}`,
    );

    expect(
      stats.requests,
      "the counters must actually be recording something",
    ).toBeGreaterThan(0);

    // Coalescing: a burst of requests inside one task turn must cost one
    // pass.  Opening a trace produced 60+ requests when this was written,
    // so an open that spends a pass per request has lost the coalescing.
    expect(
      stats.passes,
      `render passes (${stats.passes}) must be fewer than requests ` +
        `(${stats.requests}) — redraws are coalesced per task turn`,
    ).toBeLessThan(stats.requests);

    // Reconciliation: passes are cheap only if they patch.  This is the
    // assertion that fails if `renderStatusInto` goes back to tearing the
    // subtree down.
    expect(
      stats.rebuilds,
      `full #status rebuilds (${stats.rebuilds}) must stay at the handful ` +
        "of genuine structural transitions a trace open passes through",
    ).toBeLessThanOrEqual(MAX_SHELL_REBUILDS);
  });

  test("verify_bottom_strip_renders_its_tabs_as_direct_children", async ({
    ctPage,
  }) => {
    await readyOnEntry(ctPage);

    // The strip is in the footer, per Auto-Hide-Panes.md §3.1.
    await expect(
      ctPage.locator(BOTTOM_STRIP_IN_FOOTER_SELECTOR),
    ).toHaveCount(1);

    // The standalone panes `layout.nim` registers at boot are the strip's
    // baseline on every trace open, whatever the recorded language.
    await waitForDefaultBottomTabs(ctPage);
    for (const title of DEFAULT_BOTTOM_TAB_TITLES) {
      await expect(
        bottomStripTabs(ctPage).filter({ hasText: title }),
        `the ${title} pane must appear in the bottom strip`,
      ).toHaveCount(1);
    }

    // Direct children, with nothing wrapping them: `bottomStripTabs` uses
    // the `> .auto-hide-strip-tab` child combinator, so a re-introduced
    // wrapper would make these two counts disagree.
    const descendantTabs = ctPage.locator(
      `${BOTTOM_STRIP_SELECTOR} .auto-hide-strip-tab`,
    );
    await expect(descendantTabs).toHaveCount(DEFAULT_BOTTOM_TAB_COUNT);

    // The retired wrapper class must not be back.
    await expect(ctPage.locator(RETIRED_BOTTOM_TABS_SELECTOR)).toHaveCount(0);

    // The host keeps its semantic class alongside the `has-tabs` marker —
    // the strip mount used to overwrite the class outright, so the host's
    // class depended on whether the status render or the strip mount ran
    // last.
    await expect(ctPage.locator(BOTTOM_STRIP_SELECTOR)).toHaveClass(
      /(^|\s)auto-hide-bottom-strip(\s|$)/,
    );
    await expect(ctPage.locator(BOTTOM_STRIP_SELECTOR)).toHaveClass(
      /(^|\s)has-tabs(\s|$)/,
    );
  });

  test("verify_clean_console_on_trace_open", async ({
    ctPage,
    consoleErrors,
  }) => {
    await readyOnEntry(ctPage);
    // Let the panels finish initialising: the DataTable null dereference
    // this guards fired while the event log was still building its tables.
    await ctPage.waitForTimeout(8_000);

    const nullDerefs = consoleErrors.filter((line) =>
      line.includes("Cannot read properties of null"),
    );
    expect(
      nullDerefs,
      "opening a trace must not log a null dereference — see M48; the " +
        "known one was `datatable.nim:306` reading `scroller` off a " +
        "DataTable that had not been constructed yet",
    ).toEqual([]);

    // The status bar used to log one ERROR line per render, 60+ per open.
    const statusRenderLogs = consoleErrors.filter((line) =>
      line.includes("status: rendering status bar"),
    );
    expect(
      statusRenderLogs,
      "the status bar must not log at ERROR on the happy path",
    ).toEqual([]);

    // ------------------------------------------------------------------
    // M51: the whole ERROR bucket, not two known substrings.
    //
    // The two assertions above are M48's, and they could only ever be
    // written as substring filters because a clean trace open used to emit
    // 713 ERROR lines — 705 of them progress traces ("creating store",
    // "mounting now", "mount COMPLETE", "synced N locals") logged through
    // `cerror` across NINE renderer modules, plus three the harness itself
    // emitted at ERROR while reporting a healthy page.  M51 demoted them,
    // leaving 3.  The bucket can now be asserted whole: an ERROR line that
    // survives here is one that MEANS something.
    //
    // Do not add to ALLOWED_STARTUP_ERRORS to make a red run green.  Each
    // entry is a genuine startup error that is filed and outlives this
    // milestone; the allowlist exists so that those do not mask the next
    // real regression, not so that regressions can be waved through.
    const ALLOWED_STARTUP_ERRORS: { match: string; why: string }[] = [
      {
        // Thrown by monaco-languageclient's `workerFactory.js` when
        // monaco's TypeScript language mode asks for a web worker and no
        // `MonacoEnvironment.getWorker` is configured for the Electron
        // file:// renderer.  A genuine unhandled rejection, filed against
        // M51; it degrades TS language features in the editor and is not
        // caused by anything under test here.  Fixing it means configuring
        // monaco's worker environment, which is not a logging change.
        match: "Unimplemented worker javascript (workerMain.js)",
        why: "monaco language-client worker is unconfigured in the Electron renderer — filed by M51",
      },
    ];

    // Restrict to the error-level entries before asserting.  The bucket is
    // normally error-only, but `CODETRACER_TEST_LOG_ALL_CONSOLE=1` — the
    // switch someone debugging a failure here would reach for first — also
    // pushes `[console.log]` / `[console.debug]` lines into it, and without
    // this filter that switch would drown the assertion in ~3000 lines of
    // the very progress traces M51 demoted.  `[console.error]` and
    // `[pageerror]` are the two prefixes `attachErrorCollectors` uses for
    // genuine faults, so this is exactly the ERROR bucket and nothing less.
    const errorLevel = consoleErrors.filter(
      (line) =>
        line.startsWith("[console.error]") || line.startsWith("[pageerror]"),
    );
    const unexplained = errorLevel.filter(
      (line) => !ALLOWED_STARTUP_ERRORS.some((a) => line.includes(a.match)),
    );
    expect(
      unexplained,
      "opening a trace must produce an EMPTY renderer ERROR bucket apart " +
        "from the explicitly justified entries in ALLOWED_STARTUP_ERRORS " +
        "(see M51).  An ERROR line here is either a real fault worth " +
        "fixing, or a progress trace that belongs at `cdebug` — decide " +
        "which and do that, rather than widening the allowlist.\n" +
        `allowlist: ${ALLOWED_STARTUP_ERRORS.map((a) => `${a.match} (${a.why})`).join("; ")}`,
    ).toEqual([]);
  });
});
