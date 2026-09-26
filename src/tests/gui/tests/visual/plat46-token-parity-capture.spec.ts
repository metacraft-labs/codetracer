/**
 * plat46-token-parity-capture.spec.ts — PLAT-46's desktop parity column: the
 * COMPUTED CSS colour the Electron front-end paints each shared role with.
 *
 * PLAT-46 paints the terminal front-end from `codetracer-design-system`, and
 * the desktop's stylus is generated from the same pinned revision by the same
 * resolver (`scripts/tokens-to-styl.sh`). This spec reads, from a RUN of the
 * real Electron app on the `calc` recording, the colour the browser actually
 * resolved for each role both front-ends paint — pane text, tab labels, tab
 * and pane surfaces, the editor's surface and its syntax colours — and writes
 * them as `#rrggbb` to `src/tests/visual/answers/plat46-token-parity.electron.json`.
 *
 * `src/frontend/tui/tests/real_terminal/test_plat46_desktop_parity.nim` reads
 * that file and compares each role with the TUI's read-back hex. It FAILS BY
 * NAME when the file is absent, naming `just plat46-capture-electron`.
 *
 * No mocks: a real `.ct` recording, the real `ct` binary, a real
 * `replay-server`, the real Electron app.
 */

import * as fs from "fs";
import * as path from "path";

import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");

function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith("calc-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      "PLAT-46: the 'calc' recording is not in test-logs/tui-fixtures/; run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

test.use({ sourcePath: recording(), launchMode: "trace-folder" });
test.setTimeout(300_000);

test("the desktop's computed colour for every role both front-ends paint", async ({ ctPage }) => {
  await ctPage.waitForSelector(".view-line", { timeout: 90_000 });
  await ctPage.waitForTimeout(2_000);

  const colours = await ctPage.evaluate(() => {
    // `rgb(r, g, b)` / `rgba(r, g, b, a)` -> `#rrggbb` (the alpha is reported
    // separately; a translucent colour is not a token's value).
    const hex = (css: string): string => {
      const m = css.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)(?:[ ,/]+([\d.]+))?/);
      if (!m) return "";
      if (m[4] !== undefined && Number(m[4]) === 0) return "transparent";
      return "#" + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, "0")).join("");
    };
    const style = (el: Element | null) => (el ? getComputedStyle(el) : null);
    // The first element whose OWN background is opaque, walking up — what
    // the eye sees behind `el`.
    const effectiveBg = (el: Element | null): string => {
      let e: Element | null = el;
      while (e) {
        const bg = hex(getComputedStyle(e).backgroundColor);
        if (bg && bg !== "transparent") return bg;
        e = e.parentElement;
      }
      return "";
    };
    const out: Record<string, string> = {};
    const q = (sel: string) => document.querySelector(sel);

    // Tabs: the active tab is lifted onto the panel; an inactive one sits on
    // the layout's own surface.
    const active = q(".lm_header .lm_tab.lm_active");
    const inactive = q(".lm_header .lm_tab:not(.lm_active)");
    out["tab-active-bg"] = effectiveBg(active);
    out["tab-inactive-bg"] = effectiveBg(inactive);
    out["tab-active-fg"] = hex(style(active?.querySelector(".lm_title") ?? null)?.color ?? "");
    out["tab-inactive-fg"] = hex(style(inactive?.querySelector(".lm_title") ?? null)?.color ?? "");
    out["surface-canvas"] = effectiveBg(q(".lm_goldenlayout"));
    out["surface-panel"] = effectiveBg(q(".lm_content"));
    // The editor.
    const editorLine = q(".monaco-editor .view-line");
    out["surface-editor"] = effectiveBg(editorLine);
    const spans = Array.from(document.querySelectorAll(".monaco-editor .view-line span span"));
    const keyword = spans.find((s) => (s.textContent ?? "").trim() === "def");
    out["syntax-keyword"] = keyword ? hex(getComputedStyle(keyword).color) : "";
    const plain = spans.find((s) => /^[a-z_]+$/.test((s.textContent ?? "").trim()) &&
      (s.textContent ?? "").trim() !== "def");
    out["syntax-identifier"] = plain ? hex(getComputedStyle(plain).color) : "";
    // Pane text and a pane border.
    out["chrome-text"] = hex(style(q(".lm_content"))?.color ?? "");
    return out;
  });

  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(
    path.join(answersDir, "plat46-token-parity.electron.json"),
    JSON.stringify({ takenAt: new Date().toISOString(), theme: "dark", colours }, null, 2) + "\n",
  );
});
