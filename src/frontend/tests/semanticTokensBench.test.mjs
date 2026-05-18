/**
 * Microbenchmark for the Monaco Nim semantic-tokens provider.
 *
 * Asserts HARD performance budgets — a failing budget fails the process.
 * Numbers map to the spec in HANDOFF / task description:
 *
 *   - Frontend provider: round-trip + decode, 100-line file: P95 < 250ms
 *   - Frontend cache hit: P95 < 5ms
 *
 * Both bounds are easy to meet because the LSP call is mocked; this
 * benchmark guards against regressions in the JS provider machinery
 * (decoding, caching, debounce overhead).  Run with:
 *
 *   node src/frontend/tests/semanticTokensBench.test.mjs
 */

import {
  createNimSemanticTokensProvider,
} from '../languages/nimSemanticTokens.js';

function nowMs() { return performance.now(); }

function percentile(xs, p) {
  const sorted = xs.slice().sort((a, b) => a - b);
  const idx = Math.min(Math.floor((sorted.length - 1) * p), sorted.length - 1);
  return sorted[idx];
}

function buildPayload(n) {
  // ~5 tokens per line, sequential to match a 100-line Nim file.
  const out = [];
  let line = 0;
  for (let i = 0; i < n; i += 1) {
    if (i > 0 && (i % 5) === 0) line += 1;
    const deltaLine = (i > 0 && (i % 5) === 0) ? 1 : 0;
    const deltaStart = ((i % 5) === 0) ? 0 : 8;
    out.push(deltaLine, deltaStart, 4, (i % 23), 0);
  }
  return out;
}

function makeRange(sl, sc, el, ec) {
  return { startLineNumber: sl, startColumn: sc, endLineNumber: el, endColumn: ec };
}
function makeModel(uri, version) {
  return { uri: { toString() { return uri; } }, getVersionId() { return version; } };
}

async function bench(name, iters, fn, p95Target) {
  const samples = new Array(iters);
  for (let i = 0; i < iters; i += 1) {
    const t0 = nowMs();
    await fn(i);
    samples[i] = nowMs() - t0;
  }
  const p50 = percentile(samples, 0.5);
  const p95 = percentile(samples, 0.95);
  const verdict = p95 <= p95Target ? 'PASS' : 'FAIL';
  console.log(name + ',' + p50.toFixed(3) + ',' + p95.toFixed(3) + ',' + p95Target.toFixed(3) + ',' + verdict);
  return { p50, p95, p95Target, verdict };
}

console.log('benchmark,p50_ms,p95_ms,p95_target_ms,verdict');

const results = [];

// 1. Round-trip + decode, 100-line file (~500 tokens).
{
  const payload = buildPayload(500);
  const provider = createNimSemanticTokensProvider({
    sendRequest: async () => ({ data: payload }),
    debounceMs: 0,
  });
  const r = await bench('roundTrip_100lines', 100,
    async (i) => {
      // Use a different version each iteration so cache stays cold.
      const m = makeModel('file:///bench.nim', i + 1);
      await provider.provideDocumentRangeSemanticTokens(m, makeRange(1, 1, 100, 1));
    },
    250);
  results.push(r);
}

// 2. Cache hit (same uri+version+range).
{
  const payload = buildPayload(500);
  const provider = createNimSemanticTokensProvider({
    sendRequest: async () => ({ data: payload }),
    debounceMs: 0,
  });
  const m = makeModel('file:///cache.nim', 1);
  const range = makeRange(1, 1, 100, 1);
  // Warm the cache.
  await provider.provideDocumentRangeSemanticTokens(m, range);
  const r = await bench('cacheHit', 1000,
    async (_i) => {
      await provider.provideDocumentRangeSemanticTokens(m, range);
    },
    5);
  results.push(r);
}

let failed = 0;
for (const r of results) {
  if (r.verdict !== 'PASS') failed += 1;
}
if (failed > 0) {
  console.error('BUDGET VIOLATION in ' + failed + ' benchmark(s)');
  process.exit(2);
}
console.log('ALL BUDGETS PASSED');
