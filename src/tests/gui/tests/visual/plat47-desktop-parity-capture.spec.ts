/**
 * plat47-desktop-parity-capture.spec.ts — PLAT-47's desktop column: what the
 * REAL Electron front-end shows on the `calc` recording, for every property
 * the terminal and GPUI front-ends must now EQUAL.
 *
 *   * `layout`   — the first-run arrangement (no user layout, so the index
 *                  process installs the DEBUG mode's default), as every
 *                  stack's DOM rectangle with its tabs' `Content` ordinals;
 *   * `editor`   — the editor's colours as the eye sees them: the ground
 *                  behind the (transparent) Monaco surface, each syntax
 *                  class's computed colour, the resting and active line
 *                  numbers (colour composited with their opacity over the
 *                  ground), the execution line's band and the selection's,
 *                  read off the window's own pixels where layers composite;
 *   * `focus`    — the focused (selected) panel's outline colour and the
 *                  colour an unfocused panel's edge shows, after a click;
 *   * `files`    — the Files pane's entries, in order;
 *   * `calltrace`— the calltrace pane's `.call-text` entries at the stop.
 *
 * Written to `src/tests/visual/answers/plat47-desktop-parity.electron.json`.
 * The terminal's suites (`tests/real_terminal/test_plat47_*.nim`) read it and
 * compare the terminal's read-back cells with it; they FAIL BY NAME when the
 * file is absent, naming `just plat47-capture-electron`.
 *
 * The recording is the terminal lanes' own `calc` fixture
 * (`test-logs/tui-fixtures/calc-*`, `launchMode: trace-folder`), so both
 * front-ends read the same recording at the same stop.
 *
 * No mocks: a real `.ct` recording, the real `ct` binary, a real
 * `replay-server`, the real Electron app. The prefix (this checkout's desktop
 * JavaScript) comes from `scripts/plat45-desktop-prefix.sh` via
 * `PLAT47_DESKTOP_PREFIX`; without it the build's own prefix runs.
 */

import * as fs from "fs";
import * as path from "path";

import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat47-desktop-parity.electron.json");
const answersLightFile = path.join(answersDir, "plat47-desktop-parity-light.electron.json");

function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith("calc-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      "PLAT-47: the 'calc' recording is not in test-logs/tui-fixtures/; run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

test.use({
  sourcePath: recording(),
  launchMode: "trace-folder",
  noUserLayout: true,
  codetracerPrefixOverride: process.env.PLAT47_DESKTOP_PREFIX ?? "",
});
test.setTimeout(300_000);

/** `#rrggbb` of a PNG pixel read by the page itself (no image library). */
async function pixelAt(
  page: import("playwright").Page,
  png: Buffer,
  x: number,
  y: number,
): Promise<string> {
  return page.evaluate(
    async ({ b64, x, y }) => {
      const img = new Image();
      img.src = "data:image/png;base64," + b64;
      await img.decode();
      const c = document.createElement("canvas");
      c.width = img.width;
      c.height = img.height;
      const ctx = c.getContext("2d")!;
      ctx.drawImage(img, 0, 0);
      const d = ctx.getImageData(Math.round(x), Math.round(y), 1, 1).data;
      return "#" + [d[0], d[1], d[2]].map((v) => v.toString(16).padStart(2, "0")).join("");
    },
    { b64: png.toString("base64"), x, y },
  );
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function captureParity(ctPage: import("playwright").Page, theme: "dark" | "light"): Promise<any> {
  await ctPage.waitForSelector(".view-line", { timeout: 90_000 });
  await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 90_000 });
  await ctPage.waitForTimeout(3_000);

  // ---- layout, files, calltrace, and the editor's computed colours --------
  const dom = await ctPage.evaluate(() => {
    const hex = (css: string): string => {
      const m = css.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)(?:[ ,/]+([\d.]+))?/);
      if (!m) return "";
      return "#" + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, "0")).join("");
    };
    const rgb = (css: string): [number, number, number, number] => {
      const m = css.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)(?:[ ,/]+([\d.]+))?/);
      if (!m) return [0, 0, 0, 0];
      return [Number(m[1]), Number(m[2]), Number(m[3]), m[4] === undefined ? 1 : Number(m[4])];
    };
    const effectiveBg = (el: Element | null): string => {
      let e: Element | null = el;
      while (e) {
        const c = rgb(getComputedStyle(e).backgroundColor);
        if (c[3] > 0) return hex(getComputedStyle(e).backgroundColor);
        e = e.parentElement;
      }
      return "";
    };
    // A text colour composited with its own and its ancestors' opacity over
    // the ground — what the eye sees for a dimmed glyph.
    const effectiveFg = (el: Element, ground: string): string => {
      const c = rgb(getComputedStyle(el).color);
      let alpha = c[3];
      let e: Element | null = el;
      while (e && !e.classList.contains("monaco-editor")) {
        alpha *= Number(getComputedStyle(e).opacity);
        e = e.parentElement;
      }
      const g = [1, 3, 5].map((i) => parseInt(ground.slice(i, i + 2), 16));
      const out = [0, 1, 2].map((i) => Math.round(c[i] * alpha + g[i] * (1 - alpha)));
      return "#" + out.map((v) => v.toString(16).padStart(2, "0")).join("");
    };

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const w = window as any;
    const gl = w.data?.ui?.layout;
    const stacks: unknown[] = [];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const walk = (item: any) => {
      if (!item) return;
      if (item.type === "stack") {
        const rect = item.element.getBoundingClientRect();
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const contents = item.contentItems.map((c: any) => {
          const cfg = c.toConfig ? c.toConfig() : {};
          const state = cfg.componentState ?? c.container?.state ?? {};
          return typeof state.content === "number" ? state.content : -1;
        });
        const active = item.getActiveComponentItem
          ? item.contentItems.indexOf(item.getActiveComponentItem())
          : 0;
        const titles = Array.from(item.element.querySelectorAll(".lm_tab .lm_title"))
          .map((t) => ((t as Element).textContent ?? "").trim());
        stacks.push({ x: rect.x, y: rect.y, w: rect.width, h: rect.height, contents, active, titles });
        return;
      }
      for (const c of item.contentItems ?? []) walk(c);
    };
    if (gl) walk(gl.rootItem);

    const ground = effectiveBg(document.querySelector(".monaco-editor .view-line"));
    const spans = Array.from(document.querySelectorAll(".monaco-editor .view-line span span"));
    const colourOf = (pred: (t: string, s: Element) => boolean): string => {
      const s = spans.find((e) => pred((e.textContent ?? "").trim(), e));
      return s ? hex(getComputedStyle(s).color) : "";
    };
    const editor = {
      background: ground,
      keyword: colourOf((t) => t === "def" || t === "return" || t === "import"),
      string: colourOf((t) => t.startsWith("\"") || t.startsWith("'")),
      comment: colourOf((t) => t.startsWith("#")),
      number: colourOf((t) => /^[0-9]+$/.test(t)),
      identifier: colourOf((t) => /^[a-z_][a-z_0-9]*$/.test(t) && !["def", "return", "import", "for", "in", "while", "if"].includes(t)),
      delimiter: colourOf((t) => t === "," || t === ":"),
      lineNumber: "",
      activeLineNumber: "",
    };
    const resting = Array.from(document.querySelectorAll(".line-numbers:not(.active-line-number) .gutter-line"));
    if (resting.length > 0) editor.lineNumber = effectiveFg(resting[0], ground);
    const active = document.querySelector(".line-numbers.active-line-number .gutter-line");
    if (active) editor.activeLineNumber = effectiveFg(active, ground);

    // The execution line and a point on it past the text, for the pixel read.
    const on = document.querySelector(".view-overlays .on");
    const onRect = on ? on.getBoundingClientRect() : null;
    const lines = document.querySelector(".monaco-editor .view-lines");
    const linesRect = lines ? lines.getBoundingClientRect() : null;

    // The Files pane's entries, in order.
    const fsRoot = document.querySelector("[id^='filesystemComponent']");
    const files = fsRoot
      ? Array.from(fsRoot.querySelectorAll(".jstree-anchor, .filesystem-entry-text, .fs-entry-name, [class*='entry'] > span"))
          .map((e) => (e.textContent ?? "").trim()).filter((t) => t.length > 0)
      : [];
    const filesText = fsRoot ? ((fsRoot as HTMLElement).innerText ?? "") : "";

    const calltrace = Array.from(document.querySelectorAll(".calltrace-view .call-text"))
      .map((e) => (e.textContent ?? "").trim());

    return {
      stacks, editor, files, filesText, calltrace,
      onRect: onRect ? { x: onRect.x, y: onRect.y, w: onRect.width, h: onRect.height } : null,
      linesRect: linesRect ? { x: linesRect.x, y: linesRect.y, w: linesRect.width, h: linesRect.height } : null,
      viewport: { w: window.innerWidth, h: window.innerHeight },
      ticks: w.data?.services?.debugger?.location?.rrTicks ?? -1,
    };
  });

  // ---- the execution line's band, off the window's pixels -----------------
  // The execution line's band, read off the window's pixels with the editor
  // NOT focused: the band the desktop draws for the stop is the `.on`
  // decoration, and a focused Monaco lays its own cursor-line highlight over
  // whatever line the caret is on, which is a different fact. The point is
  // near the editor's right edge, past the end of the short first line.
  await ctPage.locator(".calltrace-view").first().click({ position: { x: 40, y: 200 } });
  await ctPage.waitForTimeout(500);
  const box = await ctPage.evaluate(() => {
    const ed = Array.from(document.querySelectorAll(".lm_stack"))
      .find((s) => s.querySelector(".monaco-editor .view-line"));
    const r = ed ? ed.getBoundingClientRect() : null;
    const lines = document.querySelector(".monaco-editor .view-lines");
    const lr = lines ? lines.getBoundingClientRect() : null;
    return r && lr ? { right: r.x + r.width, linesX: lr.x } : null;
  });
  const shot = await ctPage.screenshot();
  let executionLine = "";
  if (dom.onRect && box) {
    executionLine = await pixelAt(ctPage, shot, box.right - 30,
                                  dom.onRect.y + dom.onRect.h / 2);
  }

  // ---- the selection's band ----------------------------------------------
  // Lines 2..4 selected through the editor's own Monaco instance, the editor
  // focused (an unfocused selection is Monaco's inactive colour), and the
  // band read on line 3, which is empty — so the pixel is the band alone.
  const selY = await ctPage.evaluate(() => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const w = window as any;
    const eds = w.data?.ui?.editors ?? {};
    for (const k of Object.keys(eds)) {
      const m = eds[k]?.monacoEditor;
      if (!m || !m.getModel || !m.getModel()) continue;
      m.setSelection({ startLineNumber: 2, startColumn: 1, endLineNumber: 4, endColumn: 1 });
      m.focus();
      const top = m.getTopForLineNumber(3) - m.getScrollTop();
      return m.getDomNode().getBoundingClientRect().y + top + 4;
    }
    return -1;
  });
  let selection = "";
  if (selY >= 0 && box) {
    await ctPage.waitForTimeout(500);
    const shot2 = await ctPage.screenshot();
    selection = await pixelAt(ctPage, shot2, box.linesX + 2, selY);
  }

  // ---- focus: click the calltrace panel, read the outline ----------------
  await ctPage.locator(".calltrace-view").first().click({ position: { x: 40, y: 200 } });
  await ctPage.waitForTimeout(800);
  const focus = await ctPage.evaluate(() => {
    const hex = (css: string): string => {
      const m = css.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)/);
      if (!m) return "";
      return "#" + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, "0")).join("");
    };
    const paths = Array.from(document.querySelectorAll(".ct-selected-outline path"));
    const splitter = document.querySelector(".lm_splitter");
    const panel = document.querySelector(".lm_content");
    return {
      outlineCount: paths.length,
      outline: paths.length > 0 ? hex(getComputedStyle(paths[0]).stroke) : "",
      outlineWidth: paths.length > 0 ? getComputedStyle(paths[0]).strokeWidth : "",
      // What an UNFOCUSED panel's edge shows: no outline, so the splitter
      // between panels on one side and the panel's own surface on the other.
      unfocusedEdge: splitter ? hex(getComputedStyle(splitter).backgroundColor) : "",
      panel: panel ? hex(getComputedStyle(panel).backgroundColor) : "",
    };
  });

  // ---- Monaco's own tokenization of the whole file ------------------------
  // Every token Monaco's tokenizer gives the open file, as (start column,
  // scope) per line — `monaco.editor.tokenize` over the editor model's text in
  // the model's language, the tokenizer the desktop colours with. The
  // terminal's parity suite classifies the same file with its own highlighter
  // and compares the two COLOUR BY COLOUR through the theme (a class and a
  // scope that resolve to one rule are one colour), so this is recorded as
  // scopes, not as colours.
  const monacoTokens = await ctPage.evaluate(() => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const w = window as any;
    const m = w.monaco;
    const eds = w.data?.ui?.editors ?? {};
    for (const k of Object.keys(eds)) {
      const ed = eds[k]?.monacoEditor;
      const model = ed && ed.getModel ? ed.getModel() : null;
      if (!model || !m?.editor?.tokenize) continue;
      const language = model.getLanguageId ? model.getLanguageId() : model.getModeId();
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const lines = m.editor.tokenize(model.getValue(), language).map((line: any[]) =>
        line.map((t) => [t.offset, t.type]));
      // The editor is keyed by the file it shows; the model's own uri is an
      // in-memory id.
      return { path: k.split(/[\\/]/).slice(-2).join("/"), language, lines };
    }
    return null;
  });

  return {
    takenAt: new Date().toISOString(),
    theme,
    monacoTokens,
    recording: path.basename(recording()),
    ...dom,
    editor: { ...dom.editor, executionLine, selection },
    focus,
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function writeAnswers(file: string, answers: any): void {
  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(file,
    JSON.stringify(answers, null, 2).split(repoRoot).join("<repo>") + "\n");
}

test("PLAT-47: the desktop's editor, focus, files, calltrace and first-run layout", async ({ ctPage }) => {
  writeAnswers(answersFile, await captureParity(ctPage, "dark"));
  await ctPage.screenshot({ path: path.join(repoRoot, "test-logs", "plat47-desktop-parity.png") });
});

// THE LIGHT THEME, MEASURED rather than composed. The desktop is launched with
// its own configuration naming `default_white` (the `configTheme` fixture
// option rewrites the launch's `.config.yaml`), so the renderer selects the
// light stylesheet and Monaco's `codetracerWhite` through the path a user's
// config takes. The same reads as the dark test; the terminal's generated
// light editor tokens are asserted equal to this file
// (`tests/test_plat47_editor_theme.nim`).
test.describe("the light theme", () => {
  test.use({ configTheme: "default_white" });
  test("PLAT-47: the desktop's editor in its light theme", async ({ ctPage }) => {
    const answers = await captureParity(ctPage, "light");
    // The launch really is light: Monaco names the theme it applied on the
    // editor's own DOM node, and a dark launch would make every value below a
    // second copy of the dark capture.
    const monacoTheme = await ctPage.evaluate(() => {
      const el = document.querySelector(".monaco-editor");
      return el ? Array.from(el.classList).join(" ") : "";
    });
    answers.monacoClasses = monacoTheme;
    if (!/\bvs\b/.test(monacoTheme) || /\bvs-dark\b/.test(monacoTheme)) {
      throw new Error(`PLAT-47: the light launch's Monaco editor is not light: '${monacoTheme}'`);
    }
    writeAnswers(answersLightFile, answers);
    await ctPage.screenshot({ path: path.join(repoRoot, "test-logs", "plat47-desktop-parity-light.png") });
  });
});
