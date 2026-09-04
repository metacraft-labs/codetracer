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
  const target = lines[Math.min(lineIndex, lines.length - 1)];
  const box = await target.boundingBox();
  if (!box) return { opened: false, reason: '.view-line has no box' };
  const text = (await target.innerText()).trim();
  await page.mouse.move(box.x + Math.min(30, box.width / 2), box.y + box.height / 2);
  await page.mouse.click(box.x + Math.min(30, box.width / 2), box.y + box.height / 2,
    { button: 'right' });
  await settle(page, 500);
  const menu = await page.evaluate(readMenuScript);
  return { opened: true, lineText: text.slice(0, 80), lineIndex, menu };
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
    await page.evaluate(() => {
      const c = document.querySelector('#context-menu-container');
      if (c) c.style.display = 'none';
    });
    report.switchToDebug = await toggleMode(page, 'debug');
    report.legs.debugMode = await page.evaluate(modeScript);
    report.legs.debug = await openMenuOnLine(page, LINE);
    await page.screenshot({ path: outPath.replace(/\.json$/, '-debug.png') });

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
  } catch (e) {
    report.fatal = String((e && e.stack) || e).slice(0, 1500);
  } finally {
    await browser.close();
  }

  const { writeFileSync } = await import('node:fs');
  writeFileSync(outPath, JSON.stringify(report, null, 2));
  console.log(`wrote ${outPath}`);
})();
