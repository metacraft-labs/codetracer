//! Pure-Rust, WASM-safe reader for the binary CTFS interning tables (M23d).
//!
//! This is the sibling of [`super::meta_dat`], and it exists for exactly the
//! same reason that module gives: the db-backend must be able to resolve a
//! new-format container's interned paths / functions / types / variable names
//! **without the Nim FFI reader** (`codetracer_trace_writer_nim`), which is
//! gated behind the `nim-reader` cargo feature and is not available in the
//! browser build, and **without a filesystem path**, which the Nim reader
//! requires.
//!
//! Together with `meta.dat` (parsed by [`super::meta_dat`]) and the seekable
//! `calls.dat` / `steps.dat` / `values.dat` streams, this closes the last gap
//! in reading a PRODUCTION split-stream `.ct` entirely from in-memory bytes —
//! which is what M0 ("Browser Replay Gate") deliverable 1 asks for.
//!
//! # Relationship to `codetracer_trace_reader::interning_tables_reader`
//!
//! The sibling `codetracer_trace_reader` crate carries a reader for the same
//! four tables, but it is declared `#[cfg(not(target_arch = "wasm32"))]` in
//! that crate's `lib.rs`, so it does not exist in a wasm32 build. Nothing in
//! it is actually host-specific — the gate is incidental — but that crate
//! lives in a **separate repository** (`codetracer-trace-format`) shared by
//! every checkout of this one, so un-gating it there is a cross-repo change.
//!
//! Rather than let the two implementations drift silently, the equivalence is
//! **asserted by a test**: `tests/interning_tables_parity_test.rs` writes a real
//! production bundle and checks this module's output name-for-name against the
//! Nim FFI reader — the production decoder — on native.
//!
//! Note that the upstream Rust reader is NOT the comparison target, because it
//! reads a different record layout from the one production traces carry; see
//! "Record layouts" below. That difference is exactly what the parity test
//! found.
//!
//! # Record layouts — there are TWO, and real traces use the simpler one
//!
//! Each table is a Variable-Size Record Table (`<name>.dat` + `<name>.off`)
//! from `codetracer-trace-format-spec/internal-files.md`: `.off` holds
//! `record_count + 1` little-endian `u64` byte offsets into `.dat` (the
//! trailing entry is the total data length), so record `i` is
//! `dat[off[i]..off[i + 1]]` — O(1) random access, no scan. That much is
//! shared. The RECORD payload is not:
//!
//! ```text
//!  [`RecordLayout::Plain`] — what the production Nim writer emits
//!    paths.dat / funcs.dat / types.dat / varnames.dat = raw name bytes
//!    paths.dat, when the trace is column-aware ("Layout A") =
//!        path_len: varint, path: bytes, line_count: varint,
//!        line_lengths: varint x line_count (zigzag deltas)
//!
//!  [`RecordLayout::Structured`] — M23d, what the secondary Rust writer emits
//!    paths.dat / varnames.dat = raw bytes
//!    funcs.dat   = global_line_index: varint, name_len: varint, name: bytes
//!    types.dat   = kind: u8, lang_type_len: varint, lang_type: bytes,
//!                  specific_info: CBOR of TypeSpecificInfo
//! ```
//!
//! Varints are unsigned LEB128, matching `meta.dat`.
//!
//! `meta.dat` bit 12 (`has_interning_tables`) selects between them. Note that
//! it is NOT a presence check: the production Nim writer emits all four tables
//! and leaves the bit clear, because the bit means "these are M23d structured
//! records" and its records are plain. Presence is decided by asking the
//! container for `paths.dat`; see
//! [`InterningTables::open_from_ctfs`] for the full story.

use codetracer_trace_types::{FunctionRecord, Line, PathId, TypeKind, TypeRecord, TypeSpecificInfo};
use num_traits::FromPrimitive;

use codetracer_trace_writer::meta_dat::meta_dat_has_interning_tables;
use codetracer_trace_writer::step_stream::unpack_global_line_index;

use super::ctfs_container::CtfsReader;

/// Decode one unsigned LEB128 varint at `*pos`, advancing `*pos` past it.
fn decode_varint(data: &[u8], pos: &mut usize) -> Result<u64, String> {
    let mut result: u64 = 0;
    let mut shift: u32 = 0;
    loop {
        if *pos >= data.len() {
            return Err("interning table: truncated varint".to_string());
        }
        if shift >= 64 {
            return Err("interning table: varint too long".to_string());
        }
        let byte = data[*pos];
        *pos += 1;
        result |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            break;
        }
        shift += 7;
    }
    Ok(result)
}

/// One `<name>.dat` + `<name>.off` Variable-Size Record Table.
#[derive(Debug)]
struct VarSizeTable {
    dat: Vec<u8>,
    /// `record_count + 1` byte offsets; the trailing entry is the data length.
    offsets: Vec<u64>,
}

impl VarSizeTable {
    fn new(name: &str, dat: Vec<u8>, off: &[u8]) -> Result<VarSizeTable, String> {
        if !off.len().is_multiple_of(8) {
            return Err(format!("{name}.off: length {} is not a multiple of 8", off.len()));
        }
        let mut offsets = Vec::with_capacity(off.len() / 8);
        let mut pos = 0usize;
        while pos + 8 <= off.len() {
            let mut buf = [0u8; 8];
            buf.copy_from_slice(&off[pos..pos + 8]);
            offsets.push(u64::from_le_bytes(buf));
            pos += 8;
        }
        // A valid index always carries the trailing sentinel, so an EMPTY table
        // is exactly one entry (`0`). Zero entries means a truncated `.off`.
        if offsets.is_empty() {
            return Err(format!("{name}.off: empty (missing the trailing sentinel offset)"));
        }
        Ok(VarSizeTable { dat, offsets })
    }

    fn count(&self) -> usize {
        self.offsets.len() - 1
    }

    fn record(&self, id: usize) -> Result<&[u8], String> {
        if id >= self.count() {
            return Err(format!(
                "interning table: id {id} out of range (count {})",
                self.count()
            ));
        }
        let start = self.offsets[id] as usize;
        let end = self.offsets[id + 1] as usize;
        if start > end || end > self.dat.len() {
            return Err(format!(
                "interning table: record {id} offsets [{start}, {end}) out of range (dat len {})",
                self.dat.len()
            ));
        }
        Ok(&self.dat[start..end])
    }
}

/// The four decoded interning tables of a new-format container.
///
/// Decoded eagerly at open: the tables are the trace's *vocabulary*, not its
/// execution, so their size is proportional to the program's source (paths,
/// function names, type names, variable names) rather than to the number of
/// steps. A trace far larger than a browser tab's memory budget still has a
/// small vocabulary — this is precisely the split that lets the steps, calls
/// and values stay seekable.
pub struct InterningTables {
    /// Source file paths, indexed by `PathId`.
    pub paths: Vec<String>,
    /// Function records, indexed by `FunctionId`. On the [`RecordLayout::Plain`]
    /// layout only the name is on disk, so `path_id`/`line` are `0` — exactly
    /// what the Nim FFI path produces. On [`RecordLayout::Structured`] the
    /// record carries a packed `global_line_index` and the real definition site
    /// is recovered.
    pub functions: Vec<FunctionRecord>,
    /// Type records, indexed by `TypeId`.
    pub types: Vec<TypeRecord>,
    /// Variable names, indexed by `VariableId`.
    pub variable_names: Vec<String>,
    /// Which on-disk record layout these tables were decoded from.
    pub layout: RecordLayout,
}

/// Which record layout a container's interning tables use.
///
/// There are TWO, and the difference is not cosmetic — it decides whether a
/// record is a bare string or a structured blob. Getting it wrong does not
/// produce wrong names; it produces a decode error or garbage, which is how
/// this distinction was found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordLayout {
    /// **What every live recorder actually writes.** The Nim
    /// `MultiStreamTraceWriter` interns through `interning_table.nim`'s
    /// `ensureId`, which appends the RAW NAME BYTES and nothing else, for all
    /// four tables. There is no `global_line_index` on a function record and no
    /// kind byte on a type record, which is precisely why the Nim FFI reader
    /// exposes only names and why `open_new_format_nim` stubs
    /// `FunctionRecord::path_id`/`line` to zero and every `TypeRecord::kind` to
    /// `Raw`. This reader reproduces that faithfully rather than inventing
    /// data the container does not hold.
    ///
    /// `paths.dat` is the one exception: when the trace is column-aware its
    /// records switch to the self-describing "Layout A" form
    /// (`path_len` varint, path bytes, then a per-line length table).
    Plain,
    /// The M23d structured layout, which the SECONDARY Rust `CtfsTraceWriter`
    /// emits and which `meta.dat` bit 12 (`FLAG_HAS_INTERNING_TABLES`)
    /// advertises: a function record carries a packed `global_line_index`
    /// before its name, and a type record carries a `TypeKind` ordinal and a
    /// CBOR `TypeSpecificInfo` tail.
    Structured,
}

impl InterningTables {
    /// Read the interning tables through an already-open [`CtfsReader`].
    ///
    /// Returns `Ok(None)` only when the container genuinely has no binary
    /// interning tables; the caller then falls back to whatever interning its
    /// format carries.
    ///
    /// Reading through the caller's `CtfsReader` (rather than reopening a path)
    /// is what makes this browser-reachable: in the browser that reader is
    /// backed by in-memory VFS bytes.
    ///
    /// # Detection is by PRESENCE; the flag selects the LAYOUT
    ///
    /// The spec gates these tables on `meta.dat` bit 12
    /// (`FLAG_HAS_INTERNING_TABLES`), and
    /// `codetracer_trace_reader::interning_tables_reader` keys off it alone.
    /// **The production Nim writer does not stamp that bit** —
    /// `MultiStreamTraceWriter` calls `initTraceInterningTables` (which creates
    /// and fills all four tables) but its `writeMetaDat` call passes
    /// `hasCallStream` / `hasStepStream` / `hasValueStream` /
    /// `hasIoEventStream` / `hasSpanStream` and simply omits
    /// `hasInterningTables`, which defaults to `false`.
    ///
    /// That is not merely a missing bit. The bit means "these tables are in the
    /// M23d STRUCTURED layout", and the Nim writer's tables are NOT: its
    /// `ensureId` appends raw name bytes with no `global_line_index` prefix and
    /// no kind byte. So the flag is honest about the layout even though it
    /// looks like a bug about presence, and a reader that took the flag as a
    /// presence check would find nothing on any real trace — a blank Variables
    /// pane over data that is sitting on disk.
    ///
    /// So: PRESENCE decides whether to read at all (ask the container for
    /// `paths.dat`), and the FLAG decides how to decode
    /// ([`RecordLayout`]).
    pub fn open_from_ctfs(ctfs: &mut CtfsReader) -> Result<Option<InterningTables>, String> {
        let meta = ctfs.read_file("meta.dat").unwrap_or_default();
        let layout = if meta_dat_has_interning_tables(&meta) {
            RecordLayout::Structured
        } else {
            RecordLayout::Plain
        };
        // `paths.dat` is written first and unconditionally by both writers, so
        // its presence is the container's own answer to "do I carry interning
        // tables".
        if !ctfs.has_file("paths.dat") {
            return Ok(None);
        }
        // Column-aware traces switch `paths.dat` to the self-describing
        // "Layout A" record; every other table is unaffected. There is no
        // upstream `meta_dat_has_column_aware_steps` helper, so read the bit
        // through this crate's own `meta.dat` parser.
        let column_aware_paths = super::meta_dat::parse_meta_dat(&meta)
            .map(|parsed| parsed.flags & super::meta_dat::FLAG_HAS_COLUMN_AWARE_STEPS != 0)
            .unwrap_or(false);

        let paths_table = Self::load_table(ctfs, "paths")?;
        let funcs_table = Self::load_table(ctfs, "funcs")?;
        let types_table = Self::load_table(ctfs, "types")?;
        let varnames_table = Self::load_table(ctfs, "varnames")?;

        let mut paths = Vec::with_capacity(paths_table.count());
        for id in 0..paths_table.count() {
            let raw = paths_table.record(id)?;
            paths.push(if column_aware_paths {
                decode_column_aware_path(id, raw)?
            } else {
                String::from_utf8_lossy(raw).into_owned()
            });
        }

        let mut variable_names = Vec::with_capacity(varnames_table.count());
        for id in 0..varnames_table.count() {
            variable_names.push(String::from_utf8_lossy(varnames_table.record(id)?).into_owned());
        }

        let mut functions = Vec::with_capacity(funcs_table.count());
        for id in 0..funcs_table.count() {
            let raw = funcs_table.record(id)?;
            functions.push(match layout {
                RecordLayout::Structured => decode_func_record(id, raw)?,
                RecordLayout::Plain => FunctionRecord {
                    name: String::from_utf8_lossy(raw).into_owned(),
                    // Not on disk in this layout. The Nim FFI reader stubs the
                    // same two fields to zero, so this is parity rather than
                    // loss — see `RecordLayout::Plain`.
                    path_id: PathId(0),
                    line: Line(0),
                },
            });
        }

        let mut types = Vec::with_capacity(types_table.count());
        for id in 0..types_table.count() {
            let raw = types_table.record(id)?;
            types.push(match layout {
                RecordLayout::Structured => decode_type_record(id, raw)?,
                RecordLayout::Plain => TypeRecord {
                    // The type NAME is all this layout stores, so `Raw` is the
                    // only honest kind — again matching `open_new_format_nim`.
                    kind: TypeKind::Raw,
                    lang_type: String::from_utf8_lossy(raw).into_owned(),
                    specific_info: TypeSpecificInfo::None,
                },
            });
        }

        Ok(Some(InterningTables {
            paths,
            functions,
            types,
            variable_names,
            layout,
        }))
    }

    /// Load one table. The four tables are written together, so once any of
    /// them is known to exist, a missing sibling is a corrupt container rather
    /// than an absent feature — hence an error rather than `Ok(None)`.
    fn load_table(ctfs: &mut CtfsReader, name: &str) -> Result<VarSizeTable, String> {
        let dat = ctfs
            .read_file(&format!("{name}.dat"))
            .map_err(|e| format!("{name}.dat missing from a container that carries interning tables: {e}"))?;
        let off = ctfs
            .read_file(&format!("{name}.off"))
            .map_err(|e| format!("{name}.off missing from a container that carries interning tables: {e}"))?;
        VarSizeTable::new(name, dat, &off)
    }
}

/// Decode a column-aware ("Layout A") `paths.dat` record down to its path.
///
/// The record is `path_len: varint, path bytes, line_count: varint,
/// line_lengths: varint × line_count` (the per-line table is zigzag-delta
/// encoded). Only the path is needed here — the per-line lengths feed the
/// column decoder, which is a separate concern — so the tail is skipped.
fn decode_column_aware_path(id: usize, raw: &[u8]) -> Result<String, String> {
    let mut pos = 0usize;
    let path_len = decode_varint(raw, &mut pos)? as usize;
    if pos + path_len > raw.len() {
        return Err(format!("paths.dat: record {id} path extends past record"));
    }
    Ok(String::from_utf8_lossy(&raw[pos..pos + path_len]).into_owned())
}

/// Decode one M23d-layout `funcs.dat` record into a [`FunctionRecord`].
///
/// The record's `global_line_index` is the same packing the step stream uses,
/// so [`unpack_global_line_index`] recovers the `(path_id, line)` the function
/// was defined at.
fn decode_func_record(id: usize, raw: &[u8]) -> Result<FunctionRecord, String> {
    let mut pos = 0usize;
    let global_line_index = decode_varint(raw, &mut pos)?;
    let name_len = decode_varint(raw, &mut pos)? as usize;
    if pos + name_len > raw.len() {
        return Err(format!("funcs.dat: record {id} name extends past record"));
    }
    let name = String::from_utf8_lossy(&raw[pos..pos + name_len]).into_owned();
    let (path_id, line) = unpack_global_line_index(global_line_index);
    Ok(FunctionRecord {
        name,
        path_id: PathId(path_id),
        line: Line(line),
    })
}

/// Decode one `types.dat` record into a [`TypeRecord`].
///
/// An unrecognised `kind` ordinal degrades to [`TypeKind::Raw`] rather than
/// failing the open: a forward-compatible writer adding a kind this build does
/// not know about must not make the whole trace unopenable.
fn decode_type_record(id: usize, raw: &[u8]) -> Result<TypeRecord, String> {
    if raw.is_empty() {
        return Err(format!("types.dat: record {id} is empty (missing kind byte)"));
    }
    let kind_byte = raw[0];
    let mut pos = 1usize;
    let lang_type_len = decode_varint(raw, &mut pos)? as usize;
    if pos + lang_type_len > raw.len() {
        return Err(format!("types.dat: record {id} lang_type extends past record"));
    }
    let lang_type = String::from_utf8_lossy(&raw[pos..pos + lang_type_len]).into_owned();
    pos += lang_type_len;
    let specific_info: TypeSpecificInfo = cbor4ii::serde::from_slice(&raw[pos..])
        .map_err(|e| format!("types.dat: record {id} specific_info CBOR decode failed: {e}"))?;
    Ok(TypeRecord {
        kind: TypeKind::from_u8(kind_byte).unwrap_or(TypeKind::Raw),
        lang_type,
        specific_info,
    })
}

#[cfg(test)]
// Unit tests: `unwrap` is the readable spelling of "this fixture is well
// formed, and a panic here IS the failure report". The crate denies it on
// production paths (`main.rs:4`); this is the local-allow convention that
// file documents at line 53.
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    /// A `.off` index that is not a whole number of `u64`s is rejected by name,
    /// rather than silently truncating the table.
    #[test]
    fn off_index_must_be_a_multiple_of_eight() {
        let err = VarSizeTable::new("paths", vec![], &[0u8; 7]).unwrap_err();
        assert!(err.contains("paths.off"), "error names the file: {err}");
        assert!(err.contains("multiple of 8"), "error names the cause: {err}");
    }

    /// An empty `.off` is a truncated index, not an empty table: a genuinely
    /// empty table still carries the trailing sentinel offset.
    #[test]
    fn empty_off_index_is_rejected() {
        let err = VarSizeTable::new("funcs", vec![], &[]).unwrap_err();
        assert!(err.contains("sentinel"), "error explains the sentinel: {err}");
    }

    /// A single sentinel offset is the encoding of an empty (zero-record) table.
    #[test]
    fn sentinel_only_off_index_is_an_empty_table() {
        let table = VarSizeTable::new("types", vec![], &0u64.to_le_bytes()).unwrap();
        assert_eq!(table.count(), 0);
        assert!(table.record(0).is_err(), "record 0 of an empty table is out of range");
    }

    /// Records are sliced by the offset index, so a mid-table id costs the same
    /// as the first and returns exactly its own bytes.
    #[test]
    fn records_are_sliced_by_the_offset_index() {
        let dat = b"alphabetagamma".to_vec();
        let mut off = Vec::new();
        for boundary in [0u64, 5, 9, 14] {
            off.extend_from_slice(&boundary.to_le_bytes());
        }
        let table = VarSizeTable::new("varnames", dat, &off).unwrap();
        assert_eq!(table.count(), 3);
        assert_eq!(table.record(0).unwrap(), b"alpha");
        assert_eq!(table.record(1).unwrap(), b"beta");
        assert_eq!(table.record(2).unwrap(), b"gamma");
    }

    /// An offset pointing past the end of `.dat` is reported rather than
    /// panicking on the slice.
    #[test]
    fn out_of_range_offsets_are_reported_not_panicked() {
        let mut off = Vec::new();
        for boundary in [0u64, 99] {
            off.extend_from_slice(&boundary.to_le_bytes());
        }
        let table = VarSizeTable::new("paths", b"short".to_vec(), &off).unwrap();
        let err = table.record(0).unwrap_err();
        assert!(err.contains("out of range"), "{err}");
    }

    /// A `funcs.dat` record's packed `global_line_index` recovers the real
    /// definition site — the field the Nim FFI path stubs to `(0, 0)`.
    #[test]
    fn func_record_recovers_its_definition_site() {
        use codetracer_trace_writer::step_stream::pack_global_line_index;

        let gli = pack_global_line_index(7, 42);
        let mut raw = Vec::new();
        encode_varint(&mut raw, gli);
        encode_varint(&mut raw, 3);
        raw.extend_from_slice(b"run");

        let record = decode_func_record(0, &raw).unwrap();
        assert_eq!(record.name, "run");
        assert_eq!(record.path_id, PathId(7));
        assert_eq!(record.line, Line(42));
    }

    /// A truncated function name is an error naming the record, not a panic.
    #[test]
    fn truncated_func_name_is_reported() {
        let mut raw = Vec::new();
        encode_varint(&mut raw, 0);
        encode_varint(&mut raw, 10);
        raw.extend_from_slice(b"ab");
        let err = decode_func_record(3, &raw).unwrap_err();
        assert!(err.contains("record 3"), "{err}");
    }

    /// An unknown `TypeKind` ordinal degrades to `Raw` so a forward-compatible
    /// writer cannot make a trace unopenable.
    #[test]
    fn unknown_type_kind_degrades_to_raw() {
        let mut raw = vec![0xfe];
        encode_varint(&mut raw, 3);
        raw.extend_from_slice(b"u64");
        raw.extend_from_slice(&cbor4ii::serde::to_vec(Vec::new(), &TypeSpecificInfo::None).unwrap());

        let record = decode_type_record(0, &raw).unwrap();
        assert_eq!(record.kind, TypeKind::Raw);
        assert_eq!(record.lang_type, "u64");
    }

    /// A varint that never terminates within 64 bits is rejected instead of
    /// looping.
    #[test]
    fn overlong_varint_is_rejected() {
        let data = [0xffu8; 12];
        let mut pos = 0usize;
        let err = decode_varint(&data, &mut pos).unwrap_err();
        assert!(err.contains("too long"), "{err}");
    }

    fn encode_varint(out: &mut Vec<u8>, mut value: u64) {
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            out.push(byte);
            if value == 0 {
                break;
            }
        }
    }
}
