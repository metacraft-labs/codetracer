// applier.js — PLAT-18's vertical slice: the HOST half of the boundary.
//
// This is what a JS host would have to be if the ViewModel core ran as
// WebAssembly. It reads one flat command frame and applies it to a real
// document, holding the node table the core cannot hold
// (Uniform-WASM-Core.md §3).
//
// ## ONE APPLIER, BOTH CROSSING ARMS
//
// `js-crossing` and `wasm-crossing` differ only in which runtime produced the
// frame and how the host gets at the bytes. They share this function, so the
// difference between their timings is the runtime and not two decoders
// (Verification-Harness-Traps.md §14: one predicate, one function).
//
// ## THE OPCODE TABLE IS NOT WRITTEN HERE
//
// It is read from the module's own `p18OpManifest`, because a switch with the
// numbers typed out in JavaScript is a second copy of a Nim enum in a file the
// Nim compiler does not read. `buildOpTable` additionally REFUSES a manifest
// that does not name every operation this file can apply, so a renamed or
// removed operation is a loud failure rather than a document that quietly
// says something else.

'use strict';

/** Operations this applier knows how to perform. Names are `BoundaryOp`'s,
 *  minus the `bo` prefix. */
const APPLIERS = {
  CreateElement: (c) => { const h = c.u32(); const tag = c.str(); c.nodes[h] = document.createElement(tag); },
  CreateTextNode: (c) => { const h = c.u32(); const t = c.str(); c.nodes[h] = document.createTextNode(t); },
  AppendChild: (c) => { const p = c.u32(), ch = c.u32(); c.nodes[p].appendChild(c.nodes[ch]); },
  InsertBefore: (c) => { const p = c.u32(), ch = c.u32(), r = c.u32(); c.nodes[p].insertBefore(c.nodes[ch], c.nodes[r] || null); },
  RemoveChild: (c) => { const p = c.u32(), ch = c.u32(); const n = c.nodes[ch]; if (n && n.parentNode === c.nodes[p]) c.nodes[p].removeChild(n); },
  SetAttribute: (c) => { const h = c.u32(); const n = c.str(), v = c.str(); c.nodes[h].setAttribute(n, v); },
  RemoveAttribute: (c) => { const h = c.u32(); const n = c.str(); c.nodes[h].removeAttribute(n); },
  SetTextContent: (c) => { const h = c.u32(); const t = c.str(); c.nodes[h].textContent = t; },
  SetStyle: (c) => { const h = c.u32(); const p = c.str(), v = c.str(); c.nodes[h].style.setProperty(p, v); },
  SetInnerHtml: (c) => { const h = c.u32(); const s = c.str(); c.nodes[h].innerHTML = s; },
  // The handler itself never crosses: what crosses is a callback id, and the
  // host calls back IN with it. That is the direction §3A.2 says has never
  // been the hard one.
  AddEventListener: (c) => {
    const h = c.u32(), id = c.u32(); const ev = c.str();
    c.nodes[h].addEventListener(ev, () => c.dispatch(id));
  },
  ClearChildren: (c) => { const h = c.u32(); c.nodes[h].textContent = ''; },
  ClearEventListeners: (c) => { c.u32(); /* the DOM has no such call; the
      core re-creates listeners after a clear, which is why WebRenderer's own
      implementation of this is `discard` too */ },
  Focus: (c) => { const h = c.u32(); c.nodes[h].focus(); },
  SetInputValue: (c) => { const h = c.u32(); const v = c.str(); c.nodes[h].value = v; },
};

/** Operations that would have to answer BACK across the boundary. They are
 *  measured to be absent on this path, and the slice refuses to publish a
 *  timing if one appears — see `plat18_frame_renderer.nim`'s header. */
const READ_OPS = ['FirstChild', 'NextSibling', 'ParentNode', 'GetAttribute', 'InputValue'];

function makeCursor(bytes, nodes, dispatch) {
  const dec = new TextDecoder('utf-8');
  const c = {
    at: 0, nodes, dispatch,
    u32() {
      const b = bytes;
      const v = (b[c.at] | (b[c.at + 1] << 8) | (b[c.at + 2] << 16) | (b[c.at + 3] << 24)) >>> 0;
      c.at += 4;
      return v;
    },
    str() {
      const n = c.u32();
      const s = dec.decode(bytes.subarray(c.at, c.at + n));
      c.at += n;
      return s;
    },
  };
  return c;
}

/** Read `p18OpManifest`'s frame into `{ordinal: name}` and check it covers
 *  everything this file applies. Throws rather than returning a partial
 *  table: a partial op table is a scanner that finds nothing, and every
 *  "must contain" written against it would pass. */
function buildOpTable(bytes) {
  const c = makeCursor(bytes, null, null);
  const byOrdinal = {};
  const seen = new Set();
  while (c.at < bytes.length) {
    const ord = bytes[c.at++];
    const name = c.str().replace(/^bo/, '');
    byOrdinal[ord] = name;
    seen.add(name);
  }
  const missing = Object.keys(APPLIERS).filter((n) => !seen.has(n));
  if (missing.length) {
    throw new Error('op manifest does not name: ' + missing.join(','));
  }
  const missingReads = READ_OPS.filter((n) => !seen.has(n));
  if (missingReads.length) {
    throw new Error('op manifest does not name the read ops: ' + missingReads.join(','));
  }
  if (seen.size === 0) throw new Error('op manifest is empty');
  return byOrdinal;
}

/** Apply one frame. Returns the number of operations applied — the caller
 *  compares it against what the core counted, so a frame that stopped being
 *  parsed halfway cannot be reported as a fast one. */
function applyFrame(bytes, opTable, nodes, dispatch) {
  const c = makeCursor(bytes, nodes, dispatch);
  let applied = 0;
  while (c.at < bytes.length) {
    const code = bytes[c.at++];
    const name = opTable[code];
    if (name === undefined) throw new Error('unknown opcode ' + code + ' at ' + (c.at - 1));
    const fn = APPLIERS[name];
    if (fn === undefined) {
      throw new Error('frame carries a READ operation (' + name + '); this path was ' +
                      'measured to be write-only and the measurement no longer holds');
    }
    fn(c);
    applied += 1;
  }
  if (c.at !== bytes.length) throw new Error('frame did not consume exactly');
  return applied;
}

if (typeof globalThis !== 'undefined') {
  globalThis.ctP18Applier = { applyFrame, buildOpTable, APPLIERS, READ_OPS };
}
