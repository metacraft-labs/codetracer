// The gesture, driven in a real browser: edit, save, RELOAD, read it back.
//
// Emits one JSON document on stdout. `ci/test/noir-edit-persists.sh` asserts
// against it; nothing here decides pass or fail, so an arm cannot be green
// because the probe was lenient.
//
// WHY A RELOAD AND NOT A ROUND TRIP. A same-page check — write, read back,
// compare — is satisfied by a variable. The claim under test is that the work
// is in ORIGIN STORAGE, and the only way to observe that is to destroy every
// piece of JavaScript state that could be holding it. `page.reload()` does
// exactly that and keeps the origin, so OPFS is the only channel by which a
// byte can cross.
//
// AND WHY A SECOND, FRESH CONTEXT. "The marker is present after a reload"
// would also be true of a bundle that happened to contain the marker. The
// `fresh` arm opens a brand-new browser context — a new origin storage
// partition, same bytes — and requires the marker to be ABSENT there. Together
// the two say: it came from storage, not from the bundle.

import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const bundle = process.argv[2];
const MARKER = process.argv[3] || 'EDIT_PERSISTS_MARKER';

const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.wasm': 'application/wasm', '.json': 'application/json',
  '.map': 'application/json', '.ttf': 'font/ttf', '.woff': 'font/woff',
  '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png',
};

const server = http.createServer((req, res) => {
  const p = decodeURIComponent(req.url.split('?')[0]);
  let f = path.join(bundle, p);
  // The deployment serves the entry document for every route it owns; this is
  // the 200-rewrite `renderRewriteConfig` emits, which is what makes `/noir`
  // reach the renderer with its path intact.
  if (!fs.existsSync(f) || fs.statSync(f).isDirectory()) {
    f = path.join(bundle, 'index.html');
  }
  res.writeHead(200, {
    'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream',
  });
  fs.createReadStream(f).pipe(res);
});

await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/noir`;

const out = {
  mounted: false, mountedAfterReload: false,
  bannerText: '', bannerPainted: false, bannerPaintedChars: 0,
  markerBeforeReload: false, markerAfterReload: false,
  editedContent: '', restoredContent: '', bundledContent: '',
  freshContextMarker: null,
  sawNoHostForSaveFile: false, sawSavedFile: false,
  editorModels: 0, error: '',
};

const browser = await chromium.launch();

async function waitForEditMode(page) {
  await page.waitForFunction(
    () => document.querySelectorAll('.monaco-editor').length > 0,
    null, { timeout: 60000 });
  // The mount continues after the first Monaco node exists: `onNoTrace` opens
  // the initial tab and the host answers `tab-load` a task later.
  await page.waitForFunction(
    () => !!window.monaco &&
      window.monaco.editor.getModels().some((m) => m.getValue().length > 0),
    null, { timeout: 60000 });
  await page.waitForTimeout(1200);
}

// `paintedText`, not `innerText`. The instrument failure this codebase records:
// 379 characters of diagnostic were counted by `innerText`, laid out in the
// page, and visible to nobody because another element painted over them. So the
// banner is hit-tested at its own centre and must BE the element found there.
async function bannerPainted(page) {
  return await page.evaluate(() => {
    const el = document.getElementById('codetracer-durability');
    if (!el) return { painted: false, chars: 0, text: '' };
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return { painted: false, chars: 0, text: el.textContent || '' };
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    if (cx < 0 || cy < 0 || cx > innerWidth || cy > innerHeight) {
      return { painted: false, chars: 0, text: el.textContent || '' };
    }
    const hit = document.elementFromPoint(cx, cy);
    const isSelf = !!hit && (hit === el || el.contains(hit) || hit.contains(el));
    const style = getComputedStyle(el);
    const visible = style.visibility !== 'hidden' && style.display !== 'none' &&
      parseFloat(style.opacity || '1') > 0.05;
    const text = el.textContent || '';
    return {
      painted: isSelf && visible && text.trim().length > 0,
      chars: text.trim().length,
      text,
    };
  });
}

try {
  // -- the session that edits ------------------------------------------------
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(m.text()));

  await page.goto(url, { waitUntil: 'load' });
  await waitForEditMode(page);
  out.mounted = true;

  const banner = await bannerPainted(page);
  out.bannerText = banner.text;
  out.bannerPainted = banner.painted;
  out.bannerPaintedChars = banner.chars;

  // THE EDIT, as keystrokes. Not `model.setValue`: that would bypass Monaco's
  // change listener, which is what marks the tab dirty and therefore what
  // `saveTargets` reads. Typing exercises the path a visitor takes.
  await page.click('.monaco-editor');
  await page.keyboard.press('Control+A');
  await page.keyboard.type(`// ${MARKER}\nfn main(x: Field, y: pub Field) {\n`);
  await page.waitForTimeout(500);

  const mainBefore = await page.evaluate(
    (mk) => {
      const m = window.monaco.editor.getModels()
        .find((x) => x.getValue().includes(mk));
      return m ? m.getValue() : '';
    }, MARKER);
  out.markerBeforeReload = mainBefore.length > 0;
  out.editedContent = mainBefore;

  // THE SAVE.
  await page.keyboard.press('Control+S');
  await page.waitForTimeout(2500);

  out.sawNoHostForSaveFile =
    logs.some((l) => l.includes('no host for CODETRACER::save-file') &&
                     !l.includes('save-file-error'));

  // THE RELOAD — every byte of JS state is destroyed here.
  await page.reload({ waitUntil: 'load' });
  await waitForEditMode(page);
  out.mountedAfterReload = true;

  // EXACT EQUALITY, not a substring. "The marker is present" would also be
  // true of a restore that dropped half the file, or that merged the bundled
  // copy back in on top. The claim is that the tab came back holding the bytes
  // it had when it was saved, so that is what is compared.
  const after = await page.evaluate((mk) => {
    const vals = window.monaco.editor.getModels().map((m) => m.getValue());
    const hit = vals.find((v) => v.includes(mk));
    return { marker: !!hit, content: hit || '', models: vals.length };
  }, MARKER);
  out.markerAfterReload = after.marker;
  out.restoredContent = after.content;
  out.editorModels = after.models;
  await ctx.close();

  // -- THE CONTROL: a fresh origin partition, the same bytes -----------------
  const fresh = await browser.newContext();
  const freshPage = await fresh.newPage();
  await freshPage.goto(url, { waitUntil: 'load' });
  await waitForEditMode(freshPage);
  const freshInfo = await freshPage.evaluate((mk) => {
    const vals = window.monaco.editor.getModels().map((v) => v.getValue());
    const nonEmpty = vals.filter((v) => v.length > 0);
    return {
      marker: vals.some((v) => v.includes(mk)),
      // The bundled bytes, read from a partition that has never been written
      // to. This is the value the restored content must NOT equal -- it is how
      // "restored from storage" is told apart from "fell back to the bundle".
      bundled: nonEmpty.length > 0 ? nonEmpty[0] : '',
    };
  }, MARKER);
  out.freshContextMarker = freshInfo.marker;
  out.bundledContent = freshInfo.bundled;
  await fresh.close();
} catch (e) {
  out.error = String(e && e.message ? e.message : e);
}

await browser.close();
server.close();
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
