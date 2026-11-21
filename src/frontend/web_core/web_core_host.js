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
      attach: c('ctwAttach', null, ['string']),
      mountPane: c('ctwMountPane', null, ['string']),
      press: c('ctwPress', 'number', ['string', 'string']),
      expire: c('ctwExpire', 'number', ['number']),
      phase: c('ctwPhase', 'number'),
      failure: c('ctwFailure', 'string'),
      step: c('ctwStep', null, ['number']),
      stepping: c('ctwStepping', 'number'),
      position: c('ctwPosition', 'string'),
      readCrossings: c('ctwReadCrossings', 'number'),
      setViewport: c('ctwSetViewport', null, ['number', 'number', 'number', 'number']),
      mounted: c('ctwMounted', 'number'),
      pending: c('ctwPending', 'number'),
      fullValueOf: c('ctwFullValueOf', 'string', ['string']),
      eventLogMetrics: c('ctwEventLogMetrics', null, ['number', 'number']),
      eventLogSearch: c('ctwEventLogSearch', null, ['string']),
      eventLogTotal: c('ctwEventLogTotal', 'number'),
      eventLogCurrent: c('ctwEventLogCurrent', 'number'),
      eventLogRowPx: c('ctwEventLogRowPx', 'number'),
      calltraceMeasured: c('ctwCalltraceMeasured', null, ['number', 'number', 'number']),
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
  function startWebCore({ core: raw, mount, transport, pumpMs, rowPx, paneRoot, requestTimeoutMs }) {
    // Where the panes are looked up: the mount, or the whole document for a
    // host that moves each pane into a place of its own.
    const panesIn = paneRoot || mount;
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

    // Requests the core sent and the engine has not answered, by seq, with
    // the time each was sent: after `requestTimeoutMs` (the renderer's DAP
    // timeout, 30 s, by default) the core settles one as failed.
    const waiting = new Map();
    const timeoutMs = requestTimeoutMs || 30000;
    root.ctwHostPost = (json) => {
      try { const m = JSON.parse(json); if (m.type === 'request') waiting.set(m.seq, Date.now()); } catch (e) {}
      transport.send(json);
    };
    const expireStale = () => {
      const now = Date.now();
      for (const [seq, at] of waiting) {
        if (now - at >= timeoutMs) { waiting.delete(seq); if (core.expire) { core.expire(seq); flush(); } }
      }
    };
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
    transport.onMessage((text) => {
      try { const m = JSON.parse(text); if (m.type === 'response') waiting.delete(m.request_seq); } catch (e) {}
      call(core.deliver)(text);
    });
    // The panes' viewports, measured here: the core cannot read layout. A
    // pane's ViewModel asks for rows only once it knows how many fit.
    const PANES = ['state', 'calltrace', 'event-log'];
    const measured = {};
    const measure = () => {
      if (!core.mounted()) return;
      PANES.forEach((name, i) => {
        const el = panesIn.querySelector(`[data-pane="${name}"]`);
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
    // The panes' DOM decoration (`web_core_decorations.nim`): table fit and
    // overflow, the event log's search field and scrubber, run here against
    // the nodes the applier owns. Every call it makes into the core is
    // followed by a flush, like any other.
    const decorationApi = {
      fullValueOf: (p) => core.fullValueOf(p),
      eventLogMetrics: call(core.eventLogMetrics),
      eventLogSearch: call(core.eventLogSearch),
      eventLogTotal: () => core.eventLogTotal(),
      eventLogCurrent: () => core.eventLogCurrent(),
      eventLogRowPx: () => core.eventLogRowPx(),
      calltraceMeasured: call(core.calltraceMeasured),
    };
    const decorate = () => {
      if (core.mounted() && root.ctwDecoratePanes) root.ctwDecoratePanes(panesIn, decorationApi);
    };
    const timer = setInterval(() => { call(core.pump)(); measure(); decorate(); expireStale(); }, pumpMs || 16);
    root.addEventListener && root.addEventListener('resize', measure);

    return {
      openFolder: call(core.openFolder),
      attach: call(core.attach),
      mountPane: call(core.mountPane),
      // A pointer press on an element the applier owns: its attributes and
      // its ancestors' (the nearest first) cross with the operation, so the
      // core reads them without a read crossing.
      press: (operation, el) => {
        const attrs = {};
        for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
          for (const a of n.attributes) if (!(a.name in attrs)) attrs[a.name] = a.value;
          if (n.classList && n.classList.contains('ct-web-core-pane')) break;
        }
        return call(core.press)(operation, JSON.stringify(attrs)) !== 0;
      },
      // A pane's container, for a host that places panes itself (moving it
      // keeps every handle valid: the applier holds the nodes, not paths).
      paneElement: (name) => panesIn.querySelector(`[data-pane="${name}"]`),
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
