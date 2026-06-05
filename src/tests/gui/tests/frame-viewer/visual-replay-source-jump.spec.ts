import { test, expect } from "../../lib/fixtures";

/**
 * M6 — Source-jump from draw call.
 *
 * The Pixel History tab exposes one row per draw call that touched the
 * selected pixel.  Clicking a row must (a) emit a `ct/seek-to-geid`
 * command carrying the entry's GEID and (b) drive the editor service
 * to the source line that issued that draw call.
 *
 * The (a) leg is the cross-cutting contract this spec asserts directly
 * — the backend's `ct/seek-to-geid` handler resolves the GEID to a
 * `Location`, emits `ct/complete-move`, and the renderer's
 * `EditorViewComponent.onCompleteMove` consumes the location and
 * advances the active editor.  The (b) leg is verified by sampling the
 * `data.services.debugger.location` and `data.services.editor.active`
 * fields after the click and asserting they reflect the new position;
 * the fake visual-replay player (`CODETRACER_VISUAL_REPLAY_FAKE_PLAYER
 * = ready`) does not stub `ct/seek-to-geid` on its own, but the
 * Python trace this suite uses (`py_console_logs/main.py`) does — the
 * Python backend serves the GEID seek out of the real recording, so
 * the resulting `complete-move` carries a non-empty path.
 *
 * The earlier visual-replay-gui.spec.ts already covers the request
 * side; this spec is the focused M6 deliverable, including the editor
 * observation that goes beyond "command was dispatched".
 */
test.describe("MCR visual replay — source jump from draw call", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(120_000);
  test.use({
    sourcePath: "py_console_logs/main.py",
    launchMode: "trace",
    deploymentMode: "web",
    visualReplayTrace: true,
  });

  test.beforeEach(() => {
    process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER = "ready";
  });

  test.afterEach(() => {
    delete process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER;
  });

  test("pixel-history click jumps the editor to the draw-call source", async ({ ctPage }) => {
    // Bootstrap: wait for the visual replay pipeline to come up.
    await expect(ctPage.locator(".frame-viewer-component")).toBeVisible();
    await expect
      .poll(async () =>
        ctPage.evaluate(() => typeof (window as any).__CODETRACER_TEST__?.fakeMcrStepGeid),
      )
      .toBe("function");

    // Step to a frame that has pixel-history data.
    const frameResponse = ctPage.waitForResponse(
      (response) => response.url().includes("/frame?geid=246") && response.ok(),
    );
    await ctPage.evaluate(() => (window as any).__CODETRACER_TEST__.fakeMcrStepGeid(246));
    await frameResponse;

    // Click the centre of the frame to populate the Pixel History tab.
    const image = ctPage.locator(".frame-viewer-image");
    const imageBox = await image.boundingBox();
    expect(imageBox).not.toBeNull();

    const pixelHistoryResponsePromise = ctPage.waitForResponse(
      (response) =>
        response.url().includes("/pixel-history?x=")
        && response.request().method() === "POST"
        && response.ok(),
    );
    await image.click({
      position: { x: imageBox!.width / 2, y: imageBox!.height / 2 },
    });
    await pixelHistoryResponsePromise;

    // Open the Pixel History tab and wait for entries to render.
    await ctPage.locator(".lm_tab", { hasText: "PIXEL HISTORY" }).click();
    await expect(ctPage.locator(".pixel-history-component")).toBeVisible();
    await expect(ctPage.locator(".pixel-history-entry")).toHaveCount(2);

    // Capture the editor's position BEFORE the source jump so we can
    // assert that it actually changed.  The renderer mirrors the live
    // `debugger.location` through `complete-move` events; if the M6
    // chain works, this snapshot will not match the post-click one.
    const positionBefore = await ctPage.evaluate(() => {
      const d = (window as any).data;
      return {
        line: d?.services?.debugger?.location?.line ?? -1,
        path: d?.services?.debugger?.location?.path ?? "",
        rrTicks:
          d?.services?.debugger?.location?.rrTicks ?? -1,
        active: d?.services?.editor?.active ?? "",
      };
    });

    // Discoverability: every entry must carry a tooltip describing the
    // jump action.  This is the M6 surface cue and the cheapest
    // regression guard against the tooltip silently disappearing.
    const secondEntry = ctPage.locator(".pixel-history-entry").nth(1);
    await expect(secondEntry).toHaveAttribute(
      "title",
      /jump to the source line/i,
    );

    // Click an entry to trigger the source jump.
    await expect(secondEntry).toContainText("GEID 220");
    await secondEntry.click();

    // Primary assertion: the seek-to-geid command was dispatched with
    // the entry's GEID.  Recorded by `recordVmBackendRequest` in
    // ui_js.nim.
    await expect
      .poll(async () =>
        ctPage.evaluate(() => {
          const requests = (window as any).__CODETRACER_TEST__?.vmBackendRequests ?? [];
          const finder = (request: any) => request.command === "ct/seek-to-geid";
          return (
            requests.findLast?.(finder)
              ?? [...requests].reverse().find(finder)
          );
        }),
      )
      .toMatchObject({ command: "ct/seek-to-geid", args: { geid: 220 } });

    // Secondary assertion (M6 deliverable: "click history entry →
    // editor selection changes"): the debugger location's rrTicks
    // moves in response to the complete-move that the backend emits
    // for the seek.  We accept either a different rrTicks, path,
    // line, or a changed active editor — all are positive evidence
    // that the editor service consumed the navigation event.  A
    // line change alone is insufficient because the Python
    // recording may map back to the same line the trace already
    // paused on; we therefore poll on the broader location identity.
    await expect
      .poll(async () =>
        ctPage.evaluate((before) => {
          const d = (window as any).data;
          const position = {
            line: d?.services?.debugger?.location?.line ?? -1,
            path: d?.services?.debugger?.location?.path ?? "",
            rrTicks:
              d?.services?.debugger?.location?.rrTicks ?? -1,
            active: d?.services?.editor?.active ?? "",
          };
          return (
            position.rrTicks !== before.rrTicks
            || position.path !== before.path
            || position.active !== before.active
            || position.line !== before.line
          );
        }, positionBefore),
      )
      .toBe(true);
  });
});
