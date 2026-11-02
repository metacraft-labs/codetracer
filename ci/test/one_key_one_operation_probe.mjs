// one_key_one_operation_probe.mjs — what ONE key press runs, in a real
// browser tab, with the caret in the editor and outside it.
//
// WHY THIS EXISTS
// ---------------
// The desktop (and the web build) used to deliver a key through three
// registries — Mousetrap's binding loop over the YAML table, chords bound in
// code after it, and the Monaco `commands` table — which disagreed: one key
// ran two actions depending on focus (`Ctrl+E`, `Alt+E`), `F2` was dead
// outside the editor, and a chord could be delivered twice. PLAT-68 replaced
// all three with ONE capture-phase listener and the shared router
// (`src/frontend/ui/key_router.nim`). This probe measures the property that
// replacement has to keep: one press runs ONE operation, the same one
// wherever the caret is (unless a `when` clause says otherwise), and the
// action behind it runs once.
//
// WHAT THIS PROGRAM MEASURES, and it is deliberately not an assertion: it
// reports facts and `chord-and-pane-uniqueness.sh` counts assertions over
// them, so the control and every arm read the same instrument.
//
//   * `window.__ctKeyTrace` — every operation the router RAN, in order
//     (`key_router.traceOperation`). A press's entries are its operations.
//   * `window.data.actions` — every slot wrapped and counted, per press, so
//     "ran its action twice" and "also ran another action" are told apart.
//   * the editor's read-only state and the mode, either side of a press,
//     for the chord whose effect is a state change (`Ctrl+E`).
//
// SELECTION: `CT_CHORD_SUBJECTS` (comma-separated `key` values below) and
// `CT_CHORD_FOCUS` (`editor`, `outside`) pick a subset, so a chord that moves
// state the others are measured against gets a page of its own.

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 9000);
if (!url) {
  console.error('usage: one_key_one_operation_probe.mjs <url> [settleMs]');
  process.exit(2);
}

// The chords, and the ONE operation each runs on this page (the Noir
// playground is Edit mode; CUA-Keymap.md). Every one is a global-table row,
// so the same operation is expected with the caret in the editor and out of
// it. `action` names the `ClientAction` the operation runs through, where it
// runs through one; the shell derives its slot from the enum.
const CHORDS = [
  { key: 'F8', op: 'problems.next', action: 'aGotoNextError' },
  { key: 'Shift+F8', op: 'problems.previous', action: 'aGotoPreviousError' },
  { key: 'Control+Shift+KeyB', op: 'build.run', action: 'build' },
  // The web studio's Run (`frontEnd == web`, CUA-Keymap.md §3.7): VS Code's
  // open-line-below steps aside in the editor here.
  { key: 'Control+Enter', op: 'build.run-program', action: '' },
  // The program menu (CUA-Keymap.md §3.8): F10 in Edit mode, Alt+`, and an
  // Alt+mnemonic. The menu is closed after each press.
  { key: 'F10', op: 'menu.open', action: '' },
  { key: 'Alt+Backquote', op: 'menu.open', action: '' },
  { key: 'Alt+KeyD', op: 'menu.open-folder(debug)', action: '' },
];

// Measured on pages of their own: a state change the other presses would be
// measured against.
const STATE_CHORDS = [
  { key: 'Control+KeyE', op: 'editor.toggle-read-only', action: 'aToggleReadOnly' },
];

const ALL_CHORDS = CHORDS.concat(STATE_CHORDS);
const ALL_FOCUS_CONTEXTS = ['editor', 'outside'];

const subjectSel = (process.env.CT_CHORD_SUBJECTS || '').trim();
const focusSel = (process.env.CT_CHORD_FOCUS || '').trim();
const SUBJECTS = subjectSel
  ? subjectSel.split(',').map((s) => s.trim()).filter(Boolean).map((k) => {
      const c = ALL_CHORDS.find((x) => x.key === k);
      if (!c) {
        console.error(`unknown chord in CT_CHORD_SUBJECTS: ${k}`);
        process.exit(2);
      }
      return c;
    })
  : CHORDS;
const FOCUS_CONTEXTS = focusSel
  ? focusSel.split(',').map((s) => s.trim()).filter(Boolean)
  : ALL_FOCUS_CONTEXTS;
for (const f of FOCUS_CONTEXTS) {
  if (!ALL_FOCUS_CONTEXTS.includes(f)) {
    console.error(`unknown focus context in CT_CHORD_FOCUS: ${f}`);
    process.exit(2);
  }
}

const browser = await chromium.launch({});
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

const pageErrors = [];
page.on('pageerror', (e) =>
  pageErrors.push(String((e && e.message) || e).slice(0, 300)));

let loadError = '';
try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(settleMs);
} catch (e) {
  loadError = String((e && e.message) || e).slice(0, 300);
}

// PRECONDITIONS, reported as facts and asserted by the shell: every one is a
// way this probe could measure nothing and report a clean zero.
const pre = await page.evaluate(() => {
  const d = window.data;
  return {
    hasData: !!d,
    actionsIsArray: !!(d && Array.isArray(d.actions)),
    actionsLength: d && d.actions ? d.actions.length : -1,
    monacoEditors: document.querySelectorAll('.monaco-editor').length,
    hasMenuVM: !!window.__ctMenuVM,
  };
});

// The counter: every slot of `data.actions`, wrapped in place.
await page.evaluate(() => {
  const d = window.data;
  window.__chordCounts = {};
  window.__chordOriginals = [];
  (d.actions || []).forEach((fn, i) => {
    if (typeof fn !== 'function') return;
    window.__chordOriginals[i] = fn;
    d.actions[i] = function (...args) {
      window.__chordCounts[i] = (window.__chordCounts[i] || 0) + 1;
      return window.__chordOriginals[i].apply(this, args);
    };
  });
});

// Put the caret somewhere, and REPORT WHERE IT LANDED rather than assume.
async function setFocus(where) {
  const out = { where };
  try {
    if (where === 'editor') {
      const ed = await page.$('.monaco-editor .view-lines');
      if (ed) await ed.click();
    } else {
      await page.evaluate(() => {
        if (document.activeElement && document.activeElement.blur) {
          document.activeElement.blur();
        }
        document.body.focus();
      });
    }
    await page.waitForTimeout(400);
  } catch (e) {
    out.error = String((e && e.message) || e).slice(0, 200);
  }
  out.activeInsideMonaco = await page.evaluate(() => {
    const a = document.activeElement;
    return !!(a && a.closest && a.closest('.monaco-editor'));
  });
  return out;
}

async function uiState() {
  return page.evaluate(() => {
    const ui = window.data && window.data.ui;
    if (!ui) return { present: false };
    let monacoReadOnly = null;
    try {
      const out = [];
      for (const label of Object.keys(ui.editors || {})) {
        const e = ui.editors[label];
        if (!e || !e.monacoEditor) continue;
        out.push([label, !!e.monacoEditor.getRawOptions().readOnly]);
      }
      out.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
      monacoReadOnly = out;
    } catch (e) {
      monacoReadOnly = null;
    }
    return {
      present: true,
      mode: typeof ui.mode === 'number' ? ui.mode : null,
      readOnly: typeof ui.readOnly === 'boolean' ? ui.readOnly : null,
      monacoReadOnly,
    };
  });
}

const focusReports = [];
const results = [];
for (const where of FOCUS_CONTEXTS) {
  focusReports.push(await setFocus(where));
  for (const c of SUBJECTS) {
    await setFocus(where);
    const stateBefore = await uiState();
    await page.evaluate(() => {
      window.__chordCounts = {};
      window.__ctKeyTrace = [];
    });
    await page.keyboard.press(c.key);
    await page.waitForTimeout(600);
    const counts = await page.evaluate(() => window.__chordCounts);
    const ops = await page.evaluate(() => (window.__ctKeyTrace || []).slice());
    const stateAfter = await uiState();
    // A menu a press opened is closed, so the next press is measured with
    // the focus it names, not inside the menu.
    await page.evaluate(() => { if (window.__ctMenuVM) window.__ctMenuVM.close(); });
    results.push({
      focus: where,
      key: c.key,
      expectedOp: c.op,
      action: c.action,
      ops,
      allDeliveries: counts,
      totalDeliveries: Object.values(counts).reduce((a, b) => a + b, 0),
      maxDeliveries: Math.max(0, ...Object.values(counts)),
      modeChanged: stateBefore.mode !== stateAfter.mode,
      readOnlyChanged: stateBefore.readOnly !== stateAfter.readOnly,
      monacoReadOnlyChanged:
        JSON.stringify(stateBefore.monacoReadOnly) !==
        JSON.stringify(stateAfter.monacoReadOnly),
      monacoEditorsMeasured:
        stateAfter.monacoReadOnly == null ? -1 : stateAfter.monacoReadOnly.length,
      stateBefore,
      stateAfter,
    });
  }
}

console.log(JSON.stringify({
  url,
  loadError,
  pageErrors,
  requested: {
    subjects: SUBJECTS.map((c) => c.key),
    focusContexts: FOCUS_CONTEXTS,
  },
  pre,
  focusReports,
  results,
}, null, 2));

await browser.close();
