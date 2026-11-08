/**
 * The desktop's half of MC-D1 and MC-D3 (Editor-Pane.md): the real Monaco in the
 * real app, real mouse events, over the milestone's fixture document. Writes
 * `src/tests/visual/answers/plat70g-mc.electron.json`, which
 * `tui/tests/test_plat70g_differential.nim` compares the shared model to.
 *
 * Run by hand when Monaco moves: PLAT70G_CAPTURE=1 npx playwright test <this file>.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { expect, test } from "../../lib/fixtures";
import { originFixturePath } from "../../lib/value-origin-fixtures";

test.use({ sourcePath: originFixturePath("python", "simple_trivial_chain"), launchMode: "trace" });
test.setTimeout(600_000);

const Fixture =
  "snake_case_name = other.attr(x)\n    leading indentation\na == b and p->q\na.b\n\nprice λx 3€ end\nlast line no terminator";
const Positions: [number, number][] = [
  [1, 3], [1, 16], [1, 17], [1, 21], [1, 24], [2, 3], [2, 10], [3, 4], [3, 13], [4, 2], [4, 3], [5, 1], [6, 8], [6, 11], [7, 24],
];
const Rows = ["none", "shift", "alt", "shift+alt"] as const;

test("capture", async ({ ctPage: page }) => {
  test.skip(!process.env.PLAT70G_CAPTURE, "capturing is by hand");
  await page.waitForSelector(".monaco-editor .view-line", { timeout: 120_000 });
  await page.evaluate((text) => {
    const w = globalThis as any;
    const host = document.createElement("div");
    host.style.cssText = "position:fixed;left:50px;top:50px;width:1200px;height:500px;z-index:99999;background:#222";
    document.body.appendChild(host);
    w.__mc = w.monaco.editor.create(host, { value: text, readOnly: true, glyphMargin: true, fontSize: 14,
      minimap: { enabled: false }, contextmenu: false, automaticLayout: false, folding: false });
    w.__mcTarget = 0;
    w.__mc.onMouseDown((e: any) => { w.__mcTarget = e.target.type; });
  }, Fixture);
  await page.waitForTimeout(800);
  const pos = (l: number, c: number) => page.evaluate(({ l, c }) => {
    const w = globalThis as any;
    const box = w.__mc.getDomNode().getBoundingClientRect();
    const v = w.__mc.getScrolledVisiblePosition({ lineNumber: l, column: c });
    return { x: box.left + v.left, y: box.top + v.top + v.height / 2 };
  }, { l, c });
  const read = () => page.evaluate(() => {
    const w = globalThis as any;
    return w.__mc.getSelections().map((s: any) => w.__mc.getModel().getValueInRange(s) as string);
  });
  const presses: unknown[] = [];
  for (const [l, c] of Positions) {
    for (const row of Rows) {
      for (let count = 1; count <= 4; count++) {
        await page.evaluate(() => {
          const w = globalThis as any;
          w.__mc.setPosition({ lineNumber: 1, column: 1 });
          w.__mc.focus();
        });
        await page.waitForTimeout(450);
        const p = await pos(l, c);
        if (row.includes("shift")) await page.keyboard.down("Shift");
        if (row.includes("alt")) await page.keyboard.down("Alt");
        await page.mouse.click(p.x, p.y, { clickCount: count });
        if (row.includes("alt")) await page.keyboard.up("Alt");
        if (row.includes("shift")) await page.keyboard.up("Shift");
        presses.push({ line: l, column: c, mods: row, count, selections: await read() });
      }
    }
  }
  const layout = await page.evaluate(() => (globalThis as any).__mc.getLayoutInfo());
  const samples = async (left: number, width: number) => {
    const out: number[] = [];
    for (const dx of [3, Math.floor(width / 2), width - 1]) {
      const box = await page.evaluate(() => (globalThis as any).__mc.getDomNode().getBoundingClientRect().toJSON());
      const y = box.top + 30;
      await page.waitForTimeout(450);
      await page.mouse.click(box.left + left + dx, y);
      out.push(await page.evaluate(() => (globalThis as any).__mcTarget as number));
    }
    return out;
  };
  const gutter = {
    glyph: await samples(layout.glyphMarginLeft, layout.glyphMarginWidth),
    lineNumber: await samples(layout.lineNumbersLeft, layout.lineNumbersWidth),
    decorations: await samples(layout.decorationsLeft, layout.decorationsWidth),
    glyphWidth: layout.glyphMarginWidth,
  };
  const out = path.resolve(__dirname, "../../../visual/answers/plat70g-mc.electron.json");
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify({ fixture: Fixture, presses, gutter }, null, 1) + "\n");
  expect(presses.length).toBe(Positions.length * Rows.length * 4);
});
