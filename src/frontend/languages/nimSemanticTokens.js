// Monaco DocumentRangeSemanticTokensProvider for Nim.
//
// Augments the existing monarch tokenizer (`nimLanguage.js`) with semantic
// tokens served by metacraft-labs/langserver's
// `textDocument/semanticTokens/range` route.  The langserver-side legend
// lives in `nim-langserver/semantic_tokens.nim`; if you change either side
// you MUST update the other in the same commit.  The shared
// SEMANTIC_TOKEN_TYPES / SEMANTIC_TOKEN_MODIFIERS arrays below are the
// wire contract.
//
// Performance:
//  - 100-150ms debounce per (uri, version, range).  Monaco re-issues
//    range requests aggressively as the user scrolls; without debounce
//    we'd flood nimsuggest.
//  - Per-document cache keyed by (versionId, range-string).  A cache hit
//    bypasses the LSP roundtrip entirely.  Both caches are bounded by
//    URI count to keep memory predictable.

export const SEMANTIC_TOKEN_TYPES = [
  'namespace', 'type', 'class', 'enum', 'interface', 'struct',
  'typeParameter', 'parameter', 'variable', 'property', 'enumMember',
  'function', 'method', 'macro', 'keyword', 'modifier', 'comment',
  'string', 'number', 'regexp', 'operator', 'decorator', 'label',
];

export const SEMANTIC_TOKEN_MODIFIERS = [
  'declaration', 'definition', 'readonly', 'static', 'deprecated',
  'abstract', 'async', 'modification', 'documentation', 'defaultLibrary',
];

export const NIM_SEMANTIC_TOKEN_LEGEND = {
  tokenTypes: SEMANTIC_TOKEN_TYPES,
  tokenModifiers: SEMANTIC_TOKEN_MODIFIERS,
};

// Debounce window matches GH Copilot / VS Code defaults.  Lower values
// hammer the LSP; higher values feel laggy on fast typing.
const DEBOUNCE_MS = 120;

// Maximum number of cached responses per URI.  The LSP is responsible for
// invalidation by content version; we drop entries from old versions
// proactively.
const MAX_CACHE_PER_URI = 32;

function rangeKey(range) {
  return (
    range.startLineNumber + ':' + range.startColumn + ':' +
    range.endLineNumber + ':' + range.endColumn
  );
}

/**
 * Convert a raw LSP `data: number[]` payload to the Monaco-shaped
 * `Uint32Array`.  Validates length divisibility so a malformed server
 * response doesn't poison the renderer.
 */
export function lspDataToMonaco(rawData) {
  if (!rawData || typeof rawData.length !== 'number') {
    return null;
  }
  if (rawData.length % 5 !== 0) {
    console.warn('[nim semantic tokens] payload length %d is not a multiple of 5', rawData.length);
    return null;
  }
  const out = new Uint32Array(rawData.length);
  for (let i = 0; i < rawData.length; i += 1) {
    out[i] = rawData[i] >>> 0;
  }
  return out;
}

/**
 * Internal per-URI cache.  `Map` insertion order is iteration order which
 * gives us cheap LRU eviction.
 */
class TokenCache {
  constructor() {
    this.byUri = new Map(); // uri -> { version, entries: Map<rangeKey, Uint32Array> }
  }

  invalidate(uri, version) {
    const slot = this.byUri.get(uri);
    if (!slot || slot.version !== version) {
      // Different version => drop everything for this URI.
      this.byUri.set(uri, { version, entries: new Map() });
    }
  }

  get(uri, version, range) {
    const slot = this.byUri.get(uri);
    if (!slot || slot.version !== version) return null;
    return slot.entries.get(rangeKey(range)) || null;
  }

  set(uri, version, range, data) {
    this.invalidate(uri, version);
    const slot = this.byUri.get(uri);
    if (slot.entries.size >= MAX_CACHE_PER_URI) {
      const oldestKey = slot.entries.keys().next().value;
      slot.entries.delete(oldestKey);
    }
    slot.entries.set(rangeKey(range), data);
  }

  clear() {
    this.byUri.clear();
  }
}

/**
 * Debounce gate.  Only the latest `work` per key actually runs; every
 * caller that arrived during the debounce window receives the result of
 * that single run.  Older callers don't get a stale promise — they get
 * the same fresh value as the newest caller.
 */
class Debouncer {
  constructor(ms) {
    this.ms = ms;
    this.pending = new Map(); // key -> { timer, waiters: Function[][] }
  }

  schedule(key, work) {
    return new Promise((resolve, reject) => {
      const existing = this.pending.get(key);
      if (existing) {
        clearTimeout(existing.timer);
        existing.waiters.push([resolve, reject]);
        existing.work = work; // pick up the latest closure too
        existing.timer = setTimeout(() => this._fire(key), this.ms);
        return;
      }
      const slot = { timer: 0, waiters: [[resolve, reject]], work };
      slot.timer = setTimeout(() => this._fire(key), this.ms);
      this.pending.set(key, slot);
    });
  }

  async _fire(key) {
    const slot = this.pending.get(key);
    if (!slot) return;
    this.pending.delete(key);
    try {
      const value = await slot.work();
      for (const [res, _rej] of slot.waiters) res(value);
    } catch (err) {
      for (const [_res, rej] of slot.waiters) rej(err);
    }
  }
}

/**
 * Build a Monaco DocumentRangeSemanticTokensProvider for Nim.
 *
 * @param {Object} options
 * @param {Function} options.sendRequest - async (uri, range) => raw LSP response
 * @param {number} [options.debounceMs] - override debounce window
 */
export function createNimSemanticTokensProvider({ sendRequest, debounceMs }) {
  if (typeof sendRequest !== 'function') {
    throw new Error('createNimSemanticTokensProvider: sendRequest is required');
  }
  const cache = new TokenCache();
  const debouncer = new Debouncer(debounceMs != null ? debounceMs : DEBOUNCE_MS);

  return {
    getLegend() {
      return NIM_SEMANTIC_TOKEN_LEGEND;
    },

    async provideDocumentRangeSemanticTokens(model, range, _cancellationToken) {
      const uri = model.uri ? model.uri.toString() : (model.id || 'unknown');
      const version = typeof model.getVersionId === 'function' ? model.getVersionId() : 0;

      const cached = cache.get(uri, version, range);
      if (cached) {
        return { data: cached, resultId: undefined };
      }

      const key = uri + '@' + version + '#' + rangeKey(range);

      try {
        const data = await debouncer.schedule(key, async () => {
          // Re-check cache after debounce window — a sibling request may
          // have populated it while we waited.
          const lateHit = cache.get(uri, version, range);
          if (lateHit) return lateHit;

          let response = null;
          try {
            response = await sendRequest(uri, range);
          } catch (err) {
            // Network / server error: let Monaco fall back to monarch.
            console.warn('[nim semantic tokens] LSP request failed', err && err.message);
            return null;
          }
          if (!response || !response.data) return null;
          const monacoData = lspDataToMonaco(response.data);
          if (monacoData) cache.set(uri, version, range, monacoData);
          return monacoData;
        });
        if (!data) return null;
        return { data, resultId: undefined };
      } catch (err) {
        console.warn('[nim semantic tokens] provider error', err && err.message);
        return null;
      }
    },

    releaseDocumentSemanticTokens(_resultId) {
      // We don't expose result-ids (no delta protocol on our side).
    },

    // Exposed for tests.
    _cache: cache,
  };
}

/**
 * Register the provider with Monaco.  Caller supplies the `sendRequest`
 * adapter so we don't have to take a direct dependency on the LSP router
 * from this module — keeps the unit tests trivial to mock.
 */
export function registerNimSemanticTokensProvider(monaco, sendRequest) {
  const provider = createNimSemanticTokensProvider({ sendRequest });
  monaco.languages.registerDocumentRangeSemanticTokensProvider('nim', provider);
  return provider;
}
