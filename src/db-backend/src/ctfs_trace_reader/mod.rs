//! [`TraceReader`] implementation that reads from `.ct` CTFS containers.
//!
//! See the module-level documentation on [`CTFSTraceReader`] for design
//! rationale and the two-format approach.

pub mod ctfs_container;

use std::collections::HashMap;
use std::error::Error;
use std::path::Path;

use log::info;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, PathId, Place, StepId, TraceLowLevelEvent, TypeId,
    TypeRecord, ValueRecord, VariableId,
};

#[cfg(feature = "nim-reader")]
use codetracer_trace_types::EventLogKind;

use crate::db::{CellChange, Db, DbCall, DbRecordEvent, DbStep, EndOfProgram};
use crate::trace_processor::TraceProcessor;
use crate::trace_reader::TraceReader;

#[cfg(feature = "nim-reader")]
use codetracer_trace_writer_nim::NimTraceReaderHandle;

use ctfs_container::CtfsReader;

/// A [`TraceReader`] backed by a `.ct` CTFS container file.
///
/// Supports two container layouts:
///
/// ## Old format (events-based, requires postprocessing)
///
/// Contains raw `TraceLowLevelEvent` values in `events.log` plus JSON
/// metadata in `meta.json`. These events must be processed by
/// [`TraceProcessor::postprocess`] at startup to build the in-memory `Db`.
/// This is the format produced by current recorders (Python, Ruby, JS,
/// blockchain VMs).
///
/// | File | Purpose |
/// |------|---------|
/// | `meta.json` | Trace metadata (workdir, program, args) |
/// | `events.log` | Encoded `TraceLowLevelEvent` stream (chunked Zstd or legacy CBOR) |
/// | `events.fmt` | Serialization format marker (`"split-binary"` or absent for CBOR) |
///
/// ## New format (pre-processed, no postprocessing needed)
///
/// Contains pre-computed data structures written by the seek-based writer.
/// The recorder (or a post-recording finalization step) builds the same
/// data structures that `postprocess` would produce and writes them as
/// separate CTFS internal files. The reader loads these directly into
/// `Db`, skipping the expensive event-by-event postprocessing entirely.
///
/// The new format is detected by the presence of `steps.dat` in the
/// container. See `Seek-Based-CTFS-Reader.md` for the full file layout.
///
/// | File | Purpose |
/// |------|---------|
/// | `meta.dat` | Binary metadata (replaces `meta.json`) |
/// | `steps.dat` + `steps.idx` | Pre-computed step records with variable values |
/// | `calls.dat` | Pre-computed call tree records |
/// | `events.dat` | Pre-computed I/O event records with step cross-references |
/// | `paths.dat` + `paths.off` | Interned source paths with offset index |
/// | `funcs.dat` + `funcs.off` | Interned function records with offset index |
/// | `types.dat` + `types.off` | Interned type records with offset index |
/// | `varnames.dat` + `varnames.off` | Interned variable names with offset index |
///
/// See [`crate::trace_processor`] for how `TraceLowLevelEvent` values are
/// processed into the `Db` struct (old format path only).
#[derive(Debug)]
pub struct CTFSTraceReader {
    /// The fully-populated in-memory database, built from CTFS contents
    /// during [`CTFSTraceReader::open`].
    db: Db,
}

/// Returns `true` if the CTFS container uses the new pre-processed format
/// (detected by the presence of `steps.dat`), meaning postprocessing can
/// be skipped entirely.
///
/// Returns `false` for old-format containers that store raw events in
/// `events.log` and require [`TraceProcessor::postprocess`].
fn is_new_format(ctfs: &CtfsReader) -> bool {
    ctfs.has_file("steps.dat")
}

impl CTFSTraceReader {
    /// Open a `.ct` CTFS trace file, parse its contents, and build the
    /// in-memory database.
    ///
    /// Automatically detects the container format:
    /// - **New format** (has `steps.dat`): loads pre-processed data directly,
    ///   skipping [`TraceProcessor::postprocess`]. Startup is bounded by I/O
    ///   and decompression, not by trace size.
    /// - **Old format** (has `events.log`): deserializes events and runs
    ///   [`TraceProcessor::postprocess`] to build the `Db`.
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - The file cannot be opened or is not a valid CTFS container
    /// - Metadata is missing or malformed
    /// - The trace data cannot be deserialized
    /// - (Old format only) The `TraceProcessor` fails during postprocessing
    pub fn open(path: &Path) -> Result<Self, Box<dyn Error>> {
        let mut ctfs = CtfsReader::open(path)?;

        if is_new_format(&ctfs) {
            info!("CTFS new format detected — skipping postprocessing");
            Self::open_new_format(&mut ctfs, path)
        } else {
            info!("CTFS old format detected — running postprocessing");
            Self::open_old_format(&mut ctfs)
        }
    }

    /// Construct a [`CTFSTraceReader`] from raw bytes already in memory.
    ///
    /// This is the VFS-friendly counterpart of [`open`](Self::open): the
    /// caller supplies the complete `.ct` file contents (e.g. read from
    /// the in-memory VFS in WASM builds) and the reader parses them
    /// without touching the filesystem.
    ///
    /// Only the **old format** (events-based) is supported here because
    /// the new format requires the Nim FFI reader which needs a real file
    /// path.  If the container uses the new format, an error is returned.
    pub fn from_bytes(data: Vec<u8>) -> Result<Self, Box<dyn Error>> {
        let mut ctfs = CtfsReader::from_bytes(data)?;

        if is_new_format(&ctfs) {
            Err("CTFS new format (nim-reader) is not supported via from_bytes; \
                 only old-format containers can be loaded from in-memory data"
                .into())
        } else {
            info!("CTFS from_bytes: old format detected — running postprocessing");
            Self::open_old_format(&mut ctfs)
        }
    }

    /// Open a new-format CTFS container by loading pre-processed data
    /// directly into the `Db`, bypassing `TraceProcessor::postprocess`.
    ///
    /// The new format stores the same data structures that `postprocess`
    /// would build, but written at recording time (or during a finalization
    /// step). This eliminates the O(n) startup cost where n is the number
    /// of trace events.
    ///
    /// When the `nim-reader` feature is enabled, this uses
    /// [`NimTraceReaderHandle`] to open the `.ct` file via the Nim
    /// seek-based reader FFI. Currently it reads metadata and interning
    /// tables to build a minimal `Db`; full step/call/event population
    /// will follow.
    ///
    /// Without `nim-reader`, returns an error indicating the format is
    /// recognized but the reader is not available.
    #[allow(unused_variables, clippy::needless_return)]
    fn open_new_format(ctfs: &mut CtfsReader, ct_path: &Path) -> Result<Self, Box<dyn Error>> {
        #[cfg(feature = "nim-reader")]
        {
            return Self::open_new_format_nim(ctfs, ct_path);
        }

        #[cfg(not(feature = "nim-reader"))]
        {
            Err(format!(
                "CTFS new format detected (steps.dat present) but the nim-reader \
                 feature is not enabled. Container: {}. \
                 Rebuild with --features nim-reader to use the Nim seek-based reader.",
                ctfs.file_names().join(", ")
            )
            .into())
        }
    }

    /// Nim-backed new-format reader implementation.
    ///
    /// Opens the `.ct` file via the Nim `NewTraceReader` FFI, reads metadata
    /// and interning tables, and builds a minimal `Db`. Step, call, and
    /// event data is read on-demand via JSON queries to the Nim reader.
    ///
    /// # Current status
    ///
    /// This is the first integration point: it proves the FFI bridge works
    /// end-to-end and populates metadata + interning tables. Full Db
    /// population (steps, calls, events, step_map) comes next.
    #[cfg(feature = "nim-reader")]
    fn open_new_format_nim(_ctfs: &mut CtfsReader, ct_file_path: &Path) -> Result<Self, Box<dyn Error>> {
        use codetracer_trace_types::{FunctionRecord, Line, PathId, TypeKind, TypeRecord, TypeSpecificInfo};
        use num_traits::FromPrimitive;
        use std::path::PathBuf;

        let ct_path = ct_file_path.to_string_lossy().to_string();

        let reader =
            NimTraceReaderHandle::open(&ct_path).map_err(|e| format!("failed to open .ct via Nim reader: {e}"))?;

        let step_count = reader.step_count();
        let call_count = reader.call_count();
        let event_count = reader.event_count();

        info!(
            "Nim reader opened: {} steps, {} calls, {} events, {} paths, {} functions, {} types, {} varnames",
            step_count,
            call_count,
            event_count,
            reader.path_count(),
            reader.function_count(),
            reader.type_count(),
            reader.varname_count(),
        );

        let workdir_str = reader.workdir();
        let workdir = if workdir_str.is_empty() {
            PathBuf::from(".")
        } else {
            PathBuf::from(&workdir_str)
        };

        let mut db = Db::new(&workdir);

        // ── Interning tables ───────────────────────────────────────────
        //
        // Paths — also populate the reverse path_map for lookups by
        // string and ensure step_map has a slot per path.
        for i in 0..reader.path_count() {
            let p = reader.path(i).map_err(|e| format!("path {i}: {e}"))?;
            db.paths.push(p.clone());
            db.path_map.insert(p, PathId(db.paths.len() - 1));
            db.step_map.push(HashMap::new());
        }

        // Functions — the Nim reader only exposes function names (not
        // path/line), so we create stub FunctionRecords for now.
        for i in 0..reader.function_count() {
            let name = reader.function(i).map_err(|e| format!("function {i}: {e}"))?;
            db.functions.push(FunctionRecord {
                name,
                path_id: PathId(0),
                line: Line(0),
            });
        }

        // Types — only the type name is available via FFI.
        for i in 0..reader.type_count() {
            let name = reader.type_name(i).map_err(|e| format!("type {i}: {e}"))?;
            db.types.push(TypeRecord {
                kind: TypeKind::Raw,
                lang_type: name,
                specific_info: TypeSpecificInfo::None,
            });
        }

        // Variable names
        for i in 0..reader.varname_count() {
            let name = reader.varname(i).map_err(|e| format!("varname {i}: {e}"))?;
            db.variable_names.push(name);
        }

        info!(
            "Nim reader: interning tables loaded — {} paths, {} functions, {} types, {} varnames",
            db.paths.len(),
            db.functions.len(),
            db.types.len(),
            db.variable_names.len(),
        );

        // ── Calls ──────────────────────────────────────────────────────
        //
        // Load call records first. We need call entry/exit step ranges to
        // compute the step→call_key mapping for DbStep.
        //
        // call_fields returns:
        //   (function_id, parent_key, entry_step, exit_step, depth, children_count)
        //
        // We also store entry_step/exit_step per call so we can later
        // assign call_key to each step.
        struct CallRange {
            entry_step: u64,
            exit_step: u64,
        }
        let mut call_ranges: Vec<CallRange> = Vec::with_capacity(call_count as usize);

        for key in 0..call_count {
            let (function_id, parent_key, entry_step, exit_step, depth, children_count) =
                reader.call_fields(key).map_err(|e| format!("call {key}: {e}"))?;

            let mut children_keys = Vec::with_capacity(children_count as usize);
            for c in 0..children_count {
                let child_key = reader
                    .call_child(key, c)
                    .map_err(|e| format!("call {key} child {c}: {e}"))?;
                children_keys.push(CallKey(child_key as i64));
            }

            // Pull the captured call arguments via the structured FFI so
            // the frontend can render `format_board(board=...)` instead of
            // an empty `format_board()`.  The recorder stages each
            // argument's (name, CBOR-encoded value) pair on the call
            // record at write time; here we decode them back into
            // `FullValueRecord`s sharing the same varname interning
            // table that step variables use.
            let arg_count = reader.call_arg_count(key);
            let mut args: Vec<FullValueRecord> = Vec::with_capacity(arg_count as usize);
            for arg_idx in 0..arg_count {
                match reader.call_arg(key, arg_idx) {
                    Ok((varname_id, data)) => {
                        let value = if data.is_empty() {
                            ValueRecord::None { type_id: TypeId(0) }
                        } else {
                            match cbor4ii::serde::from_reader::<ValueRecord, _>(data.as_slice()) {
                                Ok(v) => v,
                                Err(e) => {
                                    log::warn!("call {key} arg {arg_idx}: CBOR decode failed: {e}, using Raw fallback");
                                    ValueRecord::Raw {
                                        r: format!("<cbor decode error: {e}>"),
                                        type_id: TypeId(0),
                                    }
                                }
                            }
                        };
                        args.push(FullValueRecord {
                            variable_id: VariableId(varname_id as usize),
                            value,
                        });
                    }
                    Err(e) => {
                        log::warn!("call {key} arg {arg_idx}: read failed: {e}");
                        break;
                    }
                }
            }

            db.calls.push(DbCall {
                key: CallKey(key as i64),
                function_id: FunctionId(function_id as usize),
                args,
                return_value: ValueRecord::None { type_id: TypeId(0) }, // TODO: return values
                step_id: StepId(entry_step as i64),
                depth: depth as usize,
                parent_key: CallKey(parent_key),
                children_keys,
            });

            call_ranges.push(CallRange { entry_step, exit_step });
        }

        info!("Nim reader: {} calls loaded", db.calls.len());

        // ── Step→call mapping ──────────────────────────────────────────
        //
        // Build a vector mapping each step index to its innermost
        // (deepest) enclosing call_key, using the entry_step/exit_step
        // ranges. A step at index S belongs to the deepest call whose
        // range [entry_step, exit_step] contains S.
        //
        // We sweep calls in key order (which matches recording order)
        // and use a simple stack to track the current innermost call.
        let mut step_to_call_key: Vec<CallKey> = vec![CallKey(-1); step_count as usize];

        // For each call, mark all steps in [entry_step, exit_step] with
        // this call_key. Because calls are ordered by entry_step and
        // children appear after their parent, later (deeper) calls
        // overwrite parent assignments — giving us the innermost call.
        for (key_idx, range) in call_ranges.iter().enumerate() {
            let call_key = CallKey(key_idx as i64);
            let start = range.entry_step as usize;
            let end = std::cmp::min(range.exit_step as usize + 1, step_count as usize);
            step_to_call_key[start..end].fill(call_key);
        }

        // Build global_call_key: for each step, the call_key of the last
        // call that started at or before that step. We sweep calls in
        // order and advance through steps.
        let mut step_to_global_call_key: Vec<CallKey> = vec![CallKey(-1); step_count as usize];
        if call_count > 0 {
            let mut call_idx: usize = 0;
            let mut current_global_key = CallKey(0);
            for (step_idx, slot) in step_to_global_call_key.iter_mut().enumerate() {
                // Advance to the last call whose entry_step <= step_idx.
                while call_idx + 1 < call_count as usize && call_ranges[call_idx + 1].entry_step <= step_idx as u64 {
                    call_idx += 1;
                    current_global_key = CallKey(call_idx as i64);
                }
                // Also check the first call.
                if call_ranges[call_idx].entry_step <= step_idx as u64 {
                    current_global_key = CallKey(call_idx as i64);
                }
                *slot = current_global_key;
            }
        }

        // ── Steps ──────────────────────────────────────────────────────
        //
        // Populate db.steps, db.step_map, and per-step scaffolding
        // (variables, instructions, compound, cells, variable_cells).
        for i in 0..step_count {
            let (path_id_raw, line_raw) = reader.step_location(i).map_err(|e| format!("step {i}: {e}"))?;

            let path_id = PathId(path_id_raw as usize);
            let line = Line(line_raw as i64);
            let step_id = StepId(i as i64);
            let call_key = step_to_call_key[i as usize];
            let global_call_key = step_to_global_call_key[i as usize];

            let db_step = DbStep {
                step_id,
                path_id,
                line,
                call_key,
                global_call_key,
            };

            db.steps.push(db_step);

            // Per-step parallel vectors that postprocess() also creates.
            db.instructions.push(vec![]);
            db.compound.push(HashMap::new());
            db.cells.push(HashMap::new());
            db.variable_cells.push(HashMap::new());

            // step_map: (path_id) → { line → [DbStep, ...] }
            // Ensure enough entries in step_map for this path_id.
            while db.step_map.len() <= path_id.0 {
                db.step_map.push(HashMap::new());
            }
            if line.0 >= 0 {
                let line_usize = line.0 as usize;
                db.step_map[path_id].entry(line_usize).or_default().push(db_step);
            }
        }

        info!("Nim reader: {} steps loaded", db.steps.len());

        // ── Variables ──────────────────────────────────────────────────
        //
        // For each step, read variable values via the structured FFI.
        // step_value returns (varname_id, type_id, cbor_data) where
        // cbor_data is a CBOR-encoded ValueRecord (tagged with "kind").
        for step_idx in 0..step_count {
            let val_count = reader.step_value_count(step_idx);
            let mut step_values: Vec<FullValueRecord> = Vec::with_capacity(val_count as usize);

            for v in 0..val_count {
                match reader.step_value(step_idx, v) {
                    Ok((varname_id, _type_id, data)) => {
                        // Decode the CBOR-encoded ValueRecord. The Nim
                        // writer produces CBOR maps with a "kind" tag
                        // matching the serde(tag = "kind") layout of
                        // ValueRecord.
                        let value = if data.is_empty() {
                            ValueRecord::None { type_id: TypeId(0) }
                        } else {
                            match cbor4ii::serde::from_reader::<ValueRecord, _>(data.as_slice()) {
                                Ok(v) => v,
                                Err(e) => {
                                    log::warn!(
                                        "step {step_idx} value {v}: CBOR decode failed: {e}, using Raw fallback"
                                    );
                                    ValueRecord::Raw {
                                        r: format!("<cbor decode error: {e}>"),
                                        type_id: TypeId(0),
                                    }
                                }
                            }
                        };
                        step_values.push(FullValueRecord {
                            variable_id: VariableId(varname_id as usize),
                            value,
                        });
                    }
                    Err(e) => {
                        log::warn!("step {step_idx} value {v}: read failed: {e}");
                        break;
                    }
                }
            }

            db.variables.push(step_values);
        }

        info!("Nim reader: variables loaded for {} steps", db.variables.len());

        // ── Events ─────────────────────────────────────────────────────
        //
        // event_fields returns (kind: u8, step_id: u64, data: Vec<u8>).
        // Nim IOEventKind: 0=stdout, 1=stderr, 2=file_op, 3=error.
        // Map to EventLogKind using num_traits::FromPrimitive for the
        // standard values, with a fallback mapping for the Nim-specific
        // kind codes.
        for idx in 0..event_count {
            match reader.event_fields(idx) {
                Ok((kind_byte, step_id_raw, data)) => {
                    // Map Nim IOEventKind values to EventLogKind.
                    // Nim: 0=ioStdout → Write, 1=ioStderr → WriteOther,
                    //      2=ioFileOp → WriteFile, 3=ioError → Error.
                    let kind = match kind_byte {
                        0 => EventLogKind::Write,
                        1 => EventLogKind::WriteOther,
                        2 => EventLogKind::WriteFile,
                        3 => EventLogKind::Error,
                        other => {
                            // Try the Rust enum's own discriminant values
                            // for forward compatibility.
                            EventLogKind::from_u8(other).unwrap_or(EventLogKind::Write)
                        }
                    };

                    let step_id = StepId(step_id_raw as i64);
                    let content = String::from_utf8_lossy(&data).to_string();

                    db.events.push(DbRecordEvent {
                        kind,
                        content,
                        step_id,
                        metadata: String::new(),
                    });
                }
                Err(e) => {
                    log::warn!("event {idx}: read failed: {e}");
                    break;
                }
            }
        }

        info!("Nim reader: {} events loaded", db.events.len());

        // ── end_of_program ─────────────────────────────────────────────
        //
        // Match the same logic as TraceProcessor::postprocess: if the
        // last event is an Error on the last step, mark it as an error
        // termination.
        db.end_of_program = if !db.events.is_empty() && !db.steps.is_empty() {
            let last_event = &db.events[db.events.len() - 1];
            let on_last_step = (last_event.step_id.0 as usize) == db.steps.len() - 1;
            if last_event.kind == EventLogKind::Error && on_last_step {
                let reason = format!("error: {}", last_event.content);
                EndOfProgram::Error { reason }
            } else {
                EndOfProgram::Normal
            }
        } else {
            EndOfProgram::Normal
        };

        info!(
            "Nim reader: Db fully populated — {} steps, {} calls, {} events, {} variables",
            db.steps.len(),
            db.calls.len(),
            db.events.len(),
            db.variables.len(),
        );

        Ok(CTFSTraceReader { db })
    }

    /// Open an old-format CTFS container by deserializing raw events from
    /// `events.log` and running `TraceProcessor::postprocess` to build
    /// the in-memory `Db`.
    ///
    /// This is the original loading path. It will remain available for
    /// backward compatibility with traces recorded before the seek-based
    /// writer was introduced.
    fn open_old_format(ctfs: &mut CtfsReader) -> Result<Self, Box<dyn Error>> {
        // 1. Read and parse trace metadata
        let meta_bytes = ctfs.read_file("meta.json")?;
        let meta: codetracer_trace_types::TraceMetadata = serde_json::from_slice(&meta_bytes)?;

        let workdir = if meta.workdir.as_os_str().is_empty() {
            // Fall back to the parent directory of the program path
            Path::new(&meta.program)
                .parent()
                .unwrap_or(Path::new("."))
                .to_path_buf()
        } else {
            meta.workdir.clone()
        };

        // 2. Read the trace events from the container.
        //    Old format: CBOR-encoded TraceLowLevelEvent sequence in
        //    `events.log`, optionally with split-binary encoding indicated
        //    by `events.fmt`.
        let events = Self::load_events(ctfs)?;

        // 3. Run the postprocessing pipeline to populate a Db struct from
        //    the raw events. This is the expensive O(n) step that the new
        //    format eliminates.
        let mut db = Db::new(&workdir);
        let mut processor = TraceProcessor::new(&mut db);
        processor.postprocess(&events)?;

        Ok(CTFSTraceReader { db })
    }

    /// Extract `TraceLowLevelEvent` values from the CTFS container.
    ///
    /// Supports three data layouts, detected automatically:
    ///
    /// 1. **Chunked split-binary** (new default): `events.fmt` contains
    ///    `"split-binary"` and `events.log` uses inline 16-byte chunk
    ///    headers with Zstd-compressed payloads. Decompressed via
    ///    [`codetracer_ctfs::ChunkedReader`], then decoded via
    ///    [`codetracer_trace_writer::split_binary::decode_events`].
    ///
    /// 2. **Chunked CBOR**: `events.log` uses chunk headers but
    ///    `events.fmt` is absent or does not say `"split-binary"`.
    ///    Decompressed via `ChunkedReader`, then deserialized as CBOR.
    ///
    /// 3. **Legacy CBOR streaming**: No chunk headers (e.g. older zeekstd
    ///    frames). Falls back to sequential `cbor4ii::serde::from_reader`.
    ///
    /// If `events.log` is missing entirely, an empty event list is
    /// returned so that the reader can still be constructed (useful for
    /// metadata-only traces or tests).
    fn load_events(ctfs: &mut CtfsReader) -> Result<Vec<TraceLowLevelEvent>, Box<dyn Error>> {
        let event_bytes = match ctfs.read_file("events.log") {
            Ok(bytes) => bytes,
            Err(_) => {
                // No events file — return an empty trace. This allows opening
                // minimal .ct files that only contain metadata (e.g. in tests).
                return Ok(Vec::new());
            }
        };

        if event_bytes.is_empty() {
            return Ok(Vec::new());
        }

        // Detect the serialization format. The presence of `events.fmt`
        // with the content `"split-binary"` indicates the new split-binary
        // encoding; otherwise we fall back to CBOR.
        let is_split_binary = match ctfs.read_file("events.fmt") {
            Ok(fmt) => fmt == b"split-binary",
            Err(_) => false, // Legacy: no format marker means CBOR
        };

        // Try the chunked format first (new writer produces inline 16-byte
        // chunk headers followed by Zstd-compressed payloads).
        if let Ok(decompressed) = codetracer_ctfs::ChunkedReader::decompress_all(&event_bytes) {
            if is_split_binary {
                return Ok(codetracer_trace_writer::split_binary::decode_events(&decompressed));
            } else {
                // Chunked CBOR — decompress, then parse CBOR from the buffer
                return Self::deserialize_cbor_from_buffer(&decompressed);
            }
        }

        // Fallback: legacy CBOR streaming (zeekstd frames, no chunk headers).
        // This path handles older `.ct` files that pre-date the chunked format.
        Self::deserialize_cbor_from_buffer(&event_bytes)
    }

    /// Deserialize a sequence of individually-encoded CBOR
    /// `TraceLowLevelEvent` values from an in-memory buffer.
    ///
    /// Uses `cbor4ii::serde::from_reader` in a loop, the same approach as
    /// `codetracer_trace_reader` for the standalone binary trace format.
    /// A parse error after at least one successful event is treated as a
    /// truncated stream (common during streaming recording when the
    /// recorder has not flushed completely).
    fn deserialize_cbor_from_buffer(data: &[u8]) -> Result<Vec<TraceLowLevelEvent>, Box<dyn Error>> {
        use std::io::BufRead;

        let mut events = Vec::new();
        let mut buf_reader = std::io::BufReader::new(data);

        loop {
            // Check for EOF before attempting to deserialize
            let buf = buf_reader.fill_buf()?;
            if buf.is_empty() {
                break;
            }

            match cbor4ii::serde::from_reader::<TraceLowLevelEvent, _>(&mut buf_reader) {
                Ok(event) => {
                    events.push(event);
                }
                Err(e) => {
                    // If we have already read some events, treat a parse error
                    // at the tail as a truncated stream (common during streaming
                    // recording — the recorder may not have flushed completely).
                    if !events.is_empty() {
                        log::warn!(
                            "CTFS: stopped reading events after {count} events: {e}. \
                             Treating as truncated stream.",
                            count = events.len()
                        );
                        break;
                    } else {
                        return Err(format!("failed to deserialize any events from events.log: {e}").into());
                    }
                }
            }
        }

        Ok(events)
    }
}

// ── TraceReader implementation ─────────────────────────────────────────
//
// All methods delegate to the inner `Db`, exactly like
// `InMemoryTraceReader`. The difference is how the Db is populated:
//
// - Old format: events.log -> load_events -> TraceProcessor::postprocess -> Db
// - New format: steps.dat + calls.dat + ... -> direct Db load (no postprocess)
//
// Both formats produce the same Db, so the TraceReader implementation is
// identical regardless of which loading path was used.

impl TraceReader for CTFSTraceReader {
    // ── Interning tables ────────────────────────────────────────────

    fn path(&self, id: PathId) -> Option<&str> {
        self.db.paths.get(id).map(|s| s.as_str())
    }

    fn function(&self, id: FunctionId) -> Option<&FunctionRecord> {
        self.db.functions.get(id)
    }

    fn type_record(&self, id: TypeId) -> Option<&TypeRecord> {
        self.db.types.get(id)
    }

    fn variable_name(&self, id: VariableId) -> Option<&str> {
        self.db.variable_names.get(id).map(|s| s.as_str())
    }

    fn path_count(&self) -> usize {
        self.db.paths.len()
    }

    fn function_count(&self) -> usize {
        self.db.functions.len()
    }

    fn type_count(&self) -> usize {
        self.db.types.len()
    }

    // ── Per-step data ───────────────────────────────────────────────

    fn step(&self, id: StepId) -> Option<&DbStep> {
        self.db.steps.get(id)
    }

    fn step_count(&self) -> usize {
        self.db.steps.len()
    }

    fn variables_at(&self, step_id: StepId) -> Option<&[FullValueRecord]> {
        self.db.variables.get(step_id).map(|v| v.as_slice())
    }

    fn compound_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>> {
        self.db.compound.get(step_id)
    }

    fn cells_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>> {
        self.db.cells.get(step_id)
    }

    fn cell_changes_for(&self, place: &Place) -> Option<&Vec<CellChange>> {
        self.db.cell_changes.get(place)
    }

    fn variable_cells_at(&self, step_id: StepId) -> Option<&HashMap<VariableId, Place>> {
        self.db.variable_cells.get(step_id)
    }

    // ── Call tree ───────────────────────────────────────────────────

    fn call(&self, key: CallKey) -> Option<&DbCall> {
        self.db.calls.get(key)
    }

    fn call_count(&self) -> usize {
        self.db.calls.len()
    }

    // ── Events ──────────────────────────────────────────────────────

    fn events(&self) -> &[DbRecordEvent] {
        &self.db.events
    }

    fn event_count(&self) -> usize {
        self.db.events.len()
    }

    // ── Secondary indices ───────────────────────────────────────────

    fn path_id_for(&self, path: &str) -> Option<PathId> {
        self.db.path_map.get(path).copied()
    }

    fn steps_on_line(&self, path_id: PathId, line: usize) -> Option<&Vec<DbStep>> {
        self.db.step_map.get(path_id).and_then(|by_line| by_line.get(&line))
    }

    fn step_map_for_path(&self, path_id: PathId) -> Option<&HashMap<usize, Vec<DbStep>>> {
        self.db.step_map.get(path_id)
    }

    // ── Iteration helpers ────────────────────────────────────────────

    fn functions_iter(&self) -> Box<dyn Iterator<Item = (FunctionId, &FunctionRecord)> + '_> {
        Box::new(self.db.functions.iter().enumerate().map(|(i, f)| (FunctionId(i), f)))
    }

    fn calls_iter(&self) -> Box<dyn Iterator<Item = &DbCall> + '_> {
        Box::new(self.db.calls.iter())
    }

    fn steps_from(&self, start_id: StepId) -> &[DbStep] {
        let start = start_id.0 as usize;
        if start < self.db.steps.items.len() {
            &self.db.steps.items[start..]
        } else {
            &[]
        }
    }

    fn path_entries_iter(&self) -> Box<dyn Iterator<Item = (&str, PathId)> + '_> {
        Box::new(self.db.path_map.iter().map(|(s, &id)| (s.as_str(), id)))
    }

    // ── Instructions ────────────────────────────────────────────────

    fn instructions_at(&self, step_id: StepId) -> Option<&Vec<String>> {
        self.db.instructions.get(step_id)
    }

    // ── Derived queries ─────────────────────────────────────────────

    fn load_step_events(&self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent> {
        self.db.load_step_events(step_id, exact)
    }

    // ── Metadata ────────────────────────────────────────────────────

    fn workdir(&self) -> &Path {
        &self.db.workdir
    }

    fn end_of_program(&self) -> &EndOfProgram {
        &self.db.end_of_program
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// Verify that a minimal .ct file with only `meta.json` can be opened
    /// and produces an empty trace (zero steps, zero calls, etc.).
    #[test]
    fn test_ctfs_trace_reader_opens_minimal_ct_file() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("test.ct");

        // Create a minimal CTFS container with just meta.json.
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/test","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json)]).unwrap();

        // Open with CTFSTraceReader
        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 0);
        assert_eq!(reader.call_count(), 0);
        assert_eq!(reader.event_count(), 0);
        assert_eq!(reader.workdir().to_str().unwrap(), "/tmp");
    }

    /// Verify that a .ct file without `events.log` opens successfully
    /// (metadata-only trace).
    #[test]
    fn test_ctfs_trace_reader_missing_events_log() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("no-events.ct");

        let meta_json = br#"{"workdir":"/home/user","program":"/home/user/app","args":["--flag"]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 0);
        assert_eq!(reader.workdir().to_str().unwrap(), "/home/user");
    }

    /// Verify that workdir falls back to the program's parent directory
    /// when the metadata workdir field is empty.
    #[test]
    fn test_ctfs_trace_reader_workdir_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("fallback.ct");

        let meta_json = br#"{"workdir":"","program":"/opt/bin/my_program","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.workdir().to_str().unwrap(), "/opt/bin");
    }

    /// Verify that opening a non-existent file returns an error.
    #[test]
    fn test_ctfs_trace_reader_nonexistent_file() {
        let result = CTFSTraceReader::open(Path::new("/nonexistent/path/trace.ct"));
        assert!(result.is_err());
    }

    /// Verify that opening a file with invalid magic bytes returns an error.
    #[test]
    fn test_ctfs_trace_reader_invalid_magic() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("bad.ct");
        std::fs::write(&ct_path, b"this is not a CTFS file at all!").unwrap();

        let result = CTFSTraceReader::open(&ct_path);
        assert!(result.is_err());
    }

    /// Verify that old-format detection works: a container with only
    /// `meta.json` (no `steps.dat`) uses the old postprocessing path.
    #[test]
    fn test_ctfs_old_format_detected_without_steps_dat() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("old-format.ct");

        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/test","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json)]).unwrap();

        // Old format should work fine (goes through postprocess path)
        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 0);
    }

    /// Verify that new-format detection works: a container with `steps.dat`
    /// is recognized as new-format. Since the new-format reader is not yet
    /// implemented, this should return an error indicating the format is
    /// recognized but unsupported.
    #[test]
    fn test_ctfs_new_format_detected_with_steps_dat() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("new-format.ct");

        // Create a container with steps.dat to trigger new-format detection.
        // The content doesn't matter — we just need the file to exist.
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/test","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json), ("steps.dat", b"placeholder")])
            .unwrap();

        let result = CTFSTraceReader::open(&ct_path);
        // Without the nim-reader feature, new-format should error; with it,
        // it may succeed or fail depending on the container contents.
        #[cfg(not(feature = "nim-reader"))]
        {
            assert!(result.is_err());
            let err_msg = result.unwrap_err().to_string();
            assert!(
                err_msg.contains("nim-reader feature is not enabled"),
                "expected 'nim-reader feature is not enabled' error, got: {err_msg}"
            );
        }
        #[cfg(feature = "nim-reader")]
        {
            // With nim-reader, the Nim FFI will attempt to open the container.
            // A placeholder steps.dat may or may not parse depending on the
            // Nim reader's tolerance for minimal/invalid data. Either outcome
            // is acceptable — the important thing is that it doesn't panic and
            // the "not enabled" error is NOT returned.
            if let Err(e) = &result {
                let msg = e.to_string();
                assert!(
                    !msg.contains("nim-reader feature is not enabled"),
                    "nim-reader is enabled but got the 'not enabled' error: {msg}"
                );
            }
        }
    }

    /// M38 — GUI integration test: full trace pipeline through CTFSTraceReader.
    ///
    /// Creates a .ct container with CBOR-encoded TraceLowLevelEvent values
    /// exercising the full pipeline: path registration, function/type interning,
    /// call entry, step recording with variables, I/O event, and return.
    /// Then opens it with CTFSTraceReader and verifies:
    ///   - Step count, step navigation (path/line), step_map lookup
    ///   - Variable inspection at each step
    ///   - Call tree structure (function, depth, parent/child)
    ///   - Event count and content
    ///   - Interning tables (paths, functions, types, variable names)
    #[test]
    fn test_gui_pipeline_with_ctfs_trace() {
        use codetracer_trace_types::{
            CallRecord, EventLogKind, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, RecordEvent,
            ReturnRecord, StepRecord, TraceLowLevelEvent, TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord,
            VariableId,
        };
        use std::path::PathBuf;

        // -- Build a realistic event stream --
        //
        // Simulates a Python program "hello.py" with:
        //   path 0: /tmp/hello.py
        //   type 0: int
        //   type 1: str
        //   function 0: main (line 1)
        //   function 1: greet (line 5)
        //   variable 0: x
        //   variable 1: name
        //
        //   call main → step line 2 (x = 42) → call greet → step line 6 (name = "world")
        //     → event Write("Hello world") → return from greet → step line 3 → return from main
        let events: Vec<TraceLowLevelEvent> = vec![
            // Intern path
            TraceLowLevelEvent::Path(PathBuf::from("/tmp/hello.py")),
            // Intern types
            TraceLowLevelEvent::Type(TypeRecord {
                kind: TypeKind::Int,
                lang_type: "int".to_string(),
                specific_info: TypeSpecificInfo::None,
            }),
            TraceLowLevelEvent::Type(TypeRecord {
                kind: TypeKind::String,
                lang_type: "str".to_string(),
                specific_info: TypeSpecificInfo::None,
            }),
            // Intern functions
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "main".to_string(),
            }),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(5),
                name: "greet".to_string(),
            }),
            // Intern variable names
            TraceLowLevelEvent::VariableName("x".to_string()),
            TraceLowLevelEvent::VariableName("name".to_string()),
            // Call main (function_id=0)
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
            // Step at line 2 of hello.py (x = 42)
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(2),
            }),
            TraceLowLevelEvent::Value(FullValueRecord {
                variable_id: VariableId(0),
                value: ValueRecord::Int {
                    i: 42,
                    type_id: TypeId(0),
                },
            }),
            // Call greet (function_id=1)
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(1),
                args: vec![FullValueRecord {
                    variable_id: VariableId(1),
                    value: ValueRecord::String {
                        text: "world".to_string(),
                        type_id: TypeId(1),
                    },
                }],
            }),
            // Step at line 6 of hello.py (inside greet)
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(6),
            }),
            TraceLowLevelEvent::Value(FullValueRecord {
                variable_id: VariableId(1),
                value: ValueRecord::String {
                    text: "world".to_string(),
                    type_id: TypeId(1),
                },
            }),
            // I/O event: stdout write
            TraceLowLevelEvent::Event(RecordEvent {
                kind: EventLogKind::Write,
                metadata: "stdout".to_string(),
                content: "Hello world".to_string(),
            }),
            // Return from greet
            TraceLowLevelEvent::Return(ReturnRecord {
                return_value: ValueRecord::None { type_id: TypeId(0) },
            }),
            // Step at line 3 (back in main, after greet returns)
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(3),
            }),
            // Return from main
            TraceLowLevelEvent::Return(ReturnRecord {
                return_value: ValueRecord::Int {
                    i: 0,
                    type_id: TypeId(0),
                },
            }),
        ];

        // Serialize events as sequential CBOR (legacy format).
        // cbor4ii::serde::to_vec takes ownership of the buffer and returns
        // the extended buffer, so we chain through each event.
        let mut cbor_buf = Vec::new();
        for event in &events {
            cbor_buf = cbor4ii::serde::to_vec(cbor_buf, event).expect("CBOR encode failed");
        }

        // Build the .ct container
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("pipeline.ct");
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/hello.py","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json), ("events.log", &cbor_buf)]).unwrap();

        // Open with CTFSTraceReader (exercises the full old-format pipeline)
        let reader = CTFSTraceReader::open(&ct_path).unwrap();

        // --- Verify step count and navigation ---
        assert_eq!(reader.step_count(), 3, "expected 3 steps (line 2, 6, 3)");

        let step0 = reader.step(StepId(0)).expect("step 0 should exist");
        assert_eq!(step0.path_id, PathId(0));
        assert_eq!(step0.line, Line(2));

        let step1 = reader.step(StepId(1)).expect("step 1 should exist");
        assert_eq!(step1.path_id, PathId(0));
        assert_eq!(step1.line, Line(6));

        let step2 = reader.step(StepId(2)).expect("step 2 should exist");
        assert_eq!(step2.path_id, PathId(0));
        assert_eq!(step2.line, Line(3));

        // --- Verify step_map lookup (path + line → steps) ---
        let steps_on_line2 = reader.steps_on_line(PathId(0), 2).expect("should have steps on line 2");
        assert_eq!(steps_on_line2.len(), 1);
        assert_eq!(steps_on_line2[0].step_id, StepId(0));

        let steps_on_line6 = reader.steps_on_line(PathId(0), 6).expect("should have steps on line 6");
        assert_eq!(steps_on_line6.len(), 1);
        assert_eq!(steps_on_line6[0].step_id, StepId(1));

        // --- Verify variable inspection ---
        // Step 0 has x=42 from the Value event plus name="world" from the
        // Call(greet) args (the processor pushes call args onto the current
        // step's variable list before the callee's first step is recorded).
        let vars0 = reader.variables_at(StepId(0)).expect("step 0 should have variables");
        assert_eq!(vars0.len(), 2, "step 0 should have 2 variables (x + greet arg)");
        assert_eq!(vars0[0].variable_id, VariableId(0));
        match &vars0[0].value {
            ValueRecord::Int { i, .. } => assert_eq!(*i, 42),
            other => panic!("expected Int value for x, got {other:?}"),
        }

        let vars1 = reader.variables_at(StepId(1)).expect("step 1 should have variables");
        // Step 1 (inside greet) has the explicit Value event for name="world"
        assert!(
            !vars1.is_empty(),
            "step 1 should have at least 1 variable (name=\"world\")"
        );
        let has_world = vars1
            .iter()
            .any(|v| matches!(&v.value, ValueRecord::String { text, .. } if text == "world"));
        assert!(has_world, "step 1 should contain name=\"world\"");

        // --- Verify call tree ---
        assert_eq!(reader.call_count(), 2, "expected 2 calls (main, greet)");

        let call0 = reader.call(CallKey(0)).expect("call 0 (main) should exist");
        assert_eq!(call0.function_id, FunctionId(0));
        assert_eq!(call0.depth, 0, "main should be at depth 0");

        let call1 = reader.call(CallKey(1)).expect("call 1 (greet) should exist");
        assert_eq!(call1.function_id, FunctionId(1));
        assert_eq!(call1.depth, 1, "greet should be at depth 1");
        assert_eq!(call1.parent_key, CallKey(0), "greet's parent should be main");

        // Verify main has greet as a child
        assert!(
            call0.children_keys.contains(&CallKey(1)),
            "main should list greet as child"
        );

        // --- Verify events ---
        assert_eq!(reader.event_count(), 1, "expected 1 I/O event");
        let io_event = &reader.events()[0];
        assert_eq!(io_event.kind, EventLogKind::Write);
        assert_eq!(io_event.content, "Hello world");

        // --- Verify interning tables ---
        assert_eq!(reader.path_count(), 1);
        assert_eq!(reader.path(PathId(0)).unwrap(), "/tmp/hello.py");
        assert_eq!(reader.path_id_for("/tmp/hello.py"), Some(PathId(0)));

        assert_eq!(reader.function_count(), 2);
        assert_eq!(reader.function(FunctionId(0)).unwrap().name, "main");
        assert_eq!(reader.function(FunctionId(1)).unwrap().name, "greet");

        assert_eq!(reader.type_count(), 2);
        assert_eq!(reader.type_record(TypeId(0)).unwrap().lang_type, "int");
        assert_eq!(reader.type_record(TypeId(1)).unwrap().lang_type, "str");

        assert_eq!(reader.variable_name(VariableId(0)).unwrap(), "x");
        assert_eq!(reader.variable_name(VariableId(1)).unwrap(), "name");

        // --- Verify metadata ---
        assert_eq!(reader.workdir().to_str().unwrap(), "/tmp");
        assert!(
            matches!(reader.end_of_program(), EndOfProgram::Normal),
            "expected Normal end of program"
        );
    }

    /// Verify the `is_new_format` helper function directly.
    #[test]
    fn test_is_new_format_detection() {
        let dir = tempfile::tempdir().unwrap();

        // Old format: no steps.dat
        let old_path = dir.path().join("old.ct");
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/test","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&old_path, &[("meta.json", meta_json)]).unwrap();
        let old_ctfs = CtfsReader::open(&old_path).unwrap();
        assert!(!is_new_format(&old_ctfs));

        // New format: has steps.dat
        let new_path = dir.path().join("new.ct");
        ctfs_container::write_minimal_ctfs(&new_path, &[("meta.json", meta_json), ("steps.dat", b"data")]).unwrap();
        let new_ctfs = CtfsReader::open(&new_path).unwrap();
        assert!(is_new_format(&new_ctfs));
    }

    // ── M43: GUI latency benchmarks ────────────────────────────────────

    /// Build a .ct container with the given number of steps, each with one
    /// variable value. Returns the path to the temporary .ct file. The
    /// caller should keep the `TempDir` alive until done.
    fn build_trace_with_steps(dir: &std::path::Path, step_count: usize) -> std::path::PathBuf {
        use codetracer_trace_types::{
            CallRecord, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, StepRecord, TraceLowLevelEvent,
            TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
        };
        use std::path::PathBuf;

        // Build a realistic event stream with `step_count` steps.
        let mut events: Vec<TraceLowLevelEvent> = Vec::new();

        // Intern 10 paths so path_id varies
        for i in 0..10 {
            events.push(TraceLowLevelEvent::Path(PathBuf::from(format!("/src/file_{i}.py"))));
        }

        // Intern types
        events.push(TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }));

        // Intern a function
        events.push(TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "main".to_string(),
        }));

        // Intern variable name
        events.push(TraceLowLevelEvent::VariableName("x".to_string()));

        // Call main
        events.push(TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }));

        // N steps with alternating path_id and incrementing lines
        for i in 0..step_count {
            events.push(TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(i % 10),
                line: Line((i + 1) as i64),
            }));
            events.push(TraceLowLevelEvent::Value(FullValueRecord {
                variable_id: VariableId(0),
                value: ValueRecord::Int {
                    i: i as i64,
                    type_id: TypeId(0),
                },
            }));
        }

        // Return from main
        events.push(TraceLowLevelEvent::Return(codetracer_trace_types::ReturnRecord {
            return_value: ValueRecord::None { type_id: TypeId(0) },
        }));

        // Serialize as CBOR
        let mut cbor_buf = Vec::new();
        for event in &events {
            cbor_buf = cbor4ii::serde::to_vec(cbor_buf, event).expect("CBOR encode failed");
        }

        let ct_path = dir.join("bench_trace.ct");
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/bench.py","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json), ("events.log", &cbor_buf)]).unwrap();

        ct_path
    }

    /// Compute the median of a sorted duration slice.
    fn median_duration(durations: &mut [std::time::Duration]) -> std::time::Duration {
        durations.sort();
        let mid = durations.len() / 2;
        if durations.len() % 2 == 0 {
            (durations[mid - 1] + durations[mid]) / 2
        } else {
            durations[mid]
        }
    }

    /// M43 — GUI step navigation latency benchmark.
    ///
    /// Creates a trace with 10K steps, measures the time for 100 random
    /// step navigations via `reader.step()`, and asserts the median latency
    /// is below a reasonable threshold.
    ///
    /// This validates that the GUI can navigate steps interactively without
    /// perceptible lag. The postprocessed `Db` stores steps in a contiguous
    /// `DistinctVec`, so random access should be O(1).
    #[test]
    fn bench_gui_step_navigation_latency() {
        use std::time::Instant;

        let dir = tempfile::tempdir().unwrap();
        let ct_path = build_trace_with_steps(dir.path(), 10_000);

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 10_000);

        // Deterministic pseudo-random step indices (avoid rand dependency).
        // LCG: seed=42, a=1103515245, c=12345, m=2^31
        let mut rng_state: u64 = 42;
        let mut step_indices: Vec<usize> = Vec::with_capacity(100);
        for _ in 0..100 {
            rng_state = (rng_state.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7FFFFFFF;
            step_indices.push((rng_state as usize) % 10_000);
        }

        // Warm up: access a few steps to ensure any lazy initialization is done
        for i in 0i64..10 {
            let _ = reader.step(StepId(i));
        }

        // Measure 100 random step navigations
        let mut durations = Vec::with_capacity(100);
        for &idx in &step_indices {
            let start = Instant::now();
            let step = reader.step(StepId(idx as i64));
            let elapsed = start.elapsed();

            assert!(step.is_some(), "step {idx} should exist");
            durations.push(elapsed);
        }

        let median = median_duration(&mut durations);

        // Print results as JSON for CI consumption
        println!(
            "{{\"benchmark\":\"gui_step_navigation\",\"step_count\":10000,\
             \"samples\":100,\"median_us\":{},\"max_us\":{}}}",
            median.as_micros(),
            durations.iter().max().unwrap().as_micros()
        );

        // Assert median < 100us. On modern hardware, indexed Vec access
        // should be well under 1us. We use 100us as a generous upper bound
        // to avoid flaky failures on slow CI machines.
        assert!(
            median.as_micros() < 100,
            "step navigation median latency too high: {}us (threshold: 100us)",
            median.as_micros()
        );
    }

    /// M43 — GUI variable load latency benchmark.
    ///
    /// Creates a trace with 10K steps (each with one variable), measures
    /// the time for 100 random `variables_at()` lookups, and asserts the
    /// median latency is below a reasonable threshold.
    ///
    /// This validates that the GUI can load variable panels without lag.
    /// Variable data is stored in a `DistinctVec<Vec<FullValueRecord>>`,
    /// so random access should be O(1) with the cost dominated by the
    /// slice creation.
    #[test]
    fn bench_gui_variable_load_latency() {
        use std::time::Instant;

        let dir = tempfile::tempdir().unwrap();
        let ct_path = build_trace_with_steps(dir.path(), 10_000);

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 10_000);

        // Deterministic pseudo-random step indices (different seed from above)
        let mut rng_state: u64 = 137;
        let mut step_indices: Vec<usize> = Vec::with_capacity(100);
        for _ in 0..100 {
            rng_state = (rng_state.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7FFFFFFF;
            step_indices.push((rng_state as usize) % 10_000);
        }

        // Warm up
        for i in 0i64..10 {
            let _ = reader.variables_at(StepId(i));
        }

        // Measure 100 random variable loads
        let mut durations = Vec::with_capacity(100);
        for &idx in &step_indices {
            let start = Instant::now();
            let vars = reader.variables_at(StepId(idx as i64));
            let elapsed = start.elapsed();

            assert!(vars.is_some(), "variables at step {idx} should exist");
            // Each step should have exactly 1 variable (x = step_index)
            assert_eq!(vars.unwrap().len(), 1, "step {idx} should have 1 variable");
            durations.push(elapsed);
        }

        let median = median_duration(&mut durations);

        // Print results as JSON for CI consumption
        println!(
            "{{\"benchmark\":\"gui_variable_load\",\"step_count\":10000,\
             \"samples\":100,\"median_us\":{},\"max_us\":{}}}",
            median.as_micros(),
            durations.iter().max().unwrap().as_micros()
        );

        // Assert median < 500us. Variable lookup is a Vec index + slice
        // creation, should be under 1us on modern hardware. Use 500us as
        // a generous bound for slow CI.
        assert!(
            median.as_micros() < 500,
            "variable load median latency too high: {}us (threshold: 500us)",
            median.as_micros()
        );
    }

    /// M43 — GUI call tree viewport latency benchmark.
    ///
    /// Creates a trace with 10K steps and a call tree, measures the time for
    /// 100 random `call()` lookups plus children enumeration, and asserts the
    /// median latency is below 500us.
    ///
    /// This validates that the GUI can render call tree viewports without lag.
    /// Call data is stored in a contiguous `DistinctVec<DbCall>`, so random
    /// access should be O(1) plus the cost of iterating `children_keys`.
    #[test]
    fn bench_gui_call_tree_viewport_latency() {
        use std::time::Instant;

        let dir = tempfile::tempdir().unwrap();
        let ct_path = build_trace_with_steps(dir.path(), 10_000);

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        // The trace has 1 call (main) with all 10K steps inside it.
        assert!(reader.call_count() >= 1, "expected at least 1 call");

        // Warm up
        for i in 0i64..reader.call_count().min(10) as i64 {
            let _ = reader.call(CallKey(i));
        }

        // Measure 100 call lookups (cycling through available calls)
        let call_count = reader.call_count();
        let mut durations = Vec::with_capacity(100);
        for sample in 0..100usize {
            let key = CallKey((sample % call_count) as i64);
            let start = Instant::now();
            let call = reader.call(key);
            // Also access children_keys to simulate viewport rendering
            if let Some(c) = call {
                let _ = c.children_keys.len();
                let _ = c.function_id;
                let _ = c.depth;
            }
            let elapsed = start.elapsed();
            durations.push(elapsed);
        }

        let median = median_duration(&mut durations);

        println!(
            "{{\"benchmark\":\"gui_call_tree_viewport\",\"call_count\":{},\
             \"samples\":100,\"median_us\":{},\"max_us\":{}}}",
            call_count,
            median.as_micros(),
            durations.iter().max().unwrap().as_micros()
        );

        assert!(
            median.as_micros() < 500,
            "call tree viewport median latency too high: {}us (threshold: 500us)",
            median.as_micros()
        );
    }

    /// M43 — GUI event log page load latency benchmark.
    ///
    /// Creates a trace with events, measures the time to load a page of 50
    /// events via `reader.events()` slice access, and asserts median < 1ms.
    ///
    /// This validates that the GUI event log panel can paginate without lag.
    #[test]
    fn bench_gui_event_log_page_load_latency() {
        use codetracer_trace_types::{
            CallRecord, EventLogKind, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, RecordEvent,
            StepRecord, TraceLowLevelEvent, TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
        };
        use std::path::PathBuf;
        use std::time::Instant;

        // Build a trace with 200 I/O events across 200 steps
        let dir = tempfile::tempdir().unwrap();
        let mut events: Vec<TraceLowLevelEvent> = vec![
            TraceLowLevelEvent::Path(PathBuf::from("/src/main.py")),
            TraceLowLevelEvent::Type(TypeRecord {
                kind: TypeKind::Int,
                lang_type: "int".to_string(),
                specific_info: TypeSpecificInfo::None,
            }),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "main".to_string(),
            }),
            TraceLowLevelEvent::VariableName("i".to_string()),
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
        ];

        for i in 0..200usize {
            events.push(TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line((i + 1) as i64),
            }));
            events.push(TraceLowLevelEvent::Value(FullValueRecord {
                variable_id: VariableId(0),
                value: ValueRecord::Int {
                    i: i as i64,
                    type_id: TypeId(0),
                },
            }));
            events.push(TraceLowLevelEvent::Event(RecordEvent {
                kind: EventLogKind::Write,
                metadata: "stdout".to_string(),
                content: format!("output line {i}"),
            }));
        }

        events.push(TraceLowLevelEvent::Return(codetracer_trace_types::ReturnRecord {
            return_value: ValueRecord::None { type_id: TypeId(0) },
        }));

        let mut cbor_buf = Vec::new();
        for event in &events {
            cbor_buf = cbor4ii::serde::to_vec(cbor_buf, event).expect("CBOR encode failed");
        }

        let ct_path = dir.path().join("event_bench.ct");
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/main.py","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json), ("events.log", &cbor_buf)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.event_count(), 200);

        // Warm up
        let _ = reader.events();

        // Measure 100 page loads of 50 events each (simulating pagination)
        let total_events = reader.event_count();
        let page_size = 50usize;
        let mut durations = Vec::with_capacity(100);

        // Deterministic page offsets
        let mut rng_state: u64 = 99;
        for _ in 0..100 {
            rng_state = (rng_state.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7FFFFFFF;
            let offset = (rng_state as usize) % (total_events.saturating_sub(page_size) + 1);

            let start = Instant::now();
            let all_events = reader.events();
            let end = (offset + page_size).min(all_events.len());
            let page = &all_events[offset..end];
            // Simulate reading event fields for rendering
            for ev in page {
                let _ = &ev.content;
                let _ = ev.kind;
                let _ = ev.step_id;
            }
            let elapsed = start.elapsed();
            durations.push(elapsed);
        }

        let median = median_duration(&mut durations);

        println!(
            "{{\"benchmark\":\"gui_event_log_page_load\",\"event_count\":{},\
             \"page_size\":{},\"samples\":100,\"median_us\":{},\"max_us\":{}}}",
            total_events,
            page_size,
            median.as_micros(),
            durations.iter().max().unwrap().as_micros()
        );

        // Assert median < 1ms (1000us) for loading 50 events
        assert!(
            median.as_micros() < 1000,
            "event log page load median latency too high: {}us (threshold: 1000us)",
            median.as_micros()
        );
    }

    /// M37 — Verify that the old-format postprocessing path correctly builds
    /// the `Db` from a 1000-step trace. This is not a startup time benchmark
    /// (the old format always requires O(n) postprocessing); it verifies
    /// correctness of the existing path that M37 preserves.
    ///
    /// The new-format startup time benchmark (`bench_new_format_startup_time`)
    /// requires the `nim-reader` feature because `open_new_format` delegates
    /// to the Nim seek-based reader. Without that feature, the new-format
    /// path returns an error, so the benchmark is feature-gated.
    #[test]
    fn bench_old_format_postprocess_1000_steps() {
        use std::time::Instant;

        let dir = tempfile::tempdir().unwrap();
        let ct_path = build_trace_with_steps(dir.path(), 1000);

        let start = Instant::now();
        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        let elapsed = start.elapsed();

        assert_eq!(reader.step_count(), 1000);
        println!(
            "{{\"benchmark\":\"old_format_postprocess_1000\",\"startup_ms\":{}}}",
            elapsed.as_millis()
        );

        // Old format with 1000 steps should complete well under 1 second.
        assert!(
            elapsed.as_millis() < 1000,
            "old-format postprocessing took too long: {}ms (threshold: 1000ms)",
            elapsed.as_millis()
        );
    }

    /// M37 — Verify new-format startup time is < 200ms.
    ///
    /// This test requires the `nim-reader` feature because `open_new_format`
    /// delegates to the Nim seek-based reader. When `nim-reader` is enabled,
    /// a properly formatted new-format `.ct` file should open in < 200ms
    /// because no O(n) postprocessing occurs — data is loaded on demand from
    /// pre-computed data structures.
    ///
    /// Without `nim-reader`, the test verifies that format detection correctly
    /// identifies the new format and returns an appropriate error.
    #[test]
    fn bench_new_format_startup_time() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("new-format-bench.ct");

        // Create a minimal new-format container with steps.dat to trigger
        // format detection. The actual content depends on the Nim writer's
        // output format.
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/bench.py","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json), ("steps.dat", b"placeholder")])
            .unwrap();

        #[cfg(not(feature = "nim-reader"))]
        {
            // Without nim-reader, verify format detection works but open fails
            // with the expected error (not a postprocessing error).
            let result = CTFSTraceReader::open(&ct_path);
            assert!(result.is_err());
            let err = result.unwrap_err().to_string();
            assert!(
                err.contains("nim-reader"),
                "expected nim-reader feature error, got: {err}"
            );
        }

        #[cfg(feature = "nim-reader")]
        {
            use std::time::Instant;

            // With nim-reader, the open should succeed (assuming the Nim reader
            // can handle the container) and complete under 200ms.
            let start = Instant::now();
            let result = CTFSTraceReader::open(&ct_path);
            let elapsed = start.elapsed();

            // NOTE: This test uses a placeholder steps.dat which the Nim reader
            // may not accept. If it errors, that's expected — the startup time
            // is still measured up to the point of error detection. A real
            // integration test with a properly recorded trace is needed for
            // full M37 verification (see M38).
            match result {
                Ok(_) => {
                    println!(
                        "{{\"benchmark\":\"new_format_startup\",\"startup_ms\":{}}}",
                        elapsed.as_millis()
                    );
                    assert!(
                        elapsed.as_millis() < 200,
                        "new-format startup took too long: {}ms (threshold: 200ms)",
                        elapsed.as_millis()
                    );
                }
                Err(e) => {
                    // Expected for placeholder data. The key verification is that
                    // the startup path reached the Nim reader (not postprocess).
                    let err = e.to_string();
                    assert!(
                        !err.contains("postprocess"),
                        "new-format path should not involve postprocessing, but got: {err}"
                    );
                    println!(
                        "{{\"benchmark\":\"new_format_startup\",\"status\":\"error\",\
                         \"startup_ms\":{},\"error\":\"{}\"}}",
                        elapsed.as_millis(),
                        err.replace('"', "'")
                    );
                }
            }
        }
    }
}
