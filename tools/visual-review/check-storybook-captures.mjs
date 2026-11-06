#!/usr/bin/env node
// Check directories of StoryBook captures written by capture-storybook.mjs:
// every image is the one a judged capture wrote, and draws something inside
// each box where its story drew content. The rules are in
// capture-verdicts.mjs (`checkCaptureDir`).
//
// Usage:
//   node tools/visual-review/check-storybook-captures.mjs [--pixels-only] <dir>...
//   node tools/visual-review/check-storybook-captures.mjs --self-test
//
// `--pixels-only` skips the provenance check (the record's sha256) and judges
// each image on its pixels alone, inside the content boxes recorded for the
// same capture name. `--self-test` is the check's positive control: synthetic
// captures in a scratch directory -- one that draws content (passes), an empty
// panel, an image whose bytes are not the recorded ones, an image with no
// record, and a refused capture -- each failing for its reason.
//
// Exit status: 0 when every directory passes, 1 when any image fails, 2 on a
// usage error.

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { checkCaptureDir, encodePng, writeVerdicts } from "./capture-verdicts.mjs";

function report(dir, result) {
  for (const f of result.failures) console.log(`FAIL ${dir}/${f.file}: ${f.message}`);
  console.log(`${dir}: ${result.checked} image(s), ${result.failures.length} failure(s)` +
    (result.notes.length ? `, ${result.notes.length} recorded capture(s) not present` : ""));
}

// A 200x120 capture: a 24px header band, and below it a panel's content box.
function syntheticCapture({ ink }) {
  const width = 200, height = 120;
  const rgb = Buffer.alloc(width * height * 3, 0x28);
  for (let y = 0; y < 24; y++) for (let x = 0; x < width; x++) rgb.fill(0x50, (y * width + x) * 3, (y * width + x) * 3 + 3);
  if (ink) {
    // A line of "text" in the content box.
    for (let y = 40; y < 52; y++) for (let x = 10; x < 120; x += 2) rgb.fill(0xe0, (y * width + x) * 3, (y * width + x) * 3 + 3);
  }
  return encodePng(width, height, rgb);
}

function selfTest() {
  const dir = mkdtempSync(join(tmpdir(), "check-storybook-captures-"));
  try {
    const box = [{ name: "panel", x: 0, y: 24, width: 200, height: 96 }];
    const pass = (bytes) => ({
      verdict: "pass", viewport: { width: 200, height: 120 }, contentBoxes: box,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    });
    const good = syntheticCapture({ ink: true });
    const empty = syntheticCapture({ ink: false });
    const files = {
      "content.png": good,
      "empty-panel.png": empty,
      "swapped.png": empty,
      "unrecorded.png": good,
    };
    for (const [name, bytes] of Object.entries(files)) writeFileSync(join(dir, name), bytes);
    writeVerdicts(dir, {
      "content.png": pass(good),
      "empty-panel.png": pass(empty),
      // The record is of the good image; the file is the empty one.
      "swapped.png": pass(good),
      "refused.png": { verdict: "refused", failures: [{ category: "empty", message: "planted" }] },
    });
    const expected = {
      "content.png": null,
      "empty-panel.png": /draws nothing in its panel content box/,
      "swapped.png": /bytes are not the ones the capture recorded/,
      "unrecorded.png": /no passing verdict recorded/,
      "refused.png": /the capture was refused/,
    };
    const result = checkCaptureDir(dir);
    let ok = true;
    for (const [file, pattern] of Object.entries(expected)) {
      const messages = result.failures.filter((f) => f.file === file).map((f) => f.message);
      const caught = pattern ? messages.some((m) => pattern.test(m)) : messages.length === 0;
      console.log(`  ${caught ? "ok  " : "FAIL"} ${file} ${pattern ? `fails: ${pattern.source}` : "passes"}` +
        (caught ? "" : ` (got: ${messages.join("; ") || "nothing"})`));
      if (!caught) ok = false;
    }
    // Pixels alone still fail the empty panel and the swapped image.
    const pixels = checkCaptureDir(dir, { pixelsOnly: true });
    for (const file of ["empty-panel.png", "swapped.png"]) {
      const caught = pixels.failures.some((f) => f.file === file && /draws nothing/.test(f.message));
      console.log(`  ${caught ? "ok  " : "FAIL"} ${file} fails on its pixels alone (--pixels-only)`);
      if (!caught) ok = false;
    }
    console.log(ok ? "self-test passed" : "self-test FAILED: the check misses a capture it exists to catch");
    return ok ? 0 : 1;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function main() {
  const args = process.argv.slice(2);
  if (args.includes("--self-test")) return selfTest();
  const pixelsOnly = args.includes("--pixels-only");
  const dirs = args.filter((a) => !a.startsWith("--"));
  const unknown = args.filter((a) => a.startsWith("--") && a !== "--pixels-only");
  if (unknown.length || dirs.length === 0) {
    console.error("usage: check-storybook-captures.mjs [--pixels-only] <dir>... | --self-test");
    return 2;
  }
  let failed = false;
  for (const dir of dirs) {
    const result = checkCaptureDir(dir, { pixelsOnly });
    report(dir, result);
    if (result.failures.length) failed = true;
  }
  return failed ? 1 : 0;
}

process.exitCode = main();
