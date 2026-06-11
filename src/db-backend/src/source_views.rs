//! `srcviews.dat` / `srcviews.off` reader — Alternate Source Views (CTFS).
//!
//! Implements the replay-server side of the *Alternate Source Views* CTFS
//! extension specified in
//! `codetracer-trace-format-spec/internal-files.md` §"Alternate Source
//! Views (Deminification Support)" (commit `23f4e37`).
//!
//! The recorder bakes pre-formatted views of minified sources directly
//! into the CTFS container (eliminating any replay-time subprocess
//! invocation).  Each record carries:
//!
//! * `path_id` — index into `paths.dat` (the *original recorded*
//!   minified source the view applies to);
//! * `view_kind` — discriminator: `1 = prettier_format`,
//!   `2 = black_format`, etc.;
//! * `view_name` — UI-facing file name (`"lodash.fmt.js"`);
//! * `content` — the formatted source as UTF-8 bytes;
//! * `sourcemap_v3` — a Source Map V3 JSON mapping positions in
//!   `content` BACK to positions in the original minified source at
//!   `path_id`.
//!
//! ## File-name caveat
//!
//! The spec says `source_views.dat` / `source_views.off`, but the CTFS
//! base40 filename encoding caps internal-file names at 12 characters.
//! The writer abbreviates to `srcviews.dat` / `srcviews.off` on disk
//! (see the comment in
//! `codetracer-trace-format-nim/src/codetracer_trace_writer/multi_stream_writer.nim`).
//! This reader matches the wire-format reality.
//!
//! ## Wire format
//!
//! `srcviews.dat` is a sequence of variable-length records; `srcviews.off`
//! is a `u64`-LE fixed-size table of offsets (`offsets[i]` and
//! `offsets[i+1]` bound record `i`'s bytes in `srcviews.dat`).  The
//! initial offset is `0` so the number of records is `offsets.len() - 1`.
//!
//! Each record is encoded as:
//!
//! ```text
//!   varint  path_id                          (LEB128 unsigned)
//!   u8      view_kind
//!   varint  view_name_len
//!   bytes   view_name      (UTF-8, view_name_len)
//!   varint  content_len
//!   bytes   content        (raw, content_len)
//!   varint  map_len
//!   bytes   map            (JSON UTF-8, map_len; may be empty)
//! ```
//!
//! ## Why parse directly instead of going through the Nim FFI
//!
//! The canonical Nim reader (`NimTraceReaderHandle`) does not yet expose
//! source-view accessors — adding the FFI shim is a documented follow-up.
//! The replay-server already has the trace bytes available through the
//! existing [`CtfsReader`] surface, and the format is independently
//! documented in the spec, so parsing here keeps the integration self-
//! contained without coupling new feature work to FFI bring-up.

use std::collections::HashMap;
use std::fmt;
use std::io;
use std::path::Path;

use crate::ctfs_trace_reader::ctfs_container::{CtfsError, CtfsReader};

/// One parsed alternate source view.
///
/// The fields mirror the on-disk record one-for-one; downstream consumers
/// can match `view_kind` to pick between competing views and read
/// `content` / `sourcemap_v3` to materialise files on disk.
#[derive(Debug, Clone)]
pub struct SourceView {
    /// Recorded `PathId` (index into `paths.dat`) the view applies to.
    pub path_id: u64,
    /// Discriminator from the spec — `0 = raw`, `1 = prettier_format`,
    /// `2 = black_format`, etc.  Reader does not interpret values; it
    /// surfaces them to the caller for selection.
    pub view_kind: u8,
    /// Human-readable name for the view (typically
    /// `<original>.fmt.<ext>`).  Used as the file name surfaced in
    /// DAP `stackTrace` responses.
    pub view_name: String,
    /// Formatted source bytes (UTF-8).  Not validated as UTF-8 here so
    /// odd recorder outputs round-trip; the caller decides whether to
    /// require valid UTF-8 when writing the materialised file.
    pub content: Vec<u8>,
    /// Source Map V3 JSON bytes mapping `content` positions back to
    /// positions in the original source at `path_id`.  Length `0`
    /// signals "no map shipped" — legal per the spec.
    pub sourcemap_v3: Vec<u8>,
}

/// In-memory snapshot of the `srcviews.dat` table.
///
/// Built once at trace open via [`SourceViews::load`], then cheaply
/// indexed by record index or `PathId`.  The struct owns all bytes; the
/// CTFS container can be dropped after construction.
#[derive(Debug, Default, Clone)]
pub struct SourceViews {
    entries: Vec<SourceView>,
    by_path: HashMap<u64, Vec<usize>>,
}

/// Errors surfaced by [`SourceViews::load`].
///
/// Distinguishes "legacy trace, no extension" (`Absent`) from a malformed
/// container or a corrupt record so callers can suppress the legacy case
/// silently while logging the corrupt-data cases for diagnostics.
#[derive(Debug)]
pub enum SourceViewsError {
    /// I/O error reading the underlying CTFS container.
    Io(io::Error),
    /// Container could not be opened or the CTFS layout is corrupt.
    Ctfs(CtfsError),
    /// Both `srcviews.dat` and `srcviews.off` are missing — this is the
    /// expected pre-extension legacy case and callers should treat it
    /// as "no source views" rather than as a hard error.
    Absent,
    /// Exactly one of the two files is present — the container is
    /// inconsistent; either both must exist or neither must.
    Inconsistent { dat_present: bool, off_present: bool },
    /// Structural parse error (record bounds, varint overflow, etc.).
    Parse(String),
}

impl fmt::Display for SourceViewsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "srcviews: I/O error: {e}"),
            Self::Ctfs(e) => write!(f, "srcviews: CTFS error: {e}"),
            Self::Absent => write!(f, "srcviews: extension files not present"),
            Self::Inconsistent {
                dat_present,
                off_present,
            } => write!(
                f,
                "srcviews: inconsistent container (srcviews.dat={dat_present}, srcviews.off={off_present})"
            ),
            Self::Parse(msg) => write!(f, "srcviews: parse error: {msg}"),
        }
    }
}

impl std::error::Error for SourceViewsError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(e) => Some(e),
            Self::Ctfs(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for SourceViewsError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

impl From<CtfsError> for SourceViewsError {
    fn from(e: CtfsError) -> Self {
        Self::Ctfs(e)
    }
}

impl SourceViews {
    /// Load `srcviews.dat` + `srcviews.off` from the CTFS container at
    /// `path`.
    ///
    /// Returns [`SourceViewsError::Absent`] when neither file is
    /// present — this is the expected back-compat case for pre-
    /// extension traces; callers should treat it as a non-error
    /// "no source views" outcome.
    pub fn load(path: &Path) -> Result<Self, SourceViewsError> {
        let mut reader = CtfsReader::open(path)?;
        Self::load_from_reader(&mut reader)
    }

    /// Load from an already-opened [`CtfsReader`].  Useful in tests and
    /// when the caller has the container parsed for another reason
    /// (e.g. dispatcher's `is_codetracer_ctfs_file` probe).
    pub fn load_from_reader(reader: &mut CtfsReader) -> Result<Self, SourceViewsError> {
        let dat_present = reader.has_file("srcviews.dat");
        let off_present = reader.has_file("srcviews.off");
        match (dat_present, off_present) {
            (false, false) => return Err(SourceViewsError::Absent),
            (true, true) => {}
            _ => {
                return Err(SourceViewsError::Inconsistent {
                    dat_present,
                    off_present,
                });
            }
        }

        let data = reader.read_file("srcviews.dat")?;
        let off_bytes = reader.read_file("srcviews.off")?;
        Self::parse(&data, &off_bytes)
    }

    /// Parse from raw `srcviews.dat` + `srcviews.off` byte buffers.
    ///
    /// Exposed so tests and ad-hoc tooling can drive the parser without
    /// constructing a CTFS container.  The contract matches the on-disk
    /// layout: `offsets` is a `u64`-LE fixed-size table; the first
    /// offset MUST be `0` (per the variable-record-table convention),
    /// and `offsets.len()` MUST be `record_count + 1` so the last
    /// offset is the end-of-data marker.
    pub fn parse(data: &[u8], off_bytes: &[u8]) -> Result<Self, SourceViewsError> {
        if !off_bytes.len().is_multiple_of(8) {
            return Err(SourceViewsError::Parse(format!(
                "srcviews.off length {} not a multiple of 8",
                off_bytes.len()
            )));
        }
        if off_bytes.len() < 8 {
            return Err(SourceViewsError::Parse(
                "srcviews.off must contain at least the initial 0 offset".to_string(),
            ));
        }
        let num_offsets = off_bytes.len() / 8;
        let mut offsets = Vec::with_capacity(num_offsets);
        for i in 0..num_offsets {
            let off = i * 8;
            // Safe — bounds were validated by the multiple-of-8 + len check.
            let bytes: [u8; 8] = match off_bytes[off..off + 8].try_into() {
                Ok(b) => b,
                Err(_) => unreachable!("8-byte slice"),
            };
            offsets.push(u64::from_le_bytes(bytes));
        }
        // Per the variable-record-table convention the first offset is 0
        // and the number of records is offsets.len() - 1.  An explicit
        // invariant check is cheap and catches truncated containers.
        if offsets[0] != 0 {
            return Err(SourceViewsError::Parse(format!(
                "srcviews.off first offset must be 0, was {}",
                offsets[0]
            )));
        }
        if let Some(last) = offsets.last()
            && (*last as usize) > data.len()
        {
            return Err(SourceViewsError::Parse(format!(
                "srcviews.off last offset {} exceeds srcviews.dat length {}",
                last,
                data.len()
            )));
        }

        let record_count = offsets.len() - 1;
        let mut entries = Vec::with_capacity(record_count);
        let mut by_path: HashMap<u64, Vec<usize>> = HashMap::new();

        for i in 0..record_count {
            let start = offsets[i] as usize;
            let end = offsets[i + 1] as usize;
            if end < start || end > data.len() {
                return Err(SourceViewsError::Parse(format!(
                    "srcviews.off record {i} bounds [{start}, {end}) invalid (data len {})",
                    data.len()
                )));
            }
            let record_bytes = &data[start..end];
            let entry = decode_record(record_bytes, i)?;
            by_path.entry(entry.path_id).or_default().push(entries.len());
            entries.push(entry);
        }

        Ok(SourceViews { entries, by_path })
    }

    /// Iterator-friendly access to the parsed records.
    pub fn entries(&self) -> &[SourceView] {
        &self.entries
    }

    /// Look up the record indices for a given recorded `PathId`.
    ///
    /// Returns `None` when no view has been registered for `path_id`.
    /// Returns multiple indices when more than one view exists (e.g. a
    /// `prettier_format` AND a `black_format` for the same path —
    /// unusual but legal per the spec).
    pub fn by_path(&self, path_id: u64) -> Option<&[usize]> {
        self.by_path.get(&path_id).map(|v| v.as_slice())
    }

    /// `true` when no records were parsed.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Number of parsed records.
    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

/// Decode one `srcviews.dat` record from its raw bytes.
///
/// The per-record layout matches the spec table (`§ srcviews.dat`).
/// `record_index` is included in error messages for diagnosability.
fn decode_record(bytes: &[u8], record_index: usize) -> Result<SourceView, SourceViewsError> {
    let mut pos = 0usize;
    let path_id = read_varint(bytes, &mut pos)
        .map_err(|e| SourceViewsError::Parse(format!("record {record_index}: path_id: {e}")))?;
    if pos >= bytes.len() {
        return Err(SourceViewsError::Parse(format!(
            "record {record_index}: truncated before view_kind"
        )));
    }
    let view_kind = bytes[pos];
    pos += 1;
    let view_name = read_length_prefixed_string(bytes, &mut pos)
        .map_err(|e| SourceViewsError::Parse(format!("record {record_index}: view_name: {e}")))?;
    let content = read_length_prefixed_bytes(bytes, &mut pos)
        .map_err(|e| SourceViewsError::Parse(format!("record {record_index}: content: {e}")))?;
    let sourcemap_v3 = read_length_prefixed_bytes(bytes, &mut pos)
        .map_err(|e| SourceViewsError::Parse(format!("record {record_index}: map: {e}")))?;

    if pos != bytes.len() {
        // Trailing bytes are not part of the wire format; flag rather
        // than silently ignore so writer bugs are caught early.
        return Err(SourceViewsError::Parse(format!(
            "record {record_index}: {} trailing byte(s) after map",
            bytes.len() - pos
        )));
    }

    Ok(SourceView {
        path_id,
        view_kind,
        view_name,
        content,
        sourcemap_v3,
    })
}

/// Decode an unsigned LEB128 varint at `*pos`, advancing `*pos`.
///
/// Mirrors `decode_varint` in `meta_dat.rs` — kept local so this module
/// has no implicit dependency on the meta.dat parser's error type.
fn read_varint(data: &[u8], pos: &mut usize) -> Result<u64, String> {
    let mut result: u64 = 0;
    let mut shift: u32 = 0;
    loop {
        if *pos >= data.len() {
            return Err("varint EOF".to_string());
        }
        let byte = data[*pos];
        *pos += 1;
        result |= u64::from(byte & 0x7F) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
        if shift >= 64 {
            return Err("varint too long (>10 bytes)".to_string());
        }
    }
}

/// Read a varint-length-prefixed byte sequence, advancing `*pos`.
fn read_length_prefixed_bytes(data: &[u8], pos: &mut usize) -> Result<Vec<u8>, String> {
    let len_u64 = read_varint(data, pos)?;
    let len = usize::try_from(len_u64).map_err(|_| format!("length {len_u64} exceeds usize"))?;
    if data.len() - *pos < len {
        return Err(format!(
            "declared length {len} exceeds remaining {} bytes",
            data.len() - *pos
        ));
    }
    let start = *pos;
    let v = data[start..start + len].to_vec();
    *pos += len;
    Ok(v)
}

/// Read a varint-length-prefixed UTF-8 string, advancing `*pos`.
fn read_length_prefixed_string(data: &[u8], pos: &mut usize) -> Result<String, String> {
    let v = read_length_prefixed_bytes(data, pos)?;
    String::from_utf8(v).map_err(|e| format!("not valid UTF-8: {e}"))
}

/// Encode an unsigned LEB128 varint into `out`.
///
/// Used by the test-only [`build_srcviews_table`] helper to construct
/// synthetic CTFS fixtures.  Kept in the module file so tests in the
/// integration `tests/` crate can build fixtures without copying the
/// codec into each test file.
pub fn encode_varint(value: u64, out: &mut Vec<u8>) {
    let mut v = value;
    loop {
        let mut byte = (v & 0x7F) as u8;
        v >>= 7;
        if v != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if v == 0 {
            break;
        }
    }
}

/// Test-only helper: serialize a list of `SourceView` records to the
/// `(srcviews.dat, srcviews.off)` byte-buffer pair the
/// [`SourceViews::parse`] entrypoint expects.
///
/// Exposed so integration tests can construct CTFS fixtures that drive
/// the full replay-server srcviews pipeline without depending on the
/// Nim writer or its FFI.
pub fn build_srcviews_table(views: &[SourceView]) -> (Vec<u8>, Vec<u8>) {
    let mut dat: Vec<u8> = Vec::new();
    let mut offsets: Vec<u64> = Vec::with_capacity(views.len() + 1);
    offsets.push(0);

    for sv in views {
        encode_varint(sv.path_id, &mut dat);
        dat.push(sv.view_kind);
        encode_varint(sv.view_name.len() as u64, &mut dat);
        dat.extend_from_slice(sv.view_name.as_bytes());
        encode_varint(sv.content.len() as u64, &mut dat);
        dat.extend_from_slice(&sv.content);
        encode_varint(sv.sourcemap_v3.len() as u64, &mut dat);
        dat.extend_from_slice(&sv.sourcemap_v3);
        offsets.push(dat.len() as u64);
    }

    let mut off: Vec<u8> = Vec::with_capacity(offsets.len() * 8);
    for o in &offsets {
        off.extend_from_slice(&o.to_le_bytes());
    }

    (dat, off)
}

// ── Tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    fn make_view(path_id: u64, view_kind: u8, name: &str, content: &str, map: &str) -> SourceView {
        SourceView {
            path_id,
            view_kind,
            view_name: name.to_string(),
            content: content.as_bytes().to_vec(),
            sourcemap_v3: map.as_bytes().to_vec(),
        }
    }

    #[test]
    fn varint_roundtrip() {
        for &v in &[0u64, 1, 127, 128, 16383, 16384, u32::MAX as u64, u64::MAX] {
            let mut buf = Vec::new();
            encode_varint(v, &mut buf);
            let mut pos = 0usize;
            let decoded = read_varint(&buf, &mut pos).unwrap();
            assert_eq!(decoded, v, "varint roundtrip failed for {v}");
            assert_eq!(pos, buf.len(), "varint over-read for {v}");
        }
    }

    #[test]
    fn parse_empty_table() {
        // An empty table has one offset (the initial 0) and no records.
        let off_bytes: Vec<u8> = 0u64.to_le_bytes().to_vec();
        let parsed = SourceViews::parse(&[], &off_bytes).expect("empty table parses");
        assert!(parsed.is_empty());
        assert_eq!(parsed.len(), 0);
        assert!(parsed.by_path(0).is_none());
    }

    #[test]
    fn parse_single_record() {
        let view = make_view(7, 1, "lodash.fmt.js", "fn add(a,b){return a+b;}\n", r#"{"version":3}"#);
        let (dat, off) = build_srcviews_table(std::slice::from_ref(&view));
        let parsed = SourceViews::parse(&dat, &off).expect("parses");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed.entries()[0].path_id, 7);
        assert_eq!(parsed.entries()[0].view_kind, 1);
        assert_eq!(parsed.entries()[0].view_name, "lodash.fmt.js");
        assert_eq!(parsed.entries()[0].content, view.content);
        assert_eq!(parsed.entries()[0].sourcemap_v3, view.sourcemap_v3);

        let by7 = parsed.by_path(7).expect("indexed");
        assert_eq!(by7, &[0]);
    }

    #[test]
    fn parse_multiple_records_same_path() {
        // Two views over the same recorded path — legal per the spec.
        let v1 = make_view(3, 1, "min.fmt.js", "// prettier\n", r#"{"version":3,"a":1}"#);
        let v2 = make_view(3, 2, "min.fmt.py", "# black\n", r#"{"version":3,"a":2}"#);
        let v3 = make_view(5, 1, "other.fmt.js", "// other\n", r#"{"version":3,"a":3}"#);
        let (dat, off) = build_srcviews_table(&[v1, v2, v3]);
        let parsed = SourceViews::parse(&dat, &off).expect("parses");
        assert_eq!(parsed.len(), 3);

        // Both records for path 3 are indexed.
        let p3 = parsed.by_path(3).expect("path 3");
        assert_eq!(p3, &[0, 1]);
        let p5 = parsed.by_path(5).expect("path 5");
        assert_eq!(p5, &[2]);

        // Unknown path returns None.
        assert!(parsed.by_path(999).is_none());
    }

    #[test]
    fn parse_record_with_empty_map() {
        // `map_len = 0` is a legal zero-byte sentinel.
        let view = make_view(0, 0, "raw.txt", "hello", "");
        let (dat, off) = build_srcviews_table(std::slice::from_ref(&view));
        let parsed = SourceViews::parse(&dat, &off).expect("parses");
        assert_eq!(parsed.entries()[0].sourcemap_v3.len(), 0);
    }

    #[test]
    fn rejects_off_with_wrong_alignment() {
        // 7 bytes ≠ multiple of 8.
        let off = vec![0u8; 7];
        let err = SourceViews::parse(&[], &off).expect_err("misaligned off");
        assert!(matches!(err, SourceViewsError::Parse(_)));
    }

    #[test]
    fn rejects_off_too_small() {
        // Empty off — must contain at least the initial 0 offset.
        let err = SourceViews::parse(&[], &[]).expect_err("empty off");
        assert!(matches!(err, SourceViewsError::Parse(_)));
    }

    #[test]
    fn rejects_off_first_offset_nonzero() {
        let mut off = Vec::new();
        off.extend_from_slice(&42u64.to_le_bytes());
        off.extend_from_slice(&42u64.to_le_bytes());
        let err = SourceViews::parse(&[], &off).expect_err("nonzero first offset");
        assert!(matches!(err, SourceViewsError::Parse(_)));
    }

    #[test]
    fn rejects_last_offset_beyond_data() {
        // Offsets claim a 100-byte record but srcviews.dat is empty.
        let mut off = Vec::new();
        off.extend_from_slice(&0u64.to_le_bytes());
        off.extend_from_slice(&100u64.to_le_bytes());
        let err = SourceViews::parse(&[], &off).expect_err("offset > data");
        assert!(matches!(err, SourceViewsError::Parse(_)));
    }

    #[test]
    fn rejects_truncated_record() {
        // Build a record, then truncate srcviews.dat by 1 byte while
        // leaving srcviews.off pointing at the original end.  The
        // resolver must refuse rather than silently returning short bytes.
        let view = make_view(0, 1, "a.fmt.js", "x", "");
        let (mut dat, off) = build_srcviews_table(std::slice::from_ref(&view));
        let _ = dat.pop();
        let err = SourceViews::parse(&dat, &off).expect_err("truncated dat");
        assert!(matches!(err, SourceViewsError::Parse(_)));
    }

    #[test]
    fn detects_trailing_bytes_in_record() {
        // Manually craft a record with garbage trailing bytes.
        let mut dat = Vec::new();
        encode_varint(0, &mut dat); // path_id
        dat.push(1); // view_kind
        encode_varint(1, &mut dat); // name_len
        dat.push(b'x'); // name
        encode_varint(1, &mut dat); // content_len
        dat.push(b'y'); // content
        encode_varint(0, &mut dat); // map_len
        // GARBAGE
        dat.extend_from_slice(b"trailing");

        let mut off = Vec::new();
        off.extend_from_slice(&0u64.to_le_bytes());
        off.extend_from_slice(&(dat.len() as u64).to_le_bytes());

        let err = SourceViews::parse(&dat, &off).expect_err("trailing bytes");
        assert!(matches!(err, SourceViewsError::Parse(_)));
    }
}
