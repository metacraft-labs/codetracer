//! Server-side Source Map V3 translation.
//!
//! Used by the CodeTracer replay-server to translate generated
//! (line, column) coordinates that the recorder captured against a
//! minified bundle (e.g. `lodash.min.js`) back to the original-source
//! coordinates the user wrote (`lodash.js`).  See the milestone spec:
//!
//! * `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P3.
//!
//! ## Why a separate crate
//!
//! The replay-server is a sprawling binary with a large dependency
//! graph; isolating sourcemap support keeps it independently testable
//! and lets the parsing + indexing logic stay narrowly scoped.  The
//! crate has a small, stable public surface — three calls and a
//! data struct — so the integration code in `db-backend` can stay
//! concise.
//!
//! ## Source Map V3 reference
//!
//! * Official spec: <https://sourcemaps.info/spec.html>
//! * `sourcemap` crate docs: <https://docs.rs/sourcemap/9>
//!
//! Per the V3 spec sourcemaps allow *sparse* mappings — some generated
//! positions intentionally have no original mapping (e.g. injected
//! prologues).  This is **not** an error; [`SourcemapIndex::translate`]
//! returns `None` in that case so the caller can fall back to the
//! recorded position.
//!
//! ## Coordinate systems
//!
//! The Source Map V3 spec and the `sourcemap` crate use **0-indexed**
//! line and column numbers.  The CodeTracer wire (DAP, CTFS step
//! records) uses **1-indexed** line numbers.  The public API on this
//! crate accepts 1-indexed inputs and returns 1-indexed outputs to
//! match the rest of the codebase; the 0/1 conversion happens at the
//! crate boundary so callers never have to think about it.

use std::error::Error;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use log::warn;

/// Translated source position pointing at the *original* source.
///
/// All coordinates are **1-indexed** — the convention used by DAP,
/// CTFS, and most text editors.  The internal Source Map V3 spec is
/// 0-indexed; the conversion happens inside [`SourcemapIndex::translate`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OriginalPos {
    /// Source file path as recorded in the sourcemap's `sources[]`
    /// array, with `sourceRoot` (if any) prepended.  This may be a
    /// relative path (e.g. `"../src/foo.ts"`) or an absolute path /
    /// `webpack://` URL depending on how the build tool emitted it.
    /// Callers that need a usable filesystem path should resolve this
    /// against the sourcemap's location on disk; see the
    /// [`SourcemapIndex::sourcemap_dir`] accessor.
    pub source: String,
    /// 1-indexed line in the original source.
    pub line: u32,
    /// 1-indexed column in the original source.
    pub column: u32,
    /// Original identifier name from the sourcemap's `names[]` array,
    /// if the segment carries one.  Tools that need this for renaming
    /// (P5) can attach the hint to step records; this milestone just
    /// surfaces it.
    pub name: Option<String>,
}

/// Error returned by [`SourcemapIndex::open`].
#[derive(Debug)]
pub enum SourcemapError {
    /// Failed to read the file from disk.
    Io(std::io::Error),
    /// The bytes did not parse as a Source Map V3 document, or the
    /// document was structurally invalid.
    Parse(String),
    /// The sourcemap file was a multi-section *indexed* sourcemap
    /// (V3 spec §"Indexed Map") whose internal structure we don't
    /// yet support.  Indexed maps are rare in practice (used by
    /// React Native's Metro bundler); falling back to no
    /// translation is preferable to crashing.
    Indexed,
}

impl fmt::Display for SourcemapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SourcemapError::Io(e) => write!(f, "I/O error reading sourcemap: {e}"),
            SourcemapError::Parse(msg) => write!(f, "failed to parse sourcemap V3: {msg}"),
            SourcemapError::Indexed => write!(f, "indexed (multi-section) sourcemaps are not supported"),
        }
    }
}

impl Error for SourcemapError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            SourcemapError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for SourcemapError {
    fn from(e: std::io::Error) -> Self {
        SourcemapError::Io(e)
    }
}

/// Indexed Source Map V3 document.
///
/// Wraps a `sourcemap::SourceMap` and adds a 1-indexed translation
/// helper plus convenience accessors used by the replay-server.
///
/// Translation uses the `sourcemap` crate's logarithmic
/// `lookup_token` — we deliberately do NOT build a flat
/// `(line, col) -> OriginalPos` HashMap because production sourcemaps
/// can be 10MB+ and that would blow up memory + load time for no
/// performance gain.
pub struct SourcemapIndex {
    inner: sourcemap::SourceMap,
    /// Pre-computed `sources()` slice — the constructor applies
    /// `sourceRoot` (if set on the map) so callers get the already-
    /// prefixed paths without having to re-derive them.
    sources: Vec<String>,
    /// Directory the sourcemap file itself lived in on disk.  Used by
    /// the replay-server to resolve relative `sources[]` entries to
    /// absolute filesystem paths when [`SourcemapIndex::source_content`]
    /// has no inline `sourcesContent` to return.
    sourcemap_dir: PathBuf,
}

impl fmt::Debug for SourcemapIndex {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SourcemapIndex")
            .field("sources", &self.sources)
            .field("sourcemap_dir", &self.sourcemap_dir)
            .field("token_count", &self.inner.get_token_count())
            .finish()
    }
}

impl SourcemapIndex {
    /// Open and parse a Source Map V3 from a JSON file on disk.
    ///
    /// Returns [`SourcemapError::Indexed`] for multi-section indexed
    /// maps — callers should treat this as "no sourcemap" and use the
    /// recorded coordinates unchanged.
    pub fn open(map_path: &Path) -> Result<Self, SourcemapError> {
        let bytes = fs::read(map_path)?;
        Self::from_slice(&bytes, map_path.parent().unwrap_or_else(|| Path::new(".")))
    }

    /// Parse a sourcemap from raw bytes.
    ///
    /// `sourcemap_dir` is the directory the sourcemap conceptually
    /// "lives in" — used to resolve relative `sources[]` paths in
    /// [`SourcemapIndex::resolve_source_path`].  Pass `"."` if you
    /// don't care about path resolution.
    pub fn from_slice(bytes: &[u8], sourcemap_dir: &Path) -> Result<Self, SourcemapError> {
        let decoded = sourcemap::decode_slice(bytes).map_err(|e| SourcemapError::Parse(format!("{e}")))?;
        let inner = match decoded {
            sourcemap::DecodedMap::Regular(m) => m,
            sourcemap::DecodedMap::Index(_) | sourcemap::DecodedMap::Hermes(_) => {
                // Multi-section indexed maps and the Hermes JS variant
                // are out of scope for the §P3 milestone.  Surfacing
                // them as a typed error lets the trace-open hook log a
                // warning and proceed without translation rather than
                // panicking inside the sourcemap crate.
                return Err(SourcemapError::Indexed);
            }
        };

        // Build the sources list with `sourceRoot` prepended.  The
        // sourcemap crate's `get_source` already applies the prefix
        // when present, so we just snapshot it once.
        let count = inner.get_source_count();
        let mut sources = Vec::with_capacity(count as usize);
        for i in 0..count {
            let s = inner.get_source(i).unwrap_or("").to_string();
            sources.push(s);
        }

        Ok(SourcemapIndex {
            inner,
            sources,
            sourcemap_dir: sourcemap_dir.to_path_buf(),
        })
    }

    /// Translate a generated (line, column) coordinate to the original
    /// source coordinate.
    ///
    /// Inputs and outputs are **1-indexed**.
    ///
    /// Returns `None` when:
    /// * The sourcemap has no segment covering `(gen_line, gen_col)`
    ///   (sparse mapping — legal per Source Map V3 §"Mappings").
    /// * The closest segment is past the end of the line (lookup
    ///   returned `None`).
    /// * The segment has no source attached (rare; a sourcemap can
    ///   legally carry "anchor" segments without an original source).
    pub fn translate(&self, gen_line: u32, gen_col: u32) -> Option<OriginalPos> {
        // Source Map V3 is 0-indexed; CTFS / DAP are 1-indexed.
        // The `saturating_sub` keeps the 0-input case (which should
        // never happen for valid 1-indexed input but is harmless to
        // tolerate) from underflowing.
        let line0 = gen_line.saturating_sub(1);
        let col0 = gen_col.saturating_sub(1);
        let token = self.inner.lookup_token(line0, col0)?;

        let source = token.get_source()?.to_string();
        // Convert the original position back to 1-indexed.
        let line = token.get_src_line().saturating_add(1);
        let column = token.get_src_col().saturating_add(1);
        let name = token.get_name().map(|s| s.to_string());

        Some(OriginalPos {
            source,
            line,
            column,
            name,
        })
    }

    /// Return the inline `sourcesContent[i]` for the given source
    /// path, if present in the sourcemap.
    ///
    /// `source` is matched against the entries returned by
    /// [`SourcemapIndex::sources`] — pass the exact string from
    /// [`OriginalPos::source`] for a guaranteed hit.
    ///
    /// Returns `None` when the source is unknown, when the sourcemap
    /// omits `sourcesContent` (common for production builds), or when
    /// the entry is the sparse `null` placeholder.
    pub fn source_content(&self, source: &str) -> Option<&str> {
        let idx = self.source_index(source)?;
        self.inner.get_source_contents(idx)
    }

    /// All source paths the sourcemap covers, with `sourceRoot`
    /// (if any) already prepended.
    pub fn sources(&self) -> &[String] {
        &self.sources
    }

    /// Directory the sourcemap file lived in on disk.  Useful for
    /// resolving relative `sources[]` entries to absolute paths when
    /// `sourcesContent` is missing and the consumer wants to fall back
    /// to a sibling-file lookup.
    pub fn sourcemap_dir(&self) -> &Path {
        &self.sourcemap_dir
    }

    /// Resolve a sourcemap-reported `source` (which may be relative,
    /// absolute, or a `webpack://` / `http(s)://` URL) to an absolute
    /// filesystem path.  Returns `None` when the source is a URL or
    /// cannot be turned into a real path.
    ///
    /// Relative paths are resolved against [`SourcemapIndex::sourcemap_dir`].
    pub fn resolve_source_path(&self, source: &str) -> Option<PathBuf> {
        // Heuristic: a string with a scheme like `webpack://` or `http://`
        // is not a path.  The sourcemap V3 spec doesn't prohibit URL-shaped
        // sources; we just skip them for the on-disk fallback.
        if source.contains("://") {
            return None;
        }
        let p = Path::new(source);
        if p.is_absolute() {
            Some(p.to_path_buf())
        } else {
            Some(self.sourcemap_dir.join(p))
        }
    }

    /// Internal: look up a source's index in the sources table.
    fn source_index(&self, source: &str) -> Option<u32> {
        self.sources
            .iter()
            .position(|s| s == source)
            .map(|i| i as u32)
    }

    /// `true` when `name` is present in the sourcemap's `names[]` array.
    ///
    /// Source Map V3 `names[]` is the dedup table the per-segment
    /// `name_index` references; entries are the **original** identifier
    /// names from the un-minified source.  The §P5 rename resolver uses
    /// this as a coarse-grained sanity check: when the user asks
    /// "does the sourcemap recognise binding name X?" we answer by
    /// checking whether X appears anywhere in `names[]`.
    ///
    /// This is intentionally NOT a per-position lookup — that path is
    /// covered by [`SourcemapIndex::translate`] returning
    /// `OriginalPos::name`.  The boolean form is what the rename
    /// resolver wants when composing with the user list: if the
    /// sourcemap already names this binding (by either side of the
    /// rename), the recorded coordinate is "blessed" and the resolver
    /// can echo it back as the renamed name.
    pub fn has_name(&self, name: &str) -> bool {
        let count = self.inner.get_name_count();
        for i in 0..count {
            if self.inner.get_name(i) == Some(name) {
                return true;
            }
        }
        false
    }
}

/// Discover a sourcemap for a given source file by following the
/// Source Map V3 resolution rules.
///
/// Resolution order (matching what browsers and DevTools do):
///
/// 1. **Sibling `<source>.map`** on disk — the most common case.
///    For `foo.min.js` we probe `foo.min.js.map`.
/// 2. **`//# sourceMappingURL=...`** comment near the end of the
///    source file.  Both inline `data:` URLs (`data:application/json;base64,...`)
///    and file path / URL forms are recognised.  URLs (http(s)) are
///    deliberately *not* fetched — the replay-server runs offline.
///
/// Returns `Ok(Some(idx))` when a sourcemap was found AND parsed,
/// `Ok(None)` when no sourcemap was found (a normal, expected case),
/// and `Err(_)` only when a sourcemap *was* found but failed to load.
/// Callers should treat parse failures as "no sourcemap" — the
/// recorded position is preferable to a crash.
pub fn discover_sourcemap_for(source_path: &Path) -> Result<Option<SourcemapIndex>, SourcemapError> {
    // Rule 1: sibling `<source>.map`.
    let sibling = {
        let mut s = source_path.as_os_str().to_owned();
        s.push(".map");
        PathBuf::from(s)
    };
    if sibling.is_file() {
        return Ok(Some(SourcemapIndex::open(&sibling)?));
    }

    // Rule 2: scan the source file's tail for `//# sourceMappingURL=`.
    if !source_path.is_file() {
        return Ok(None);
    }
    let source_bytes = match fs::read(source_path) {
        Ok(b) => b,
        Err(e) => {
            warn!(
                "discover_sourcemap_for: could not read source {} for sourceMappingURL scan: {e}",
                source_path.display()
            );
            return Ok(None);
        }
    };
    match parse_source_mapping_url(&source_bytes) {
        Some(SourceMappingUrl::Inline(bytes)) => {
            // The data URL form embeds the sourcemap JSON directly —
            // we still want to resolve relative `sources[]` against
            // the source file's directory, since that's where the
            // build tool would have written real sibling files.
            let dir = source_path.parent().unwrap_or_else(|| Path::new("."));
            Ok(Some(SourcemapIndex::from_slice(&bytes, dir)?))
        }
        Some(SourceMappingUrl::Path(p)) => {
            // Resolve relative URLs against the source file's directory.
            let dir = source_path.parent().unwrap_or_else(|| Path::new("."));
            let abs = if p.is_absolute() { p } else { dir.join(p) };
            if abs.is_file() {
                Ok(Some(SourcemapIndex::open(&abs)?))
            } else {
                Ok(None)
            }
        }
        Some(SourceMappingUrl::Remote) | None => Ok(None),
    }
}

/// Internal representation of a parsed `sourceMappingURL=...`.
#[derive(Debug)]
enum SourceMappingUrl {
    /// `data:application/json[;charset=utf-8];base64,...` — decoded payload.
    Inline(Vec<u8>),
    /// A file path or relative URL.
    Path(PathBuf),
    /// `http(s)://` URL — we don't fetch these.
    Remote,
}

/// Parse the trailing `//# sourceMappingURL=<value>` (or the older
/// `//@ sourceMappingURL=`) comment if present in `source_bytes`.
///
/// Per convention the comment lives near the very end of the file, so
/// we only scan the last ~4 KB to avoid pathological cost on massive
/// minified bundles.  Inline base64 sourcemaps will exceed 4 KB; the
/// helper handles that by scanning from the *last* `sourceMappingURL=`
/// occurrence in the trailing tail and following it to EOF.
fn parse_source_mapping_url(source_bytes: &[u8]) -> Option<SourceMappingUrl> {
    // Scan a tail window — the comment is supposed to be on the last
    // line, but inline base64 sourcemaps can be ENORMOUS.  We probe
    // a 64 KiB tail (enough to cover typical inline maps for small
    // libraries) plus, on miss, the entire file as a fallback.
    const PROBE: usize = 64 * 1024;
    let tail_start = source_bytes.len().saturating_sub(PROBE);
    if let Some(url) = find_source_mapping_url(&source_bytes[tail_start..]) {
        return Some(url);
    }
    // Inline data URLs can be larger than the probe window — try the
    // whole file as a last resort.  This is O(n) but only invoked when
    // the tail probe missed.
    find_source_mapping_url(source_bytes)
}

fn find_source_mapping_url(haystack: &[u8]) -> Option<SourceMappingUrl> {
    // Look for `sourceMappingURL=` (case-sensitive — the convention is
    // exact).  We find the LAST occurrence to handle cases where a
    // build tool injected one early in the file by mistake.
    let needle = b"sourceMappingURL=";
    let pos = memrfind(haystack, needle)?;
    let after = &haystack[pos + needle.len()..];
    // Read until newline or end of file.
    let end = after
        .iter()
        .position(|&b| b == b'\n' || b == b'\r')
        .unwrap_or(after.len());
    let value = std::str::from_utf8(&after[..end]).ok()?.trim();
    if value.is_empty() {
        return None;
    }

    // Inline `data:` URL (the typical webpack `devtool: 'inline-source-map'` output).
    if let Some(rest) = value.strip_prefix("data:") {
        // Two encodings are allowed: base64 and percent-encoded.  Only
        // base64 is in practice — fall back to skipping the entry for
        // other forms.
        let (_mime, payload) = rest.split_once(',')?;
        if rest.contains(";base64") {
            // The base64 module isn't in our dep tree; do the decode
            // ourselves to keep this crate dependency-light.
            let decoded = decode_base64(payload.trim())?;
            return Some(SourceMappingUrl::Inline(decoded));
        }
        // Non-base64 data URLs: percent-decode would be needed, but
        // these are exceedingly rare for sourcemaps in the wild.
        return None;
    }

    if value.starts_with("http://") || value.starts_with("https://") {
        return Some(SourceMappingUrl::Remote);
    }

    Some(SourceMappingUrl::Path(PathBuf::from(value)))
}

/// Find the last occurrence of `needle` in `haystack`.
fn memrfind(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    let last = haystack.len() - needle.len();
    let mut i = last + 1;
    while i > 0 {
        i -= 1;
        if &haystack[i..i + needle.len()] == needle {
            return Some(i);
        }
    }
    None
}

/// Minimal RFC 4648 base64 decoder.  Tolerates trailing whitespace /
/// newlines (common when the sourceMappingURL comment is hand-written).
fn decode_base64(input: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' | b'-' => Some(62), // tolerate base64url
            b'/' | b'_' => Some(63), // tolerate base64url
            _ => None,
        }
    }

    // Strip whitespace.  Sourcemap data URLs are typically a single
    // line but defensiveness is cheap here.
    let cleaned: Vec<u8> = input
        .bytes()
        .filter(|b| !b.is_ascii_whitespace() && *b != b'=')
        .collect();

    let mut out = Vec::with_capacity(cleaned.len() * 3 / 4);
    let mut buf: u32 = 0;
    let mut bits = 0;
    for &b in &cleaned {
        let v = val(b)?;
        buf = (buf << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal hand-crafted Source Map V3 covering one generated
    /// line.  Three mappings (all 0-indexed, as the V3 spec uses):
    ///   gen (0, 0)  -> orig.js (0, 0)  name="alpha"
    ///   gen (0, 5)  -> orig.js (1, 2)  name="beta"
    ///   gen (0, 10) -> orig.js (4, 4)  (no name)
    ///
    /// Mappings string decoded:
    ///   `AAAAA`  = [0, 0, 0, 0, 0]              gen_col=0, src=0, orig_line=0, orig_col=0, name=0
    ///   `KACEC`  = [+5, +0, +1, +2, +1]         gen_col=5, src=0, orig_line=1, orig_col=2, name=1
    ///   `KAGE`   = [+5, +0, +3, +2]             gen_col=10, src=0, orig_line=4, orig_col=4
    ///
    /// Encoding reference: <https://sourcemaps.info/spec.html>
    /// (B64-VLQ; segments separated by `,`).
    const TINY_MAP: &str = r#"{
        "version": 3,
        "file": "min.js",
        "sources": ["orig.js"],
        "sourcesContent": ["function alpha(){return beta();}\nfunction beta(){}\n"],
        "names": ["alpha","beta"],
        "mappings": "AAAAA,KACEC,KAGE"
    }"#;

    /// A second fixture with `sourcesContent[0] = null` (the sparse
    /// case the spec calls out).  Mappings string is the same.
    const SPARSE_CONTENT_MAP: &str = r#"{
        "version": 3,
        "file": "min.js",
        "sources": ["orig.js"],
        "sourcesContent": [null],
        "names": ["alpha","beta"],
        "mappings": "AAAAA,KACEC,KAGE"
    }"#;

    /// A sourcemap omitting `sourcesContent` entirely (the production-
    /// build common case).
    const NO_CONTENT_MAP: &str = r#"{
        "version": 3,
        "file": "min.js",
        "sources": ["orig.js"],
        "names": ["alpha","beta"],
        "mappings": "AAAAA,KACEC,KAGE"
    }"#;

    fn parse(s: &str) -> SourcemapIndex {
        SourcemapIndex::from_slice(s.as_bytes(), Path::new("/tmp/fake")).expect("parse")
    }

    #[test]
    fn loads_minimal_sourcemap() {
        let idx = parse(TINY_MAP);
        assert_eq!(idx.sources(), &["orig.js".to_string()]);
        assert_eq!(idx.sourcemap_dir(), Path::new("/tmp/fake"));
    }

    #[test]
    fn translate_first_segment_returns_original() {
        let idx = parse(TINY_MAP);
        // gen (1,1) is 1-indexed → 0,0 → first segment.
        let pos = idx.translate(1, 1).expect("first segment maps");
        assert_eq!(pos.source, "orig.js");
        assert_eq!(pos.line, 1);
        assert_eq!(pos.column, 1);
        assert_eq!(pos.name.as_deref(), Some("alpha"));
    }

    #[test]
    fn translate_mid_line_returns_intermediate_segment() {
        let idx = parse(TINY_MAP);
        // gen col 6 (1-indexed) → 0-indexed 5 → segment 2 → orig (1,2) → 1-idx (2,3).
        let pos = idx.translate(1, 6).expect("mid segment maps");
        assert_eq!(pos.source, "orig.js");
        assert_eq!(pos.line, 2);
        assert_eq!(pos.column, 3);
        assert_eq!(pos.name.as_deref(), Some("beta"));
    }

    #[test]
    fn translate_past_last_segment_falls_back_to_last() {
        // `lookup_token` is a greatest-lower-bound search, so a column
        // *past* the last mapping returns the last segment — that's the
        // standard browser DevTools behaviour.  Asserting the returned
        // segment is the last one is the meaningful contract.
        let idx = parse(TINY_MAP);
        let pos = idx.translate(1, 9999).expect("clamps to last segment");
        assert_eq!(pos.source, "orig.js");
        assert_eq!(pos.line, 5);
        assert_eq!(pos.column, 5);
        assert!(pos.name.is_none(), "third segment has no name");
    }

    #[test]
    fn translate_on_unmapped_line_returns_none() {
        // Line 2 (1-idx) has no mappings in our tiny fixture →
        // `lookup_token` returns the last segment of line 1 because of
        // greatest-lower-bound semantics.  Lines BEFORE line 1 should
        // return None.  The 0,0 input on line 1 already covers the
        // "first segment" case; here we test a generated coordinate
        // that the crate can't pin to any token at all.
        let empty_map = r#"{
            "version": 3,
            "file": "min.js",
            "sources": ["orig.js"],
            "names": [],
            "mappings": ""
        }"#;
        let idx = parse(empty_map);
        assert!(idx.translate(1, 1).is_none(), "empty mappings → None");
    }

    #[test]
    fn source_content_inline_returns_string() {
        let idx = parse(TINY_MAP);
        let content = idx.source_content("orig.js").expect("inline content present");
        assert!(content.contains("function alpha"));
        assert!(content.contains("function beta"));
    }

    #[test]
    fn source_content_returns_none_when_omitted() {
        let idx = parse(NO_CONTENT_MAP);
        assert!(idx.source_content("orig.js").is_none());
    }

    #[test]
    fn source_content_returns_none_for_sparse_null() {
        let idx = parse(SPARSE_CONTENT_MAP);
        assert!(idx.source_content("orig.js").is_none());
    }

    #[test]
    fn source_content_unknown_path_returns_none() {
        let idx = parse(TINY_MAP);
        assert!(idx.source_content("does-not-exist.js").is_none());
    }

    #[test]
    fn resolve_source_path_absolute_passes_through() {
        let idx = parse(TINY_MAP);
        let abs = idx.resolve_source_path("/abs/orig.js").unwrap();
        assert_eq!(abs, PathBuf::from("/abs/orig.js"));
    }

    #[test]
    fn resolve_source_path_relative_joins_with_dir() {
        let idx = parse(TINY_MAP);
        let p = idx.resolve_source_path("orig.js").unwrap();
        assert_eq!(p, PathBuf::from("/tmp/fake/orig.js"));
    }

    #[test]
    fn resolve_source_path_webpack_url_returns_none() {
        let idx = parse(TINY_MAP);
        assert!(idx.resolve_source_path("webpack://./src/orig.js").is_none());
    }

    #[test]
    fn open_reads_file_from_disk() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("min.js.map");
        fs::write(&path, TINY_MAP).unwrap();
        let idx = SourcemapIndex::open(&path).expect("open");
        assert_eq!(idx.sources(), &["orig.js".to_string()]);
        assert_eq!(idx.sourcemap_dir(), dir.path());
    }

    #[test]
    fn open_nonexistent_returns_io_error() {
        let err = SourcemapIndex::open(Path::new("/definitely/does/not/exist.map")).unwrap_err();
        assert!(matches!(err, SourcemapError::Io(_)));
    }

    #[test]
    fn open_malformed_returns_parse_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bad.map");
        fs::write(&path, b"not a sourcemap").unwrap();
        let err = SourcemapIndex::open(&path).unwrap_err();
        assert!(matches!(err, SourcemapError::Parse(_)));
    }

    #[test]
    fn discover_sourcemap_sibling_file_succeeds() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("foo.min.js");
        let map = dir.path().join("foo.min.js.map");
        fs::write(&src, b"// minified bundle here\n").unwrap();
        fs::write(&map, TINY_MAP).unwrap();
        let idx = discover_sourcemap_for(&src).expect("disk error").expect("sourcemap found");
        assert_eq!(idx.sources(), &["orig.js".to_string()]);
    }

    #[test]
    fn discover_sourcemap_no_sibling_no_comment_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("foo.min.js");
        fs::write(&src, b"console.log('no sourcemap here');\n").unwrap();
        let res = discover_sourcemap_for(&src).expect("disk error");
        assert!(res.is_none());
    }

    #[test]
    fn discover_sourcemap_via_url_comment_resolves_relative_path() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("foo.min.js");
        let map = dir.path().join("foo.bundle.map");
        // The source file does NOT have a sibling foo.min.js.map but
        // names a different relative file via the comment.
        fs::write(
            &src,
            b"console.log('hi');\n//# sourceMappingURL=foo.bundle.map\n",
        )
        .unwrap();
        fs::write(&map, TINY_MAP).unwrap();
        let idx = discover_sourcemap_for(&src).expect("disk error").expect("sourcemap found");
        assert_eq!(idx.sources(), &["orig.js".to_string()]);
    }

    #[test]
    fn discover_sourcemap_inline_data_url() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("foo.min.js");
        // Construct an inline data URL by base64-encoding TINY_MAP.
        let encoded = base64_encode_for_test(TINY_MAP.as_bytes());
        let comment = format!(
            "console.log('hi');\n//# sourceMappingURL=data:application/json;charset=utf-8;base64,{encoded}\n"
        );
        fs::write(&src, comment).unwrap();
        let idx = discover_sourcemap_for(&src).expect("disk error").expect("sourcemap found");
        assert_eq!(idx.sources(), &["orig.js".to_string()]);
    }

    #[test]
    fn discover_sourcemap_remote_url_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("foo.min.js");
        fs::write(
            &src,
            b"console.log('hi');\n//# sourceMappingURL=https://example.com/foo.map\n",
        )
        .unwrap();
        // We don't fetch remote URLs — should return None.
        let res = discover_sourcemap_for(&src).expect("disk error");
        assert!(res.is_none());
    }

    #[test]
    fn names_field_surfaces_on_translate() {
        let idx = parse(TINY_MAP);
        let pos = idx.translate(1, 1).unwrap();
        assert_eq!(pos.name.as_deref(), Some("alpha"));
        let pos = idx.translate(1, 6).unwrap();
        assert_eq!(pos.name.as_deref(), Some("beta"));
    }

    /// Tiny base64 encoder, used only by `discover_sourcemap_inline_data_url`
    /// to round-trip a known map through the `data:` URL parser.  Kept
    /// inside the test module so the crate's main API stays
    /// decoder-only (we don't currently need to write inline maps).
    fn base64_encode_for_test(input: &[u8]) -> String {
        const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
        let mut i = 0;
        while i + 3 <= input.len() {
            let n = ((input[i] as u32) << 16) | ((input[i + 1] as u32) << 8) | (input[i + 2] as u32);
            out.push(ALPHABET[((n >> 18) & 0x3F) as usize] as char);
            out.push(ALPHABET[((n >> 12) & 0x3F) as usize] as char);
            out.push(ALPHABET[((n >> 6) & 0x3F) as usize] as char);
            out.push(ALPHABET[(n & 0x3F) as usize] as char);
            i += 3;
        }
        let rem = input.len() - i;
        if rem == 1 {
            let n = (input[i] as u32) << 16;
            out.push(ALPHABET[((n >> 18) & 0x3F) as usize] as char);
            out.push(ALPHABET[((n >> 12) & 0x3F) as usize] as char);
            out.push('=');
            out.push('=');
        } else if rem == 2 {
            let n = ((input[i] as u32) << 16) | ((input[i + 1] as u32) << 8);
            out.push(ALPHABET[((n >> 18) & 0x3F) as usize] as char);
            out.push(ALPHABET[((n >> 12) & 0x3F) as usize] as char);
            out.push(ALPHABET[((n >> 6) & 0x3F) as usize] as char);
            out.push('=');
        }
        out
    }

    #[test]
    fn base64_decoder_round_trips_random_bytes() {
        // Sanity-check our hand-rolled decoder against the test encoder.
        let payload: Vec<u8> = (0u8..=255).collect();
        let enc = base64_encode_for_test(&payload);
        let dec = decode_base64(&enc).expect("decode");
        assert_eq!(dec, payload);
    }
}
