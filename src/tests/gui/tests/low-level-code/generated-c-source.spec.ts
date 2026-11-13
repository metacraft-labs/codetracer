/**
 * generated-c-source.spec.ts — the desktop's View › View Generated C Source
 * and View › View Disassembly, in the real Electron app.
 *
 * Spec: codetracer-pm `spec/GUI/Debugging-Features/Generated-Code-Listing.md`
 * §13.4 — for a Nim source, the C a line compiled to, shown in the Low Level
 * Code pane and anchored to that line; in Debug mode read from the recording
 * (a stock compiler's `#line` directives, or the `.c.map` Source Map v3 that
 * CodeTracer's own Nim compiler writes into `<trace>/nimcache/`), in Edit mode
 * (HSF-E11) compiled from the saved file then; and View Disassembly the stop's
 * machine code in the same pane.
 *
 *   (a) a recording `ct record` makes with a STOCK Nim compiler
 *       (`GENC_STOCK_NIM`, as `CODETRACER_NIM_EXE_PATH`) of the program the
 *       example recording `codetracer-example-recordings/nim/flow_test` was
 *       made from: its C carries `#line` directives and no maps. (That
 *       committed folder itself cannot be opened by the desktop: it holds no
 *       `.ct` container, which every desktop trace import requires, and an rr
 *       folder that does — `ct-native-replay record` — is imported but never
 *       starts its replay; see the report of the change that added this
 *       spec.)
 *   (b) a recording made by today's `ct record` of a Nim program, which
 *       compiles it with CodeTracer's Nim and keeps the C and its maps in the
 *       recording's `nimcache/`;
 *   (c) Edit mode on a small Nim project: the caret line's C, and a file that
 *       does not compile refused with the compiler's own error.
 *
 * WHAT IS ASSERTED, AND AGAINST WHAT. The pane's rows are read from the DOM.
 * The row the listing anchors the asked-about line to (`.active-instruction`)
 * must (1) be in the pane's visible area, (2) carry the text of that line of
 * the generated C file read from disk by this spec, and (3) be a row the C
 * file itself attributes to the Nim line — through its `#line` directives,
 * or through its source map, decoded here by a decoder of this spec's own
 * (not the product's). So a listing anchored to the wrong line, a listing of
 * another file, or a right answer scrolled out of sight each fail.
 *
 * No mocks: real recordings, the real replay (`replay-server`, `ct-native-
 * replay`), the real Nim compiler, and this checkout's desktop JavaScript
 * (`PLAT60_DESKTOP_PREFIX`, `scripts/plat45-desktop-prefix.sh`).
 */
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

import { expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import { test } from "../../lib/fixtures";

const prefix = process.env.PLAT60_DESKTOP_PREFIX ?? "";
const stockNim = process.env.GENC_STOCK_NIM ?? "";
const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");

// ---------------------------------------------------------------------------
// The generated C, read independently of the product
// ---------------------------------------------------------------------------

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** Base64 VLQ, https://sourcemaps.info/spec.html "Base64 VLQ". */
function decodeVlq(segment: string): number[] {
  const out: number[] = [];
  let value = 0;
  let shift = 0;
  for (const ch of segment) {
    const digit = B64.indexOf(ch);
    if (digit < 0) throw new Error(`bad VLQ digit ${ch}`);
    value += (digit & 31) << shift;
    if (digit & 32) {
      shift += 5;
    } else {
      out.push(value & 1 ? -(value >> 1) : value >> 1);
      value = 0;
      shift = 0;
    }
  }
  return out;
}

/**
 * The 1-based C lines ANY of whose mapped segments names `nimFile` (by its
 * file name) at 1-based `nimLine` — what a reader of the map attributes each
 * C line to. Every segment, not the first: CodeTracer's compiler records a
 * zero-width segment wherever it starts emitting a node, so one C line names
 * many Nim lines in emission order and its first is arbitrary: the
 * `nimln_(60);{` that opens nim_sudoku_solver's `var testBoards` names ninety
 * positions, line 1 first and line 60 among them. The product attributes a
 * line the same way (`nim_c_producer.mapRowsOf`).
 */
function mapLinesFor(mapText: string, nimFile: string, nimLine: number): Set<number> {
  const map = JSON.parse(mapText);
  const sources: string[] = map.sources ?? [];
  const lines = new Set<number>();
  let src = 0;
  let origLine = 0;
  const groups = String(map.mappings ?? "").split(";");
  groups.forEach((group, i) => {
    for (const seg of group.split(",")) {
      if (seg.length === 0) continue;
      const f = decodeVlq(seg);
      if (f.length < 4) continue;
      src += f[1];
      origLine += f[2];
      if (path.basename(sources[src] ?? "") === nimFile && origLine + 1 === nimLine) {
        lines.add(i + 1);
      }
    }
  });
  return lines;
}

/**
 * The 1-based C lines a stock compiler's `#line <nimLine> FX_<n>` runs
 * attribute to `nimFile` — each directive and the lines up to the next.
 */
function directiveLinesFor(cText: string, nimFile: string, nimLine: number): Set<number> {
  const lines = cText.split("\n");
  const fx = new Map<string, string>();
  for (const l of lines) {
    const m = /^#define (FX_\d+) "(.*)"/.exec(l);
    if (m) fx.set(m[1], m[2]);
  }
  const out = new Set<number>();
  let inRun = false;
  lines.forEach((l, i) => {
    const m = /^#line (\d+) (FX_\d+)/.exec(l);
    if (m) {
      inRun = Number(m[1]) === nimLine && path.basename(fx.get(m[2]) ?? "") === nimFile;
    }
    if (inRun) out.add(i + 1);
  });
  return out;
}

/** The C lines `cFile` attributes to `nimFile:nimLine`, by whichever form it carries. */
function expectedCLines(cFile: string, nimFile: string, nimLine: number): Set<number> {
  const text = fs.readFileSync(cFile, "utf8");
  if (/^#line \d+ FX_\d+/m.test(text)) return directiveLinesFor(text, nimFile, nimLine);
  return mapLinesFor(fs.readFileSync(cFile + ".map", "utf8"), nimFile, nimLine);
}

// ---------------------------------------------------------------------------
// The app
// ---------------------------------------------------------------------------

/** Run the menu element named `label`'s own action, as choosing it does. */
async function runMenuItem(page: Page, label: string): Promise<void> {
  const action = await page.evaluate((name: string) => {
    const data = (window as any).data;
    const walk = (node: any): number => {
      if (!node) return -1;
      if (node.name === name) return Number(node.action);
      for (const c of node.elements ?? []) {
        const found = walk(c);
        if (found >= 0) return found;
      }
      return -1;
    };
    return walk(data.ui.menuNode);
  }, label);
  expect(action, `the View menu has "${label}"`).toBeGreaterThanOrEqual(0);
  // A Nim exception reaches here as a plain object: say what it carries.
  const thrown = await page.evaluate((a: number) => {
    try {
      (window as any).data.actions[a](null);
      return "";
    } catch (e: any) {
      const text = (v: any) => Array.isArray(v) ? String.fromCharCode(...v) : String(v ?? "");
      return `${text(e?.name)}: ${text(e?.message ?? e?.msg)} ${text(e?.stack)}`;
    }
  }, action);
  expect(thrown, `"${label}" ran without throwing`).toBe("");
}

/** Put the active editor's caret on `line`; answers the editor's file. */
async function caretAt(page: Page, line: number): Promise<string> {
  return page.evaluate((l: number) => {
    const data = (window as any).data;
    const active = data.services.editor.active;
    const editor = data.ui.editors[active];
    editor.monacoEditor.setPosition({ lineNumber: l, column: 1 });
    editor.monacoEditor.focus();
    return String(editor.path);
  }, line);
}

interface PaneRow {
  offset: number;
  text: string;
  active: boolean;
  inView: boolean;
}

/** The shown Low Level Code pane: its rows and its header's error, from the DOM. */
function readPane(page: Page): Promise<{ rows: PaneRow[]; error: string; address: string }> {
  return page.evaluate(() => {
    const panes = Array.from(document.querySelectorAll(".low-level-code")) as HTMLElement[];
    const pane = panes.find((p) => p.offsetParent !== null) ?? panes[0];
    if (!pane) return { rows: [], error: "", address: "" };
    const text = (n: Element | null) => (n ? (n.textContent || "").trim() : "");
    // The nearest scrolling ancestor of the rows is the visible area.
    const list = pane.querySelector(".low-level-code-instructions") as HTMLElement | null;
    let box: HTMLElement | null = list;
    while (box && !(box.scrollHeight > box.clientHeight + 1 &&
                    /(auto|scroll)/.test(getComputedStyle(box).overflowY))) {
      box = box.parentElement;
    }
    const view = (box ?? pane).getBoundingClientRect();
    const rows = Array.from(pane.querySelectorAll(".low-level-code-instruction")).map((r) => {
      const rect = r.getBoundingClientRect();
      return {
        offset: Number(text(r.querySelector(".low-level-code-instruction-offset"))),
        text: (r.querySelector(".low-level-code-instruction-name")?.textContent ?? ""),
        active: r.classList.contains("active-instruction"),
        inView: rect.height > 0 && rect.top >= view.top - 1 && rect.bottom <= view.bottom + 1 &&
          rect.top >= 0 && rect.bottom <= window.innerHeight,
      };
    });
    return {
      rows,
      error: text(pane.querySelector(".low-level-code-error")),
      address: text(pane.querySelector(".low-level-code-address")),
    };
  });
}

/** Wait until the pane holds an anchored row in view, or `timeoutMs` passes. */
async function anchoredListing(page: Page, timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  let pane = await readPane(page);
  while (Date.now() < deadline) {
    const active = pane.rows.filter((r) => r.active);
    if (active.length === 1 && active[0].inView) return pane;
    await page.waitForTimeout(250);
    pane = await readPane(page);
  }
  return pane;
}

/** The stop: its source path and line, once the debugger has one in a `.nim` file. */
async function nimStop(page: Page): Promise<{ path: string; line: number }> {
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    const at = await page.evaluate(() => {
      const loc = (window as any).data?.services?.debugger?.location;
      return { path: String(loc?.path ?? ""), line: Number(loc?.line ?? -1) };
    });
    if (at.path.endsWith(".nim") && at.line > 0) return at;
    await page.waitForTimeout(500);
  }
  // Say what the window said instead: the status bar's notifications carry a
  // replay's refusal.
  const said = await page.evaluate(() => {
    const data = (window as any).data;
    const session = data?.sessions?.[data.activeSessionIndex];
    const notes = session?.ui?.status?.notifications ?? [];
    const loc = data?.services?.debugger?.location;
    return { location: `${loc?.path ?? ""}:${loc?.line ?? ""}`,
             notifications: (Array.isArray(notes) ? notes : []).map((n: any) => String(n?.text ?? n)) };
  });
  throw new Error(`the replay never stopped in a Nim source: ${JSON.stringify(said)}`);
}

/** The active editor shows `file`. */
async function editorShows(page: Page, file: string): Promise<void> {
  await expect.poll(() => page.evaluate(() => {
    const data = (window as any).data;
    const editor = data?.ui?.editors?.[data?.services?.editor?.active];
    return editor?.monacoEditor ? String(editor.path) : "";
  }), { timeout: 90_000 }).toBe(file);
}

/** The anchored row, checked against the C file it must have come from. */
function checkAnchoredRow(pane: { rows: PaneRow[]; error: string }, cFile: string, nimFile: string, nimLine: number) {
  const active = pane.rows.filter((r) => r.active);
  expect(active.length, `one row is anchored to the line (the pane: ${pane.rows.length} rows, ` +
    `error "${pane.error}")`).toBe(1);
  const row = active[0];
  expect(row.inView, `the anchored row (C line ${row.offset}) is in view`).toBe(true);
  const cLines = fs.readFileSync(cFile, "utf8").split("\n");
  expect(row.text.trim(), `the anchored row is line ${row.offset} of ${cFile}`)
    .toBe((cLines[row.offset - 1] ?? "").trim());
  const expected = expectedCLines(cFile, nimFile, nimLine);
  expect(expected.size, `${cFile} attributes some C to ${nimFile}:${nimLine}`).toBeGreaterThan(0);
  expect([...expected], `C line ${row.offset} is one ${cFile} attributes to ${nimFile}:${nimLine}`)
    .toContain(row.offset);
}

/** View Disassembly: the pane changes to the stop's machine code. */
async function checkDisassembly(page: Page) {
  await runMenuItem(page, "View Disassembly");
  const deadline = Date.now() + 60_000;
  let pane = await readPane(page);
  while (Date.now() < deadline && !(pane.address.length > 0 && pane.rows.length > 0)) {
    await page.waitForTimeout(500);
    pane = await readPane(page);
  }
  expect(pane.address, `the header names the function's address (error: ${pane.error})`)
    .toMatch(/^Originating address: 0x[0-9A-Fa-f]+$/);
  // Machine code: each row is a mnemonic at a load address, not a line of C.
  expect(pane.rows.length).toBeGreaterThan(5);
  const mnemonic = /^(endbr64|push|pop|mov|movs|movz|lea|sub|add|xor|and|or|cmp|test|call|ret|j[a-z]+|nop|leave|imul|shl|shr|sar|cdq|cqo|set[a-z]+|cmov[a-z]+|int3|ud2)/;
  const machine = pane.rows.filter((r) => mnemonic.test(r.text.trim().toLowerCase()));
  expect(machine.length, `rows are instructions: ${pane.rows.slice(0, 5).map((r) => r.text).join(" | ")}`)
    .toBeGreaterThan(pane.rows.length * 0.8);
}

test.setTimeout(600_000);

// ---------------------------------------------------------------------------
// (a) a stock-Nim recording
// ---------------------------------------------------------------------------

/**
 * The recording's Nim stop, the C of its module — the recording's own
 * `nimcache/@m<module>.nim.c` — and the View menu's two items over it.
 */
async function generatedCOfStop(page: Page, expectDirectives: boolean) {
  // The replay's first stop, asked about as it is: its line has C
  // (`checkAnchoredRow` asserts that the C file attributes some to it).
  const stop = await nimStop(page);
  console.log(`# the first Nim stop: ${stop.path}:${stop.line}`);
  const folder = await page.evaluate(() => String((window as any).data.trace.outputFolder));
  const cFileOf = (nim: string) => path.join(folder, "nimcache", "@m" + path.basename(nim) + ".c");
  await editorShows(page, stop.path);
  await caretAt(page, stop.line);
  await runMenuItem(page, "View Generated C Source");
  const pane = await anchoredListing(page);
  const cFile = cFileOf(stop.path);
  const text = fs.readFileSync(cFile, "utf8");
  if (expectDirectives) {
    expect(text, `${cFile}: a stock compiler's #line directives`).toMatch(/^#line \d+ FX_/m);
  } else {
    expect(text, `${cFile}: CodeTracer's compiler writes no #line directives`).not.toMatch(/^#line \d+ FX_/m);
    expect(fs.existsSync(cFile + ".map"), `${cFile} has its source map`).toBe(true);
  }
  checkAnchoredRow(pane, cFile, path.basename(stop.path), stop.line);
  await checkDisassembly(page);
}

/** `CODETRACER_NIM_EXE_PATH` for the recordings one describe makes. */
function recordWithNim(nim: string) {
  let saved: string | undefined;
  test.beforeAll(() => {
    saved = process.env.CODETRACER_NIM_EXE_PATH;
    if (nim.length > 0) process.env.CODETRACER_NIM_EXE_PATH = nim;
  });
  test.afterAll(() => {
    if (saved === undefined) delete process.env.CODETRACER_NIM_EXE_PATH;
    else process.env.CODETRACER_NIM_EXE_PATH = saved;
  });
}

test.describe("View Generated C Source on a stock-Nim recording", () => {
  test.skip(stockNim.length === 0 || !fs.existsSync(stockNim),
    "MISSING-PREREQ: GENC_STOCK_NIM, a stock Nim compiler (scripts/generated-c-desktop.sh)");
  recordWithNim(stockNim);
  test.use({
    sourcePath: path.join(repoRoot, "src", "db-backend", "test-programs", "nim", "nim_flow_test.nim"),
    launchMode: "trace",
    codetracerPrefixOverride: prefix,
  });

  test("the stop line's C by its #line directives, in view; then the machine code", async ({ ctPage }) => {
    await generatedCOfStop(ctPage, true);
  });
});

// ---------------------------------------------------------------------------
// (b) a `ct record` recording (CodeTracer's Nim, source maps in nimcache/)
// ---------------------------------------------------------------------------

test.describe("View Generated C Source on a ct record recording of a Nim program", () => {
  test.use({ sourcePath: "nim_sudoku_solver/main.nim", launchMode: "trace", codetracerPrefixOverride: prefix });

  test("the stop line's C by its source map, in view; then the machine code", async ({ ctPage }) => {
    await generatedCOfStop(ctPage, false);
  });
});

// ---------------------------------------------------------------------------
// (c) Edit mode
// ---------------------------------------------------------------------------

/** A small Nim project, outside the checkout. */
const project = fs.mkdtempSync(path.join(os.tmpdir(), "ct-genc-edit-"));
const good = path.join(project, "main.nim");
const broken = path.join(project, "broken.nim");
fs.writeFileSync(good, [
  "proc twice(x: int): int =",
  "  result = x * 2",
  "",
  "echo twice(21)",
  "",
].join("\n"));
fs.writeFileSync(broken, [
  "let answer: int = \"forty-two\"",
  "echo answer",
  "",
].join("\n"));
const caretLine = 2;

/** The scratch nimcache the desktop compiled `source` into. */
function listingCacheOf(source: string): string {
  const home = process.env.CODETRACER_HOME ?? "";
  const root = path.join(home, "state", "nim-c-listings");
  const stem = path.basename(source, ".nim");
  const dirs = fs.existsSync(root) ? fs.readdirSync(root).filter((d) => d.startsWith(stem + "-")) : [];
  expect(dirs.length, `one nimcache for ${source} under ${root}`).toBe(1);
  return path.join(root, dirs[0]);
}

/** Choose View Generated C Source, watching for the pane's "compiling" state. */
async function viewGeneratedCWatchingCompile(page: Page): Promise<boolean> {
  await page.evaluate(() => {
    const w = window as any;
    w.__gencSawCompiling = false;
    // The main process's answer, kept for a failure message.
    w.data.ipc.on("CODETRACER::nim-c-listing-compiled", (_e: any, answer: any) => {
      w.__gencAnswer = JSON.stringify(answer);
    });
    const observer = new MutationObserver(() => {
      for (const e of Array.from(document.querySelectorAll(".low-level-code .low-level-code-error"))) {
        if ((e.textContent ?? "").startsWith("compiling ")) w.__gencSawCompiling = true;
      }
    });
    observer.observe(document.body, { subtree: true, childList: true, characterData: true });
    w.__gencObserver = observer;
  });
  await runMenuItem(page, "View Generated C Source");
  return page.evaluate(() => (window as any).__gencSawCompiling === true);
}

test.describe("View Generated C Source in Edit mode", () => {
  test.describe("a file that compiles", () => {
    test.use({ launchMode: "edit", editFolderPath: good, codetracerPrefixOverride: prefix });

    test("the caret line's C, compiled from the saved file, in view", async ({ ctPage }) => {
      await editorShows(ctPage, good);
      await caretAt(ctPage, caretLine);
      await viewGeneratedCWatchingCompile(ctPage);
      const pane = await anchoredListing(ctPage);
      const sawCompiling = await ctPage.evaluate(() => (window as any).__gencSawCompiling === true);
      expect(sawCompiling, "the pane said it was compiling while the compiler ran").toBe(true);
      const answer = await ctPage.evaluate(() => (window as any).__gencAnswer ?? "");
      expect(pane.error, `the main process answered ${answer}`).toBe("");
      checkAnchoredRow(pane, path.join(listingCacheOf(good), "@mmain.nim.c"), "main.nim", caretLine);
    });
  });

  test.describe("a file that does not compile", () => {
    test.use({ launchMode: "edit", editFolderPath: broken, codetracerPrefixOverride: prefix });

    test("refused, with the compiler's error", async ({ ctPage }) => {
      await editorShows(ctPage, broken);
      await caretAt(ctPage, 1);
      await viewGeneratedCWatchingCompile(ctPage);
      let pane = await readPane(ctPage);
      const deadline = Date.now() + 60_000;
      while (Date.now() < deadline && !pane.error.startsWith("could not compile")) {
        await ctPage.waitForTimeout(250);
        pane = await readPane(ctPage);
      }
      expect(pane.error).toContain("could not compile broken.nim to C: ");
      // The compiler's own first error line, naming the file and the mismatch.
      expect(pane.error).toMatch(/broken\.nim\(1, \d+\) Error: type mismatch/);
      expect(pane.rows.length).toBe(0);
    });
  });
});
