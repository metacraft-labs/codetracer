/**
 * Unit tests for the Monaco DocumentRangeSemanticTokensProvider in
 * `src/frontend/languages/nimSemanticTokens.js`.
 *
 * The provider is pure JS and the langserver dependency is injected via
 * the `sendRequest` adapter, so these tests run without booting Monaco
 * or nimsuggest.
 *
 * Run with:
 *   node src/frontend/tests/semanticTokensProvider.test.mjs
 */

import {
  createNimSemanticTokensProvider,
  lspDataToMonaco,
  NIM_SEMANTIC_TOKEN_LEGEND,
  SEMANTIC_TOKEN_TYPES,
  SEMANTIC_TOKEN_MODIFIERS,
} from '../languages/nimSemanticTokens.js';

let passed = 0;
let failed = 0;
const failures = [];

function test(name, fn) {
  return Promise.resolve(fn()).then(() => {
    passed += 1;
    console.log('\x1b[32m✓\x1b[0m ' + name);
  }, (err) => {
    failed += 1;
    failures.push({ name, err });
    console.log('\x1b[31m✗\x1b[0m ' + name);
    console.log('   \x1b[31m' + (err && err.message ? err.message : err) + '\x1b[0m');
  });
}

function describe(name, fn) {
  console.log('\n\x1b[1m' + name + '\x1b[0m');
  return fn();
}

function assert(cond, msg) { if (!cond) throw new Error(msg || 'Assertion failed'); }
function assertEqual(a, b, msg) {
  if (a !== b) throw new Error(msg || 'Expected ' + JSON.stringify(b) + ' but got ' + JSON.stringify(a));
}

function makeRange(sl, sc, el, ec) {
  return { startLineNumber: sl, startColumn: sc, endLineNumber: el, endColumn: ec };
}

function makeModel(uri, version) {
  return {
    uri: { toString() { return uri; } },
    getVersionId() { return version; },
  };
}

// ---------------------------------------------------------------------------
// lspDataToMonaco
// ---------------------------------------------------------------------------

await describe('lspDataToMonaco', async () => {
  await test('returns Uint32Array of identical contents for valid payload', () => {
    const out = lspDataToMonaco([0, 0, 3, 11, 0]);
    assert(out instanceof Uint32Array);
    assertEqual(out.length, 5);
    assertEqual(out[3], 11);
  });

  await test('returns null for malformed (non-multiple-of-5) data', () => {
    assertEqual(lspDataToMonaco([1, 2, 3]), null);
  });

  await test('returns null for null/undefined input', () => {
    assertEqual(lspDataToMonaco(null), null);
    assertEqual(lspDataToMonaco(undefined), null);
  });

  await test('coerces large values via >>> 0', () => {
    const out = lspDataToMonaco([0, 0, 1, 0, 0xFFFFFFFF]);
    assertEqual(out[4], 0xFFFFFFFF);
  });
});

// ---------------------------------------------------------------------------
// Legend export
// ---------------------------------------------------------------------------

await describe('NIM_SEMANTIC_TOKEN_LEGEND', async () => {
  await test('exports the documented token type order', () => {
    assertEqual(NIM_SEMANTIC_TOKEN_LEGEND.tokenTypes[11], 'function');
    assertEqual(NIM_SEMANTIC_TOKEN_LEGEND.tokenTypes[13], 'macro');
    assertEqual(NIM_SEMANTIC_TOKEN_LEGEND.tokenTypes.length, SEMANTIC_TOKEN_TYPES.length);
  });

  await test('exports readonly as the 3rd modifier (index 2)', () => {
    assertEqual(NIM_SEMANTIC_TOKEN_LEGEND.tokenModifiers[2], 'readonly');
    assertEqual(NIM_SEMANTIC_TOKEN_LEGEND.tokenModifiers.length, SEMANTIC_TOKEN_MODIFIERS.length);
  });
});

// ---------------------------------------------------------------------------
// provideDocumentRangeSemanticTokens — happy path
// ---------------------------------------------------------------------------

await describe('provideDocumentRangeSemanticTokens — round-trip', async () => {
  await test('returns Monaco-shaped data for a canned LSP response', async () => {
    let calls = 0;
    const provider = createNimSemanticTokensProvider({
      sendRequest: async () => {
        calls += 1;
        return { data: [0, 0, 5, 11, 0, 1, 4, 3, 13, 0] };
      },
      debounceMs: 0,
    });
    const result = await provider.provideDocumentRangeSemanticTokens(
      makeModel('file:///a.nim', 1), makeRange(1, 1, 10, 1));
    assert(result, 'expected non-null result');
    assert(result.data instanceof Uint32Array);
    assertEqual(result.data.length, 10);
    assertEqual(result.resultId, undefined);
    assertEqual(calls, 1);
  });
});

// ---------------------------------------------------------------------------
// Cache behaviour
// ---------------------------------------------------------------------------

await describe('provideDocumentRangeSemanticTokens — caching', async () => {
  await test('second request with identical (uri, version, range) reuses cache', async () => {
    let calls = 0;
    const provider = createNimSemanticTokensProvider({
      sendRequest: async () => {
        calls += 1;
        return { data: [0, 0, 5, 11, 0] };
      },
      debounceMs: 0,
    });
    const model = makeModel('file:///cached.nim', 7);
    const range = makeRange(1, 1, 5, 1);
    const r1 = await provider.provideDocumentRangeSemanticTokens(model, range);
    const r2 = await provider.provideDocumentRangeSemanticTokens(model, range);
    assertEqual(calls, 1, 'sendRequest should be called once');
    assert(r1.data instanceof Uint32Array);
    assert(r2.data instanceof Uint32Array);
  });

  await test('changing version invalidates the cache', async () => {
    let calls = 0;
    const provider = createNimSemanticTokensProvider({
      sendRequest: async () => {
        calls += 1;
        return { data: [0, 0, 5, 11, 0] };
      },
      debounceMs: 0,
    });
    const range = makeRange(1, 1, 5, 1);
    await provider.provideDocumentRangeSemanticTokens(
      makeModel('file:///a.nim', 1), range);
    await provider.provideDocumentRangeSemanticTokens(
      makeModel('file:///a.nim', 2), range);
    assertEqual(calls, 2);
  });
});

// ---------------------------------------------------------------------------
// Debounce: many quick requests coalesce
// ---------------------------------------------------------------------------

await describe('provideDocumentRangeSemanticTokens — debounce', async () => {
  await test('5 calls within debounce window produce 1 LSP request', async () => {
    let calls = 0;
    const provider = createNimSemanticTokensProvider({
      sendRequest: async () => {
        calls += 1;
        return { data: [0, 0, 5, 11, 0] };
      },
      debounceMs: 30,
    });
    const model = makeModel('file:///debounce.nim', 1);
    const range = makeRange(1, 1, 5, 1);
    const ps = [];
    for (let i = 0; i < 5; i += 1) {
      ps.push(provider.provideDocumentRangeSemanticTokens(model, range));
    }
    const results = await Promise.all(ps);
    // Every promise resolves to the eventual value (debouncer pattern).
    for (const r of results) assert(r === null || (r && r.data));
    // The point is that we don't issue 5 separate sendRequest calls.
    assert(calls <= 1, 'expected <=1 LSP call, got ' + calls);
  });
});

// ---------------------------------------------------------------------------
// Graceful fallback
// ---------------------------------------------------------------------------

await describe('provideDocumentRangeSemanticTokens — graceful fallback', async () => {
  await test('LSP returns null => provider returns null', async () => {
    const provider = createNimSemanticTokensProvider({
      sendRequest: async () => null,
      debounceMs: 0,
    });
    const r = await provider.provideDocumentRangeSemanticTokens(
      makeModel('file:///null.nim', 1), makeRange(1, 1, 5, 1));
    assertEqual(r, null);
  });

  await test('LSP throws => provider returns null and does not propagate', async () => {
    const provider = createNimSemanticTokensProvider({
      sendRequest: async () => { throw new Error('boom'); },
      debounceMs: 0,
    });
    const r = await provider.provideDocumentRangeSemanticTokens(
      makeModel('file:///throws.nim', 1), makeRange(1, 1, 5, 1));
    assertEqual(r, null);
  });

  await test('Malformed (non-5N) payload => returns null without throwing', async () => {
    const provider = createNimSemanticTokensProvider({
      sendRequest: async () => ({ data: [1, 2, 3] }),
      debounceMs: 0,
    });
    const r = await provider.provideDocumentRangeSemanticTokens(
      makeModel('file:///bad.nim', 1), makeRange(1, 1, 5, 1));
    assertEqual(r, null);
  });

  await test('Missing model.uri / getVersionId is tolerated', async () => {
    const provider = createNimSemanticTokensProvider({
      sendRequest: async () => ({ data: [0, 0, 3, 11, 0] }),
      debounceMs: 0,
    });
    const r = await provider.provideDocumentRangeSemanticTokens(
      { id: 'noUri' }, makeRange(1, 1, 5, 1));
    assert(r, 'expected result with synthetic model id');
    assertEqual(r.data.length, 5);
  });
});

// ---------------------------------------------------------------------------
// Constructor preconditions
// ---------------------------------------------------------------------------

await describe('createNimSemanticTokensProvider — preconditions', async () => {
  await test('throws if sendRequest is not a function', () => {
    let threw = false;
    try { createNimSemanticTokensProvider({}); } catch (_e) { threw = true; }
    assert(threw, 'expected throw');
  });
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

console.log('\n========================================');
console.log('Nim Semantic Tokens Provider Tests');
console.log('========================================');
console.log('Results: \x1b[32m' + passed + ' passed\x1b[0m, \x1b[31m' + failed + ' failed\x1b[0m');
if (failed > 0) {
  for (const f of failures) console.log(' - ' + f.name + ': ' + (f.err && f.err.message));
  process.exit(1);
}
