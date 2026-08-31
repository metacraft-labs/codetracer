/**
 * Three `innerHTML` sinks in the Electron renderer, and what keeps them text.
 *
 * CodeTracer's whole purpose is replaying UNTRUSTED programs, and its renderer
 * is an Electron renderer — markup that executes there is not a defaced page.
 * Three sinks put strings that are not markup into `innerHTML`:
 *
 *  1. `renderer.nim`'s file-conflict dialog interpolated a workspace `path`
 *     into `overlay.innerHTML`.  `<`, `>`, `"` and `'` are all legal POSIX
 *     filename characters, and the path arriving on `CODETRACER::change-file`
 *     is either a watched source file (`index/config.nim:108`) or a string an
 *     ACP agent put in a `tool_call_update` (`ipc_subsystems/acp_ipc.nim:413`,
 *     forwarded with no filesystem check at all).
 *
 *  2. Both copies of `showContextMenu` — `renderer.nim` and
 *     `viewmodel/views/context_menu_bridge.nim` — assigned `option.name` and
 *     `option.hint` to `innerHTML`.  Most labels are literals.  Not all:
 *     `isonim_state_view.nim`'s "Switch process: <role>" carries a `role` or
 *     `recordingId` copied verbatim out of a shipped `session.toml`
 *     (`db-backend/src/session_manifest.rs`'s `unquote` is the only content
 *     check there is, and 1- and 2-trace manifests have no role whitelist),
 *     and `panel_transfer.nim:151` carries a window title.
 *
 *  3. `ui/terminal_output.nim` and `ui/build.nim` put `ansi_up` output into
 *     `innerHTML` on purpose — the `<span>` colour runs are the point.  That
 *     is safe ONLY because `ansi_up` 6.0.6 initialises `_escape_html = true`.
 *     Nothing pinned it.  `escape_html = false` is one line, and the library
 *     offers it.
 *
 * The fixes are `textContent` at 1 and 2, and an explicit `escape_html = true`
 * in `lib/ansi_html.nim` at 3.  This file is what keeps them.
 *
 * EVERY negative below has a positive twin through the same code path: for
 * each hostile value, the PRE-FIX sink is exercised on the same DOM and MUST
 * render the payload.  A harness that stopped observing anything would fail
 * those immediately, so "renders nothing" can never pass vacuously.
 *
 * Run (see `just test-frontend-js`):
 *   nim -d:chronicles_enabled=off -d:ctRenderer --out:PROBE js \
 *       src/frontend/tests/html_sinks_probe.nim
 *   node --no-warnings src/frontend/tests/htmlSinks.test.mjs PROBE
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../../..');
const SELF = path.relative(REPO, fileURLToPath(import.meta.url));

const probePath = process.argv[2];
if (!probePath || !fs.existsSync(probePath)) {
  console.error(
    `htmlSinks.test.mjs: needs the compiled html_sinks_probe.js as argv[2]; got ${probePath}`);
  process.exit(2);
}

// ---------------------------------------------------------------------------
// A real DOM.  jsdom, not karax's `-d:nodejs` emulation — the whole question
// is what an HTML parser does with these strings.
// ---------------------------------------------------------------------------

const { JSDOM } = require(path.join(REPO, 'node_modules/jsdom'));
const { AnsiUp } = require(path.join(REPO, 'node_modules/ansi_up/ansi_up.js'));

const dom = new JSDOM(
  '<!DOCTYPE html><html><body><div id="context-menu-container"></div></body></html>',
  { url: 'http://localhost' });
globalThis.window = dom.window;
globalThis.document = dom.window.document;
// Node 22 exposes `navigator` as a getter-only global, so a plain assignment
// throws before a single assertion runs.  Node 20 allows it — which is why
// this has to be written the awkward way rather than the way that worked
// locally.  (`monaco-env.mjs` carries the same dance.)
try { delete globalThis.navigator; } catch { /* not configurable: ignore */ }
Object.defineProperty(globalThis, 'navigator', {
  value: dom.window.navigator, writable: true, configurable: true,
});
// `frontend_imports.js` does `window.AnsiUp = ansi_up.AnsiUp` for the bundle;
// the probe's `new AnsiUp` resolves through the same global.
globalThis.AnsiUp = AnsiUp;

// `types.nim` dumps its api tables to the console at import time.  Silence
// that, and only that.
const realLog = console.log;
console.log = () => {};
require(probePath);
console.log = realLog;

const doc = dom.window.document;
const menuContainer = doc.getElementById('context-menu-container');

// ---------------------------------------------------------------------------
// Test framework (same shape as the sibling `*.test.mjs` files)
// ---------------------------------------------------------------------------

let passed = 0;
let failed = 0;

function assert(condition, message) {
  if (condition) {
    passed++;
    console.log(`\x1b[32m  ok\x1b[0m ${message}`);
  } else {
    failed++;
    console.log(`\x1b[31m  FAIL\x1b[0m ${message}`);
  }
}

function assertEqual(actual, expected, message) {
  assert(
    actual === expected,
    `${message} \x1b[2m(expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)})\x1b[0m`);
}

function describe(name) {
  console.log(`\n\x1b[1m${name}\x1b[0m`);
}

/** Elements that can carry or become a payload once parsed. */
const PAYLOAD_SELECTOR = 'img,svg,script,iframe,form,math,style,template,noscript,object,embed,a';

function payloadElements(el) {
  return el.querySelectorAll(PAYLOAD_SELECTOR).length;
}

/**
 * Does anything under `el` carry a real `on*` ATTRIBUTE?
 *
 * Deliberately not a regex over `el.innerHTML`: the serialisation of an
 * escaped text node still reads `... onerror=alert(1)&gt;`, so a regex there
 * reports a handler over a DOM that has none, and every fixed site "fails".
 * Attribute names are the only thing that distinguishes markup from text.
 */
function hasEventHandlerAttr(el) {
  for (const node of el.querySelectorAll('*')) {
    for (const attr of node.attributes) {
      if (/^on/i.test(attr.name)) return true;
    }
  }
  return false;
}

/** Render `html` through the PRE-FIX sink, in this same document. */
function renderAsMarkup(html) {
  const scratch = doc.createElement('div');
  scratch.innerHTML = html;
  return scratch;
}

// ---------------------------------------------------------------------------
// The corpora.  Each entry names the origin that can carry it.
// ---------------------------------------------------------------------------

/** Site 1 — paths.  Origin: a watched source file, or an ACP `filepath`. */
const HOSTILE_PATHS = {
  'a workspace source file named with an img payload':
    '/home/u/proj/<img src=x onerror=alert(1)>/main.rs',
  'a directory named with an svg payload':
    '/tmp/<svg onload=alert(1)>/lib.rs',
  'an ACP tool_call_update filepath that is pure markup':
    '<script>alert(1)</script>',
  'a path component that is an iframe':
    '/home/u/<iframe src="javascript:alert(1)">/x.rs',
};
const HOSTILE_PATH_COUNT = 4;

/** Site 2 — menu labels.  Origin named per entry. */
const HOSTILE_LABELS = {
  'session.toml role, via "Switch process:" (isonim_state_view.nim:313)':
    'Switch process: <img src=x onerror=alert(1)>',
  'session.toml recording_id, the label fallback when role is empty':
    'Switch process: <svg onload=alert(1)>',
  'a window title, via "Send to:" (panel_transfer.nim:151)':
    'Send to: <iframe src="javascript:alert(1)">',
  'a trace value expression, via "Add ... to scratchpad" (editor.nim:1497)':
    'Add <img src=x onerror=alert(1)> to scratchpad',
};
const HOSTILE_LABEL_COUNT = 4;

/** Site 3 — program output.  Origin: the recorded program's own stdout. */
const HOSTILE_OUTPUT = {
  'program stdout that is an img payload':
    '<img src=x onerror=alert(1)>',
  'program stdout that tries to close ansi_up\'s own span first':
    '</span><img src=x onerror=alert(1)>',
  'ANSI-coloured output wrapping a script tag':
    '\x1b[31m<script>alert(1)</script>\x1b[0m',
  'program stdout with an inline handler':
    '<div onclick=alert(1)>click</div>',
};
const HOSTILE_OUTPUT_COUNT = 4;

// ---------------------------------------------------------------------------

console.log('\x1b[1mRenderer HTML sinks — path, menu label, program output\x1b[0m');

describe('C. Controls — the DOM is real, the probe is the shipped code');

// If this fails every "renders no element" assertion below is free.
{
  const control = renderAsMarkup('<img src=x onerror=alert(1)>');
  assertEqual(payloadElements(control), 1,
    'jsdom parses markup assigned to innerHTML (the harness can see a payload)');
}

for (const name of ['__ctFileConflictOverlay', '__ctFileConflictMarkup',
                    '__ctShowContextMenu', '__ctAnsiToHtml', '__ctAnsiEscapeFlag']) {
  assertEqual(typeof globalThis[name], 'function',
    `the compiled probe published ${name}`);
}

assert(menuContainer !== null,
  'the document has the #context-menu-container the shipped menu renders into');

// The bundle claim for site 3: the instance the probe constructs is the class
// the shipped bundle puts on `window`.
{
  const frontendImports = fs.readFileSync(
    path.join(REPO, 'src/frontend/frontend_imports.js'), 'utf8');
  assert(/^import \* as ansi_up from 'ansi_up';$/m.test(frontendImports),
    "the shipped bundle's entry imports the ansi_up package tested here");
  assert(/^window\.AnsiUp = ansi_up\.AnsiUp;$/m.test(frontendImports),
    'and publishes it as the `AnsiUp` global both call sites construct');
  const indexHtml = fs.readFileSync(path.join(REPO, 'src/frontend/index.html'), 'utf8');
  assert(indexHtml.includes('public/dist/frontend_bundle.js'),
    'index.html loads that bundle');
}

// Canary on the pin.  The product now sets this explicitly, but if upstream
// ever flips the default this line is the one that says so.
assertEqual(new AnsiUp().escape_html, true,
  "ansi_up's own constructor default is still escape_html = true");

describe(`A. The file-conflict dialog — ${HOSTILE_PATH_COUNT} hostile paths`);

// The shipped markup constant, read back out of the product.
const dialogMarkup = globalThis.__ctFileConflictMarkup();
assert(!dialogMarkup.includes('{'),
  'the dialog markup is a constant — it interpolates nothing');
assert(dialogMarkup.includes('<span class="file-conflict-dialog-path"></span>'),
  'and it carries an empty placeholder element for the path');

let checkedPaths = 0;
for (const [name, value] of Object.entries(HOSTILE_PATHS)) {
  // The PRE-FIX sink: exactly what `renderer.nim` used to do — the same
  // markup with the path spliced in where the placeholder now sits.
  const before = renderAsMarkup(
    dialogMarkup.replace('<span class="file-conflict-dialog-path"></span>', value));
  // The shipped builder.
  const after = globalThis.__ctFileConflictOverlay(value);
  checkedPaths++;

  // The demonstration, and the positive twin of the two assertions after it.
  assert(payloadElements(before) > 0 || hasEventHandlerAttr(before),
    `${name}: the PRE-FIX interpolation DOES render it as markup`);

  assertEqual(payloadElements(after), 0,
    `${name}: the shipped dialog renders no element from it`);
  assert(!hasEventHandlerAttr(after),
    `${name}: the shipped dialog renders no event-handler attribute`);

  // "Renders nothing" would also be satisfied by a dialog that dropped the
  // path.  It must still SAY the path, as one text node.
  // Read through `?.`: a missing element has to REDDEN the two assertions
  // below, not throw past them.  A mutation arm that dies mid-suite reports a
  // state it never reached — see Verification-Harness-Traps §1.
  const pathEl = after.querySelector('.file-conflict-dialog-path');
  assert(pathEl !== null, `${name}: the dialog still has its path element`);
  assertEqual(pathEl?.textContent ?? null, value,
    `${name}: and shows the path verbatim, as text`);
  assertEqual(pathEl?.childNodes.length ?? -1, 1,
    `${name}: as exactly one node`);

  // The e2e locator in `file_conflicts.spec.ts` is `.file-conflict-dialog`
  // with text "changed on disk".  Keep it.
  const box = after.querySelector('.file-conflict-dialog');
  assert(box !== null && box.textContent.includes('changed on disk'),
    `${name}: the dialog the e2e locator looks for is still there`);
}
// Trap 4b: the corpus size is knowable, so assert the count.
assertEqual(checkedPaths, HOSTILE_PATH_COUNT,
  'every hostile path was rendered (no silent skip)');

describe(`B. The context menu — ${HOSTILE_LABEL_COUNT} hostile labels`);

const HOSTILE_HINT = '<img src=x onerror=alert(1)>';

let checkedLabels = 0;
for (const [name, value] of Object.entries(HOSTILE_LABELS)) {
  // PRE-FIX twin, same document: what `labelEl.innerHTML = option.name` did.
  const before = renderAsMarkup(value);
  assert(payloadElements(before) > 0,
    `${name}: the PRE-FIX innerHTML DOES render it as markup`);

  globalThis.__ctShowContextMenu(value, HOSTILE_HINT);
  checkedLabels++;

  const label = menuContainer.querySelector('.ct-menu-item-label');
  const hint = menuContainer.querySelector('.ct-menu-item-sublabel');

  assert(label !== null, `${name}: the shipped menu rendered a label element`);
  assertEqual(payloadElements(menuContainer), 0,
    `${name}: and the whole menu contains no element from the label`);
  assert(!hasEventHandlerAttr(menuContainer),
    `${name}: and no event-handler attribute`);
  assertEqual(label?.textContent ?? null, value,
    `${name}: the label reads verbatim, as text`);
  assertEqual(label?.childNodes.length ?? -1, 1,
    `${name}: as exactly one node`);
  assert(hint !== null && hint.textContent === HOSTILE_HINT,
    `${name}: the hint is text too`);
}
assertEqual(checkedLabels, HOSTILE_LABEL_COUNT,
  'every hostile label was rendered (no silent skip)');

describe(`C3. Program output through ansi_up — ${HOSTILE_OUTPUT_COUNT} hostile outputs`);

assertEqual(globalThis.__ctAnsiEscapeFlag(), true,
  'the product constructor leaves escape_html = true on the instance');

const unescaping = new AnsiUp();
unescaping.escape_html = false;

let checkedOutput = 0;
for (const [name, value] of Object.entries(HOSTILE_OUTPUT)) {
  const shipped = renderAsMarkup(globalThis.__ctAnsiToHtml(value));
  // The mutation twin: the same library, the same value, one flag flipped.
  // This is what site 3 becomes if anyone writes that line.
  const unsafe = renderAsMarkup(unescaping.ansi_to_html(value));
  checkedOutput++;

  assert(payloadElements(unsafe) > 0 || hasEventHandlerAttr(unsafe),
    `${name}: with escape_html = false it DOES render as markup`);

  assertEqual(payloadElements(shipped), 0,
    `${name}: through the product's converter it renders no element`);
  assert(!hasEventHandlerAttr(shipped),
    `${name}: and no event-handler attribute`);
  assert(shipped.textContent.includes(value.replace(/\x1b\[[0-9;]*m/g, '')),
    `${name}: and the output is still shown, as text`);
}
assertEqual(checkedOutput, HOSTILE_OUTPUT_COUNT,
  'every hostile output was rendered (no silent skip)');

// The `<span>`s are the reason this sink is `innerHTML` at all.  If escaping
// ever cost us them, the fix would be wrong in the other direction.
{
  const coloured = renderAsMarkup(globalThis.__ctAnsiToHtml('\x1b[31mred\x1b[0m'));
  assertEqual(coloured.querySelectorAll('span').length, 1,
    'ANSI colour still produces the <span> this sink exists for');
  assertEqual(coloured.textContent, 'red',
    'carrying the text and nothing else');
}

describe('S. Source scan — the sinks stay written this way');

const SCAN_EXTENSIONS = new Set(['.nim', '.js', '.mjs', '.ts']);
const scanned = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) { walk(full); continue; }
    if (!SCAN_EXTENSIONS.has(path.extname(entry.name))) continue;
    const rel = path.relative(REPO, full);
    if (rel === SELF) continue;  // this file quotes the patterns on purpose
    scanned.push(rel);
  }
})(path.join(REPO, 'src'));

// Trap 4: assert the scan reached the tree before asserting what is not in it.
console.log(`  \x1b[2mfiles scanned: ${scanned.length}\x1b[0m`);
assert(scanned.length >= 900,
  `the scan reached the source tree (${scanned.length} files)`);

const sources = new Map(
  scanned.map((rel) => [rel, fs.readFileSync(path.join(REPO, rel), 'utf8')]));

function filesMatching(pattern) {
  return [...sources.entries()]
    .filter(([, text]) => pattern.test(text)).map(([rel]) => rel).sort().join(',');
}

// --- site 2: BOTH copies of the menu renderer -------------------------------
//
// The behavioural arm above drives the `context_menu_bridge` copy.  The
// `renderer.nim` copy is byte-for-byte the same loop in a module that cannot
// be imported (it is the Electron entry point), so the scan is what covers it
// — and the positive control is that the scan finds both.
assertEqual(filesMatching(/proc showContextMenu\*\(options: seq\[ContextMenuItem\]/),
  'src/frontend/renderer.nim,src/frontend/viewmodel/views/context_menu_bridge.nim',
  'the scan finds both copies of showContextMenu');
assertEqual(filesMatching(/textContent = option\.(name|hint)/),
  'src/frontend/renderer.nim,src/frontend/viewmodel/views/context_menu_bridge.nim',
  'and both write the label and the hint with textContent');
assertEqual(filesMatching(/innerHTML = option\./), '',
  'no copy assigns a menu option to innerHTML');

// --- site 1: the dialog -----------------------------------------------------
assertEqual(filesMatching(/const FileConflictDialogMarkup\* = /),
  'src/frontend/ui/file_conflict_dialog.nim',
  'the scan finds the module that owns the dialog markup');
assert(/buildFileConflictOverlay\(path\)/.test(sources.get('src/frontend/renderer.nim')),
  'and renderer.nim builds the overlay through it');
assertEqual(filesMatching(/innerHTML = cstring\((&|fmt)"/), '',
  'no source interpolates a formatted string into innerHTML');

// --- the two sites the scan above FOUND, in `ui/layout.nim` -----------------
//
// Neither was on the list this file was written for.  The GoldenLayout tab
// title carries a native absolute path (its own comment says so) and the
// component host interpolated a panel label into an unquoted `id=`.
assertEqual(filesMatching(/titleElement\.textContent = /),
  'src/frontend/ui/layout.nim',
  'the scan finds the editor tab title, which carries an absolute path');
assertEqual(filesMatching(/titleElement\.innerHTML/), '',
  'and it is never written as markup');
assertEqual(filesMatching(/proc mountComponentContainer\*/),
  'src/frontend/ui/layout.nim',
  'the component host is mounted through createElement + setAttribute');

// --- site 3: ansi_up --------------------------------------------------------
assertEqual(filesMatching(/importcpp: "new AnsiUp"/),
  'src/frontend/lib/ansi_html.nim',
  'the scan finds the single `new AnsiUp` in the product');
// Anchored to `result.` and to the start of the line, because the loose form
// `/escape_html = true/` matched the module's own DOC COMMENT: deleting the
// assignment left the prose behind and this assertion stayed green.  A scan
// that can be satisfied by a sentence about the code is not reading the code.
assertEqual(filesMatching(/^ +result\.escape_html = true$/m),
  'src/frontend/lib/ansi_html.nim',
  'and that constructor sets escape_html = true explicitly');
assertEqual(filesMatching(/escape_html\s*=\s*false/), '',
  'no source turns escape_html off');

// ---------------------------------------------------------------------------

const EXPECTED_ASSERTIONS = 104;
const total = passed + failed;
console.log(`\n\x1b[1m${total} assertions, ${failed} failed\x1b[0m`);
// Trap 4b again, at the top level: a silent skip anywhere above moves this.
if (total !== EXPECTED_ASSERTIONS) {
  console.log(`\x1b[31m  FAIL\x1b[0m the suite ran ${total} assertions, not ${EXPECTED_ASSERTIONS} — something was skipped or added without updating the count`);
  process.exit(1);
}
if (failed > 0) process.exit(1);
