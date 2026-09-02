// Low Level Code row click — asserted in a real Chromium DOM, on the render
// arm the web bundle actually ships.
//
// ## Why this exists
//
// `isonim_low_level_code_view.nim` has TWO row renderers. The headless suites
// drive `renderInstructionRowMock`, which binds `onclick = handler`. The web
// bundle renders `renderInstructionRowWeb`, which binds via
// `isonim_dom.addEventListener`. They are different procs reaching the same
// `onInstructionClick` closure — so a suite that only exercises the Mock arm
// can be entirely green against a binding no user ever touches. That is the
// divergent-arms hazard this repo has been bitten by (a lane compiled with a
// different define than the shipped bundle, every case taking the other
// branch).
//
// This probe closes that gap for the gesture that used to throw: clicking a
// Low Level Code row. It drives real Chromium, clicks the row's CENTRE with a
// real hit test (Playwright refuses the click if another element would receive
// it), and asserts what the click asked the backend for.
//
// ## What it does NOT prove
//
// The story's backend is a `MockBackendService`, so this checks the BINDING
// and the PAYLOAD, not the engine. That the request actually moves the session
// is asserted against a real `replay-server` in
// `src/frontend/viewmodel/tests/unit/test_row_click_jump_vm.nim`. The two
// together span click -> handler -> command -> position.
//
// ## Run
//
//   just build-storybook-components     # produces storybook/dist/components.js
//   node ci/test/low_level_code_row_click_probe.mjs
//
// Needs `playwright` resolvable (the Nix dev shell provides it; outside it,
// point NODE_PATH at a checkout that has node_modules/playwright). Serves the
// bundle itself on an OS-assigned port — no external server to start.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const bundlePath = resolve(repoRoot, 'storybook/dist/components.js');

if (!existsSync(bundlePath)) {
  console.error(`missing ${bundlePath}\nrun: just build-storybook-components`);
  process.exit(2);
}

// STALENESS GATE. This probe asserts against a PRE-BUILT bundle, so a stale
// `components.js` would silently test code that is no longer on disk — the
// same shape as a lane compiled from different sources than the one that
// ships. Not hypothetical: while mutation-testing this probe, a bundle left
// over from a mutation arm produced two confident failures against
// already-corrected source.
//
// The gate is on CONTENT, not mtime, and that is deliberate. An mtime gate was
// tried first and is unworkable here: `nim js` does not rewrite its output when
// the generated JS is byte-identical, so once any source is touched the bundle
// stays "older" forever and the gate goes permanently red no matter how many
// correct rebuilds happen — a check that reports a problem it can no longer
// measure. Comparing the command string the VM currently sends against what
// the bundle contains has no such failure mode: a legitimate rebuild always
// agrees, and a bundle built from different source does not.
{
  const vmPath = resolve(repoRoot, 'src/frontend/viewmodel/viewmodels/low_level_code_vm.nim');
  const vmSource = await readFile(vmPath, 'utf8');
  const jumpProc = vmSource.split('proc jumpToInstruction*')[1] ?? '';
  const wanted = jumpProc.match(/backend\.send\("([^"]+)"/)?.[1];
  if (!wanted) {
    console.error(`could not read the command sent by jumpToInstruction in ${vmPath}`);
    process.exit(2);
  }
  if (!(await readFile(bundlePath, 'utf8')).includes(wanted)) {
    console.error(
      `storybook/dist/components.js does not contain "${wanted}", the command\n` +
        `${vmPath} currently sends — the bundle was built from different source.\n` +
        'run: just build-storybook-components',
    );
    process.exit(2);
  }
}

// Resolve `playwright` without assuming a node_modules in THIS worktree.
// Bare-specifier resolution walks up from this file, and `NODE_PATH` is not
// consulted for ESM — so outside the dev shell (which puts playwright on the
// path) point CT_PLAYWRIGHT_NODE_MODULES at any checkout that has it.
let chromium;
{
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const candidates = [
    process.env.CT_PLAYWRIGHT_NODE_MODULES,
    resolve(repoRoot, 'node_modules'),
  ].filter(Boolean);

  try {
    ({ chromium } = await import('playwright'));
  } catch {
    let loaded = null;
    for (const dir of candidates) {
      try {
        const req = createRequire(resolve(dir, 'noop.js'));
        loaded = await import(pathToFileURL(req.resolve('playwright')).href);
        break;
      } catch {
        /* try the next candidate */
      }
    }
    if (!loaded) {
      console.error(
        'playwright is not resolvable. Run inside the dev shell, or set\n' +
        'CT_PLAYWRIGHT_NODE_MODULES=/path/to/a/checkout/node_modules',
      );
      process.exit(2);
    }
    // playwright's entry is CJS: importing it by file URL puts the exports on
    // `.default`, while the bare-specifier path above yields named exports.
    chromium = loaded.chromium ?? loaded.default?.chromium;
  }
}

if (!chromium) {
  console.error('resolved playwright, but it exposes no `chromium` launcher');
  process.exit(2);
}

const PAGE = `<!doctype html><html><head><meta charset="utf-8"><title>row click</title>
<style>
 .low-level-code-instruction{padding:6px 10px;font-family:monospace;cursor:pointer;border-bottom:1px solid #ddd}
 .low-level-code-error{color:#b00;padding:6px}
 body{margin:0;font-size:14px}
</style></head><body><div id="root"></div><script src="/components.js"></script></body></html>`;

const bundle = await readFile(bundlePath);
const server = createServer((req, res) => {
  if (req.url === '/components.js') {
    res.writeHead(200, { 'content-type': 'application/javascript' });
    res.end(bundle);
  } else {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(PAGE);
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/`;

let failures = 0;
let checks = 0;
const check = (name, cond, detail = '') => {
  checks++;
  if (cond) console.log(`  [OK] ${name}`);
  else {
    failures++;
    console.log(`  [FAILED] ${name} ${detail}`);
  }
};

const browser = await chromium.launch();
const page = await browser.newPage();
const pageErrors = [];
page.on('pageerror', (e) => pageErrors.push(String(e)));
await page.goto(url, { waitUntil: 'load' });

const mount = (fixture) =>
  page.evaluate((f) => {
    const root = document.getElementById('root');
    root.innerHTML = '';
    window.mountCodeTracerStory(root, 'panel', 'low-level-code', f);
  }, fixture);
const sentCommands = async () =>
  JSON.parse(await page.evaluate(() => window.storyBackendCommands()));

console.log('[Suite] Low Level Code row click, real Chromium DOM (shipped web render arm)');

// --- a row that carries a source back-pointer -------------------------------
await mount('default');
await page.waitForSelector('.low-level-code-instruction', { timeout: 10000 });
const rows = page.locator('.low-level-code-instruction');
const rowCount = await rows.count();
check('the shipped web arm painted the fixture rows (count asserted)', rowCount === 3, `got ${rowCount}`);

// The THIRD row is offset 8 -> line 43. Row 1 is line 42 and the ACTIVE row is
// offset 4, so a payload of 43 can only come from the row actually clicked.
const target = rows.nth(2);
const box = await target.boundingBox();
check('the target row has a real hit-testable box', !!box && box.width > 0 && box.height > 0, JSON.stringify(box));

await target.click(); // centre of the element, with a real hit test
await page.waitForTimeout(300);

const sent = await sentCommands();
check('exactly one backend request resulted from the click', sent.length === 1, JSON.stringify(sent));
if (sent.length === 1) {
  check('the click asked for a source-line jump', sent[0].command === 'ct/source-line-jump', `got ${sent[0].command}`);
  check("it carried the clicked row's path", sent[0].args.path === 'src/combat.nr', JSON.stringify(sent[0].args));
  check("it carried the clicked row's line (43, not 42)", sent[0].args.line === 43, JSON.stringify(sent[0].args));
}
check('no error banner on a row that could jump', (await page.locator('.low-level-code-error').count()) === 0);

// --- a row with no back-pointer ---------------------------------------------
await mount('no-source-ref');
await page.waitForSelector('.low-level-code-instruction', { timeout: 10000 });
const before = (await sentCommands()).length;
await page.locator('.low-level-code-instruction').first().click();
await page.waitForTimeout(300);
const after = (await sentCommands()).length;
check('a row with no back-pointer sends nothing', after === before, `before=${before} after=${after}`);
const errText = await page.locator('.low-level-code-error').first().textContent().catch(() => null);
check('...and the pane says so, rendered into the real DOM', !!errText && errText.length > 0, `text=${JSON.stringify(errText)}`);

check('no uncaught page errors', pageErrors.length === 0, pageErrors.join(' | '));

await browser.close();
server.close();

console.log(`\nRESULT: ${checks - failures}/${checks} checks passed, ${failures} failed`);
if (checks === 0) {
  console.log('RESULT: FAILED — no checks ran');
  process.exit(1);
}
process.exit(failures === 0 ? 0 : 1);
