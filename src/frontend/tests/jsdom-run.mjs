// jsdom-run.mjs — run a Nim suite compiled for the BROWSER target (`nim js`
// WITHOUT `-d:nodejs`) under node, over a real DOM.
//
// The `renderer-dom` lane's runner (ci/lib/run-nim-test-lane.sh, backend
// `js-dom`). A renderer module cannot be compiled with `-d:nodejs` (`kdom`
// has no `createElementNS` there — see ci/lib/test-lane-files.sh on
// `js-browser`), and its module graph touches `window` and `document` at
// import time, so it is compiled as the browser module it is and given
// jsdom's `window`, `document` and `navigator` as its globals.
//
// `test-frontend-js` also runs a few `-d:nodejs` suites here. They compile
// for node but reach IsoNim's `core/nondet`, which reads the page globals
// below as soon as a `window` exists, so a bare `window = globalThis` alias
// is not enough for them.
//
// Without `-d:nodejs`, `std/unittest` cannot set the process's exit status;
// a suite run here sets `process.exitCode` itself when a check fails, and the
// lane runner also counts `[FAILED]` lines.
//
// `globalThis.ctRepoRoot` is the checkout, for suites that read a committed
// fixture.
//
// Usage: node src/frontend/tests/jsdom-run.mjs <compiled-suite.js>
import { createRequire } from 'node:module';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../../..');

const suite = process.argv[2];
if (!suite || !fs.existsSync(suite)) {
  console.error(`jsdom-run.mjs: needs the compiled suite as argv[2]; got ${suite}`);
  process.exit(2);
}

const jsdomPath = path.join(REPO, 'node_modules/jsdom');
if (!fs.existsSync(jsdomPath)) {
  console.error(`jsdom-run.mjs: ${jsdomPath} is absent — install the repo's node modules ` +
    '(the frontend-js lane has the same requirement)');
  process.exit(2);
}
const { JSDOM } = require(jsdomPath);
const dom = new JSDOM('<!DOCTYPE html><html><body></body></html>',
  // `pretendToBeVisual` gives the window `requestAnimationFrame`, which a
  // mounted pane schedules its measurement with (jsdom's own, at 60 Hz).
  { url: 'http://localhost', pretendToBeVisual: true });
globalThis.window = dom.window;
globalThis.document = dom.window.document;
try { delete globalThis.navigator; } catch { /* not configurable: ignore */ }
Object.defineProperty(globalThis, 'navigator', {
  value: dom.window.navigator, writable: true, configurable: true,
});

// The rest of the page globals a browser module may read AT IMPORT TIME, as
// bare names. IsoNim's `core/nondet` snapshots the page environment when it
// initialises in a window (`location.href`, `innerWidth`/`innerHeight`,
// `devicePixelRatio`, `matchMedia(...)`, `localStorage`), and every suite that
// reaches it through the renderer's module graph — `ui/session_switch` does,
// via its menu — dies before its first line without these. They are jsdom's
// own objects, not stand-ins, with one exception: jsdom does not implement
// `matchMedia` (https://github.com/jsdom/jsdom/issues/3522), so a page whose
// media queries match nothing answers it, which is what a headless window
// with no preferences would report.
for (const name of ['location', 'localStorage', 'sessionStorage',
  'innerWidth', 'innerHeight', 'devicePixelRatio']) {
  if (!(name in globalThis)) {
    Object.defineProperty(globalThis, name, {
      get: () => dom.window[name], configurable: true,
    });
  }
}
if (typeof dom.window.matchMedia !== 'function') {
  dom.window.matchMedia = (query) => ({
    matches: false, media: String(query), onchange: null,
    addListener() {}, removeListener() {},
    addEventListener() {}, removeEventListener() {}, dispatchEvent() { return false; },
  });
}
if (!('matchMedia' in globalThis)) globalThis.matchMedia = dom.window.matchMedia;

// The observers, the style query and the frame clock a mounted pane reaches
// as bare names; all but `ResizeObserver` are jsdom's own. jsdom has no
// layout engine and so no `ResizeObserver`
// (https://github.com/jsdom/jsdom/issues/3368); the stand-in observes nothing,
// which is what a pane that is never resized sees. No suite here reads a size.
for (const name of ['MutationObserver', 'getComputedStyle', 'KeyboardEvent',
  'requestAnimationFrame', 'cancelAnimationFrame']) {
  if (!(name in globalThis) && dom.window[name]) {
    globalThis[name] = name === 'getComputedStyle'
      ? dom.window.getComputedStyle.bind(dom.window)
    : (name.endsWith('AnimationFrame') ? dom.window[name].bind(dom.window) : dom.window[name]);
  }
}
if (!('ResizeObserver' in globalThis)) {
  globalThis.ResizeObserver = class {
    observe() {} unobserve() {} disconnect() {}
  };
}

globalThis.ctRepoRoot = REPO;
require(suite);
