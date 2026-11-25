// Compare the element boxes two arms wrote for one story
// (`capture-dom.mjs --boxes`, `codetracer-zgui-story --boxes`).
//
//   node tools/story-parity/box-diff.mjs <reference.json> <candidate.json> [--tolerance 0.5] [--limit 40]
//
// The lists are walked in document order and paired element for element. A
// pair whose depth or tag differs means the two documents differ in structure
// there, and ends the walk; a pair whose id or classes differ is reported and
// the walk goes on. Otherwise every pair whose border
// box is off by more than the tolerance (CSS px) on any edge is listed,
// outermost first, so the first line is usually the cause of the rest.

import { readFileSync } from "node:fs";

const [refPath, candPath] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const opt = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i >= 0 ? Number(process.argv[i + 1]) : d; };
const tol = opt("tolerance", 0.5);
const limit = opt("limit", 40);
// zgui creates its own elements for the HTML tags with behaviour
// (isonim-zgui's user-agent sheet): the same element under another name.
const ZGUI_NAMES = { button: "control", select: "control", summary: "control",
  input: "field", textarea: "editor", img: "image", svg: "vector" };
const sameTag = (t, u) => t === u || ZGUI_NAMES[t] === u || ZGUI_NAMES[u] === t;
const a = JSON.parse(readFileSync(refPath, "utf8"));
const b = JSON.parse(readFileSync(candPath, "utf8"));
let shown = 0;
const n = Math.min(a.length, b.length);
if (a.length !== b.length) console.log(`element counts differ: ${a.length} against ${b.length}`);
for (let i = 0; i < n && shown < limit; i++) {
  const p = a[i], q = b[i];
  if (p.d !== q.d || !sameTag(p.t, q.t)) {
    console.log(`#${i} structure: ${"  ".repeat(p.d)}${p.t}${p.e} (depth ${p.d}) against ${q.t}${q.e} (depth ${q.d})`);
    shown++;
    break;
  }
  if (p.e !== q.e) {
    // Same element, different id or classes: a class one arm adds and the
    // other does not (a browser-only decoration) changes what rules match.
    console.log(`#${i} classes: ${"  ".repeat(p.d)}${p.t}${p.e} against ${q.e}`);
    shown++;
  }
  const off = Math.max(Math.abs(p.x - q.x), Math.abs(p.y - q.y), Math.abs(p.w - q.w), Math.abs(p.h - q.h));
  if (off > tol) {
    const f = (v) => Number(v).toFixed(1);
    console.log(`#${i} ${"  ".repeat(p.d)}${p.t}${p.e}: [${f(p.x)},${f(p.y)} ${f(p.w)}x${f(p.h)}] against [${f(q.x)},${f(q.y)} ${f(q.w)}x${f(q.h)}]`);
    shown++;
  }
}
if (shown === 0) console.log(`all ${n} element boxes within ${tol}px`);
