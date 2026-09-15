// main.js — Electron main process for PLAT-18's vertical slice.
//
// Loads `page.html` in a renderer, waits for the three arms to register, runs
// the driver, and relays every `PLAT18-…` line the renderer prints to this
// process's stdout so the shell script that owns the run can grade it.
//
// A renderer's `console.log` does NOT reach the parent's stdout on its own —
// it goes to the Chromium devtools console, which nothing here is reading. So
// `console-message` is forwarded explicitly. The first version of this file
// left that out and reported a clean, silent, entirely empty run.

'use strict';

const { app, BrowserWindow } = require('electron');
const path = require('path');

app.disableHardwareAcceleration();
app.commandLine.appendSwitch('no-sandbox');

let failed = false;

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    show: false,
    width: 1200,
    height: 900,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: false,
      // The wasm glue fetches its own `.wasm` beside the page, so the page is
      // loaded from `file://` and web security has to allow that fetch. This
      // is a measurement harness on a local file, not a browsing context.
      webSecurity: false,
    },
  });

  // EVERY line is forwarded, not only the `PLAT18-` ones. A harness that
  // filters the renderer's console keeps exactly the lines it already knows
  // about and discards the one diagnostic that would explain a failure —
  // which is how `ci/lib/run-nim-test-lane.sh` came to separate compile from
  // run, for the same reason. Results go to stdout; everything else to
  // stderr, so the grader's `grep` is still unambiguous.
  win.webContents.on('console-message', (_e, _level, message) => {
    if (message.startsWith('PLAT18-')) console.log(message);
    else console.error('renderer: ' + message);
  });
  win.webContents.on('render-process-gone', (_e, details) => {
    console.log('PLAT18-SLICE-VERDICT FAIL renderer gone: ' + JSON.stringify(details));
    failed = true;
    app.exit(1);
  });

  await win.loadFile(path.join(__dirname, 'page.html'));

  try {
    // The wasm module is fetched and instantiated asynchronously, so the page
    // cannot have all three arms at load time. COLD START IS MEASURED HERE,
    // around exactly that: `loadP18Wasm()` covers fetch, compile, instantiate
    // and the module's own `main` (which runs Nim's module initialisers).
    const result = await win.webContents.executeJavaScript(`
      (async () => {
        const t0 = performance.now();
        await globalThis.loadP18Wasm();
        const wasmReadyMs = performance.now() - t0;
        console.log('PLAT18-SLICE-COLDSTART wasm_instantiate_ms=' + wasmReadyMs.toFixed(3));
        return globalThis.ctP18Run();
      })()
    `);
    // COLD START — §4 metric 1, §5's first criterion and the one the user
    // named as the veto. One arm per renderer, because a cold start is a
    // property of a process's first moments and the page above is warm.
    for (const arm of [
      { name: 'js-direct', src: 'arm_js_direct.js', wasm: 0 },
      { name: 'js-crossing', src: 'arm_js_crossing.js', wasm: 0 },
      { name: 'wasm-crossing', src: 'arm_wasm.js', wasm: 1 },
    ]) {
      const w = new BrowserWindow({
        show: false, width: 800, height: 600,
        webPreferences: { nodeIntegration: false, contextIsolation: false, webSecurity: false },
      });
      w.webContents.on('console-message', (_e, _l, m) => {
        if (m.startsWith('PLAT18-')) console.log(m);
        else console.error('coldstart(' + arm.name + '): ' + m);
      });
      await w.loadFile(path.join(__dirname, 'coldstart.html'), {
        search: `arm=${arm.name}&src=${arm.src}&wasm=${arm.wasm}`,
      });
      await w.webContents.executeJavaScript('globalThis.ctP18ColdStart()');

      // The renderer is now holding the 602-row pane. `getAppMetrics` is
      // Electron's own per-process accounting, taken from the MAIN process, so
      // it is a measurement of the address space rather than of a JS-visible
      // counter the engine is free to coarsen.
      const pid = w.webContents.getOSProcessId();
      const metric = app.getAppMetrics().find((x) => x.pid === pid);
      if (metric && metric.memory) {
        console.log('PLAT18-SLICE-RSS arm=' + arm.name +
                    ' working_set_kb=' + metric.memory.workingSetSize +
                    ' peak_working_set_kb=' + (metric.memory.peakWorkingSetSize || 0));
      } else {
        console.log('PLAT18-SLICE-RSS arm=' + arm.name + ' UNAVAILABLE');
      }
      w.destroy();
    }

    console.log('PLAT18-SLICE-VERDICT ' + (result === 'ok' ? 'ok' : 'FAIL ' + result));
  } catch (err) {
    console.log('PLAT18-SLICE-VERDICT FAIL ' + (err && err.message ? err.message : String(err)));
    failed = true;
  }
  app.exit(failed ? 1 : 0);
});
