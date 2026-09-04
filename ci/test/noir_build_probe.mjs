// noir_build_probe.mjs — press Build in a real browser and report what the
// compiler actually did.
//
// WHY THIS EXISTS BESIDE `web_renderer_probe.mjs`
// ----------------------------------------------
// That probe loads a page and reports what is on it. This one has to DRIVE the
// page: the claim under test is not "a surface mounted" but "a gesture reached
// 19 MB of Noir compiler and a result came back", and the only instrument for
// that is a browser that performs the gesture.
//
// THE MEASUREMENT THAT DEFINED THE PROBLEM, and the one this program repeats.
// Instrumenting `Worker.postMessage` before page scripts ran and then
// exercising Run test, the BUILD pane's ▶ and ■, a test row, F5, Ctrl+B,
// Ctrl+Shift+B and Ctrl+R produced ONE `configure` message, ZERO `start`
// messages, and ZERO `.wasm` network requests. Every check over that
// deployment was green, because each one asserted a step. So the three fields
// this program exists to report are:
//
//   workerMessages   every string handed to `Worker.postMessage`, in order
//   wasmRequests     every response whose URL ends `.wasm`, with its size
//   buildPanePainted the BUILD pane's rows, hit-tested, as a USER reads them
//
// `addInitScript` runs before any page script, which is the only position from
// which `Worker.postMessage` can be wrapped without racing the bundle.
//
// PAINTED TEXT, NOT `innerText`. `web-renderer-mounts.sh` records why: its
// "there is a product on this page" check was being satisfied almost entirely
// by a 379-character developer diagnostic that sat at (0,0) under the topbar
// and that no user could see. `innerText` is defined over rendered text, and
// the text WAS rendered — it was covered. So every row reported below is
// hit-tested with `elementFromPoint` at its own centre.
//
// This program asserts nothing. It reports facts and lets
// `ci/test/noir-build-in-browser.sh` count assertions over them, so the arms
// and the control read one instrument.

import { chromium } from 'playwright';

const url = process.argv[2];
const gesture = process.argv[3] || 'shortcut';   // shortcut | button | run | none
const settleMs = Number(process.argv[4] || 12000);
// Where to write `<prefix>-before-full.png`, `-before-pane.png`, `-after-*`.
// Optional: the assertions below read numbers, and a screenshot is what a
// human reads when a number is disputed. Nothing depends on it being set.
const shotPrefix = process.argv[5] || '';
if (!url) {
  console.error(
    'usage: noir_build_probe.mjs <url> [gesture] [settleMs] [shotPrefix]');
  process.exit(2);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

const pageErrors = [];
const consoleLines = [];
const wasmRequests = [];

// EVERY CONSOLE LINE IS TIMESTAMPED, and the timestamps are the only way this
// program can report how long a compile took.
//
// The subject is a wasm module fetched over HTTP and run in a worker, so there
// is no wall-clock number in the DOM to read and no `performance` mark the
// product emits. What the product DOES emit is `web_noir_build.report`, which
// prints `<phase>-started` and `<phase>-exit` on the console — so the interval
// between those two lines is the compile, measured from the product's own
// account of its own dispatch rather than from a poll that could be late by a
// whole polling interval.
//
// Relative to navigation, because an absolute epoch would make two runs
// incomparable and the question is always "how long after the page opened".
const navigationStart = Date.now();
const stamp = () => Date.now() - navigationStart;
const consoleTimeline = [];

page.on('pageerror', (e) =>
  pageErrors.push(String((e && e.message) || e).slice(0, 300)));
page.on('console', (m) => {
  const text = m.text().slice(0, 500);
  consoleLines.push(`${m.type()}: ${text}`);
  if (text.includes('codetracer-')) consoleTimeline.push({ ms: stamp(), text });
});
page.on('response', async (r) => {
  const u = r.url();
  if (!u.endsWith('.wasm')) return;
  let bytes = -1;
  try {
    const length = r.headers()['content-length'];
    bytes = length ? Number(length) : -1;
  } catch (e) { /* a response body may be unavailable; the URL is the fact */ }
  wasmRequests.push({ url: u, status: r.status(), bytes });
});

// THE INSTRUMENT, installed before a single page script runs.
//
// `Worker.prototype.postMessage` is wrapped rather than `Worker` itself,
// because the transport constructs its worker inside a Nim closure and a
// replaced constructor would have to reproduce the real one exactly. Wrapping
// the method leaves construction alone and still sees every message.
//
// The messages are recorded as STRINGS, which is not a lossy convenience: the
// protocol is text in both directions by design (`wasm_worker.nim`'s header
// records the day a sibling campaign lost to an engine that sent objects one
// way and JSON the other), so anything arriving here that is NOT a string is
// itself a finding and is recorded as its `typeof`.
await page.addInitScript(() => {
  window.__ctWorkerMessages = [];
  const original = Worker.prototype.postMessage;
  Worker.prototype.postMessage = function (message, ...rest) {
    try {
      window.__ctWorkerMessages.push(
        typeof message === 'string'
          ? message.slice(0, 2000)
          : `NON-STRING(${typeof message})`);
    } catch (e) { /* never let the instrument break the subject */ }
    return original.call(this, message, ...rest);
  };
});

const report = {
  url, gesture,
  // WHICH BUILD THIS MEASURED. Read from the page's own
  // `#codetracer-deployment` block, so a verdict about "the deployed site"
  // names the revision it was taken against instead of whatever was live when
  // somebody read the report. A local bundle carries the same block.
  revision: '',
  commit: '',
  branch: '',
  loadError: '',
  gestureError: '',
  mounted: false,
  buildPaneOpened: false,
  workerMessages: [],
  wasmRequests: [],
  buildPanePainted: [],
  buildPaneRejected: [],
  buildPaneRowCount: -1,
  problemRowsPainted: [],
  runButtonPresent: false,
  stopButtonEnabled: false,
  headerText: '',
  constraints: {},
  // THE PANE AS A VISITOR WHO HAS DONE NOTHING SEES IT.
  //
  // The distinction this field exists for is the whole of the defect it was
  // added against: `constraints` is read after a gesture, and every assertion
  // over it was green on a deployment where a visitor who made no gesture saw
  // no listing at all. A pane that only works when driven is not a pane that
  // works, and only a snapshot taken BEFORE the driving can tell them apart.
  constraintsBefore: {},
  // The persistent-storage toast, and specifically whether it is sitting on
  // the pane above. See `noticeScript`.
  notice: {},
  noticeBefore: {},
  consoleTimeline: [],
  // Milliseconds from the product's own `-started` line to its `-exit` line,
  // per phase. Empty when a phase did not run.
  phaseMs: {},
  // Milliseconds from navigation to the pane holding its first opcode row.
  // -1 when it never did.
  msToFirstListing: -1,
  pageErrors: [],
  consoleLines: [],
};

// The CONSTRAINTS pane, after the same Build. Its DOM contract is written out
// at the top of `viewmodel/views/isonim_constraints_view.nim`.
//
// ## Why this lives in the BUILD gate
//
// The pane's own browser gate — `ci/test/constraints-listing-browser.sh` —
// paints it from a listing compiled into the probe as a constant. That proves
// the pane can render a listing. It cannot prove a listing ever REACHES it,
// because no compiler runs in it. This gate is the only one where a real
// `noir_wasm.wasm` is fetched over HTTP and compiles a real project, so it is
// the only place the question "does the deployed module produce a listing"
// can be asked at all.
//
// It was worth asking. `ci/deploy/noir-wasm.pin` sat on a revision predating
// `VfsResponse.acir_listing` while the pane rendered listings correctly in
// every headless suite over it, and the live site showed a visitor the
// `noteListingUnavailable` caption on every Build. Nothing was red. The pane
// was right, the module was old, and no gate joined the two.
//
// ## The string that says which path painted the pane
//
// `.constraints-name` reads `main` when the report came from the compile-time
// `noirTemplateNargoInfoJson` constant — `nargo info` names the function —
// and `func 0` when it came from `reportFromAcirListing`, because that is how
// `--print-acir` heads its constrained block. One string, and it distinguishes
// the two sources completely. Asserting on the row COUNT alone would not: both
// paths report 17.
const constraintsScript = () => {
  const pane = document.querySelector('.component-container.constraints');
  if (!pane) return { mounted: false };
  const text = (el) => el ? (el.innerText || el.textContent || '')
    .replace(/\s+/g, ' ').trim() : '';
  // LAID OUT AND HIT-TESTED, for the reason this file's header gives about
  // the build pane: a row with a zero-height box, or one under another
  // element, is not a row a user reads. An inactive GoldenLayout tab is
  // exactly that case, and it is the likeliest way this arm could report
  // "no rows" about a pane that is perfectly fine.
  const laidOut = (el) => {
    const b = el.getBoundingClientRect();
    if (b.width === 0 || b.height === 0) return false;
    const top = document.elementFromPoint(
      b.x + Math.min(20, b.width / 2), b.y + b.height / 2);
    return !!top && (top === el || el.contains(top) || top.contains(el));
  };
  const opcodes = Array.from(pane.querySelectorAll('.constraints-opcode'));
  const rows = Array.from(pane.querySelectorAll('.constraints-row'));
  const notice = pane.querySelector('.constraints-listing-notice');
  const paneBox = pane.getBoundingClientRect();
  return {
    mounted: true,
    // WHY IT IS NOT VISIBLE, when it is not. A bare `false` here sends the
    // reader to the product; usually the answer is that the pane is behind
    // another tab, which is the harness. These three say which.
    paneRect: [Math.round(paneBox.x), Math.round(paneBox.y),
               Math.round(paneBox.width), Math.round(paneBox.height)],
    tabTitles: Array.from(document.querySelectorAll('.lm_tab'))
      .map((t) => ((t.innerText || t.textContent || '').trim() +
                   (t.className.includes('lm_active') ? ' [active]' : ''))),
    paneCovering: (() => {
      if (paneBox.width === 0 || paneBox.height === 0) return 'zero-size';
      const top = document.elementFromPoint(
        paneBox.x + Math.min(20, paneBox.width / 2),
        paneBox.y + paneBox.height / 2);
      if (!top) return 'nothing-at-point';
      if (top === pane || pane.contains(top) || top.contains(pane)) return '';
      return top.tagName + '.' + String(top.className || '').slice(0, 60);
    })(),
    paneVisible: laidOut(pane),
    headline: text(pane.querySelector('.constraints-headline')),
    // `hidden` is the class the view sets when a listing DID arrive, so the
    // notice being visible is the old module's signature, not a fault.
    noticeVisible: !!notice && !notice.className.includes('hidden'),
    noticeText: notice ? text(notice) : '',
    functionNames: rows.map(
      (r) => text(r.querySelector('.constraints-name'))).filter((s) => s),
    rowTexts: rows.map(text),
    opcodeRows: opcodes.length,
    opcodeRowsLaidOut: opcodes.filter(laidOut).length,
    firstOpcode: opcodes.length ? text(opcodes[0]) : '',
    lastOpcode: opcodes.length ? text(opcodes[opcodes.length - 1]) : '',
    provenance: text(pane.querySelector('.constraints-provenance')),
    absence: text(pane.querySelector('.constraints-absence')),
    // `stale` and `compiling` live here — see `containerClass` in
    // `views/isonim_constraints_view.nim`.
    paneClass: pane.className,
    // ROWS BY INDEX, split into the three spans the view emits, so an
    // assertion can name ONE row and say what it must contain.
    //
    // This is the field that makes the gate's constraints arm falsifiable for
    // its own reason. `opcodeRows >= 1` is an existential: it is satisfied by
    // any row, including a row of the wrong listing, and the only way it can
    // go red is if the pane is empty. A named index with named text can go red
    // because the compiler changed what it prints, because the parser split it
    // differently, or because a different project was compiled — three
    // failures the count cannot see.
    //
    // Capped at 60: `/noir/demo` has 829 rows, and a JSON dump of all of them
    // would bury every other field in this report.
    opcodesByIndex: opcodes.slice(0, 60).map((o) => ({
      offset: text(o.querySelector('.low-level-code-instruction-offset')),
      name: text(o.querySelector('.low-level-code-instruction-name')),
      args: text(o.querySelector('.low-level-code-instruction-args')),
      laidOut: laidOut(o),
    })),
  };
};

// THE PERSISTENT-STORAGE TOAST, AND WHAT IT IS SITTING ON.
//
// `#active-notifications` is `position: fixed` above the status bar and holds
// every toast the product raises. The durability notice is the one that is
// raised on a first visit and stays until dismissed, so where it lands is not
// a flash — it is the default first screen.
//
// THE MEASUREMENT IS THE INTERSECTION, IN PIXELS, WITH THE CONSTRAINTS PANE.
// Not "is the toast visible" and not "is the pane visible": both were true on
// the deployment this was written against, while the toast covered the lower
// ~180px of the pane's column. An area is the only reading that distinguishes
// "both are on screen" from "one is on top of the other", and it is a number
// a gate can hold at zero.
//
// `elementFromPoint` is also asked, at a point inside the pane that the toast
// claims, because an intersection of rectangles is geometry and the question
// is about PAINT — a toast that intersects but is painted underneath would be
// a different and much smaller problem.
const noticeScript = () => {
  const host = document.getElementById('active-notifications');
  const text = (el) => el ? (el.innerText || el.textContent || '')
    .replace(/\s+/g, ' ').trim() : '';
  const toasts = host
    ? Array.from(host.querySelectorAll('.status-notification'))
    : [];
  // The durability notice by its own sentence, not by position in the stack:
  // any other toast raised in the same second would otherwise be measured
  // instead of it.
  const durability = toasts.filter(
    (t) => text(t).includes('saved in this browser'));
  const pane = document.querySelector('.component-container.constraints');
  const paneBox = pane ? pane.getBoundingClientRect() : null;
  const describe = (t) => {
    const b = t.getBoundingClientRect();
    const rect = [Math.round(b.x), Math.round(b.y),
                  Math.round(b.width), Math.round(b.height)];
    let overlapPx = 0;
    let coversPaneAt = '';
    if (paneBox && paneBox.width > 0 && paneBox.height > 0) {
      const w = Math.max(0, Math.min(b.right, paneBox.right) -
                            Math.max(b.x, paneBox.x));
      const h = Math.max(0, Math.min(b.bottom, paneBox.bottom) -
                            Math.max(b.y, paneBox.y));
      overlapPx = Math.round(w * h);
      if (overlapPx > 0) {
        // The centre of the intersection: a point that is inside BOTH boxes,
        // so whatever `elementFromPoint` answers is the one that won.
        const cx = (Math.max(b.x, paneBox.x) +
                    Math.min(b.right, paneBox.right)) / 2;
        const cy = (Math.max(b.y, paneBox.y) +
                    Math.min(b.bottom, paneBox.bottom)) / 2;
        const top = document.elementFromPoint(cx, cy);
        coversPaneAt = top
          ? top.tagName + '.' + String(top.className || '').slice(0, 60)
          : 'nothing-at-point';
      }
    }
    return {
      text: text(t).slice(0, 400),
      rect,
      // TRUNCATION, ASKED OF THE ELEMENT RATHER THAN OF A SCREENSHOT. The
      // report this was added for described the text as clipped on its left
      // edge (`...ort project`), which an element-only screenshot of a
      // NEIGHBOURING element reproduces by cropping and which the page itself
      // may or may not be doing. `scrollWidth > clientWidth` is the page's own
      // answer, and it is the one that settles it.
      overflowsHorizontally: t.scrollWidth > t.clientWidth + 1,
      messageOverflows: (() => {
        const m = t.querySelector('.notification-message');
        return !!m && m.scrollWidth > m.clientWidth + 1;
      })(),
      overlapPx,
      coversPaneAt,
    };
  };
  return {
    hostPresent: !!host,
    hostRect: host ? (() => {
      const b = host.getBoundingClientRect();
      return [Math.round(b.x), Math.round(b.y),
              Math.round(b.width), Math.round(b.height)];
    })() : [],
    toastCount: toasts.length,
    durabilityCount: durability.length,
    paneRect: paneBox
      ? [Math.round(paneBox.x), Math.round(paneBox.y),
         Math.round(paneBox.width), Math.round(paneBox.height)]
      : [],
    durability: durability.map(describe),
    // The whole stack's worst offender, so a toast this probe does not know
    // about cannot cover the pane unreported.
    maxOverlapPx: toasts.reduce(
      (acc, t) => Math.max(acc, describe(t).overlapPx), 0),
  };
};

// The rows of the BUILD pane, hit-tested. `#build` is the output container's
// id in `viewmodel/views/isonim_build_view.nim`; each row is a `div` whose
// class `lineClass` picks.
const paintedRowsScript = () => {
  const container = document.getElementById('build');
  if (!container) return { rows: [], count: -1, header: '', run: false, stopEnabled: false };
  const painted = [];
  // EVERY ROW IS REPORTED WITH ITS VERDICT, not merely accepted or dropped.
  //
  // A hit test that rejects everything and a pane with no rows produce the
  // same empty list, and they are different faults: the first is the
  // instrument and the second is the product. `rejected` is what tells them
  // apart in the gate's dump, and it exists because the first version of this
  // probe reported zero painted rows over a pane that a screenshot showed
  // plainly — the measurement failure this file's own header warns about,
  // arriving in the file that warns about it.
  const rejected = [];
  for (const row of container.children) {
    const r = row.getBoundingClientRect();
    const cs = getComputedStyle(row);
    const text = (row.innerText || row.textContent || '')
      .replace(/\u00a0/g, ' ').trim();
    const why = (reason) => rejected.push(
      reason + ' rect=' + Math.round(r.x) + ',' + Math.round(r.y) + ' ' +
      Math.round(r.width) + 'x' + Math.round(r.height) + ' :: ' +
      text.slice(0, 60));
    if (r.width === 0 || r.height === 0) { why('zero-size'); continue; }
    if (cs.visibility === 'hidden' || cs.display === 'none' ||
        cs.opacity === '0') {
      why('css-' + cs.visibility + '/' + cs.display + '/' + cs.opacity);
      continue;
    }
    // The LEFT of the row, not its centre. A row is as wide as the pane and
    // its text is at the start of it; probing the middle of a 1592px row asks
    // about empty space, which any later sibling with a margin can own.
    const px = r.x + Math.min(20, r.width / 2);
    const py = r.y + r.height / 2;
    const top = document.elementFromPoint(px, py);
    if (!top) { why('nothing-at-point'); continue; }
    if (!(top === row || row.contains(top) || top.contains(row))) {
      why('covered-by-' + top.tagName + '.' +
          String(top.className || '').slice(0, 40));
      continue;
    }
    if (text.length === 0) { why('empty-text'); continue; }
    painted.push(text);
  }
  const headerEl = document.querySelector('.build-header, .build-status');
  const runBtn = document.querySelector('.build-run-btn');
  const stopBtn = document.querySelector('.build-stop-btn');
  const problems = Array.from(
    document.querySelectorAll('.build-output-line.build-clickable')
  ).map((e) => (e.innerText || e.textContent || '').trim());
  return {
    rows: painted,
    rejected,
    count: container.children.length,
    header: headerEl ? (headerEl.innerText || '').trim() : '',
    run: !!runBtn,
    stopEnabled: !!stopBtn && !stopBtn.className.includes('disabled'),
    problems,
  };
};

try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  // Wait for the renderer to say it mounted. The line is the same one
  // `web-renderer-mounts.sh` reads, so "the surface came up" is one fact with
  // one spelling across both gates.
  for (let i = 0; i < 60; i += 1) {
    if (consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'))) break;
    await page.waitForTimeout(250);
  }
  report.mounted = consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'));

  // THE MOUNT LINE IS NOT THE END OF START-UP. `ui/layout.nim` registers the
  // standalone auto-hide panes on a `setTimeout` that runs after GoldenLayout
  // has created every container, and the strip is rebuilt from scratch each
  // time `autoHideState.onChanged` fires. A gesture issued into the middle of
  // that races it. A user cannot press a key before the page has drawn either,
  // so waiting here measures the product rather than a state no one is in.
  await page.waitForTimeout(2500);

  // BLUR THE EDITOR FIRST, and this is a real property of the product rather
  // than a harness convenience. Mousetrap's default `stopCallback` ignores a
  // chord raised inside an INPUT / TEXTAREA / contenteditable, and Monaco's
  // input surface is a textarea that takes focus when the editor pane mounts.
  // A user pressing Ctrl+B with the caret in the editor is in exactly that
  // state, so if the chord has to be reached from elsewhere, the gate should
  // find that out rather than paper over it: the click below targets the
  // topbar, which is where a user's pointer is when they have just used a
  // menu, and the assertion that the build ran is what says whether it was
  // enough.
  //
  // AND NOT ON THE `none` ARM. A click is a gesture. The arm whose claim is
  // "a visitor who does nothing sees the listing" cannot open a menu first,
  // and there is nothing for it to blur: it presses no chord, so Mousetrap's
  // `stopCallback` has nothing to refuse. Leaving the click in would also put
  // an open File menu over the FILES pane in every screenshot the arm takes,
  // which is how it was noticed.
  if (gesture !== 'none') {
    try {
      await page.click('#menu', { position: { x: 5, y: 5 }, timeout: 3000 });
    } catch (e) { /* no topbar is itself reported by the mount assertions */ }
  }

  // WHICH BUILD THIS IS. The block is in the document, so no request is made
  // and no ordering is raced; a page without one reports the empty identity,
  // which is a correct deployment rather than a failure.
  report.revision = await page.evaluate(() => {
    const el = document.getElementById('codetracer-deployment');
    if (!el) return '';
    try {
      const d = JSON.parse(el.textContent || '{}');
      return JSON.stringify(
        { revision: d.revision || '', commit: d.commit || '',
          branch: d.branch || '' });
    } catch (e) { return ''; }
  });
  if (report.revision) {
    try {
      const d = JSON.parse(report.revision);
      report.revision = d.revision;
      report.commit = d.commit;
      report.branch = d.branch;
    } catch (e) { /* reported verbatim if it will not parse */ }
  }

  // ---------------------------------------------------------------------
  // BEFORE ANY GESTURE. What does the pane show a visitor who just landed?
  // ---------------------------------------------------------------------
  //
  // This snapshot is the control for the whole of the "compiles on load"
  // claim, and it is taken HERE — after the mount and the layout settle, and
  // before a single key is pressed — because that is the state a visitor is
  // actually in. Note that on a build which compiles on load this is a RACE
  // by design: the compile is in flight, so `constraintsBefore` is expected to
  // show the pane's `compiling` state and `constraints` to show the listing.
  // The gate reads `constraints` for the listing and this one for the third
  // state; neither is asserted to be the other.
  report.constraintsBefore = await page.evaluate(constraintsScript);
  report.noticeBefore = await page.evaluate(noticeScript);
  if (shotPrefix) {
    await page.screenshot({ path: `${shotPrefix}-before-full.png` });
    try {
      const el = await page.$('.component-container.constraints');
      if (el) await el.screenshot({ path: `${shotPrefix}-before-pane.png` });
    } catch (e) { /* the pane's absence is reported by the snapshot above */ }
  }

  if (gesture === 'none') {
    // THE VISITOR WHO LANDS AND READS, and makes no gesture at all.
    //
    // The arm the whole "by default" complaint is about: every other gesture
    // here drives the page, and a pane that only works when driven passes all
    // of them. Nothing is pressed and nothing is clicked; the wait below is
    // the reader's patience, and what the pane holds at the end of it is the
    // product's answer.
    //
    // It waits for the LISTING rather than for a fixed delay, so a fast
    // machine is not held for the timeout and a slow one is not cut off before
    // the compiler has been fetched. The fixed fallback is the timeout itself,
    // which is what a build that never compiles spends.
    const deadline = Date.now() + settleMs;
    while (Date.now() < deadline) {
      const rows = await page.evaluate(() => document.querySelectorAll(
        '.component-container.constraints .constraints-opcode').length);
      if (rows > 0) { report.msToFirstListing = stamp(); break; }
      await page.waitForTimeout(250);
    }
  } else if (gesture === 'run') {
    // RUN is `ctrl+enter`, deliberately not `ctrl+r` or `F5` — both are the
    // browser's own reload on every platform, and a studio that ate either
    // would be taking a key away from the user rather than giving them one.
    await page.keyboard.press('Control+Enter');
  } else {
    await page.keyboard.press('Control+b');
  }

  // The pane is created on demand by `openLayoutTab(Content.Build)`, then the
  // IsoNim view mounts into it. Both are asynchronous.
  //
  // ONE POLL FOR THE `none` ARM, not forty. The automatic compile mounts the
  // BUILD pane without revealing it (`web_noir_build.activeRevealsBuildPane`),
  // so `#build` may well be in the DOM — that is worth recording — but there
  // is no gesture in flight for the loop to be waiting on, and forty quarter-
  // seconds of waiting for one would be ten seconds spent measuring nothing.
  const buildPaneTries = gesture === 'none' ? 1 : 40;
  for (let i = 0; i < buildPaneTries; i += 1) {
    const seen = await page.evaluate(() => !!document.getElementById('build'));
    if (seen) { report.buildPaneOpened = true; break; }
    await page.waitForTimeout(250);
  }

  if (gesture === 'button') {
    // THE SECOND GESTURE, and the one the acceptance names. The first opened
    // the pane; this one is a user clicking ▶ in it.
    //
    // THE FIRST BUILD IS WAITED OUT FIRST, and that is not politeness:
    // `startNoirBuild` refuses while a run is in flight
    // (`reason=already-running`), which is the correct product behaviour —
    // two concurrent compiles over one worker and one pane would interleave
    // their output. A click issued during the first compile therefore
    // produces ONE start message, and a gate that asserted two would be
    // asserting that the guard is absent.
    for (let i = 0; i < 60; i += 1) {
      const ready = await page.evaluate(() => {
        const btn = document.querySelector('.build-run-btn');
        const stop = document.querySelector('.build-stop-btn');
        const rows = (document.getElementById('build') || { children: [] })
          .children.length;
        const idle = !stop || stop.className.includes('disabled');
        return !!btn && idle && rows > 0;
      });
      if (ready) break;
      await page.waitForTimeout(250);
    }
    await page.click('.build-run-btn', { timeout: 5000 });
  }

  // Settle. A first compile has to FETCH ~16 MB of wasm off the local server,
  // compile it, and then compile the project — measured at ~2.5 s for the
  // fetch-and-instantiate and ~0.4 s for the project on this machine, so the
  // budget is generous and the loop exits as soon as the pane has settled.
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
  await page.waitForTimeout(750);

  const painted = await page.evaluate(paintedRowsScript);
  report.buildPanePainted = painted.rows;
  report.buildPaneRejected = painted.rejected || [];
  report.buildPaneRowCount = painted.count;
  report.headerText = painted.header;
  report.runButtonPresent = painted.run;
  report.stopButtonEnabled = painted.stopEnabled;
  report.problemRowsPainted = painted.problems || [];

  // THE CONSTRAINTS PANE, AFTER DISMISSING THE BUILD OVERLAY. The pane's tab
  // is already `lm_active` — `default_layout.json` puts it in the right-hand
  // column and nothing deactivates it — so this is NOT a tab switch. The
  // BUILD pane that Ctrl+B just opened is an auto-hide overlay drawn ON TOP
  // of that column, and it is what the hit test finds: measured,
  // `elementFromPoint` over the pane's centre returns
  // `DIV.build-output-container` while all 34 opcode rows sit in the DOM
  // underneath it.
  //
  // Escape is the gesture, and it is the user's: a reader who has just
  // watched a build finish dismisses the output and looks at the pane behind
  // it. Clicking the CONSTRAINTS tab does NOT work and the reason is worth
  // recording — the tab is itself under the overlay, so the click fails
  // Playwright's actionability check rather than switching anything.
  //
  // ORDER MATTERS: the BUILD pane is read above, before this dismisses it.
  //
  // NOT ON THE `none` ARM, and this is the one line that would invalidate it.
  // Escape is a keypress. An arm whose entire claim is "a visitor who makes no
  // gesture sees the listing" cannot press a key before reading the pane —
  // that is precisely the substitution the arm exists to catch, and it would
  // have gone unnoticed because the pane looks identical either way. On that
  // arm the automatic compile never reveals the overlay in the first place, so
  // there is nothing to dismiss.
  if (gesture !== 'none') {
    try {
      await page.keyboard.press('Escape');
      await page.waitForTimeout(750);
    } catch (e) { /* reported by constraints.paneVisible below */ }
  }
  report.constraints = await page.evaluate(constraintsScript);
  report.notice = await page.evaluate(noticeScript);

  if (shotPrefix) {
    await page.screenshot({ path: `${shotPrefix}-after-full.png` });
    try {
      const el = await page.$('.component-container.constraints');
      if (el) await el.screenshot({ path: `${shotPrefix}-after-pane.png` });
    } catch (e) { /* the pane's absence is reported by the snapshot above */ }
  }

  report.workerMessages = await page.evaluate(
    () => (window.__ctWorkerMessages || []).slice());
} catch (e) {
  report.loadError = String((e && e.message) || e).slice(0, 400);
}

// PHASE DURATIONS, paired off the product's own console lines.
//
// `web_noir_build.report` prints `<phase>-started` and `<phase>-exit`, so a
// compile's duration is the gap between the two — the product's account of
// its own dispatch, not this program's guess at when a poll noticed something.
// Unpaired lines are dropped rather than defaulted: a `-started` with no
// `-exit` means the phase did not finish, and reporting a duration for it
// would be inventing the number the reader most needs to be missing.
for (const entry of consoleTimeline) {
  const m = entry.text.match(/codetracer-noir-build: (\w+)-(started|exit)/);
  if (!m) continue;
  const [, phase, edge] = m;
  report.phaseMs[phase] = report.phaseMs[phase] || {};
  report.phaseMs[phase][edge] = entry.ms;
}
for (const phase of Object.keys(report.phaseMs)) {
  const p = report.phaseMs[phase];
  if (typeof p.started === 'number' && typeof p.exit === 'number') {
    p.ms = p.exit - p.started;
  }
}
report.consoleTimeline = consoleTimeline;

report.wasmRequests = wasmRequests;
report.pageErrors = pageErrors;
report.consoleLines = consoleLines.filter((l) =>
  l.includes('codetracer-') || l.includes('Error') || l.includes('error:'));

await browser.close();
console.log(JSON.stringify(report, null, 2));
