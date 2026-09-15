// wasm_bridge.js — PLAT-18's vertical slice: reaching PLAT-17's core from a
// browser host.
//
// The emscripten module is built `-sMODULARIZE=1 -sEXPORT_NAME=ctP18Module
// -sENVIRONMENT=web`, so this is a BROWSER build and not the node build
// PLAT-17's lane runs (`-sNODERAWFS=1`). That distinction is PLAT-17's own
// bound 1 and it is what makes this file the first thing in the campaign to
// run the core where it would actually ship.
//
// `frameBytes` returns a VIEW into linear memory — no copy — and re-reads
// `HEAPU8` on every call, because `-sALLOW_MEMORY_GROWTH=1` detaches and
// replaces the backing buffer whenever the heap grows. A cached `HEAPU8` is a
// view of a detached ArrayBuffer, which reads as length 0: an empty frame, a
// fast timing, and a document that never changed.

'use strict';

async function loadP18Wasm() {
  const Module = await globalThis.ctP18Module();
  const call = (name, ret, args) => Module.cwrap(name, ret, args || []);

  const frameBase = call('p18FrameBase', 'number');
  const frameLen = call('p18FrameLen', 'number');

  globalThis.ctP18Wasm = {
    reset: call('p18Reset', null),
    mount: call('p18Mount', null),
    beginFrame: call('p18BeginFrame', null),
    expand: call('p18Expand', null),
    step: call('p18Step', null),
    collapse: call('p18Collapse', null),
    rows: call('p18Rows', 'number'),
    frameLen,
    // How many operations the core put in the frame, for the host's
    // applied-equals-emitted floor in `driver.js`.
    ops: call('p18Ops', 'number'),
    readCrossings: call('p18ReadCrossings', 'number'),
    dispatch: call('p18Dispatch', null, ['number']),
    opManifest: call('p18OpManifest', null),
    frameBytes: () => {
      const base = frameBase();
      const len = frameLen();
      if (len === 0) return new Uint8Array(0);
      return Module.HEAPU8.subarray(base, base + len);
    },
    // Exposed so the cold-start arm can report what it paid for.
    _module: Module,
  };
  return globalThis.ctP18Wasm;
}

globalThis.loadP18Wasm = loadP18Wasm;
