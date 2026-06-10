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
