// build_error_nav_probe.mjs — next/previous build error, in a real browser tab.
//
// WHAT THIS MEASURES THAT NOTHING ELSE DOES
// -----------------------------------------
// `noir_build_probe.mjs` proves a Build reaches the compiler and paints a
// verdict. It says nothing about what happens next, and "what happens next"
// is where this feature lived as dead scaffolding: `aGotoNextError` and
// `aGotoPreviousError` have been `ClientAction` members with commented-out
// menu entries and NO HANDLER, `renderer.jumpLocation` has had zero callers,
// and the PROBLEMS pane's row click dispatched `ct/jump-location` — a command
// with no engine implementation in the repo. All of that was green.
//
// So every claim here is about an OBSERVABLE END STATE, never about a call:
//
//   * the PROBLEMS pane's rows, hit-tested at their own centre, with the
//     file/line/column each one paints;
//   * Monaco's caret, read out of the live editor via `getPosition()`, before
//     and after the keystroke — a caret that did not move and a caret that
//     moved to the wrong place are different failures and are separated;
//   * `document.activeElement`, because "the editor is focused afterwards" is
//     half of the point of going to an error;
//   * the menu item's own painted sublabel, read from the DOM, because a
//     chord that is bound but invisible is the discoverability half of the
//     requirement.
//
// The caret is compared against the position THE PANE ITSELF REPORTS rather
// than against a hardcoded line:col. A constant would rot the moment the
// bundled template changed a line, and would then either fail for the wrong
// reason or — worse — be "fixed" to whatever the code now does, which is the
// check-that-requires-the-current-behaviour trap. Non-vacuity is kept by
// asserting separately that the reported position is a real one and that the
// caret actually moved.
//
// Usage: node build_error_nav_probe.mjs <url> [settleMs]

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 45000);

if (!url) {
  console.error('usage: build_error_nav_probe.mjs <url> [settleMs]');
  process.exit(2);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

const consoleLines = [];
const pageErrors = [];
page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text()}`));
page.on('pageerror', (e) => pageErrors.push(String(e.message || e)));

const report = {
  url,
  mounted: false,
  buildPaneOpened: false,
  problemsPaneOpened: false,
  problemRows: [],
  problemRowsRejected: [],
  caretBefore: null,
  caretAfterNext: null,
  caretAfterSecond: null,
  activeElementAfterNext: '',
  editorFocusedAfterNext: false,
  openedPathAfterNext: '',
  statusAfterNext: '',
  statusAfterWrap: '',
  caretAfterWrap: null,
  navigableCount: 0,
  menuItems: [],
  loadError: '',
  pageErrors: [],
  consoleLines: [],
};

// ---------------------------------------------------------------------------
// Reading the PROBLEMS pane, hit-tested.
//
// Same discipline as `noir_build_probe.mjs`: a row is only counted when a hit
// test at its own left edge lands on it or inside it. A row parked at
// `left: -9999px` in a dismissed auto-hide overlay, or covered by another
// pane, is not a row a user can read.
// ---------------------------------------------------------------------------
const readProblems = () => {
  const rows = [];
  const rejected = [];
  const list = document.getElementById('problems-list');
  if (!list) return { rows, rejected, present: false, status: '' };
  for (const row of list.querySelectorAll('.problems-row')) {
    const r = row.getBoundingClientRect();
    const cs = getComputedStyle(row);
    const text = (row.innerText || row.textContent || '').replace(/ /g, ' ').trim();
    const why = (reason) =>
      rejected.push(
        `${reason} rect=${Math.round(r.x)},${Math.round(r.y)} ` +
          `${Math.round(r.width)}x${Math.round(r.height)} :: ${text.slice(0, 60)}`,
      );
    if (r.width === 0 || r.height === 0) { why('zero-size'); continue; }
    if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') {
      why(`css-${cs.visibility}/${cs.display}/${cs.opacity}`);
      continue;
    }
    const px = r.x + Math.min(20, r.width / 2);
    const py = r.y + r.height / 2;
    const top = document.elementFromPoint(px, py);
    if (!top) { why('nothing-at-point'); continue; }
    if (!(top === row || row.contains(top) || top.contains(row))) {
      why(`covered-by-${top.tagName}.${String(top.className || '').slice(0, 40)}`);
      continue;
    }
    if (text.length === 0) { why('empty-text'); continue; }
    const pathEl = row.querySelector('.problems-path');
    const locEl = row.querySelector('.problems-location');
    const msgEl = row.querySelector('.problems-message');
    rows.push({
      text,
      path: pathEl ? (pathEl.innerText || pathEl.textContent || '').trim() : '',
      location: locEl ? (locEl.innerText || locEl.textContent || '').trim() : '',
      message: msgEl ? (msgEl.innerText || msgEl.textContent || '').trim() : '',
      selected: row.className.includes('problems-row-selected'),
      severityError: row.className.includes('problems-severity-error'),
      // WHAT THE ROW ACTUALLY LOOKS LIKE, not what class it carries. A
      // selected row whose class nothing styles is indistinguishable on
      // screen from an unselected one, and only the computed value says so.
      background: cs.backgroundColor,
      boxShadow: cs.boxShadow,
    });
  }
  const statusEl = document.querySelector('.problems-status');
  const panelEl = document.querySelector('.problems-panel');
  let chain = [];
  let node = panelEl;
  for (let i = 0; node && i < 6; i += 1) {
    const rr = node.getBoundingClientRect();
    chain.push(`${node.tagName}.${String(node.className || '').slice(0, 50)}@${Math.round(rr.x)},${Math.round(rr.y)}`);
    node = node.parentElement;
  }
  return {
    chain,
    rows,
    rejected,
    present: true,
    status: statusEl ? (statusEl.innerText || statusEl.textContent || '').trim() : '',
  };
};

// ---------------------------------------------------------------------------
// Monaco's caret, read from the live editor.
//
// NOT from a model, and not from CodeTracer's own state: the claim is that the
// EDITOR's caret moved, and the editor is the only thing that can answer that.
// `window.monaco.editor.getEditors()` returns every mounted instance; the one
// that matters is the one holding focus, falling back to the first.
// ---------------------------------------------------------------------------
const readCaret = () => {
  const m = window.monaco;
  if (!m || !m.editor || typeof m.editor.getEditors !== 'function') return null;
  const editors = m.editor.getEditors();
  if (!editors || editors.length === 0) return null;
  let chosen = editors.find((e) => {
    try { return e.hasTextFocus && e.hasTextFocus(); } catch (err) { return false; }
  });
  if (!chosen) chosen = editors[0];
  let pos = null;
  try { pos = chosen.getPosition(); } catch (err) { pos = null; }
  let uri = '';
  try { uri = String(chosen.getModel().uri.path || ''); } catch (err) { uri = ''; }
  return {
    line: pos ? pos.lineNumber : -1,
    col: pos ? pos.column : -1,
    uri,
    editorCount: editors.length,
    hasFocus: (() => {
      try { return !!(chosen.hasTextFocus && chosen.hasTextFocus()); } catch (e) { return false; }
    })(),
  };
};

const describeActive = () => {
  const a = document.activeElement;
  if (!a) return '(none)';
  return `${a.tagName}.${String(a.className || '').slice(0, 60)}`;
};

try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  for (let i = 0; i < 60; i += 1) {
    if (consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'))) break;
    await page.waitForTimeout(250);
  }
  report.mounted = consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'));

  // Same settle the build probe uses, for the same reason: the auto-hide strip
  // is registered on a timeout after GoldenLayout has built every container.
  await page.waitForTimeout(2500);

  // Blur the editor before the BUILD chord, exactly as `noir_build_probe.mjs`
  // does — Mousetrap ignores a chord raised inside Monaco's textarea, so Ctrl+B
  // has to come from outside it.
  try {
    await page.click('#menu', { position: { x: 5, y: 5 }, timeout: 3000 });
  } catch (e) { /* reported by the mount assertions */ }

  await page.keyboard.press('Control+b');

  for (let i = 0; i < 40; i += 1) {
    const seen = await page.evaluate(() => !!document.getElementById('build'));
    if (seen) { report.buildPaneOpened = true; break; }
    await page.waitForTimeout(250);
  }

  // Let the compile finish. A first compile fetches ~20 MB of wasm.
  // WAIT FOR THE BUILD'S OWN EXIT LINE, not for a class name.
  //
  // This predicate used to be `rows > 0 && !(running &&
  // !running.className.includes('disabled'))`, and both halves are unsound as a
  // settle signal. `rows > 0` is true from the FIRST diagnostic row, mid-
  // compile. And reading `className.includes('disabled')` to decide whether a
  // build is still running is the one check that cannot tell a live control
  // from a dead one — the blindness that produced a false defect report in this
  // campaign, here doing worse work than it did there, because a wait that
  // returns early does not fail: it hands the fixed delay below the job of
  // being the real wait, silently.
  //
  // `web_noir_build.onExit` reports `$phase & "-exit"`, so a finished compile
  // says so on the console with its own verdict. That is the event, it is
  // already captured, and it cannot be satisfied by a partially painted pane.
  const deadline = Date.now() + settleMs;
  let buildExitLine = '';
  while (Date.now() < deadline) {
    buildExitLine = consoleLines.find(
      (l) => l.includes('codetracer-noir-build:') && l.includes('-exit')) || '';
    if (buildExitLine) break;
    await page.waitForTimeout(250);
  }
  report.buildExitLine = buildExitLine;
  await page.waitForTimeout(1500);

  report.problemsPaneOpened = await page.evaluate(
    () => !!document.getElementById('problems-list'));

  let problems = await page.evaluate(readProblems);
  report.problemRows = problems.rows;
  report.problemRowsRejected = problems.rejected;
  report.panelChain = problems.chain || [];

  // PUT THE CARET SOMEWHERE KNOWN AND WRONG FIRST.
  //
  // Without this the "caret moved" assertion could pass because the caret
  // happened to start where the diagnostic is. Line 1, column 1 is a position
  // no diagnostic in the broken fixture occupies, and clicking into the editor
  // also establishes that the editor HAD focus before the keystroke — which is
  // what makes "focus stayed in the editor" meaningful rather than accidental.
  await page.evaluate(() => {
    const m = window.monaco;
    if (!m || !m.editor) return;
    const editors = m.editor.getEditors();
    if (editors && editors.length > 0) {
      editors[0].setPosition({ lineNumber: 1, column: 1 });
      editors[0].focus();
    }
  });
  await page.waitForTimeout(300);
  report.caretBefore = await page.evaluate(readCaret);

  // THE KEYSTROKE, ISSUED WITH THE CARET IN THE EDITOR.
  //
  // This is the whole point: a user presses "next error" while editing. A
  // global Mousetrap binding alone would be swallowed here, which is why the
  // chord is in MONACO_SHORTCUTS_WHITELIST and delegated to the editor.
  await page.keyboard.press('Control+Alt+KeyN');
  await page.waitForTimeout(1200);

  report.caretAfterNext = await page.evaluate(readCaret);
  report.activeElementAfterNext = await page.evaluate(describeActive);
  report.editorFocusedAfterNext = !!(
    report.caretAfterNext && report.caretAfterNext.hasFocus);
  report.openedPathAfterNext = report.caretAfterNext ? report.caretAfterNext.uri : '';

  problems = await page.evaluate(readProblems);
  report.problemRows = problems.rows;
  report.statusAfterNext = problems.status;
  report.navigableCount = problems.rows.filter((r) => r.severityError).length;

  // A SECOND NEXT, so "it moves" is distinguished from "it lands on the first
  // error whatever you press".
  await page.keyboard.press('Control+Alt+KeyN');
  await page.waitForTimeout(1000);
  report.caretAfterSecond = await page.evaluate(readCaret);

  // KEEP PRESSING UNTIL IT WRAPS. The list length is not assumed; the loop is
  // bounded by the number of error rows plus one, and the announcement is read
  // from the pane rather than inferred.
  const bound = Math.max(1, report.navigableCount) + 2;
  for (let i = 0; i < bound; i += 1) {
    const s = await page.evaluate(() => {
      const el = document.querySelector('.problems-status');
      return el ? (el.innerText || el.textContent || '').trim() : '';
    });
    if (s.includes('wrapped')) break;
    await page.keyboard.press('Control+Alt+KeyN');
    await page.waitForTimeout(700);
  }
  const wrapped = await page.evaluate(readProblems);
  report.statusAfterWrap = wrapped.status;
  report.caretAfterWrap = await page.evaluate(readCaret);

  // THE MENU, AND THE CHORD BESIDE THE LABEL.
  //
  // Opened with `ctrl+m` (`aMenu`), not by clicking the logo: measured, the
  // click focuses the button and opens nothing, and a gate that clicked and
  // then found no items would report "the menu has no shortcut" for a menu it
  // never opened — a false negative that looks exactly like the defect.
  //
  // The Build folder is entered by `mouseover`, which is what
  // `nodeMouseOverHandler` binds. Every row's label and sublabel are then read
  // as PAINTED TEXT, with its rect, so "the chord is displayed" is a claim
  // about pixels rather than about a field being set.
  try {
    // DISMISS THE AUTO-HIDE OVERLAY FIRST, and this is a product fact rather
    // than harness convenience. Navigating revealed the PROBLEMS pane, which
    // puts `#auto-hide-backdrop` over the whole viewport to catch the click
    // that dismisses it — and the menu renders UNDERNEATH it. Measured: every
    // menu row, including the two that predate this feature, had real
    // coordinates and lost a hit test to that backdrop. Escape is the
    // dismissal `Auto-Hide-Panes.md` §3.3 lists, and it is the state a user
    // who reaches for a menu is in.
    //
    // The z-order itself is a real defect, and it is NOT this feature's: it
    // affects `Rebuild/Re-record file` exactly as much. It is recorded here
    // rather than papered over by loosening the hit test, which would have
    // made this gate unable to see the -9999 failure mode it exists for.
    report.backdropOverMenu = await page.evaluate(
      () => !!document.getElementById('auto-hide-backdrop'));
    await page.keyboard.press('Escape');
    await page.waitForTimeout(500);

    // BLUR THE EDITOR. `ctrl+m` is Monaco's own "toggle tab focus mode"
    // binding, so with the caret still in the code from the navigation above it
    // never reaches the application and the menu silently does not open —
    // measured, as five failed menu assertions over a menu that was never
    // shown. A user opening a menu clicks the chrome; so does this.
    try {
      await page.click('#menu', { position: { x: 5, y: 5 }, timeout: 3000 });
    } catch (e) { /* the mount assertions cover a missing topbar */ }
    await page.waitForTimeout(400);
    await page.keyboard.press('Control+m');
    await page.waitForTimeout(900);
    report.menuRootLabels = await page.evaluate(() =>
      Array.from(document.querySelectorAll('.ct-menu-item-label'))
        .map((e) => e.textContent.trim()));
    report.menuOpenedBuild = await page.evaluate(() => {
      const labels = Array.from(document.querySelectorAll('.ct-menu-item-label'));
      const b = labels.find((l) => l.textContent.trim() === 'Build');
      if (!b) return false;
      const row = b.closest('div[id^="menu-element-"]') || b.parentElement;
      if (!row) return false;
      row.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
      return true;
    });
    await page.waitForTimeout(900);
    report.menuItems = await page.evaluate(() =>
      Array.from(document.querySelectorAll('div[id^="menu-element-"]')).map((row) => {
        const l = row.querySelector(':scope > .ct-menu-item-label');
        const sub = row.querySelector(':scope > .ct-menu-item-sublabel');
        const r = row.getBoundingClientRect();
        const cs = getComputedStyle(row);
        const label = l ? (l.innerText || l.textContent || '').trim() : '';
        // Hit-test the row's own label, so an item rendered off-screen or
        // underneath something else is not counted as displayed.
        let painted = false;
        let hit = '';
        if (r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' &&
            cs.display !== 'none' && cs.opacity !== '0') {
          const top = document.elementFromPoint(
            r.x + Math.min(20, r.width / 2), r.y + r.height / 2);
          painted = !!top && (top === row || row.contains(top) || top.contains(row));
          if (!painted) {
            hit = top ? `${top.tagName}#${top.id}.${String(top.className || '').slice(0, 40)}` : '(nothing)';
          }
        }
        return {
          label,
          shortcut: sub ? (sub.innerText || sub.textContent || '').trim() : '',
          painted,
          hit,
          x: Math.round(r.x),
          y: Math.round(r.y),
          width: Math.round(r.width),
        };
      }));
  } catch (e) {
    report.menuError = String((e && e.message) || e).slice(0, 200);
  }
} catch (e) {
  report.loadError = String((e && e.message) || e).slice(0, 400);
}

report.pageErrors = pageErrors;
report.consoleLines = consoleLines.filter(
  (l) => l.includes('codetracer-') || l.includes('Error') || l.includes('error:'));

await browser.close();
console.log(JSON.stringify(report, null, 2));
