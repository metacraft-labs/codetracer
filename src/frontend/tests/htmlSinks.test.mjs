/**
 * Every way markup or code can enter this renderer's DOM, and what keeps each
 * one shut.
 *
 * CodeTracer's whole purpose is replaying UNTRUSTED programs, and its renderer
 * is an Electron renderer running with `nodeIntegration: true` — markup that
 * executes there is not a defaced page.  Eight sinks put strings that are not
 * markup into `innerHTML`; the first three are the ones a triage trail led to,
 * and the rest were found by pinning the population rather than by looking:
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
 *  4. `ui/layout.nim` wrote the GoldenLayout editor tab title with `innerHTML`
 *     and interpolated a panel label into an unquoted `id=`; `ui/auto_hide.nim`
 *     wrote the auto-hide overlay title the same way.  All three carry a
 *     native absolute path.  None of them was on the list this file was
 *     written for — arm S found them.
 *
 *  5. `ui/low_level_code.nim` wrote A LINE OF THE RECORDED PROGRAM'S OWN
 *     SOURCE into `innerHTML`, and `ui/shell.nim` wrote a summary built from
 *     a recorded command line, a binary path and a linker error message.
 *     `ui/auto_hide_overlay.nim` exported a caller-less proc whose whole body
 *     was `contentEl.innerHTML = html`.  Arm S3 found all three by counting.
 *
 *  6. `ShellFacade.openExternalUrl`'s "implementations must refuse anything
 *     but http/https/mailto" was a DOC COMMENT, honoured by one of the two
 *     implementations that can open anything.  Arm S5.
 *
 * The fixes are `textContent` at 1, 2 and 4, `createElement` + `setAttribute`
 * for the `id=`, and an explicit `escape_html = true` in `lib/ansi_html.nim`
 * at 3.  This file is what keeps them.
 *
 * Arm S2 covers the sinks that are fine BECAUSE their input cannot vary, and
 * asserts the thing that makes it so — an `int` field type, a literal frame
 * list, a closed set of call sites over four `const`s.  "It is a literal
 * today" is exactly the reasoning that missed 4.
 *
 * Arms S3-S5 are the bounded negative.  S3 pins the WHOLE `innerHTML`
 * population — 48 writes, 14 of them non-clearing, every one triaged — so a
 * forty-ninth is a red run.  It pins them as a TABLE of files and a TRANSCRIPT
 * of the fourteen live writes, not as the number 48, so the red run names the
 * file that grew and quotes the line that did it: a budget whose failure
 * cannot say what it found is a budget the next reader bumps.  S4 sweeps the
 * other ways in (`outerHTML`,
 * `insertAdjacentHTML`, `document.write`, `srcdoc`, `<webview>`, `eval`,
 * `new Function`, string-bodied timers, karax's `verbatim`) and finds none,
 * with each pattern proved against a sample so an empty result cannot be an
 * empty pattern.  S5 pins the URL and code-execution reach that does exist.
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

// BUILD OUTPUT IS NOT SOURCE. `src/build-*/` and any `dist/` are produced by
// `just build-once` and are git-ignored (`.gitignore` carries `build-*/` and
// `dist/`). They hold `frontend_bundle.js`, `ui.js` and the vendored chunks —
// the COMPILED form of the very sources scanned below — so every pattern this
// section asserts about is found a second time, in a generated file, and
// reported as though someone had written it that way.
//
// Without this the section passes only on a tree that has NEVER been built and
// fails on every tree that has, which is the sequence AGENTS.md and CI both
// prescribe. Same defect, same fix as `monacoMarkdownSanitizer.test.mjs`.
const isGeneratedDir = (name) =>
  name === 'node_modules' || name === 'dist' || name.startsWith('build-');

const scanned = [];
/** Generated directories skipped above, so the skip itself can be asserted. */
const skippedGenerated = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (isGeneratedDir(entry.name)) { skippedGenerated.push(path.relative(REPO, full)); continue; }
      walk(full);
      continue;
    }
    if (isGeneratedDir(entry.name)) continue;
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

// Trap 4b: the exclusion must not become a way to scan nothing, and must not
// silently stop excluding. Both directions are asserted; the second only when
// there IS build output, so this stays honest on a clean checkout too.
assert(!scanned.some((rel) => rel.split(path.sep).some(isGeneratedDir)),
  'no generated directory survived the scan filter');

// Stated as ONE unconditional assertion, not an `if` around one: this suite
// reconciles its total assertion count at the end, so an assertion that runs
// only on a built tree would make that total depend on whether anyone had run
// `just build-once` — reintroducing, in the counter, exactly the build-state
// dependence this fix removes from the scan.
const builtDirs = ['src/build-debug', 'src/public/dist']
  .filter((rel) => fs.existsSync(path.join(REPO, rel)));
console.log(`  \x1b[2mbuild output present: ${builtDirs.length > 0 ? builtDirs.join(', ') : '(none)'}; generated dirs skipped: ${skippedGenerated.length}\x1b[0m`);
assert(builtDirs.length === 0 || skippedGenerated.length > 0,
  builtDirs.length === 0
    ? 'no build output in this tree, so there was nothing for the scan to skip'
    : `this tree HAS build output, so the scan must have skipped some (skipped ${skippedGenerated.length})`);

const sources = new Map(
  scanned.map((rel) => [rel, fs.readFileSync(path.join(REPO, rel), 'utf8')]));

function filesMatching(pattern) {
  return [...sources.entries()]
    .filter(([, text]) => pattern.test(text)).map(([rel]) => rel).sort().join(',');
}

/**
 * Every match of `pattern` across the scan, as `file:match` strings.
 *
 * `filesMatching` answers "which files mention this"; this answers "and what
 * exactly did they say".  It is what turns "the argument is a constant" from
 * an assumption into a closed set — see the chevron block below.
 */
function matchesAcross(pattern) {
  const out = [];
  for (const [rel, text] of sources) {
    for (const m of text.matchAll(pattern)) out.push(`${rel}:${m[0]}`);
  }
  return out.sort().join(' | ');
}

const FRONTEND = path.join(REPO, 'src/frontend');
const isComment = (line) => /^\s*(#|\/\/)/.test(line);
const isClear = (rhs) => rhs.trim() === 'cstring""' || rhs.trim() === '""';

/**
 * The shipped front end, with whole-line comments removed.
 *
 * Two scoping decisions, both learned the hard way in this file:
 *
 *  * **Comments are stripped**, because trap 4d is not a one-off.  Scanning
 *    the raw text for `verbatim(` matched five doc comments that mention
 *    karax's `verbatim`, and `setOverlayContent` matched the comment recording
 *    its own deletion.  A scan asserting a property of code must read code.
 *  * **`src/frontend`, excluding `/tests/`**, because the claim being made is
 *    about the renderer that ships.  Test harnesses legitimately use
 *    `new Function` (the startup benchmark compiles generated source on
 *    purpose) and `$eval` (Playwright), and `src/public/third_party` carries
 *    vendored `window.open` and `setAttribute("href", …)` that CodeTracer
 *    does not author.
 */
const shipped = new Map();
for (const [rel, text] of sources) {
  if (!path.join(REPO, rel).startsWith(FRONTEND)) continue;
  if (rel.includes('/tests/')) continue;
  shipped.set(rel, text.split('\n').filter((l) => !isComment(l)).join('\n'));
}

function shippedMatching(pattern) {
  return [...shipped.entries()]
    .filter(([, text]) => pattern.test(text)).map(([rel]) => rel).sort().join(',');
}

function shippedMatchesAcross(pattern) {
  const out = [];
  for (const [rel, text] of shipped) {
    for (const m of text.matchAll(pattern)) out.push(`${rel}:${m[0]}`);
  }
  return out.sort().join(' | ');
}

// Trap 4 for the narrower scan too: it has its own population, so assert it
// reached one before asserting what is not in it.
console.log(`  \x1b[2mshipped front-end files scanned: ${shipped.size}\x1b[0m`);
assert(shipped.size >= 250,
  `the shipped-front-end scan reached the tree (${shipped.size} files)`);


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
// Anchored on the PARAMETER LIST, not on the `*`. This read
// `/proc mountComponentContainer\*/` until the proc stopped being exported
// (it has no caller outside its own module, and the `*` was costing a
// `frontend-reachability` finding), at which point an assertion about an
// HTML sink would have failed over a visibility marker it does not care
// about.
assertEqual(filesMatching(/proc mountComponentContainer\(/),
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

describe('S2. The other innerHTML sinks — each one\'s input, and what fixes it');

// Everything below was read and set aside once already, on the assumption that
// its input could not vary.  `ui/layout.nim` is why that assumption is not
// worth much on its own: the tab title was assigned with `innerHTML` under
// exactly the same reasoning, and it carries an absolute path.  So each of
// these now records WHAT MAKES THE INPUT FIXED, as an assertion.

// --- ui/auto_hide.nim: the overlay title.  NOT a literal. -------------------
//
// `pinPanel` builds `AutoHidePanel.title` from
// `contentItem.tab.titleElement.textContent`, falling back to
// `componentState.label`.  For a pinned EDITOR tab both of those are derived
// from a native absolute path (`layout.nim`'s tab-title block, and
// `pinnedDocumentPath`'s own docs).  Only the four standalone panels — BUILD,
// PROBLEMS, FIND IN FILES, REQUESTS — are literals.
//
// Coverage here is scan-only: `ui/auto_hide.nim` imports
// `isonim/web/web_renderer`, and requiring an isonim checkout to run
// `just test-frontend-js` would cost more than it buys.  This is the same
// treatment `renderer.nim`'s menu copy gets, and M3 is the evidence that a
// scan with a positive control does catch that regression.
assertEqual(filesMatching(/getElementById\(cstring"auto-hide-overlay-title"\)/),
  'src/frontend/ui/auto_hide.nim',
  'the scan finds the auto-hide overlay title element');
assertEqual(filesMatching(/titleEl\.textContent = panel\.title/),
  'src/frontend/ui/auto_hide.nim',
  'and the title is written as text');
assertEqual(filesMatching(/titleEl\.innerHTML/), '',
  'and never as markup');
// The origin claim itself, so that "it is only a literal" cannot be
// re-asserted later without this line moving.
assert(/let text = tab\.titleElement\.textContent/.test(
  sources.get('src/frontend/ui/auto_hide.nim')),
  'pinPanel still takes that title from the GoldenLayout tab, which carries a path');

// --- ui/low_level_code.nim: A LINE OF THE RECORDED PROGRAM'S SOURCE --------
//
// Found by pinning the population, not by following a trail.  `sourceCode` is
// `tabInfo.sourceLines[highLevelLine-1]` — the program's own bytes.  For an
// HTML, JSX, Vue, PHP or template file it is markup by construction, and for
// anything else a string literal will do.  Scan-only coverage: the module
// reaches `ui_imports` and, through it, isonim.
assertEqual(shippedMatching(/textDom\.textContent = cstring\(fmt"\{highLevelLine\}\| \{sourceCode\}"\)/),
  'src/frontend/ui/low_level_code.nim',
  "the low-level view writes the program's source line as text");
assertEqual(shippedMatching(/textDom\.innerHTML/), '',
  'and never as markup');

// --- ui/shell.nim: a command line, a binary path, a linker error -----------
//
// `eventSummary` interpolates `event.program`, `event.binary`, `event.command`,
// `event.errorMessage` and a `recordingId`.  A recorded build controls all of
// them.  Scan-only, same reason.
assertEqual(shippedMatching(/eventSummary\.textContent = cstring\(event\.eventSummary\(\)\)/),
  'src/frontend/ui/shell.nim',
  'the shell event summary is written as text');
assertEqual(shippedMatching(/eventSummary\.innerHTML/), '',
  'and never as markup');

// --- ui/datatable.nim: two integers.  Enforced by the TYPE. ----------------
assertEqual(matchesAcross(/innerHTML = cstring\(\$\(self\.[A-Za-z]+\)\)/g),
  'src/frontend/ui/datatable.nim:innerHTML = cstring($(self.endRow)) | '
  + 'src/frontend/ui/datatable.nim:innerHTML = cstring($(self.rowsCount))',
  'datatable writes exactly two innerHTML values, both `$` of a field');
assert(/rowsCount\*: int\n\s+startRow\*: int\n\s+endRow\*: int/.test(
  sources.get('src/frontend/types.nim')),
  'and those fields are declared `int`, so `$` cannot produce a `<`');

// --- ui/editor.nim: a three-frame literal animation, and the label under it -
{
  const editorNim = sources.get('src/frontend/ui/editor.nim');
  assert(/let frames = \["Running\.  ", "Running\.\. ", "Running\.\.\."\]/.test(editorNim),
    'the load animation still reads from a literal three-frame list');
  assertEqual(matchesAcross(/el\.innerHTML = [A-Za-z]+\[i\]/g),
    'src/frontend/ui/editor.nim:el.innerHTML = frames[i]',
    'and that list is the only thing it assigns');

  // The forty-ninth write, named here rather than absorbed into a bumped
  // budget.  `restoreTestButton` puts the Run-test control back the way it
  // was, and `8df2b765` wrote its label with `innerHTML`.  Every value that
  // reaches it TODAY is a literal — `""`, `"Run test (timed out)"`, and the
  // defaulted `settleEditorTestRun()` — so the sink was not exploitable when
  // it landed.  It was still wrong: `note` is a sentence, the button's resting
  // label is built with `createTextNode`, and `settleEditorTestRun` is
  // EXPORTED with a defaulted parameter, so the population is decided by
  // whoever calls it next.  A host that wanted to say why a run was refused —
  // a compiler diagnostic, a recorded program's own stderr — would have been
  // writing markup.  So the sink was removed rather than budgeted for, and
  // this line is what keeps it removed.
  assertEqual(matchesAcross(/el\.(innerHTML|textContent) = if note\.len > 0/g),
    'src/frontend/ui/editor.nim:el.textContent = if note.len > 0',
    "the Run-test button's label is restored as text, not as markup");
}

// --- the `setInnerHtml` helpers: a constant chevron, and a CLOSED call set --
//
// "The payload is a constant SVG" is only true while nothing else calls the
// helper, so the assertion is the whole call set, not the constant.
assertEqual(filesMatching(/proc setInnerHtml\(r: WebRenderer/),
  'src/frontend/viewmodel/views/isonim_request_panel_view.nim,'
  + 'src/frontend/viewmodel/views/isonim_vcs_view.nim',
  'the scan finds both setInnerHtml helpers');
assertEqual(matchesAcross(/r\.setInnerHtml\([^)]*\)/g),
  'src/frontend/viewmodel/views/isonim_request_panel_view.nim:r.setInnerHtml(chevronHost, chevronSvg) | '
  + 'src/frontend/viewmodel/views/isonim_vcs_view.nim:r.setInnerHtml(chevronHost, chevronSvg)',
  'and every call passes chevronSvg — the call set is closed');
assertEqual(matchesAcross(/^const chevron(Up|Down)Svg/gm),
  'src/frontend/viewmodel/views/isonim_request_panel_view.nim:const chevronDownSvg | '
  + 'src/frontend/viewmodel/views/isonim_request_panel_view.nim:const chevronUpSvg | '
  + 'src/frontend/viewmodel/views/isonim_vcs_view.nim:const chevronDownSvg | '
  + 'src/frontend/viewmodel/views/isonim_vcs_view.nim:const chevronUpSvg',
  'and chevronSvg is one of four compile-time `const`s, so it cannot vary');

describe('S3. The whole innerHTML population, pinned');

// Six sites were fixed by looking at the ones a trail led to.  That is not the
// same as knowing how many there are.  This enumerates every `innerHTML` write
// in the shipped front end and pins the LIST, so a seventh is a red run rather
// than an unnoticed addition.
//
// Comment lines are excluded deliberately: `ui/trace.nim` carries two
// commented-out writes, and counting those would mean un-commenting one moved
// nothing.

// A TABLE AND A TRANSCRIPT, NOT TWO NUMBERS.  This arm used to assert
// `total === 48`, and the first time it moved it said "expected 48, got 49" —
// which tells the reader that a forty-ninth write exists and nothing whatever
// about where it is or what it writes.  Re-deriving that by hand is work, and
// the cheap way out of work is to bump the number, which turns the budget into
// a rubber stamp and makes the next genuinely new sink invisible.  So both
// halves below assert a VALUE that names its members: when one moves, the
// failure prints the file that grew and the line of source that did it, and
// triage starts from a diff instead of a hunt.
//
// The 48 in this file's header is DERIVED from the table rather than written
// twice, so the prose and the pin cannot drift apart.

/** Every shipped front-end file that writes innerHTML: `[file, clears, live]`. */
const INNER_HTML_BY_FILE = [
  ['src/frontend/renderer.nim', 1, 0],
  ['src/frontend/storybook_components.nim', 7, 2],
  ['src/frontend/subwindow.nim', 1, 0],
  ['src/frontend/ui/auto_hide_overlay.nim', 1, 0],
  ['src/frontend/ui/auto_hide.nim', 3, 1],
  ['src/frontend/ui/calltrace.nim', 2, 0],
  ['src/frontend/ui/datatable.nim', 0, 2],
  ['src/frontend/ui/editor.nim', 0, 1],
  ['src/frontend/ui/event_log.nim', 1, 0],
  ['src/frontend/ui/file_conflict_dialog.nim', 0, 1],
  ['src/frontend/ui/flow.nim', 2, 0],
  ['src/frontend/ui/layout.nim', 3, 0],
  ['src/frontend/ui/request_panel.nim', 1, 0],
  ['src/frontend/ui/scratchpad.nim', 1, 0],
  ['src/frontend/ui/state.nim', 1, 0],
  ['src/frontend/ui/terminal_output.nim', 1, 0],
  ['src/frontend/ui/trace.nim', 6, 3],
  ['src/frontend/ui/welcome_screen.nim', 2, 0],
  ['src/frontend/viewmodel/views/context_menu_bridge.nim', 1, 0],
  ['src/frontend/viewmodel/views/isonim_build_view.nim', 0, 1],
  ['src/frontend/viewmodel/views/isonim_request_panel_view.nim', 0, 1],
  ['src/frontend/viewmodel/views/isonim_terminal_output_view.nim', 0, 1],
  ['src/frontend/viewmodel/views/isonim_vcs_view.nim', 0, 1],
];

/**
 * The source text of every NON-CLEARING write, verbatim.
 *
 * The clears are counted but not transcribed: `x.innerHTML = cstring""` cannot
 * carry a payload, and `isClear` is what says so.  These fourteen are the
 * actual sinks, and each one is triaged by name in arm S or S2 above.
 */
const INNER_HTML_LIVE_WRITES = [
  'src/frontend/storybook_components.nim: denseHost.innerHTML = `denseHtml`;',
  'src/frontend/storybook_components.nim: if (detailedHost) detailedHost.innerHTML = `detailedHtml`;',
  'src/frontend/ui/auto_hide.nim: pinBtn.innerHTML = cstring"&#x2715;"  # X close/dismiss icon',
  'src/frontend/ui/datatable.nim: endRowField.innerHTML = cstring($(self.endRow))',
  'src/frontend/ui/datatable.nim: rowsCountField.innerHTML = cstring($(self.rowsCount))',
  'src/frontend/ui/editor.nim: el.innerHTML = frames[i]',
  'src/frontend/ui/file_conflict_dialog.nim: overlay.innerHTML = cstring(FileConflictDialogMarkup)',
  'src/frontend/ui/trace.nim: self.kindSwitchButton.innerHTML =',
  'src/frontend/ui/trace.nim: self.resultsOverlayDom.children[0].innerHTML = "Loading..."',
  'src/frontend/ui/trace.nim: self.resultsOverlayDom.children[0].innerHTML = NO_RESULTS_MESSAGE',
  'src/frontend/viewmodel/views/isonim_build_view.nim: lineNode.innerHTML = cstring(lineCopy.htmlText)',
  'src/frontend/viewmodel/views/isonim_request_panel_view.nim: node.innerHTML = cstring(html)',
  'src/frontend/viewmodel/views/isonim_terminal_output_view.nim: contentNode.innerHTML = cstring(frag.htmlText)',
  'src/frontend/viewmodel/views/isonim_vcs_view.nim: node.innerHTML = cstring(html)',
];

const foundByFile = new Map();
const foundLive = [];
for (const [rel, text] of sources) {
  if (!path.join(REPO, rel).startsWith(FRONTEND)) continue;
  if (rel.includes('/tests/')) continue;
  for (const line of text.split('\n')) {
    if (isComment(line)) continue;
    const m = /\.innerHTML\s*=(.*)$/.exec(line);
    if (!m) continue;
    const tally = foundByFile.get(rel) ?? { clears: 0, live: 0 };
    if (isClear(m[1])) {
      tally.clears++;
    } else {
      tally.live++;
      foundLive.push(`${rel}: ${line.trim()}`);
    }
    foundByFile.set(rel, tally);
  }
}

const asTable = (rows) => rows
  .map(([rel, clears, live]) => `${rel} ${clears} clear + ${live} live`)
  .sort().join('\n');

const innerHtmlTotal = INNER_HTML_BY_FILE.reduce((n, [, c, l]) => n + c + l, 0);
console.log(`  \x1b[2minnerHTML writes pinned: ${innerHtmlTotal} `
  + `(${INNER_HTML_LIVE_WRITES.length} non-clearing) across `
  + `${INNER_HTML_BY_FILE.length} files\x1b[0m`);

assertEqual(
  asTable([...foundByFile.entries()].map(([rel, t]) => [rel, t.clears, t.live])),
  asTable(INNER_HTML_BY_FILE),
  `the innerHTML population is these ${innerHtmlTotal} writes in these `
  + `${INNER_HTML_BY_FILE.length} files`);
assertEqual(
  foundLive.sort().join('\n'),
  [...INNER_HTML_LIVE_WRITES].sort().join('\n'),
  `and the ${INNER_HTML_LIVE_WRITES.length} non-clearing ones are written exactly this way`);

// The four that arm S/S2 do not already name, so all fourteen are accounted
// for rather than merely counted.
{
  const traceNim = sources.get('src/frontend/ui/trace.nim');
  assert(/RUN_TRACE_MESSAGE: cstring = "[^"<>]*"/.test(traceNim)
      && /NO_RESULTS_MESSAGE: cstring = "[^"<>]*"/.test(traceNim),
    'trace.nim\'s two overlay messages are markup-free string constants');
  assert(/innerHTML =\s*\n?\s*\(\$self\.chart\.viewKind\)\[4\.\.\^1\]/.test(traceNim),
    'and its third write is an enum name, which the type keeps markup-free');
  assert(/innerHTML = cstring"&#x2715;"/.test(
    sources.get('src/frontend/ui/auto_hide.nim')),
    'auto_hide\'s remaining write is a literal HTML entity — markup on purpose');
  assert(/htmlEscape\(/.test(sources.get('src/frontend/storybook_components.nim')),
    'the storybook table builder escapes the values it interpolates');
}

// The sink deleted rather than fixed: an exported proc whose whole body was
// `contentEl.innerHTML = html`, with no callers.
assertEqual(shippedMatching(/setOverlayContent/), '',
  'the caller-less setOverlayContent markup sink is gone, name and all');

describe('S4. The other ways markup or code enters a DOM — a counted negative');

// Trap 4a: a lone "must not contain" has nothing to fail.  Each row below
// asserts BOTH that the pattern can see a real instance (against a sample
// string) and that the tree contains none.  A pattern broken by an escaping
// slip fails the first half instead of passing the second for free.
const FORBIDDEN = [
  ['outerHTML assignment', /\.outerHTML\s*=/, 'el.outerHTML = x'],
  ['insertAdjacentHTML', /insertAdjacentHTML/, "el.insertAdjacentHTML('beforeend', x)"],
  ['document.write', /document\s*\.\s*write(ln)?\s*\(/, 'document.write(x)'],
  ['an iframe srcdoc', /srcdoc/, 'frame.srcdoc = x'],
  ['an Electron <webview>', /<webview|createElement\((cstring)?"webview"/, '<webview src="x">'],
  ['eval', /(^|[^\w.])eval\s*\(/, 'eval(userInput)'],
  ['new Function', /new Function\s*\(/, 'new Function(src)'],
  ['a string-bodied timer', /set(Timeout|Interval)\s*\(\s*["'`]/, 'setTimeout("alert(1)", 0)'],
  ["karax's verbatim", /\bverbatim\s*\(/, 'verbatim(html)'],
];
let forbiddenChecked = 0;
for (const [name, pattern, sample] of FORBIDDEN) {
  assert(pattern.test(sample), `the ${name} pattern matches a known instance`);
  assertEqual(shippedMatching(pattern), '', `the shipped front end never uses ${name}`);
  forbiddenChecked++;
}
assertEqual(forbiddenChecked, FORBIDDEN.length,
  `every one of the ${FORBIDDEN.length} forbidden sinks was scanned`);

// The URL-bearing sinks that DO exist, pinned to their exact population.
assertEqual(shippedMatchesAcross(/setAttribute\((cstring)?"(href|src|srcdoc|action|formaction)"[^)]*\)/g),
  'src/frontend/browsersync_serv.nim:setAttribute("src", scriptTagSrc) | '
  + 'src/frontend/subwindow.nim:setAttribute(cstring"src", cstring"./public/resources/shared/codetracer_welcome_logo.svg")',
  'exactly two URL attributes are ever set');
// One is a literal asset path.  The other re-creates a <script> during
// browser-sync hot reload with the `src` READ BACK OFF a script tag already in
// the page — it introduces no new value — and `src/Tupfile`'s rule for
// `browsersync_serv.js` is commented out, so it is not even built.
assert(/scriptTagSrc = existingScript\.getAttribute\("src"\)/.test(
  shipped.get('src/frontend/browsersync_serv.nim')),
  "and browser-sync's copies a src off an existing tag rather than minting one");
assert(/^# : frontend\/browsersync_serv\.nim/m.test(
  fs.readFileSync(path.join(REPO, 'src/Tupfile'), 'utf8')),
  'and that dev-only module has no build rule at all');
assertEqual(shippedMatchesAcross(/executeJavaScript\("[^"]*"\)/g),
  'src/frontend/index/window.nim:executeJavaScript("document.body.style.backgroundColor = \'black\';") | '
  + 'src/frontend/index/window.nim:executeJavaScript("document.body.style.backgroundColor = \'transparent\';")',
  'both executeJavaScript calls take a string literal');
assertEqual(shippedMatchesAcross(/let url = "file:\/\/" & \$?codetracerExeDir & "[^"]*"/g),
  'src/frontend/index/install.nim:let url = "file://" & $codetracerExeDir & "/subwindow.html" | '
  + 'src/frontend/index/window.nim:let url = "file://" & $codetracerExeDir & "/index.html"',
  'both loadURL targets are the install directory, not a caller-supplied URL');
assertEqual(shippedMatchesAcross(/win\.loadURL\(cstring\(url\)\)/g),
  'src/frontend/index/install.nim:win.loadURL(cstring(url)) | '
  + 'src/frontend/index/window.nim:win.loadURL(cstring(url))',
  'and those are the only two loadURL calls');

describe('S5. openExternalUrl — the contract was prose, and one arm did not read it');

// `ShellFacade.openExternalUrl`'s doc comment says implementations must refuse
// anything but http/https/mailto.  `desktop_electron` checked; `web_browser`
// handed the string to `window.open`.  Trap 4d at the level of a contract: a
// rule stated in a comment has a population of one enforcement site.
assertEqual(shippedMatching(/proc allowedExternalUrlScheme\*/),
  'src/frontend/viewmodel/platform/shell.nim',
  'the allow-list is one predicate, in the facade that declares the rule');
assertEqual(shippedMatchesAcross(/if not allowedExternalUrlScheme\(url\):/g),
  'src/frontend/viewmodel/host/desktop_electron.nim:if not allowedExternalUrlScheme(url): | '
  + 'src/frontend/viewmodel/host/web_browser.nim:if not allowedExternalUrlScheme(url): | '
  + 'src/frontend/viewmodel/platform/web_platform.nim:if not allowedExternalUrlScheme(url):',
  'and all THREE constructions that can reach an opener call it');
// Three and not two, and the third is the one that matters: `web_platform`'s
// bridge is PLUGGABLE, so a guard living only in `host/web_browser.nim` is a
// guard one bridge implementation happens to have.  The fake bridge in
// `test_platform_web.nim` proved it by accepting `javascript:` straight
// through the real one.
// The population itself: every place the field is given a body.  Three of the
// five hand the request somewhere else; the two that act on it are above.
assertEqual(shippedMatching(/openExternalUrl\*?\s*[:=]\s*proc/),
  'src/frontend/viewmodel/host/desktop_electron.nim,'
  + 'src/frontend/viewmodel/host/remote_stub.nim,'
  + 'src/frontend/viewmodel/host/web_browser.nim,'
  + 'src/frontend/viewmodel/platform/shell.nim,'
  + 'src/frontend/viewmodel/platform/web_platform.nim',
  'and the set of files that implement the field has not grown');
assertEqual(shippedMatchesAcross(/window\.open\([^)]*\)/g),
  "src/frontend/viewmodel/host/web_browser.nim:window.open(u, '_blank', 'noopener,noreferrer')",
  'there is exactly one window.open in the front end, behind that check');

// The reason all of this is code execution rather than a defaced panel.  If
// the renderer is ever hardened, this goes red and the assessment gets reread
// — which is the point of asserting it rather than asserting nothing.
assertEqual(shippedMatchesAcross(/"nodeIntegration": true/g),
  'src/frontend/index/install.nim:"nodeIntegration": true | '
  + 'src/frontend/index/window.nim:"nodeIntegration": true',
  'both BrowserWindows still run with nodeIntegration — the severity premise');

// ---------------------------------------------------------------------------

// 158 -> 160 on 2026-09-05, for the two guards added to the source scan above:
// "no generated directory survived the scan filter" and, when the tree has
// build output, "the scan must have skipped some". The number goes UP because
// the suite gained two contracts; it is raised here, in the same diff, rather
// than the reconciliation being relaxed — this check caught the edit, which is
// exactly what it is for.
const EXPECTED_ASSERTIONS = 160;
const total = passed + failed;
console.log(`\n\x1b[1m${total} assertions, ${failed} failed\x1b[0m`);
// Trap 4b again, at the top level: a silent skip anywhere above moves this.
if (total !== EXPECTED_ASSERTIONS) {
  console.log(`\x1b[31m  FAIL\x1b[0m the suite ran ${total} assertions, not ${EXPECTED_ASSERTIONS} — something was skipped or added without updating the count`);
  process.exit(1);
}
if (failed > 0) process.exit(1);
