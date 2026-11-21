// driver.js — PLAT-18's vertical slice: the SCHEDULE.
//
// Runs the three arms against ONE document in ONE Electron renderer process,
// interleaved, and prints one `PLAT18-SLICE …` line per (arm, phase).
//
// ## WHY INTERLEAVED
//
// Verification-Harness-Traps.md §12a: an absolute bound on a single
// measurement is a coin flip with one side hidden, and the host this campaign
// runs on has been measured at load 60+ on 24 CPUs. Running all three arms
// back to back inside one sample, and repeating the sample, puts the same
// scheduler noise on every arm — so the RATIO between arms is meaningful even
// when no individual number is.
//
// ## THE NON-VACUITY FLOOR
//
// Three checks, and a failure of any of them voids the run rather than being
// reported beside it:
//
//   * `checkAttached` — the panel reached the document at all;
//   * `checkRows` — the CORE's row count (`p18Rows`) and the DOCUMENT's
//     (`.value-expanded-name[data-variable-name]`) must agree, and after
//     EXPAND both must be 602;
//   * `checkOps` — on the crossing arms, the op count the host APPLIED must
//     equal the count the core PUT IN the frame (`p18Ops`).
//
// A timing over a document that never received its 602 rows is a timing of
// nothing, and that is the shape this campaign keeps meeting.
//
// The third of these was stated in this header for a while as something the
// run did, while `applyFrame` only RETURNED its count and nothing compared it
// — a claim in prose with nothing in the machine behind it (§14). `p18Ops`
// and `checkOps` are that gap closed rather than the sentence deleted,
// because the property is the one STEP and COLLAPSE need: neither changes the
// row count, so the two checks above them are satisfied by a frame that was
// applied only half way.
//
// ## THE PANE, AND PARITY
//
// The slice drives more than one pane (`CT_P18_PANE` in the build script);
// `globalThis.CT_P18_PANE_CONFIG` names the pane's row selector and its row
// counts, so the floors above are the pane's own.
//
// And the arms must draw THE SAME DOCUMENT, not only the same number of
// rows. On the first sample, after every phase, each arm's document is
// snapshotted and compared (`checkParity`):
//
//   * `js-crossing` against `wasm-crossing`: the WHOLE document, byte for
//     byte. Same Nim source, same renderer, same host applier, two
//     compilers — any difference is a defect in one of the two cores.
//   * `js-direct` against `js-crossing`: the pane's ROWS (each row's
//     markup). `js-direct` is the shipping build and draws through
//     `WebRenderer`, whose panel chrome can differ from the generic panel's
//     (the variables pane's does), so the rows are what the two are held
//     to. Attributes the pane's own DOM decoration writes on `js-direct`
//     only are named in the config (`directIgnoreAttrs`) and removed from
//     both sides before the comparison, so a difference anywhere else still
//     fails.
//
// A mismatch voids the run, like the floors above.

'use strict';

const SAMPLES = Number(globalThis.CT_P18_SAMPLES || 9);
const PANE = globalThis.CT_P18_PANE_CONFIG || {
  name: 'variables',
  // the 600-member mapping, its own row, and `counter`
  rowSelector: '.value-expanded-name[data-variable-name]',
  rowElementSelector: '.value-expanded-name[data-variable-name]',
  expandedRows: 602,
  collapsedRows: 2,
  directIgnoreAttrs: [],
};
const EXPECTED_ROWS = PANE.expandedRows;
const EXPECTED_COLLAPSED_ROWS = PANE.collapsedRows;

function rootEl() { return document.getElementById('ct-p18-root'); }

function clearRoot() {
  const r = rootEl();
  while (r.firstChild) r.removeChild(r.firstChild);
}

// THE SELECTOR IS NOT `[data-variable-name]`, AND THE REASON IS A MEASUREMENT.
// `renderVariableRowImpl` puts that attribute on TWO elements per row — the
// row container and the origin badge button — so the bare attribute selector
// reported FOUR rows for a two-row panel. Left as it was, the EXPAND check
// would have demanded 602 and been handed 1204, which at least fails loudly;
// what it would NOT have caught is a panel drawing 301 rows twice. The row
// container is the one carrying `value-expanded-name` (`rowClass`), and that
// is also the class `plat18_marshalling_probe.countRows` filters on, so the
// two instruments count the same thing.
function domRows() {
  return rootEl().querySelectorAll(PANE.rowSelector).length;
}

/** The pane's rows as markup, with the decoration-owned attributes removed. */
function rowSnapshot(ignoreAttrs) {
  const out = [];
  for (const el of rootEl().querySelectorAll(PANE.rowElementSelector)) {
    const copy = el.cloneNode(true);
    if (ignoreAttrs.length) {
      for (const n of [copy, ...copy.querySelectorAll('*')]) {
        for (const a of ignoreAttrs) n.removeAttribute(a);
      }
    }
    out.push(copy.outerHTML);
  }
  return out;
}

function snapshot() {
  return {
    document: rootEl().innerHTML,
    rows: rowSnapshot([]),
    rowsUndecorated: rowSnapshot(PANE.directIgnoreAttrs || []),
  };
}

function firstDifference(a, b) {
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  return i;
}

/** Compare two arms' snapshots of one phase. Throws on a mismatch. */
function checkParity(phaseName, left, leftSnap, right, rightSnap, mode) {
  let a, b, items;
  if (mode === 'document') {
    a = [leftSnap.document];
    b = [rightSnap.document];
  } else {
    a = leftSnap.rowsUndecorated;
    b = rightSnap.rowsUndecorated;
  }
  items = a.length;
  if (a.length !== b.length) {
    throw new Error(`parity ${left}/${right} ${phaseName} (${mode}): ${a.length} ` +
                    `against ${b.length} item(s)`);
  }
  let bytes = 0;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      const at = firstDifference(a[i], b[i]);
      throw new Error(`parity ${left}/${right} ${phaseName} (${mode}): item ${i} differs ` +
                      `at character ${at}: ${JSON.stringify(a[i].slice(Math.max(0, at - 60), at + 80))} ` +
                      `against ${JSON.stringify(b[i].slice(Math.max(0, at - 60), at + 80))}`);
    }
    bytes += a[i].length;
  }
  if (bytes === 0) {
    throw new Error(`parity ${left}/${right} ${phaseName} (${mode}): compared nothing`);
  }
  console.log(`PLAT18-SLICE-PARITY pane=${PANE.name} phase=${phaseName} ${left}=${right}` +
              ` mode=${mode} items=${items} chars=${bytes}`);
}

function now() { return performance.now(); }

/** One arm, wrapped so the driver treats all three the same way. */
function makeArm(name, api, frameBytesOf) {
  return {
    name,
    api,
    crossing: frameBytesOf !== null,
    applier: null,
    frameBytesOf,
  };
}

/** A fresh host for a crossing arm: IsoNim's frame applier, its opcode table
 *  read from the core's own manifest, handle 0 standing for the pane's root. */
function prepareArm(arm) {
  if (!arm.crossing) return;
  arm.api.opManifest();
  arm.applier = globalThis.IsonimFrameApplier.createFrameApplier({
    manifest: arm.frameBytesOf().slice(),
    mount: rootEl(),
    dispatch: (id) => { arm.api.dispatch(id); return 0; },
  });
}

/** Run one phase. Returns {coreMs, hostMs, bytes, ops}.
 *
 *  `coreMs` is the ViewModel and the view: everything inside the module.
 *  `hostMs` is the decode and the DOM application: everything outside it.
 *  They are SEPARATE because they are different quantities — the direct arm
 *  has no `hostMs` at all, and folding them would hide which half moved.  */
function phase(arm, phaseName, fn) {
  let bytes = 0;
  let ops = 0;
  let hostMs = 0;

  if (arm.crossing) arm.api.beginFrame();
  const t0 = now();
  fn();
  const t1 = now();

  if (arm.crossing) {
    const frame = arm.frameBytesOf();
    bytes = frame.length;
    // Read BEFORE the frame is applied. `AddEventListener` dispatches back
    // into the core, and a callback that reached `p18BeginFrame` would zero
    // the counter under the comparison.
    const emitted = arm.api.ops();
    const h0 = now();
    ops = arm.applier.apply(frame);
    hostMs = now() - h0;
    checkOps(arm, phaseName, emitted, ops);
  }
  return { coreMs: t1 - t0, hostMs, bytes, ops };
}

// THE THIRD FLOOR, AND IT IS DISJOINT FROM THE OTHER TWO.
//
// The row checks compare COUNTS of elements; this compares COUNTS of
// operations, and the two catch different things. A frame whose cursor
// desynchronises mid-stream — a `str()` that read a wrong length and left
// `at` inside a payload — applies a prefix, stops early or throws on a
// nonsense opcode, and in the cases where it stops early it reports a fast
// timing over a partly-updated document. STEP and COLLAPSE are exactly where
// that hides: neither changes the number of rows, so both row checks stay
// satisfied at 602 and 2 however much of the attribute and text traffic never
// landed.
//
// It was claimed in this file's header before it was implemented, which is
// the §14 shape — a property asserted in prose and nowhere the machine reads.
function checkOps(arm, phaseName, emitted, applied) {
  if (emitted !== applied) {
    throw new Error(`${arm.name}/${phaseName}: the core put ${emitted} operation(s) in ` +
                    `the frame and the host applied ${applied}`);
  }
}

function median(xs) {
  const s = xs.slice().sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
}

/** The nearest-rank percentile: the smallest sample at least `p` of the
 *  samples are at or below. At 100 samples p99 is the 99th order statistic;
 *  at fewer than 100 it is the maximum, and the line says how many samples
 *  it was taken over. */
function percentile(xs, p) {
  const s = xs.slice().sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil(p * s.length) - 1))];
}

function report(arm, phaseName, samples) {
  const core = samples.map((s) => s.coreMs);
  const host = samples.map((s) => s.hostMs);
  const total = samples.map((s) => s.coreMs + s.hostMs);
  const bytes = samples[0].bytes;
  for (const s of samples) {
    if (s.bytes !== bytes) {
      throw new Error(`${arm}/${phaseName}: frame size moved between samples ` +
                      `(${bytes} vs ${s.bytes})`);
    }
  }
  console.log(`PLAT18-SLICE arm=${arm} phase=${phaseName} samples=${samples.length}` +
    ` bytes=${bytes} ops=${samples[0].ops}` +
    ` core_ms_median=${median(core).toFixed(3)}` +
    ` core_ms_min=${Math.min(...core).toFixed(3)}` +
    ` core_ms_max=${Math.max(...core).toFixed(3)}` +
    ` host_ms_median=${median(host).toFixed(3)}` +
    ` total_ms_median=${median(total).toFixed(3)}` +
    ` total_ms_min=${Math.min(...total).toFixed(3)}` +
    ` total_ms_max=${Math.max(...total).toFixed(3)}` +
    ` total_ms_p99=${percentile(total, 0.99).toFixed(3)}`);
}

// TWO CHECKS, NOT ONE, AND THEY HAVE DISJOINT EVIDENCE.
//
// "the panel reached the document" and "the rows are identifiable in it" are
// different properties with different failure modes, and a single row count
// answers 0 for both. Two mutation arms proved it: one that drops the root
// `appendChild` so the panel is never attached, and one that makes the host
// read a `SetAttribute` operation and not perform it — different defects, one
// symptom, and the harness refused the run because neither could be
// attributed (Verification-Harness-Traps.md §32a: defence in depth costs a
// test each, and the evidence has to be disjoint or the older arm is the one
// that goes quiet).
function checkAttached(arm, phaseName) {
  const n = rootEl().childElementCount;
  if (n === 0) {
    throw new Error(`${PANE.name} pane, ${arm.name}/${phaseName}: the panel never reached the document ` +
                    `— the container holds ${n} child element(s)`);
  }
}

function checkRows(arm, phaseName, expected) {
  const core = arm.api.rows();
  const dom = domRows();
  if (core !== expected || dom !== expected) {
    throw new Error(`${PANE.name} pane, ${arm.name}/${phaseName}: core says ${core} row(s), the document ` +
                    `holds ${dom}, expected ${expected}`);
  }
}

function run() {
  const arms = [];
  if (globalThis.p18Direct) {
    arms.push(makeArm('js-direct', globalThis.p18Direct, null));
  }
  if (globalThis.p18Frame) {
    arms.push(makeArm('js-crossing', globalThis.p18Frame, globalThis.p18Frame.frameBytes));
  }
  if (globalThis.ctP18Wasm) {
    arms.push(makeArm('wasm-crossing', globalThis.ctP18Wasm, globalThis.ctP18Wasm.frameBytes));
  }
  if (arms.length === 0) throw new Error('no arm loaded');

  const results = {};
  for (const a of arms) {
    results[a.name] = { MOUNT: [], EXPAND: [], STEP: [], COLLAPSE: [] };
  }

  // Sample 0's documents, per arm and phase, for `checkParity`.
  const snaps = {};
  for (const a of arms) snaps[a.name] = {};
  const snap = (i, arm, phaseName) => {
    if (i === 0) snaps[arm.name][phaseName] = snapshot();
  };

  for (let i = 0; i < SAMPLES; i++) {
    for (const arm of arms) {
      clearRoot();
      prepareArm(arm);
      arm.api.reset();

      results[arm.name].MOUNT.push(phase(arm, 'MOUNT', () => arm.api.mount()));
      checkAttached(arm, 'MOUNT');
      checkRows(arm, 'MOUNT', EXPECTED_COLLAPSED_ROWS);
      snap(i, arm, 'MOUNT');

      results[arm.name].EXPAND.push(phase(arm, 'EXPAND', () => arm.api.expand()));
      checkRows(arm, 'EXPAND', EXPECTED_ROWS);
      snap(i, arm, 'EXPAND');

      results[arm.name].STEP.push(phase(arm, 'STEP', () => arm.api.step()));
      checkRows(arm, 'STEP', EXPECTED_ROWS);
      snap(i, arm, 'STEP');

      results[arm.name].COLLAPSE.push(phase(arm, 'COLLAPSE', () => arm.api.collapse()));
      checkRows(arm, 'COLLAPSE', EXPECTED_COLLAPSED_ROWS);
      snap(i, arm, 'COLLAPSE');

      if (arm.crossing && arm.api.readCrossings() !== 0) {
        throw new Error(`${arm.name}: ${arm.api.readCrossings()} read crossing(s); the ` +
                        'write-only measurement this slice rests on no longer holds');
      }
    }
  }

  // STEADY-STATE MEMORY — §4 metric 4. Taken on a FRESH pass with the 602
  // rows standing, after a settle, and reported per arm with what it is a
  // measurement OF, because the two arms do not hold their state in the same
  // place: the JS arms' is entirely `usedJSHeapSize`, and the wasm arm's is
  // split between linear memory (the core) and the JS heap (the host's node
  // table and the document). Adding them up for one arm and not the other is
  // the comparison this line exists to prevent.
  for (const arm of arms) {
    clearRoot();
    prepareArm(arm);
    arm.api.reset();
    phase(arm, 'MEMORY-MOUNT', () => arm.api.mount());
    phase(arm, 'MEMORY-EXPAND', () => arm.api.expand());
    checkRows(arm, 'MEMORY', EXPECTED_ROWS);
    const jsHeap = (performance.memory && performance.memory.usedJSHeapSize) || 0;
    const linear = arm.api._module ? arm.api._module.HEAPU8.length : 0;
    console.log(`PLAT18-SLICE-MEMORY arm=${arm.name} rows=${EXPECTED_ROWS}` +
      ` js_heap_bytes=${jsHeap} linear_memory_bytes=${linear}` +
      ` total_bytes=${jsHeap + linear}`);
  }

  for (const p of ['MOUNT', 'EXPAND', 'STEP', 'COLLAPSE']) {
    if (snaps['js-crossing'] && snaps['wasm-crossing']) {
      checkParity(p, 'js-crossing', snaps['js-crossing'][p],
                  'wasm-crossing', snaps['wasm-crossing'][p], 'document');
    }
    if (snaps['js-direct'] && snaps['js-crossing']) {
      checkParity(p, 'js-direct', snaps['js-direct'][p],
                  'js-crossing', snaps['js-crossing'][p], 'rows');
    }
  }

  for (const arm of arms) {
    for (const p of ['MOUNT', 'EXPAND', 'STEP', 'COLLAPSE']) {
      report(arm.name, p, results[arm.name][p]);
    }
  }
  console.log(`PLAT18-SLICE-ARMS ${arms.map((a) => a.name).join(',')}`);
  return 'ok';
}

globalThis.ctP18Run = run;
