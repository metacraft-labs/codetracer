// The story-parity harness's report and floor gate (scripts/story-parity.sh).
//
//   node tools/story-parity/report.mjs --results <results.jsonl> --out <dir>
//     --floors <floors.json> [--check] [--update]
//
// Writes <out>/report.json (every comparison) and <out>/report.md (one row per
// arm, story and size, ranked by differing pixels, with the panes ranked by
// area beneath). With --check, every comparison that has a floor must be at or
// under it, and every comparison must have one; a comparison that could not be
// made fails. With --update, floors are lowered to the counts measured (never
// raised: a count above its floor is a regression, not a new floor) and
// comparisons with no floor yet get one.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

function arg(name, fallback = undefined) {
  const at = process.argv.indexOf(`--${name}`);
  if (at >= 0 && at + 1 < process.argv.length) return process.argv[at + 1];
  if (fallback === undefined) throw new Error(`missing --${name}`);
  return fallback;
}
const flag = (name) => process.argv.includes(`--${name}`);

const results = readFileSync(arg("results"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
const out = arg("out");
const floorsPath = arg("floors");
const check = flag("check");
const update = flag("update");

const floorsDoc = existsSync(floorsPath)
  ? JSON.parse(readFileSync(floorsPath, "utf8"))
  : { "//": "", floors: {} };
const floors = floorsDoc.floors;
const key = (r) => `${r.arm} ${r.story} ${r.size}`;

let failures = [];
let lowered = [];
for (const r of results) {
  const k = key(r);
  const floor = floors[k];
  if (!r.comparable) {
    failures.push(`${k}: not comparable (${r.reason})`);
    continue;
  }
  if (floor === undefined) {
    if (update) floors[k] = r.differing;
    else if (check) failures.push(`${k}: no floor (measured ${r.differing}); run with --update-floors`);
    continue;
  }
  if (r.differing > floor) {
    failures.push(`${k}: ${r.differing} differing px, above its floor ${floor}`);
  } else if (r.differing < floor) {
    lowered.push(`${k}: ${floor} -> ${r.differing}`);
    if (update) floors[k] = r.differing;
  }
}

const sorted = [...results].sort((a, b) => (b.differing ?? 0) - (a.differing ?? 0));
let md = "# Story parity\n\n| arm | story | size | differing px | % | FLIP mean | floor |\n|---|---|---|---:|---:|---:|---:|\n";
for (const r of sorted) {
  const pct = r.comparable ? (100 * r.differingFraction).toFixed(2) : "-";
  md += `| ${r.arm} | ${r.story} | ${r.size} | ${r.comparable ? r.differing : r.reason} | ${pct} | ${r.comparable ? r.flipMean.toFixed(4) : "-"} | ${floors[key(r)] ?? "-"} |\n`;
}
md += "\n## Panes, by differing pixels\n\n";
for (const r of sorted.filter((r) => r.comparable)) {
  md += `- ${r.arm} ${r.story} ${r.size}: ` +
    [...r.regions].sort((a, b) => b.differing - a.differing)
      .map((g) => `${g.name} ${g.differing}/${g.area}`).join(", ") +
    `, outside ${r.outsideRegions}\n`;
}
writeFileSync(join(out, "report.md"), md);
writeFileSync(join(out, "report.json"), JSON.stringify(results, null, 2));
if (update) {
  floorsDoc["//"] = "Story-parity floors: per arm, story and size, the most differing pixels allowed against the DOM arm. Only ever lowered (scripts/story-parity.sh --update-floors). The target is 0.";
  const ordered = Object.fromEntries(Object.entries(floors).sort(([a], [b]) => a.localeCompare(b)));
  floorsDoc.floors = ordered;
  writeFileSync(floorsPath, JSON.stringify(floorsDoc, null, 2) + "\n");
}
console.log(md);
for (const l of lowered) console.log(`lowered: ${l}`);
for (const f of failures) console.error(`FAIL ${f}`);
process.exit(failures.length > 0 && (check || !update) && failures.some((f) => check || f.includes("not comparable")) ? 1 : 0);
