// editor_resize_follows_pane_probe.mjs — does the Monaco editor follow its
// pane when the pane is resized, in BOTH modes and BOTH directions?
//
// Reported against noirstudio.dev: "Resizing the panel that holds the Monaco
// editor doesn't seem to resize the actual editor. The scrollbar stays in
// place. This is in debug mode."
//
// THIS PROBE ASSERTS NOTHING. It drags a real GoldenLayout splitter with the
// mouse, samples geometry around each drag, and prints one JSON report. The
// paired `ci/test/editor-resize-follows-pane.sh` counts the assertions over
// that JSON — the convention every gate in this directory follows, so that a
// probe crash is a missing report rather than a silent pass.
//
// WHAT IS MEASURED, AND WHY IT IS THE EDITOR'S OWN BOX. The claim under test
// is not "a layout function was called" — it is that the editor's rendered
// geometry tracks the pane's. So every sample reads
// `getBoundingClientRect()` off Monaco's own nodes and off the pane, at the
// same instant, and the report carries both. A check that only watched for a
// `layout()` call would have passed on the broken build: `layout()` WAS being
// called, with the right numbers, once, at adoption.
//
// THE SCROLLBAR IS SAMPLED SEPARATELY because it is what the user perceives.
// "The scrollbar stays in place" is the report's own wording, and Monaco's
// vertical scrollbar is positioned from the same layout info that sizes the
// view — so it is a second, independent reading of the same failure.
//
// THE 5x5 GUARD. `Math.max(5, ...)` in Monaco's `ElementSizeObserver`
// (`browser/config/elementSizeObserver.js`) is where a zero measurement turns
// into a five-pixel editor, and a 5x5 editor inside an 880x902 pane is the
// regression a previous fix in this area left behind. Every sample therefore
// records the raw box so the shell gate can refuse it, in both modes. Fixing
// the resize by re-introducing the clamp is not a fix.

import { chromium } from 'playwright';
import { writeFileSync } from 'node:fs';

const url = process.argv[2];
const outPath = process.argv[3];
const settleMs = Number(process.argv[4] || 1200);

if (!url || !outPath) {
  console.error('usage: editor_resize_follows_pane_probe.mjs <url> <out.json> [settleMs]');
  process.exit(2);
}

const report = {
  url,
  consoleErrors: [],
  pageErrors: [],
  legs: {},
};

const settle = (page, ms = settleMs) => page.waitForTimeout(ms);

// Two animation frames, then a beat. A ResizeObserver callback is delivered
// before paint, and Monaco re-lays out inside it, so a single frame can sample
// a box that is about to change.
const frames = (page) =>
  page.evaluate(() => new Promise((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(() => resolve(true)))));

// ---------------------------------------------------------------------------
// The reader.
// ---------------------------------------------------------------------------
//
// THE EDITOR IS TAKEN FROM THE PRODUCT, not from `monaco.editor.getEditors()`.
// That array also holds the tracepoint editors and the inline diff editors,
// and its order is creation order — `[0]` is not "the file the user is
// looking at". `data.ui.editors[data.services.editor.active]` is what the
// product itself considers active, and the fallback is recorded in the report
// so a run that had to guess says so.
const measureScript = () => {
  const rect = (el) => {
    if (!el) return null;
    const b = el.getBoundingClientRect();
    return {
      w: Math.round(b.width), h: Math.round(b.height),
      x: Math.round(b.x), right: Math.round(b.right),
    };
  };

  const d = window.data;
  let m = null;
  let via = 'none';
  try {
    const active = d && d.services && d.services.editor ? d.services.editor.active : null;
    const ed = (d && d.ui && d.ui.editors && active != null) ? d.ui.editors[active] : null;
    if (ed && ed.monacoEditor) { m = ed.monacoEditor; via = 'active'; }
  } catch (e) { /* falls through to the getEditors() route below */ }
  if (!m && window.monaco && monaco.editor.getEditors().length > 0) {
    m = monaco.editor.getEditors()[0];
    via = 'getEditors[0]';
  }
  if (!m) return { ok: false, reason: 'no monaco editor on the page', via };

  // Monaco has TWO roots and they are not interchangeable here:
  //   getContainerDomNode() -> the node handed to monaco.editor.create, which
  //       is what `automaticLayout`'s ResizeObserver watches;
  //   getDomNode()          -> the inner `.monaco-editor` view node, which
  //       Monaco sizes with inline pixels.
  // Both are reported, with their connectedness, because the defect this gate
  // exists for was precisely the two coming apart.
  const view = m.getDomNode ? m.getDomNode() : null;
  const container = m.getContainerDomNode ? m.getContainerDomNode() : null;

  // THE PANE IS FOUND FROM THE VIEW, NOT FROM THE CONTAINER. On the broken
  // build the container is DETACHED, so `container.closest('.lm_content')`
  // either finds nothing or finds the dead pane it was detached with — and a
  // detached element measures 0x0. Reading the pane through it reported
  // "pane 0 -> 0", which made the editor look like it was tracking a pane that
  // never moved: the vacuous pass this gate exists to avoid. The view node is
  // in the live document in both builds, so the pane reached through it is the
  // one on screen.
  const host = view ? view.closest('.lm_content') : null;

  let li = null;
  try {
    const info = m.getLayoutInfo();
    li = { w: Math.round(info.width), h: Math.round(info.height) };
  } catch (e) { /* reported as null */ }

  // THE RIGHT-EDGE FURNITURE — "the scrollbar stays in place" is the report's
  // own wording, and it is a second reading of the failure that is independent
  // of the editor's own box.
  //
  // WHICH ELEMENT IS CHOSEN AT RUNTIME, and the choice is reported. Monaco only
  // gives the vertical scrollbar a box when the content actually overflows
  // vertically, and the file this gate opens is 22 lines in a 902px editor — so
  // a hard-coded `.scrollbar.vertical` measured 0x0 in every leg and the check
  // compared two zeroes and passed. A subject with no geometry is not a
  // subject. The first candidate that HAS a box is used, and the gate is told
  // which one, so a run can never quietly assert on nothing.
  const candidates = [
    ['overviewRuler', '.decorationsOverviewRuler'],
    ['verticalScrollbar', '.scrollbar.vertical'],
    ['horizontalScrollbar', '.scrollbar.horizontal'],
  ];
  const furniture = {};
  let rightEdge = null;
  let rightEdgeName = 'none';
  for (const [name, sel] of candidates) {
    const el = view ? view.querySelector(sel) : null;
    const r = rect(el);
    furniture[name] = r;
    if (!rightEdge && r && r.w > 0 && r.h > 0) { rightEdge = r; rightEdgeName = name; }
  }

  return {
    ok: true,
    via,
    pane: rect(host),
    view: rect(view),
    container: rect(container),
    viewConnected: view ? view.isConnected : null,
    // The view is what the re-host moves, so it is what must be live and in
    // the pane on screen.
    viewInPane: !!(view && host && host.contains(view)),
    // REPORTED, NOT ASSERTED, and it is the root cause in one field. After the
    // re-host that entering debug mode performs, Monaco's own `_domElement` —
    // the element `automaticLayout`'s ResizeObserver watches, and the only one
    // it will ever watch — is left detached. Measured: `true` in edit mode,
    // `false` in debug mode, in the same session.
    containerConnected: container ? container.isConnected : null,
    layoutInfo: li,
    furniture,
    rightEdge,
    rightEdgeName,
    viewLines: document.querySelectorAll('.view-line').length,
  };
};

const measure = async (page) => { await frames(page); return page.evaluate(measureScript); };

// ---------------------------------------------------------------------------
// The gesture: a real pointer drag of a real GoldenLayout splitter.
// ---------------------------------------------------------------------------
//
// NOT `layout.updateSize()` and not `setViewportSize()`. Both change the
// editor's size through code paths a user never takes, and the product has a
// programmatic relayout (`editor-pane.ts` uses it) that would mask exactly the
// failure under test. The user drags the divider, so the probe drags it.
//
// `.lm_splitter` without `.lm_vertical` is the column splitter (`cursor:
// col-resize` in `styles/components/golden_layout.styl`) — the one that
// changes the editor pane's WIDTH.
async function dragSplitter(page, dx) {
  const geo = await page.evaluate(() => {
    // THE SPLITTER MUST BE ONE THAT BOUNDS THE EDITOR'S OWN PANE.
    //
    // The first shape of this took `document.querySelector('.lm_splitter')`.
    // In Edit mode that happens to be the divider beside the editor; in Debug
    // mode the layout has more panes and the first splitter divides two of
    // them instead, so the drag moved a pane the editor is not in and the leg
    // reported "pane Δ0" — the editor trivially "followed" a pane that never
    // moved. The gesture has to land on the divider a user would grab to
    // widen THIS editor.
    const view = (() => {
      const d = window.data;
      const active = d && d.services && d.services.editor ? d.services.editor.active : null;
      const ed = (d && d.ui && d.ui.editors && active != null) ? d.ui.editors[active] : null;
      const m = (ed && ed.monacoEditor) ||
        ((window.monaco && monaco.editor.getEditors()[0]) || null);
      return m && m.getDomNode ? m.getDomNode() : null;
    })();
    const pane = view ? view.closest('.lm_content') : null;
    if (!pane) return null;
    const p = pane.getBoundingClientRect();

    const columns = [...document.querySelectorAll('.lm_splitter:not(.lm_vertical)')];
    if (columns.length === 0) return null;

    // Nearest column splitter to either vertical edge of the pane, and which
    // edge it is — reported, because the sign of the pane's response depends
    // on it and a leg that grabbed the wrong divider should be legible.
    let best = null;
    for (const s of columns) {
      const b = s.getBoundingClientRect();
      const cx = b.x + b.width / 2;
      const dRight = Math.abs(cx - p.right);
      const dLeft = Math.abs(cx - p.x);
      const edge = dRight <= dLeft ? 'right' : 'left';
      const dist = Math.min(dRight, dLeft);
      if (!best || dist < best.dist) {
        best = { dist, edge, x: cx, y: b.y + b.height / 2, w: b.width, h: b.height };
      }
    }
    if (!best) return null;
    return { ...best, pane: { x: Math.round(p.x), right: Math.round(p.right), w: Math.round(p.width) },
             columns: columns.length };
  });
  if (!geo) return { dragged: false, reason: 'no column splitter bounding the editor pane' };
  // A divider that is nowhere near the pane would move some other pane.
  if (geo.dist > 40) {
    return { dragged: false, reason: `nearest column splitter is ${Math.round(geo.dist)}px from the editor pane's edges`, geo };
  }

  await page.mouse.move(geo.x, geo.y);
  await page.mouse.down();
  // In steps: GoldenLayout installs its drag listener on the first move after
  // mousedown, and a single jump can be delivered before that listener exists.
  await page.mouse.move(geo.x + dx, geo.y, { steps: 16 });
  await page.mouse.up();
  await settle(page);
  return { dragged: true, at: geo, dx };
}

// One direction of one mode: sample, drag, sample.
async function resizeLeg(page, dx) {
  const before = await measure(page);
  const drag = await dragSplitter(page, dx);
  const after = await measure(page);
  return { dx, drag, before, after };
}

// ---------------------------------------------------------------------------
// Reaching Debug mode, the way a user does.
// ---------------------------------------------------------------------------
//
// `Ctrl+Enter` is the product's Run chord. The topbar is clicked first to move
// focus out of Monaco's textarea, because Mousetrap's default `stopCallback`
// drops a chord raised inside one. This is spelled the same way as
// `ci/test/editor_context_menu_modes_probe.mjs` on purpose.
async function runToDebugMode(page) {
  try {
    await page.click('#menu', { position: { x: 5, y: 5 }, timeout: 3000 });
  } catch (e) { /* a missing topbar surfaces as a failure to reach a session */ }
  await page.keyboard.press('Control+Enter');

  // A first Run fetches ~16 MB of compiler and ~4.6 MB of tracer, compiles,
  // traces, then fetches the engine and instantiates it.
  const deadline = Date.now() + 240000;
  const read = () => page.evaluate(() => ({
    mode: (window.data && window.data.ui) ? Number(window.data.ui.mode) : null,
    controls: !!document.querySelector('#next-image'),
    lines: document.querySelectorAll('.view-line').length,
  }));
  while (Date.now() < deadline) {
    const s = await read();
    if (s.mode === 0 && s.controls && s.lines > 0) return { reached: true, state: s };
    await page.waitForTimeout(500);
  }
  const s = await read();
  return {
    reached: false,
    state: s,
    reason: `Run did not reach a replay session with source on screen within 240s `
      + `(mode=${s.mode} debugControls=${s.controls} viewLines=${s.lines}) — are the `
      + `Noir wasm modules and the replay engine in this bundle?`,
  };
}

(async () => {
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1600, height: 1000 } });
  const page = await context.newPage();
  page.on('pageerror', (e) => report.pageErrors.push(String(e.message).slice(0, 300)));
  page.on('console', (m) => {
    if (m.type() === 'error') report.consoleErrors.push(m.text().slice(0, 300));
  });

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForSelector('.lm_goldenlayout', { timeout: 90000 });
    await page.waitForSelector('.view-line', { timeout: 120000 });
    await settle(page, 2500);

    report.splitters = await page.evaluate(() => ({
      all: document.querySelectorAll('.lm_splitter').length,
      column: document.querySelectorAll('.lm_splitter:not(.lm_vertical)').length,
    }));

    // ---- EDIT MODE. The control arm: this is the mode that works today, and
    // it must keep working. A fix that made Debug follow by breaking Edit is
    // not a fix.
    report.legs.editBoot = await measure(page);
    report.legs.editGrow = await resizeLeg(page, 180);
    report.legs.editShrink = await resizeLeg(page, -180);

    // ---- DEBUG MODE. The reported case.
    report.run = await runToDebugMode(page);
    if (report.run.reached) {
      await settle(page, 2500);
      await page.screenshot({ path: outPath.replace(/\.json$/, '-debug-before.png') });
      report.legs.debugBoot = await measure(page);
      report.legs.debugGrow = await resizeLeg(page, 180);
      await page.screenshot({ path: outPath.replace(/\.json$/, '-debug-grown.png') });
      report.legs.debugShrink = await resizeLeg(page, -180);
      await page.screenshot({ path: outPath.replace(/\.json$/, '-debug-shrunk.png') });
    }
  } catch (e) {
    report.fatal = String((e && e.stack) || e).slice(0, 1200);
  } finally {
    try { writeFileSync(outPath, JSON.stringify(report, null, 2)); } catch (e) { /* nothing left to do */ }
    await browser.close();
  }
})();
