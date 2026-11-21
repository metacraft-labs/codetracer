// web_core_host.js — the browser front-end's host half of `web_core.nim`.
//
// The core runs as WebAssembly (or, for comparison, as `nim js`) and cannot
// hold a DOM node or open a socket. This file gives it both:
//
//   * the document, through IsoNim's frame applier (`frame_applier.js`):
//     after every call into the core, the frame it wrote is applied and the
//     applied operation count is checked against the count the core wrote;
//   * the transport: the core's `ctwHostPost(json)` goes to `transport.send`,
//     and each message `transport` receives goes back in through
//     `ctwDeliver`.
//
// `startWebCore` returns a handle with the core's queries, `step`, and
// `node(handle)` — the DOM node behind a frame handle, for host-side
// decoration that must read layout without a crossing.
//
// ## THE LOOP
//
// The core's futures settle from `drainPlatformCallbacks`. The host drives it:
// after every message and every call, and on a timer (`pumpMs`, default 16)
// for callbacks a timer inside the core queued.

'use strict';

(function (root) {
  const PHASES = ['created', 'launching', 'ready', 'failed', 'disposed'];

  /** The wasm32 build, bound through Emscripten's cwrap. */
  function bindWasm(M) {
    const c = (n, r, a) => M.cwrap(n, r, a || []);
    const base = c('isonimFrameBase', 'number');
    const len = c('isonimFrameLen', 'number');
    return {
      boot: c('ctwBoot', null),
      pump: c('ctwPump', null),
      deliver: c('ctwDeliver', null, ['string']),
      openFolder: c('ctwOpenFolder', null, ['string']),
      phase: c('ctwPhase', 'number'),
      failure: c('ctwFailure', 'string'),
      step: c('ctwStep', null, ['number']),
      stepping: c('ctwStepping', 'number'),
      position: c('ctwPosition', 'string'),
      readCrossings: c('ctwReadCrossings', 'number'),
      setViewport: c('ctwSetViewport', null, ['number', 'number', 'number', 'number']),
      mounted: c('ctwMounted', 'number'),
      pending: c('ctwPending', 'number'),
      frameOps: c('isonimFrameOps', 'number'),
      frameReset: c('isonimFrameReset', null),
      frameManifest: c('isonimFrameManifest', null),
      dispatch: c('isonimFrameDispatch', 'number',
        ['number', 'string', 'string', 'string', 'number', 'number']),
      forget: c('isonimFrameForget', null, ['number']),
      // A view into linear memory, re-read every time: memory growth
      // replaces the buffer, and a cached view reads as an empty frame.
      frameBytes: () => {
        const n = len();
        return n === 0 ? new Uint8Array(0) : M.HEAPU8.subarray(base(), base() + n);
      },
    };
  }

  /**
   * Start a core.
   *
   *   core       the `nim js` build's `ctwJsCore`, or an Emscripten module
   *   mount      the element the panes are drawn into
   *   transport  {send(text), onMessage(cb)}
   */
  function startWebCore({ core: raw, mount, transport, pumpMs, rowPx }) {
    const core = raw && raw.cwrap ? bindWasm(raw) : raw;
    if (!core) throw new Error('web core host: no core');
    let applier = null;
    let applied = 0;
    let frames = 0;
    const flush = () => {
      const frame = core.frameBytes();
      const written = core.frameOps();
      const n = frame.length ? applier.apply(frame) : 0;
      core.frameReset();
      if (n !== written) throw new Error(`web core host: applied ${n} of ${written} operations`);
      applied += n;
      if (n) frames += 1;
    };
    const call = (fn) => (...args) => { const v = fn(...args); flush(); return v; };

    root.ctwHostPost = (json) => transport.send(json);
    core.frameManifest();
    const manifest = core.frameBytes().slice();
    core.frameReset();
    applier = root.IsonimFrameApplier.createFrameApplier({
      manifest,
      mount,
      dispatch: (id, type, value, key, deltaY, mods) => {
        const flags = core.dispatch(id, type, value, key, deltaY, mods);
        flush();
        return flags;
      },
    });
    call(core.boot)();
    transport.onMessage(call(core.deliver));
    // The panes' viewports, measured here: the core cannot read layout. A
    // pane's ViewModel asks for rows only once it knows how many fit.
    const PANES = ['state', 'calltrace', 'event-log'];
    const measured = {};
    const measure = () => {
      if (!core.mounted()) return;
      PANES.forEach((name, i) => {
        const el = mount.querySelector(`[data-pane="${name}"]`);
        if (!el) return;
        const rows = Math.max(1, Math.floor(el.clientHeight / (rowPx || 18)));
        const cols = Math.max(1, Math.floor(el.clientWidth / 8));
        const key = rows + 'x' + cols;
        if (measured[name] !== key) {
          measured[name] = key;
          core.setViewport(i, rows, cols, 0);
          flush();
        }
      });
    };
    const timer = setInterval(() => { call(core.pump)(); measure(); }, pumpMs || 16);
    root.addEventListener && root.addEventListener('resize', measure);

    return {
      openFolder: call(core.openFolder),
      step: call(core.step),
      pump: call(core.pump),
      node: applier.node,
      forget: core.forget || (() => {}),
      state: () => ({
        phase: PHASES[core.phase()] || String(core.phase()),
        failure: core.failure(),
        stepping: core.stepping() !== 0,
        position: core.position(),
        readCrossings: core.readCrossings(),
        pending: core.pending(),
        applied,
        frames,
      }),
      stop: () => clearInterval(timer),
    };
  }

  root.CtWebCoreHost = { startWebCore, bindWasm };
})(typeof globalThis !== 'undefined' ? globalThis : this);
