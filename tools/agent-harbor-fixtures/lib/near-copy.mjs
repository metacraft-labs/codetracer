// Near-copy detection: does a text contain an excerpt of private fixture
// content, even one that was edited, reflowed or reindented?
//
// An exact-copy check (a file's sha256) misses an excerpt; a session-id check
// misses an excerpt that carries no id (a plan's prose, a diff's hunk, a test
// run's output). This module compares *shingles*: every run of `shingleSize`
// consecutive non-whitespace characters. The method is the containment test
// of Broder's resemblance work (A. Z. Broder, "On the resemblance and
// containment of documents", 1997,
// https://doi.org/10.1109/SEQUEN.1997.666900), sampled by the "0 mod p"
// rule so the index stays small, with the shingles hashed by a Rabin-Karp
// rolling hash (https://en.wikipedia.org/wiki/Rabin%E2%80%93Karp_algorithm).
//
// How the parameters were chosen (measured over the real trees and the
// private set):
//
//   - Whitespace is removed before shingling, so reflowing a paragraph,
//     reindenting code or re-serialising JSON with another indent changes
//     no shingle.
//   - So is each line's leader: the whitespace and comment, quote, list and
//     diff markers it starts with (`leaderChars`). Pasting a paragraph into
//     a `##`, `//`, `#`, `--` or `>` comment, or taking a diff's added lines
//     without their `+`, then changes no shingle either. Without this, a
//     marker on every line breaks every shingle that spans a line end: a
//     400-byte excerpt of a private plan pasted into a Nim doc comment went
//     unreported in 11 of 28 places tried (2026-11-04).
//   - `shingleSize` 48: long enough that no shared idiom (an import line, a
//     licence phrase, a JSON key path common to the wire format) fills a
//     region on its own, short enough that a one-character edit leaves most
//     of a few-hundred-byte excerpt's shingles intact.
//   - A finding is a *region*: shingles found in the index whose spans
//     overlap or sit within `mergeGap` characters of each other, merged. The
//     characters its spans COVER (a bridged gap does not count) must reach
//     `minRegion`, and it must hold `minDistinctShingles` different
//     shingles (one shared line repeated down a file is not an excerpt). A
//     one-character edit removes the `shingleSize` shingles that span it and
//     leaves a gap of one character between the spans either side, so the
//     region survives it with one character less; a coincidence of two
//     shared phrases with unrelated text between them does not reach
//     `minRegion`. 200 non-blank characters are about 250 to 330 bytes of
//     prose or indented code; the self-test's shortest plant is 325 bytes.
//   - Measured over the real trees on 2026-11-04 (codetracer a602c8ae9,
//     isonim 239e39f, nim-agents d49813a, nim-agent-harbor 7953355,
//     nim-agents-isonim-viewmodels 2a17d7a, all with this change on top):
//     the largest region anywhere outside what the allowlist allows covered
//     152 characters (a shared .editorconfig), then 147 (a lock file's
//     header) and 136 (a pre-commit configuration); none reaches
//     `minRegion`. The shared files -- `config.nims`, lock files, the
//     pre-commit configuration, a shared test -- hold regions of 208 to
//     6884 because a captured diff of another public repository changes
//     its own copy of them. public-tree-allowlist.json lets each such file
//     share text only with the diff SECTIONS that change a copy of it
//     (`diffs/*#config.nims`, ...): the private diffs are indexed one
//     section per changed file, so a plan, a fleet record or any other
//     hunk pasted into an allowlisted file is still a finding. What such an
//     entry cannot see is the allowed section itself pasted into that file:
//     text of another repository's copy of the same shared file. (Pinning
//     each shared region by digest was tried first and rejected: a routine
//     lock refresh re-shapes the regions of a lock file and turned the
//     check red with nothing leaked.)
//   - Detection floor, measured the same day over the private plans and
//     diffs (about 60 places per file): an unedited 400-byte excerpt is
//     found in 235 of 238 places; with four letters changed at random,
//     in 185 of 238; a 600-byte excerpt with four changed letters in 236
//     of 238. Pasting into a comment does not change these figures (line
//     leaders above). What escapes is an excerpt whose changes fall closer
//     together than `shingleSize`, so that no clean 200-character stretch
//     is left.
//   - A shingle that also occurs in an excluded text (the synthetic set: the
//     wire format's shape vocabulary, published on purpose) is removed from
//     the index, and so is a shingle with fewer than `minDistinct` distinct
//     characters (rules of `-----`, runs of `0000`).

import { createHash } from "node:crypto";

// Hashes are two independent 26-bit polynomial hashes packed into one exact
// double, so the index is a `Map` of numbers. Over the public trees (about
// 2 x 10^7 sampled lookups against about 2 x 10^5 indexed shingles in 2^52
// values) the expected number of chance hits is about 10^-3, and a finding
// needs ten different ones in one place.

export const shingleSize = 48;
export const minRegion = 200;
export const mergeGap = shingleSize;
export const minDistinct = 10;
/** A region must hold this many DIFFERENT private shingles. */
export const minDistinctShingles = 10;
/** Keep the shingles whose second hash is 0 mod (sampleMask + 1). */
export const sampleMask = 3;

// Primes below 2^26 and bases below them: every product in the rolling hash
// stays below 2^53, so plain doubles compute it exactly.
const P1 = 67108859;
const P2 = 67108837;
const B1 = 65599;
const B2 = 31337;

function powMod(base, exp, mod) {
  let r = 1;
  for (let i = 0; i < exp; i++) r = (r * base) % mod;
  return r;
}
const POW1 = powMod(B1, shingleSize - 1, P1);
const POW2 = powMod(B2, shingleSize - 1, P2);

function isSpace(code) {
  if (code <= 32) return true;
  if (code < 0x85) return false;
  return (
    code === 0x85 || code === 0xa0 || code === 0x1680 || (code >= 0x2000 && code <= 0x200a) ||
    code === 0x2028 || code === 0x2029 || code === 0x202f || code === 0x205f || code === 0x3000 || code === 0xfeff
  );
}

/**
 * The characters a line's LEADER is made of besides whitespace: comment
 * markers (`#`, `//`, `;`, `--`, `%`, `!`, the ` * ` of a block comment),
 * quote and table markers (`>`, `|`) and diff markers (`+`, `-`). The leader
 * is dropped from the private text and from the scanned text alike, so both
 * lose the same characters.
 */
const leaderChars = new Set([..."#/;*>!%+-|"].map((c) => c.charCodeAt(0)));

/**
 * `text` without whitespace and without each line's leader, and for each
 * remaining character its offset in `text` (to report a line).
 */
export function flatten(text) {
  const offsets = new Int32Array(text.length);
  const parts = [];
  let n = 0;
  let runStart = -1;
  let atLineStart = true;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code === 10 || code === 13) atLineStart = true;
    else if (atLineStart && !isSpace(code) && !leaderChars.has(code)) atLineStart = false;
    if (isSpace(code) || atLineStart) {
      if (runStart >= 0) {
        parts.push(text.slice(runStart, i));
        runStart = -1;
      }
    } else {
      if (runStart < 0) runStart = i;
      offsets[n++] = i;
    }
  }
  if (runStart >= 0) parts.push(text.slice(runStart));
  return { flat: parts.join(""), offsets: offsets.subarray(0, n) };
}

/**
 * Calls `visit(position, key)` for every SAMPLED shingle of `flat`. This is
 * the one place a shingle is hashed and sampled: the index and the scan both
 * go through it, so they cannot disagree on what a shingle is.
 */
function forEachSampledShingle(flat, visit) {
  const k = shingleSize;
  if (flat.length < k) return;
  let h1 = 0;
  let h2 = 0;
  for (let i = 0; i < k; i++) {
    const c = flat.charCodeAt(i);
    h1 = (h1 * B1 + c) % P1;
    h2 = (h2 * B2 + c) % P2;
  }
  if ((h2 & sampleMask) === 0) visit(0, h1 * 67108864 + h2);
  for (let i = k; i < flat.length; i++) {
    const out = flat.charCodeAt(i - k);
    const c = flat.charCodeAt(i);
    h1 = ((h1 - ((out * POW1) % P1) + P1) * B1 + c) % P1;
    h2 = ((h2 - ((out * POW2) % P2) + P2) * B2 + c) % P2;
    if ((h2 & sampleMask) === 0) visit(i - k + 1, h1 * 67108864 + h2);
  }
}

function distinctAtLeast(flat, start, count) {
  const seen = new Set();
  for (let i = start; i < start + shingleSize; i++) {
    seen.add(flat.charCodeAt(i));
    if (seen.size >= count) return true;
  }
  return false;
}

/**
 * The index of private content: `sources` is a list of `{ name, text }`
 * (the private fixture files), `excluded` a list of texts whose shingles are
 * NOT private (the synthetic set). Returns the index with its counts, so a
 * caller can assert it is not empty.
 */
export function buildNearCopyIndex(sources, excluded = []) {
  const hashes = new Map();
  // For a shingle more than one source holds, the other sources: an
  // allowlist entry may drop a shingle only when EVERY source of it is one
  // the entry allows.
  const alsoIn = new Map();
  const names = [];
  let lowEntropy = 0;
  for (const { name, text } of sources) {
    const id = names.push(name) - 1;
    const { flat } = flatten(text);
    forEachSampledShingle(flat, (pos, key) => {
      if (!distinctAtLeast(flat, pos, minDistinct)) {
        lowEntropy++;
        return;
      }
      const first = hashes.get(key);
      if (first === undefined) hashes.set(key, id);
      else if (first !== id) {
        if (!alsoIn.has(key)) alsoIn.set(key, new Set());
        alsoIn.get(key).add(id);
      }
    });
  }
  let removed = 0;
  for (const text of excluded) {
    forEachSampledShingle(flatten(text).flat, (_pos, key) => {
      alsoIn.delete(key);
      if (hashes.delete(key)) removed++;
    });
  }
  return { hashes, alsoIn, names, lowEntropy, removed, sourceCount: sources.length };
}

/**
 * Every region of `text` made of private shingles that covers at least
 * `minRegion` non-whitespace characters and holds at least
 * `minDistinctShingles` different ones, in the order they occur. A region
 * names the private source most of its shingles came from, the line of
 * `text` it starts on, and `sha256`, the digest of its flattened text (to
 * tell two regions apart in a report).
 *
 * `allowSource(name)`, when given, is an allowlist entry's predicate over
 * source names: a shingle every source of which it accepts is not counted.
 * Sources are as fine as the caller indexed them -- one section of a diff,
 * for instance -- so an entry that lets a shared file share text with the
 * diff hunks of that file's other copies still counts every other private
 * shingle pasted into it.
 */
export function nearCopyRegions(text, index, allowSource = null) {
  if (index.hashes.size === 0) return [];
  const allowed = new Set();
  if (allowSource) index.names.forEach((name, id) => allowSource(name) && allowed.add(id));
  const isAllowed = (key, id) => {
    if (!allowed.has(id)) return false;
    const others = index.alsoIn?.get(key);
    if (others) for (const other of others) if (!allowed.has(other)) return false;
    return true;
  };
  const { flat, offsets } = flatten(text);
  const found = [];
  let region = null;
  const close = () => {
    if (!region) return;
    if (region.covered >= minRegion && region.keys.size >= minDistinctShingles) {
      let source = -1;
      let most = 0;
      for (const [id, n] of region.votes) if (n > most) [source, most] = [id, n];
      found.push({
        start: region.start,
        end: region.end,
        covered: region.covered,
        shingles: region.keys.size,
        source: index.names[source],
        sha256: createHash("sha256").update(flat.slice(region.start, region.end)).digest("hex"),
      });
    }
  };
  forEachSampledShingle(flat, (pos, key) => {
    const id = index.hashes.get(key);
    if (id === undefined || isAllowed(key, id)) return;
    if (region && pos <= region.end + mergeGap) {
      // Spans arrive in increasing order, so only the part of this one past
      // the region's end is newly covered; a gap bridged by `mergeGap` is
      // never counted as covered.
      region.covered += pos + shingleSize - Math.max(region.end, pos);
      region.end = pos + shingleSize;
    } else {
      close();
      region = { start: pos, end: pos + shingleSize, covered: shingleSize, keys: new Set(), votes: new Map() };
    }
    region.keys.add(key);
    region.votes.set(id, (region.votes.get(id) ?? 0) + 1);
  });
  close();
  // Line numbers in one pass over `text`, regions being in order.
  let line = 1;
  let scanned = 0;
  for (const r of found) {
    const at = offsets[r.start];
    for (; scanned < at; scanned++) if (text.charCodeAt(scanned) === 10) line++;
    r.line = line;
  }
  return found;
}

/** The largest region `nearCopyRegions` finds in `text`, or null. */
export function nearCopyRegion(text, index, allowSource = null) {
  let best = null;
  for (const r of nearCopyRegions(text, index, allowSource)) if (!best || r.covered > best.covered) best = r;
  return best;
}
