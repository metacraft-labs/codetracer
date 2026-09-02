// web_renderer_probe.mjs — load a built Noir Studio bundle in a real browser
// and report what a user would see.
//
// WHY A BROWSER AND NOT A GREP
// ----------------------------
// Every check this repository had over the web bundle read BYTES: the renderer
// compiled, the document referenced it, the file was served at the size it was
// uploaded at, the boot arm printed `ok`. All four were true of a deployment
// that painted a blank page for a week, because none of them is *a page that
// paints*. Verification-Harness-Traps.md calls this trap 2 — "a chain of
// `success: true` is not a result; assert the artefact" — and the artefact here
// is a DOM.
//
// This program does not assert anything. It reports facts and lets
// `web-renderer-mounts.sh` count assertions over them, so that the mutation
// arms and the control arm read the same instrument.
//
// The single most important field is `pageErrors`. The defect that shipped was
// an uncaught `ReferenceError` thrown after the boot line, and traps doc 3 says
// why nothing saw it: "a module that fails to load leaves no in-page error".
// A harness that does not subscribe to `pageerror` cannot tell a renderer that
// mounted from one that died on its first statement.

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 9000);
if (!url) {
  console.error('usage: web_renderer_probe.mjs <url> [settleMs]');
  process.exit(2);
}

// A SECOND ORIGIN, WITHOUT A SECOND SERVER OR A REAL DOMAIN.
//
// `noirstudio.dev` is meant to be the Noir entry point the way
// `ide.codetracer.com/noir` is: one Pages project, one tree, two custom
// domains, and `/` meaning different things on each because the page reads its
// own origin. A gate for that has to load the SAME bundle on a DIFFERENT
// origin — same-origin is the entire variable.
//
// `--host-resolver-rules` is how Chromium is told a hostname resolves to the
// loopback server, so the page's `window.location.origin` is a real foreign
// origin rather than `127.0.0.1`. Nothing is registered, nothing is fetched
// off the machine, and the harness's no-egress property is unchanged.
//
// Format: `MAP <host> 127.0.0.1:<port>` — the caller composes it, because only
// it knows the port the OS handed the server.
const hostMap = process.env.CT_PROBE_HOST_MAP || '';
const browser = await chromium.launch(
  hostMap ? { args: [`--host-resolver-rules=${hostMap}`] } : {});
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

const pageErrors = [];
const consoleLines = [];
const failedRequests = [];

page.on('pageerror', (e) =>
  pageErrors.push(String((e && e.message) || e).slice(0, 300)));
page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text().slice(0, 400)}`));
page.on('response', (r) => {
  if (r.status() >= 400) failedRequests.push(`${r.status()} ${r.url()}`);
});

let loadError = '';
try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(settleMs);
} catch (e) {
  loadError = String((e && e.message) || e).slice(0, 300);
}

let dom = {};
try {
  dom = await page.evaluate(() => {
    const root = document.getElementById('dom-root');
    const text = (document.body.innerText || '').trim();
    return {
      // The subject of every assertion below it. Reported separately from its
      // contents so "the probe looked at nothing" and "the probe looked at an
      // empty page" are different sentences — traps doc 4, the empty haystack.
      domRootPresent: !!root,
      domRootHtmlLength: root ? root.innerHTML.trim().length : -1,
      domRootElementCount: root ? root.querySelectorAll('*').length : -1,
      // The product's OWN class constants, from
      // viewmodel/views/isonim_welcome_screen_view.nim. A class name is what
      // the view code emits, so a check on it reads the renderer's output
      // rather than the document's skeleton — the skeleton is in index.html
      // and would satisfy an id-based check while empty.
      welcomeScreenRoots: document.querySelectorAll('.welcome-screen-root').length,
      startOptions: document.querySelectorAll('.start-option').length,
      recentPanels:
        document.querySelectorAll('.recent-folders, .recent-traces').length,
      // The OTHER surface, for the route arm. `/noir` must mount the bundled
      // template rather than the welcome screen (Noir-Studio.md §1b.0 rule 5,
      // first row), so the gate needs to see both and tell them apart — a
      // check that only counted welcome screens could say "the wrong thing
      // mounted" but never "the right thing did".
      //
      // These are `viewmodel/views/isonim_filesystem_view.nim`'s own
      // constants. `.filesystem-container` is the panel wrapper; the tree
      // itself renders as jstree markup in the real-DOM path (NOT the
      // `.filesystem-entry` classes, which are the MockRenderer's), so the row
      // count reads `a.jstree-anchor` — one per file and folder.
      filesystemPanels: document.querySelectorAll('.filesystem-container').length,
      filesystemEntries: document.querySelectorAll('a.jstree-anchor').length,
      // The template's own file names, as RENDERED text. The count above would
      // be satisfied by a tree of the right size holding anything at all; this
      // is what makes the assertion about *the Noir template* and not about
      // "some filesystem panel mounted".
      entryLabels: Array.from(document.querySelectorAll('a.jstree-anchor'))
        .map((a) => (a.innerText || '').trim())
        .filter((t) => t.length > 0),
      // ...AND WHICH OF THEM A USER CAN ACTUALLY SEE, by hit test.
      //
      // This field exists because every other field above was right about a
      // page that rendered NOTHING. The first version of the template surface
      // mounted into `#isonim-app`, and measured: panel present, 7 entries,
      // labels correct, colour `rgb(243,243,243)` on `rgb(27,27,27)`, real
      // geometry, `innerText` unchanged at 422 characters — and a screenshot
      // that was uniformly dark. `#session-container-0` comes later in the
      // entry document and painted straight over it.
      //
      // `innerText` cannot see that: it is defined over rendered text, and the
      // text WAS rendered — it was covered. So the instrument for occlusion
      // has to be occlusion. `elementFromPoint` at each label's centre returns
      // the topmost element there; if that is not the label or something
      // inside it, a user is looking at whatever is.
      //
      // Deliberately reported beside `entryLabels` rather than replacing it:
      // the two disagreeing is the diagnosis (mounted but covered), and one
      // number could not say that.
      entryLabelsVisible: Array.from(
        document.querySelectorAll('a.jstree-anchor')
      ).filter((a) => {
        const r = a.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) return false;
        const top = document.elementFromPoint(
          r.x + r.width / 2, r.y + r.height / 2);
        return !!top && (top === a || a.contains(top));
      }).map((a) => (a.innerText || '').trim()),
      // THE EDIT-MODE SURFACE. §1a: the first screen is "CodeTracer in Edit
      // mode on a working multi-file project", so the gate needs to see the
      // parts of it that the filesystem fields above cannot: the layout, the
      // editor pane, and the topbar.
      //
      // These are deliberately the DESKTOP's own selectors, not web-specific
      // ones. `.lm_stack` and `.lm_title` are GoldenLayout's; `.monaco-editor`
      // and `.view-line` are Monaco's; `#menu` is the topbar's id in
      // `src/frontend/index.html`. A web-only class here would let the two
      // platforms drift apart without this gate noticing, which is the whole
      // property §3 asks for.
      glStacks: document.querySelectorAll('.lm_stack').length,
      glTabTitles: Array.from(document.querySelectorAll('.lm_tab .lm_title'))
        .map((e) => (e.textContent || '').trim()).filter((t) => t.length > 0),
      monacoEditors: document.querySelectorAll('.monaco-editor').length,
      // The SOURCE, as painted lines. Monaco renders one `.view-line` per
      // visible row, so this is what a reader of the editor pane actually
      // reads — and it is separate from `paintedText` because a pane that
      // mounted with no content is a different failure from a pane that did
      // not mount, and the gate has to be able to say which.
      editorLinesVisible: Array.from(document.querySelectorAll('.view-line'))
        .filter((e) => {
          const r = e.getBoundingClientRect();
          if (r.width === 0 || r.height === 0) return false;
          const top = document.elementFromPoint(
            r.x + r.width / 2, r.y + r.height / 2);
          return !!top && (top === e || e.contains(top) || top.contains(e));
        // NON-BREAKING SPACES NORMALISED, and this is a measurement fix rather
        // than a convenience. Monaco emits U+00A0 for the spaces inside a
        // source line, so `textContent` gives back `fn\u00a0main` — which
        // matches nothing a check writes as `fn main`. The first version of
        // this field did not normalise, and the assertion went red over an
        // editor that was plainly showing the right code in the screenshot:
        // a measurement defect that would have been read as a product one,
        // which is the trap this file's own header warns about.
        //
        // A user reads a space, so the instrument reports a space.
        }).map((e) => (e.textContent || '').replace(/\u00a0/g, ' ').trim())
          .filter((t) => t.length > 0),
      // The topbar, measured as PAINT rather than presence. `#menu` is in the
      // entry document's skeleton whether or not the renderer ever drew into
      // it, so `!!document.getElementById('menu')` would be green over the
      // blank page this gate exists for. This counts its painted descendants.
      topbarPainted: (() => {
        const menu = document.getElementById('menu');
        if (!menu) return 0;
        let painted = 0;
        for (const e of menu.querySelectorAll('*')) {
          const r = e.getBoundingClientRect();
          if (r.width === 0 || r.height === 0) continue;
          const cs = getComputedStyle(e);
          if (cs.visibility === 'hidden' || cs.display === 'none' ||
              cs.opacity === '0') continue;
          const top = document.elementFromPoint(
            r.x + r.width / 2, r.y + r.height / 2);
          if (top && (top === e || e.contains(top) || top.contains(e))) painted += 1;
        }
        return painted;
      })(),
      // NOTHING MAY COVER THE STATUS BAR — a standing guard, not a check on
      // any one surface.
      //
      // It exists because a surface reached for the bottom of the screen and
      // got it: the storage-durability notice was painted into a bespoke
      // `<div id="codetracer-durability">` at `position:fixed; bottom:0;
      // z-index:2147483646`, which is where `#status` lives, so the product
      // covered its own footer on every first visit. That one is fixed — the
      // sentence goes through `ui/status.nim`'s notification stack now, which
      // sits at `bottom:38px` — and this field is here so the NEXT one is
      // caught by a gate rather than by a person noticing.
      //
      // `footer-visibility-css-guard.spec.ts` names this family as unguarded
      // in its own "WHERE IT STOPS" section: asking for a box catches
      // regressions that change LAYOUT and none that change only PAINTING,
      // and an occluded footer keeps a full-size box. Playwright calls it
      // visible. `readyOnEntryTest` passes. This asks the browser what is
      // actually at those pixels.
      //
      // THE WALK IS UPWARD, and that is the whole design. `bar.contains(hit)`
      // would be satisfied vacuously by `document.body`, which contains every
      // overlay too; requiring `#status` on the ancestor chain of whatever
      // `elementFromPoint` returns asks the only question worth asking —
      // "does the pixel at this point belong to the status bar".
      //
      // THREE POINTS, not one. The banner spanned the full width, but an
      // overlay covering only the location readout on the right would be as
      // much of a defect and a single centre probe would walk past it.
      statusBar: (() => {
        const bar = document.getElementById('status-base');
        if (!bar) return { found: false, unobscured: false, points: 0, coveredBy: [] };
        const r = bar.getBoundingClientRect();
        const rect = { x: r.left, y: r.top, w: r.width, h: r.height };
        if (r.width < 1 || r.height < 1) {
          return { found: true, unobscured: false, points: 0, coveredBy: ['zero-sized'], rect };
        }
        const owned = (node) => {
          let n = node;
          while (n) { if (n.id === 'status') return true; n = n.parentElement; }
          return false;
        };
        const describe = (n) => !n ? 'nothing' :
          (n.tagName.toLowerCase() +
           (n.id ? '#' + n.id : '') +
           (typeof n.className === 'string' && n.className
             ? '.' + n.className.trim().split(/\s+/).join('.') : ''));
        const cy = r.top + r.height / 2;
        const coveredBy = [];
        let points = 0;
        for (const f of [0.15, 0.5, 0.85]) {
          const cx = r.left + r.width * f;
          if (cx < 0 || cy < 0 || cx > innerWidth || cy > innerHeight) continue;
          points += 1;
          const hit = document.elementFromPoint(cx, cy);
          if (!owned(hit)) coveredBy.push(describe(hit));
        }
        return { found: true, unobscured: points > 0 && coveredBy.length === 0, points, coveredBy, rect };
      })(),
      // NS9'S TWO PANES. §1a's first screen is "Filesystem, Editor, Test
      // Results, Constraints", and until this campaign the last two existed on
      // no platform. They are ordinary CodeTracer panes now — `Content`
      // members with IsoNim views — so these read their own class names, the
      // same way the filesystem fields above read `isonim_filesystem_view`'s.
      testRows: Array.from(document.querySelectorAll('.test-results-row'))
        .map((e) => ({
          name: (e.querySelector('.test-results-name') || {}).textContent || '',
          where: (e.querySelector('.test-results-where') || {}).textContent || '',
          state: (typeof e.className === 'string' ? e.className : '')
            .replace('test-results-row', '').trim(),
        })),
      testHeadline:
        ((document.querySelector('.test-results-headline') || {}).textContent || '').trim(),
      // The stated reason a run cannot start here. EMPTY on an ordinary web
      // deployment, because there is now a runner: `noir_wasm.wasm` exports
      // `nv_test_vfs` and the worker routes `test` to it. It stays non-empty
      // for a bundle that placed no compiler module, which is a statement
      // about that deployment rather than about the product.
      testAbsenceLength:
        ((document.querySelector('.test-results-absence') || {}).textContent || '').trim().length,
      // THE AFFORDANCE THAT REPLACED THE PARAGRAPH. Its presence AND its
      // enabled state are both read, because a ▶ that is painted but
      // permanently disabled is the dead affordance the absence line existed
      // to avoid — and the two are indistinguishable in a screenshot.
      // THE EDITOR'S RUN-TEST CONTROL, IN THE GUTTER. Read as the LINES it
      // sits on, not as a count: the bundled `src/main.nr` declares two tests,
      // at lines 13 (`#[test]`) and 18 (`#[test(should_fail)]`), and the second
      // is the one the text scan this replaced could not see — it matched
      // `lineStr.strip() == "#[test]"` exactly. A count of 1 and a count of 2
      // are the before and after of that defect, and only the LINES say which
      // of the two is missing.
      gutterRunSlots: Array.from(document.querySelectorAll('.gutter-runtest'))
        .map((e) => e.getAttribute('data-runtest-line'))
        .filter((v) => v !== null)
        .sort((a, b) => Number(a) - Number(b)),
      // A control painted over the breakpoint's hit area is worse than none:
      // the click would set a breakpoint. Measured as the two boxes, so the
      // assertion is about GEOMETRY rather than about class names that happen
      // to differ.
      gutterRunSlotBoxes: Array.from(
        document.querySelectorAll('.gutter-runtest')).map((e) => {
          const r = e.getBoundingClientRect();
          const row = e.closest('.gutter');
          const marker = row
            ? row.querySelector('[class*="gutter-breakpoint"], [class*="gutter-no-breakpoint"]')
            : null;
          const m = marker ? marker.getBoundingClientRect() : null;
          return {
            line: e.getAttribute('data-runtest-line'),
            left: Math.round(r.left), right: Math.round(r.right),
            width: Math.round(r.width),
            markerLeft: m ? Math.round(m.left) : null,
            overlapsMarker: m ? !(r.right <= m.left || r.left >= m.right) : null,
          };
        }),
      // THE GUTTER'S BAND MAP, MEASURED.
      //
      // The strip carries FOUR concerns and they must not collide:
      // breakpoints/tracepoints, VCS change indicators, the line number, and
      // the run-test control. `viewmodel/viewmodels/editor_gutter_lanes.nim`
      // declares which band owns which, left to right; this reads back where
      // each one actually LANDED, so the declaration and the paint can be
      // compared rather than each being believed on its own.
      //
      // Reported as NUMBERS — every band's left and right edge in device
      // pixels — because a band map asserted as a boolean is the shape of
      // check that let `.diff-line` sit in this strip at 73x0 px for a year
      // while every gutter test stayed green.
      gutterBands: (() => {
        // A row with no run control, so the bands measured are the ones
        // RESERVED on every line. The run control is measured separately, on
        // its own row, by `gutterRunSlotBoxes`.
        const guts = [...document.querySelectorAll('.margin-view-overlays .gutter')];
        const gut = guts.find((g) => !g.querySelector('.gutter-runtest')) || guts[0];
        if (!gut) return null;
        const sel = {
          pointer: '[class*="gutter-highlight"], [class*="gutter-no-highlight"]',
          lineNumber: '.gutter-line',
          vcs: '.diff-line',
          breakpoint: '[class*="gutter-no-breakpoint"], [class*="gutter-breakpoint-"]',
          tracepoint: '[class*="gutter-no-trace"], [class*="gutter-trace"], [class*="gutter-disabled-trace"]',
        };
        const bands = {};
        for (const [name, s] of Object.entries(sel)) {
          const el = gut.querySelector(s);
          if (!el) { bands[name] = null; continue; }
          const r = el.getBoundingClientRect();
          const cx = Math.round(r.x + r.width / 2);
          const cy = Math.round(r.y + r.height / 2);
          const hit = r.width && r.height ? document.elementFromPoint(cx, cy) : null;
          bands[name] = {
            left: Math.round(r.left), right: Math.round(r.right),
            width: Math.round(r.width), height: Math.round(r.height),
            ownsHitArea: hit ? (hit === el || el.contains(hit)) : false,
            hitElement: hit
              ? `${hit.tagName}.${typeof hit.className === 'string' ? hit.className.slice(0, 40) : ''}`
              : null,
          };
        }
        // Pairwise horizontal overlap, computed rather than assumed. Two bands
        // that merely touch are one band to a rounding error, so a zero-width
        // gap is reported as an overlap of 0 and read as such by the gate.
        const names = Object.keys(bands).filter((n) => bands[n] && bands[n].width > 0);
        const overlaps = [];
        for (let i = 0; i < names.length; i++) {
          for (let j = i + 1; j < names.length; j++) {
            const a = bands[names[i]], b = bands[names[j]];
            const ov = Math.min(a.right, b.right) - Math.max(a.left, b.left);
            if (ov > 0) overlaps.push({ a: names[i], b: names[j], px: ov });
          }
        }
        // Left-to-right order of the bands that have a box, by left edge. The
        // declaration in `editor_gutter_lanes.nim` names this same order.
        const order = names.slice().sort((a, b) => bands[a].left - bands[b].left);
        const ln = gut.querySelector('.gutter-line');
        const chev = (() => {
          const row = gut.closest('.margin-view-overlays > div');
          const c = row && row.querySelector('[class*="codicon-folding"]');
          if (!c) return null;
          const r = c.getBoundingClientRect();
          return { left: Math.round(r.left), right: Math.round(r.right) };
        })();
        return {
          line: gut.getAttribute('data-line'),
          gutter: (r => ({ left: Math.round(r.left), right: Math.round(r.right), width: Math.round(r.width) }))(gut.getBoundingClientRect()),
          chevron: chev,
          bands, overlaps, order,
          lineNumberClipped: ln ? ln.scrollWidth > ln.clientWidth + 1 : null,
        };
      })(),
      testRunButton: (() => {
        const btn = document.querySelector('.test-results-run-btn');
        if (!btn) return null;
        const cls = typeof btn.className === 'string' ? btn.className : '';
        return {
          text: (btn.textContent || '').trim(),
          disabled: cls.includes('disabled'),
          title: btn.getAttribute('title') || '',
        };
      })(),
      constraintRows: Array.from(document.querySelectorAll('.constraints-row'))
        .map((e) => ({
          name: (e.querySelector('.constraints-name') || {}).textContent || '',
          kind: (e.querySelector('.constraints-kind') || {}).textContent || '',
          count: (e.querySelector('.constraints-count') || {}).textContent || '',
        })),
      constraintHeadline:
        ((document.querySelector('.constraints-headline') || {}).textContent || '').trim(),
      // Where the numbers came from. A count with no provenance is a count a
      // user cannot judge, so its ABSENCE is a defect the gate can see.
      constraintProvenance:
        ((document.querySelector('.constraints-provenance') || {}).textContent || '').trim(),
      // THE PROPORTIONS §1a DRAWS: 20 / 55 / 25. Measured as painted width
      // over the viewport, because the layout's own declaration is gone by
      // the time anything can read it — GoldenLayout renormalises a row to
      // fill 100% on load (see `layout_config_repair.unclaimedTopLevelPercent`).
      paneWidths: (() => {
        const w = window.innerWidth || 1;
        const pct = (sel) => {
          const e = document.querySelector(sel);
          if (!e) return -1;
          const r = e.getBoundingClientRect();
          return Math.round((r.width / w) * 1000) / 10;
        };
        return {
          filesystem: pct('.filesystem-container'),
          editor: pct('.monaco-editor'),
          testResults: pct('.test-results'),
        };
      })(),
      // What a person reads off the screen. `innerText` is defined over the
      // RENDERED text — it is the field that answers "is there a product on
      // this page", and the only one of the two that a screenshot agrees with.
      visibleText: text.slice(0, 1200),
      visibleTextLength: text.length,
      // ...AND WHAT `innerText` STILL OVERCOUNTS, which is why the field below
      // exists.
      //
      // `innerText` is defined over rendered text but NOT over VISIBLE text:
      // it counts glyphs that are laid out and then painted over. Measured on
      // the deployed `/noir`, 2026-09-01:
      //
      //     innerText           425 characters
      //     readable by a user   46 characters   (six file names)
      //     the other 379        the boot diagnostic, sitting under #menu
      //
      // So `visibleTextLength > 200` — this gate's own assertion — was
      // satisfied almost entirely by a developer log line the user cannot
      // see. A page showing nothing but a hidden diagnostic would pass it.
      //
      // `paintedTextLength` measures each TEXT NODE with a Range (so the box
      // is the glyphs' own box, not some ancestor's) and hit-tests its centre.
      // A Range is required rather than an element walk: the tree's labels
      // live in anchors that also contain an icon element, and an
      // element-level walk either skips them or attributes the icon's box to
      // the text. The first version of this measurement did skip them and
      // reported 0 for a page whose six labels are plainly legible — a
      // measurement bug that would have been read as a product defect.
      paintedText: (() => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let painted = 0, occluded = 0;
        const shown = [], hidden = [];
        let n;
        while ((n = walker.nextNode())) {
          const t = (n.textContent || '').trim();
          if (!t) continue;
          const owner = n.parentElement;
          if (!owner) continue;
          const cs = getComputedStyle(owner);
          const range = document.createRange();
          range.selectNodeContents(n);
          const c = range.getBoundingClientRect();
          const off = c.width === 0 || c.height === 0 ||
            cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0';
          const top = off ? null
            : document.elementFromPoint(c.x + c.width / 2, c.y + c.height / 2);
          if (!off && top && (top === owner || owner.contains(top) || top.contains(owner))) {
            painted += t.length; shown.push(t.slice(0, 60));
          } else { occluded += t.length; hidden.push(t.slice(0, 60)); }
        }
        return { painted, occluded, shown, hidden };
      })(),
      // ...and what the DOM merely CONTAINS. Reported beside it and asserted
      // by nothing, because the pair is a diagnostic and not a verdict: when
      // `domTextLength` is large and `visibleTextLength` is 0, the markup is
      // right and the browser drew nothing, which is a fault in the machine
      // running the check rather than in the thing being checked. Reading
      // this one INSTEAD would make the gate pass over the blank page it
      // exists to catch, so it stays out of every assertion.
      domTextLength: (document.body.textContent || '').trim().length,
      title: document.title,
      // THE RENDERED TREE, AS ONE COMPARABLE VALUE.
      //
      // `ide.codetracer.com/noir` and `noirstudio.dev/` are meant to be the
      // same screen reached two ways, and "the same" has to be checkable
      // rather than eyeballed. This is every element a user could see —
      // tag, id, class, integer rect, and whether it hit-tests to itself —
      // joined in document order. Two hosts agreeing on this string agree on
      // layout, stacking and content; two hosts disagreeing produce a diff
      // that names the element.
      //
      // Rects are rounded to integers because sub-pixel layout differs
      // harmlessly between runs. The ORIGIN is deliberately excluded: it is
      // the one thing that must differ between the two hosts, and including
      // it would make the digests differ by construction.
      renderedTree: (() => {
        const rows = [];
        for (const e of document.querySelectorAll('body *')) {
          const c = e.getBoundingClientRect();
          if (c.width === 0 || c.height === 0) continue;
          const cs = getComputedStyle(e);
          if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') continue;
          const top = document.elementFromPoint(c.x + c.width / 2, c.y + c.height / 2);
          const painted = !!top && (top === e || e.contains(top) || top.contains(e));
          const cls = (typeof e.className === 'string' ? e.className : '').trim();
          rows.push([e.tagName.toLowerCase(), e.id, cls,
                     Math.round(c.x), Math.round(c.y),
                     Math.round(c.width), Math.round(c.height),
                     painted ? 'p' : 'o'].join('|'));
        }
        return rows;
      })(),
      // The origin the PAGE believes it is on. Reported so a route arm can
      // show it measured the second host and not the first — a host-mapping
      // rule that silently failed to apply would otherwise look exactly like
      // a product that ignored the origin.
      origin: location.origin,
    };
  });
} catch (e) {
  dom = { evaluateError: String((e && e.message) || e).slice(0, 300) };
}

let screenshotWritten = '';
if (process.env.CT_PROBE_SCREENSHOT) {
  try {
    await page.screenshot({ path: process.env.CT_PROBE_SCREENSHOT });
    screenshotWritten = process.env.CT_PROBE_SCREENSHOT;
  } catch (e) {
    /* a screenshot is a convenience, never a verdict */
  }
}

// ---------------------------------------------------------------------------
// AND THEN PRESS IT. Everything above is a description of a page; this is the
// only part that finds out whether the page DOES anything.
// ---------------------------------------------------------------------------
//
// THE CHECK THIS REPLACES ASSERTED A CLASS NAME, and the class name is exactly
// what lied. `dom.testRunButton.disabled` reads `className.includes('disabled')`
// — so a control that is painted, unstyled-as-dead, correctly titled, and wired
// to nothing scores identically to a working one. That is the same failure as
// the screenshot the whole file exists to improve on, one abstraction up: a
// picture cannot tell a live button from a dead one, and neither can its class.
//
// So: click it the way a user does and watch for the run.
//
// `page.click` and not `el.click()`. The DOM method dispatches an event at a
// node regardless of whether a person could reach it; Playwright's actionability
// requires the element to be visible, stable, enabled and — the one that matters
// here — TO RECEIVE THE POINTER at its own hit point. A run control covered by
// an overlay would pass `el.click()` and fail this, which is the correct verdict:
// the gutter checks above already reason about hit areas for the same reason.
//
// The evidence is the CONSOLE, not the DOM. `ui/web_noir_build.report` prints
// `codetracer-noir-build: nbpTest-started handle=N` at the moment the worker
// accepts the dispatch, and `nbpTest-refused reason=...` when it does not. Those
// two are the distinction this phase exists to draw, and they are unreachable
// from any state the page paints before the click. A pane headline is reported
// beside them because the headline is what the user actually sees, but the
// started line is the one that cannot be faked by rendering.
let runClick = null;
if (process.env.CT_PROBE_CLICK_RUN) {
  const marker = 'codetracer-noir-build:';
  const linesBefore = consoleLines.length;
  runClick = {
    attempted: true,
    clicked: false,
    clickError: '',
    headlineBefore: '',
    headlineAfter: '',
    startedLine: '',
    refusedLine: '',
    resultsLine: '',
    exitLine: '',
    newConsole: [],
  };
  try {
    const headlineOf = () =>
      page.evaluate(() =>
        ((document.querySelector('.test-results-headline') || {}).textContent ||
          '').trim());
    runClick.headlineBefore = await headlineOf();
    await page.click('.test-results-run-btn', { timeout: 15000 });
    runClick.clicked = true;

    // The dispatch is synchronous with the click, but the worker has ~16 MB of
    // wasm to fetch and instantiate before it answers, so the STARTED line and
    // the verdicts are waited for separately and with very different budgets.
    const waitForLine = async (test, budgetMs) => {
      const deadline = Date.now() + budgetMs;
      while (Date.now() < deadline) {
        const hit = consoleLines.slice(linesBefore).find(test);
        if (hit) return hit;
        await page.waitForTimeout(250);
      }
      return '';
    };
    runClick.startedLine = await waitForLine(
      (l) => l.includes(marker) && l.includes('nbpTest-started'), 30000);
    // Reported whether or not the run started, because "it started" and "it was
    // refused for a named reason" are both answers, and only silence is not.
    runClick.refusedLine = consoleLines.slice(linesBefore).find(
      (l) => l.includes(marker) &&
             (l.includes('test-refused') || l.includes('test-ignored') ||
              l.includes('nbpTest-refused'))) || '';
    runClick.headlineAfter = await headlineOf();
    if (runClick.startedLine) {
      runClick.exitLine = await waitForLine(
        (l) => l.includes(marker) && l.includes('nbpTest-exit'), 180000);
      runClick.resultsLine = await waitForLine(
        (l) => l.includes(marker) && l.includes('test-results '), 10000);
      runClick.headlineAfter = await headlineOf();
    }
  } catch (e) {
    runClick.clickError = String((e && e.message) || e).slice(0, 300);
  }
  runClick.newConsole = consoleLines.slice(linesBefore)
    .filter((l) => l.includes(marker)).slice(0, 40);
}

// THE EDITOR'S OWN RUN CONTROL, PRESSED.
//
// The report this exists for is verbatim: "I tried to interact with the 'Run
// test' feature in Codetracer inserted in the monaco editor... Naturally, it
// just hanged in the browser without the ability to run the actual test."
//
// `runClick` above presses the Test Results pane's control and is the proof
// that A run can start. It says nothing about THIS control, which is a
// different element, on a different surface, wired through a different hook
// (`editor.editorTestRunHook` -> `web_noir_build.startNoirTestRecording`), and
// which is the one the user pressed. The two were separately capable of being
// broken and only one was ever measured.
//
// WHAT IS RECORDED, and why each field is not the others:
//
//   * `ownsHitArea` — `elementFromPoint` at the control's own centre. A
//     control painted under the breakpoint marker would be pressed by nobody,
//     and a screenshot cannot tell that apart from a working one.
//   * `startedLine` / `refusedLine` — the dispatch, from the console. "It
//     started" and "it was refused, for this reason" are both answers; only
//     silence is the reported defect.
//   * `runningAfterClick` — the slot took a RUNNING state. On its own this is
//     the defect, not the fix: the shipped bug was a control that span forever
//     over a message no host answered.
//   * `runningAfterSettle` — and it STOPPED. This is the pair that separates
//     "ran" from "hanged", and it is why both are recorded rather than the
//     first alone.
let gutterRunClick = null;
if (process.env.CT_PROBE_CLICK_GUTTER_RUN) {
  const marker = 'codetracer-noir-build:';
  const linesBefore = consoleLines.length;
  gutterRunClick = {
    attempted: true,
    slot: null,
    clicked: false,
    clickError: '',
    startedLine: '',
    refusedLine: '',
    exitLine: '',
    resultsLine: '',
    runningAfterClick: null,
    runningAfterSettle: null,
    headlineBefore: '',
    headlineAfter: '',
    newConsole: [],
  };
  try {
    const headlineOf = () =>
      page.evaluate(() =>
        ((document.querySelector('.test-results-headline') || {}).textContent ||
          '').trim());
    const runningCount = () =>
      page.evaluate(() =>
        document.querySelectorAll('.gutter-runtest.running').length);

    // The row has to be HOVERED for the control to be visible; it is laid out
    // at all times (`opacity`, not `display`) so its box is stable, but a
    // press with no hover is not the gesture a user makes.
    gutterRunClick.slot = await page.evaluate(() => {
      const el = document.querySelector('.gutter-runtest[data-runtest-line]');
      if (!el) return null;
      const r = el.getBoundingClientRect();
      const row = el.closest('.gutter');
      const bp = row && row.querySelector(
        '[class*="gutter-breakpoint-"], [class*="gutter-no-breakpoint"]');
      const br = bp ? bp.getBoundingClientRect() : null;
      const cx = Math.round(r.x + r.width / 2);
      const cy = Math.round(r.y + r.height / 2);
      const hit = document.elementFromPoint(cx, cy);
      return {
        line: el.getAttribute('data-runtest-line'),
        left: Math.round(r.left), right: Math.round(r.right),
        width: Math.round(r.width), height: Math.round(r.height),
        centre: { x: cx, y: cy },
        breakpointLeft: br ? Math.round(br.left) : null,
        breakpointRight: br ? Math.round(br.right) : null,
        overlapsBreakpoint: br ? !(r.right <= br.left || r.left >= br.right) : null,
        ownsHitArea: hit === el || el.contains(hit),
        hitElement: hit
          ? `${hit.tagName}.${typeof hit.className === 'string' ? hit.className.slice(0, 40) : ''}`
          : null,
      };
    });
    if (gutterRunClick.slot) {
      gutterRunClick.headlineBefore = await headlineOf();
      await page.mouse.move(
        gutterRunClick.slot.centre.x, gutterRunClick.slot.centre.y);
      await page.waitForTimeout(300);
      await page.mouse.click(
        gutterRunClick.slot.centre.x, gutterRunClick.slot.centre.y);
      gutterRunClick.clicked = true;
      await page.waitForTimeout(500);
      gutterRunClick.runningAfterClick = await runningCount();

      const waitForLine = async (test, budgetMs) => {
        const deadline = Date.now() + budgetMs;
        while (Date.now() < deadline) {
          const hit = consoleLines.slice(linesBefore).find(test);
          if (hit) return hit;
          await page.waitForTimeout(250);
        }
        return '';
      };
      gutterRunClick.startedLine = await waitForLine(
        (l) => l.includes(marker) && l.includes('nbpTest-started'), 30000);
      gutterRunClick.refusedLine = consoleLines.slice(linesBefore).find(
        (l) => l.includes(marker) &&
               (l.includes('test-record-refused') ||
                l.includes('test-record-ignored') ||
                l.includes('test-refused') || l.includes('test-ignored') ||
                l.includes('nbpTest-refused'))) || '';
      if (gutterRunClick.startedLine) {
        gutterRunClick.exitLine = await waitForLine(
          (l) => l.includes(marker) && l.includes('nbpTest-exit'), 180000);
        gutterRunClick.resultsLine = await waitForLine(
          (l) => l.includes(marker) && l.includes('test-results '), 10000);
      }
      await page.waitForTimeout(1500);
      gutterRunClick.runningAfterSettle = await runningCount();
      gutterRunClick.headlineAfter = await headlineOf();
    }
  } catch (e) {
    gutterRunClick.clickError = String((e && e.message) || e).slice(0, 300);
  }
  gutterRunClick.newConsole = consoleLines.slice(linesBefore)
    .filter((l) => l.includes(marker)).slice(0, 40);
}

await browser.close();

console.log(
  JSON.stringify(
    {
      url,
      loadError,
      dom,
      runClick,
      gutterRunClick,
      pageErrors,
      failedRequests: [...new Set(failedRequests)],
      // The two arms' own sentences, picked out of the console rather than the
      // DOM: the renderer hides its status element on success, and a headless
      // check must not depend on a diagnostic staying visible to a user.
      bootLine:
        consoleLines.find((l) => l.includes('codetracer-web-boot:')) || '',
      rendererLine:
        consoleLines.find((l) => l.includes('codetracer-web-renderer:')) || '',
      consoleErrorCount: consoleLines.filter((l) => l.startsWith('error:')).length,
      screenshotWritten,
    },
    null,
    2
  )
);
