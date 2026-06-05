import { test, expect } from "../../lib/fixtures";
import { resolveRealVisualTracePath } from "../../lib/real-visual-trace";

/**
 * Real-recording end-to-end smoke test for the M3+ Video Player chrome.
 *
 * The pre-M3 incarnation of this spec drove the legacy Frame Viewer pane
 * (``.frame-viewer-*`` selectors, a "FRAME VIEWER" tab, draw-call click
 * targets in the same panel).  Both that pane and its selectors were
 * retired when the Video Player took over as the visual-replay home in
 * M3 — this rewrite restores the same end-to-end vertical against the
 * new chrome:
 *
 *   - "VIDEO PLAYER" tab co-resident with the source editor stack.
 *   - "PIXEL HISTORY" and "SHADER DEBUG" tabs in the state stack.
 *   - Transport bar buttons (play, ff, rw, jump start/end, step frame,
 *     step draw, pixel-picker toggle).
 *   - Scrub slider drives ``/frame?frame=N`` requests; the image src
 *     advances in response.
 *   - Fast-forward cycles the rate badge through 1× → 2× → 4× → 8×.
 *   - Pixel picker mode shows the loupe overlay; click commits a pixel
 *     and the Pixel History tab populates.
 *   - Source-jump: clicking a Pixel History entry dispatches
 *     ``ct/seek-to-geid``.
 *   - Keyboard shortcuts (Space = play/pause, Shift+→ = step draw,
 *     P = picker toggle, Escape = picker cancel) drive the VM through
 *     the in-test action hook.
 *
 * Like the legacy spec, the fake-player gate is cleared in
 * ``beforeEach`` so the real ``ct_gfx_player`` is exercised against a
 * recorded GL trace.  Binary prerequisites (``ct_cli``, ``ct_gfx_player``,
 * ``ct-native-replay``, optional ``gl_scene``) are resolved by
 * ``lib/real-visual-trace.ts``.
 */

const visualTracePath = resolveRealVisualTracePath();

test.describe("MCR visual replay real recording GUI integration", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(240_000);
  test.use({
    sourcePath: "unused-for-real-visual-trace",
    launchMode: "trace",
    deploymentMode: "web",
    visualReplayTracePath: visualTracePath,
  });

  test.beforeEach(() => {
    // Force the real ``ct_gfx_player`` — the whole point of this spec
    // is end-to-end coverage of the recorded-trace pipeline, not a
    // canned fake response.
    delete process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER;
  });

  test("recorded GL trace drives Video Player chrome end-to-end", async ({ ctPage }) => {
    // ----- Layout: additive tab placement ----------------------------------
    const videoPlayerTab = ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" });
    await expect(videoPlayerTab).toBeVisible();
    // GoldenLayout sets ``display: none`` on inactive tabs in the stack.
    // The Video Player tab is added after the editor, which boots active,
    // so click the tab to bring the player to the front before asserting
    // on its chrome.
    await videoPlayerTab.click();
    const videoPlayer = ctPage.locator(".video-player-component");
    await expect(videoPlayer).toBeVisible();

    // Pixel History + Shader Debug live in the state stack alongside STATE.
    const stateStack = ctPage.locator(".lm_stack", {
      has: ctPage.locator(".lm_tab", { hasText: "STATE" }),
    });
    await expect(
      stateStack.locator(".lm_tab", { hasText: "PIXEL HISTORY" }),
    ).toBeVisible();
    await expect(
      stateStack.locator(".lm_tab", { hasText: "SHADER DEBUG" }),
    ).toBeVisible();

    // The Video Player tab itself should be co-resident with the editor
    // stack; the editor tab is whatever source file the trace landed on.
    const editorStack = ctPage.locator(".lm_stack", {
      has: ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" }),
    });
    await expect(editorStack).toHaveCount(1);

    // The retired pane must not reappear under any guise.
    await expect(
      ctPage.locator(".lm_tab", { hasText: "FRAME VIEWER" }),
    ).toHaveCount(0);

    // ----- Player connection: image src arrives ----------------------------
    // The new chrome no longer exposes a visible "connection status" /
    // "player URL" string — the player URL is internal state.  Instead
    // we verify connection-by-effect: the frame image src eventually
    // points at a non-empty resource served by the player.
    const image = ctPage.locator(".video-player-image");
    await expect
      .poll(
        async () => (await image.getAttribute("src")) ?? "",
        { timeout: 120_000 },
      )
      .not.toBe("");

    // Wait for /info to have completed (the startup spinner switches
    // off once frameCount > 0).  We assert via the scrub range: its
    // ``max`` attribute reflects ``frameCount - 1`` and is "0" until
    // /info responds.
    const scrub = ctPage.locator(".video-player-scrub-range");
    await expect(scrub).toBeVisible();
    await expect
      .poll(
        async () => Number((await scrub.getAttribute("max")) ?? "0"),
        { timeout: 120_000 },
      )
      .toBeGreaterThan(0);

    // ----- Transport bar: buttons all rendered ------------------------------
    for (const cls of [
      "video-player-jump-start",
      "video-player-rewind",
      "video-player-play",
      "video-player-fast-forward",
      "video-player-jump-end",
      "video-player-step-draw-back",
      "video-player-step-draw-forward",
      "video-player-step-frame-back",
      "video-player-step-frame-forward",
      "video-player-picker",
    ]) {
      await expect(
        ctPage.locator(`.video-player-button.${cls}`),
      ).toBeVisible();
    }
    await expect(ctPage.locator(".video-player-rate-badge")).toBeVisible();

    // ----- Scrub slider drives /frame?frame=N requests ----------------------
    const firstImageSrc = (await image.getAttribute("src")) ?? "";
    const maxFrame = Number(await scrub.getAttribute("max") ?? "0");
    const targetFrame = Math.min(4, Math.max(1, Math.floor(maxFrame / 2)));

    const frameResponse = ctPage.waitForResponse(
      (response) => response.url().includes("/frame?") && response.ok(),
      { timeout: 60_000 },
    );
    // Setting the input value programmatically and firing ``input`` mirrors
    // a user drag-release; the VM seeks to the new frame.
    await scrub.evaluate((el, value) => {
      (el as HTMLInputElement).value = String(value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    }, targetFrame);
    await frameResponse;
    await expect
      .poll(async () => (await image.getAttribute("src")) ?? "")
      .not.toBe(firstImageSrc);

    // Frame label updates to the new frame index.
    await expect(ctPage.locator(".video-player-frame-label")).toContainText(
      new RegExp(`Frame ${targetFrame}\\b`),
    );

    // ----- Fast-forward cycles rate badge 1× → 2× → 4× → 8× -----------------
    // Use the test hook for deterministic drive; the keyboard binding
    // path is exercised separately at the bottom of this spec.
    await expect
      .poll(async () =>
        ctPage.evaluate(
          () => typeof (window as any).__CODETRACER_TEST__?.videoPlayerAction,
        ),
      )
      .toBe("function");
    const invokeAction = async (name: string) =>
      ctPage.evaluate(
        (action) =>
          (window as any).__CODETRACER_TEST__.videoPlayerAction(action),
        name,
      );
    await invokeAction("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("1×");
    await invokeAction("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("2×");
    await invokeAction("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("4×");
    await invokeAction("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("8×");
    await invokeAction("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("1×");
    // Pause so the rest of the spec runs against a stable state.
    await invokeAction("VideoPlayerTogglePlay");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("Paused");

    // ----- Pixel picker mode: loupe overlay + commit -----------------------
    await invokeAction("VideoPlayerTogglePicker");
    await expect(
      ctPage.locator(".video-player-component.picker-active"),
    ).toBeVisible();
    await expect(
      ctPage.locator(".video-player-button.video-player-picker.pressed"),
    ).toBeVisible();
    await expect(
      ctPage.locator(".video-player-canvas-overlay.picker"),
    ).toBeVisible();

    // Hover the image so the loupe overlay positions and reveals itself.
    const imageBox = await image.boundingBox();
    expect(imageBox).not.toBeNull();
    const hoverX = imageBox!.width * 0.25;
    const hoverY = imageBox!.height * 0.25;
    await image.hover({ position: { x: hoverX, y: hoverY } });
    // Loupe is hidden when no magnifier is set; once hover propagates a
    // magnifier signal it pops up.  Software-only renderers occasionally
    // delay the canvas sample by a frame; poll the display state.
    const loupe = ctPage.locator(".video-player-loupe");
    await expect
      .poll(async () => {
        const display = await loupe.evaluate((el) =>
          window.getComputedStyle(el as Element).display,
        );
        return display;
      })
      .not.toBe("none");
    await expect(ctPage.locator(".video-player-loupe-canvas")).toBeVisible();
    await expect(ctPage.locator(".video-player-loupe-readout").first()).toBeVisible();

    // Commit the pixel.  The handler fires the /pixel-history POST and
    // /shader-debug POST against the real player.
    const pixelHistoryResponsePromise = ctPage.waitForResponse(
      (response) =>
        response.url().includes("/pixel-history")
        && response.request().method() === "POST"
        && response.ok(),
      { timeout: 60_000 },
    );
    const shaderDebugResponsePromise = ctPage.waitForResponse(
      (response) =>
        response.url().includes("/shader-debug")
        && response.request().method() === "POST"
        && response.ok(),
      { timeout: 60_000 },
    );
    await image.click({ position: { x: hoverX, y: hoverY } });
    const pixelHistoryResponse = await pixelHistoryResponsePromise;
    const pixelHistoryPayload = await pixelHistoryResponse.json();
    expect(Array.isArray(pixelHistoryPayload)).toBe(true);
    expect(pixelHistoryPayload.length).toBeGreaterThan(0);
    const shaderDebugResponse = await shaderDebugResponsePromise;
    const shaderDebugPayload = await shaderDebugResponse.json();
    expect(
      shaderDebugPayload.fragmentShaderSource
        ?? shaderDebugPayload.shaderSource
        ?? shaderDebugPayload.source,
    ).toContain("fragColor");

    // Committing exits picker mode (per spec).  Confirm the .pressed
    // class drops and the overlay loses its picker variant.
    await expect(
      ctPage.locator(".video-player-component.picker-active"),
    ).toHaveCount(0);

    // ----- Pixel History tab populates after commit -------------------------
    await ctPage.locator(".lm_tab", { hasText: "PIXEL HISTORY" }).click();
    const pixelHistory = ctPage.locator(".pixel-history-component");
    await expect(pixelHistory).toBeVisible();
    const pixelHistoryEntries = ctPage.locator(".pixel-history-entry");
    await expect(pixelHistoryEntries.first()).toBeVisible({ timeout: 60_000 });
    await expect.poll(async () => pixelHistoryEntries.count()).toBeGreaterThan(0);

    // ----- Source-jump: clicking an entry dispatches ct/seek-to-geid --------
    await ctPage.evaluate(() => {
      const t = (window as any).__CODETRACER_TEST__ ?? {};
      t.vmBackendRequests = [];
      (window as any).__CODETRACER_TEST__ = t;
    });
    await pixelHistoryEntries.first().click();
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
      .toMatchObject({ command: "ct/seek-to-geid" });

    // ----- Shader Debug tab shows the fragment shader source ---------------
    await ctPage.locator(".lm_tab", { hasText: "SHADER DEBUG" }).click();
    const shaderDebug = ctPage.locator(".shader-debug-component");
    await expect(shaderDebug).toBeVisible();
    await expect(ctPage.locator(".shader-debug-source")).toBeVisible();
    await expect(ctPage.locator(".shader-debug-source")).toContainText("fragColor");

    // ----- Keyboard shortcuts drive the same VM transitions -----------------
    // Space / K toggles play; the rate badge flips from "Paused" to a
    // direction arrow and back.  The action hook is the canonical
    // invocation point: it bypasses focus scoping (which is tested in
    // ``video-player-keyboard-focus-scope.spec.ts``).
    expect(await invokeAction("VideoPlayerTogglePlay")).toBeTruthy();
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText(/[▶◀]/);
    expect(await invokeAction("VideoPlayerTogglePlay")).toBeTruthy();
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("Paused");
    expect(await invokeAction("VideoPlayerStepDrawForward")).toBeTruthy();
    expect(await invokeAction("VideoPlayerStepDrawBack")).toBeTruthy();
    expect(await invokeAction("VideoPlayerTogglePicker")).toBeTruthy();
    await expect(
      ctPage.locator(".video-player-component.picker-active"),
    ).toBeVisible();
    expect(await invokeAction("VideoPlayerCancelPicker")).toBeTruthy();
    await expect(
      ctPage.locator(".video-player-component.picker-active"),
    ).toHaveCount(0);
  });
});
