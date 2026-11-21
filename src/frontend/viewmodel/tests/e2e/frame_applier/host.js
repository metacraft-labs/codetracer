// host.js — binds a frame_events_core build to IsoNim's frame applier.
//
// The two builds expose the same entry points: `nim js` as the global
// `feCore`, wasm32 through Emscripten's `cwrap`. Everything after the binding
// is the same code, so the browser test compares the two cores and not two
// hosts.

'use strict';

function wasmCore(M) {
  const c = (n, r, a) => M.cwrap(n, r, a || []);
  const base = c('feFrameBase', 'number');
  const len = c('feFrameLen', 'number');
  return {
    mount: c('feMount', null),
    readCrossings: c('feReadCrossings', 'number'),
    ops: c('feOps', 'number'),
    reset: c('feReset', null),
    manifest: c('feManifest', null),
    dispatch: c('feDispatch', 'number', ['number', 'string', 'string', 'string', 'number', 'number']),
    // A view into linear memory, re-read every time: growth replaces it.
    frameBytes: () => {
      const n = len();
      return n === 0 ? new Uint8Array(0) : M.HEAPU8.subarray(base(), base() + n);
    },
  };
}

// What the page itself saw of each event after the core's listeners ran:
// whether the core's preventDefault reached the real event.
globalThis.fePrevented = [];
for (const t of ['wheel', 'paste', 'submit']) {
  window.addEventListener(t, (ev) => globalThis.fePrevented.push(t + ':' + ev.defaultPrevented));
}

async function boot() {
  const arm = new URLSearchParams(location.search).get('arm');
  const core = arm === 'wasm' ? wasmCore(await globalThis.feModule()) : globalThis.feCore;
  if (!core) throw new Error('no core for arm ' + arm);
  core.manifest();
  const manifest = core.frameBytes().slice();
  core.reset();
  let applier = null;
  let applied = 0;
  const flush = () => {
    const frame = core.frameBytes();
    const written = core.ops();
    const n = frame.length ? applier.apply(frame) : 0;
    core.reset();
    if (n !== written) throw new Error('applied ' + n + ' of ' + written + ' operations');
    applied += n;
  };
  applier = globalThis.IsonimFrameApplier.createFrameApplier({
    manifest,
    mount: document.getElementById('mount'),
    dispatch: (id, type, value, key, deltaY, mods) => {
      const flags = core.dispatch(id, type, value, key, deltaY, mods);
      flush();
      return flags;
    },
  });
  core.mount();
  flush();
  globalThis.feState = () => ({ readCrossings: core.readCrossings(), applied, arm });
  globalThis.feReady = true;
}

boot().catch((e) => { globalThis.feError = String(e && e.stack || e); });
