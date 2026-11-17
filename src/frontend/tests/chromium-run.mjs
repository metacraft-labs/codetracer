// chromium-run.mjs — run a Nim suite compiled for the BROWSER target
// (`nim js`, no `-d:nodejs`) inside a real page in headless Chromium, and
// deliver the keys it asks for through Chromium's own input pipeline.
//
// The `renderer-chromium` lane's runner (ci/lib/run-nim-test-lane.sh, backend
// `js-chromium`). It exists for suites whose claim is about what a BROWSER
// does — a real document, real focus, trusted keyboard events — which
// `jsdom-run.mjs` cannot make: jsdom is a DOM, not a browser, and it has no
// input pipeline, no top layer and no `showModal()`.
//
// WHAT THE PAGE GETS
//
//   window.ctPress(selector, key)  -> Promise
//       Focus the element `selector` names (skipped when `selector` is empty:
//       the key then goes to whatever holds focus), then press `key` with
//       Playwright's `keyboard.press`, which Chromium receives as a TRUSTED
//       key event — `isTrusted` is true, and the browser's default actions
//       run unless a handler prevents them. That is the whole difference from
//       a suite dispatching `new KeyboardEvent(...)` at an element itself.
//       Focus is taken with `element.focus()`, the same call a reader's click
//       or Tab ends in; an element the browser will not focus (inert, hidden,
//       disabled) keeps focus where it was, which is what a suite asserting
//       exclusivity needs.
//   window.ctClick(selector, button = "left") -> Promise
//       Click through Chromium's pointer input ("right" opens context menus).
//   window.ctMouse(kind, x, y, button, clickCount) -> Promise
//       A trusted press / move / release / click / wheel at page coordinates.
//   window.ctKey('down' | 'up', key) -> Promise
//       Hold or release a key (a modifier around a click).
//   window.ctIme(composing, commit) -> Promise
//       An input method's composition (`Input.imeSetComposition`) and its
//       commit (`Input.insertText`), as Chromium delivers an IME's text.
//   window.ctAxTree() -> Promise<string>
//       The accessibility tree (role, name, value, focused) as JSON.
//   window.ctLspStart(command, args, filesJson) / ctLspRequest(method, json) /
//   ctLspNotify(method, json)
//       A real language server over stdio, for the editors' language
//       features (requests answer JSON).
//   window.ctForcedColors(on) -> Promise
//       Emulate `forced-colors: active` (a high-contrast theme).
//   window.ctFinish(exitCode)
//       The suite is done. The runner exits with the larger of this code and
//       its own verdict (a page error, or a `[FAILED]` line, is a failure).
//   window.ctDeviceScale(scale) -> Promise
//       Change Chromium's real device scale through CDP while retaining the
//       CSS viewport. Resolution media queries and layout remain browser-owned.
//
// The suite's `echo` output arrives as console messages and is printed
// verbatim, so the lane runner counts `[OK]` / `[FAILED]` / `CHECKS:` lines
// exactly as it does for every other backend.
//
// NEEDS `node_modules/playwright` and Playwright's Chromium, both of which the
// dev shell provides (`PLAYWRIGHT_BROWSERS_PATH`). It fails, exit 2, rather
// than skipping when either is missing.
//
// Usage: node src/frontend/tests/chromium-run.mjs <compiled-suite.js>
import path from 'node:path';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../../..');

const suite = process.argv[2];
if (!suite || !fs.existsSync(suite)) {
  console.error(`chromium-run.mjs: needs the compiled suite as argv[2]; got ${suite}`);
  process.exit(2);
}

let chromium;
try {
  ({ chromium } = require(path.join(REPO, 'node_modules/playwright')));
} catch (e) {
  console.error('chromium-run.mjs: node_modules/playwright is absent — run inside the dev ' +
    `shell, which links it (${e.message})`);
  process.exit(2);
}

const timeoutMs = Number(process.env.CT_CHROMIUM_SUITE_TIMEOUT_MS || 180000);

let browser;
try {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined,
  });
} catch (e) {
  console.error('chromium-run.mjs: could not launch Playwright\'s Chromium — the dev shell ' +
    `sets PLAYWRIGHT_BROWSERS_PATH to it (${String(e.message).split('\n')[0]})`);
  process.exit(2);
}

let verdict = 0;
let lsp = null;  // a language server a suite started (`ctLspStart`)
let sawFailedLine = false;
try {
  const page = await browser.newPage();
  page.on('console', (msg) => {
    const text = msg.text();
    if (text.includes('[FAILED]')) sawFailedLine = true;
    console.log(text);
  });
  page.on('pageerror', (err) => {
    console.log(`  [FAILED] uncaught page error: ${String(err).split('\n')[0]}`);
    // The first frames of the stack: where it was thrown is what a reader
    // needs, and a Nim defect's message alone is often just its type.
    for (const line of String(err.stack || '').split('\n').slice(1, 9)) console.log(`    ${line}`);
    sawFailedLine = true;
  });

  let finish;
  const finished = new Promise((resolve) => { finish = resolve; });
  await page.exposeFunction('ctFinish', (code) => finish(Number(code) || 0));
  // `keyboard.press` knows only the keys of a US layout; a combining mark or
  // an emoji is an "Unknown key". Those go through the DevTools protocol's
  // `Input.dispatchKeyEvent` — the call `keyboard.press` itself makes — with
  // the character as both `key` and `text`, so Chromium still receives a
  // trusted key event through its input pipeline.
  const cdp = await page.context().newCDPSession(page);
  await page.exposeFunction('ctDeviceScale', async (deviceScaleFactor) => {
    const viewport = await page.evaluate(() => ({ width: innerWidth, height: innerHeight }));
    const reducedMotion = await page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches);
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      ...viewport, deviceScaleFactor, mobile: false,
    });
    // A DPR-only metrics override changes devicePixelRatio and resolution
    // matches, but this Chromium does not deliver their change events until
    // a media invalidation. Toggle a genuine browser media feature and restore
    // its prior value: Chromium reevaluates and delivers the real resolution
    // notifications without any CSS resize or synthetic event.
    try {
      await cdp.send('Emulation.setEmulatedMedia', { features: [{
        name: 'prefers-reduced-motion', value: reducedMotion ? 'no-preference' : 'reduce',
      }] });
    } finally {
      await cdp.send('Emulation.setEmulatedMedia', { features: [{
        name: 'prefers-reduced-motion', value: reducedMotion ? 'reduce' : 'no-preference',
      }] });
    }
    await page.waitForFunction((scale) => devicePixelRatio === scale, deviceScaleFactor);
  });
  await page.exposeFunction('ctPress', async (selector, key) => {
    if (selector) {
      await page.evaluate((sel) => {
        const el = document.querySelector(sel);
        if (el) el.focus();
      }, selector);
    }
    const chars = [...key];
    if (chars.length === 1 && key.codePointAt(0) > 0x7e) {
      await cdp.send('Input.dispatchKeyEvent',
        { type: 'keyDown', key, text: key, unmodifiedText: key });
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key });
    } else {
      await page.keyboard.press(key);
    }
  });

  // Real pointer input, including native contextmenu events on a right click.
  await page.exposeFunction('ctClick', async (selector, button = 'left') => {
    await page.locator(selector).click({ button });
  });

  // Pointer input at page coordinates: a press, a move with the button held
  // and a release, each a trusted mouse event; `clickCount` is the browser's
  // `detail` (2 and 3 for a double and a triple click).
  await page.exposeFunction('ctMouse', async (kind, x, y, button = 'left', clickCount = 1) => {
    if (kind === 'move') await page.mouse.move(x, y);
    else if (kind === 'down') { await page.mouse.move(x, y); await page.mouse.down({ button, clickCount }); }
    else if (kind === 'up') await page.mouse.up({ button, clickCount });
    else if (kind === 'click') await page.mouse.click(x, y, { button, clickCount });
    else if (kind === 'wheel') await page.mouse.wheel(x, y);
  });
  // A key held or released (a modifier around a click).
  await page.exposeFunction('ctKey', async (kind, key) => {
    if (kind === 'down') await page.keyboard.down(key);
    else await page.keyboard.up(key);
  });
  // Text an input method produces, through the DevTools protocol's own IME
  // entry points: `Input.imeSetComposition` (Chromium dispatches
  // compositionstart / compositionupdate to the focused element) and
  // `Input.insertText` (the commit: compositionend and the input). `commit`
  // empty only composes.
  await page.exposeFunction('ctIme', async (composing, commit) => {
    if (composing) {
      await cdp.send('Input.imeSetComposition',
        { text: composing, selectionStart: composing.length, selectionEnd: composing.length });
    }
    if (commit) await cdp.send('Input.insertText', { text: commit });
  });
  // The accessibility tree as a screen reader reads it: every node's role,
  // name and value (`Accessibility.getFullAXTree`), with the focused flag.
  await page.exposeFunction('ctAxTree', async () => {
    const { nodes } = await cdp.send('Accessibility.getFullAXTree');
    return JSON.stringify(nodes.filter((n) => !n.ignored).map((n) => {
      const prop = (name) => {
        const p = (n.properties || []).find((q) => q.name === name);
        return p ? p.value.value : undefined;
      };
      return {
        role: n.role && n.role.value, name: n.name && n.name.value,
        value: n.value && n.value.value, focused: prop('focused') === true,
        multiline: prop('multiline') === true, readonly: prop('readonly') === true,
      };
    }));
  });
  // A real language server over stdio (JSON-RPC with LSP framing), for the
  // suites that grade an editor's language features against one: start it,
  // send requests and notifications, read the responses. `ctLspStart`
  // answers the server's `initialize` result (JSON).
  await page.exposeFunction('ctLspStart', async (command, args, filesJson) => {
    const { spawn } = await import('node:child_process');
    const os = await import('node:os');
    // The project goes in a fresh directory OUTSIDE this checkout: a server
    // walks up from a file for its configuration, and nimsuggest evaluating
    // this repository's `config.nims` dies (IndexDefect, measured
    // 2026-11-12) before it answers anything.
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ct-lsp-'));
    const files = JSON.parse(filesJson);
    for (const [name, text] of Object.entries(files)) {
      fs.writeFileSync(path.join(root, name), text);
    }
    const rootUri = 'file://' + root;
    // stderr drained (a server logs there freely, and an unread pipe fills
    // and stalls it); kept in a file when CT_LSP_STDERR names one.
    const proc = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'] });
    const errLog = process.env.CT_LSP_STDERR ? fs.createWriteStream(process.env.CT_LSP_STDERR) : null;
    proc.stderr.on('data', (d) => { if (errLog) errLog.write(d); });
    let buffer = Buffer.alloc(0);
    const pending = new Map();
    let nextId = 1;
    proc.stdout.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      for (;;) {
        const sep = buffer.indexOf('\r\n\r\n');
        if (sep < 0) break;
        const header = buffer.slice(0, sep).toString('ascii');
        const m = /Content-Length: (\d+)/i.exec(header);
        if (!m) { buffer = buffer.slice(sep + 4); continue; }
        const len = Number(m[1]);
        if (buffer.length < sep + 4 + len) break;
        const body = JSON.parse(buffer.slice(sep + 4, sep + 4 + len).toString('utf8'));
        buffer = buffer.slice(sep + 4 + len);
        if (body.id !== undefined && pending.has(body.id) && body.method === undefined) {
          const { resolve } = pending.get(body.id);
          pending.delete(body.id);
          resolve(body.error ? { __error: body.error } : body.result);
        } else if (body.id !== undefined && body.method !== undefined) {
          // A request from the server (workspace/configuration, …): answered empty.
          send({ jsonrpc: '2.0', id: body.id, result: null });
        }
      }
    });
    function send(msg) {
      const json = Buffer.from(JSON.stringify(msg), 'utf8');
      proc.stdin.write(`Content-Length: ${json.length}\r\n\r\n`);
      proc.stdin.write(json);
    }
    lsp = {
      proc, send,
      request(method, params) {
        const id = nextId++;
        return new Promise((resolve) => {
          pending.set(id, { resolve });
          send({ jsonrpc: '2.0', id, method, params });
        });
      },
      notify(method, params) { send({ jsonrpc: '2.0', method, params }); },
    };
    const init = await lsp.request('initialize', {
      processId: process.pid, rootUri, capabilities: {
        textDocument: { hover: { contentFormat: ['plaintext', 'markdown'] },
          completion: { completionItem: { snippetSupport: false } },
          semanticTokens: { requests: { range: true, full: true },
            tokenTypes: [], tokenModifiers: [], formats: ['relative'] } } },
      workspaceFolders: [{ uri: rootUri, name: 'root' }],
    });
    lsp.notify('initialized', {});
    lsp.root = root;
    return JSON.stringify({ root, init });
  });
  await page.exposeFunction('ctLspRequest', async (method, paramsJson) => {
    if (!lsp) return JSON.stringify({ __error: 'no language server' });
    const r = await lsp.request(method, JSON.parse(paramsJson));
    return JSON.stringify(r === undefined ? null : r);
  });
  await page.exposeFunction('ctLspNotify', async (method, paramsJson) => {
    if (lsp) lsp.notify(method, JSON.parse(paramsJson));
  });
  // A forced-colours (Windows high contrast) emulation, as the media feature
  // a stylesheet reads.
  await page.exposeFunction('ctForcedColors', async (on) => {
    await cdp.send('Emulation.setEmulatedMedia',
      { features: [{ name: 'forced-colors', value: on ? 'active' : 'none' }] });
  });

  // A run of some of a suite's cases (a mutation harness grading one arm):
  // `CT_CHROMIUM_ONLY` names them, comma-separated; a suite that supports it
  // reads `window.ctOnly` and skips its tally.
  await page.setContent('<!DOCTYPE html><html><head><meta charset="utf-8"></head>' +
    '<body></body></html>');
  await page.evaluate((only) => { window.ctOnly = only; },
    process.env.CT_CHROMIUM_ONLY || '');
  await page.addScriptTag({ path: path.resolve(suite) });

  const timedOut = new Promise((resolve) =>
    setTimeout(() => resolve('timeout'), timeoutMs));
  const code = await Promise.race([finished, timedOut]);
  if (code === 'timeout') {
    console.log(`  [FAILED] the suite did not call ctFinish within ${timeoutMs} ms`);
    verdict = 1;
  } else {
    verdict = code;
  }
} finally {
  await browser.close();
  if (lsp && lsp.proc) lsp.proc.kill();
  if (lsp && lsp.root) fs.rmSync(lsp.root, { recursive: true, force: true });
}
if (sawFailedLine && verdict === 0) verdict = 1;
process.exit(verdict);
