//! Per-trace Source Map V3 cache and translation glue.
//!
//! Owns the recordings's `SourcemapIndex` per registered source path and
//! exposes the translated `(file, line, column)` triple that the DAP
//! `stackTrace` and any future `source` handlers need.  Sits between
//! [`crate::ctfs_trace_reader::CTFSTraceReader`] (the recorded paths.dat
//! / step records source) and [`crate::dap_handler::Handler`] (the
//! consumer that builds DAP responses).
//!
//! Spec: `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P3.
//!
//! ## Architecture
//!
//! * **Single source of truth, server-side.** The replay-server applies
//!   the translation once; every UI surface (DAP `stackTrace`, future
//!   DAP `source`, breakpoint editor) gets the translated coordinates
//!   without each having to re-implement the lookup.
//!
//! * **Per-trace cache.** The cache lives on [`crate::dap_handler::Handler`]
//!   alongside `macro_sourcemaps`, scoped to the recording's lifetime.
//!   Repeated lookups are O(log n) thanks to `sourcemap` crate's
//!   `lookup_token`; we do not flatten to a HashMap.
//!
//! * **Best-effort.** Translation is opportunistic — when no sourcemap
//!   is found, parsing fails, or the segment is sparse, the original
//!   recorded coordinates flow through unchanged.  This guarantees
//!   recordings without sourcemaps keep working exactly as before.
//!
//! ## Configuration
//!
//! The `CT_SOURCEMAP_TRANSLATION` environment variable provides a hard
//! kill-switch.  Set to `0`, `off`, or `false` to disable trace-open
//! sourcemap discovery and translation.  Useful when:
//!
//! 1. A buggy sourcemap is misleading the user (bisecting backwards).
//! 2. The user explicitly wants to debug the minified form.
//! 3. Performance regression hunting at trace-open time.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use log::{debug, info, warn};
use sourcemap_translate::{OriginalPos, SourcemapIndex, discover_sourcemap_for};

use codetracer_trace_types::PathId;

use crate::autoformat::{self, AutoFormatError};
use crate::rename_list::{RenameList, Scope};

/// One translated location returned by [`SourcemapCache::translate`].
///
/// All coordinates are 1-indexed and ready to flow into DAP responses.
#[derive(Debug, Clone)]
pub struct TranslatedLocation {
    /// Absolute path to the original source file.  When the sourcemap
    /// has inline `sourcesContent[i]`, the cache also writes the
    /// content to this path so the UI's filesystem-based source reader
    /// can pick it up — see [`SourcemapCache::translate_for_path`] for
    /// the lazy materialisation contract.
    pub path: String,
    /// 1-indexed line in the original source.
    pub line: u32,
    /// 1-indexed column in the original source.
    pub column: u32,
    /// Original identifier name from the sourcemap's `names[]`, if any.
    /// Groundwork for §P3.5 / §P5 renaming — exposed for downstream
    /// consumers; the milestone does not yet wire it into responses.
    pub name: Option<String>,
}

/// Per-trace Source Map V3 cache.
///
/// Built once during trace open, then queried on every stackTrace /
/// source-line response.
#[derive(Default, Debug)]
pub struct SourcemapCache {
    /// Indexed by recorded `PathId` for O(1) lookup at stackTrace
    /// time.  Recordings register paths via the CTFS path stream; we
    /// snapshot the IDs that resolved to a parseable sourcemap.
    /// `Arc` for cheap cloning into the by-path index (a
    /// `SourcemapIndex` wraps a parsed `sourcemap::SourceMap` which
    /// is intentionally not `Clone` — the underlying memory is large
    /// and shared by reference is the natural fit).
    by_path_id: HashMap<PathId, Arc<SourcemapIndex>>,
    /// Indexed by absolute path string — useful when the consumer
    /// only has the resolved path (e.g. from `Location.path`) and
    /// doesn't carry the PathId through the call.  Mirrors
    /// `by_path_id` by sharing the same Arc, so updates stay
    /// consistent without double-storing the parsed sourcemap.
    by_path: HashMap<String, Arc<SourcemapIndex>>,
    /// Tracks which `<original-source>` files this cache has already
    /// materialised on disk from inline `sourcesContent`.  Prevents
    /// the lazy writer from clobbering user-edited files between
    /// queries within the same session.
    materialised: HashMap<String, ()>,
    /// §P4 — per-path auto-format cache.  Keyed by the recorded
    /// absolute path string.  Each entry is either:
    ///
    /// * `Some(Arc<AutoFormatLookup>)` — auto-format succeeded; the
    ///   formatted content has been materialised to disk under
    ///   `cache_dir/sourcemap-translate/autoformat_<sanitised>` and the
    ///   position map is ready to project recorded coordinates.
    /// * `None` — auto-format was attempted and **failed** (no tool,
    ///   not minified, unknown extension, subprocess error).  Keeping
    ///   the negative entry around prevents us from re-running the
    ///   subprocess on every hot-loop translation call for the same
    ///   pass-through path.
    autoformat_by_path: HashMap<String, Option<Arc<AutoFormatLookup>>>,
    /// §P5 — user-provided variable rename list.  Loaded once at
    /// trace open from `<recording-dir>/renames.toml` (or from a CLI-
    /// supplied path) and consulted by [`SourcemapCache::resolve_name`]
    /// when the value-stream renderer wants the user-facing name for a
    /// recorded binding.  `None` when no rename list was supplied (or
    /// `CT_RENAME_LIST=0` disabled the feature).
    ///
    /// `Arc` so we can hand a cheap snapshot to consumers without
    /// re-cloning the parsed entries on every value-render call.
    rename_list: Option<Arc<RenameList>>,
}

/// One auto-formatted path's projected source + materialised file path.
///
/// Built once per recorded minified path the first time
/// [`SourcemapCache::translate_via_autoformat`] is asked about it;
/// cached for the rest of the session so the formatter subprocess
/// runs at most once per source.
#[derive(Debug)]
pub struct AutoFormatLookup {
    /// Absolute path to the materialised formatted-source sidecar on
    /// disk — what the UI's filesystem reader picks up.  When the
    /// cache was built without a `cache_dir` (e.g. test fixtures
    /// without a trace dir) this falls back to the original recorded
    /// path so the caller can still surface the projected
    /// `(line, column)` pair.
    pub formatted_path: String,
    /// Synthetic line-only position map.  Built by
    /// [`autoformat::PositionMap::from_diff`].
    pub position_map: autoformat::PositionMap,
}

/// `true` when the `CT_SOURCEMAP_TRANSLATION` env var requests the
/// trace-open hook be skipped.
///
/// Accepted "off" values (case-insensitive): `0`, `off`, `false`, `no`.
/// Anything else (including unset) means "on" — the default.
pub fn translation_enabled() -> bool {
    match std::env::var("CT_SOURCEMAP_TRANSLATION") {
        Ok(v) => {
            let lower = v.trim().to_ascii_lowercase();
            !matches!(lower.as_str(), "0" | "off" | "false" | "no")
        }
        Err(_) => true,
    }
}

impl SourcemapCache {
    /// Build a fresh empty cache.
    pub fn new() -> Self {
        Self::default()
    }

    /// `true` when the cache has no entries — useful as a fast-path
    /// guard in hot DAP handlers so they don't pay the
    /// (Path, line, col) string-formatting tax when no sourcemap was
    /// discovered.
    pub fn is_empty(&self) -> bool {
        self.by_path_id.is_empty()
    }

    /// Total number of recorded paths that have an attached sourcemap.
    pub fn len(&self) -> usize {
        self.by_path_id.len()
    }

    /// Discover and load a sourcemap for the given recorded path.
    ///
    /// The `absolute_path` is the on-disk path the recording observed
    /// (typically `<workdir>/<recorded relative>`).  Resolution rules
    /// match what browsers and DevTools do:
    ///
    /// 1. Sibling `<absolute_path>.map`.
    /// 2. `//# sourceMappingURL=` comment in the source file (both
    ///    file paths and inline base64 `data:` URLs are recognised).
    ///
    /// On success, the sourcemap is cached under both the `PathId` and
    /// the absolute path string.  Failures are logged at `warn!` and
    /// the cache is left unchanged — translation will fall through to
    /// the recorded coordinates.
    pub fn try_load(&mut self, path_id: PathId, absolute_path: &Path) {
        match discover_sourcemap_for(absolute_path) {
            Ok(Some(idx)) => {
                info!(
                    "sourcemap_cache: loaded sourcemap for {} → {} source(s)",
                    absolute_path.display(),
                    idx.sources().len()
                );
                let key = absolute_path.display().to_string();
                let shared = Arc::new(idx);
                // Two views over the same parsed sourcemap — PathId
                // is the hot stackTrace path; the absolute-path string
                // index supports consumers that don't carry the
                // PathId through (e.g. ad-hoc `source_content`
                // lookups from a `Location.path`).
                self.by_path_id.insert(path_id, Arc::clone(&shared));
                self.by_path.insert(key, shared);
            }
            Ok(None) => {
                debug!("sourcemap_cache: no sourcemap for {}", absolute_path.display());
            }
            Err(e) => {
                warn!(
                    "sourcemap_cache: failed to load sourcemap for {}: {e}",
                    absolute_path.display()
                );
            }
        }
    }

    /// §P6.2 — install an externally-built [`SourcemapIndex`] under the
    /// given `(PathId, absolute_path)` key.
    ///
    /// Used by the `srcviews.dat` loader to plug a recorder-baked
    /// alternate view's Source Map V3 into the existing translation
    /// pipeline.  The cache stores the index under both keys (sharing
    /// one `Arc`) so the hot `translate_for_path` / `translate` lookups
    /// hit identical data regardless of whether the caller has the
    /// `PathId` or the path string on hand.
    ///
    /// Calls REPLACE any existing entry under the same keys — `srcviews`
    /// records are explicitly recorder-baked and the spec says they
    /// take precedence over any sibling `<path>.map` discovered by the
    /// §P3 loader.  The dispatcher therefore calls
    /// [`Handler::load_source_views`](crate::dap_handler::Handler::load_source_views)
    /// AFTER [`Handler::load_sourcemaps`](crate::dap_handler::Handler::load_sourcemaps)
    /// so the srcviews entries overwrite the sibling-map ones.
    pub fn install_index(&mut self, path_id: PathId, absolute_path: &str, idx: SourcemapIndex) {
        let shared = Arc::new(idx);
        self.by_path_id.insert(path_id, Arc::clone(&shared));
        self.by_path.insert(absolute_path.to_string(), shared);
    }

    /// Translate a recorded generated position by `PathId`.
    ///
    /// Returns `None` when the path has no associated sourcemap, the
    /// segment is sparse, or the segment has no source.  Callers
    /// should fall back to the recorded position in that case.
    ///
    /// The returned [`TranslatedLocation::path`] is an absolute on-disk
    /// path: either the resolved `sources[i]` entry, or — when the
    /// sourcemap has inline `sourcesContent` and the resolved path
    /// doesn't exist on disk — a lazily-materialised sidecar inside
    /// the trace's cache directory.
    pub fn translate(
        &mut self,
        path_id: PathId,
        line: u32,
        column: u32,
        cache_dir: Option<&Path>,
    ) -> Option<TranslatedLocation> {
        let idx = self.by_path_id.get(&path_id)?;
        translate_with_index(idx, line, column, cache_dir, &mut self.materialised)
    }

    /// Translate using an absolute path key.  Same contract as
    /// [`SourcemapCache::translate`].
    pub fn translate_for_path(
        &mut self,
        path: &str,
        line: u32,
        column: u32,
        cache_dir: Option<&Path>,
    ) -> Option<TranslatedLocation> {
        let idx = self.by_path.get(path)?;
        translate_with_index(idx, line, column, cache_dir, &mut self.materialised)
    }

    /// §P4 — lazy auto-format fallback for a recorded path.
    ///
    /// Called by [`crate::dap_handler::Handler::apply_sourcemap_translation`]
    /// when the sourcemap path returned nothing (the recorded source
    /// has no sibling `.map` and no `//# sourceMappingURL=`).
    ///
    /// Behaviour:
    ///
    /// * **First call for a path**: read the file, run the
    ///   minified-heuristic, and — if it qualifies — invoke
    ///   [`autoformat::autoformat`].  Cache the result (positive *or*
    ///   negative) under the absolute path string.  Materialise the
    ///   formatted content as a sidecar under
    ///   `cache_dir/sourcemap-translate/autoformat_<sanitised-name>`.
    ///
    /// * **Subsequent calls**: serve from the in-memory cache.  The
    ///   formatter subprocess never runs twice for the same path
    ///   within a session.
    ///
    /// Returns `None` when the path:
    /// * Doesn't exist on disk.
    /// * Doesn't look minified.
    /// * The formatter isn't installed / failed / timed out.
    /// * The position map projection didn't anchor the recorded line.
    ///
    /// In every `None` case the caller falls through to the recorded
    /// `(path, line, column)` — auto-format is best-effort and never
    /// destructive.
    pub fn translate_via_autoformat(
        &mut self,
        recorded_path: &str,
        line: u32,
        column: u32,
        cache_dir: Option<&Path>,
    ) -> Option<TranslatedLocation> {
        if !autoformat::autoformat_enabled() {
            return None;
        }

        // First, hit the cache.  Avoid double-format on repeat lookups
        // for both positive and negative outcomes.
        if let Some(entry) = self.autoformat_by_path.get(recorded_path) {
            return entry
                .as_ref()
                .and_then(|lookup| project_through_autoformat(lookup, line, column));
        }

        // Not cached — attempt the lazy build.
        let result = self.build_autoformat_entry(recorded_path, cache_dir);
        // Cache the outcome (positive or negative).
        self.autoformat_by_path
            .insert(recorded_path.to_string(), result.clone());
        result.and_then(|lookup| project_through_autoformat(&lookup, line, column))
    }

    /// Look up an existing auto-format entry without triggering a new
    /// subprocess.  Used by callers that want the formatted-source
    /// path (e.g. DAP `source` content delivery) without rerunning
    /// the heuristic.
    pub fn autoformat_lookup(&self, recorded_path: &str) -> Option<Arc<AutoFormatLookup>> {
        self.autoformat_by_path.get(recorded_path).and_then(|e| e.clone())
    }

    /// Reset just the auto-format cache.  Exposed so tests can switch
    /// `CT_AUTOFORMAT` between calls without stale negative entries
    /// suppressing the new behaviour.
    pub fn reset_autoformat_cache(&mut self) {
        self.autoformat_by_path.clear();
    }

    /// Lazy builder shared by [`Self::translate_via_autoformat`].
    /// Returns `Some(lookup)` on a usable auto-format, `None` for the
    /// negative cache.
    fn build_autoformat_entry(
        &mut self,
        recorded_path: &str,
        cache_dir: Option<&Path>,
    ) -> Option<Arc<AutoFormatLookup>> {
        let path = Path::new(recorded_path);
        if !path.is_file() {
            debug!("autoformat: recorded path is not a file on disk: {recorded_path}");
            return None;
        }
        let content = match std::fs::read_to_string(path) {
            Ok(c) => c,
            Err(e) => {
                debug!("autoformat: failed to read {recorded_path}: {e}");
                return None;
            }
        };

        let threshold = autoformat::minified_threshold();
        if !autoformat::looks_minified(&content, threshold) {
            debug!("autoformat: source does not look minified (avg line < {threshold} chars): {recorded_path}");
            return None;
        }

        let formatted = match autoformat::autoformat(path, &content) {
            Ok(r) => r,
            Err(AutoFormatError::NoTool) => {
                info!("autoformat: no formatter on PATH; skipping {recorded_path}");
                return None;
            }
            Err(AutoFormatError::Timeout) => {
                warn!("autoformat: formatter timed out on {recorded_path}");
                return None;
            }
            Err(e) => {
                warn!("autoformat: failed for {recorded_path}: {e}");
                return None;
            }
        };

        // Materialise the formatted content under the trace's cache
        // directory if one was configured — gives the UI a real file
        // path to read.  Without a cache_dir we still build the
        // position map and surface the projected `(line, col)`, but
        // the path the caller sees is the recorded one.
        let formatted_path = match cache_dir {
            Some(dir) => materialise_autoformat(dir, recorded_path, &formatted.formatted_content)
                .unwrap_or_else(|| recorded_path.to_string()),
            None => recorded_path.to_string(),
        };

        Some(Arc::new(AutoFormatLookup {
            formatted_path,
            position_map: formatted.position_map,
        }))
    }

    /// Return the inline `sourcesContent[i]` for an original source
    /// path, looking across all loaded sourcemaps.
    ///
    /// `original_source` is the `OriginalPos::source` string returned
    /// by a previous `translate` call.  The match is done against
    /// every loaded sourcemap's `sources[]` list because the original
    /// source might be reached through any minified path that the
    /// sourcemap covers.
    pub fn source_content_for(&self, original_source: &str) -> Option<String> {
        for idx in self.by_path_id.values() {
            let idx: &SourcemapIndex = idx.as_ref();
            if let Some(content) = idx.source_content(original_source) {
                return Some(content.to_string());
            }
        }
        None
    }

    /// §P5 — install a user-provided rename list.
    ///
    /// Replaces any existing rename list.  Pass `None` to clear.
    /// Called once at trace-open time after [`SourcemapCache::try_load`]
    /// has finished — see
    /// [`crate::dap_handler::Handler::load_rename_list`].
    pub fn set_rename_list(&mut self, list: Option<RenameList>) {
        self.rename_list = list.map(Arc::new);
    }

    /// `true` when a non-empty rename list is installed.
    pub fn has_rename_list(&self) -> bool {
        match &self.rename_list {
            Some(l) => !l.is_empty(),
            None => false,
        }
    }

    /// Read-only access to the installed rename list — useful for
    /// tests and diagnostics surfacing the parsed entries without
    /// going through the resolver.
    pub fn rename_list(&self) -> Option<&RenameList> {
        self.rename_list.as_deref()
    }

    /// §P5 — resolve a recorded binding's user-facing name.
    ///
    /// Composition rules (spec §P5):
    ///
    /// 1. **User rename list** wins on conflict — explicit > inferred.
    /// 2. **Sourcemap V3 `names[]`** confirms otherwise un-renamed
    ///    bindings: when the sourcemap's name table contains
    ///    `minified_name`, the resolver echoes it back, signalling
    ///    that the recorded name is already a known original name
    ///    (i.e. the bundle preserved it).
    /// 3. Returns `None` for unknown bindings — callers surface the
    ///    recorded name unchanged in that case.
    ///
    /// ## File-key matching
    ///
    /// The recorded path string is often an absolute path
    /// (e.g. `/home/me/proj/lodash.min.js`) while the user-facing
    /// rename list keys off the bundle name as the user wrote it
    /// (e.g. `lodash.min.js`).  The resolver tries the recorded path
    /// verbatim first, then the file's basename — that way both
    /// `file = "/abs/path/lodash.min.js"` and `file = "lodash.min.js"`
    /// in the TOML resolve cleanly without forcing every author to
    /// pin an absolute path.
    ///
    /// `file` is the recorded path string (absolute or relative);
    /// `scope_hint` narrows the lookup to a function or block scope
    /// when available; `minified_name` is the recorded binding name.
    ///
    /// Back-compat wrapper for callers that don't yet carry a
    /// `(line, col)` pair from the surrounding step.  Internally this
    /// delegates to [`SourcemapCache::resolve_name_at_position`] with
    /// the **sentinel position `(0, 0)`**, which tells the per-position
    /// branch to short-circuit — preserving the P5 contract where the
    /// resolver only consults the user list + `names[]` membership.
    ///
    /// New code that has access to the step's `(line, col)` should
    /// prefer [`SourcemapCache::resolve_name_at_position`] directly so
    /// the per-segment `name_index` branch can recover original
    /// identifier names from the sourcemap.
    pub fn resolve_name(&self, file: &str, scope_hint: Option<&Scope>, minified_name: &str) -> Option<String> {
        // Sentinel `(0, 0)` — position lookup is suppressed.  See
        // `resolve_name_at_position` for the gating logic.
        self.resolve_name_at_position(file, 0, 0, scope_hint, minified_name)
    }

    /// §P6.4 — position-aware resolver.
    ///
    /// Composition rules:
    ///
    /// 1. **User rename list** (scope-aware) — explicit > inferred.
    /// 2. **Per-position sourcemap segment lookup** — when a sourcemap
    ///    is loaded for `file`, ask [`SourcemapIndex::translate`] for
    ///    the segment covering `(line, col)`.  When the segment carries
    ///    a `name_index`, the sourcemap crate returns the resolved
    ///    original-side name as [`OriginalPos::name`]; we surface it
    ///    directly.  This is what recovers `userId` from a minified
    ///    `a` *at the position where it appears in the bundle*.
    /// 3. **Sourcemap V3 `names[]` membership fallback** — when the
    ///    per-position lookup didn't yield a name (sparse segment, or
    ///    the segment has no `name_index`), preserve the P5 behaviour:
    ///    iterate every loaded sourcemap's `names[]` and, if any
    ///    contains `minified_name`, echo it back as a "blessed" name.
    /// 4. `None` — caller surfaces the recorded name unchanged.
    ///
    /// ## Position sentinel
    ///
    /// `(line=0, col=0)` is a **sentinel** that suppresses the
    /// per-position branch entirely — the resolver behaves exactly
    /// like the P5 wrapper.  This is what
    /// [`SourcemapCache::resolve_name`] uses internally and what
    /// callers without real position info should pass.
    ///
    /// Otherwise `(line, col)` are 1-indexed and refer to the
    /// **generated** / minified-bundle coordinates from the
    /// surrounding step.
    pub fn resolve_name_at_position(
        &self,
        file: &str,
        line: u32,
        col: u32,
        scope_hint: Option<&Scope>,
        minified_name: &str,
    ) -> Option<String> {
        // Step 1 — user list (explicit wins).
        if let Some(list) = &self.rename_list {
            // Try the recorded path verbatim, then the basename as a
            // fallback.  We deliberately do not normalise both sides
            // (e.g. canonicalising the recorded path) — the TOML
            // author's choice is what determines the key.
            if let Some(renamed) = list.lookup(file, scope_hint, minified_name) {
                return Some(renamed.to_string());
            }
            let basename = std::path::Path::new(file).file_name().and_then(|s| s.to_str());
            if let Some(bn) = basename
                && bn != file
                && let Some(renamed) = list.lookup(bn, scope_hint, minified_name)
            {
                return Some(renamed.to_string());
            }
        }

        // Step 2 — per-position sourcemap segment lookup.
        //
        // Gated on `(line, col) != (0, 0)` — the back-compat
        // [`SourcemapCache::resolve_name`] wrapper passes the `(0, 0)`
        // sentinel to suppress this branch, preserving the P5
        // contract.  When the caller supplies real position info we
        // ask the sourcemap for the original-side name attached to
        // the segment covering that position.
        //
        // File-key matching mirrors the way `try_load` indexes the
        // cache — `by_path` is keyed off the recorded absolute path
        // string the trace observed.  We try the path verbatim first;
        // if that doesn't hit, we fall back to scanning every loaded
        // sourcemap.  The scan handles the case where the renderer
        // keyed off a slightly different path representation (e.g.
        // canonicalised vs. recorded).
        if line != 0 && col != 0 {
            if let Some(idx) = self.by_path.get(file) {
                let idx: &SourcemapIndex = idx.as_ref();
                if let Some(pos) = idx.translate(line, col)
                    && let Some(name) = pos.name
                {
                    return Some(name);
                }
            } else {
                for idx in self.by_path.values() {
                    let idx: &SourcemapIndex = idx.as_ref();
                    if let Some(pos) = idx.translate(line, col)
                        && let Some(name) = pos.name
                    {
                        return Some(name);
                    }
                }
            }
        }

        // Step 3 — sourcemap V3 `names[]` membership confirmation
        // fallback (P5 behaviour).  When the per-position branch
        // didn't recover a name (sentinel suppressed, sparse segment,
        // or a segment without a `name_index`), fall back to the
        // coarse-grained membership test: if `minified_name` appears
        // anywhere in any loaded sourcemap's `names[]`, echo it back
        // as a "blessed" name.
        for idx in self.by_path_id.values() {
            let idx: &SourcemapIndex = idx.as_ref();
            if idx.has_name(minified_name) {
                return Some(minified_name.to_string());
            }
        }
        None
    }
}

/// Internal: perform a translation against a single sourcemap index
/// and materialise the original source content on disk if necessary.
fn translate_with_index(
    idx: &SourcemapIndex,
    line: u32,
    column: u32,
    cache_dir: Option<&Path>,
    materialised: &mut HashMap<String, ()>,
) -> Option<TranslatedLocation> {
    // CTFS column may be 0 when the recorder didn't capture column
    // information.  In that case treat it as "start of line" (col=1)
    // so the sourcemap lookup still returns the first segment.
    let col = if column == 0 { 1 } else { column };
    let line = if line == 0 { 1 } else { line };
    let pos = idx.translate(line, col)?;

    let resolved = resolve_original_path(idx, &pos, cache_dir, materialised);
    Some(TranslatedLocation {
        path: resolved,
        line: pos.line,
        column: pos.column,
        name: pos.name,
    })
}

/// Resolve a sourcemap's `sources[i]` entry to an absolute on-disk
/// path, lazily writing the inline `sourcesContent[i]` to a sidecar
/// when the resolved path doesn't already exist.
///
/// The sidecar lives under `cache_dir/sourcemap-translate/<sources[i]>`
/// when a `cache_dir` is provided.  When no `cache_dir` is configured
/// we just return the unresolved string — the consumer can still use
/// the translated `(line, column)` even without a real file path.
fn resolve_original_path(
    idx: &SourcemapIndex,
    pos: &OriginalPos,
    cache_dir: Option<&Path>,
    materialised: &mut HashMap<String, ()>,
) -> String {
    // First preference: a real on-disk path the sourcemap resolves to.
    if let Some(p) = idx.resolve_source_path(&pos.source) {
        if p.is_file() {
            return p.display().to_string();
        }
        // Path resolves but no file on disk — try the inline content
        // materialisation path below before falling back.
        if let (Some(content), Some(cache_root)) = (idx.source_content(&pos.source), cache_dir)
            && let Some(materialised_path) = materialise_original(cache_root, &pos.source, content, materialised)
        {
            return materialised_path;
        }
        // No content to write — return the unresolved-but-typed path
        // anyway so the UI shows the expected file name.  The user
        // sees "file not found" in the editor pane, which is correct
        // and informative.
        return p.display().to_string();
    }
    // Fall-through: webpack://-style URL or other unresolvable form.
    // Try inline content materialisation by source name only.
    if let (Some(content), Some(cache_root)) = (idx.source_content(&pos.source), cache_dir)
        && let Some(materialised_path) = materialise_original(cache_root, &pos.source, content, materialised)
    {
        return materialised_path;
    }
    pos.source.clone()
}

/// Write the inline `sourcesContent[i]` value to a sidecar file under
/// `cache_dir/sourcemap-translate/`, return the absolute path.
///
/// Idempotent: the first call writes the file, subsequent calls for
/// the same logical source name return the cached path without
/// rewriting.  We do NOT clobber existing files — if the path already
/// exists on disk and we haven't written it ourselves, we leave it
/// alone (defensive: the user might be editing the original source).
fn materialise_original(
    cache_dir: &Path,
    logical_name: &str,
    content: &str,
    materialised: &mut HashMap<String, ()>,
) -> Option<String> {
    let cache_root = cache_dir.join("sourcemap-translate");
    if std::fs::create_dir_all(&cache_root).is_err() {
        return None;
    }
    // Flatten the logical name (which may contain ../ or absolute
    // path segments) into a safe filename to avoid path traversal.
    // We preserve the basename for legibility.
    let safe_name = sanitize_for_cache(logical_name);
    let out_path = cache_root.join(safe_name);

    if materialised.contains_key(&out_path.display().to_string()) {
        return Some(out_path.display().to_string());
    }

    // Only write once: skip if file already exists.
    if out_path.exists() {
        materialised.insert(out_path.display().to_string(), ());
        return Some(out_path.display().to_string());
    }
    match std::fs::write(&out_path, content.as_bytes()) {
        Ok(_) => {
            materialised.insert(out_path.display().to_string(), ());
            Some(out_path.display().to_string())
        }
        Err(e) => {
            warn!(
                "sourcemap_cache: could not materialise {} → {}: {e}",
                logical_name,
                out_path.display()
            );
            None
        }
    }
}

/// §P4 — project a recorded `(line, column)` through the cached
/// auto-format lookup, returning a [`TranslatedLocation`] pointing at
/// the materialised formatted-source sidecar.
///
/// Falls back to `None` when the line wasn't anchored — the caller
/// then surfaces the recorded coordinates unchanged.
fn project_through_autoformat(lookup: &Arc<AutoFormatLookup>, line: u32, column: u32) -> Option<TranslatedLocation> {
    let (fmt_line, fmt_col) = lookup.position_map.project(line, column)?;
    Some(TranslatedLocation {
        path: lookup.formatted_path.clone(),
        line: fmt_line,
        column: fmt_col,
        // Auto-format preserves bindings (it only reflows whitespace);
        // there are no original `names[]` to attribute here.
        name: None,
    })
}

/// §P4 — write the formatter's output to
/// `<cache_dir>/sourcemap-translate/autoformat_<sanitised-name>`.
///
/// Idempotent: returns the path if the file already exists with the
/// same content; rewrites on content mismatch so re-running with a
/// newer formatter version is reflected in the on-disk view.
///
/// The `autoformat_` prefix on the basename distinguishes these
/// sidecars from the P3 materialised inline-sourcesContent files
/// (which use no prefix) so the two paths can coexist in the same
/// cache directory without colliding.
fn materialise_autoformat(cache_dir: &Path, recorded_path: &str, formatted_content: &str) -> Option<String> {
    let cache_root = cache_dir.join("sourcemap-translate");
    if std::fs::create_dir_all(&cache_root).is_err() {
        return None;
    }
    // Reuse the sourcemap-cache sanitiser to stay consistent across
    // both materialisation paths.
    let basename = sanitize_for_cache(recorded_path);
    let mut prefixed = std::ffi::OsString::from("autoformat_");
    prefixed.push(basename.as_os_str());
    let out_path = cache_root.join(prefixed);

    // Rewrite when the on-disk content drifts — handles the case where
    // a follow-up session formats the same source with a newer tool
    // version.  We deliberately don't skip-on-exists because the spec
    // promises the user sees the *current* formatted view.
    let needs_write = match std::fs::read_to_string(&out_path) {
        Ok(existing) => existing != formatted_content,
        Err(_) => true,
    };
    if needs_write && let Err(e) = std::fs::write(&out_path, formatted_content.as_bytes()) {
        warn!(
            "autoformat: failed to materialise formatted source to {}: {e}",
            out_path.display()
        );
        return None;
    }
    Some(out_path.display().to_string())
}

/// Convert a sourcemap logical source name (e.g. `webpack:///./src/foo.ts`,
/// `../node_modules/lodash/lodash.js`, `/abs/path/file.js`) into a safe
/// filename for the sidecar cache.  Strips path-traversal segments and
/// scheme prefixes; preserves the basename for human-recognisability.
fn sanitize_for_cache(logical_name: &str) -> PathBuf {
    let no_scheme = logical_name
        .split_once("://")
        .map(|(_scheme, rest)| rest)
        .unwrap_or(logical_name);
    let cleaned: String = no_scheme
        .chars()
        .map(|c| match c {
            '/' | '\\' => '_',
            ':' => '_',
            c if c.is_ascii_control() => '_',
            c => c,
        })
        .collect();
    // Strip leading underscores / dots so the file is browsable.
    let trimmed = cleaned.trim_start_matches(['_', '.']);
    PathBuf::from(if trimmed.is_empty() { "source" } else { trimmed })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use std::fs;

    const TINY_MAP: &str = r#"{
        "version": 3,
        "file": "min.js",
        "sources": ["orig.js"],
        "sourcesContent": ["function alpha(){return beta();}\nfunction beta(){}\n"],
        "names": ["alpha","beta"],
        "mappings": "AAAAA,KACEC,KAGE"
    }"#;

    #[test]
    fn cache_empty_returns_none() {
        let mut cache = SourcemapCache::new();
        assert!(cache.is_empty());
        assert_eq!(cache.len(), 0);
        let t = cache.translate(PathId(0), 1, 1, None);
        assert!(t.is_none());
    }

    #[test]
    fn try_load_indexes_by_path_id_and_path() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("min.js");
        let map = dir.path().join("min.js.map");
        fs::write(&src, b"console.log('min');\n").unwrap();
        fs::write(&map, TINY_MAP).unwrap();
        let mut cache = SourcemapCache::new();
        cache.try_load(PathId(7), &src);
        assert!(!cache.is_empty());
        assert_eq!(cache.len(), 1);
        let t = cache.translate(PathId(7), 1, 1, None).expect("translate");
        // resolve_source_path joins `orig.js` against `dir` — the
        // file doesn't exist on disk so the path is returned as-is
        // (best-effort) but the line/column are correct.
        assert_eq!(t.line, 1);
        assert_eq!(t.column, 1);
        assert!(t.name.as_deref() == Some("alpha"));
        assert!(t.path.ends_with("orig.js"));
    }

    #[test]
    fn translate_returns_none_when_no_map() {
        let mut cache = SourcemapCache::new();
        let t = cache.translate(PathId(99), 1, 1, None);
        assert!(t.is_none());
    }

    #[test]
    fn materialise_writes_inline_content_to_cache_dir() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("min.js");
        let map = dir.path().join("min.js.map");
        fs::write(&src, b"console.log('min');\n").unwrap();
        fs::write(&map, TINY_MAP).unwrap();
        let cache_dir = dir.path().join("cache");
        fs::create_dir_all(&cache_dir).unwrap();

        let mut cache = SourcemapCache::new();
        cache.try_load(PathId(7), &src);

        // First call materialises the inline content.
        let t = cache.translate(PathId(7), 1, 1, Some(&cache_dir)).expect("translate");
        // The translated path should now point at a real file on disk
        // OR the resolved-but-unwritten path.  Our resolver prefers
        // an on-disk match first; orig.js doesn't exist so it tries
        // materialisation.  But our resolver returns the resolved
        // path even when no file is present — so the path we get
        // may be either the materialised sidecar OR the unmaterialised
        // sibling.  Both are valid; the cache test only verifies the
        // materialisation actually happens.
        let _ = t;
        assert!(
            cache_dir.join("sourcemap-translate").join("orig.js").is_file(),
            "materialised content should be written"
        );
        let body = fs::read_to_string(cache_dir.join("sourcemap-translate").join("orig.js")).unwrap();
        assert!(body.contains("function alpha"));
    }

    #[test]
    fn source_content_for_lookups_across_all_maps() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("min.js");
        let map = dir.path().join("min.js.map");
        fs::write(&src, b"console.log('min');\n").unwrap();
        fs::write(&map, TINY_MAP).unwrap();
        let mut cache = SourcemapCache::new();
        cache.try_load(PathId(7), &src);
        let content = cache.source_content_for("orig.js").expect("inline content");
        assert!(content.contains("function alpha"));
    }

    #[test]
    fn sanitize_for_cache_handles_webpack_urls() {
        let p = sanitize_for_cache("webpack:///./src/foo.ts");
        assert_eq!(p, PathBuf::from("src_foo.ts"));
    }

    #[test]
    fn sanitize_for_cache_handles_relative_paths() {
        let p = sanitize_for_cache("../node_modules/lodash/lodash.js");
        assert_eq!(p, PathBuf::from("node_modules_lodash_lodash.js"));
    }

    #[test]
    fn resolve_name_returns_user_list_first() {
        let mut cache = SourcemapCache::new();
        let list = RenameList::parse_toml(
            r#"
                [[rename]]
                file = "lodash.min.js"
                from = "e"
                to = "array"
            "#,
        )
        .unwrap();
        cache.set_rename_list(Some(list));
        assert!(cache.has_rename_list());
        assert_eq!(cache.resolve_name("lodash.min.js", None, "e").as_deref(), Some("array"));
    }

    #[test]
    fn resolve_name_function_scope_overrides_global() {
        let mut cache = SourcemapCache::new();
        let list = RenameList::parse_toml(
            r#"
                [[rename]]
                file = "lodash.min.js"
                scope = "global"
                from = "t"
                to = "global_result"

                [[rename]]
                file = "lodash.min.js"
                scope = "function:chunk"
                from = "t"
                to = "chunk_result"
            "#,
        )
        .unwrap();
        cache.set_rename_list(Some(list));
        let chunk = Scope::Function("chunk".to_string());
        assert_eq!(
            cache.resolve_name("lodash.min.js", Some(&chunk), "t").as_deref(),
            Some("chunk_result")
        );
        // No matching function hint → falls back to global.
        let other = Scope::Function("other".to_string());
        assert_eq!(
            cache.resolve_name("lodash.min.js", Some(&other), "t").as_deref(),
            Some("global_result")
        );
    }

    #[test]
    fn resolve_name_user_list_wins_over_sourcemap_names() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("min.js");
        let map = dir.path().join("min.js.map");
        fs::write(&src, b"console.log('min');\n").unwrap();
        fs::write(&map, TINY_MAP).unwrap();
        let mut cache = SourcemapCache::new();
        cache.try_load(PathId(7), &src);
        // Sourcemap has `alpha` in its names[] — resolve_name would
        // echo it back via the sourcemap branch.  Install a user
        // override that maps `alpha -> user_alpha` and assert the user
        // list wins.
        let list = RenameList::parse_toml(
            r#"
                [[rename]]
                file = "min.js"
                from = "alpha"
                to = "user_alpha"
            "#,
        )
        .unwrap();
        cache.set_rename_list(Some(list));
        assert_eq!(
            cache.resolve_name("min.js", None, "alpha").as_deref(),
            Some("user_alpha")
        );
    }

    #[test]
    fn resolve_name_falls_back_to_sourcemap_names() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("min.js");
        let map = dir.path().join("min.js.map");
        fs::write(&src, b"console.log('min');\n").unwrap();
        fs::write(&map, TINY_MAP).unwrap();
        let mut cache = SourcemapCache::new();
        cache.try_load(PathId(7), &src);
        // No user rename list installed — sourcemap's names[] confirms
        // `alpha` is a known binding and echoes it back.
        assert_eq!(cache.resolve_name("min.js", None, "alpha").as_deref(), Some("alpha"));
        // Unknown binding name returns None so the caller can surface
        // the recorded name unchanged.
        assert!(cache.resolve_name("min.js", None, "totally_unknown").is_none());
    }

    #[test]
    fn resolve_name_returns_none_without_any_data() {
        let cache = SourcemapCache::new();
        assert!(cache.resolve_name("any.js", None, "a").is_none());
    }

    #[test]
    fn translation_enabled_respects_env() {
        // Default (unset) is on.
        // SAFETY: tests run sequentially; we restore the var after.
        // We can't reliably manipulate env in parallel tests, so this
        // test asserts the parser logic directly via temp var.
        let key = "CT_SOURCEMAP_TRANSLATION";
        let orig = std::env::var(key).ok();
        unsafe { std::env::remove_var(key) };
        assert!(translation_enabled());
        unsafe { std::env::set_var(key, "0") };
        assert!(!translation_enabled());
        unsafe { std::env::set_var(key, "OFF") };
        assert!(!translation_enabled());
        unsafe { std::env::set_var(key, "1") };
        assert!(translation_enabled());
        // Restore.
        match orig {
            Some(v) => unsafe { std::env::set_var(key, v) },
            None => unsafe { std::env::remove_var(key) },
        }
    }
}
