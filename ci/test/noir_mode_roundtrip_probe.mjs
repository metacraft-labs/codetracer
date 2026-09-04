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
// THE MUTATION ARM RUNS IN THIS TAB, AFTER THE CONTROL TRIPS, AND THAT IS A
// MEASUREMENT DECISION RATHER THAN A CONVENIENCE.
//
// The arm exists to show that the return assertions CAN go red — a check that
// has never been observed to fail certifies the defect instead of catching it.
// It used to be a second bundle on disk with a `<script>` injected into
// `index.html`, driven by a SECOND browser launch. That arm could not be shown
// to redden anything, because a fresh tab pays the cold Noir/wasm compile
// again: its single trip hit the compile wall, the forward leg never arrived,
// and all three arm checks reported "the arm broke the probe" — which proves
// nothing about the return assertion in either direction.
//
// Driven here, the arm is WARM BY CONSTRUCTION: same tab, same worker, same
// compiled modules, immediately after a control trip that just succeeded. And
// it is a strictly smaller mutation — nothing on disk differs between control
// and arm, so the only variable is the Stop button's click handler, which is
// exactly the variable the arm is about.
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
  // The mutation arm's own record. `armInstalled` is the "verify the mutation
  // landed" step: an arm whose instrument never attached would produce a green
  // return and be indistinguishable from a working product.
  armInstalled: false,
  armSwallowedClicks: 0,
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

  // THE EDITOR THE USER IS TYPING INTO, ASKED ABOUT BY NAME.
  //
  // `anyEditable` below is `some(f === false)` over EVERY Monaco instance in
  // the document, and two of them never follow the mode at all: the tracepoint
  // editor is constructed `readOnly: false` unconditionally
  // (`src/frontend/ui/trace.nim:1671-1680`) and the inline diff editor
  // `readOnly: true` (`src/frontend/ui/editor.nim:1938`). So one mounted
  // tracepoint editor satisfies "the editors are writable again" on its own,
  // with the source editor read-only — which is precisely the failure a mode
  // transition makes possible, since a rebuilt pane can leave the visible
  // instance behind while another instance carries the new state.
  //
  // An existential over a heterogeneous collection cannot fail for the reason
  // it was written to detect, because some other member always answers for it.
  // This resolves the ONE editor the frontend considers active, the same way
  // the frontend's own code reaches it.
  let activeSourceEditorReadOnly = 'no-active-editor';
  try {
    const data = window.data;
    const active = data && data.ui && data.ui.editors &&
      data.ui.editors[data.services && data.services.editor &&
        data.services.editor.active];
    const mon = active && active.monacoEditor;
    if (mon && mon.getRawOptions) {
      const v = mon.getRawOptions().readOnly;
      activeSourceEditorReadOnly = typeof v === 'boolean' ? v : String(v);
    }
  } catch (err) { activeSourceEditorReadOnly = 'threw'; }

  // Debugger-only panes. Their presence is the LAYOUT half of the mode
  // question, and `Mode-Transitions.md` §7 makes it the primary signal:
  // "Which panes are present is the primary signal; the toolbar is the
  // second." So both are recorded, and the shell asserts on both.
  const debugPaneSelectors = [
    '#stateComponent-0', '#calltraceComponent-0',
    '#eventLogComponent-0', '#traceComponent-0',
  ];

  // THE SIDEBAR PANES, ASKED WHETHER THEY HOLD ANYTHING — one field each.
  //
  // Reported: "when I enter debug mode and then hit the Stop button, the FILES,
  // VCS and TESTS panels become empty." MOUNTED AND EMPTY is the failure, so a
  // selector match is not the measurement: every one of these containers is
  // present in both modes and was present throughout the reported failure. What
  // changed is that they held no rows.
  //
  // Recorded per pane and never summed. "The sidebar has content" is an
  // existential over three unlike things and cannot fail for its own reason —
  // FILES alone would answer for VCS, exactly as `anyEditable` above let a
  // tracepoint editor answer for the source editor. Three fields, three
  // assertions, three failure messages that name a pane.
  const paneRowCount = (containerSelector, rowSelector) => {
    const host = document.querySelector(containerSelector);
    if (!host) return 'absent';
    return host.querySelectorAll(rowSelector).length;
  };

  // Each row selector is the one the pane's own IsoNim view emits, so a count
  // above zero means the view mounted AND rendered, which is the pair that came
  // apart: the mount latch survived a container the layout swap destroyed, so
  // the view never re-mounted into the fresh, empty host.
  //
  // FILES IS MATCHED BY PREFIX, and the exact id is why this gate could never
  // have passed. `viewmodel/views/isonim_filesystem_view.nim:442` emits
  // `id = "filesystemComponent"` with NO `-0`; only the legacy Karax path used
  // `filesystemComponent-{id}` (`ui/filesystem.nim:511-512` tries the keyed id
  // and then falls back to the bare one). This probe asked for
  // `#filesystemComponent-0`, got no host, and reported `filesEntries:
  // 'absent'` — which `noir-mode-roundtrip.sh`'s `num()` turns into -1 and
  // every `-gt 0` comparison then fails. Measured on the deployed build: the
  // host is `#filesystemComponent`, it carries `data-ct-isonim-mounted="1"`,
  // and it holds 12 `a.jstree-anchor` rows. The pane was never the problem.
  //
  // `[id^="filesystemComponent"]` is the form `jump_follow_probe.mjs:262` and
  // `noir_demo_path_probe.mjs:221` already use, and `pane_children_probe.mjs`
  // records having made exactly this correction — so this file was the last
  // one holding the stale id.
  const filesEntries = paneRowCount('[id^="filesystemComponent"]', 'a.jstree-anchor');
  const testsEntries = paneRowCount('#testResultsComponent-0',
    '.test-results-row, .isonim-test-row, li');
  let vcsEntries = paneRowCount('#vcsComponent-0', '.vcs-commit, .isonim-vcs-commit, li');
  if (vcsEntries === 'absent') {
    // The component id is capitalised inconsistently in the layout config; the
    // pane's own mount helper tries both, so the probe must too.
    vcsEntries = paneRowCount('#vCSComponent-0', '.vcs-commit, .isonim-vcs-commit, li');
  }

  // WHETHER VCS PAINTED A BODY AT ALL, which is a different question from how
  // many commits it lists and is the one this gate can actually ask.
  //
  // The web fixture is a template unpacked into a VFS; it is NOT a git
  // repository, so the pane's correct and permanent answer is the
  // `.vcs-no-repo` empty state — zero `.vcs-commit` rows, forever. The
  // assertion `vcsEntries > 0` therefore could not be satisfied by any healthy
  // web build, which is the second reason this gate has never been green.
  //
  // The reported defect was "the VCS panel becomes EMPTY after Stop", and an
  // emptied host and a rendered no-repo state are distinguishable: the latter
  // has a body. So the subject here is the body, and the commit count stays
  // beside it for the case where a fixture does have history.
  const vcsBody = (() => {
    const host = document.querySelector('#vcsComponent-0')
      || document.querySelector('#vCSComponent-0');
    if (!host) return 'absent';
    const rendered = host.querySelector('.vcs-container, .vcs-panel-body');
    if (!rendered) return 'no-body';
    if (host.querySelector('.vcs-no-repo')) return 'no-repo';
    return 'commits';
  })();

  // The mark `ui/isonim_panel_mount.nim` writes onto a container it has mounted
  // a view into. Recorded so a failure can distinguish "the view never mounted"
  // from "the view mounted and rendered nothing" — the first is this defect,
  // the second would be a different one.
  const paneMounted = (sel) => {
    const host = document.querySelector(sel);
    return host ? host.getAttribute('data-ct-isonim-mounted') === '1' : 'absent';
  };

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
    // The claim `anyEditable` was meant to make. Kept alongside it rather than
    // replacing it, so a disagreement between the two is visible in the
    // recorded snapshot and names itself.
    activeSourceEditorReadOnly,
    activeSourceEditorEditable: activeSourceEditorReadOnly === false,
    allReadOnly: readOnlyFlags.length > 0 && readOnlyFlags.every((f) => f === true),
    domEditors: document.querySelectorAll('.monaco-editor').length,
    debugPanesPresent: debugPaneSelectors.filter((s) => document.querySelector(s)),
    // One field per pane, by name. See `paneRowCount` above for why this is
    // never collapsed into a single "the sidebar is populated" boolean.
    filesEntries,
    vcsEntries,
    vcsBody,
    testsEntries,
    filesMounted: paneMounted('[id^="filesystemComponent"]'),
    vcsMounted: paneMounted('#vcsComponent-0'),
    testsMounted: paneMounted('#testResultsComponent-0'),
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

  // A GESTURE THAT DID NOT PRODUCE A `click` EVENT IS NOT A PRESSED BUTTON,
  // and until now this probe could not tell the difference.
  //
  // `record.clicked` says only that `page.mouse.click` did not throw. It says
  // nothing about whether the browser produced a `click`, and the browser
  // produces none when `mousedown` and `mouseup` land on different nodes —
  // which is exactly what happens while the topbar is being re-mounted. So
  // this gate reported `clicked: true` for a Stop gesture that reached
  // nothing, three trips running, and the failure was read as a dead handler.
  //
  // The listener goes on `window` in the CAPTURE phase, so it runs before any
  // document-level listener: the mutation arm's instrument swallows the click
  // with `stopImmediatePropagation` on `document`, and this must still record
  // that the EVENT existed. `clickEventFired` is about the browser; whether
  // the product's own handler ran is what the consequence checks are for.
  await page.evaluate((sel) => {
    window.__ctClickSeen = false;
    const onClick = (e) => {
      const target = document.querySelector(sel);
      if (target && (e.target === target || target.contains(e.target))) {
        window.__ctClickSeen = true;
      }
    };
    window.addEventListener('click', onClick, true);
    window.__ctClickOff = () => window.removeEventListener('click', onClick, true);
  }, selector);

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

  record.clickEventFired = await page.evaluate(() => {
    const seen = !!window.__ctClickSeen;
    if (window.__ctClickOff) window.__ctClickOff();
    return seen;
  });
  if (record.clicked && !record.clickEventFired) {
    record.error = 'the pointer went down and up on the element and the browser ' +
      'produced no click event — the node was replaced between them';
    report.gestureErrors.push(record);
  }
  return record;
}

// Blur the editor before anything that must not be swallowed by Monaco.
//
// THIS USED TO BE A POINTER CLICK ON `#menu`, AND THAT GESTURE DESTROYED THE
// VERY NEXT GESTURE — which is what made this gate report a broken product.
//
// `#isonim-debug-controls` is a CHILD of `#menu`, so `click('#menu', {x:5,y:5})`
// lands on the topbar's own background. That rebuilds the menu shell, and
// `renderMenuShellInto` re-creates the topbar host, so the toolbar is
// re-mounted and every button in it is a NEW DOM node. A pointer click
// delivered while that is happening has its `mousedown` and its `mouseup` land
// on two different nodes, and a browser fires NO `click` event at all when the
// two disagree.
//
// Measured, four arms against the same tab and the same bundle
// (`data-topbar-surface` read before and after, listeners in the capture
// phase):
//
//   nothing before the Run click      mousedown/mouseup/click, same node -> Run ran
//   click the TOPBAR background first mousedown+mouseup, DIFFERENT nodes, no
//                                     click event at all      -> Run did nothing
//   click inside the EDITOR first     same node               -> Run ran
//   blur via JS, no pointer gesture   same node               -> Run ran
//
// So the old blur destroyed the Run on every trip. With the Run lost, the tab
// stayed in edit mode for the whole 420-second forward wait, and the gate then
// attributed that wait to a "cold Noir compile" — a number that does not
// exist: measured here, `nbpCompile-started` to `nbpCompile-exit` is 343ms on
// the FIRST compile of a fresh tab, and Run to `debugger-controls` is 633ms.
// The same lost-click mechanism is why the Stop button appeared dead: the
// probe reported `clicked: true`, which only says `page.mouse.click` did not
// throw, and never that a `click` event was produced.
//
// A JS blur touches no DOM, rebuilds nothing, and leaves the node the next
// gesture was hit-tested against exactly where it was.
//
// THE UNDERLYING PRODUCT DEFECT IS NOT FIXED BY THIS and is not this file's to
// fix. It is fixed in the product — `renderMenuShellInto` now rebuilds the
// shell AROUND the topbar host instead of over it — and it is asserted by
// `menuGestureLeg` below, which makes exactly this gesture on purpose and
// then presses a debugger control. What the JS blur buys is that every OTHER
// leg here measures the product instead of measuring its own blur.
async function blurEditor(page) {
  try {
    await page.evaluate(() => {
      const active = document.activeElement;
      if (active && typeof active.blur === 'function') active.blur();
      const ed = window.monaco && window.monaco.editor;
      for (const e of ((ed && ed.getEditors && ed.getEditors()) || [])) {
        try {
          if (e.hasTextFocus && e.hasTextFocus() && e.getDomNode) e.getDomNode().blur();
        } catch (err) { /* one editor refusing to blur is not a failed blur */ }
      }
    });
  } catch (e) { /* a page that cannot be evaluated shows up in the snapshots */ }
}

// Poll for a DOM fact rather than sleeping for a duration.
//
// `budgetMs` is an upper bound on WAITING, not a claim about how long the
// product may take: the answer is read again after every poll and returned as
// soon as it is what was asked for. A fixed sleep in its place is the defect
// class that passes on a fast machine and reports a healthy product as broken
// on a loaded runner.
async function waitForElement(page, id, wanted, budgetMs) {
  const deadline = Date.now() + budgetMs;
  for (;;) {
    let present = false;
    try {
      present = await page.evaluate((elementId) => !!document.getElementById(elementId), id);
    } catch (e) { /* a page mid-navigation answers on the next poll */ }
    if (present === wanted) return true;
    if (Date.now() >= deadline) return false;
    await page.waitForTimeout(50);
  }
}

// ---------------------------------------------------------------------------
// THE MENU GESTURE — the press a menu interaction used to swallow
// ---------------------------------------------------------------------------
//
// `#isonim-debug-controls` is a CHILD of `#menu`, and a menu-shell rebuild
// re-created that host. A pointer press is `mousedown` then `mouseup`, and per
// the DOM spec the browser fires a `click` ONLY when both landed on the same
// node — so a rebuild between them produced NO click event at all, and the
// press was silently discarded. Every control in the toolbar was affected:
// Run, Step, Stop.
//
// THE GESTURE HAS TO CAUSE A REBUILD, or it asserts nothing. `ui/menu.nim`'s
// render gate (issue #555) skips a rebuild whose signature has not changed, so
// merely clicking the caption bar's background is a no-op and a check written
// over it PASSES ON THE UNFIXED PRODUCT — measured, against a bundle built from
// `cloud`: all three of these checks were green there when the gesture was a
// bare background click.
//
// Opening the menu changes `MenuShellModel.active`, which IS in the signature,
// so the shell is genuinely rebuilt. And the press that follows is the sharpest
// case there is: `ui/menu.nim`'s dismiss handler runs on `mousedown` in the
// CAPTURE phase, so it rebuilds the shell BETWEEN the `mousedown` and the
// `mouseup` of the very press the user is making.
//
// TWO FACTS, RECORDED SEPARATELY, because they fail for different reasons.
// `survived` is about the NODES — tags written onto the topbar host and one of
// its buttons before the gesture and read back after it, so "the same node" is
// a property of the node and not of the markup it happens to produce again.
// `control` is the user-visible consequence, asserted through
// `clickEventFired` and not through `clicked`, which only ever meant
// `page.mouse.click` did not throw.
async function menuGestureLeg(page, prefix, who) {
  const leg = { leg: `${prefix}-menu-gesture` };

  leg.tagged = await page.evaluate(() => {
    const host = document.getElementById('isonim-debug-controls');
    if (!host) return { ok: false, why: 'no #isonim-debug-controls' };
    host.__ctHostTag = 'ct-host';
    const button = host.querySelector('button');
    if (!button) return { ok: false, why: 'the topbar carries no button' };
    button.__ctButtonTag = 'ct-button';
    return { ok: true, buttons: host.querySelectorAll('button').length };
  });

  // Open the menu, by its own button, at a hit-tested point.
  leg.open = await hitTestedClick(page, '#menu-root', `${who}: open the menu`);
  // WAIT ON THE EVENT, NOT ON A CLOCK. `#menu-main` is emitted only while
  // `MenuShellModel.active` is true, so its appearance IS the shell having
  // been re-rendered with a different signature. A fixed sleep here would
  // pass on a fast machine and report a product defect on a loaded runner.
  leg.menuOpen = await waitForElement(page, 'menu-main', true, 5000);

  leg.survived = await page.evaluate(() => {
    const host = document.getElementById('isonim-debug-controls');
    const button = host && host.querySelector('button');
    return {
      hostPresent: !!host,
      host: !!(host && host.__ctHostTag === 'ct-host'),
      button: !!(button && button.__ctButtonTag === 'ct-button'),
      buttons: host ? host.querySelectorAll('button').length : 0,
    };
  });

  // The press. Its own `mousedown` dismisses the open menu, so the shell is
  // rebuilt in the middle of it — which is the case that produced no `click`.
  leg.control = await hitTestedClick(
    page, '#next-image', `${who}: a debugger control pressed with the menu open`);
  // The press dismisses the menu; wait for THAT rather than for a duration.
  leg.menuDismissed = await waitForElement(page, 'menu-main', false, 5000);
  // Leave the menu closed whatever happened, so no later leg inherits it.
  leg.menuStillOpen = await page.evaluate(() => {
    const main = document.getElementById('menu-main');
    if (!main) return false;
    document.body.click();
    return true;
  });
  report.legs.push(leg);
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

  // ONE ROUND TRIP, used by both the control trips and the mutation arm.
  //
  // Shared deliberately: an arm driven by different code from the control is
  // an arm that can be green (or red) for a reason the control never sees.
  // `prefix` names the legs; `stepCount` is 0 for the arm, whose subject is
  // the return and not the stepping.
  async function roundTrip(prefix, who, stepCount, menuGesture = false) {
    // -----------------------------------------------------------------
    // EDIT -> REPLAY, by the Run button on the edit toolbar.
    // -----------------------------------------------------------------
    await blurEditor(page);
    const runClick = await hitTestedClick(page, '#run-image', `${who}: Run`);
    report.legs.push({ leg: `${prefix}-run-gesture`, gesture: runClick });

    // 240s, not 60s. THE FIRST COMPILE IS NOT LIKE THE OTHERS: measured on
    // this gate's own runs, trip 1 timed out at 60s and then at 240s while trips 2 and 3
    // reached the debugger in 631ms, because the cold Noir compile in wasm
    // dominates and everything after it is warm. A timeout tuned to the warm
    // case reports the product as broken on the one run a real visitor makes.
    const arrived = await waitForSurface(page, 'debugger-controls', 420000);
    report.legs.push({ leg: `${prefix}-run-wait`, ...arrived });
    await page.waitForTimeout(1500);
    await snapshot(page, `${prefix}-replay`);

    // The menu-bar gesture, driven here because this is where the debugger
    // controls exist and pressing one is harmless — a step in a replay.
    if (menuGesture) {
      await menuGestureLeg(page, prefix, who);
    }

    // Step, so the session is demonstrably live rather than merely painted.
    if (stepCount > 0) {
      const tops = new Set();
      const first = await caretTops(page);
      if (first >= 0) tops.add(first);
      const moveLines = [];
      for (let i = 0; i < stepCount; i += 1) {
        const movesBefore = report.consoleMilestones.length;
        const c = await hitTestedClick(page, '#next-image', `${who}: step ${i + 1}`);
        if (!c.clicked) break;
        // WAIT FOR THE MOVE THE ENGINE REPORTS, not for 800ms.
        //
        // The reading this guards is the caret's `y` — a PIXEL, which is wrong
        // rather than absent when read early: mid-step it returns the previous
        // position's offset, and `tops` is a Set, so an early read collapses
        // two distinct positions into one and the leg concludes the caret did
        // not move. A duration that is usually long enough produces a wrong
        // NUMBER here, not a missing one.
        //
        // `ui/web_replay_host.nim` reports `codetracer-replay: move
        // <path>:<line> missingPath=<bool>` on every `ct/complete-move`,
        // whether or not the position changed — which is the distinction a
        // caret poll cannot draw. This probe's console filter is by CONTENT
        // and `codetracer-replay:` is already in its allowlist, so the line was
        // being captured and not used.
        const moveDeadline = Date.now() + 15000;
        let moveLine = '';
        while (Date.now() < moveDeadline) {
          moveLine = report.consoleMilestones.slice(movesBefore).find(
            (l) => l.includes('codetracer-replay: move ')) || '';
          if (moveLine) break;
          await page.waitForTimeout(100);
        }
        moveLines.push(moveLine || '(no move reported within 15s)');
        const t = await caretTops(page);
        if (t >= 0) tops.add(t);
      }
      report.legs.push({
        leg: `${prefix}-step`,
        caretPositions: Array.from(tops),
        // Beside the pixels, so a failure says whether the move was never
        // reported or was reported and landed where it started.
        moveLines,
      });
    }

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
    const stopClick = await hitTestedClick(page, '#stop-image', `${who}: Stop`);
    report.legs.push({
      leg: `${prefix}-stop-gesture`,
      surfaceBefore: surfaceBeforeStop,
      gesture: stopClick,
    });

    const back = await waitForSurface(page, 'edit-commands', 20000);
    report.legs.push({ leg: `${prefix}-stop-wait`, ...back });
    await page.waitForTimeout(1000);
    await snapshot(page, `${prefix}-edit`);
  }

  for (let trip = 1; trip <= trips; trip += 1) {
    // The menu-bar gesture is driven ONCE, on the first trip: its subject is a
    // structural property of the topbar host, not something that could hold on
    // one trip and fail on the next.
    await roundTrip(`trip-${trip}`, `trip ${trip}`, steps, trip === 1);
    const txt = await modelText(page, marker);
    report.markerPresentPerLeg.push({ trip, present: txt.includes(marker), chars: txt.length });
  }

  // -------------------------------------------------------------------
  // THE MUTATION ARM — a Stop that is present, hit-testable, and reaches
  // nothing.
  //
  // This is the product as it shipped before this campaign: `renderer
  // .stopAction` was `discard` from the initial open-source commit, and the
  // toolbar had no Stop button at all. The instrument reproduces the reachable
  // half of that — the button stays, the click lands on it, and the handler
  // behind it never runs — because "the control is missing" and "the control
  // does nothing" fail this gate's return assertions for different reasons and
  // only the second one is the defect that survived three other gates.
  //
  // Capture phase with `stopImmediatePropagation`, so it runs before whatever
  // the product bound and the product's own handler never sees the click.
  // -------------------------------------------------------------------
  report.armInstalled = await page.evaluate(() => {
    window.__ctArmSwallowed = 0;
    document.addEventListener('click', function (e) {
      let t = e.target;
      while (t) {
        if (t.id === 'stop-image') {
          window.__ctArmSwallowed += 1;
          e.stopImmediatePropagation();
          e.preventDefault();
          return;
        }
        t = t.parentElement;
      }
    }, true);
    return true;
  });

  if (report.armInstalled) {
    await roundTrip('arm', 'arm', 0);
    // VERIFY THE MUTATION LANDED. Without this the arm's red return is
    // ambiguous: a listener that never attached, and a Stop that never
    // reached its handler, produce the same "the mode did not come back".
    report.armSwallowedClicks = await page.evaluate(() => window.__ctArmSwallowed || 0);
  }
} catch (e) {
  report.fatal = String((e && e.message) || e).slice(0, 400);
} finally {
  await browser.close();
}

console.log(JSON.stringify(report, null, 2));
