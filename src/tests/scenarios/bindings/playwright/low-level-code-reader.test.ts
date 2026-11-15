// The desktop binding's Low Level Code reader on a listing of thousands of
// rows: it reads what is on screen (and the marked and executing rows), not
// every row, and one read stays well inside a scenario's poll interval.
//
// A Nim recording's generated C listing has thousands of rows. Reading each
// one (rect, computed style, text) on every poll made a single observation
// take over ten minutes on a loaded host (codetracer-pm issue 2026-11-15 "A
// step replaces the generated C listing with the disassembly", whose gate
// scenario could not reach its last step). The page here is the pane's DOM as
// `low_level_code` renders it, in a real Chromium, read by the binding's own
// `readSurfacePw4`.
//
// Run: node src/tests/scenarios/bindings/playwright/low-level-code-reader.test.ts
// (inside the dev shell, which links node_modules/playwright).

import { createRequire } from "node:module";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { readSurfacePw4 } from "./codetracer-binding.ts";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../../../../..");
const require = createRequire(import.meta.url);
const { chromium } = require(path.join(REPO, "node_modules/playwright"));

const ROWS = 5000;
const MARKED = 3700;
const ROW_PX = 20;
const PANE_PX = 600;
const READ_BUDGET_MS = 1000;

let failures = 0;
const check = (ok: boolean, what: string) => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${what}`);
  if (!ok) failures++;
};

const page_html = `<!doctype html><html><body style="margin:0">
<div class="low-level-code" style="height:${PANE_PX}px;width:800px;overflow:auto">
  <div class="low-level-code-instructions" id="rows"></div>
</div>
<script>
  const rows = document.getElementById("rows");
  const frag = document.createDocumentFragment();
  for (let i = 0; i < ${ROWS}; i++) {
    const row = document.createElement("div");
    row.className = "low-level-code-instruction" + (i === ${MARKED} ? " active-instruction" : "");
    row.style.height = "${ROW_PX}px";
    row.innerHTML = '<span class="low-level-code-instruction-offset">' + i +
      '</span><span class="low-level-code-instruction-name">nimln_(' + i + ');</span>' +
      '<span class="low-level-code-instruction-source"></span>';
    frag.appendChild(row);
  }
  rows.appendChild(frag);
  // The pane reveals its marked row (generated_code.revealActiveGeneratedRow).
  document.querySelector(".low-level-code").scrollTop = ${MARKED * ROW_PX} - ${PANE_PX / 2};
</script></body></html>`;

const browser = await chromium.launch({
  executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined,
});
try {
  const page = await browser.newPage();
  await page.setContent(page_html);
  const result = await page.evaluate(
    `(() => { const root = { role: "window", children: [] };
       const t0 = performance.now();
       (${readSurfacePw4.toString()})(root);
       const ms = performance.now() - t0;
       const llc = root.children.find((c) => c.role === "low-level-code");
       return { ms, count: llc?.props.count, read: llc?.children.length ?? -1,
                active: (llc?.children ?? []).filter((c) => c.props.active).map((c) => c.props.name) };
     })()`) as { ms: number; count: number; read: number; active: string[] };

  console.log(`low-level-code reader over ${ROWS} rows: read ${result.read} in ${result.ms.toFixed(1)} ms`);
  check(result.count === ROWS, `count is every instruction (${result.count})`);
  check(result.read > 0 && result.read <= 3 * (PANE_PX / ROW_PX) + 10,
        `only the rows within a screen of the viewport are read (${result.read})`);
  check(result.active.length === 1 && result.active[0] === `nimln_(${MARKED});`,
        `the marked row is read (${JSON.stringify(result.active)})`);
  check(result.ms < READ_BUDGET_MS, `one read takes under ${READ_BUDGET_MS} ms (${result.ms.toFixed(1)})`);

  // The marked row is read even when the pane is scrolled away from it.
  await page.evaluate(`document.querySelector(".low-level-code").scrollTop = 0`);
  const away = await page.evaluate(
    `(() => { const root = { role: "window", children: [] };
       (${readSurfacePw4.toString()})(root);
       const llc = root.children.find((c) => c.role === "low-level-code");
       return (llc?.children ?? []).filter((c) => c.props.active).length; })()`) as number;
  check(away === 1, "the marked row is read when scrolled out of view");
} finally {
  await browser.close();
}

if (failures > 0) {
  console.log(`FAIL: low-level-code-reader: ${failures} check(s)`);
  process.exit(1);
}
console.log("PASS: low-level-code-reader");
