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

await browser.close();

console.log(
  JSON.stringify(
    {
      url,
      loadError,
      dom,
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
