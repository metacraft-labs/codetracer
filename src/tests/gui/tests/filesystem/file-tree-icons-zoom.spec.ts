/** Real recordings and the shipped Electron renderer/CSS, without mocks.
 * The headless FilesystemVM counterpart is filesystem_vm_test.nim. Geometry
 * alone misses replaced content overflowing a correctly sized pseudo-element:
 * compare screenshots with each icon visible/hidden to measure its PAINT.
 */
import { test, expect, testProgramsPath } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { writeFileSync, mkdirSync, cpSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { Page, Locator } from "@playwright/test";

test.setTimeout(0);

async function paintedBounds(page: Page, icon: Locator) {
  // Visibility does not alter layout. Isolate the target's paint so blinking
  // cursors or async updates elsewhere cannot enlarge the measured bounds.
  await icon.evaluate(el => el.classList.add("file-tree-paint-probe"));
  let before: Buffer, after: Buffer;
  const hidden = "body * { visibility: hidden !important; }";
  try {
    before = await page.screenshot({ animations: "disabled", scale: "css",
      style: hidden + ".file-tree-paint-probe, .file-tree-paint-probe::before { visibility: visible !important; }" });
    after = await page.screenshot({ animations: "disabled", scale: "css", style: hidden });
  } finally {
    await icon.evaluate(el => el.classList.remove("file-tree-paint-probe"));
  }
  return page.evaluate(async ([visible, hidden]) => {
    async function pixels(encoded: string) {
      const image = new Image();
      image.src = `data:image/png;base64,${encoded}`;
      await image.decode();
      const canvas = document.createElement("canvas");
      canvas.width = image.width; canvas.height = image.height;
      const ctx = canvas.getContext("2d")!;
      ctx.drawImage(image, 0, 0);
      return { data: ctx.getImageData(0, 0, image.width, image.height).data,
        width: image.width, height: image.height };
    }
    const a = await pixels(visible), b = await pixels(hidden);
    let left = a.width, top = a.height, right = -1, bottom = -1;
    for (let y = 0; y < a.height; y++) for (let x = 0; x < a.width; x++) {
      const offset = (y * a.width + x) * 4;
      if ([0, 1, 2].some(c => Math.abs(a.data[offset+c] - b.data[offset+c]) > 20)) {
        left = Math.min(left, x); right = Math.max(right, x);
        top = Math.min(top, y); bottom = Math.max(bottom, y);
      }
    }
    const scaleX = a.width / innerWidth, scaleY = a.height / innerHeight;
    return { left: left / scaleX, top: top / scaleY,
      width: (right-left+1) / scaleX, height: (bottom-top+1) / scaleY,
      scaleX, scaleY, pngWidth: a.width, pngHeight: a.height,
      viewportWidth: innerWidth, viewportHeight: innerHeight };
  }, [before!.toString("base64"), after!.toString("base64")]);
}

const liveFolder = join(tmpdir(), `ct-file-icons-zoom-${process.pid}`);

for (const fixture of [
  { name: "Noir", source: "noir_example/", selector: ".jstree-anchor:has-text(\"main.nr\") > .jstree-themeicon" },
  { name: "lazy Noir", source: "", selector: ".custom-noir-icon" },
  { name: "Octicons fallback", source: "", selector: ".book-icon" },
  { name: "Mfizz fallback", source: "", selector: ".c-icon" },
  { name: "Devicons fallback", source: "", selector: ".rust-icon" },
  { name: "folders", source: "multi_root/app/main.py", selector: ".jstree-themeicon:not(.jstree-themeicon-custom):not(.jstree-file)" },
]) {
  test.describe(fixture.name, () => {
    test.use(fixture.source === ""
      ? { editFolderPath: liveFolder, launchMode: "edit" }
      : { sourcePath: `${testProgramsPath}/${fixture.source}`, launchMode: "trace" });
    if (fixture.source === "") {
      test.beforeAll(() => {
        // A real source file two stubs below the opened folder: the loader
        // lists one level per load, so `project` and then `src` each arrive
        // as a "Loading..." stub. Expanding them invokes update-path-content
        // and its normal icon map.
        mkdirSync(join(liveFolder, "project", "src"), { recursive: true });
        cpSync(join(testProgramsPath, "noir_example", "src", "main.nr"),
          join(liveFolder, "project", "src", "main.nr"));
        writeFileSync(join(liveFolder, "README.md"), "# Zoom fixture\n");
        writeFileSync(join(liveFolder, "main.c"), "int main(void) { return 0; }\n");
        writeFileSync(join(liveFolder, "main.rs"), "fn main() {}\n");
      });
      test.afterAll(() => rmSync(liveFolder, { recursive: true, force: true }));
    }
    test("Files icons keep their painted proportions at both zoom limits", async ({ ctPage }, testInfo) => {
      const layout = new LayoutPage(ctPage);
      await layout.waitForFilesystemLoaded();
      const filesystem = (await layout.filesystemTabs(true))[0];
      expect(filesystem, "Files pane exists").toBeTruthy();
      await filesystem.clickTab();
      await filesystem.waitForReady();
      const tree = ctPage.locator(".session-container:not(.hidden) .filesystem:visible").first();
      // Readiness is the Files pane's real loaded tree, independent of which
      // optional status-bar fields this layout chooses to show.
      await expect(tree.locator(".jstree-anchor").first()).toBeVisible();
      if (fixture.name === "Noir")
        await filesystem.nodeByPath("source folders", "src", "main.nr");
      if (fixture.name === "lazy Noir") {
        const project = tree.locator(".jstree-anchor").filter({ hasText: /^project$/ });
        await expect(project).toBeVisible();
        await project.locator("..").locator(":scope > .jstree-ocl").click();
        const src = tree.locator(".jstree-anchor").filter({ hasText: /^src$/ });
        await expect(src).toBeVisible();
        await src.locator("..").locator(":scope > .jstree-ocl").click();
      }
      const icon = tree.locator(fixture.selector).first();
      await expect(icon).toBeVisible();
      const measurements: { font: number; width: number; height: number }[] = [];
      for (const font of [6, 40]) {
        // Use the real desktop zoom actions; extra presses verify clamping too.
        const currentFont = await ctPage.evaluate(() => parseFloat(getComputedStyle(document.documentElement).fontSize));
        const steps = Math.ceil(Math.abs(font - currentFont) / 2) + 1;
        for (let step = 0; step < steps; step++)
          await ctPage.keyboard.press(font === 6 ? "Control+Minus" : "Control+Equal");
        await expect.poll(() => ctPage.evaluate(() => parseFloat(getComputedStyle(document.documentElement).fontSize))).toBe(font);
        await icon.scrollIntoViewIfNeeded();
        await ctPage.mouse.move(0, 0);
        const box = await icon.boundingBox();
        expect(box).not.toBeNull();
        const line = await icon.locator("..").boundingBox();
        expect(line).not.toBeNull();
        const rowMetrics = await tree.locator(".jstree-anchor:visible > .jstree-themeicon").evaluateAll(icons => icons.map(icon => {
          const i = icon.getBoundingClientRect(), row = icon.parentElement!.getBoundingClientRect();
          return { label: icon.parentElement!.textContent, width: i.width, height: i.height,
            rowHeight: row.height, dy: Math.abs(i.y + i.height / 2 - row.y - row.height / 2) };
        }));
        expect(rowMetrics.length, "real trace renders file/folder rows").toBeGreaterThan(0);
        for (const row of rowMetrics) {
          expect(row.width, row.label ?? "icon width").toBeLessThanOrEqual(row.rowHeight + 1);
          expect(row.height, row.label ?? "icon height").toBeLessThanOrEqual(row.rowHeight + 1);
          expect(row.dy, row.label ?? "icon centre").toBeLessThanOrEqual(1);
        }
        const styles = await icon.evaluate(el => {
          const icon = getComputedStyle(el), before = getComputedStyle(el, "::before");
          return { classes: el.className, fontSize: icon.fontSize, beforeFontSize: before.fontSize,
            beforeLineHeight: before.lineHeight, beforeFontFamily: before.fontFamily,
            beforeTop: before.top, background: icon.backgroundImage,
            backgroundSize: icon.backgroundSize, content: before.content,
            beforeBackground: before.backgroundImage, beforeSize: before.backgroundSize };
        });
        const paint = await paintedBounds(ctPage, icon);
        await tree.screenshot({ path: testInfo.outputPath(`${fixture.name}-${font}px.png`), scale: "css" });
        await testInfo.attach(`${fixture.name}-${font}px.png`, { path: testInfo.outputPath(`${fixture.name}-${font}px.png`), contentType: "image/png" });
        const metricsPath = testInfo.outputPath(`${fixture.name}-${font}px.json`);
        writeFileSync(metricsPath, JSON.stringify({ box, line, paint, styles, rowMetrics }, null, 2));
        await testInfo.attach(`${fixture.name}-${font}px.json`, { path: metricsPath, contentType: "application/json" });
        expect(Math.abs(paint.scaleX - paint.scaleY), "capture maps uniformly to CSS pixels").toBeLessThan(0.01);
        expect(paint.width, "icon actually paints pixels").toBeGreaterThan(0);
        expect(paint.height).toBeGreaterThan(0);
        expect(paint.width, "paint fits its icon box").toBeLessThanOrEqual(box!.width + 1);
        expect(paint.height, "paint fits the row").toBeLessThanOrEqual(line!.height + 1);
        // Glyph bearings and raster hinting need not make the ink symmetric.
        // The slot is centred above; its paint must not escape into other rows
        // or the filename, including a small glyph shifted outside its slot.
        expect(paint.left, "paint stays inside the icon slot's left edge").toBeGreaterThanOrEqual(box!.x - 1);
        expect(paint.left + paint.width, "paint stays inside the icon slot's right edge").toBeLessThanOrEqual(box!.x + box!.width + 1);
        expect(paint.top, "paint stays below the row's top edge").toBeGreaterThanOrEqual(line!.y - 1);
        expect(paint.top + paint.height, "paint stays above the row's bottom edge").toBeLessThanOrEqual(line!.y + line!.height + 1);
        measurements.push({ font, width: paint.width, height: paint.height });
      }
      for (const dimension of ["width", "height"] as const)
        expect(Math.abs(measurements[1][dimension] - measurements[0][dimension] * 40 / 6), `${dimension} scales with the root font (raster rounding allowed)`)
          .toBeLessThanOrEqual(8);
    });
  });
}
