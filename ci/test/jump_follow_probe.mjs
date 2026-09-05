// jump_follow_probe.mjs — why a click in the file tree is sometimes ignored,
// and what the editor actually does after a jump.
//
// THE REPORTS THIS MEASURES
// -------------------------
// Against the deployed `noirstudio.dev`, entered through `/noir/demo`:
//
//   1. "I tried jumping through the call trace, but my impression is that the
//      editor was not always following the position of the caret/cursor after
//      the jump."
//   2. "I'm still unable to reliably open files. Some clicks in the file tree
//      work, others don't."
//   3. "The clicks in the file tree that don't work also don't close an active
//      right click menu, so they must be ignored somehow."
//   4. "Some jumps resulted in very rapid re-rendering of the state panel while
//      the call trace panel was also showing a 'Loading' indicator" / "the
//      rapid redrawing ended after few seconds ... the whole UI felt less
//      responsive at the time."
//
// WHY (3) DECIDES THE SHAPE OF THIS FILE
// --------------------------------------
// A context menu that stays open means the click never reached the document's
// dismiss handler. That separates "the handler ran and did nothing useful"
// from "the handler never ran", and only the second is consistent with the
// menu surviving. So the tree-click arm does NOT assert on whether a tab
// opened. It records, for each click, in this order:
//
//   * what `document.elementFromPoint(x, y)` answers at the click point
//     BEFORE the press — the overlay, if there is one, names itself here;
//   * every `pointerdown`/`mousedown`/`click` that reaches the DOCUMENT in the
//     capture phase, with its real target and `composedPath()[0]`;
//   * whether a context menu that was open beforehand is still open after.
//
// Those three readings put every failing click into exactly one bucket:
//   A. no document-level event at all      -> the pointer went elsewhere;
//      `elementFromPoint` says where.
//   B. an event arrived, target NOT the row -> an overlay; the target names it.
//   C. an event arrived ON the row and no tab opened -> the handler ran and the
//      work downstream of it failed.
//
// EVERY CLICK IS A REAL MOUSE CLICK at hit-tested coordinates
// (`page.mouse.click`), never `el.click()`. A synthetic `.click()` dispatches
// straight at the node and cannot observe an overlay at all, which is the one
// thing this probe exists to detect — it would report bucket C for every
// failure by construction.
//
// THE JUMP ARM measures the EDITOR, not a call. Per jump it records the target
// line the app itself reports, and then Monaco's caret, its visible ranges and
// its scrollTop AFTER a settle. "The editor followed" is: the caret is on the
// target line AND the target line is inside a visible range. A jump that set
// the caret and was then scrolled away by a late-arriving load fails the second
// half while passing the first, and the two are reported separately.
//
// THE STORM ARM counts State-pane DOM mutations and long tasks over a window,
// so "unpleasant to watch" and "less responsive" become numbers. It attributes
// nothing on its own; the render count and the main-thread cost are the report.
//
// Usage: node jump_follow_probe.mjs <base-url> [mountMs] [runMs]
// Prints ONE JSON object on stdout.

import { chromium } from 'playwright';

const base = process.argv[2];
const MOUNT_MS = Number(process.argv[3] || process.env.CT_JF_MOUNT_MS || 14000);
const RUN_MS = Number(process.argv[4] || process.env.CT_JF_RUN_MS || 60000);

if (!base) {
  console.error('usage: jump_follow_probe.mjs <base-url> [mountMs] [runMs]');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const out = {
  base,
  mounted: false,
  pageErrors: [],
  consoleErrors: [],
  treeClicks: [],
  contextMenuProbe: null,
  closeReopen: [],
  storm: null,
  jumps: [],
  topbarAfterRun: '',
  notes: [],
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1680, height: 1050 } });

// THE THROW THIS IS ABOUT NEVER REACHES `pageerror`.
// `showTab` is called from an async proc, so `componentItem is not a child of
// this stack` surfaces as an unhandled promise REJECTION, not an error event.
// That is precisely why the defect survived two rounds of reports with a
// console nobody could see. Capture both, at document level, before any app
// code runs.
await page.addInitScript(() => {
  window.__jfRejections = [];
  window.__jfErrors = [];
  window.addEventListener('unhandledrejection', (e) => {
    const r = e.reason;
    window.__jfRejections.push(String((r && (r.stack || r.message)) || r).slice(0, 600));
  });
  window.addEventListener('error', (e) => {
    window.__jfErrors.push(String((e.error && (e.error.stack || e.error.message)) || e.message).slice(0, 600));
  });
});

const consoleLines = [];
page.on('console', (m) => {
  const t = `${m.type()}: ${m.text()}`;
  consoleLines.push(t);
  if (m.type() === 'error') out.consoleErrors.push(m.text().slice(0, 300));
});
page.on('pageerror', (e) => out.pageErrors.push(String(e.message || e).slice(0, 300)));

// ---------------------------------------------------------------------------
// Instrumentation installed in the page.
//
// Capture phase on `document`, so a listener that calls `stopPropagation` in
// the bubble phase cannot hide the event from us; and `composedPath()[0]`
// alongside `target`, because a retargeted event through a shadow boundary
// would otherwise be reported as its host.
// ---------------------------------------------------------------------------
const INSTRUMENT = () => {
  const w = window;
  if (w.__jfInstalled) return;
  w.__jfInstalled = true;
  w.__jfEvents = [];
  w.__jfMutations = [];
  w.__jfLongTasks = [];

  const describe = (n) => {
    if (!n) return '(null)';
    if (n === document) return '#document';
    if (n === w) return 'window';
    const tag = n.tagName ? n.tagName.toLowerCase() : String(n.nodeName || '?');
    const id = n.id ? `#${n.id}` : '';
    const cls = n.className && typeof n.className === 'string'
      ? `.${n.className.trim().split(/\s+/).slice(0, 4).join('.')}` : '';
    return `${tag}${id}${cls}`.slice(0, 140);
  };
  w.__jfDescribe = describe;

  for (const type of ['pointerdown', 'mousedown', 'click', 'contextmenu']) {
    document.addEventListener(type, (e) => {
      let path0 = null;
      try { path0 = e.composedPath ? e.composedPath()[0] : null; } catch (err) { path0 = null; }
      w.__jfEvents.push({
        type,
        t: Math.round(performance.now()),
        target: describe(e.target),
        path0: describe(path0),
        defaultPrevented: !!e.defaultPrevented,
        x: e.clientX,
        y: e.clientY,
        atPoint: describe(document.elementFromPoint(e.clientX, e.clientY)),
      });
    }, true);
  }

  try {
    const po = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        w.__jfLongTasks.push({ start: Math.round(entry.startTime), dur: Math.round(entry.duration) });
      }
    });
    po.observe({ entryTypes: ['longtask'] });
    w.__jfLongTaskObserver = po;
  } catch (err) { /* longtask unsupported */ }
};

// The State pane's mutation counter. Attached on demand because the pane does
// not exist until a session does.
const ATTACH_STATE_OBSERVER = () => {
  const w = window;
  const root = document.querySelector('[id^="stateComponent"]')
    || document.querySelector('.state-container')
    || document.querySelector('[id^="StateComponent"]');
  if (!root) return null;
  if (w.__jfStateObserver) { try { w.__jfStateObserver.disconnect(); } catch (e) {} }
  w.__jfMutations = [];
  const obs = new MutationObserver((records) => {
    for (const r of records) {
      w.__jfMutations.push({
        t: Math.round(performance.now()),
        type: r.type,
        added: r.addedNodes ? r.addedNodes.length : 0,
        removed: r.removedNodes ? r.removedNodes.length : 0,
      });
    }
  });
  obs.observe(root, { childList: true, subtree: true, attributes: true, characterData: true });
  w.__jfStateObserver = obs;
  return root.id || root.className || 'state';
};

const readCaret = () => {
  const m = window.monaco;
  if (!m || !m.editor || typeof m.editor.getEditors !== 'function') return null;
  const editors = m.editor.getEditors();
  if (!editors || editors.length === 0) return null;
  const d = window.data;
  const activeKey = d && d.services && d.services.editor ? String(d.services.editor.active || '') : '';

  // The editor that MATTERS is the one the app calls active, not whichever
  // Monaco happens to hold focus: a jump that fails to activate a tab leaves
  // focus on the previous editor, and reading that one would report the old
  // file's caret as though the jump had landed.
  let chosen = null;
  try {
    if (d && d.ui && d.ui.editors && activeKey && d.ui.editors[activeKey]) {
      const c = d.ui.editors[activeKey].monacoEditor;
      if (c && typeof c.getPosition === 'function') chosen = c;
    }
  } catch (e) { chosen = null; }
  if (!chosen) chosen = editors.find((e) => { try { return e.hasTextFocus(); } catch (x) { return false; } }) || editors[0];

  let pos = null; let uri = ''; let ranges = []; let scrollTop = -1; let visible = false;
  let domHeight = -1;
  try { pos = chosen.getPosition(); } catch (e) { pos = null; }
  try { uri = String(chosen.getModel().uri.path || ''); } catch (e) { uri = ''; }
  try {
    ranges = (chosen.getVisibleRanges() || []).map((r) => [r.startLineNumber, r.endLineNumber]);
  } catch (e) { ranges = []; }
  try { scrollTop = Math.round(chosen.getScrollTop()); } catch (e) { scrollTop = -1; }
  try {
    const dom = chosen.getDomNode();
    domHeight = dom && dom.isConnected ? Math.round(dom.getBoundingClientRect().height) : -1;
    visible = !!(dom && dom.isConnected && domHeight > 0);
  } catch (e) { visible = false; }

  return {
    activeKey,
    line: pos ? pos.lineNumber : -1,
    col: pos ? pos.column : -1,
    uri,
    ranges,
    scrollTop,
    domVisible: visible,
    domHeight,
    editorCount: editors.length,
  };
};

try {
  await page.goto(`${base}/noir/demo`, { waitUntil: 'load', timeout: 60000 });
  await page.evaluate(INSTRUMENT);
  for (let i = 0; i < 80; i += 1) {
    if (consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'))) break;
    await page.waitForTimeout(250);
  }
  out.mounted = consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'));
  await page.waitForTimeout(MOUNT_MS);
  await page.evaluate(INSTRUMENT); // re-arm in case the renderer replaced document

  // -------------------------------------------------------------------------
  // ARM 1 — clicks in the file tree, as real mouse clicks, with the three
  // readings that bucket a failure.
  // -------------------------------------------------------------------------
  const rows = await page.evaluate(() => {
    const anchors = Array.from(document.querySelectorAll('.filesystem-container a.jstree-anchor, [id^="filesystemComponent"] a.jstree-anchor'));
    return anchors.map((a, i) => {
      const r = a.getBoundingClientRect();
      return {
        i,
        text: (a.textContent || '').trim().slice(0, 60),
        x: Math.round(r.left + r.width / 2),
        y: Math.round(r.top + r.height / 2),
        w: Math.round(r.width),
        h: Math.round(r.height),
      };
    }).filter((r) => r.w > 0 && r.h > 0);
  });
  out.notes.push(`file tree rows found: ${rows.length}`);

  const openTabTitles = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('.lm_tab .lm_title')).map((t) => (t.textContent || '').trim()));

  // COORDINATES ARE RE-READ IMMEDIATELY BEFORE EVERY CLICK, by the row's own
  // text. The tree re-renders when a folder toggles, so a rect captured once at
  // the start sends every later click into the container's background — which
  // reports "the click missed the row" for a product that is behaving.
  const rowRectByText = (text) => page.evaluate((t) => {
    const anchors = Array.from(document.querySelectorAll(
      '.filesystem-container a.jstree-anchor, [id^="filesystemComponent"] a.jstree-anchor'));
    const a = anchors.find((n) => (n.textContent || '').trim() === t);
    if (!a) return null;
    const r = a.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return null;
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  }, text);

  const clickRowAndMeasure = async (row, label) => {
    const fresh = await rowRectByText(row.text);
    if (!fresh) return { label, row: row.text, bucket: 'SKIP: row not present when clicked' };
    row = { ...row, x: fresh.x, y: fresh.y };

    const before = await page.evaluate(({ x, y }) => {
      window.__jfEvents = [];
      window.__jfRejections = [];
      window.__jfErrors = [];
      return {
        atPoint: window.__jfDescribe(document.elementFromPoint(x, y)),
        menuOpen: !!document.querySelector('#context-menu-container .ct-menu-item'),
      };
    }, { x: row.x, y: row.y });

    const tabsBefore = await openTabTitles();
    const caretBefore = await page.evaluate(readCaret);
    await page.mouse.click(row.x, row.y);
    await page.waitForTimeout(1200);
    const after = await page.evaluate(() => ({
      events: window.__jfEvents.slice(),
      menuOpen: !!document.querySelector('#context-menu-container .ct-menu-item'),
      rejections: (window.__jfRejections || []).slice(),
      errors: (window.__jfErrors || []).slice(),
    }));
    const tabsAfter = await openTabTitles();
    const caretAfter = await page.evaluate(readCaret);

    const sawClick = after.events.some((e) => e.type === 'click');
    const onRow = after.events.some((e) => e.type === 'click'
      && (String(e.target).includes('jstree') || String(e.path0).includes('jstree')));
    // Kept as EVIDENCE, no longer as the verdict — see below.
    const opened = tabsAfter.length > tabsBefore.length
      || JSON.stringify(tabsAfter) !== JSON.stringify(tabsBefore);

    // THE CLAIM IS "THE CLICKED FILE IS NOW THE ACTIVE EDITOR", and it is read
    // off `data.services.editor.active` — the application's OWN notion of the
    // active editor, the same field the jump assertions in this file already
    // turn on.
    //
    // It used to be "the list of open tab titles changed", which is a proxy
    // that CANNOT EXPRESS THE CLAIM IN EITHER DIRECTION:
    //
    //   * it calls a WORKING click a failure whenever the file's tab is
    //     already open, because activating an existing tab adds no title and
    //     reorders nothing. That is not a rare corner: this probe clicks every
    //     row once in Edit mode before it ever reaches Debug mode, so by then
    //     the tabs it is about to click are the ones it opened itself.
    //   * it calls a BROKEN click a pass whenever the titles move for an
    //     unrelated reason — a pane opening a listing of its own, say.
    //
    // The gate compensated with `badclicks <= 1`, a threshold whose own
    // comment claimed rows were "excluded by name rather than by fudging the
    // verdict" while the code excluded nothing and fudged by count. One extra
    // already-open tab anywhere in the layout therefore reads as a product
    // defect, and one genuinely dead row reads as fine. Asserting the active
    // editor needs no threshold and no exclusions: activating an already-open
    // tab and opening a fresh one are both simply correct.
    const baseName = (k) => String(k || '').split(/[\\/]/).pop();
    const activeBefore = baseName(caretBefore && caretBefore.activeKey);
    const activeAfter = baseName(caretAfter && caretAfter.activeKey);
    const showsClickedFile = activeAfter === row.text;

    let bucket;
    if (!sawClick) bucket = 'A: no document-level click at all';
    else if (!onRow) bucket = 'B: click arrived, target is NOT the tree row';
    else if (!showsClickedFile) bucket = 'C: click arrived on the row, the file did not become active';
    else bucket = 'OK';

    return {
      label,
      row: row.text,
      point: [row.x, row.y],
      elementFromPointBefore: before.atPoint,
      events: after.events,
      rejections: after.rejections,
      errors: after.errors,
      menuOpenBefore: before.menuOpen,
      menuOpenAfter: after.menuOpen,
      tabsBefore,
      tabsAfter,
      opened,
      activeBefore,
      activeAfter,
      showsClickedFile,
      bucket,
    };
  };

  // Files only. A folder row toggles expansion and opens no tab, so asserting
  // "a tab appeared" over it would fail for a product doing the right thing.
  const fileRows = rows.filter((r) => /\.nr$/.test(r.text));
  out.notes.push(`file rows (.nr): ${fileRows.map((r) => r.text).join(', ')}`);
  for (const row of fileRows) {
    out.treeClicks.push(await clickRowAndMeasure(row, 'plain'));
  }

  // -------------------------------------------------------------------------
  // ARM 2 — the user's own discriminator: open a context menu, then click a
  // tree row. If the row click is swallowed, the menu survives it.
  // -------------------------------------------------------------------------
  if (fileRows.length >= 2) {
    const target = fileRows[0];
    const tr = await rowRectByText(target.text);
    if (tr) await page.mouse.click(tr.x, tr.y, { button: 'right' });
    await page.waitForTimeout(900);
    const menuState = await page.evaluate(() => {
      const menus = Array.from(document.querySelectorAll('#context-menu-container'))
        .filter((m) => m.getBoundingClientRect().height > 0);
      return {
        open: !!document.querySelector('#context-menu-container .ct-menu-item'),
        items: Array.from(document.querySelectorAll('#context-menu-container .ct-menu-item-label'))
          .map((n) => (n.textContent || '').trim()).slice(0, 12),
        described: menus.map((m) => window.__jfDescribe(m)),
        // Anything full-bleed sitting over the page while the menu is up is
        // the prime suspect for swallowing the dismiss click.
        overlays: Array.from(document.querySelectorAll('body *'))
          .filter((n) => {
            const r = n.getBoundingClientRect();
            const cs = getComputedStyle(n);
            return r.width > window.innerWidth * 0.8 && r.height > window.innerHeight * 0.8
              && cs.pointerEvents !== 'none'
              && (cs.position === 'fixed' || cs.position === 'absolute');
          })
          .map((n) => window.__jfDescribe(n)).slice(0, 10),
      };
    });
    const otherRow = fileRows.find((r) => r.text !== target.text) || fileRows[0];
    const afterMenuClick = await clickRowAndMeasure(otherRow, 'with-context-menu-open');
    out.contextMenuProbe = { menuState, afterMenuClick };
  }

  // -------------------------------------------------------------------------
  // ARM 3 — close and re-open, the user's reproduction for the storm.
  // -------------------------------------------------------------------------
  await page.evaluate(ATTACH_STATE_OBSERVER);
  for (const fileRow of fileRows.slice(0, 4)) {
    // Close the EDITOR tab for this file, not whichever tab happens to be
    // active: FILES / VCS / TESTS are sidebar panes, and closing those measures
    // something the user never described.
    const closed = await page.evaluate((name) => {
      const tabs = Array.from(document.querySelectorAll('.lm_tab'));
      const tab = tabs.find((t) => {
        const title = (t.querySelector('.lm_title') || {}).textContent || '';
        return title.trim().endsWith(name);
      });
      if (!tab) return null;
      const btn = tab.querySelector('.lm_close_tab');
      if (!btn) return null;
      const title = (tab.querySelector('.lm_title') || {}).textContent || '';
      const r = btn.getBoundingClientRect();
      if (r.width <= 0) return null;
      return { title: title.trim(), x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
    }, fileRow.text);
    if (!closed) { out.notes.push(`close/reopen: no editor tab for ${fileRow.text}`); continue; }

    await page.evaluate(() => { window.__jfRejections = []; window.__jfErrors = []; });
    await page.mouse.click(closed.x, closed.y);
    await page.waitForTimeout(1000);
    const afterClose = await page.evaluate(() => ({
      tabs: Array.from(document.querySelectorAll('.lm_tab .lm_title')).map((t) => (t.textContent || '').trim()),
      rejections: (window.__jfRejections || []).slice(),
    }));

    const measured = await clickRowAndMeasure(fileRow, `reopen-${fileRow.text}`);
    out.closeReopen.push({ closedTab: closed.title, afterClose, reopen: measured });
  }

  // -------------------------------------------------------------------------
  // ARM 4 — Run, then jump through call trace frames.
  // -------------------------------------------------------------------------
  await page.evaluate(() => {
    const ae = document.activeElement;
    if (ae && typeof ae.blur === 'function') ae.blur();
    document.body.focus();
  });
  await page.keyboard.press('Control+Enter');
  await page.waitForTimeout(RUN_MS);
  out.topbarAfterRun = await page.evaluate(() => {
    const el = document.querySelector('[data-topbar-surface]');
    return el ? el.getAttribute('data-topbar-surface') : '';
  });

  await page.evaluate(ATTACH_STATE_OBSERVER);

  // -------------------------------------------------------------------------
  // ARM 3b — the tree clicks AGAIN, now in DEBUG mode.
  //
  // The user reached this by running the tests first, and the edit-mode pass
  // above is clean, so a probe that only clicked before the Run would report
  // the file tree healthy and miss the report entirely. The mode switch
  // rebuilds the layout, which is what makes a cached `.parent` stale.
  // -------------------------------------------------------------------------
  out.treeClicksDebugMode = [];
  for (const row of fileRows) {
    out.treeClicksDebugMode.push(await clickRowAndMeasure(row, 'debug-mode'));
  }
  out.closeReopenDebugMode = [];
  for (const fileRow of fileRows.slice(0, 3)) {
    const closed = await page.evaluate((name) => {
      const tabs = Array.from(document.querySelectorAll('.lm_tab'));
      const tab = tabs.find((t) => ((t.querySelector('.lm_title') || {}).textContent || '').trim().endsWith(name));
      if (!tab) return null;
      const btn = tab.querySelector('.lm_close_tab');
      if (!btn) return null;
      const r = btn.getBoundingClientRect();
      if (r.width <= 0) return null;
      const title = ((tab.querySelector('.lm_title') || {}).textContent || '').trim();
      return { title, x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
    }, fileRow.text);
    if (!closed) { out.notes.push(`debug close/reopen: no editor tab for ${fileRow.text}`); continue; }
    await page.evaluate(() => { window.__jfRejections = []; });
    await page.mouse.click(closed.x, closed.y);
    await page.waitForTimeout(1000);
    const measured = await clickRowAndMeasure(fileRow, `debug-reopen-${fileRow.text}`);
    out.closeReopenDebugMode.push({ closedTab: closed.title, reopen: measured });
  }

  const frames = await page.evaluate(() => {
    const pane = document.getElementById('calltraceComponent-0');
    if (!pane) return [];
    return Array.from(pane.querySelectorAll('.calltrace-call-line, .calltrace-row'))
      .map((n, i) => {
        const r = n.getBoundingClientRect();
        return {
          i,
          text: (n.textContent || '').trim().slice(0, 70),
          x: Math.round(r.left + Math.min(r.width / 2, 120)),
          y: Math.round(r.top + r.height / 2),
          h: Math.round(r.height),
        };
      }).filter((f) => f.h > 0);
  });
  out.notes.push(`calltrace frames found: ${frames.length}`);

  // SPREAD the sample across the call trace rather than taking the first six.
  // The first frames are all `<top-level>`/`main` in the entry file, so a
  // prefix sample is almost entirely same-file jumps and would miss the
  // cross-file case the report is about.
  const step = Math.max(1, Math.floor(frames.length / 8));
  const sample = [];
  for (let i = 0; i < frames.length && sample.length < 8; i += step) sample.push(frames[i]);
  out.notes.push(`jump sample: ${sample.map((f) => f.text.slice(0, 24)).join(' | ')}`);

  for (const f of sample) {
    const before = await page.evaluate(() => {
      window.__jfMutations = [];
      window.__jfLongTasks = [];
      window.__jfEvents = [];
      window.__jfRejections = [];
      window.__jfErrors = [];
      return {
        caret: null,
        calltraceLoading: !!document.querySelector('#calltraceComponent-0 [class*="loading"], #calltraceComponent-0 .loader'),
        t: Math.round(performance.now()),
      };
    });
    const caretBefore = await page.evaluate(readCaret);

    // Same staleness rule as the tree: the call trace re-renders as sections
    // load, so the rect is re-read by the row's own text at click time.
    const fr = await page.evaluate((t) => {
      const pane = document.getElementById('calltraceComponent-0');
      if (!pane) return null;
      const n = Array.from(pane.querySelectorAll('.calltrace-call-line, .calltrace-row'))
        .find((el) => (el.textContent || '').trim().slice(0, 70) === t);
      if (!n) return null;
      const r = n.getBoundingClientRect();
      if (r.height <= 0) return null;
      return { x: Math.round(r.left + Math.min(r.width / 2, 120)), y: Math.round(r.top + r.height / 2) };
    }, f.text);
    if (!fr) { out.notes.push(`jump: frame gone when clicked: ${f.text.slice(0, 30)}`); continue; }

    await page.mouse.click(fr.x, fr.y);
    await page.waitForTimeout(700);
    const midLoading = await page.evaluate(() =>
      !!document.querySelector('#calltraceComponent-0 [class*="loading"], #calltraceComponent-0 .loader'));

    // Settle before reading: a jump that lands correctly and is then overwritten
    // by a late load is a different defect from one that never landed, and only
    // a settled reading can tell them apart.
    await page.waitForTimeout(4000);

    const caretAfter = await page.evaluate(readCaret);
    const burst = await page.evaluate(() => ({
      mutations: window.__jfMutations.length,
      firstMutation: window.__jfMutations.length ? window.__jfMutations[0].t : -1,
      lastMutation: window.__jfMutations.length ? window.__jfMutations[window.__jfMutations.length - 1].t : -1,
      longTasks: window.__jfLongTasks.slice(),
      stillLoading: !!document.querySelector('#calltraceComponent-0 [class*="loading"], #calltraceComponent-0 .loader'),
      rejections: (window.__jfRejections || []).slice(),
      errors: (window.__jfErrors || []).slice(),
    }));

    // The target the APP itself reports, so the assertion is not against a
    // hardcoded line that would rot with the template.
    const reported = await page.evaluate(() => {
      const d = window.data;
      try {
        const loc = d.services.debugger.location;
        return { path: String(loc.path || ''), line: Number(loc.line), rrTicks: Number(loc.rrTicks) };
      } catch (e) { return null; }
    });

    // "FOLLOWED" MUST INCLUDE BEING ON SCREEN.
    //
    // The caret landing on the target line and the target sitting inside a
    // "visible" range are both satisfied vacuously by an editor laid out at
    // zero height: Monaco reports a single-line visible range like [[14,14]]
    // for a pane the user cannot see at all. That is exactly the state a failed
    // tab activation leaves behind, so a predicate without the height check
    // reports "followed" for the very failure being investigated.
    const onTarget = !!(reported && caretAfter && caretAfter.line === reported.line);
    const inRange = !!(reported && caretAfter
      && caretAfter.ranges.some(([a, b]) => reported.line >= a && reported.line <= b));
    const onScreen = !!(caretAfter && caretAfter.domVisible && caretAfter.domHeight >= 100);
    const rightFile = !!(reported && caretAfter && reported.path
      && String(caretAfter.activeKey || '').endsWith(String(reported.path)));
    const followed = onTarget && inRange && onScreen && rightFile;

    out.jumps.push({
      frame: f.text,
      reported,
      caretBefore,
      caretAfter,
      caretOnTarget: onTarget,
      targetInVisibleRange: inRange,
      editorOnScreen: onScreen,
      activeTabIsTargetFile: rightFile,
      followed,
      calltraceLoadingAtJump: midLoading,
      calltraceLoadingBefore: before.calltraceLoading,
      // The discriminator the whole report turns on: did this jump stay in the
      // file that was already active, or cross into another one?
      crossFile: !!(reported && caretBefore && reported.path
        && !String(caretBefore.activeKey || '').endsWith(String(reported.path))),
      burst,
    });
  }

  out.allRejections = await page.evaluate(() => (window.__jfRejections || []).slice());
  const totalLong = await page.evaluate(() => (window.__jfLongTasks || []).reduce((s, t) => s + t.dur, 0));
  out.storm = {
    totalLongTaskMs: totalLong,
    perJump: out.jumps.map((j) => ({
      frame: j.frame,
      mutations: j.burst.mutations,
      spanMs: j.burst.lastMutation - j.burst.firstMutation,
      longTaskMs: j.burst.longTasks.reduce((s, t) => s + t.dur, 0),
      loadingDuringJump: j.calltraceLoadingAtJump,
    })),
  };
} catch (err) {
  out.notes.push(`probe threw: ${String(err && err.message || err).slice(0, 300)}`);
} finally {
  console.log(JSON.stringify(out, null, 2));
  await browser.close();
}
