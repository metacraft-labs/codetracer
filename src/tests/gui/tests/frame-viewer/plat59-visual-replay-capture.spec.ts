/**
 * plat59-visual-replay-capture.spec.ts — PLAT-59, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Visual Replay panes are
 * measured against.
 *
 * Spec: codetracer-pm `spec/GUI/Debugging-Features/Visual-Replay.md` (the Video
 * Player, its Scrub Slider, the Pixel Picker, Pixel History, Shader Debug) and
 * its "The terminal and the GPUI window (PLAT-59)" section.
 *
 * The real Electron front-end on the `gl_scene` visual recording the native
 * suites open (`scripts/record-visual-replay-fixture.sh`;
 * `test-logs/tui-fixtures/visual-gl-scene` or
 * `CODETRACER_VISUAL_REPLAY_FIXTURE`), its Visual Replay panes read from the
 * DOM:
 *
 *   * THE FRAME AT THREE POSITIONS — the first (Jump to Start), the slider's
 *     frame 30 (a drag on the slider: press, input, release) and the last
 *     (Jump to End): the frame label, and the colour of each of the four quads
 *     in the image the Video Player shows (read off the `<img>` at its natural
 *     size), in quadrant order;
 *   * A DRAW CALL: Step Draw Call back twice from the first frame's whole
 *     image — the draw label and the quads drawn so far;
 *   * A PICKED PIXEL: the picker (P) and a click on source pixel (40, 50) of the
 *     last frame — the Pixel History's header and rows (draw call, GEID,
 *     post-modify colour), the Shader Debug's context; a click on the last
 *     row, and the draw label after it.
 *
 * Written to `src/tests/visual/answers/plat59-visual-replay.electron.json`,
 * which `src/frontend/tui/tests/test_plat59_visual_replay.nim` and
 * `src/frontend/gpui/tests/test_plat59_gpui_visual_replay.nim` assert the
 * native panes against.
 *
 * No mocks: a real recording, a real `replay-server`, a real `ct_gfx_player`
 * (the desktop starts it, `index/visual_replay_player`), the real Electron app
 * running the desktop this checkout built (`just build-once`).
 */
import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersFile =
  process.env.PLAT59_ANSWERS_OUT ||
  path.join(repoRoot, "src", "tests", "visual", "answers", "plat59-visual-replay.electron.json");

function recording(): string {
  const env = process.env.CODETRACER_VISUAL_REPLAY_FIXTURE ?? "";
  for (const dir of [env, path.join(repoRoot, "test-logs", "tui-fixtures", "visual-gl-scene")]) {
    if (dir && fs.existsSync(path.join(dir, "gfx_stream", "gfx_frames.idx"))) return dir;
  }
  throw new Error(
    "PLAT-59: the visual recording is not here; run scripts/record-visual-replay-fixture.sh " +
      "or set CODETRACER_VISUAL_REPLAY_FIXTURE.",
  );
}

/** The four quads' colours in the image the Video Player shows, Q0..Q3. */
function readQuads(page: any) {
  return page.evaluate(async () => {
    const img = document.querySelector(".video-player-image") as HTMLImageElement | null;
    if (!img || !img.src) return null;
    if (!img.complete) await new Promise((r) => img.addEventListener("load", r, { once: true }));
    const w = img.naturalWidth;
    const h = img.naturalHeight;
    if (!w || !h) return null; // not decoded yet: not an image to read
    const c = document.createElement("canvas");
    c.width = w;
    c.height = h;
    const ctx = c.getContext("2d")!;
    ctx.drawImage(img, 0, 0);
    const hex = (x: number, y: number) => {
      const d = ctx.getImageData(x, y, 1, 1).data;
      return "#" + [d[0], d[1], d[2]].map((v) => v.toString(16).padStart(2, "0")).join("");
    };
    // Quadrant q: bottom (GL y < 0) for 0 and 1, right for 1 and 3; the
    // image's top row is the framebuffer's top.
    const at = (q: number) => hex(q % 2 === 1 ? (3 * w) / 4 : w / 4, q >= 2 ? h / 4 : (3 * h) / 4);
    // Which image this is: frames of solid quads can encode to the same
    // length, so a length would call a new frame unchanged.
    let src = 0;
    for (let i = 0; i < img.src.length; i++) src = (src * 31 + img.src.charCodeAt(i)) | 0;
    return { width: w, height: h, quads: [at(0), at(1), at(2), at(3)], src };
  });
}

function labels(page: any) {
  return page.evaluate(() => ({
    frame: (document.querySelector(".video-player-frame-label")?.textContent || "").trim(),
    draw: (document.querySelector(".video-player-draw-label")?.textContent || "").trim(),
  }));
}

async function action(page: any, name: string) {
  const ok = await page.evaluate((n: string) => (globalThis as any).__CODETRACER_TEST__?.videoPlayerAction?.(n), name);
  if (!ok) throw new Error(`the Video Player did not take ${name}`);
}

/** Wait until the frame label reads `want` and the image shows that frame. */
async function settle(page: any, want: string, previousSrc: number | null = null) {
  const deadline = Date.now() + 90_000;
  for (;;) {
    const l = await labels(page);
    const q = await readQuads(page);
    if (l.frame === want && q && q.src !== previousSrc) return { labels: l, quads: q };
    if (Date.now() > deadline) throw new Error(`the Video Player never showed ${want}: ${JSON.stringify(l)}`);
    await page.waitForTimeout(250);
  }
}

/** `gl_scene.c`'s `color_for_quadrant`: quad `q`'s colour at `frame`. */
function quadColour(frame: number, q: number): string {
  const seed = frame * 4 + q;
  return "#" + [(seed * 47 + 100) % 256, (seed * 73 + 50) % 256, (seed * 113 + 25) % 256]
    .map((v) => v.toString(16).padStart(2, "0")).join("");
}

test.describe("PLAT-59: the desktop's Visual Replay panes, captured", () => {
  test.setTimeout(600_000);
  test.use({
    // Opened as the desktop's gate opens a recorded GL trace
    // (`visual-replay-real-recording.spec.ts`): `ct host --trace-path`. The
    // debug server refuses this recording, and the panes do not need it.
    sourcePath: "unused-for-real-visual-trace",
    launchMode: "trace",
    deploymentMode: "web",
    visualReplayTracePath: path.join(recording(), "trace.ct"),
  });

  test("three frames, a draw call, a picked pixel's history", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e: any) => pageErrors.push(String(e?.stack ?? e)));
    // The Video Player tab the desktop added for a recording with graphics.
    const tab = ctPage.locator(".lm_tab", { hasText: /video player/i }).first();
    await tab.waitFor({ timeout: 180_000 });
    await tab.click();
    await ctPage.waitForSelector(".video-player-component", { timeout: 180_000 });
    await ctPage.waitForSelector(".video-player-image[src^='data:']", { timeout: 180_000 });

    const frames: any[] = [];
    // The first frame, reached from the last: the image shown at connect is
    // not a frame of the recording's, so the wait has to see the image change.
    await action(ctPage, "VideoPlayerJumpEnd");
    let shown = await settle(ctPage, "Frame 59 / 59");
    await action(ctPage, "VideoPlayerJumpStart");
    shown = await settle(ctPage, "Frame 0 / 59", shown.quads.src);
    frames.push({ frame: 0, label: shown.labels.frame, quadColours: shown.quads.quads });
    // Frame 30, by a drag on the slider: press, input, release.
    const before = shown.quads.src;
    await ctPage.evaluate(() => {
      const el = document.querySelector(".video-player-scrub-range") as HTMLInputElement;
      el.value = "10";
      el.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
      el.value = "20";
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.value = "30";
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    });
    shown = await settle(ctPage, "Frame 30 / 59", before);
    frames.push({ frame: 30, label: shown.labels.frame, quadColours: shown.quads.quads });
    // The last frame.
    await action(ctPage, "VideoPlayerJumpEnd");
    shown = await settle(ctPage, "Frame 59 / 59", shown.quads.src);
    frames.push({ frame: 59, label: shown.labels.frame, quadColours: shown.quads.quads });

    // A draw call: from frame 0's whole image (its last draw), two back.
    await action(ctPage, "VideoPlayerJumpStart");
    shown = await settle(ctPage, "Frame 0 / 59", shown.quads.src);
    await action(ctPage, "VideoPlayerStepDrawBack");
    await ctPage.waitForTimeout(500);
    await action(ctPage, "VideoPlayerStepDrawBack");
    const drawDeadline = Date.now() + 60_000;
    let drawLabels = await labels(ctPage);
    while (drawLabels.draw !== "Draw 1 / 3" && Date.now() < drawDeadline) {
      await ctPage.waitForTimeout(250);
      drawLabels = await labels(ctPage);
    }
    await ctPage.waitForTimeout(500);
    const drawQuads = await readQuads(ctPage);
    const draw = { frame: 0, label: drawLabels.draw, quadColours: drawQuads?.quads ?? [] };

    // A picked pixel: the last frame, the picker, a click on (40, 50).
    await action(ctPage, "VideoPlayerJumpEnd");
    shown = await settle(ctPage, "Frame 59 / 59", drawQuads?.src ?? null);
    await action(ctPage, "VideoPlayerTogglePicker");
    const box = await ctPage.locator(".video-player-image").boundingBox();
    if (!box) throw new Error("the Video Player's image has no box");
    const px = 40;
    const py = 50;
    const cx = box.x + ((px + 0.5) * box.width) / shown.quads.width;
    const cy = box.y + ((py + 0.5) * box.height) / shown.quads.height;
    await ctPage.mouse.move(cx, cy);
    await ctPage.mouse.click(cx, cy);
    const historyTab = ctPage.locator(".lm_tab", { hasText: "Pixel History" }).first();
    if (await historyTab.count()) await historyTab.click();
    await ctPage.waitForSelector(".pixel-history-entry", { timeout: 300_000 });
    const history = await ctPage.evaluate(() => ({
      header: (document.querySelector(".pixel-history-pixel")?.textContent || "").trim(),
      entries: Array.from(document.querySelectorAll(".pixel-history-entry")).map((e) => {
        const swatches = Array.from(e.querySelectorAll(".pixel-history-swatch")) as HTMLElement[];
        return {
          drawCallIndex: Number(((e.querySelector(".pixel-history-draw")?.textContent || "").match(/\d+/) || ["-1"])[0]),
          geid: Number((e as HTMLElement).dataset.geid ?? -1),
          pass: (e.querySelector(".pixel-history-pass")?.textContent || "").trim(),
          post: swatches.length >= 3 ? swatches[2].style.background : "",
        };
      }),
    }));
    const shaderTab = ctPage.locator(".lm_tab", { hasText: "Shader Debug" }).first();
    if (await shaderTab.count()) await shaderTab.click();
    await ctPage.waitForTimeout(1_000);
    const shader = await ctPage.evaluate(() => ({
      context: (document.querySelector(".shader-debug-context")?.textContent || "").trim(),
      lines: Array.from(document.querySelectorAll(".shader-debug-line-code")).map((e) => (e.textContent || "").trim()),
    }));
    // A row's click: the Video Player shows that draw call.
    if (await historyTab.count()) await historyTab.click();
    await ctPage.locator(".pixel-history-entry").last().click();
    const lastDraw = history.entries.length ? history.entries[history.entries.length - 1].drawCallIndex : -1;
    const navDeadline = Date.now() + 60_000;
    let navLabels = await labels(ctPage);
    while (navLabels.draw !== "Draw 2 / 3" && Date.now() < navDeadline) {
      await ctPage.waitForTimeout(250);
      navLabels = await labels(ctPage);
    }

    const out = {
      _comment: [
        "PLAT-59 — the desktop's Visual Replay panes on the gl_scene recording, read from the real Electron app.",
        "Produced by src/tests/gui/tests/frame-viewer/plat59-visual-replay-capture.spec.ts",
        "(`just plat59-capture-electron`).",
      ],
      frames,
      draw,
      history: { pixel: { x: px, y: py, frame: 59 }, header: history.header, entries: history.entries },
      shader,
      navigation: { clickedDraw: lastDraw, drawLabel: navLabels.draw },
      pageErrors,
    };
    fs.mkdirSync(path.dirname(answersFile), { recursive: true });
    fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");

    expect(frames.map((f) => f.frame)).toEqual([0, 30, 59]);
    // The image is the PROGRAM's: every quad its colour at that frame, the
    // image's top row first.
    for (const f of frames) {
      expect(f.quadColours).toEqual([0, 1, 2, 3].map((q) => quadColour(f.frame, q)));
    }
    expect(history.entries.length).toBeGreaterThan(0);
    // The pixel (40, 50) of frame 59 is in quad 2 (the image's top-left):
    // the last draw call that wrote it is that quad's.
    expect(history.entries[history.entries.length - 1].drawCallIndex).toBe(59 * 4 + 2);
  });
});
