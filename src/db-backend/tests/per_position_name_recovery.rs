//! §P6.4 acceptance test — per-position original-name recovery.
//!
//! Spec:
//! `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P6.4.
//!
//! The P5 resolver only confirmed a binding's membership in the
//! sourcemap V3 `names[]` table — it could not recover the original
//! name from the per-token `name_index` field.  P6.4 fixes that by
//! threading `(line, col)` into [`SourcemapCache::resolve_name_at_position`]
//! so the resolver can ask the per-segment translation for the original
//! name that lives in the bundle at exactly that position.
//!
//! ## What this file covers
//!
//! 1. `per_position_recovers_original_from_segment` — a hand-crafted
//!    sourcemap with a single segment at `(gen_line=1, gen_col=10)`
//!    pointing at `(src_line=1, src_col=0, name_index=0)` recovers
//!    `userId` from the recorded `a`.
//! 2. `user_list_still_wins_at_position` — a user rename list mapping
//!    `a -> adminId` MUST win over the per-position recovery.
//! 3. `position_outside_any_segment_falls_back` — a `(line, col)` past
//!    the last segment yields no name; with `"a"` absent from the
//!    sourcemap's `names[]`, the fallback membership check also fails
//!    and the resolver returns `None`.
//! 4. `per_position_with_no_name_index_returns_none` — a segment that
//!    covers the position but has no `name_index` returns `None` from
//!    the position branch; the membership fallback still runs and may
//!    confirm the binding (or not).

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::fs;
use std::path::PathBuf;

use codetracer_trace_types::PathId;
use db_backend::rename_list::RenameList;
use db_backend::sourcemap_cache::SourcemapCache;

/// A hand-crafted sourcemap V3 with:
/// * One source file `orig.js`.
/// * One name `userId`.
/// * One segment at `(gen_line=1, gen_col=10)` (0-indexed: line 0,
///   col 9) pointing at `(src_idx=0, src_line=0, src_col=0,
///   name_index=0)`.
///
/// The VLQ mapping for `[9, 0, 0, 0, 0]` is `"SAAAA"`:
/// * `9` → signed VLQ → `(9 << 1) | 0` = `18` → base64 char index 18 = `S`.
/// * Each `0` → `A`.
///
/// This is the simplest possible sourcemap that exercises the
/// per-segment `name_index` lookup we added in P6.4.
const SINGLE_NAME_MAP: &str = r#"{
    "version": 3,
    "file": "min.js",
    "sources": ["orig.js"],
    "sourcesContent": ["const userId = 1;\n"],
    "names": ["userId"],
    "mappings": "SAAAA"
}"#;

/// Same shape as `SINGLE_NAME_MAP` but the segment is encoded with
/// only 4 fields — `[gen_col, src_idx, src_line, src_col]` — so the
/// per-token `name_index` is absent.  Source Map V3 permits 1-, 4-,
/// or 5-field segments; the 4-field form is what bundlers emit when a
/// token doesn't carry an original identifier.
const NO_NAME_INDEX_MAP: &str = r#"{
    "version": 3,
    "file": "min.js",
    "sources": ["orig.js"],
    "sourcesContent": ["const userId = 1;\n"],
    "names": [],
    "mappings": "SAAA"
}"#;

/// Two-segment sourcemap whose **last** segment carries no
/// `name_index`.  The `sourcemap` crate's `lookup_token` is a
/// greatest-lower-bound search, so a generated column *past* the last
/// segment clamps to it — the position-recovery branch therefore sees
/// `name = None` for any query past the last segment's column.
///
/// Segments (5- then 4-field):
/// * `[9, 0, 0, 0, 0]` → `SAAAA` — col 10 (1-idx), source(0,0,0), name "userId".
/// * Delta `[10, 0, 0, 0]` → `UAAA` — col 20 (1-idx), source(0,0,0), no name.
const TRAILING_NO_NAME_MAP: &str = r#"{
    "version": 3,
    "file": "min.js",
    "sources": ["orig.js"],
    "sourcesContent": ["const userId = 1;\n"],
    "names": ["userId"],
    "mappings": "SAAAA,UAAA"
}"#;

/// Build a `SourcemapCache` with the given sourcemap JSON written next
/// to a synthetic `min.js`.  Returns the cache and the absolute path
/// the resolver should be queried with.
fn cache_with_map(map_json: &str) -> (SourcemapCache, String, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("tempdir");
    let src = dir.path().join("min.js");
    let map = dir.path().join("min.js.map");
    fs::write(&src, b"console.log('min');\n").expect("write src");
    fs::write(&map, map_json).expect("write map");
    let mut cache = SourcemapCache::new();
    cache.try_load(PathId(1), &src);
    let path_str = src.display().to_string();
    (cache, path_str, dir)
}

#[test]
fn per_position_recovers_original_from_segment() {
    // The sourcemap has a single segment at (gen_line=1, gen_col=10)
    // pointing at name_index=0 → "userId".  The recorded binding name
    // is `"a"` (a minified identifier the bundler emitted); the user
    // list is empty, so the resolver should reach the per-position
    // sourcemap branch and recover `"userId"` from the segment.
    let (cache, path_str, _dir) = cache_with_map(SINGLE_NAME_MAP);
    let result = cache.resolve_name_at_position(&path_str, 1, 10, None, "a");
    assert_eq!(
        result,
        Some("userId".to_string()),
        "per-position sourcemap segment MUST recover the original name"
    );
}

#[test]
fn user_list_still_wins_at_position() {
    // Same sourcemap as above, but install a user rename list that
    // maps `a -> adminId`.  Even though the per-position sourcemap
    // branch would surface `"userId"`, the user list MUST win per the
    // P5/P6.4 precedence rules.
    let (mut cache, path_str, _dir) = cache_with_map(SINGLE_NAME_MAP);
    let basename = PathBuf::from(&path_str)
        .file_name()
        .expect("basename")
        .to_string_lossy()
        .to_string();
    let toml = format!(
        r#"
            [[rename]]
            file = "{basename}"
            from = "a"
            to = "adminId"
        "#
    );
    let list = RenameList::parse_toml(&toml).expect("parse rename list");
    cache.set_rename_list(Some(list));
    let result = cache.resolve_name_at_position(&path_str, 1, 10, None, "a");
    assert_eq!(
        result,
        Some("adminId".to_string()),
        "user rename list MUST win over per-position sourcemap recovery"
    );
}

#[test]
fn position_outside_any_segment_falls_back() {
    // Query a column past the last segment.  The `sourcemap` crate's
    // `lookup_token` is a greatest-lower-bound search, so a column
    // *past* the last segment clamps to it (matching DevTools'
    // behaviour).  Our `TRAILING_NO_NAME_MAP` ends with a 4-field
    // segment that has no `name_index`, so the position-recovery
    // branch sees `name = None` and falls through to the membership
    // check.  With `"a"` absent from `names[]` (the only entry is
    // `"userId"`), the membership check also fails → overall `None`.
    let (cache, path_str, _dir) = cache_with_map(TRAILING_NO_NAME_MAP);
    let result = cache.resolve_name_at_position(&path_str, 1, 999, None, "a");
    assert!(
        result.is_none(),
        "position past last segment (which has no name_index) + recorded name absent from names[] → None"
    );
}

#[test]
fn per_position_with_no_name_index_returns_none() {
    // The sourcemap's only segment is a 4-field segment without a
    // `name_index`, and `names[]` is empty.  The per-position branch
    // returns `None` (segment exists but has no name), and the
    // membership fallback also fails because `names[]` is empty.  The
    // overall result is `None`.
    let (cache, path_str, _dir) = cache_with_map(NO_NAME_INDEX_MAP);
    let result = cache.resolve_name_at_position(&path_str, 1, 10, None, "a");
    assert!(result.is_none(), "segment without name_index + empty names[] → None");
}
