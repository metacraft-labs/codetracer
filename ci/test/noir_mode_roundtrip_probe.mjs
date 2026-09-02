// ci/test/noir_mode_roundtrip_probe.mjs
//
// EDIT -> RUN -> REPLAY -> STOP -> EDIT, N times, in a real browser tab.
//
// THE SUBJECT IS THE TRANSITION, not the two modes.
//
// `noir_replay_probe.mjs` already drives a Run and a return, and it is the
// prior art this file is modelled on. What it does NOT do is observe the mode
// SURFACE: its whole forward-direction evidence is
// `!!document.querySelector('#next-image')`, and the shell's verdict smuggles
// the mode claim into a parenthetical over that one boolean —
// "the debugger's step control is mounted (Run leaves edit mode)". Nothing
// records what the topbar was BEFORE the Run, so "we are in replay mode now"
// is measured against an unrecorded baseline, and a product that never left
// edit mode at all could satisfy the return-leg checks trivially.
//
// So this probe takes a full MODE SNAPSHOT at every leg — before the Run,
// during the replay, and after the return — and takes them through the same
// reader, so the three are comparable values rather than three different
// questions. The snapshot names the topbar surface the product itself
// declares (`data-topbar-surface`, emitted by both panel roots for exactly
// this purpose), the debugger panes that are mounted, and the raw Monaco
// `readOnly` option per editor.
//
// This program ASSERTS NOTHING. It reports facts and lets
// `ci/test/noir-mode-roundtrip.sh` count assertions over them, so the arms and
// the control read one instrument. That split is the house style here
// (`noir_replay_probe.mjs`, `noir_build_probe.mjs`, `noir_edit_persists_probe
// .mjs` all say the same thing in their own headers) and its point is that an
// arm cannot be green because the probe was lenient.
//
// Usage:  node noir_mode_roundtrip_probe.mjs <url> [settleMs] [trips] [steps]
// Output: one JSON document on stdout.

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 60000);
const trips = Number(process.argv[4] || 3);
const steps = Number(process.argv[5] || 3);

if (!url) {
  console.error('usage: noir_mode_roundtrip_probe.mjs <url> [settleMs] [trips] [steps]');
  process.exit(2);
}

const report = {
  url,
  trips,
  steps,
  mounted: false,
  pageErrors: [],
  consoleMilestones: [],
  // One entry per leg, in the order they were taken. The whole point of the
  // probe: a list of comparable snapshots rather than scattered booleans.
  legs: [],
  editMarker: '',
  markerReachedModel: false,
  markerPresentPerLeg: [],
  gestureErrors: [],
  fatal: '',
};

// ---------------------------------------------------------------------------
// The mode snapshot — ONE reader, used at every leg
// ---------------------------------------------------------------------------
//
// EVERY INPUT TO THE VERDICT IS RECORDED, including whether the instrument
// itself exists. `hasGetEditors` is here because `monaco.editor.getEditors`
// is not present in every Monaco build, and without it "no editable editor"
// and "no way to ask" are the same false — which is exactly how a boolean
// `stepButtonPresent: false` once claimed a toolbar was unmounted for three
// passes while the toolbar was on screen.
const snapshotScript = () => {
  const host = document.getElementById('isonim-debug-controls');
  const panel = host && host.firstElementChild;

  // WHAT THE HOST ACTUALLY HOLDS. Not a boolean about one selector: the
  // children, by tag and id, so a snapshot that disagrees with expectation
  // can say what was there instead.
  const hostChildren = host
    ? Array.from(host.children).map(
        (c) => `${c.tagName.toLowerCase()}.${String(c.className || '').slice(0, 40)}`)
    : null;

  const buttonIds = panel
    ? Array.from(panel.querySelectorAll('button')).map((b) => b.id || '(no id)')
    : [];

  const ed = window.monaco && window.monaco.editor;
  const hasGetEditors = !!(ed && typeof ed.getEditors === 'function');
  const editors = hasGetEditors ? (ed.getEditors() || []) : [];
  const readOnlyFlags = editors.map((e) => {
    try {
      const v = e.getRawOptions && e.getRawOptions().readOnly;
      return typeof v === 'boolean' ? v : String(v);
    } catch (err) { return 'threw'; }
  });

  // Debugger-only panes. Their presence is the LAYOUT half of the mode
  // question, and `Mode-Transitions.md` §7 makes it the primary signal:
  // "Which panes are present is the primary signal; the toolbar is the
  // second." So both are recorded, and the shell asserts on both.
  const debugPaneSelectors = [
    '#stateComponent-0', '#calltraceComponent-0',
    '#eventLogComponent-0', '#traceComponent-0',
  ];

  return {
    hostPresent: !!host,
    hostChildren,
    // The product's own declaration of which panel is mounted.
    topbarSurface: panel ? panel.getAttribute('data-topbar-surface') : null,
    editToolbarButtonCount: panel ? panel.getAttribute('data-button-count') : null,
    buttonIds,
    // Named individually because each answers a different spec sentence.
    stopButtonPresent: buttonIds.includes('stop-image'),
    stepButtonPresent: buttonIds.includes('next-image'),
    buildButtonPresent: buttonIds.includes('build-image'),
    runButtonPresent: buttonIds.includes('run-image'),
    hasGetEditors,
    editorCount: editors.length,
    readOnlyFlags,
    anyEditable: readOnlyFlags.some((f) => f === false),
    allReadOnly: readOnlyFlags.length > 0 && readOnlyFlags.every((f) => f === true),
    domEditors: document.querySelectorAll('.monaco-editor').length,
    debugPanesPresent: debugPaneSelectors.filter((s) => document.querySelector(s)),
  };
};

async function snapshot(page, label) {
  let snap;
  try {
    snap = await page.evaluate(snapshotScript);
  } catch (e) {
    snap = { readError: String((e && e.message) || e).slice(0, 200) };
  }
  snap.leg = label;
  report.legs.push(snap);
  return snap;
}

// ---------------------------------------------------------------------------
// A real pointer click, hit-tested before it is sent
// ---------------------------------------------------------------------------
//
// Playwright's own actionability already hit-tests (it refuses to click an
// element that would not receive the pointer), but it reports that as a
// timeout, and a timeout is indistinguishable from "the control was never
// mounted". So the geometry is read FIRST and recorded, and the click is sent
// at a point this probe has confirmed lands on the element — which is what
// caught a diagnostics pane parked at x = -9999 in a sibling gate.
async function hitTestedClick(page, selector, what) {
  const geo = await page.evaluate((sel) => {
    const el = document.querySelector(sel);
    if (!el) return { found: false };
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) {
      return { found: true, zeroSized: true, rect: { x: r.x, y: r.y, w: r.width, h: r.height } };
    }
    const cx = r.x + r.width / 2;
    const cy = r.y + r.height / 2;
    const top = document.elementFromPoint(cx, cy);
    return {
      found: true,
      zeroSized: false,
      rect: { x: r.x, y: r.y, w: r.width, h: r.height },
      point: { x: cx, y: cy },
      // Does the point actually reach the control, or something over it?
      reaches: !!top && (top === el || el.contains(top) || top.contains(el)),
      topAtPoint: top
        ? `${top.tagName.toLowerCase()}#${top.id || ''}.${String(top.className || '').slice(0, 40)}`
        : null,
    };
  }, selector);

  const record = { what, selector, ...geo, clicked: false };
  if (!geo.found || geo.zeroSized || !geo.reaches) {
    record.error = !geo.found
      ? 'no such element'
      : geo.zeroSized ? 'element has zero size' : 'a point on the element does not reach it';
    report.gestureErrors.push(record);
    return record;
  }

  try {
    // The real thing: CDP mouse input at a coordinate we hit-tested, not
    // `el.click()`, which dispatches a synthetic event no user could send and
    // which reaches controls that are covered, disabled or off-screen.
    await page.mouse.click(geo.point.x, geo.point.y);
    record.clicked = true;
  } catch (e) {
    record.error = String((e && e.message) || e).slice(0, 200);
    report.gestureErrors.push(record);
  }
  return record;
}

// Blur the editor before anything that must not be swallowed by Monaco.
async function blurEditor(page) {
  try {
    await page.click('#menu', { position: { x: 5, y: 5 }, timeout: 3000 });
  } catch (e) { /* a missing topbar shows up in the snapshots */ }
}

// Wait for a snapshot predicate rather than a fixed sleep, and report how
// long it took — a transition that needed 19 of 20 seconds is a fact worth
// having even when it passes.
async function waitForSurface(page, wanted, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    try {
      last = await page.evaluate(() => {
        const host = document.getElementById('isonim-debug-controls');
        const panel = host && host.firstElementChild;
        return panel ? panel.getAttribute('data-topbar-surface') : null;
      });
      if (last === wanted) return { reached: true, waitedMs: timeoutMs - (deadline - Date.now()), surface: last };
    } catch (e) { /* keep waiting; the snapshot records the end state */ }
    await page.waitForTimeout(300);
  }
  return { reached: false, waitedMs: timeoutMs, surface: last };
}

const caretTops = (page) => page.evaluate(() => {
  const marks = document.querySelectorAll('.view-overlays .on, .view-line .on, .on');
  for (const m of marks) {
    const r = m.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    return Math.round(r.y);
  }
  return -1;
});

const modelText = (page, marker) => page.evaluate((mk) => {
  const models = (window.monaco && window.monaco.editor && window.monaco.editor.getModels()) || [];
  const m = models.find((x) => x.getValue().includes(mk));
  if (m) return m.getValue();
  return models.length ? models[0].getValue() : '';
}, marker);

// ---------------------------------------------------------------------------

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

page.on('pageerror', (e) => report.pageErrors.push(String(e.message).slice(0, 300)));
page.on('console', (m) => {
  const t = m.text();
  if (/codetracer-web-renderer:|codetracer-replay:|noir-build:|edit-toolbar|trace accepted:/.test(t)) {
    report.consoleMilestones.push(t.slice(0, 300));
    if (t.includes('codetracer-web-renderer: ok')) report.mounted = true;
  }
});

try {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(Math.min(settleMs, 20000));

  // -------------------------------------------------------------------
  // Leg 0 — EDIT, the baseline every later leg is compared against.
  // -------------------------------------------------------------------
  await snapshot(page, 'edit-initial');

  // Type a marker, so "the edit survived" is a claim about something that
  // was demonstrably there. Recorded separately from the round trip so a
  // failure can say WHICH half broke.
  const marker = `MODETRIP_${Date.now().toString(36).toUpperCase()}`;
  report.editMarker = marker;
  try {
    const lineTarget = await page.$('.view-line');
    if (lineTarget) await lineTarget.click({ timeout: 3000 });
    else await page.click('#editorComponent-0', { timeout: 3000 });
    await page.keyboard.type(`// ${marker}\n`);
    await page.waitForTimeout(500);
    const txt = await modelText(page, marker);
    report.markerReachedModel = txt.includes(marker);
  } catch (e) {
    report.gestureErrors.push({ what: 'type marker', error: String(e.message).slice(0, 200) });
  }

  for (let trip = 1; trip <= trips; trip += 1) {
    // -----------------------------------------------------------------
    // EDIT -> REPLAY, by the Run button on the edit toolbar.
    // -----------------------------------------------------------------
    await blurEditor(page);
    const runClick = await hitTestedClick(page, '#run-image', `trip ${trip}: Run`);
    report.legs.push({ leg: `trip-${trip}-run-gesture`, gesture: runClick });

    // 240s, not 60s. THE FIRST COMPILE IS NOT LIKE THE OTHERS: measured on
    // this gate's own runs, trip 1 timed out at 60s and then at 240s while trips 2 and 3
    // reached the debugger in 631ms, because the cold Noir compile in wasm
    // dominates and everything after it is warm. A timeout tuned to the warm
    // case reports the product as broken on the one run a real visitor makes.
    const arrived = await waitForSurface(page, 'debugger-controls', 420000);
    report.legs.push({ leg: `trip-${trip}-run-wait`, ...arrived });
    await page.waitForTimeout(1500);
    await snapshot(page, `trip-${trip}-replay`);

    // Step, so the session is demonstrably live rather than merely painted.
    const tops = new Set();
    const first = await caretTops(page);
    if (first >= 0) tops.add(first);
    for (let i = 0; i < steps; i += 1) {
      const c = await hitTestedClick(page, '#next-image', `trip ${trip}: step ${i + 1}`);
      if (!c.clicked) break;
      await page.waitForTimeout(800);
      const t = await caretTops(page);
      if (t >= 0) tops.add(t);
    }
    report.legs.push({ leg: `trip-${trip}-step`, caretPositions: Array.from(tops) });

    // -----------------------------------------------------------------
    // REPLAY -> EDIT, by the STOP BUTTON.
    //
    // The button is the point. `Debugger-Controls.md` requires Stop to be
    // reachable by toolbar button, menu entry and chord; the chord existed
    // and reached a `stopAction` that was `discard`, and the button did not
    // exist at all. Driving the BUTTON is what makes this gate able to fail
    // for the reason the user would hit.
    // -----------------------------------------------------------------
    await blurEditor(page);
    // THE SURFACE IMMEDIATELY BEFORE THE GESTURE, so the shell can assert that
    // the return CHANGED something.
    //
    // Without this the return leg has a false pass with a very convincing
    // shape: on a trip whose Run never entered Debug mode, the tab is still on
    // `edit-commands`, `waitForSurface('edit-commands')` returns `reached:
    // true` on its first poll, and the gate prints "pressing Stop MOVED the
    // mode ... 0ms" — measured, in this gate's own first run. A transition
    // assertion has to name the surface it came FROM.
    const surfaceBeforeStop = await page.evaluate(() => {
      const host = document.getElementById('isonim-debug-controls');
      const panel = host && host.firstElementChild;
      return panel ? panel.getAttribute('data-topbar-surface') : null;
    });
    const stopClick = await hitTestedClick(page, '#stop-image', `trip ${trip}: Stop`);
    report.legs.push({
      leg: `trip-${trip}-stop-gesture`,
      surfaceBefore: surfaceBeforeStop,
      gesture: stopClick,
    });

    const back = await waitForSurface(page, 'edit-commands', 20000);
    report.legs.push({ leg: `trip-${trip}-stop-wait`, ...back });
    await page.waitForTimeout(1000);
    await snapshot(page, `trip-${trip}-edit`);

    const txt = await modelText(page, marker);
    report.markerPresentPerLeg.push({ trip, present: txt.includes(marker), chars: txt.length });
  }
} catch (e) {
  report.fatal = String((e && e.message) || e).slice(0, 400);
} finally {
  await browser.close();
}

console.log(JSON.stringify(report, null, 2));
