// The record `capture-storybook.mjs` keeps beside the images it writes, and
// the check of a directory of captures against it.
//
// `capture-verdicts.json`, in the capture directory, maps each image's file
// name to the verdict of the render check's judge
// (storybook/scripts/story-render-judge.mjs) on the story at the moment it was
// shot: `pass`, with the image's sha256 and the boxes, in page pixels, where
// the story drew its content (the panel's content area, or each shown panel
// of a layout); or `refused`, with the judge's failures, when no image was
// written.
//
// `checkCaptureDir(dir)` holds the images to it, in two independent ways:
//
//   1. Provenance. Every PNG in the directory has a `pass` record whose sha256
//      is its bytes, and no record is `refused`. An image written by anything
//      else, or by an earlier tool that shot before the story had rendered,
//      has no such record.
//   2. Pixels. Inside every recorded content box the image draws something: at
//      least MIN_INK pixels that differ clearly from the box's dominant colour.
//      An empty panel is one flat colour below its header, whatever wrote it,
//      and a story's content (a line of text, a status mark) is far more than
//      MIN_INK pixels. With `pixelsOnly` the provenance check is skipped, so an
//      image can be judged on its pixels alone (the boxes still come from the
//      record of the same capture name).
//
// A SEPARATE MODULE from the capture script, which resolves Playwright at import
// time: this check reads files only and runs with node alone.
//
// PNG: https://www.w3.org/TR/png-3/ -- the decoder reads what Chromium writes
// for a screenshot, 8-bit truecolour with or without alpha, not interlaced,
// and refuses anything else rather than guess.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { deflateSync, inflateSync } from "node:zlib";

export const VERDICTS_FILE = "capture-verdicts.json";
// A pixel is ink when its colour is this far (sum of the channel differences)
// from the box's dominant colour. Chromium fills a flat panel with one exact
// colour (an empty panel measures 0 ink pixels even at a distance of 2), and
// content under a modal's veil can differ from its background by less than
// 24 (measured on the command-palette layout in Light), so the bar is low.
export const INK_DISTANCE = 6;
// The ink a content box must show. A single word of 16px text draws a few
// hundred such pixels; an empty panel draws none.
export const MIN_INK = 40;
// Pixels left out at each edge of a box, where a panel's border is drawn.
const INSET = 2;

export function readVerdicts(dir) {
  const path = join(dir, VERDICTS_FILE);
  if (!existsSync(path)) return {};
  return JSON.parse(readFileSync(path, "utf8")).captures ?? {};
}

export function writeVerdicts(dir, captures) {
  const sorted = Object.fromEntries(Object.entries(captures).sort(([a], [b]) => a.localeCompare(b)));
  writeFileSync(join(dir, VERDICTS_FILE), JSON.stringify({
    about: "Written by tools/visual-review/capture-storybook.mjs; checked by tools/visual-review/check-storybook-captures.mjs.",
    captures: sorted,
  }, null, 2) + "\n");
}

// decodePng(buffer) -> { width, height, channels, pixels } (pixels: RGB or RGBA rows).
export function decodePng(buffer) {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (buffer.length < 8 || !buffer.subarray(0, 8).equals(signature)) throw new Error("not a PNG");
  let offset = 8;
  let header = null;
  const data = [];
  while (offset + 8 <= buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    const chunk = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      header = { width: chunk.readUInt32BE(0), height: chunk.readUInt32BE(4), depth: chunk[8], colour: chunk[9], interlace: chunk[12] };
    } else if (type === "IDAT") {
      data.push(chunk);
    } else if (type === "IEND") {
      break;
    }
    offset += 12 + length;
  }
  if (!header) throw new Error("PNG without IHDR");
  if (header.depth !== 8 || (header.colour !== 2 && header.colour !== 6) || header.interlace !== 0) {
    throw new Error(`unsupported PNG (depth ${header.depth}, colour type ${header.colour}, interlace ${header.interlace})`);
  }
  const channels = header.colour === 6 ? 4 : 3;
  const stride = header.width * channels;
  const raw = inflateSync(Buffer.concat(data));
  if (raw.length < header.height * (stride + 1)) throw new Error("PNG image data is truncated");
  const pixels = Buffer.alloc(header.height * stride);
  for (let y = 0; y < header.height; y++) {
    // Each row: a filter byte, then the filtered bytes (PNG §7.3, §9).
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const row = pixels.subarray(y * stride, (y + 1) * stride);
    const above = y > 0 ? pixels.subarray((y - 1) * stride, y * stride) : null;
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? row[x - channels] : 0;
      const b = above ? above[x] : 0;
      const c = above && x >= channels ? above[x - channels] : 0;
      let value = line[x];
      if (filter === 1) value += a;
      else if (filter === 2) value += b;
      else if (filter === 3) value += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        value += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      } else if (filter !== 0) throw new Error(`PNG row ${y} has unknown filter ${filter}`);
      row[x] = value & 0xff;
    }
  }
  return { width: header.width, height: header.height, channels, pixels };
}

// encodePng(width, height, rgb) -> a PNG buffer (8-bit RGB, filter 0). Only
// for the self-test's synthetic images.
export function encodePng(width, height, rgb) {
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buf) => {
    let c = 0xffffffff;
    for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, body) => {
    const out = Buffer.alloc(12 + body.length);
    out.writeUInt32BE(body.length, 0);
    out.write(type, 4, "ascii");
    body.copy(out, 8);
    out.writeUInt32BE(crc(out.subarray(4, 8 + body.length)), 8 + body.length);
    return out;
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const raw = Buffer.alloc(height * (width * 3 + 1));
  for (let y = 0; y < height; y++) rgb.copy(raw, y * (width * 3 + 1) + 1, y * width * 3, (y + 1) * width * 3);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0)),
  ]);
}

// inkIn(image, box) -> { ink, judged }: the pixels inside the box (inset)
// that differ clearly from the box's dominant colour.
export function inkIn(image, box) {
  const x0 = Math.max(0, Math.round(box.x) + INSET);
  const y0 = Math.max(0, Math.round(box.y) + INSET);
  const x1 = Math.min(image.width, Math.round(box.x + box.width) - INSET);
  const y1 = Math.min(image.height, Math.round(box.y + box.height) - INSET);
  if (x1 - x0 < 4 || y1 - y0 < 4) return { ink: 0, judged: false };
  const { channels, pixels, width } = image;
  const counts = new Map();
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * width + x) * channels;
      const key = (pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2];
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
  }
  let dominant = 0;
  let most = -1;
  for (const [key, n] of counts) if (n > most) { most = n; dominant = key; }
  const dr = dominant >> 16, dg = (dominant >> 8) & 0xff, db = dominant & 0xff;
  let ink = 0;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * width + x) * channels;
      if (Math.abs(pixels[i] - dr) + Math.abs(pixels[i + 1] - dg) + Math.abs(pixels[i + 2] - db) > INK_DISTANCE) ink++;
    }
  }
  return { ink, judged: true };
}

// checkCaptureDir(dir, { pixelsOnly }) -> { checked, failures: [{ file, message }], notes }.
export function checkCaptureDir(dir, { pixelsOnly = false } = {}) {
  const failures = [];
  const notes = [];
  const fail = (file, message) => failures.push({ file, message });
  const records = readVerdicts(dir);
  const images = readdirSync(dir).filter((name) => name.endsWith(".png")).sort();
  if (images.length === 0) fail("", "no PNG in the directory");
  for (const [file, record] of Object.entries(records)) {
    if (record.verdict === "refused") {
      fail(file, `the capture was refused, no image was written: ${(record.failures ?? []).map((f) => `${f.category}: ${f.message}`).join("; ")}`);
    } else if (!images.includes(file)) {
      notes.push(`${file}: recorded, not in the directory`);
    }
  }
  for (const file of images) {
    const record = records[file];
    if (!record || record.verdict !== "pass") {
      fail(file, `no passing verdict recorded in ${VERDICTS_FILE}: the image was not written by a judged capture`);
      continue;
    }
    const bytes = readFileSync(join(dir, file));
    if (!pixelsOnly) {
      const digest = createHash("sha256").update(bytes).digest("hex");
      if (digest !== record.sha256) {
        fail(file, `its bytes are not the ones the capture recorded (sha256 ${digest.slice(0, 12)}…, recorded ${String(record.sha256).slice(0, 12)}…)`);
      }
    }
    let image;
    try {
      image = decodePng(bytes);
    } catch (error) {
      fail(file, `cannot be read: ${error.message}`);
      continue;
    }
    if (record.viewport && image.width !== record.viewport.width) {
      fail(file, `is ${image.width}px wide, the capture's viewport was ${record.viewport.width}px`);
    }
    const boxes = record.contentBoxes ?? [];
    if (boxes.length === 0) fail(file, "the record names no content box to check");
    let judged = 0;
    for (const box of boxes) {
      const { ink, judged: wasJudged } = inkIn(image, box);
      if (!wasJudged) continue;
      judged++;
      if (ink < MIN_INK) {
        fail(file, `draws nothing in its ${box.name} content box (${box.width}x${box.height} at ${box.x},${box.y}): ${ink} ink pixel(s), at least ${MIN_INK} expected`);
      }
    }
    if (boxes.length > 0 && judged === 0) fail(file, "every content box is too small to judge");
  }
  return { checked: images.length, failures, notes };
}
