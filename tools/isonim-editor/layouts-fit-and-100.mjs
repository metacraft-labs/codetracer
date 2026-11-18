#!/usr/bin/env node
// e2e_codetracer_instance_layouts_fit_and_100: CodeTracer's full-window
// layout stories, opened in the IsoNim Editor instance at the Wide screen type
// (1920x1080), fit the preview area and also show at 100% with scrollbars.
// Run by `just isonim-editor-codetracer --layouts-fit-and-100` (or
// `just test-isonim-editor-layouts-fit-and-100`) against an instance it
// started (scripts/isonim-editor-codetracer.sh).
//
// The stories are the "Layouts" group's L1 to L14, read from stories.json
// (ids `codetracer-layouts--l-<n>-...`), which `just storybook-stories` writes
// from the same declaration the editor instance shows. The instance lists the
// Layouts group under Pages (its stories are whole windows), so each is a
// page story (`kind=page`), opened in the editor's page preview, the surface
// that carries the zoom cluster, through its story URL (`view=page`,
// `viewport=wide`, `zoom=fit`), in a 1920x1080
// browser window, once in each CodeTracer theme (`ctTheme=dark` and
// `ctTheme=light`). Every number below is measured in the live page; nothing is
// judged from a screenshot. The screenshots, `l-<n>-<fit|100>-<theme>.png` in
// --out, are written for a reader only.
//
// How the IsoNim Editor sizes and zooms a page preview, which this test holds it to:
//   - The frame is the screen type's fixed size, 1920x1080 for Wide, and the
//     story lays out at that size whatever the zoom. The zoom scales the frame
//     as a whole.
//   - Fit is the largest level at which the whole frame shows in the preview
//     area, never above 100%: min(1, areaWidth / 1920, areaHeight / 1080),
//     where the area is the preview area's full client box, with no gutter or
//     margin. The frame then touches the area's edge in its constraining
//     direction.
//   - 100% shows the frame at its real size; where the frame is larger than
//     the area, the area scrolls in that direction.
//
// The layout's extent. A story is mounted into the frame's <body> under a
// `.ct-storybook-surface` wrapper. A layout's panes are fixed-position boxes,
// so the wrapper (and the frame element inside it) is 0 px tall and says
// nothing about where the layout is drawn. The extent is therefore the union
// of the layout's outermost boxes: walking down from the wrapper, the first
// element on each path whose box is non-empty (and is displayed and visible)
// is one of them, and the walk does not descend into it. What is inside such
// a box (a scrolled code view, a long call trace) is the layout's own content,
// clipped or scrolled by the layout itself, not overflow of the frame. The one
// exception is a fixed-position element: it escapes every box it sits in (the
// status bar is fixed inside the 0 px footer of the root container), so every
// displayed and visible fixed-position element with a non-empty box is counted
// too.
//
// Checks, per layout:
//   renders      The story's layout is mounted in the preview frame's
//                document: it has a non-empty extent, at least 10 visible
//                elements and some text. Without this the checks below would
//                be about an empty frame.
//   theme        The frame's document is in the theme the URL asked for.
//   fit.level    The editor is in Fit mode (the URL says zoom=fit), and the
//                frame's scale, read from its on-screen box (box / 1920 and
//                box / 1080), equals min(1, area client width / 1920, area
//                client height / 1080) within 0.002; the readout is that
//                level rounded to a whole percent.
//   fit.frame    The scaled frame lies inside the preview area's client box
//                (to 0.5 px), touches it in the constraining direction (to
//                1 px), and the area does not scroll (scrollWidth <=
//                clientWidth and scrollHeight <= clientHeight).
//   fit.layout   The rendered layout lies entirely inside the preview area:
//                inside the frame's document nothing overflows (for <html>
//                and <body>, scrollWidth <= clientWidth and scrollHeight <=
//                clientHeight), the extent lies inside the frame's viewport
//                (to 0.5 px), and the extent's on-screen box, mapped through
//                the frame's scale, lies inside the area's client box.
//   fit.fills    The layout fills the Wide viewport it lays out at: the
//                extent equals the frame's viewport (to 1 px).
//   100.level    After pressing the cluster's "100%": the URL says zoom=100,
//                the readout says 100%, and the frame's on-screen box is
//                1920x1080 (to 1 px), i.e. scale 1.
//   100.natural  The content is at its natural size: the extent's on-screen
//                box equals its CSS box (to 1 px), its CSS box is the one
//                measured at Fit (the layout does not change with the zoom),
//                and the frame's document overflows nothing, as at Fit.
//   100.scroll   The preview area's scroll container (the zoom stage's
//                parent) scrolls on every axis where the frame is larger than
//                its client box: scrollWidth > clientWidth when 1920 >
//                clientWidth, scrollHeight > clientHeight when 1080 >
//                clientHeight, at least one of them holds, overflow is
//                `auto`, and the scrollbars take space (offset size minus
//                client size > 0 on those axes).
//
// Scrollbars: Playwright starts headless Chromium with --hide-scrollbars,
// which draws every scrollbar at zero width, so this test launches it without
// that flag (`ignoreDefaultArgs`) and the 100.scroll gutters are real.
//
// Nothing is mocked. The editor, its server, CodeTracer's stories and
// stylesheets and the browser are the real ones. The instance's agent backend
// is the one it uses beyond loopback, which refuses every session; this test
// starts none.
//
//   node tools/isonim-editor/layouts-fit-and-100.mjs --url <origin>
//     --out <dir> --stories <stories.json>

import { createRequire } from "node:module";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const require = createRequire(import.meta.url);
// Playwright comes from the dev shell's NODE_PATH, as for smoke.mjs.
const { chromium } = require("playwright");

function arg(name, fallback = undefined) {
  const at = process.argv.indexOf(`--${name}`);
  if (at >= 0 && at + 1 < process.argv.length) return process.argv[at + 1];
  if (fallback === undefined) throw new Error(`missing --${name}`);
  return fallback;
}

const TEST_NAME = "e2e_codetracer_instance_layouts_fit_and_100";
const origin = arg("url").replace(/\/$/, "");
const outDir = arg("out");
const stories = JSON.parse(readFileSync(arg("stories"), "utf8")).stories;

// The Wide screen type and the browser window, both 1920x1080.
const FRAME = { width: 1920, height: 1080 };
const WINDOW = { width: 1920, height: 1080 };
// CodeTracer's two themes; the instance picks the preview's from `ctTheme`.
const THEMES = ["dark", "light"];
const LEVEL_TOLERANCE = 0.002;
const PX = 1;
const RENDER_TIMEOUT_MS = 20000;

const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok: !!ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
  return !!ok;
}

// L1 .. L14, in order, from the generated story list.
function layoutStories() {
  const layouts = stories
    .map((s) => ({ s, m: /^codetracer-layouts--l-(\d+)-/.exec(s.id) }))
    .filter(({ m }) => m)
    .map(({ s, m }) => ({ ...s, number: Number(m[1]) }))
    .sort((a, b) => a.number - b.number);
  return layouts;
}

function storyUrl(story, zoom, theme) {
  // A story's position in its group is part of its identity, as in smoke.mjs.
  const index = Math.max(0, stories.filter((s) => s.editorGroup === story.editorGroup)
    .findIndex((s) => s.name === story.name));
  const q = new URLSearchParams({ view: "page", storyGroup: story.editorGroup, story: story.name,
    kind: "page", index: String(index), viewport: "wide", zoom, ctTheme: theme });
  return `${origin}/?${q}`;
}

// Everything the checks read, in one snapshot of the page.
async function measure(page) {
  return page.evaluate(() => {
    const box = (r) => ({ left: r.left, top: r.top, right: r.right, bottom: r.bottom,
      width: r.width, height: r.height });
    const frame = document.querySelector('[data-preview-zoom-frame="true"]');
    const stage = document.querySelector('[data-preview-zoom-stage="true"]');
    const iframe = document.querySelector("[data-page-project-frame]");
    const host = stage && stage.parentElement;
    const out = { url: location.search, readout: document.querySelector("[data-preview-zoom-level]")?.textContent ?? null };
    if (!frame || !stage || !iframe || !host) return { ...out, missing: { frame: !frame, stage: !stage, iframe: !iframe, host: !host } };
    const hostRect = host.getBoundingClientRect();
    const hostStyle = getComputedStyle(host);
    out.host = {
      // The client box in viewport coordinates: inside the borders, without
      // the scrollbars.
      client: { left: hostRect.left + host.clientLeft, top: hostRect.top + host.clientTop,
        right: hostRect.left + host.clientLeft + host.clientWidth,
        bottom: hostRect.top + host.clientTop + host.clientHeight,
        width: host.clientWidth, height: host.clientHeight },
      scrollWidth: host.scrollWidth, scrollHeight: host.scrollHeight,
      vGutter: host.offsetWidth - host.clientWidth - (parseFloat(hostStyle.borderLeftWidth) + parseFloat(hostStyle.borderRightWidth)),
      hGutter: host.offsetHeight - host.clientHeight - (parseFloat(hostStyle.borderTopWidth) + parseFloat(hostStyle.borderBottomWidth)),
      overflowX: hostStyle.overflowX, overflowY: hostStyle.overflowY,
    };
    out.frame = box(frame.getBoundingClientRect());
    out.frameCss = { width: frame.offsetWidth, height: frame.offsetHeight };
    out.frameScaleAttr = Number(frame.getAttribute("data-preview-zoom-scale"));
    const iframeRect = iframe.getBoundingClientRect();
    out.iframe = box(iframeRect);
    const doc = iframe.contentDocument;
    const win = iframe.contentWindow;
    if (!doc || !doc.body || !win) return { ...out, doc: null };
    const viewport = { width: win.innerWidth, height: win.innerHeight };
    const sx = iframeRect.width / iframe.clientWidth;
    const sy = iframeRect.height / iframe.clientHeight;
    const toPage = (r) => ({ left: iframeRect.left + iframe.clientLeft * sx + r.left * sx,
      top: iframeRect.top + iframe.clientTop * sy + r.top * sy,
      right: iframeRect.left + iframe.clientLeft * sx + r.right * sx,
      bottom: iframeRect.top + iframe.clientTop * sy + r.bottom * sy,
      width: r.width * sx, height: r.height * sy });
    const scrollOf = (el) => ({ scrollWidth: el.scrollWidth, scrollHeight: el.scrollHeight,
      clientWidth: el.clientWidth, clientHeight: el.clientHeight,
      overflowX: win.getComputedStyle(el).overflowX, overflowY: win.getComputedStyle(el).overflowY });
    const root = doc.body.querySelector(":scope > .ct-storybook-surface");
    out.doc = {
      theme: doc.documentElement.getAttribute("data-codetracer-theme"),
      viewport, bodyChildren: doc.body.children.length,
      html: scrollOf(doc.documentElement), body: { ...scrollOf(doc.body), box: box(doc.body.getBoundingClientRect()) },
    };
    if (root) {
      const shown = (el) => {
        const cs = win.getComputedStyle(el);
        const b = el.getBoundingClientRect();
        return b.width > 0 && b.height > 0 && cs.visibility !== "hidden" && cs.display !== "none";
      };
      // The layout's outermost boxes (see the header).
      const outer = [];
      const stack = [...root.children];
      while (stack.length) {
        const el = stack.pop();
        if (win.getComputedStyle(el).display === "none") continue;
        if (shown(el)) outer.push(el.getBoundingClientRect());
        else stack.push(...el.children);
      }
      for (const el of root.querySelectorAll("*")) {
        if (win.getComputedStyle(el).position === "fixed" && shown(el)) outer.push(el.getBoundingClientRect());
      }
      if (outer.length) {
        const u = outer.reduce((a, b) => ({ left: Math.min(a.left, b.left), top: Math.min(a.top, b.top),
          right: Math.max(a.right, b.right), bottom: Math.max(a.bottom, b.bottom) }),
          { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity });
        u.width = u.right - u.left;
        u.height = u.bottom - u.top;
        out.root = { box: u, page: toPage(u), css: { width: u.width, height: u.height }, outerBoxes: outer.length,
          visibleElements: [...root.querySelectorAll("*")].filter(shown).length,
          textLength: root.innerText.trim().length };
      }
    }
    return out;
  });
}

const inside = (inner, outer, tol) => inner.left >= outer.left - tol && inner.top >= outer.top - tol &&
  inner.right <= outer.right + tol && inner.bottom <= outer.bottom + tol;
const fmt = (b) => b ? `${b.width.toFixed(1)}x${b.height.toFixed(1)}@(${b.left.toFixed(1)},${b.top.toFixed(1)})` : "none";
const noScroll = (s) => s.scrollWidth <= s.clientWidth && s.scrollHeight <= s.clientHeight;
const sc = (s) => `${s.scrollWidth}x${s.scrollHeight} in ${s.clientWidth}x${s.clientHeight}`;

// The layout is drawn: its wrapper is in the frame's document with text.
async function waitForLayout(page) {
  try {
    await page.waitForFunction(() => {
      const f = document.querySelector("[data-page-project-frame]");
      const root = f?.contentDocument?.body?.querySelector(":scope > .ct-storybook-surface");
      return !!root && root.innerText.trim().length > 0;
    }, null, { timeout: RENDER_TIMEOUT_MS, polling: 250 });
    return true;
  } catch {
    return false;
  }
}

// The zoom has settled: the frame's on-screen box is the same in two reads
// 400 ms apart (the editor measures the area with a resize observer).
async function settle(page) {
  let last = "";
  for (let i = 0; i < 40; i++) {
    const now = await page.evaluate(() => {
      const f = document.querySelector('[data-preview-zoom-frame="true"]');
      const s = f && f.parentElement && f.parentElement.parentElement;
      return f ? JSON.stringify([f.getBoundingClientRect(), s && s.clientWidth, s && s.clientHeight]) : "";
    });
    if (now && now === last) return;
    last = now;
    await page.waitForTimeout(400);
  }
}

function checkLayoutGeometry(m) {
  // Shared by both phases: the frame's document overflows nothing, and the
  // layout's extent lies inside the frame's viewport.
  const d = m.doc;
  const r = m.root;
  const viewportBox = { left: 0, top: 0, right: d.viewport.width, bottom: d.viewport.height };
  const unclipped = noScroll(d.html) && noScroll(d.body) && inside(r.box, viewportBox, 0.5);
  const detail = `html ${sc(d.html)}, body ${sc(d.body)}, ` +
    `layout extent ${fmt(r.box)} (${r.outerBoxes} outer boxes), frame viewport ${d.viewport.width}x${d.viewport.height}`;
  return { unclipped, detail };
}

// A screenshot for a reader. Playwright waits for the page's fonts first; a
// capture that cannot be taken is reported, and the measurements stand. The
// 120 s timeout has the same reason as the 100% click's below: with a layout
// mounted, the editor's main thread was measured drawing one frame in 5 to 6 s,
// and a capture waits for frames.
async function screenshot(page, path) {
  try {
    await page.screenshot({ path, timeout: 120000 });
  } catch (error) {
    console.log(`NOTE no screenshot ${path}: ${String(error.message).split("\n")[0]}`);
  }
}

async function runLayout(page, story, theme) {
  const label = `${story.name} [${theme}]`;
  const summary = { layout: label, id: story.id, theme };
  const shot = (zoom) => join(outDir, `l-${story.number}-${zoom}-${theme}.png`);

  await page.goto(storyUrl(story, "fit", theme), { waitUntil: "domcontentloaded" });
  await page.locator('[data-preview-zoom-cluster="true"]').waitFor({ state: "attached", timeout: 60000 });
  const rendered = await waitForLayout(page);
  await settle(page);
  const fit = await measure(page);
  summary.fit = fit;
  await screenshot(page, shot("fit"));

  if (fit.missing) {
    check(`${label}: the page preview has its zoom frame`, false, JSON.stringify(fit.missing));
    return summary;
  }
  const d = fit.doc;
  summary.rendered = check(`${label}: renders`, rendered && fit.root && fit.root.visibleElements >= 10 && fit.root.textLength >= 20,
    fit.root ? `layout extent ${fmt(fit.root.box)}, ${fit.root.visibleElements} visible elements, ${fit.root.textLength} chars of text`
      : `no layout in the preview frame's document (<body> has ${d ? d.bodyChildren : "no document"} element children)`);

  check(`${label}: theme`, d && d.theme === theme, `frame document theme ${d ? d.theme : "none"}`);

  // fit.level
  const area = fit.host.client;
  const expected = Math.min(1, area.width / FRAME.width, area.height / FRAME.height);
  const scaleX = fit.frame.width / FRAME.width;
  const scaleY = fit.frame.height / FRAME.height;
  const pct = `${Math.round(expected * 100)}%`;
  summary.fitLevel = check(`${label}: fit.level`,
    /(^|[?&])zoom=fit(&|$)/.test(fit.url) && /(^|[?&])viewport=wide(&|$)/.test(fit.url) &&
      fit.frameCss.width === FRAME.width && fit.frameCss.height === FRAME.height &&
      Math.abs(scaleX - expected) <= LEVEL_TOLERANCE && Math.abs(scaleY - expected) <= LEVEL_TOLERANCE &&
      fit.readout === pct,
    `area ${area.width}x${area.height}, expected ${expected.toFixed(4)} (${pct}), frame ${fmt(fit.frame)} ` +
      `= ${scaleX.toFixed(4)} x ${scaleY.toFixed(4)}, readout ${fit.readout}, frame CSS ${fit.frameCss.width}x${fit.frameCss.height}`);

  // fit.frame
  const widthBound = area.width / FRAME.width <= area.height / FRAME.height;
  const touches = widthBound ? Math.abs(fit.frame.width - area.width) <= PX : Math.abs(fit.frame.height - area.height) <= PX;
  summary.fitFrame = check(`${label}: fit.frame`,
    inside(fit.frame, area, 0.5) && touches &&
      fit.host.scrollWidth <= area.width && fit.host.scrollHeight <= area.height,
    `frame ${fmt(fit.frame)} in area ${fmt(area)}, touches the ${widthBound ? "width" : "height"}: ${touches}, ` +
      `area scroll ${fit.host.scrollWidth}x${fit.host.scrollHeight}`);

  // fit.layout and fit.fills need the layout.
  if (summary.rendered) {
    const g = checkLayoutGeometry(fit);
    const onScreen = inside(fit.root.page, area, 0.5);
    summary.fitLayout = check(`${label}: fit.layout`, g.unclipped && onScreen,
      `${g.detail}; on screen ${fmt(fit.root.page)} in area ${fmt(area)}`);
    summary.fitFills = check(`${label}: fit.fills`,
      Math.abs(fit.root.box.width - d.viewport.width) <= PX && Math.abs(fit.root.box.height - d.viewport.height) <= PX,
      `layout extent ${fit.root.box.width.toFixed(1)}x${fit.root.box.height.toFixed(1)}, frame viewport ${d.viewport.width}x${d.viewport.height}`);
  } else {
    check(`${label}: fit.layout`, false, "not measurable: the layout did not render");
    check(`${label}: fit.fills`, false, "not measurable: the layout did not render");
  }

  // 100%
  // Generous: with a layout of 2,500+ elements in the frame the editor's main
  // thread was measured drawing one frame in 5 to 6 s on this kind of host, and
  // a click waits for the button to be stable across frames.
  await page.locator('[aria-label="Show preview at 100%"]').click({ timeout: 120000 });
  try {
    await page.waitForFunction(() => /(^|[?&])zoom=100(&|$)/.test(location.search), null, { timeout: 30000 });
  } catch { /* checked below */ }
  await settle(page);
  const full = await measure(page);
  summary.full = full;
  await screenshot(page, shot("100"));

  summary.fullLevel = check(`${label}: 100.level`,
    /(^|[?&])zoom=100(&|$)/.test(full.url) && full.readout === "100%" &&
      Math.abs(full.frame.width - FRAME.width) <= PX && Math.abs(full.frame.height - FRAME.height) <= PX,
    `readout ${full.readout}, frame ${fmt(full.frame)}, URL ${/(zoom=[^&]*)/.exec(full.url)?.[1]}`);

  if (summary.rendered && full.root && fit.root) {
    const g = checkLayoutGeometry(full);
    const sameAsFit = Math.abs(full.root.css.width - fit.root.css.width) <= PX &&
      Math.abs(full.root.css.height - fit.root.css.height) <= PX;
    const unscaled = Math.abs(full.root.page.width - full.root.css.width) <= PX &&
      Math.abs(full.root.page.height - full.root.css.height) <= PX;
    summary.fullNatural = check(`${label}: 100.natural`, g.unclipped && sameAsFit && unscaled,
      `layout extent on screen ${full.root.page.width.toFixed(1)}x${full.root.page.height.toFixed(1)}, ` +
        `CSS ${full.root.css.width.toFixed(1)}x${full.root.css.height.toFixed(1)} ` +
        `(at Fit ${fit.root.css.width.toFixed(1)}x${fit.root.css.height.toFixed(1)}); ${g.detail}`);
  } else {
    check(`${label}: 100.natural`, false, "not measurable: the layout did not render");
  }

  const h = full.host;
  const needX = FRAME.width > h.client.width;
  const needY = FRAME.height > h.client.height;
  const scrollsX = h.scrollWidth > h.client.width;
  const scrollsY = h.scrollHeight > h.client.height;
  summary.fullScroll = check(`${label}: 100.scroll`,
    (needX || needY) && (!needX || (scrollsX && h.overflowX === "auto" && h.hGutter > 0)) &&
      (!needY || (scrollsY && h.overflowY === "auto" && h.vGutter > 0)),
    `area client ${h.client.width}x${h.client.height}, scroll ${h.scrollWidth}x${h.scrollHeight}, ` +
      `overflow ${h.overflowX}/${h.overflowY}, scrollbars: vertical ${h.vGutter}px, horizontal ${h.hGutter}px`);
  return summary;
}

async function main() {
  mkdirSync(outDir, { recursive: true });
  const layouts = layoutStories();
  const numbers = layouts.map((l) => l.number);
  check("stories.json declares the layouts L1 to L14",
    JSON.stringify(numbers) === JSON.stringify([...Array(14)].map((_, i) => i + 1)),
    `found ${numbers.join(", ")}`);

  const browser = await chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
  const context = await browser.newContext({ viewport: WINDOW });
  const page = await context.newPage();
  const consoleLines = [];
  page.on("console", (msg) => consoleLines.push(`[${msg.type()}] ${msg.text()}`));
  page.on("pageerror", (error) => consoleLines.push(`[pageerror] ${error.message}`));
  const summaries = [];
  try {
    for (const theme of THEMES) {
      for (const story of layouts) {
        try {
          summaries.push(await runLayout(page, story, theme));
        } catch (error) {
          check(`${story.name} [${theme}]: completed`, false, error.stack ?? String(error));
          await page.screenshot({ path: join(outDir, `l-${story.number}-failure-${theme}.png`) }).catch(() => {});
        }
      }
    }
  } finally {
    writeFileSync(join(outDir, "browser-console.log"), consoleLines.join("\n") + "\n");
    writeFileSync(join(outDir, "results.json"), JSON.stringify(results, null, 2) + "\n");
    writeFileSync(join(outDir, "measurements.json"), JSON.stringify(summaries, null, 2) + "\n");
    await browser.close();
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`${TEST_NAME}: ${results.length - failed.length}/${results.length} checks passed`);
  process.exit(failed.length === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
