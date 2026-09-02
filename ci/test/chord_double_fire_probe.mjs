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

// The two places a caret can be when a chord is pressed, because the whole
// question is which of them each path is live in. `editor` is the case the
// override exists for; `outside` is the case that worked without it.
const FOCUS_CONTEXTS = ['editor', 'outside'];

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
const focusReports = [];
const results = [];
for (const where of FOCUS_CONTEXTS) {
  const f = await setFocus(where);
  focusReports.push(f);
  for (const c of CHORDS) {
    // Re-assert focus before every press: a chord that opens a panel or moves
    // the caret would otherwise silently change the context for the next one.
    await setFocus(where);
    const before = consoleLines.length;
    await page.evaluate(() => { window.__chordCounts = {}; });
    await page.keyboard.press(c.key);
    await page.waitForTimeout(600);
    const counts = await page.evaluate(() => window.__chordCounts);
    const fresh = consoleLines.slice(before);
    results.push({
      focus: where,
      key: c.key,
      action: c.action,
      index: c.index,
      // The number this whole program exists to produce.
      deliveries: counts[String(c.index)] || 0,
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
  pre,
  focusReports,
  results,
}, null, 2));

await browser.close();
