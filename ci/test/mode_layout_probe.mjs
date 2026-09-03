// mode_layout_probe.mjs — ONE LAYOUT PER MODE, measured as RENDERED GEOMETRY
// in a real browser tab, across mode switches and across a reload.
//
// WHAT THIS ASSERTS THAT THE MODEL TEST CANNOT
// -------------------------------------------
// `src/tests/gui/tests/layout/mode_layout_test.nim` exercises the layout MODEL
// — the per-mode tables, the placement engine, and their composition over the
// real bundled config. Every assertion in it can hold of a product whose
// workspace looks wrong, because a layout config is not a workspace:
// GoldenLayout still has to accept it, build the stacks, and give each pane a
// box on the screen.
//
// So nothing here reads a config. Every assertion is over
// `getBoundingClientRect()` of a mounted pane, or over the tab strip the panes
// are actually in. That choice is not stylistic — every defect in this
// product's recent layout work was invisible to markup assertions. Ids,
// labels and element counts were all correct while the surface was visibly
// wrong, and a pane exiled at zero width satisfies a presence check exactly as
// a working one does. `document.querySelector('#constraintsComponent-0')`
// returning an element proves nothing at all.
//
// THE THREE QUESTIONS, and each is a sentence from the request
// ------------------------------------------------------------
//   1. Does a mode switch CHANGE the layout? Before this work it did not — the
//      previous mode's arrangement was carried across, which is what the
//      report is about.
//   2. Are TEST RESULTS and CONSTRAINTS *tabs of* the stacks the request named
//      (FILES in both modes; the EVENT LOG in debug mode), rather than panes
//      of their own? Asked by comparing the boxes of the stack headers, not by
//      reading the layout config the page was handed.
//   3. Does an arrangement SURVIVE A RELOAD? This is the half of the request
//      most likely to be quietly missing — a layout that applies on switch and
//      resets on reload satisfies the letter and fails the ask — so the probe
//      reloads and re-measures rather than trusting the switch.
//
// AND ONE MORE, which is a hard requirement rather than a nicety: what does a
// user get when the saved layout cannot be loaded? Arm D writes deliberate
// rubbish into the store and asserts the workspace comes back with PANES IN IT
// and a visible notice. Layout persistence has already produced a workspace
// that came back empty here; "degrades to a sensible default, loudly" is the
// property, and it is measured rather than asserted in a comment.
//
// Usage: node ci/test/mode_layout_probe.mjs <url> <out.json>

import { chromium } from 'playwright';

const url = process.argv[2];
const outPath = process.argv[3];
if (!url || !outPath) {
  console.error('usage: mode_layout_probe.mjs <url> <out.json>');
  process.exit(2);
}

const report = {
  url,
  pageErrors: [],
  consoleErrors: [],
  legs: [],
  arms: {},
};

// ---------------------------------------------------------------------------
// The measurement. RECTANGLES, and the stack each pane is in.
// ---------------------------------------------------------------------------
//
// `paneBox` reports the rect of the pane's own mount container. `stackOf`
// walks up to the enclosing `.lm_stack` and reports the ids of every tab in
// it, which is how "nested under the same pane that holds FILES" is asked:
// two panes are nested together exactly when they share a stack.
const measureScript = () => {
  const rect = (el) => {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return {
      x: Math.round(r.x * 10) / 10,
      y: Math.round(r.y * 10) / 10,
      w: Math.round(r.width * 10) / 10,
      h: Math.round(r.height * 10) / 10,
    };
  };

  // PANES ARE ADDRESSED BY THE TITLE ON THEIR TAB, not by a DOM id.
  //
  // Two reasons, and the second is the one that decides it. The mount
  // container's id is `<content>Component-<id>` and one of the four subjects
  // does not reliably have one — the Filesystem panel has a legacy unkeyed
  // fallback mount (`ui/filesystem.nim`), so `#filesystemComponent-0` is
  // absent on the very surface this probe measures, and a probe keyed on it
  // reports "no FILES pane" about a window with FILES plainly on screen.
  //
  // The deciding reason is that the REQUEST is phrased in tab titles: "nested
  // under the same pane that holds the FILES". Two panes are nested together
  // exactly when their tabs are in one strip, which is a question about the
  // rendered header — so it is asked there, of the same text the user reads.
  const stripOf = (title) => {
    const tabs = Array.from(document.querySelectorAll('.lm_tab'));
    const tab = tabs.find((t) => {
      const el = t.querySelector('.lm_title');
      return ((el ? el.textContent : t.textContent) || '').trim() === title;
    });
    if (!tab) return { present: false };
    const stack = tab.closest('.lm_stack');
    const header = stack ? stack.querySelector('.lm_header') : null;
    const strip = header ? header.querySelector('.lm_tabs') : null;
    const siblings = strip
      ? Array.from(strip.querySelectorAll('.lm_tab')).map((t) => {
          const el = t.querySelector('.lm_title');
          return ((el ? el.textContent : t.textContent) || '').trim();
        })
      : [];
    // A pane GoldenLayout has parked in the overflow dropdown is in the DOM,
    // has an id, and cannot be reached by a user. `display:none` on the list
    // is how that state looks, and it is the state the tab-strip work fixed.
    const dropdown = stack ? stack.querySelector('.lm_tabdropdown_list') : null;
    const exiled = dropdown
      ? Array.from(dropdown.querySelectorAll('.lm_title'))
          .map((t) => (t.textContent || '').trim())
      : [];
    return {
      present: true,
      tabBox: rect(tab),
      stackBox: rect(stack),
      headerBox: rect(header),
      // The identity a "same stack?" question needs. Assigned per measurement
      // rather than read from the DOM, because GoldenLayout gives stacks no
      // stable attribute of their own.
      stackKey: stack ? siblings.join(' | ') : null,
      siblings,
      exiled,
    };
  };

  const subjects = ['FILES', 'VCS', 'TEST RESULTS', 'CONSTRAINTS', 'EVENT LOG',
                    'STATE', 'CALL TRACE'];
  const strips = {};
  for (const title of subjects) strips[title] = stripOf(title);

  // THE TOP-LEVEL COLUMNS. "A standing pane for CONSTRAINTS" is, geometrically,
  // an extra child of the ground row with a box of its own.
  const root = document.querySelector('.lm_goldenlayout');
  const ground = root ? root.querySelector(':scope > .lm_item') : null;
  const topLevelChildren = ground
    ? Array.from(ground.children)
        .filter((c) => c.classList && (c.classList.contains('lm_item') ||
          c.classList.contains('lm_stack') || c.classList.contains('lm_column') ||
          c.classList.contains('lm_row')))
        .map((c) => rect(c))
    : [];

  // THE PANE'S OWN CONTENT BOX, which is a different question from its tab's.
  //
  // THIS MEASUREMENT EXISTS BECAUSE ITS ABSENCE SHIPPED A BROKEN DEPLOY. The
  // strips above answer "is this pane nested with that one", which is what the
  // request was phrased in, and every leg of this probe was green while the
  // pre-publish mount gate refused to publish: it measures the PANE elements,
  // and a nested pane is a background tab, so its content box is 0 and its
  // controls take no click. `19.8 54.4 0` where the layout declares 20/55/25.
  //
  // A tab in the strip is reachable in one gesture; a pane behind it is not
  // RENDERED. Both facts are true at once and only one of them was measured.
  const contentBoxes = (() => {
    const w = window.innerWidth || 1;
    const pct = (sel) => {
      const e = document.querySelector(sel);
      // `null` means NOT FOUND and `{w: 0}` means found-and-not-rendered, and
      // conflating them is how this measurement would fail the way the strips
      // did. Zero is the defect; absent is a selector that does not resolve on
      // this leg, which several do not once a mode switch has remounted the
      // IsoNim panels. Only the routes that mount from scratch — boot and
      // reload, which are the routes the pre-publish gate covers — are
      // expected to answer for every pane.
      if (!e) return null;
      const r = e.getBoundingClientRect();
      return {
        w: Math.round(r.width * 10) / 10,
        h: Math.round(r.height * 10) / 10,
        // The share of the window, which is the unit the mount gate's §1a
        // proportion check is written in, so the two are comparable.
        pct: Math.round((r.width / w) * 1000) / 10,
      };
    };
    return {
      // The same selectors `ci/test/web_renderer_probe.mjs` reads, deliberately
      // — a second spelling of "the Test Results pane" is a second thing to
      // keep in step, and the point is to fail where that gate fails.
      filesystem: pct('.filesystem-container'),
      editor: pct('.monaco-editor'),
      testResults: pct('.test-results'),
      constraints: pct('.constraints-container, [class*="constraints"]'),
    };
  })();

  const panelRoot = document.querySelector('[data-topbar-surface]');

  return {
    goldenLayoutPresent: !!root,
    goldenLayoutBox: rect(root),
    topLevelChildren,
    contentBoxes,
    stackCount: document.querySelectorAll('.lm_stack').length,
    topbarSurface: panelRoot ? panelRoot.getAttribute('data-topbar-surface') : null,
    mode: (window.data && window.data.ui) ? String(window.data.ui.mode) : null,
    strips,
    allTabTitles: Array.from(document.querySelectorAll('.lm_tab .lm_title'))
      .map((t) => (t.textContent || '').trim()),
    // The editor is the pane a user loses if a layout swap goes wrong, and
    // `Mode-Transitions.md` §7 requires it never to be empty. Measured, not
    // counted: `.view-line` is Monaco's rendered text.
    editorLines: document.querySelectorAll('.view-line').length,
    notifications: Array.from(
      document.querySelectorAll('[class*="notification"]'),
    ).map((n) => (n.textContent || '').trim()).filter((t) => t.length > 0)
     .map((t) => t.slice(0, 240)),
    storeKeys: (() => {
      try {
        return Object.keys(localStorage)
          .filter((k) => k.startsWith('CODETRACER_MODE_LAYOUT_'))
          .map((k) => ({ key: k, bytes: (localStorage.getItem(k) || '').length }));
      } catch (e) { return [{ key: '<localStorage unavailable>', bytes: 0 }]; }
    })(),
  };
};

async function measure(page, label) {
  let snap;
  try {
    snap = await page.evaluate(measureScript);
  } catch (e) {
    snap = { readError: String((e && e.message) || e).slice(0, 300) };
  }
  snap.leg = label;
  report.legs.push(snap);
  return snap;
}

// The mode toggle, through the product's own bound action rather than a
// synthesised keypress: `ctrl+f5` reaches `ClientAction.switchEdit` /
// `switchDebug` through the config, and driving the ACTION keeps this probe
// measuring the layout rather than the keymap (which has its own gates).
async function toggleMode(page, want) {
  return page.evaluate((wanted) => {
    const d = window.data;
    if (!d) return 'no data';
    try {
      if (wanted === 'debug') d.functions.switchToDebug(d);
      else d.functions.switchToEdit(d);
      return 'ok';
    } catch (e) {
      return 'threw: ' + String((e && e.message) || e).slice(0, 200);
    }
  }, want);
}

const settle = (page, ms = 700) => page.waitForTimeout(ms);

(async () => {
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1600, height: 1000 } });
  const page = await context.newPage();

  page.on('pageerror', (e) => report.pageErrors.push(String(e.message).slice(0, 300)));
  page.on('console', (m) => {
    if (m.type() === 'error') report.consoleErrors.push(m.text().slice(0, 300));
  });

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 120000 });
    // The workspace has to exist before anything about it can be measured. A
    // probe that measured a page still booting would report "no panes" as a
    // layout defect.
    await page.waitForSelector('.lm_goldenlayout', { timeout: 120000 });
    await page.waitForFunction(
      () => Array.from(document.querySelectorAll('.lm_tab .lm_title'))
        .some((t) => (t.textContent || '').trim() === 'FILES'),
      null, { timeout: 120000 });
    await settle(page, 2500);

    report.arms.bootMode = await page.evaluate(() =>
      (window.data && window.data.ui) ? String(window.data.ui.mode) : 'unknown');

    // ---- leg 1: the mode the tab boots into -----------------------------
    await measure(page, 'boot');

    // ---- leg 2: switch to DEBUG -----------------------------------------
    report.arms.toDebug = await toggleMode(page, 'debug');
    await settle(page);
    await measure(page, 'debug');
    await page.screenshot({ path: outPath.replace(/\.json$/, '-debug.png'), fullPage: false });

    // ---- leg 3: back to EDIT --------------------------------------------
    report.arms.toEdit = await toggleMode(page, 'edit');
    await settle(page);
    await measure(page, 'edit');
    await page.screenshot({ path: outPath.replace(/\.json$/, '-edit.png'), fullPage: false });

    // ---- legs 4-7: two more round trips ---------------------------------
    //
    // `Mode-Transitions.md` §6: "the check needs at least three, because the
    // failure mode is a slot that is right once and empty afterwards". The
    // shell compares trip 3 against trip 1.
    for (const trip of [2, 3]) {
      await toggleMode(page, 'debug');
      await settle(page);
      await measure(page, `debug-trip${trip}`);
      await toggleMode(page, 'edit');
      await settle(page);
      await measure(page, `edit-trip${trip}`);
    }

    // ---- arm P: PERSISTENCE ---------------------------------------------
    //
    // Rearrange something in the CURRENT mode, then reload, and see whether it
    // came back. The rearrangement is a splitter drag rather than a synthetic
    // config write, because a config written by the probe would prove the
    // store works and say nothing about whether the product ever fills it.
    report.arms.storedBeforeReload = await page.evaluate(() => {
      try {
        const out = {};
        for (const k of Object.keys(localStorage)) {
          if (k.startsWith('CODETRACER_MODE_LAYOUT_')) out[k] = localStorage.getItem(k).length;
        }
        return out;
      } catch (e) { return { error: String(e) }; }
    });

    // Widen the FILES column by dragging the splitter beside it.
    const dragged = await (async () => {
      const filesStackWidth = () => {
        const tab = Array.from(document.querySelectorAll('.lm_tab')).find((t) => {
          const el = t.querySelector('.lm_title');
          return ((el ? el.textContent : '') || '').trim() === 'FILES';
        });
        const s = tab ? tab.closest('.lm_stack') : null;
        return s ? Math.round(s.getBoundingClientRect().width * 10) / 10 : null;
      };
      const before = await page.evaluate(filesStackWidth);
      const splitter = await page.$('.lm_splitter');
      if (!splitter || before === null) return { ok: false, reason: 'no splitter or no FILES stack' };
      const box = await splitter.boundingBox();
      if (!box) return { ok: false, reason: 'splitter has no box' };
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.mouse.down();
      await page.mouse.move(box.x + box.width / 2 + 160, box.y + box.height / 2, { steps: 12 });
      await page.mouse.up();
      await settle(page, 1200);
      const after = await page.evaluate(filesStackWidth);
      return { ok: true, before, after, moved: after !== null && Math.abs(after - before) > 8 };
    })();
    report.arms.drag = dragged;

    report.arms.storedAfterDrag = await page.evaluate(() => {
      try {
        const out = {};
        for (const k of Object.keys(localStorage)) {
          if (k.startsWith('CODETRACER_MODE_LAYOUT_')) out[k] = localStorage.getItem(k).length;
        }
        return out;
      } catch (e) { return { error: String(e) }; }
    });

    await measure(page, 'after-drag');

    // RELOAD, and measure the same width.
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 120000 });
    await page.waitForSelector('.lm_goldenlayout', { timeout: 120000 });
    await page.waitForFunction(
      () => Array.from(document.querySelectorAll('.lm_tab .lm_title'))
        .some((t) => (t.textContent || '').trim() === 'FILES'),
      null, { timeout: 120000 });
    await settle(page, 2500);
    await measure(page, 'after-reload');
    await page.screenshot({ path: outPath.replace(/\.json$/, '-reload.png'), fullPage: false });

    // ---- arm D: DEGRADATION ---------------------------------------------
    //
    // A stored layout that cannot be read. `loadLayout` throwing on a saved
    // layout is not hypothetical here — it is what left the workspace EMPTY
    // after a Stop — so the requirement is that the user gets a working
    // default and is told, never an empty window and a console line.
    report.arms.corruptWritten = await page.evaluate(() => {
      try {
        const keys = Object.keys(localStorage)
          .filter((k) => k.startsWith('CODETRACER_MODE_LAYOUT_'));
        // Both stores, so whichever mode the tab reloads into hits it.
        for (const k of ['CODETRACER_MODE_LAYOUT_EDIT', 'CODETRACER_MODE_LAYOUT_DEBUG']) {
          localStorage.setItem(k, '{"root": {"type": "row", "content": [ THIS IS NOT JSON');
        }
        return { hadKeys: keys, wrote: 2 };
      } catch (e) { return { error: String(e) }; }
    });

    await page.reload({ waitUntil: 'domcontentloaded', timeout: 120000 });
    await page.waitForSelector('.lm_goldenlayout', { timeout: 120000 });
    await settle(page, 2500);
    const degraded = await measure(page, 'after-corrupt');
    await page.screenshot({ path: outPath.replace(/\.json$/, '-corrupt.png'), fullPage: false });

    // And a switch on top of the corrupt store, because that is the path that
    // reads it a second time.
    await toggleMode(page, 'debug');
    await settle(page);
    await measure(page, 'after-corrupt-debug');
    await page.screenshot({ path: outPath.replace(/\.json$/, '-corrupt-debug.png'), fullPage: false });

    report.arms.degradedStripCount = degraded && degraded.strips
      ? Object.values(degraded.strips).filter((s) => s.present).length
      : 0;
  } catch (e) {
    report.fatal = String((e && e.stack) || e).slice(0, 1200);
  } finally {
    await browser.close();
  }

  const { writeFileSync } = await import('node:fs');
  writeFileSync(outPath, JSON.stringify(report, null, 2));
  console.log(`wrote ${outPath}`);
})();
