// editor_context_menu_modes_probe.mjs — WHAT THE EDITOR'S RIGHT-CLICK MENU
// SAYS, read from the DOM of a real tab, once per mode, on the same file.
//
// THE REPORT
// ----------
// Against `noirstudio.dev`: "I noticed that the right click menu content over
// the editor area is not context dependent (Edit vs Debug). Most of the entries
// are debug operations."
//
// So the subject is not "does a menu appear" and not "does the menu differ
// between the modes". Both of those can hold of a product that still fails the
// sentence above — a menu that differs by one row is a menu that differs, and a
// menu that is non-empty is a menu. This probe therefore reports the ENTRY
// NAMES, per mode, and the shell gate asserts them one at a time, in both
// directions: the right ones present AND the wrong ones absent.
//
// WHY THE NAMES AND NOT THE COUNT
// -------------------------------
// A count cannot name what is wrong. The failure this exists to catch reads
// "Jump to line, Run to Cursor, Add tracepoint present in Edit mode", and that
// message is only available if the names were collected.
//
// NOT A GREP OVER `ui.js`
// -----------------------
// Nim's JS backend emits some string literals as bare char-code arrays, so a
// text search over the bundle is not a presence test for a menu label. Every
// reading here is `document.querySelector` over a menu that was actually
// opened by a right-click.
//
// THE MODE IS DRIVEN THROUGH THE PRODUCT'S OWN ACTION
// ---------------------------------------------------
// `data.functions.switchToEdit` / `switchToDebug`, the same entry points
// `ci/test/mode_layout_probe.mjs` drives and the same ones the toolbar and the
// mode chord reach. Setting `data.ui.mode` directly would measure a field
// nobody transitions through.
//
// Usage: node ci/test/editor_context_menu_modes_probe.mjs <url> <out.json>

import { chromium } from 'playwright';

const url = process.argv[2];
const outPath = process.argv[3];
if (!url || !outPath) {
  console.error('usage: editor_context_menu_modes_probe.mjs <url> <out.json>');
  process.exit(2);
}

const report = {
  url,
  pageErrors: [],
  consoleErrors: [],
  legs: {},
};

const settle = (page, ms = 700) => page.waitForTimeout(ms);

// ---------------------------------------------------------------------------
// Reading the menu.
//
// `.ct-menu-item-label` is the row's action name and `.ct-menu-item-sublabel`
// its shortcut-or-reason; the split is the markup's, not this probe's — see
// `src/tests/gui/page-objects/components/context-menu.ts`, which reads the same
// two classes and carries the note about `innerText` folding the two together
// when they are not separated.
//
// `.context-menu-hint` is deliberately NOT collected as an entry: it is the
// non-interactive row naming the browser's own context-menu gesture, and
// counting it as a command is what the `[hint]` checks in
// `menu-and-context-menu-in-browser.sh` exist to prevent.
// ---------------------------------------------------------------------------
const readMenuScript = () => {
  const container = document.querySelector('#context-menu-container');
  if (!container) return { present: false, reason: 'no #context-menu-container' };
  const style = window.getComputedStyle(container);
  const rect = container.getBoundingClientRect();
  const rows = Array.from(container.querySelectorAll('.context-menu-item'));
  const entries = rows.map((row) => {
    const label = row.querySelector('.ct-menu-item-label');
    const sub = row.querySelector('.ct-menu-item-sublabel');
    const r = row.getBoundingClientRect();
    return {
      name: ((label ? label.textContent : row.textContent) || '').trim(),
      sublabel: ((sub ? sub.textContent : '') || '').trim(),
      disabled: row.classList.contains('ct-menu-item--disabled'),
      ariaDisabled: row.getAttribute('aria-disabled'),
      // PAINTED, so "present" is never satisfied by a row with no box. A menu
      // whose rows have zero height is a menu the user cannot use, and it
      // satisfies a name check exactly as a working one does.
      painted: r.width > 0 && r.height > 0,
      // A disabled row must not be reachable by a click. Asked of the hit test
      // at the row's own centre rather than of the class, because
      // `pointer-events: none` is what actually decides it.
      hitIsSelf: (() => {
        const hit = document.elementFromPoint(
          Math.round(r.x + r.width / 2), Math.round(r.y + r.height / 2));
        return !!(hit && (hit === row || row.contains(hit)));
      })(),
    };
  });
  return {
    present: true,
    visible: style.display !== 'none' && rect.width > 0 && rect.height > 0,
    display: style.display,
    box: { w: Math.round(rect.width), h: Math.round(rect.height) },
    entries,
    names: entries.map((e) => e.name),
    hintRows: container.querySelectorAll('.context-menu-hint').length,
  };
};

// The mode, read from the product rather than inferred. `data.ui.mode` is a
// `LayoutMode` ordinal (0 = DebugMode, 1 = EditMode) — reported raw AND named,
// so a member inserted into the enum shows up as a changed name rather than
// silently reclassifying a leg.
const modeScript = () => {
  const names = ['DebugMode', 'EditMode', 'QuickEditMode', 'InteractiveEditMode',
                 'CalltraceLayoutMode'];
  const raw = (window.data && window.data.ui) ? window.data.ui.mode : null;
  const n = Number(raw);
  return {
    raw: String(raw),
    name: Number.isInteger(n) && names[n] ? names[n] : String(raw),
    topbarSurface: (() => {
      const el = document.querySelector('[data-topbar-surface]');
      return el ? el.getAttribute('data-topbar-surface') : null;
    })(),
  };
};

async function toggleMode(page, want) {
  const outcome = await page.evaluate((wanted) => {
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
  await settle(page, 1400);
  return outcome;
}

// Right-click a line of code and read what came up.
//
// THE SAME LINE IN BOTH MODES, passed in by the caller, because "the menu
// differs" would otherwise be satisfiable by having right-clicked somewhere
// else. The target is a `.view-line` — Monaco's rendered text, the surface the
// report is about — and the click lands a little way into the line so it is
// over a token rather than over trailing whitespace.
async function openMenuOnLine(page, lineIndex) {
  await page.evaluate(() => {
    const c = document.querySelector('#context-menu-container');
    if (c) { c.style.display = 'none'; c.innerHTML = ''; }
  });
  const lines = await page.$$('.view-line');
  if (!lines.length) return { opened: false, reason: 'no .view-line on screen' };

  // A LINE WITH TEXT ON IT.  `.view-line` elements exist for blank lines too,
  // and a blank one is a few pixels wide — a click "30px into it" lands past
  // the content, Monaco reports NO position for the event, and
  // `createContextMenuItems` returns an empty seq before it has read the mode.
  // The menu is then never shown at all.
  //
  // That is not hypothetical: the Debug leg picked index 2, which is blank in
  // the file this probe drives, and reported an empty menu that read exactly
  // like "the Debug entries are missing". Blank lines are skipped so the click
  // is always on code.
  const candidates = [];
  for (const el of lines) {
    const t = ((await el.innerText()) || '').trim();
    if (t.length > 2) candidates.push({ el, text: t });
  }
  if (!candidates.length) {
    return { opened: false, reason: 'every .view-line on screen is blank' };
  }
  const chosen = candidates[Math.min(lineIndex, candidates.length - 1)];
  const box = await chosen.el.boundingBox();
  if (!box) return { opened: false, reason: '.view-line has no box' };
  const x = box.x + Math.min(12, Math.max(2, box.width / 3));
  const y = box.y + box.height / 2;

  // WHAT IS ACTUALLY UNDER THE POINTER, asked of the hit test before the
  // click rather than inferred from the empty menu afterwards.
  //
  // A right-click that produces no menu has two very different causes and the
  // row count cannot tell them apart: the handler ran and built nothing, or
  // the gesture never reached the editor because something is lying over it.
  // The second is what was measured in Debug mode — `#auto-hide-backdrop`, a
  // transparent full-viewport layer (z-index 98) that `#auto-hide-overlay`
  // leaves up — and a probe that only counted rows reported it as a menu
  // defect for two rounds. `elementFromPoint` at the exact click point is the
  // same question the browser asks when it routes the event.
  const cover = await page.evaluate(({ px, py }) => {
    const describe = (n) => {
      if (!n) return null;
      const cls = typeof n.className === 'string' ? n.className : '';
      return n.tagName.toLowerCase() + (n.id ? '#' + n.id : '') +
        (cls ? '.' + cls.trim().split(/\s+/).join('.') : '');
    };
    const hit = document.elementFromPoint(Math.round(px), Math.round(py));
    const overlay = document.getElementById('auto-hide-overlay');
    const backdrop = document.getElementById('auto-hide-backdrop');
    const m = window.monaco;
    const ed = (m && m.editor && m.editor.getEditors) ? m.editor.getEditors()[0] : null;
    const view = ed && ed.getDomNode ? ed.getDomNode() : null;
    return {
      hit: describe(hit),
      // The pane is the editor's when the hit test lands INSIDE Monaco's view
      // node. Anything else means the click cannot reach the editor at all.
      hitIsInsideEditor: !!(view && hit && view.contains(hit)),
      // `clientWidth`/`clientHeight` and `isConnected`, never a Monaco
      // self-report: Monaco answers a plausible one-line visible range for a
      // DETACHED pane, so a caret check passes on a fully broken product.
      editorView: view
        ? { w: view.clientWidth, h: view.clientHeight, isConnected: view.isConnected }
        : null,
      overlayClasses: overlay ? overlay.className : null,
      backdrop: backdrop
        ? {
            display: window.getComputedStyle(backdrop).display,
            w: backdrop.clientWidth,
            h: backdrop.clientHeight,
          }
        : null,
    };
  }, { px: x, py: y });

  await page.mouse.move(x, y);
  await page.mouse.click(x, y, { button: 'right' });
  await settle(page, 500);
  const menu = await page.evaluate(readMenuScript);
  return {
    opened: true,
    lineText: chosen.text.slice(0, 80),
    lineIndex,
    candidateCount: candidates.length,
    cover,
    menu,
  };
}

// RUN, then read the menu in the session it produced.
//
// The gesture is `Ctrl+Enter`, the product's own Run chord — deliberately not
// `Ctrl+R` or `F5`, both of which are the browser's reload. The editor is
// blurred first because Mousetrap's default `stopCallback` ignores a chord
// raised inside a textarea and Monaco's input surface is one. All of that is
// `ci/test/noir_replay_probe.mjs`'s, and it is spelled the same way here on
// purpose: two spellings of "Run the program" is two things to keep in step.
async function debugLegViaRun(page, lineIndex, outPath) {
  try {
    await page.click('#menu', { position: { x: 5, y: 5 }, timeout: 3000 });
  } catch (e) { /* a missing topbar shows up as a failure to reach a session */ }
  await page.keyboard.press('Control+Enter');

  // WAITED FOR: THE DEBUG SESSION ON SCREEN, not a log line.
  //
  // The first shape of this waited for `OBJ:start` in `window.__ctWorkerMessages`,
  // copied from `noir_replay_probe.mjs`. That array is empty on this route, so
  // the wait ran to its 180s ceiling and the leg reported "Run did not reach a
  // replay session" about a page that had reached one in FIVE SECONDS. The
  // measurement was of the instrument.
  //
  // The three conditions below are the ones this leg actually needs, and each
  // is a thing a user can see: the debugger is in Debug mode, its controls are
  // mounted, and the editor has painted source to right-click. A first Run
  // fetches ~16 MB of compiler and ~4.6 MB of tracer, compiles, traces, then
  // fetches ~18 MB of engine and instantiates it, so the ceiling stays generous.
  const deadline = Date.now() + 180000;
  let ready = null;
  while (Date.now() < deadline) {
    const state = await page.evaluate(() => ({
      mode: (window.data && window.data.ui) ? Number(window.data.ui.mode) : null,
      controls: !!document.querySelector('#next-image'),
      lines: document.querySelectorAll('.view-line').length,
    }));
    if (state.mode === 0 && state.controls && state.lines > 0) { ready = state; break; }
    await page.waitForTimeout(500);
  }
  if (ready === null) {
    const state = await page.evaluate(() => ({
      mode: (window.data && window.data.ui) ? Number(window.data.ui.mode) : null,
      controls: !!document.querySelector('#next-image'),
      lines: document.querySelectorAll('.view-line').length,
    }));
    return {
      opened: false,
      reason: 'Run did not reach a replay session with source on screen within '
        + `180s (mode=${state.mode} debugControls=${state.controls} `
        + `viewLines=${state.lines}) — are the Noir wasm modules and the replay `
        + 'engine in this bundle?',
    };
  }

  await settle(page, 2500);
  await page.screenshot({ path: outPath.replace(/\.json$/, '-debug-session.png') });

  const leg = await openMenuOnLine(page, lineIndex);
  leg.debugControlsMounted = await page.evaluate(
    () => !!document.querySelector('#next-image'));
  return leg;
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
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 120000 });
    await page.waitForSelector('.lm_goldenlayout', { timeout: 120000 });
    // A MENU OVER CODE NEEDS CODE. Waiting for the editor to have rendered
    // lines is what keeps "no debug entries in Edit mode" from passing because
    // there was nothing to right-click.
    await page.waitForFunction(
      () => document.querySelectorAll('.view-line').length > 0,
      null, { timeout: 120000 });
    await settle(page, 2500);

    report.bootMode = await page.evaluate(modeScript);
    report.editorLinesAtBoot = await page.evaluate(
      () => document.querySelectorAll('.view-line').length);

    // The line every leg uses. Index 2 rather than 0 so the click is inside the
    // body of the file rather than on a header comment that may be blank.
    const LINE = 2;

    // ---- EDIT ------------------------------------------------------------
    report.switchToEdit = await toggleMode(page, 'edit');
    report.legs.editMode = await page.evaluate(modeScript);
    report.legs.edit = await openMenuOnLine(page, LINE);
    await page.screenshot({ path: outPath.replace(/\.json$/, '-edit.png') });

    // ---- DEBUG -----------------------------------------------------------
    //
    // TWO ROUTES INTO DEBUG MODE, and they are not equivalent on this surface.
    //
    //   * `switchToDebug` is the mode toggle. Measured here, it leaves the
    //     workspace with NO editor pane and no filesystem tree — the Monaco
    //     instance's DOM node comes back disconnected — so there is nothing to
    //     right-click. That is a mode-transition defect and it is REPORTED
    //     rather than worked around, because a probe that silently took the
    //     other road would have hidden it.
    //   * RUN is how a user of `noirstudio.dev` actually gets there: it
    //     compiles, traces, and opens a real session with the executing source
    //     on screen. That is the state the report is about, so that is where
    //     the Debug menu is read.
    //
    // Run needs the Noir compiler and tracer and the replay engine to be in the
    // bundle. When they are not, this leg reports why and the shell gate says
    // the Debug half was not measured instead of passing over it.
    await page.evaluate(() => {
      const c = document.querySelector('#context-menu-container');
      if (c) c.style.display = 'none';
    });
    report.switchToDebug = await toggleMode(page, 'debug');
    report.legs.debugModeViaToggle = await page.evaluate(modeScript);
    report.legs.debugViaToggle = await page.evaluate(() => ({
      viewLines: document.querySelectorAll('.view-line').length,
      editorContainers: document.querySelectorAll('[id^=editorComponent-]').length,
      monacoDomConnected: (() => {
        const m = window.monaco;
        if (!m || !m.editor.getEditors) return null;
        const e = m.editor.getEditors()[0];
        const n = e && e.getDomNode && e.getDomNode();
        return n ? n.isConnected : null;
      })(),
    }));

    // Back to Edit. The Run leg is deliberately LAST — see below.
    await toggleMode(page, 'edit');

    // ---- BACK TO EDIT ----------------------------------------------------
    //
    // A menu built once from a mode read at construction time would be right on
    // the first switch and wrong afterwards, which is the failure shape the
    // layout register was built to stop having. So the round trip is measured,
    // not assumed: the Edit menu after a visit to Debug must equal the Edit
    // menu before it.
    await page.evaluate(() => {
      const c = document.querySelector('#context-menu-container');
      if (c) c.style.display = 'none';
    });
    report.switchBackToEdit = await toggleMode(page, 'edit');
    report.legs.editAgainMode = await page.evaluate(modeScript);
    report.legs.editAgain = await openMenuOnLine(page, LINE);
    await page.screenshot({ path: outPath.replace(/\.json$/, '-edit-again.png') });

    // ---- EDIT, READ-ONLY -------------------------------------------------
    //
    // THE DISABLED PATH NEEDS A SUBJECT. Without this leg every "disabled rows
    // carry a reason" assertion is quantified over an empty set and cannot
    // fail: the ordinary Edit-mode menu has no disabled row in it.
    //
    // Read-onlyness is toggled INSIDE Edit mode, through the product's own
    // `toggleReadOnly` — the command `Ctrl+E` is bound to, and deliberately
    // independent of the mode (`Mode-Transitions.md` §9
    // `Mode.ReadOnlyDoesNotMoveMode`). That independence is exactly what makes
    // Cut and Paste "applicable here, unavailable now" rather than
    // inapplicable: the user can clear the flag, and the row has to say which
    // flag it is.
    await page.evaluate(() => {
      const c = document.querySelector('#context-menu-container');
      if (c) c.style.display = 'none';
    });
    report.toggleReadOnly = await page.evaluate(() => {
      try {
        window.data.functions.toggleReadOnly(window.data);
        return 'ok';
      } catch (e) {
        return 'threw: ' + String((e && e.message) || e).slice(0, 200);
      }
    });
    await settle(page, 1200);
    report.legs.readOnlyState = await page.evaluate(() => ({
      uiReadOnly: !!(window.data && window.data.ui && window.data.ui.readOnly),
      mode: (window.data && window.data.ui) ? String(window.data.ui.mode) : null,
    }));
    report.legs.editReadOnly = await openMenuOnLine(page, LINE);
    await page.screenshot({ path: outPath.replace(/\.json$/, '-edit-readonly.png') });

    // ---- DEBUG, THROUGH RUN ----------------------------------------------
    //
    // LAST, and the order is load-bearing. Run compiles and traces in the tab
    // and then swaps the whole workspace; when any of that goes wrong the page
    // does not come back, and a Run placed earlier took the Edit legs down with
    // it — the first version of this probe reported an EMPTY Edit menu two legs
    // later and the failure read as a menu defect. Every assertion that can be
    // made without a session is therefore already made by the time this runs.
    //
    // Read-only is cleared first: it was set by the leg above, and Run against
    // a read-only editor is not the gesture being measured.
    await page.evaluate(() => {
      const c = document.querySelector('#context-menu-container');
      if (c) c.style.display = 'none';
      try {
        if (window.data && window.data.ui && window.data.ui.readOnly) {
          window.data.functions.toggleReadOnly(window.data);
        }
      } catch (e) { /* reported by the leg's own reason string */ }
    });
    await settle(page, 1000);
    report.legs.debug = await debugLegViaRun(page, LINE, outPath);
    report.legs.debugMode = await page.evaluate(modeScript);
    await page.screenshot({ path: outPath.replace(/\.json$/, '-debug.png') });
  } catch (e) {
    report.fatal = String((e && e.stack) || e).slice(0, 1500);
  } finally {
    await browser.close();
  }

  const { writeFileSync } = await import('node:fs');
  writeFileSync(outPath, JSON.stringify(report, null, 2));
  console.log(`wrote ${outPath}`);
})();
