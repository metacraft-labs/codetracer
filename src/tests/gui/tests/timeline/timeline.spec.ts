/**
 * timeline.spec.ts — the L6 companion to
 * `src/tests/gui/tests/timeline/timeline_vm_test.nim` (issue #693).
 *
 * WHAT THIS COVERS THAT THE HEADLESS SUITES CANNOT
 * ------------------------------------------------
 * `timeline_vm_test.nim` grades the projections and `isonim_views_test.nim`
 * grades the DOM the view emits through the mock renderer. Neither can see:
 *
 *   * whether the marks and the labels are VISIBLE — they are placed by an
 *     inline `left` percentage and made visible by
 *     `src/frontend/styles/components/timeline.styl`; a mock DOM has no
 *     stylesheet and no layout, so a rule that never reached the built CSS
 *     would not redden either suite;
 *   * whether `mountIsoNimTimeline`'s render effect really redraws the panel
 *     when the extent arrives — on a replay the extent arrives with the event
 *     log (PLAT-41), i.e. AFTER mount, and a mount-time-only render would
 *     show the empty state for ever;
 *   * DRAG to seek (`Front-Ends/Electron-GUI.md:156`). A drag is
 *     mousedown / mousemove / mouseup against a laid-out element with a
 *     non-zero `getBoundingClientRect().width`. The mock renderer has neither
 *     layout nor a pointer, so this file is the ONLY place the drag path is
 *     exercised at all.
 *
 * STATUS: **NEVER EXECUTED.** Written 2026-09-24 against codetracer `dev`
 * `a9b3aaf4d`. `just build-once` does not complete on the host this was
 * authored on — no Electron, no Playwright — so nothing below has been run.
 * It typechecks (`npx tsc --noEmit` in `src/tests/gui`) and that is the whole
 * of the evidence for it. Treat a first green run as a measurement still
 * owed, not as a re-confirmation.
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

test.describe("Timeline — execution overview", () => {
  test.use({ sourcePath: "c_sudoku_solver/main.c", launchMode: "trace" });

  test("the timeline shows the recording's extent, tick labels and event markers", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTimelineLoaded();

    const timeline = (await layout.timelineTabs(true))[0];
    if (timeline === undefined) {
      throw new Error("Timeline pane did not open");
    }
    await timeline.clickTab();

    // THE EXTENT. On a completed replay this arrives with the event log, so
    // it is polled rather than read once: reading it immediately after mount
    // would be reading the empty state and calling it a failure.
    await expect.poll(() => timeline.maxTicks(), { timeout: 30_000 }).toBeGreaterThan(0);

    // …and once it is known the empty state must be gone. Both halves, so a
    // view that rendered the note and the track together still fails.
    await expect(timeline.emptyState()).toBeHidden();
    await expect(timeline.track()).toBeVisible();

    // TICK LABELS, at the default 1.0x zoom: five gradations, the first
    // naming the recording's first tick and the last its last.
    await expect(timeline.tickLabels()).toHaveCount(5);
    const min = await timeline.minTicks();
    const max = await timeline.maxTicks();
    await expect(timeline.tickLabels().first()).toHaveText(String(min));
    await expect(timeline.tickLabels().last()).toHaveText(String(max));

    // EVENT MARKERS. `Front-Ends/Electron-GUI.md:155`. A C recording with a
    // calltrace has calls; asserting only ">= 1" rather than an exact count
    // is deliberate, because the marks are a projection of the calltrace
    // WINDOW the pane has paged and the window size is not this test's
    // business.
    await expect.poll(() => timeline.markersOfKind("call").count(), { timeout: 30_000 })
      .toBeGreaterThan(0);
    // The marks must be laid out, not merely present: a rule missing from the
    // built stylesheet leaves a zero-sized element that no user can see, and
    // that is precisely what the headless suites cannot detect.
    const firstMark = timeline.markersOfKind("call").first();
    const markBox = await firstMark.boundingBox();
    expect(markBox).not.toBeNull();
    expect(markBox!.width).toBeGreaterThan(0);
    expect(markBox!.height).toBeGreaterThan(0);

    // The pane reports the real total even when it caps what it draws.
    expect(await timeline.markerCount()).toBeGreaterThanOrEqual(
      await timeline.markers().count(),
    );
  });

  test("dragging the playhead seeks, and lands where it was released", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTimelineLoaded();

    const timeline = (await layout.timelineTabs(true))[0];
    if (timeline === undefined) {
      throw new Error("Timeline pane did not open");
    }
    await timeline.clickTab();
    await expect.poll(() => timeline.maxTicks(), { timeout: 30_000 }).toBeGreaterThan(0);

    const min = await timeline.minTicks();
    const max = await timeline.maxTicks();
    const quarter = min + Math.floor((max - min) / 4);
    const threeQuarters = min + Math.floor((3 * (max - min)) / 4);

    await timeline.dragFromTickToTick(quarter, threeQuarters);

    // The engine answers a seek with `stopped` + `ct/complete-move`, so the
    // position is polled rather than read. The tolerance is one percent of
    // the recording: a drag lands on a PIXEL, and a pixel is more than one
    // tick wide on any recording long enough to be worth scrubbing.
    const tolerance = Math.max(1, Math.floor((max - min) / 100));
    await expect
      .poll(() => timeline.currentTicks(), { timeout: 30_000 })
      .toBeGreaterThan(threeQuarters - tolerance);
    expect(await timeline.currentTicks()).toBeLessThan(threeQuarters + tolerance);
  });
});
