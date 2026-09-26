// jsdom-run.mjs — run a Nim suite compiled for the BROWSER target (`nim js`
// WITHOUT `-d:nodejs`) under node, over a real DOM.
//
// The `renderer-dom` lane's runner (ci/lib/run-nim-test-lane.sh, backend
// `js-dom`). A renderer module cannot be compiled with `-d:nodejs` (karax's
// `kdom` has no `createElementNS` there — see ci/lib/test-lane-files.sh on
// `js-browser`), and its module graph touches `window` and `document` at
// import time, so it is compiled as the browser module it is and given
// jsdom's `window`, `document` and `navigator` as its globals.
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
  { url: 'http://localhost' });
globalThis.window = dom.window;
globalThis.document = dom.window.document;
try { delete globalThis.navigator; } catch { /* not configurable: ignore */ }
Object.defineProperty(globalThis, 'navigator', {
  value: dom.window.navigator, writable: true, configurable: true,
});

globalThis.ctRepoRoot = REPO;
require(suite);
