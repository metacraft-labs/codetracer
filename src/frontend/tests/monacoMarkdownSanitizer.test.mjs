/**
 * Does attacker-supplied trace content reach the vulnerable DOMPurify?
 *
 * `monaco-editor@0.54.0` pins `dompurify@3.1.7` exactly, and that copy is in
 * the shipped browser bundle: `src/frontend/frontend_imports.js` does
 * `import * as monaco from 'monaco-editor'`, webpack inlines it into
 * `src/public/dist/frontend_bundle.js`, and `src/frontend/index.html` loads
 * that as its first script.  DOMPurify 3.1.7 predates the 3.2.4 fix for the
 * namespace-confusion mutation-XSS class, so the dependency scanners flag it.
 *
 * CodeTracer renders untrusted trace content — variable values, string
 * contents, file paths, program output — so "a vulnerable sanitizer is in the
 * bundle" is not by itself an answer.  The question is whether any of that
 * content can reach `DOMPurify.sanitize` *as markup*.  It cannot, and this
 * file is the reason it stays that way.
 *
 * WHY IT IS SAFE.  Monaco only ever sanitizes the output of `marked`, and
 * `renderMarkdown` installs an HTML-token renderer that DELETES raw HTML
 * before sanitization whenever the markdown string does not carry
 * `supportHtml` (monaco-editor/esm/vs/base/browser/markdownRenderer.js, the
 * `if (!markdown.supportHtml)` branch).  So DOMPurify's input is markup
 * `marked` generated — `<p>`, `<code>`, `<a>`, `<strong>` — never markup an
 * attacker wrote.  The mutation-XSS payloads all need `<math>` / `<form>` /
 * `<mglyph>` / `<style>` / `<template>` / `<noscript>` to survive to the
 * sanitizer, and none of them can.
 *
 * WHAT KEEPS IT SAFE.  Two properties, both asserted below:
 *
 *   1. Nothing in CodeTracer sets `supportHtml` on a markdown string.  The
 *      only `IMarkdownString` the product builds at all is the column
 *      breakpoint tooltip in `ui/editor.nim`, whose value is two integers in
 *      a constant sentence.
 *   2. With `supportHtml` unset, hostile markup does not reach DOMPurify —
 *      and with it set, it does.  The second half is the control: it is the
 *      arm that goes red if the interception below ever stops observing the
 *      real call, so the first half can never pass vacuously.
 *
 * If a future change needs HTML in a hover, THAT is the change that makes
 * these advisories exploitable, and arm M below is what will say so.
 *
 * Run: node --experimental-loader ./src/frontend/tests/css-loader.mjs \
 *        src/frontend/tests/monacoMarkdownSanitizer.test.mjs
 */

import './monaco-env.mjs';

import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../../..');
const MONACO_BROWSER = path.join(
  REPO, 'node_modules/monaco-editor/esm/vs/base/browser');

// `dompurify.js` exports the purify *instance* as its default export, and
// `domSanitize.js` calls `dompurify.sanitize(...)` on that same object — a
// plain property on a shared module singleton, so the call is observable from
// here without touching Monaco's source.  (An ESM named export would not be.)
const dompurify = (await import(path.join(MONACO_BROWSER, 'dompurify/dompurify.js'))).default;
const { renderMarkdown } = await import(path.join(MONACO_BROWSER, 'markdownRenderer.js'));

// ---------------------------------------------------------------------------
// Test framework (same shape as the sibling `nim*.test.mjs` files)
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

// ---------------------------------------------------------------------------
// The interception
// ---------------------------------------------------------------------------

/** Every string handed to `DOMPurify.sanitize` since the last `render`. */
let sanitizerInputs = [];
const realSanitize = dompurify.sanitize;
dompurify.sanitize = function (dirty, config) {
  sanitizerInputs.push(String(dirty));
  return realSanitize.call(this, dirty, config);
};

/**
 * Render one markdown string the way Monaco renders every hover, completion
 * detail and signature-help doc, and report both what the sanitizer saw and
 * what landed in the DOM.
 */
function render(markdown) {
  sanitizerInputs = [];
  const element = renderMarkdown(markdown).element;
  return { toSanitizer: sanitizerInputs.slice(), html: element.innerHTML, element };
}

/**
 * The tags every published DOMPurify mutation-XSS needs in the sanitizer's
 * INPUT.  `marked` emits none of them, so their absence from `toSanitizer` is
 * the property under test.
 */
const MXSS_TAGS = [
  'math', 'mtext', 'mglyph', 'annotation-xml',
  'form', 'style', 'template', 'noscript',
  'svg', 'script', 'iframe', 'img',
];

function hostileTagsIn(html) {
  const lowered = html.toLowerCase();
  return MXSS_TAGS.filter((tag) => lowered.includes(`<${tag}`));
}

// ---------------------------------------------------------------------------
// The corpus: trace-shaped inputs, i.e. things a recorded program can put in
// a variable, a path or its own output.
// ---------------------------------------------------------------------------

const HOSTILE = {
  'a Rust Debug value carrying markup':
    'Foo { name: "<img src=x onerror=alert(1)>" }',
  'a source path carrying markup':
    '/tmp/<svg onload=alert(1)>/main.rs',
  'CVE-2025-26791 (form/math/mglyph/style), the 3.2.4 fix':
    '<form><math><mtext></form><form><mglyph><style></math><img src onerror=alert(1)>',
  'the table/mglyph namespace-confusion variant':
    '<math><mtext><table><mglyph><style><!--</style><img src onerror=alert(1)>',
  'the noscript/style variant':
    '<noscript><style></noscript><img src=x onerror=alert(1)>',
  'a template-wrapped script':
    '<template><script>alert(1)</script></template>',
  'program output that is itself HTML':
    'stdout: served <div id="root"><style>@import"x"</style></div>',
};
const HOSTILE_COUNT = 7;

// ---------------------------------------------------------------------------

console.log('\x1b[1mMonaco markdown sanitizer — trace content reachability\x1b[0m');

describe('C. Controls — the thing under test is present and observed');

// If this moves, the whole triage above was done against a different library
// and every assertion below describes a version nobody is shipping.
assertEqual(dompurify.version, '3.1.7',
  'monaco-editor ships the DOMPurify version this file was written against');

// The bundle claim: the module just imported is the module webpack inlines.
const frontendImports = fs.readFileSync(
  path.join(REPO, 'src/frontend/frontend_imports.js'), 'utf8');
assert(/^import \* as monaco from 'monaco-editor';$/m.test(frontendImports),
  "the shipped bundle's entry imports the monaco-editor package tested here");

const indexHtml = fs.readFileSync(path.join(REPO, 'src/frontend/index.html'), 'utf8');
assert(indexHtml.includes('public/dist/frontend_bundle.js'),
  'index.html loads that bundle');

// Positive control on the interception.  Every negative assertion below is of
// the form "the sanitizer never saw X"; on a broken interception that is true
// for free.  This is the paired positive: benign markdown MUST reach
// DOMPurify, exactly once, carrying marked's own markup.
{
  const benign = render({ value: 'hello **world**' });
  assertEqual(benign.toSanitizer.length, 1,
    'benign markdown reaches DOMPurify exactly once (interception is live)');
  assertEqual(benign.toSanitizer[0], '<p>hello <strong>world</strong></p>',
    'and what it receives is the markup marked generated');
  assertEqual(benign.html, '<p>hello <strong>world</strong></p>',
    'which survives sanitization unchanged');
}

describe(`A. With CodeTracer's flags — ${HOSTILE_COUNT} hostile trace values`);

let checkedSafe = 0;
for (const [name, value] of Object.entries(HOSTILE)) {
  // No `supportHtml`, no `isTrusted` — exactly how every markdown string in
  // this product is built.
  const r = render({ value });
  checkedSafe++;

  assertEqual(r.toSanitizer.length, 1,
    `${name}: reaches DOMPurify exactly once`);
  assertEqual(hostileTagsIn(r.toSanitizer.join('')).join(','), '',
    `${name}: no mutation-XSS tag reaches DOMPurify at all`);
  assertEqual(r.element.querySelectorAll(
    'img,svg,math,form,style,script,iframe,template,noscript').length, 0,
    `${name}: renders no element that could carry a payload`);
  assert(!/\son[a-z]+\s*=/i.test(r.html),
    `${name}: renders no event-handler attribute`);
}
// Trap 4b: the corpus size is knowable, so assert the count, not "at least one".
assertEqual(checkedSafe, HOSTILE_COUNT,
  'every hostile value in the corpus was rendered (no silent skip)');

describe('M. Mutation arm — the flag that would make these advisories exploitable');

// The twin of arm A, through the same interception and the same corpus.  If
// the interception ever stops observing the real `sanitize`, arm A goes green
// for the wrong reason and THIS goes red immediately.
let checkedReaches = 0;
for (const [name, value] of Object.entries(HOSTILE)) {
  const r = render({ value, supportHtml: true });
  checkedReaches++;

  assertEqual(r.toSanitizer.length, 1,
    `${name} (supportHtml): reaches DOMPurify exactly once`);
  assert(hostileTagsIn(r.toSanitizer.join('')).length > 0,
    `${name} (supportHtml): the payload DOES reach DOMPurify — so arm A is not vacuous`);
}
assertEqual(checkedReaches, HOSTILE_COUNT,
  'every hostile value was also rendered with supportHtml (no silent skip)');

describe('S. Source scan — nothing in CodeTracer sets that flag');

const SCAN_EXTENSIONS = new Set(['.nim', '.js', '.mjs', '.ts']);
const SCAN_ROOT = path.join(REPO, 'src');
const SELF = path.relative(REPO, fileURLToPath(import.meta.url));

// BUILD OUTPUT IS NOT SOURCE. `src/build-*/` and any `dist/` are produced by
// `just build-once` and are git-ignored (`.gitignore` carries `build-*/` and
// `dist/`). They contain `frontend_bundle.js` and the vendored Monaco chunks —
// i.e. Monaco's OWN definitions of `supportHtml`, `isTrusted` and
// `MarkdownString`, bundled. Scanning them makes this suite report Monaco's
// source as though CodeTracer had written it.
//
// Without this exclusion the suite passes only on a tree that has NEVER been
// built and fails on every tree that has — including the one produced by the
// `just build-once` that both CI and AGENTS.md tell you to run first. The
// verdict therefore tracked whether a build had happened, not whether any
// CodeTracer source sets the flag, which is the one thing it exists to answer.
const isGeneratedDir = (name) =>
  name === 'node_modules' || name === 'dist' || name.startsWith('build-');

/** Files in `src/` this scan actually read, as repo-relative paths. */
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
    if (rel === SELF) continue;  // this file names the flag on purpose
    scanned.push(rel);
  }
})(SCAN_ROOT);

// Trap 4: assert the scan reached the tree before asserting what is not in it.
// A moved directory, a renamed extension or a bad join all read as "clean".
console.log(`  \x1b[2mfiles scanned: ${scanned.length}\x1b[0m`);
assert(scanned.length >= 900,
  `the scan reached the source tree (${scanned.length} files)`);

// Trap 4b: the exclusion above must not become a way to scan nothing, and must
// not silently stop excluding. Both directions are asserted, and the second is
// asserted only when there IS build output to exclude — so this stays honest on
// a clean checkout as well as on a built one.
assert(!scanned.some((rel) => rel.split(path.sep).some(isGeneratedDir)),
  'no generated directory survived the scan filter');

// One unconditional assertion, not an `if` around one, so the number of
// assertions this file runs does not depend on whether the tree has been
// built. (`htmlSinks.test.mjs` reconciles its total and would fail outright;
// keeping both files the same shape avoids planting that trap here later.)
const builtDirs = ['src/build-debug', 'src/public/dist']
  .filter((rel) => fs.existsSync(path.join(REPO, rel)));
console.log(`  \x1b[2mbuild output present: ${builtDirs.length > 0 ? builtDirs.join(', ') : '(none)'}; generated dirs skipped: ${skippedGenerated.length}\x1b[0m`);
assert(builtDirs.length === 0 || skippedGenerated.length > 0,
  builtDirs.length === 0
    ? 'no build output in this tree, so there was nothing for the scan to skip'
    : `this tree HAS build output, so the scan must have skipped some (skipped ${skippedGenerated.length})`);

const sources = new Map(scanned.map((rel) => [rel, fs.readFileSync(path.join(REPO, rel), 'utf8')]));

function filesMatching(pattern) {
  return [...sources.entries()].filter(([, text]) => pattern.test(text)).map(([rel]) => rel);
}

// The paired POSITIVE: the scan must find the one markdown string this
// product does build.  If this list is ever empty the negatives below are
// meaningless, whatever caused it.
assertEqual(filesMatching(/hoverMessage\s*:/).join(','), 'src/frontend/ui/editor.nim',
  'the scan finds the single IMarkdownString CodeTracer builds');

const editorNim = sources.get('src/frontend/ui/editor.nim');
assert(/hoverMessage:\s*js\{value:\s*hoverText\}/.test(editorNim),
  'that tooltip renders a local `hoverText`, not a caller-supplied string');
assert(/let hoverText = cstring\("Column breakpoint at line " & \$line &\s*\n?\s*", column " & \$b\.column\)/.test(editorNim),
  'and `hoverText` is a constant sentence around two integers — no trace content');

// The other channel into that renderer, and the only one carrying content
// derived from the recorded program's own source: an LSP server's hover,
// completion detail and signature-help docs, bridged in by
// monaco-languageclient.  `vscode-languageclient` defaults its markdown
// options to `{ isTrusted: false, supportHtml: false }` and raises the flag
// only when `clientOptions.markdown.supportHtml === true`
// (node_modules/vscode-languageclient/lib/common/client.js).  So the property
// is "CodeTracer never puts a `markdown` key on its client options" — and the
// positive control is that the scan still finds the file that builds them.
assertEqual(filesMatching(/setField\(clientOptions,/).join(','),
  'src/frontend/lsp_controller.nim',
  'the scan finds the file that builds the LSP client options');
assert(!/setField\(clientOptions,\s*"markdown"/.test(sources.get('src/frontend/lsp_controller.nim')),
  'and those options carry no markdown block, so the LSP path keeps the defaults');

// The negatives, each now backed by a scan proven to be reading the tree.
assertEqual(filesMatching(/supportHtml/).join(','), '',
  'no CodeTracer source sets supportHtml on a markdown string');
assertEqual(filesMatching(/(^|[^.\w])isTrusted\s*:/m).join(','), '',
  'no CodeTracer source sets isTrusted on a markdown string');
assertEqual(filesMatching(/\bMarkdownString\b/).join(','), '',
  'no CodeTracer source constructs a MarkdownString directly');
assertEqual(filesMatching(/glyphMarginHoverMessage/).join(','), '',
  'no CodeTracer source builds a glyph-margin markdown tooltip');

// ---------------------------------------------------------------------------

console.log(`\n\x1b[1m${passed + failed} assertions, ${failed} failed\x1b[0m`);
if (failed > 0) process.exit(1);
