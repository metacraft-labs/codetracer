// tests_pane_row_controls_probe.mjs — drive the TESTS pane's two per-row
// controls in a real browser and report what happened.
//
// WHAT THIS EXISTS TO SEPARATE
// ----------------------------
// The user asked for two things and said explicitly that the second is *not*
// the first: "re-run a specific test" and "enter an existing recording (this
// is not necessarily a re-run)". An implementation that re-ran the test on
// both controls would look identical in a screenshot, identical in a DOM
// snapshot of class names, and identical to any check that only asserted "a
// debugger opened".
//
// So this program's whole design is one comparison: the RECORDING ID a row
// carries, read before a click and again after it.
//
//     ⟳  refresh      -> the id CHANGES, and no session opens
//     ⏵  open         -> the id is UNCHANGED, and a session opens
//     ⇧⏵ refresh+open -> the id CHANGES, and a session opens
//
// The second row of that table is the feature. If its id changed, the product
// re-ran a test the user asked it not to re-run, and every other green check
// here would be worthless.
//
// A SECOND, INDEPENDENT DISCRIMINATOR is taken from the console, because a
// single instrument that is subtly wrong is how this campaign's defects
// survive: `ui/web_noir_build.report` emits `test-recording-retained` when a
// recording is MADE and `test-recording-entered` when one is REPLAYED. Those
// two counts must move differently for the two controls, and they are produced
// by a different mechanism from the DOM attribute — one is a log line at the
// moment of retention, the other is a rendered attribute derived through the
// view model. Agreeing by accident is not available to them.
//
// LIKE `web_renderer_probe.mjs`, THIS ASSERTS NOTHING. It reports facts and
// lets `tests-pane-row-controls.sh` count assertions over them, so the control
// arm and the change arm read the same instrument.

import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';

const url = process.argv[2];
const shotDir = process.argv[3] || '';
const settleMs = Number(process.argv[4] || 9000);
if (!url) {
  console.error('usage: tests_pane_row_controls_probe.mjs <url> [shotDir] [settleMs]');
  process.exit(2);
}
if (shotDir) mkdirSync(shotDir, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

const pageErrors = [];
const buildLog = [];
const replayLog = [];
page.on('pageerror', (e) => pageErrors.push(String((e && e.message) || e).slice(0, 300)));
page.on('console', (m) => {
  const t = m.text();
  // Only these modules' own lines. The renderer is chatty and the counts below
  // must not drift with unrelated logging.
  if (t.includes('codetracer-noir-build:')) buildLog.push(t.slice(0, 400));
  // THE REPLAY HOST'S OWN ACCOUNT, kept apart from the build's. "The host took
  // the request" and "the engine came up" are different claims, and a
  // deployment that ships no replay engine satisfies the first and not the
  // second — which is a fact about the BUNDLE and must not read as a fact
  // about the control that made the request.
  if (t.includes('codetracer-replay:')) replayLog.push(t.slice(0, 400));
});

const out = {
  url,
  pageErrors,
  steps: [],
  shots: [],
};

const note = (name, data) => out.steps.push({ name, ...data });

const shot = async (name) => {
  if (!shotDir) return;
  const file = `${shotDir}/${name}.png`;
  await page.screenshot({ path: file });
  out.shots.push(file);
};

// Count of the two log kinds so far. Read as a DELTA around each gesture,
// never as a total: a total cannot say which click produced which line.
const logCounts = () => ({
  retained: buildLog.filter((l) => l.includes('test-recording-retained')).length,
  entered: buildLog.filter((l) => l.includes('test-recording-entered')).length,
});

// ---------------------------------------------------------------------------
// Reading the pane
// ---------------------------------------------------------------------------

// THE TESTS TAB IS A BACKGROUND TAB, and a background tab is `display: none`.
// Noir-Studio.md §1a accepts that cost explicitly ("running the tests from a
// cold Edit-mode workspace is two pointer actions"). A probe that skipped this
// would find no rows and report the feature missing on a product that has it.
const openTestsTab = async () => {
  return await page.evaluate(() => {
    const tabs = Array.from(document.querySelectorAll('.lm_tab'));
    const tab = tabs.find((t) => (t.textContent || '').trim() === 'TESTS');
    if (!tab) return { found: false, captions: tabs.map((t) => (t.textContent || '').trim()) };
    tab.click();
    return { found: true, captions: tabs.map((t) => (t.textContent || '').trim()) };
  });
};

const readRows = async () =>
  await page.evaluate(() =>
    Array.from(document.querySelectorAll('.test-results-row')).map((e) => {
      const q = (sel) => e.querySelector(sel);
      const btn = (sel) => {
        const b = q(sel);
        if (!b) return null;
        const r = b.getBoundingClientRect();
        // WHAT A POINTER AT THIS CONTROL'S CENTRE WOULD ACTUALLY HIT.
        //
        // A box and a class say the control was PAINTED. Only a hit test says
        // it can be REACHED, and the difference is this campaign's commonest
        // defect: a capability present, correct, and covered by something.
        const cx = r.left + r.width / 2;
        const cy = r.top + r.height / 2;
        const inView = cx >= 0 && cy >= 0 && cx <= innerWidth && cy <= innerHeight;
        const hit = inView ? document.elementFromPoint(cx, cy) : null;
        const describe = (n) => !n ? 'nothing' :
          (n.tagName.toLowerCase() + (n.id ? '#' + n.id : '') +
            (typeof n.className === 'string' && n.className
              ? '.' + n.className.trim().split(/\s+/).join('.') : ''));
        return {
          present: true,
          hit: describe(hit),
          // THE WHOLE STACK, not just the top. When a control is covered, the
          // name of what covers it is the finding; "something" is a shrug.
          hitStack: inView
            ? document.elementsFromPoint(cx, cy).slice(0, 4).map(describe) : [],
          inView,
          hitsSelf: !!hit && (hit === b || b.contains(hit)),
          disabled: (b.className || '').includes('disabled'),
          title: b.getAttribute('title') || '',
          ariaLabel: b.getAttribute('aria-label') || '',
          className: b.className || '',
          mark: (b.textContent || '').trim(),
          openMode: b.getAttribute('data-ct-open-mode') || '',
          // VISIBLE, not merely present. A control with a zero box is the
          // dead-affordance shape wearing a DOM node.
          box: { w: Math.round(r.width), h: Math.round(r.height) },
        };
      };
      return {
        testId: e.getAttribute('data-ct-test-id') || '',
        recordingId: e.getAttribute('data-ct-recording-id') || '',
        name: (q('.test-results-name') || {}).textContent || '',
        state: (typeof e.className === 'string' ? e.className : '')
          .replace('test-results-row', '').trim(),
        refresh: btn('.test-results-refresh-btn'),
        open: btn('.test-results-open-btn'),
      };
    }));

// THE BUILD PANEL SLIDES IN OVER EVERYTHING WHEN A RUN PRODUCES OUTPUT, and
// it brings `#auto-hide-backdrop` with it — a full-viewport click-to-dismiss
// layer. That is the auto-hide overlay's documented behaviour and not this
// pane's, but it lands squarely on this feature's natural gesture: press ⟳,
// then press ⏵, and the second click is absorbed by the backdrop.
//
// The probe DISMISSES it rather than pretending it is not there, and reports
// both facts — whether the control was covered, and whether it is reachable
// once the overlay is gone. Clicking through with `force` would have hidden
// the obstruction; skipping the dismissal would have blamed this pane for the
// overlay's layer.
const dismissAutoHideOverlay = async () => {
  const state = await page.evaluate(() => {
    const backdrop = document.querySelector('#auto-hide-backdrop');
    if (!backdrop) return { present: false };
    const visible = getComputedStyle(backdrop).display !== 'none';
    if (visible) backdrop.click();
    return { present: true, visible };
  });
  if (state.visible) await page.waitForTimeout(700);
  return state;
};

const clickRowButton = async (index, which, withShift) => {
  // SHIFT IS PRESSED AS A REAL KEY, held across the click and released after.
  // Passing a synthetic `shiftKey` on the click event would test a code path
  // the product does not have — the pane reads a document-level keydown, which
  // is the only mechanism that can also update the tooltip mid-hover.
  if (withShift) await page.keyboard.down('Shift');
  const sel = `.test-results-row:nth-of-type(${index + 1}) ` +
    (which === 'refresh' ? '.test-results-refresh-btn' : '.test-results-open-btn');
  // HOVER FIRST, and read the tooltip while the key is down. This is the
  // staleness check: the pointer is already on the button when Shift is
  // pressed, which is exactly when a mouseover-time title would be wrong.
  await page.hover(sel).catch(() => {});
  const armed = await page.evaluate((s) => {
    const b = document.querySelector(s);
    if (!b) return null;
    return {
      title: b.getAttribute('title') || '',
      className: b.className || '',
      openMode: b.getAttribute('data-ct-open-mode') || '',
      mark: (b.textContent || '').trim(),
    };
  }, sel);
  // A REAL POINTER CLICK, not `element.click()`. `force` skips Playwright's
  // own actionability assertions but the browser still delivers the event to
  // whatever is topmost at those coordinates — which is the property being
  // tested. A synthetic `element.click()` invokes the listener directly and
  // would pass over a control no user could reach.
  let clickError = '';
  await page.click(sel, { force: true, timeout: 5000 })
    .catch((e) => { clickError = String((e && e.message) || e).slice(0, 200); });
  if (withShift) await page.keyboard.up('Shift');
  return { ...armed, clickError };
};

// ---------------------------------------------------------------------------

try {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(settleMs);

  const tabs = await openTestsTab();
  await page.waitForTimeout(1200);
  note('tests-tab', tabs);

  const initial = await readRows();
  note('initial', { rows: initial });
  await shot('01-tests-pane-initial');

  // -- THE ARMED TOOLTIP, BEFORE ANY RECORDING EXISTS ----------------------
  // Read here as well as after a recording, because the two states have
  // different honest labels and only one of them may say "open".
  if (initial.length > 0) {
    await page.keyboard.down('Shift');
    await page.waitForTimeout(150);
    const shiftedNoRecording = await readRows();
    await page.keyboard.up('Shift');
    await page.waitForTimeout(150);
    note('shift-with-no-recording', { rows: shiftedNoRecording });
  }

  // -- 1. REFRESH ONE ROW: a recording is made, and nothing navigates ------
  let beforeRefresh = logCounts();
  const refreshArmed = initial.length > 0
    ? await clickRowButton(0, 'refresh', false) : null;
  note('refresh-click', { armed: refreshArmed });

  // The recording takes an instrumented compile plus a trace. Poll for the id
  // rather than sleeping a fixed time: a fixed sleep either flakes or hides a
  // regression in how long this takes.
  let refreshed = [];
  for (let i = 0; i < 90; i += 1) {
    await page.waitForTimeout(1000);
    refreshed = await readRows();
    if (refreshed.some((r) => r.recordingId)) break;
  }
  const afterRefresh = logCounts();
  note('after-refresh', {
    rows: refreshed,
    retainedDelta: afterRefresh.retained - beforeRefresh.retained,
    enteredDelta: afterRefresh.entered - beforeRefresh.entered,
    // DID IT NAVIGATE? A refresh must NOT. The debugger's own panes are what
    // a session looks like; the TESTS pane survives a mode switch (it is a tab
    // of FILES in both), so its presence proves nothing and this does.
    debuggerOpened: await page.evaluate(() =>
      // THE DEBUGGER'S OWN PANES, by the classes their views actually emit.
      // `.component-container.calltrace` was tried first and matches nothing:
      // the container carries only `component-container`, and the pane's
      // identity is inside it (`isonim_calltrace_view` renders
      // `.calltrace-component`). A selector that cannot match is a check that
      // reports "no debugger" over a debugger — trap 4 with a plausible name.
      !!document.querySelector('.calltrace-component, .calltrace-lines')),
  });
  await shot('02-after-refresh-one-row');

  const recordedRow = refreshed.findIndex((r) => r.recordingId);
  const idAfterRefresh = recordedRow >= 0 ? refreshed[recordedRow].recordingId : '';

  // WAS THE NEXT CONTROL REACHABLE, and if not, what was on top of it? Both
  // are reported: the obstruction is a finding about the overlay, and the
  // reachability after dismissal is the finding about this pane.
  const coveredAfterRefresh = recordedRow >= 0 ? refreshed[recordedRow].open : null;
  const dismissed = await dismissAutoHideOverlay();
  const afterDismiss = await readRows();
  note('reachability', {
    coveredImmediatelyAfterRefresh:
      !!coveredAfterRefresh && coveredAfterRefresh.hitsSelf === false,
    coveredBy: coveredAfterRefresh ? coveredAfterRefresh.hitStack : [],
    backdrop: dismissed,
    reachableAfterDismiss: recordedRow >= 0 && !!afterDismiss[recordedRow] &&
      !!afterDismiss[recordedRow].open && afterDismiss[recordedRow].open.hitsSelf === true,
  });

  // -- 2. ENTER THE EXISTING RECORDING: nothing is re-run ------------------
  if (recordedRow >= 0) {
    // ERRORS ARE SPLIT AT THE FIRST NAVIGATION, and the split is not a way of
    // getting to zero. Everything up to here is this pane: mounting, painting
    // the controls, recording, tracking the modifier. Everything after is the
    // replay-entry path — opening a session, switching to Debug mode, mounting
    // the debugger's panes — which this feature CALLS but does not own, and
    // which the editor's existing gutter Run-test control reaches the same
    // way. Reporting one number would let a defect in either half hide behind
    // the other; reporting two says which half to send someone to.
    out.pageErrorsBeforeNavigation = pageErrors.slice();
    const beforeOpen = logCounts();
    const openArmed = await clickRowButton(recordedRow, 'open', false);
    note('open-click', { armed: openArmed, idBefore: idAfterRefresh });
    await page.waitForTimeout(6000);

    // IF THE POINTER CLICK PRODUCED NOTHING, ASK WHETHER THE HANDLER EXISTS.
    //
    // Two very different defects look identical from outside: a control that
    // is unreachable by a pointer, and one that is reachable and wired to
    // nothing. This step separates them by invoking the listener directly —
    // and the result is reported rather than substituted, because a direct
    // invocation is NOT evidence that a user can do it.
    const midOpen = logCounts();
    if (midOpen.entered === beforeOpen.entered) {
      const sel = `.test-results-row:nth-of-type(${recordedRow + 1}) .test-results-open-btn`;
      const dispatched = await page.evaluate((s) => {
        const b = document.querySelector(s);
        if (!b) return 'no-such-element';
        b.click();
        return 'dispatched';
      }, sel);
      await page.waitForTimeout(4000);
      const afterDirect = logCounts();
      note('open-direct-dispatch', {
        dispatched,
        enteredDelta: afterDirect.entered - midOpen.entered,
        retainedDelta: afterDirect.retained - midOpen.retained,
      });
    }
    const afterOpen = logCounts();
    const rowsAfterOpen = await readRows();
    const stillThere = rowsAfterOpen.find((r) => r.testId === refreshed[recordedRow].testId);
    // WHICH RECORDING WAS ACTUALLY ENTERED, taken from the host's own line.
    //
    // The row's attribute was the first instrument and it is not enough on its
    // own HERE, because entering a recording switches the workspace to Debug
    // mode and the pane is re-mounted — so "the id is unchanged" degrades to
    // "the row is gone", which proves nothing either way. The log line
    // `test-recording-entered ... recording=<id>` is written by the host at
    // the moment it hands the trace over, survives the re-mount, and names the
    // recording it opened. Comparing THAT to the id the row carried before the
    // click is the discriminator in a form the mode switch cannot erase.
    const enteredIds = buildLog
      .filter((l) => l.includes('test-recording-entered'))
      .map((l) => (l.match(/recording=(\S+)/) || [])[1] || '');
    note('after-open', {
      rows: rowsAfterOpen,
      idBefore: idAfterRefresh,
      idAfter: stillThere ? stillThere.recordingId : '(row re-mounted by the mode switch)',
      enteredRecordingId: enteredIds[enteredIds.length - 1] || '',
      // THE DISCRIMINATOR, stated as one boolean so a reader of the JSON
      // cannot miss which fact this whole program is about: the recording that
      // was ENTERED is the one that already EXISTED.
      enteredTheExistingRecording:
        enteredIds[enteredIds.length - 1] === idAfterRefresh && !!idAfterRefresh,
      recordingIdUnchanged: !stillThere || stillThere.recordingId === idAfterRefresh,
      retainedDelta: afterOpen.retained - beforeOpen.retained,
      enteredDelta: afterOpen.entered - beforeOpen.entered,
      debuggerOpened: await page.evaluate(() =>
        // THE DEBUGGER'S OWN PANES, by the classes their views actually emit.
      // `.component-container.calltrace` was tried first and matches nothing:
      // the container carries only `component-container`, and the pane's
      // identity is inside it (`isonim_calltrace_view` renders
      // `.calltrace-component`). A selector that cannot match is a check that
      // reports "no debugger" over a debugger — trap 4 with a plausible name.
      !!document.querySelector('.calltrace-component, .calltrace-lines')),
    });
    await shot('03-entered-existing-recording');

    // -- 3. SHIFT + OPEN: a NEW recording, and it is landed in -------------
    //
    // A SECOND PASS ON A FRESH PAGE, and it has to be. Step 2 just entered a
    // recording, which is a mode switch — the workspace is the debugger now,
    // the TESTS pane has been re-mounted, and driving the shifted gesture from
    // that state would be measuring the pane's post-switch condition rather
    // than the modifier. So the page is reloaded and the row is recorded again
    // from scratch, which is also the sequence a user performs: they arrive,
    // they record, they hold Shift.
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(settleMs);
    await openTestsTab();
    await page.waitForTimeout(1200);

    const passTwoBefore = logCounts();
    await clickRowButton(0, 'refresh', false);
    let seeded = [];
    for (let i = 0; i < 90; i += 1) {
      await page.waitForTimeout(1000);
      seeded = await readRows();
      if (seeded.some((r) => r.recordingId)) break;
    }
    note('pass-two-seed', {
      retainedDelta: logCounts().retained - passTwoBefore.retained,
      seededId: (seeded.find((r) => r.recordingId) || {}).recordingId || '',
    });

    await dismissAutoHideOverlay();
    const rowsNow = await readRows();
    const idx = rowsNow.findIndex((r) => r.recordingId);
    if (idx >= 0) {
      const beforeShift = logCounts();
      const shiftArmed = await clickRowButton(idx, 'open', true);
      note('shift-open-click', {
        armed: shiftArmed,
        idBefore: rowsNow[idx].recordingId,
      });
      await dismissAutoHideOverlay();
      const targetId = rowsNow[idx].testId;
      const idBeforeShift = rowsNow[idx].recordingId;
      let shifted = [];
      for (let i = 0; i < 120; i += 1) {
        await page.waitForTimeout(1000);
        const retainedNow = buildLog
          .filter((l) => l.includes('test-recording-retained'))
          .map((l) => (l.match(/recording=(\S+)/) || [])[1] || '');
        shifted = await readRows();
        if (retainedNow[retainedNow.length - 1] &&
            retainedNow[retainedNow.length - 1] !== idBeforeShift) break;
      }
      await page.waitForTimeout(6000);
      const afterShift = logCounts();
      const r = shifted.find((x) => x.testId === targetId);
      // SAME TWO INSTRUMENTS AS THE OPEN ARM, and the same reason: the shifted
      // gesture also ends in a mode switch, so the row's attribute may be gone
      // by the time it is read. The retained line names the NEW recording and
      // the entered line names what was landed in; both survive.
      const retainedIds = buildLog
        .filter((l) => l.includes('test-recording-retained'))
        .map((l) => (l.match(/recording=(\S+)/) || [])[1] || '');
      const enteredIds2 = buildLog
        .filter((l) => l.includes('test-recording-entered'))
        .map((l) => (l.match(/recording=(\S+)/) || [])[1] || '');
      const newestRetained = retainedIds[retainedIds.length - 1] || '';
      note('after-shift-open', {
        idBefore: idBeforeShift,
        idAfter: r ? r.recordingId : '(row re-mounted by the mode switch)',
        newestRetained,
        lastEntered: enteredIds2[enteredIds2.length - 1] || '',
        recordingIdChanged: !!newestRetained && !!idBeforeShift &&
          newestRetained !== idBeforeShift,
        // LANDED IN THE NEW ONE, not merely made it. "Recorded again" and
        // "opened what it recorded" are two claims and the shifted gesture
        // promises both.
        landedInTheNewRecording:
          !!newestRetained && enteredIds2[enteredIds2.length - 1] === newestRetained,
        retainedDelta: afterShift.retained - beforeShift.retained,
        enteredDelta: afterShift.entered - beforeShift.entered,
        debuggerOpened: await page.evaluate(() =>
          !!document.querySelector('.calltrace-component, .calltrace-lines')),
      });
      await shot('04-after-shift-refresh-and-open');
    }
  }

  out.buildLog = buildLog.slice(-60);
  out.replayLog = replayLog.slice(-40);
} catch (e) {
  out.fatal = String((e && e.stack) || e).slice(0, 2000);
}

await browser.close();
console.log(JSON.stringify(out, null, 2));
