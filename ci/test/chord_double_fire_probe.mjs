// chord_double_fire_probe.mjs — how many times does ONE key press run the
// action bound to it, in a real browser tab?
//
// WHY THIS EXISTS
// ---------------
// `ui/shortcuts.nim` sets `Mousetrap.prototype.stopCallback` to a proc that
// returns `false` for everything. Mousetrap's default returns `true` when the
// event target is an INPUT / SELECT / TEXTAREA / contentEditable
// (`node_modules/mousetrap/mousetrap.js`, `Mousetrap.prototype.stopCallback`),
// and Monaco's editor takes its keystrokes on a hidden `textarea.inputarea`.
// So the override's PURPOSE is real — without it no chord works while the
// caret is in the code editor — and its side effect is that, for the eleven
// chords in `ui/editor.nim`'s MONACO_SHORTCUTS_WHITELIST, the SAME action is
// now reachable twice for one press: once through Monaco's own `addCommand`
// (installed by `delegateShortcuts`) and once through Mousetrap's global bind
// (installed by `configureShortcuts`). Both call `data.actions[action](nil)`.
//
// Stepping does not visibly double today, but not because anything stops it:
// `renderer.nim`'s `step` and `ui/debug.nim`'s `dapStep` both drop a request
// while `data.status.stableBusy` is set, and that flag is a step-serialisation
// guard (its own comment says it is there for "holding F10"), not a
// double-delivery guard. It swallows the second delivery by accident. A chord
// whose action is not a step — or a step taken before the flag is set — has
// nothing between it and running twice.
//
// WHAT THIS PROGRAM MEASURES, and it is deliberately not an assertion.
// Following `web_renderer_probe.mjs`: this reports facts and
// `chord-double-fire.sh` counts assertions over them, so the control arm and
// the mutation arm read the same instrument.
//
// The instrument is `window.data.actions` (`types.nim:2021`,
// `array[ClientAction, ClientActionHandler]`, so a JS array indexed by the
// enum's ordinal). EVERY slot is wrapped, and the report is per-index, because
// "the chord ran its action twice" and "the chord also ran a different action"
// are different defects and one total could not tell them apart.
//
// It ALSO counts the two `cdebug` lines that name the delivery path —
// `shortcuts: global handle` (`ui/shortcuts.nim:76`, the Mousetrap bind) and
// `editor: shortcuts: monaco handle` (`ui/editor.nim:280`, the Monaco
// command). Those are the diagnosis: a total of 2 says it doubled, and the two
// path counters say WHICH two paths delivered, which is what tells a fix that
// removed the duplicate apart from a fix that removed the wrong one of the
// pair. `cdebug` is `console.debug` unconditionally (`lib/logging.nim:29`) —
// there is no build flag between this measurement and the shipped bundle.

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 9000);
if (!url) {
  console.error('usage: chord_double_fire_probe.mjs <url> [settleMs]');
  process.exit(2);
}

// The stepping chords, which is where the hazard was noticed, plus the two
// non-F-key whitelist entries. Ordinals are `ClientAction`'s declaration order
// in `common/common_types/codetracer_features/frontend.nim:20` — the enum is
// unvalued, so the ordinal IS the array index. The name is carried so the
// report reads as an action rather than as a number.
// EVERY entry of MONACO_SHORTCUTS_WHITELIST that the shipped yaml also binds,
// which is the exact set that is reachable through both paths at once. A
// subset would leave the claim "every whitelisted chord" untested on the
// members most likely to differ — F2/F8/F12 are the ones Monaco itself binds
// natively (Rename, Next Problem, Go to Definition), and CTRL+S is the only
// non-F-key and the only one registered TWICE on the same editor (once from
// `editor.nim`'s hardcoded `commands` table, once from the config loop).
const CHORDS = [
  { key: 'F2', action: 'forwardContinue', index: 0 },
  { key: 'F8', action: 'forwardContinue', index: 0 },
  { key: 'F10', action: 'forwardNext', index: 2 },
  { key: 'F11', action: 'forwardStep', index: 4 },
  { key: 'F12', action: 'forwardStepOut', index: 6 },
  { key: 'Shift+F8', action: 'reverseContinue', index: 1 },
  { key: 'Shift+F10', action: 'reverseNext', index: 3 },
  { key: 'Shift+F11', action: 'reverseStep', index: 5 },
  { key: 'Shift+F12', action: 'reverseStepOut', index: 7 },
  { key: 'Control+s', action: 'aSave', index: 43 },
  // CTRL+B — the chord this gate was extended for, and the one that proves the
  // exclusivity claim is about MONACO and not about `stopCallback`.
  //
  // It joined MONACO_SHORTCUTS_WHITELIST because measurement on the deployed
  // site said the global bind alone does not reach it: caret in `src/main.nr`,
  // `Ctrl+B`, and there was no `shortcuts: global handle ctrl+b build` line and
  // no `nargo compile` worker start — while the same press with focus on
  // `<body>` built the project. The keydown arrives at `document` in the
  // CAPTURE phase and never returns in the BUBBLE phase, which is where
  // Mousetrap listens, so in the `editor` context the Monaco path is the only
  // live one and in `outside` the Mousetrap path is.
  //
  // Unlike ALT+F8 there is no native Monaco binding to double with: the
  // standalone editor's keybinding resolver, queried on the live page, returns
  // an EMPTY list for Ctrl+B/Cmd+B. That is exactly what this entry pins, so a
  // future Monaco upgrade that DOES bind `ctrl+b` reddens here rather than
  // silently compiling the project twice per press.
  { key: 'Control+b', action: 'build', index: 9 },
];

// THE SHADOWED CHORDS — the ones a hard `Mousetrap.bind` claimed after the
// config loop had already claimed them, so that the config entry names an
// action the key never dispatches.
//
// They are NOT in `CHORDS` above and are never pressed in the same page as it,
// and that separation is deliberate rather than tidy. Both of them change
// application state that the other presses are measured against: `CTRL+E`
// flips `data.ui.readOnly` and `data.ui.mode` and rebuilds the layout, and
// `ALT+1` opens a Low Level Code tab which stays open. Pressed in the middle of
// the 22-press sweep, they would move the eleven chords after them into a
// different mode and the run would be measuring a different product either side
// of them. Selected with `CT_CHORD_SUBJECTS`, one chord and one focus context
// per page load, so every press below lands on a page in its BOOT state.
//
// That freshness is also what makes `lowLevelTabs` readable. `openLowLevelCode`
// creates a component the FIRST time and only redraws afterwards
// (`utils.nim`), so a second press on the same page moves no counter — and
// "the effect did not happen" and "the effect had already happened" would be
// the same reading.
const SHADOW_CHORDS = [
  // CTRL+E — `default_config.yaml` declares `switchEdit: "CTRL+E"`, and
  // `switchEdit` is `data.actions[17]` = `data.switchToEdit()`.
  { key: 'Control+e', action: 'switchEdit', index: 17 },
  // ALT+1 — `default_config.yaml` declares `aLowLevel1: "ALT+1"`, and
  // `aLowLevel1` is `data.actions[88]` = `data.openLowLevelCode()`.
  { key: 'Alt+1', action: 'aLowLevel1', index: 88 },
];

const ALL_CHORDS = CHORDS.concat(SHADOW_CHORDS);

// The two places a caret can be when a chord is pressed, because the whole
// question is which of them each path is live in. `editor` is the case the
// override exists for; `outside` is the case that worked without it.
const ALL_FOCUS_CONTEXTS = ['editor', 'outside'];

// SELECTION, and the default is the historical one so the 22-press sweep this
// program was written for is byte-for-byte what it always was.
const subjectSel = (process.env.CT_CHORD_SUBJECTS || '').trim();
const focusSel = (process.env.CT_CHORD_FOCUS || '').trim();
const SUBJECTS = subjectSel
  ? subjectSel.split(',').map((s) => s.trim()).filter(Boolean)
      .map((k) => {
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
const consoleLines = [];
page.on('pageerror', (e) =>
  pageErrors.push(String((e && e.message) || e).slice(0, 300)));
page.on('console', (m) => consoleLines.push(m.text()));

let loadError = '';
try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(settleMs);
} catch (e) {
  loadError = String((e && e.message) || e).slice(0, 300);
}

// ---------------------------------------------------------------------------
// PRECONDITIONS, reported as facts and asserted by the shell.
//
// Every one of these is a way this probe could measure NOTHING and report a
// clean zero. A press that reaches no binding produces "1 delivery" nowhere
// and "0 deliveries" everywhere, and 0 == 0 would look like a fixed bug. The
// empty-haystack trap: the count of subjects has to be asserted too.
// ---------------------------------------------------------------------------
const pre = await page.evaluate(() => {
  const d = window.data;
  const editors = document.querySelectorAll('.monaco-editor');
  const inputArea = document.querySelector('.monaco-editor textarea.inputarea');
  return {
    hasData: !!d,
    hasActions: !!(d && d.actions),
    actionsIsArray: !!(d && Array.isArray(d.actions)),
    actionsLength: d && d.actions ? d.actions.length : -1,
    // The slots the chords below index into. A `null` here means the press
    // could not have run anything, and the delivery count would be 0 for a
    // reason that has nothing to do with the defect.
    boundActionIndexes: d && d.actions
      ? d.actions.map((f, i) => (typeof f === 'function' ? i : -1))
          .filter((i) => i >= 0)
      : [],
    monacoEditors: editors.length,
    hasMonacoInputArea: !!inputArea,
    hasMousetrap: typeof window.Mousetrap !== 'undefined',
    // Is the override actually in place in THIS bundle? The whole measurement
    // is about its effect, so a run against a bundle where it is absent must
    // say so rather than report a happy single delivery.
    stopCallbackReturnsFalseOnTextarea: (() => {
      try {
        const ta = document.createElement('textarea');
        document.body.appendChild(ta);
        const mt = window.Mousetrap;
        if (!mt || typeof mt.stopCallback !== 'function') return null;
        const r = mt.stopCallback({ type: 'keydown' }, ta, 'f10');
        ta.remove();
        return r === false;
      } catch (e) {
        return null;
      }
    })(),
  };
});

// ---------------------------------------------------------------------------
// The counter. Wraps every slot of `data.actions` in place.
// ---------------------------------------------------------------------------
await page.evaluate(() => {
  const d = window.data;
  window.__chordCounts = {};
  window.__chordOriginals = [];
  d.actions.forEach((fn, i) => {
    if (typeof fn !== 'function') return;
    window.__chordOriginals[i] = fn;
    d.actions[i] = function (...args) {
      window.__chordCounts[i] = (window.__chordCounts[i] || 0) + 1;
      return window.__chordOriginals[i].apply(this, args);
    };
  });
});

// Put the caret somewhere, and REPORT WHERE IT LANDED rather than assume.
// A press measured against a focus that silently failed to move is a press
// measured in the wrong context, and it would report a clean single delivery
// for a reason that has nothing to do with the product.
async function setFocus(where) {
  const out = { where, clicked: false };
  try {
    if (where === 'editor') {
      const ed = await page.$('.monaco-editor .view-lines');
      if (ed) { await ed.click(); out.clicked = true; }
    } else {
      // A point outside every editor. `#menu` is the topbar; clicking its
      // background moves the caret out of Monaco without activating a row.
      await page.evaluate(() => {
        if (document.activeElement && document.activeElement.blur) {
          document.activeElement.blur();
        }
        document.body.focus();
      });
      out.clicked = true;
    }
    await page.waitForTimeout(400);
  } catch (e) {
    out.error = String((e && e.message) || e).slice(0, 200);
  }
  Object.assign(out, await page.evaluate(() => {
    const a = document.activeElement;
    const inEditor = !!(a && a.closest && a.closest('.monaco-editor'));
    return {
      activeTag: a ? a.tagName : '',
      activeClass: a ? String(a.className || '').slice(0, 80) : '',
      // The fact each context is asserted on.
      activeInsideMonaco: inEditor,
    };
  }));
  return out;
}

// ---------------------------------------------------------------------------
// One press per (chord, focus context), counted separately, with the console
// watermark taken before and after so the per-path tallies belong to THIS
// press.
// ---------------------------------------------------------------------------

// THE EFFECT, read either side of every press.
//
// The delivery counters above answer "was the config's action dispatched".
// That is the whole question for a chord whose two claimants both go through
// `data.actions`, and it is HALF the question for a shadowed one: a hard
// `Mousetrap.bind` calls its target proc DIRECTLY (`ui_js.nim`'s `alt+1` runs
// `data.openLowLevelCode()`, not `data.actions[aLowLevel1]`), so the action
// counter reads 0 while the user plainly sees something happen. Reading 0 and
// concluding "the key is dead" would be wrong, and reading 0 after a fix and
// concluding "the key is alive" would be wrong in the other direction.
//
// So the observable state is reported too, and it is state the product owns
// rather than anything this probe installs: `data.ui.readOnly` and
// `data.ui.mode` are what `toggleReadOnly` and `switchToEdit` both move, and
// `data.ui.componentMapping[18]` (`Content.LowLevelCode`) is the table
// `openLowLevelCode` registers into. Same fields on both bundles, so control
// and fix are graded by one instrument.
async function uiState() {
  return page.evaluate(() => {
    const d = window.data;
    const ui = d && d.ui;
    if (!ui) return { present: false };
    let lowLevelTabs = -1;
    try {
      const m = ui.componentMapping && ui.componentMapping[18];
      lowLevelTabs = m ? Object.keys(m).length : 0;
    } catch (e) {
      lowLevelTabs = -1;
    }
    return {
      present: true,
      // `LayoutMode` — `DebugMode` and `EditMode`, as ordinals.
      mode: typeof ui.mode === 'number' ? ui.mode : null,
      readOnly: typeof ui.readOnly === 'boolean' ? ui.readOnly : null,
      lowLevelTabs,
    };
  });
}

const focusReports = [];
const results = [];
for (const where of FOCUS_CONTEXTS) {
  const f = await setFocus(where);
  focusReports.push(f);
  for (const c of SUBJECTS) {
    // Re-assert focus before every press: a chord that opens a panel or moves
    // the caret would otherwise silently change the context for the next one.
    await setFocus(where);
    const before = consoleLines.length;
    const stateBefore = await uiState();
    await page.evaluate(() => { window.__chordCounts = {}; });
    await page.keyboard.press(c.key);
    await page.waitForTimeout(600);
    const counts = await page.evaluate(() => window.__chordCounts);
    const stateAfter = await uiState();
    const fresh = consoleLines.slice(before);
    results.push({
      focus: where,
      key: c.key,
      action: c.action,
      index: c.index,
      stateBefore,
      stateAfter,
      // The three effect deltas, named so a shell check reads as a statement
      // about the product rather than as arithmetic on two blobs.
      modeChanged: stateBefore.mode !== stateAfter.mode,
      readOnlyChanged: stateBefore.readOnly !== stateAfter.readOnly,
      lowLevelTabsOpened: stateAfter.lowLevelTabs - stateBefore.lowLevelTabs,
      // The number this whole program exists to produce.
      deliveries: counts[String(c.index)] || 0,
      // AND THE WHOLE MAP, which is what lets ONE probe grade two bundles
      // whose action tables are not the same table.
      //
      // `index` above is a number baked into this file, and a fix that moves a
      // chord from one `ClientAction` to another moves the slot the check must
      // read. Baking the post-fix index in would make the probe agree with the
      // fix by construction and could not be run against the control at all;
      // reporting the raw counter map instead leaves the naming to the shell,
      // so the control arm and the fixed arm are read by the same program.
      // `pre.actionsLength` says how many slots existed, so "index 184
      // delivered 0" cannot be confused with "index 184 is not a slot".
      allDeliveries: counts,
      // Anything else the press ran, so "it doubled" is not confused with
      // "it also fired something unrelated".
      otherActions: Object.entries(counts)
        .filter(([i]) => Number(i) !== c.index)
        .map(([i, n]) => `${i}:${n}`),
      // WHICH path delivered.
      mousetrapPath: fresh.filter((l) =>
        l.includes('shortcuts: global handle')).length,
      monacoPath: fresh.filter((l) =>
        l.includes('editor: shortcuts: monaco handle')).length,
    });
  }
}

console.log(JSON.stringify({
  url,
  loadError,
  pageErrors,
  // WHAT WAS ASKED FOR, so a shell arm can assert that the selection it passed
  // is the selection that ran. `CT_CHORD_SUBJECTS` naming a chord this program
  // does not know is already fatal above; this is the other half — a run whose
  // report the shell reads under the wrong label.
  requested: {
    subjects: SUBJECTS.map((c) => c.key),
    focusContexts: FOCUS_CONTEXTS,
  },
  pre,
  focusReports,
  results,
}, null, 2));

await browser.close();
