#!/usr/bin/env node
// Count the whole-document restyles the Changes panel's path cuts cost, and
// fail when a cut — or any inline-style write or inserted element — makes
// the browser restyle the whole document.
//
// WHY. The 300-file Code tab (`ChangesCodeLongKeyboard`) cuts every row's
// path in its middle at the sidebar width (`ah_cut_text.nim`), and each cut
// writes inline style on its row and measures it. A stylesheet rule
// `:root:has(... :not([style*="display: none"]) ...)` (the caption bar's
// height switch) made Chromium re-evaluate `:root` on every inline-style
// write and restyle all ~3400 elements each time: ~2500 whole-document
// restyles, 86 s of style recalculation, 45-100 s to mount at 360px against
// ~2.4 s at 1440px. See ci/test/css-has-invalidation-guard.py for the two
// selector shapes measured to do this and why.
//
// WHAT IT COUNTS, AND WHY NOT TIME. Wall-clock time is useless on a shared
// host (the same build mounted in 2-27 s depending on load). What does not
// depend on load is how many elements each style recalculation touched:
// Chromium records it as `elementCount` on every `UpdateLayoutTree` trace
// event (category `devtools.timeline`). A "whole-document restyle" here is a
// recalculation that touched at least half the document's elements.
//
// The arms:
//
//   mount    trace the story's mount at 360x900 until the cuts are drawn;
//            fail if the whole-document restyles number one per ten cuts or
//            more (before the fix: ~1400-2200 for 300 cuts; after: 0). An
//            instrument failure if fewer than 100 paths were cut or no
//            recalculation was traced: the check then measured nothing.
//   writes   on the mounted story, one inline-style write on a cut row and
//            one inserted element; fail if the recalculation that follows
//            either touches half the document (before: 3394 / 3395 elements;
//            after: 2 / 8).
//   caption  the caption bar's switch still switches: on a page carrying the
//            compiled theme stylesheet, `#menu` reads the 2.375rem / 0.375rem
//            welcome values when `body > #welcomeScreen` carries
//            `data-welcome-shown` (which ui/welcome_screen.nim sets together
//            with the host's content), and the 2.125rem / 0.125rem workspace
//            values when it does not — including when the host is shown by
//            inline style with content, which is no longer the switch.
//
// `--self-test` is the positive control: it plants each failure into a
// passing run — the old caption rule (mount and writes must fail), a
// `:root:has()` naming only a class (writes must fail on the insertion), the
// switch forced to the workspace height (caption must fail), and the story at
// 1440px where nothing is cut (mount must report an instrument failure) — and
// exits 0 only when the unplanted run passes and every plant is caught.
// Plants are CSS added to the real story page or a width change; nothing is
// mocked.
//
// Usage (from the repository root, after `just storybook-build`, which
// `just storybook-check-style-invalidation` runs first):
//
//   node storybook/scripts/check-style-invalidation.mjs [--url <storybook>]
//       [--self-test] [--timeout <ms>]
//
// `--timeout` (default 600000) only stops a hung page; it is not a verdict.

import { createRequire } from "node:module";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { serveStatic } from "./check-story-render.mjs";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const storybookDir = resolve(scriptDir, "..");
const repoRoot = resolve(storybookDir, "..");
const staticDir = join(storybookDir, "storybook-static");

const STORY = "codetracer-agent-harbor--changes-code-long-keyboard";
const NARROW = { width: 360, height: 900 };
const WIDE = { width: 1440, height: 900 };
// A recalculation that touches at least this share of the document's
// elements is a whole-document restyle.
const WHOLE_DOCUMENT_SHARE = 0.5;
// The mount may restyle the whole document a few times (first style, font
// loads); the cuts must not add one each. Fewer than one per CUTS_PER_RESTYLE
// cuts passes.
const CUTS_PER_RESTYLE = 10;
const MIN_CUTS = 100;
const THEMES = ["default_dark_theme_electron.css", "default_white_theme_electron.css"];
const CAPTION = {
  workspace: { height: "2.125rem", padding: "0.125rem" },
  welcome: { height: "2.375rem", padding: "0.375rem" },
};

// --- Arguments --------------------------------------------------------------

const argValue = (name) => {
  const i = process.argv.indexOf(name);
  return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : undefined;
};
const known = new Set(["--url", "--self-test", "--timeout"]);
for (const arg of process.argv.slice(2)) {
  if (arg.startsWith("--") && !known.has(arg)) {
    console.error(`check-style-invalidation: unknown option ${arg}`);
    process.exit(2);
  }
}
const timeoutMs = Number(argValue("--timeout") ?? 600000);

// --- Tracing ------------------------------------------------------------------

const TRACE_CATEGORIES = ["devtools.timeline"];

// The element counts of every style recalculation in a trace buffer.
function recalcElementCounts(buffer) {
  const { traceEvents } = JSON.parse(buffer.toString());
  return traceEvents
    .filter((e) => e.name === "UpdateLayoutTree" && typeof e.args?.elementCount === "number")
    .map((e) => e.args.elementCount);
}

// Add `css` to the page as it loads (a planted stylesheet defect).
async function plantCss(page, css) {
  if (!css) return;
  await page.addInitScript((text) => {
    document.addEventListener("DOMContentLoaded", () => {
      const s = document.createElement("style");
      s.textContent = text;
      document.head.appendChild(s);
    });
  }, css);
}

// Let the cuts settle: they run in ResizeObserver callbacks and again when
// fonts finish loading, so wait for the fonts and two rendering steps.
const settle = (page) => page.evaluate(async () => {
  await document.fonts.ready;
  for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(r));
});

// mount + writes arms on one page.
async function checkStory(browser, baseUrl, { css, viewport = NARROW } = {}) {
  const page = await browser.newPage({ viewport });
  page.setDefaultTimeout(timeoutMs);
  const failures = [];
  try {
    await plantCss(page, css);
    await browser.startTracing(page, { categories: TRACE_CATEGORIES });
    await page.goto(`${baseUrl}/iframe.html?id=${STORY}&viewMode=story`);
    await page.waitForSelector(".ah-code-file-focused");
    await settle(page);
    const counts = recalcElementCounts(await browser.stopTracing());
    const { elements, cuts } = await page.evaluate(() => ({
      elements: document.getElementsByTagName("*").length,
      cuts: document.querySelectorAll('[data-ah-cut="path"][data-ah-shown]').length,
    }));
    const whole = counts.filter((n) => n >= elements * WHOLE_DOCUMENT_SHARE).length;
    const mount = { elements, cuts, recalcs: counts.length, whole };
    if (counts.length === 0) {
      failures.push({ arm: "mount", instrument: true, message: "no style recalculation was traced" });
    } else if (cuts < MIN_CUTS) {
      failures.push({ arm: "mount", instrument: true,
        message: `only ${cuts} paths were cut (at least ${MIN_CUTS} expected): nothing was measured` });
    } else if (whole * CUTS_PER_RESTYLE >= cuts) {
      failures.push({ arm: "mount",
        message: `${whole} of ${counts.length} style recalculations restyled the whole document ` +
          `(>= ${WHOLE_DOCUMENT_SHARE * 100}% of ${elements} elements) while ${cuts} paths were cut` });
    }

    // writes: one inline-style write and one insertion on a cut row, each
    // followed by a forced style recalculation.
    const writes = {};
    for (const [label, body] of [
      ["inline-style write", "el.style.setProperty('--ct-invalidation-probe', '1');"],
      ["element insertion", "el.appendChild(document.createElement('span'));"],
    ]) {
      await page.evaluate(() => document.body.getBoundingClientRect());
      await browser.startTracing(page, { categories: TRACE_CATEGORIES });
      await page.evaluate(`(() => {
        const rows = document.querySelectorAll('[data-ah-cut="path"]');
        const el = rows[Math.floor(rows.length / 2)] ?? document.querySelector(".ah-code-file-focused");
        ${body}
        getComputedStyle(el).color;
      })()`);
      const probe = recalcElementCounts(await browser.stopTracing());
      const worst = Math.max(0, ...probe);
      writes[label] = worst;
      if (worst >= elements * WHOLE_DOCUMENT_SHARE) {
        failures.push({ arm: "writes",
          message: `one ${label} on a cut row restyled ${worst} of ${elements} elements` });
      }
    }
    return { failures, mount, writes };
  } finally {
    await page.close();
  }
}

// caption arm.
async function checkCaption(browser, baseUrl, { css } = {}) {
  const failures = [];
  for (const theme of THEMES) {
    const page = await browser.newPage({ viewport: WIDE });
    page.setDefaultTimeout(timeoutMs);
    try {
      await page.setContent(`<!doctype html><html><head>
        <link rel="stylesheet" href="${baseUrl}/frontend/styles/${theme}">
        ${css ? `<style>${css}</style>` : ""}</head>
        <body><div id="menu" class="menu"></div><div id="welcomeScreen"></div></body></html>`,
        { waitUntil: "load" });
      const cases = [
        ["host hidden and empty", "", "", "workspace"],
        ["host shown by inline style, with content, not marked", "display: block", "content", "workspace"],
        ["host marked, with content", "display: block", "content+mark", "welcome"],
      ];
      for (const [label, style, content, want] of cases) {
        const got = await page.evaluate(([style, content]) => {
          const host = document.getElementById("welcomeScreen");
          host.replaceChildren();
          host.removeAttribute("data-welcome-shown");
          host.setAttribute("style", style);
          if (content) host.appendChild(document.createElement("div")).className = "welcome-screen-root";
          if (content.includes("mark")) host.setAttribute("data-welcome-shown", "");
          const cs = getComputedStyle(document.getElementById("menu"));
          return {
            height: cs.getPropertyValue("--caption-bar-height").trim(),
            padding: cs.getPropertyValue("--caption-bar-padding-bottom").trim(),
          };
        }, [style, content]);
        const expected = CAPTION[want];
        if (got.height !== expected.height || got.padding !== expected.padding) {
          failures.push({ arm: "caption",
            message: `${theme}, ${label}: caption bar ${got.height || "unset"} / ${got.padding || "unset"}, ` +
              `expected the ${want} ${expected.height} / ${expected.padding}` });
        }
      }
    } finally {
      await page.close();
    }
  }
  return { failures };
}

function printRun(name, story, caption) {
  const failures = [...(story?.failures ?? []), ...(caption?.failures ?? [])];
  console.log(`${failures.length ? "FAIL" : "ok  "} ${name}`);
  if (story?.mount) {
    const m = story.mount;
    console.log(`       mount: ${m.cuts} paths cut, ${m.recalcs} style recalculations, ` +
      `${m.whole} of them whole-document (${m.elements} elements)`);
  }
  if (story?.writes) {
    console.log(`       writes: ${Object.entries(story.writes).map(([k, v]) => `${k} restyled ${v}`).join(", ")}`);
  }
  for (const f of failures) console.log(`       ${f.arm}${f.instrument ? " (instrument)" : ""}: ${f.message}`);
  return failures;
}

const OLD_CAPTION_RULE = ':root:has(> body > #welcomeScreen:not([style*="display: none"]):not([style*="display:none"]) > *) { --caption-bar-height: 2.375rem; }';
const PLANTS = [
  { name: "the old caption switch (reads `style` from :root)", story: { css: OLD_CAPTION_RULE },
    expect: [["mount", false], ["writes", false]] },
  { name: "a :root:has() naming only a class", story: { css: ":root:has(.ct-never-present) { --ct-planted: 1; }" },
    expect: [["writes", false]] },
  { name: "the switch forced to the workspace height",
    caption: { css: "body:has(> #welcomeScreen[data-welcome-shown]) { --caption-bar-height: 2.125rem !important; }" },
    expect: [["caption", false]] },
  { name: "the story at 1440px, where no path is cut", story: { viewport: WIDE },
    expect: [["mount", true]] },
];

async function main() {
  let baseUrl = argValue("--url");
  let server = null;
  if (!baseUrl) {
    const { requireFreshStorybookStatic } = await import(join(repoRoot, "tools/visual-review/storybook-freshness.mjs"));
    requireFreshStorybookStatic(repoRoot);
    server = await serveStatic(staticDir);
    baseUrl = `http://127.0.0.1:${server.address().port}`;
  }
  baseUrl = baseUrl.replace(/\/$/, "");

  const { chromium } = createRequire(join(storybookDir, "package.json"))("playwright");
  const browser = await chromium.launch({
    executablePath: process.env.CODETRACER_CAPTURE_CHROMIUM || undefined,
    args: ["--no-sandbox"],
  });
  let exitCode = 0;
  try {
    // Sequential on purpose: one browser can trace one page at a time.
    const control = printRun(`${STORY} at ${NARROW.width}x${NARROW.height}, and the caption switch`,
      await checkStory(browser, baseUrl), await checkCaption(browser, baseUrl));
    if (control.length) exitCode = 1;
    if (process.argv.includes("--self-test")) {
      console.log("\nself-test:");
      console.log(`  ${control.length ? "FAIL" : "ok  "} control passes unplanted`);
      for (const plant of PLANTS) {
        const failures = printRun(`planted: ${plant.name}`,
          plant.story ? await checkStory(browser, baseUrl, plant.story) : null,
          plant.caption ? await checkCaption(browser, baseUrl, plant.caption) : null);
        const caught = plant.expect.every(([arm, instrument]) =>
          failures.some((f) => f.arm === arm && Boolean(f.instrument) === instrument));
        console.log(`  ${caught ? "ok  " : "FAIL"} planted ${plant.name} -> ` +
          plant.expect.map(([arm, instrument]) => `${arm}${instrument ? " (instrument)" : ""}`).join(", "));
        if (!caught) exitCode = 1;
      }
      console.log(exitCode === 0 ? "self-test passed" : "self-test FAILED: the check misses a failure it exists to catch");
    }
  } finally {
    await browser.close();
    if (server) server.close();
  }
  process.exit(exitCode);
}

main().catch((error) => {
  console.error(`check-style-invalidation: ${error.stack ?? error}`);
  process.exit(2);
});
