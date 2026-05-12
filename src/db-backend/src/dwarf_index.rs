//! M-DWARF-1: DWARF parsing infrastructure for the db-backend.
//!
//! ## Purpose
//!
//! The F5 browser-replay path currently synthesises a single stack frame
//! whose `source.path` is taken straight from `meta.paths[0]` and whose
//! `line` is hard-coded to 1 (see `emulator_session.rs`). To get
//! production-grade replay we need to be able to ask, given an emulator
//! program counter, three things:
//!
//!   1. Which **source file** the PC corresponds to.
//!   2. Which **line / column** inside that file.
//!   3. Which **function** the PC is inside (for stack-frame names).
//!
//! This module owns the parsed-DWARF state and answers those questions
//! via [`DwarfIndex::resolve_pc`]. It also enumerates every source file
//! referenced by the binary via [`DwarfIndex::source_files`] so the
//! recorder side (M-DWARF-2) can attach source contents to the trace.
//!
//! ## Scope of M-DWARF-1
//!
//! This is the **foundation** milestone — pure parser infrastructure with
//! no recorder, emulator, or DAP wiring:
//!
//! * M-DWARF-2 plugs `source_files()` into the recorder to extract source
//!   blobs from the binary at record time.
//! * M-DWARF-3 plugs `resolve_pc()` into `emulator_session.rs` so DAP
//!   frames carry real source coordinates instead of `(paths[0], 1)`.
//! * M-DWARF-4 adds the CFI / `.eh_frame` walker for multi-frame stack
//!   unwinding.
//!
//! ## Implementation notes
//!
//! We build on the `addr2line`-on-`gimli` stack — the de-facto pure-Rust
//! solution for PC → line resolution. The full type chain is:
//!
//! ```text
//!     ELF bytes
//!         │
//!         ▼ object::File::parse
//!     object::File<'_>     (zero-copy view over the input bytes)
//!         │
//!         ▼ load each .debug_* section into an Arc<[u8]>
//!     gimli::Dwarf<EndianArcSlice<RunTimeEndian>>
//!         │
//!         ▼ addr2line::Context::from_dwarf
//!     addr2line::Context<EndianArcSlice<RunTimeEndian>>
//! ```
//!
//! We use `EndianArcSlice` (rather than `EndianSlice<'a>`) so the
//! [`DwarfIndex`] struct can own its DWARF data without dragging a
//! lifetime parameter through every caller — important because
//! `emulator_session.rs` (and eventually `dap_handler.rs`) will hold a
//! `DwarfIndex` for the entire lifetime of a replay session.
//!
//! The `object` crate's lifetime ties to the input bytes, but we never
//! store the `object::File` directly: we extract each `.debug_*` section
//! into an owned `Arc<[u8]>` and discard the `File` immediately.
//!
//! ## DWARF spec references
//!
//! Useful when reasoning about edge cases:
//! * DWARF v5 spec §6.2 (line number information) — file-table layout.
//! * DWARF v5 spec §3.3.1 (subprogram entries) — function name attrs.
//! * <https://dwarfstd.org/doc/DWARF5.pdf>

use std::borrow::Cow;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use addr2line::Context as Addr2lineContext;
use gimli::{EndianArcSlice, Reader as _, RunTimeEndian};
use object::{Object, ObjectSection};

/// Internal alias — the reader type the rest of this module deals with.
///
/// `EndianArcSlice<RunTimeEndian>` is a thread-safe, reference-counted
/// byte buffer paired with a runtime-determined endianness. This lets
/// [`DwarfIndex`] be `Send + Sync` without forcing callers to choose an
/// endianness statically (DWARF endianness matches the host object, which
/// is only known once the ELF header is parsed).
type Reader = EndianArcSlice<RunTimeEndian>;

/// Errors produced while parsing an ELF + DWARF blob.
///
/// We collapse the underlying `object` and `gimli` errors into two
/// variants because callers (recorder + emulator session) only need to
/// know "is the binary unreadable?" / "is the DWARF malformed?" — they
/// cannot do anything more granular than fall back to the no-DWARF code
/// path. We hand-roll `Display` + `Error` (rather than adding a
/// `thiserror` dep just for this) to keep the WASM dep graph minimal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DwarfError {
    /// The input bytes are not a recognisable object file (typically not
    /// ELF — we only enable the `elf` feature on `object`).
    Object(String),

    /// The binary is valid ELF but contained malformed or missing DWARF
    /// such that `addr2line` could not build an index.
    Dwarf(String),
}

impl std::fmt::Display for DwarfError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DwarfError::Object(msg) => write!(f, "object parse error: {msg}"),
            DwarfError::Dwarf(msg) => write!(f, "DWARF parse error: {msg}"),
        }
    }
}

impl std::error::Error for DwarfError {}

/// Public per-PC resolution result.
///
/// Returned by [`DwarfIndex::resolve_pc`]. All fields are owned (`PathBuf`
/// / `String`) so the caller does not need to hold the [`DwarfIndex`]
/// alive while inspecting the result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PcInfo {
    /// The source file the PC maps to, as recorded by the DWARF line
    /// program. Absolute or relative path exactly as DWARF stored it —
    /// we do *not* canonicalise it because the recorder needs the raw
    /// path to look up the matching source blob.
    pub file: PathBuf,

    /// 1-based source line number. DWARF guarantees a valid line for any
    /// PC that maps inside a compilation unit's line program range.
    pub line: u32,

    /// 1-based column, if the DWARF line program emitted column info.
    /// Many compilers emit only lines; treat `None` as "column unknown".
    pub column: Option<u32>,

    /// Mangled function name. Demangling is intentionally deferred to
    /// the caller (or to a later milestone) so this module stays
    /// agnostic to the source language. For Rust binaries the caller
    /// can pipe this through `rustc_demangle`; for C it is already
    /// human-readable.
    pub function: Option<String>,
}

/// Owns parsed DWARF for one ELF binary and answers PC → source queries.
///
/// One `DwarfIndex` per binary. Cheap to clone? No — the inner context
/// is large (`Arc`-wrapped section bytes + parsed unit headers); pass
/// `&DwarfIndex` instead.
pub struct DwarfIndex {
    /// The addr2line query context. Stores `Arc<Dwarf<R>>` internally
    /// so we don't need a separate handle.
    context: Addr2lineContext<Reader>,

    /// All source paths referenced by the line programs of every CU,
    /// pre-computed so `source_files()` is O(1) per call. Stored as a
    /// `BTreeSet<PathBuf>` to deduplicate (a single header is often
    /// referenced from many CUs) and yield a deterministic order.
    source_files: Arc<BTreeSet<PathBuf>>,

    /// Reverse `(file, line) -> [PC]` index built from every CU's line
    /// program. Used by [`Self::pcs_for_line`] so the emulator session
    /// can resolve a user-set breakpoint at `(source, line)` to one or
    /// more static PCs at session-construction time — letting the
    /// `Continue` step action compare runtime PCs against a small
    /// `HashSet` instead of re-walking DWARF after every emulator
    /// instruction.
    ///
    /// The key uses `(PathBuf, u32)` — we lower-case neither nor
    /// canonicalise the path, so callers must pass the same path string
    /// DWARF emitted. Two reasonable lookup strategies are exposed via
    /// [`Self::pcs_for_line`]:
    ///
    /// * Exact match against the DWARF path (cheap O(1) probe).
    /// * Basename fallback — useful when the GUI sends a different but
    ///   equivalent path (e.g. relative vs absolute, or canonicalised).
    pcs_by_line: Arc<HashMap<(PathBuf, u32), Vec<u64>>>,
}

impl DwarfIndex {
    /// Parse an ELF binary and build a queryable DWARF index.
    ///
    /// Returns an error if the input is not a recognised object file or
    /// if the DWARF sections cannot be parsed into a coherent context.
    /// An ELF with **no** DWARF sections still succeeds — every
    /// `.debug_*` section just becomes empty and `resolve_pc` will
    /// return `None` for every PC.
    pub fn from_elf_bytes(bytes: &[u8]) -> Result<Self, DwarfError> {
        // Phase 1: parse the ELF container. `object::File::parse`
        // accepts a `&[u8]` and yields a borrowed view — we immediately
        // extract owned byte ranges and drop the view so the resulting
        // `DwarfIndex` has no lifetime parameter.
        let object_file = object::File::parse(bytes).map_err(|e| DwarfError::Object(e.to_string()))?;

        // Endianness comes from the ELF header, not from a compile-time
        // const — we may eventually parse arm64-be or RISC-V cores.
        let endian = if object_file.is_little_endian() {
            RunTimeEndian::Little
        } else {
            RunTimeEndian::Big
        };

        // Phase 2: pull each .debug_* section into an Arc<[u8]>. The
        // closure handed to `gimli::Dwarf::load` receives a SectionId
        // and returns the section bytes (compressed sections would be
        // decompressed by `section.uncompressed_data`, but we disabled
        // compression to keep wasm size down — DWARF in the MCR
        // recorder will be uncompressed).
        let load_section = |id: gimli::SectionId| -> Result<Reader, gimli::Error> {
            let name = id.name();
            // `section_by_name` searches for both the regular form and
            // the gnu-compressed `.zdebug_*` form. We do not handle
            // SHF_COMPRESSED-style compression here since the `object`
            // `compression` feature is off — sections that report
            // themselves as compressed will surface as empty, which is
            // the correct fallback for "I cannot read this".
            let data: Cow<'_, [u8]> = match object_file.section_by_name(name) {
                Some(section) => section.uncompressed_data().unwrap_or(Cow::Borrowed(&[])),
                None => Cow::Borrowed(&[]),
            };
            // Convert &[u8] / Cow into an Arc<[u8]> — this is the
            // single allocation per section that lets the resulting
            // reader outlive `object_file`.
            let arc: Arc<[u8]> = Arc::from(data.into_owned().into_boxed_slice());
            Ok(EndianArcSlice::new(arc, endian))
        };

        let dwarf = gimli::Dwarf::load(load_section).map_err(|e| DwarfError::Dwarf(e.to_string()))?;

        // Phase 3: pre-walk every CU's line program to collect the set
        // of referenced source files. We do this *before* moving the
        // `Dwarf` into the addr2line `Context` (which exposes no public
        // accessor back to its inner `Dwarf`) so the line-program walk
        // is straightforward. Doing it up-front also surfaces any
        // file-table errors as part of the constructor's `Result`
        // rather than as a silent empty file list later.
        let source_files = collect_source_files(&dwarf)?;

        // Phase 4: walk every CU's line program a second time to build
        // the reverse `(file, line) -> [PC]` index. This is the
        // foundation for breakpoint resolution in M-Step-Stress: when
        // the DAP client sets a breakpoint at `(path, line)` the
        // emulator session needs to know which static PC(s) to
        // compare runtime PCs against during `Continue`.
        let pcs_by_line = collect_pcs_by_line(&dwarf)?;

        // Phase 5: hand the loaded sections to addr2line. From this
        // point on we don't need `object_file` (which still borrowed
        // `bytes`), and the returned `Context` owns its sections via
        // `Arc<Dwarf<R>>` internally.
        let context = Addr2lineContext::from_dwarf(dwarf).map_err(|e| DwarfError::Dwarf(e.to_string()))?;

        Ok(Self {
            context,
            source_files: Arc::new(source_files),
            pcs_by_line: Arc::new(pcs_by_line),
        })
    }

    /// Non-erroring variant of [`Self::from_elf_bytes`].
    ///
    /// Returns an empty index for any input that fails to parse —
    /// useful as a fallback in code paths that can tolerate "no DWARF"
    /// without distinguishing it from "garbage bytes". This is the
    /// shape `emulator_session.rs` will use in M-DWARF-3 when the
    /// binary blob in `meta.dat` is missing or corrupt: the session
    /// should still come up with the synthetic single-frame fallback
    /// rather than refuse to start.
    pub fn from_elf_bytes_lossy(bytes: &[u8]) -> Self {
        Self::from_elf_bytes(bytes).unwrap_or_else(|_| Self::empty())
    }

    /// Construct an empty index — every query returns `None`.
    ///
    /// Used by [`Self::from_elf_bytes_lossy`] and by callers that need
    /// a default-constructible placeholder before the binary is loaded.
    ///
    /// We piggy-back on `gimli::Dwarf::load` to construct a fully
    /// initialised `Dwarf<R>` where every section is empty —
    /// hand-building the struct ourselves would tie us to gimli's
    /// internal field layout (which can grow new sections between
    /// versions, e.g. `debug_macro` in DWARF 5).
    pub fn empty() -> Self {
        let endian = RunTimeEndian::Little;
        let empty_arc: Arc<[u8]> = Arc::from(Vec::new().into_boxed_slice());
        let dwarf = gimli::Dwarf::<Reader>::load(|_id: gimli::SectionId| -> Result<Reader, gimli::Error> {
            Ok(EndianArcSlice::new(empty_arc.clone(), endian))
        })
        .expect("empty section loader is infallible");
        let context = Addr2lineContext::from_dwarf(dwarf).expect("empty Dwarf -> Context is always valid");
        Self {
            context,
            source_files: Arc::new(BTreeSet::new()),
            pcs_by_line: Arc::new(HashMap::new()),
        }
    }

    /// Resolve a program counter to its `(file, line, column, function)`.
    ///
    /// Returns `None` when the PC falls outside every compilation
    /// unit's address ranges — typically meaning the PC is inside libc,
    /// a JIT page, or an instruction the compiler did not emit line
    /// info for (e.g. compiler-inserted prologue padding).
    ///
    /// **Inlining**: addr2line returns a `FrameIter` so it can describe
    /// each inlined function in the call chain. For M-DWARF-1 we
    /// collapse that into the *innermost* frame (the one actually
    /// executing at this PC); M-DWARF-4 will expose the full chain when
    /// it wires up multi-frame stack traces.
    pub fn resolve_pc(&self, pc: u64) -> Option<PcInfo> {
        // `find_frames` may return either a fast-path single Location
        // or a full inlining chain. Either way we iterate to the last
        // (innermost) frame to get the actual PC's location.
        let mut frame_iter = self.context.find_frames(pc).skip_all_loads().ok()?;

        // Walk to the innermost frame. We track the most recent
        // `Location` separately because the *outermost* frame's location
        // is the call site of the outermost inlinee — not what we want.
        // Each inner frame's `location` is the call site within its
        // caller; the very last frame's `location` is the PC itself.
        let mut last_function: Option<String> = None;
        let mut last_location: Option<(PathBuf, u32, Option<u32>)> = None;

        while let Ok(Some(frame)) = frame_iter.next() {
            if let Some(loc) = frame.location.as_ref() {
                if let (Some(file), Some(line)) = (loc.file, loc.line) {
                    last_location = Some((PathBuf::from(file), line, loc.column));
                }
            }
            if let Some(func) = frame.function.as_ref() {
                if let Ok(name) = func.raw_name() {
                    last_function = Some(name.into_owned());
                }
            }
        }

        // If we have no location at all the PC is not covered by any
        // line program — surface `None` instead of returning a
        // half-populated record.
        let (file, line, column) = last_location?;
        Some(PcInfo {
            file,
            line,
            column,
            function: last_function,
        })
    }

    /// Enumerate every source file referenced by the binary's DWARF.
    ///
    /// The iterator yields each path **once** even if multiple CUs
    /// referenced the same header. Order is `BTreeSet` order
    /// (lexicographic on the raw DWARF path string) so callers can
    /// rely on a deterministic sequence across runs.
    ///
    /// The recorder side (M-DWARF-2) uses this to know which on-disk
    /// files to slurp into the trace.
    pub fn source_files(&self) -> impl Iterator<Item = PathBuf> + '_ {
        self.source_files.iter().cloned()
    }

    /// Number of distinct source files referenced. Useful for tests.
    pub fn source_file_count(&self) -> usize {
        self.source_files.len()
    }

    /// Reverse lookup: every static PC whose line-program row maps to
    /// `(file, line)`. Returns an empty `Vec` when nothing matches.
    ///
    /// The DAP `setBreakpoints` request reaches the emulator session as
    /// `(path, line)` from the client. We need to resolve that pair to
    /// concrete static PCs so the `Continue` action can compare each
    /// post-step PC against an O(1) `HashSet<u64>` rather than
    /// re-walking the DWARF context after every emulator instruction.
    ///
    /// Lookup is tolerant of two common path mismatches between DAP and
    /// DWARF:
    ///
    /// 1. **Exact match** on the DWARF-emitted path (canonical case).
    /// 2. **Basename fallback** — when the GUI sends `/abs/hello.c` but
    ///    DWARF has `hello.c`, or vice versa. This is a pragmatic
    ///    compromise: identically-named files across CUs collapse, but
    ///    inventory/demo binaries practically never have name clashes,
    ///    and forcing the GUI to round-trip the canonical DWARF path
    ///    through `setBreakpoints` would force ugly client-side logic.
    ///
    /// All matching PCs are deduplicated and returned in ascending
    /// order — useful for tests and for deterministic breakpoint sets.
    pub fn pcs_for_line(&self, file: &Path, line: u32) -> Vec<u64> {
        let mut out: BTreeSet<u64> = BTreeSet::new();

        // Exact match: the cheapest and most common case for traces
        // where the recorder and GUI agree on the path.
        if let Some(pcs) = self.pcs_by_line.get(&(file.to_path_buf(), line)) {
            out.extend(pcs.iter().copied());
        }

        // Basename fallback: scan the map looking for any (file', line)
        // whose `file'.file_name()` matches our `file.file_name()`. The
        // table is small (one entry per (path, executed line)) so the
        // linear scan is fine in practice — a typical binary maps a few
        // hundred to a few thousand (file, line) keys.
        if let Some(needle) = file.file_name() {
            for ((path, l), pcs) in self.pcs_by_line.iter() {
                if *l != line {
                    continue;
                }
                if path.file_name() == Some(needle) {
                    out.extend(pcs.iter().copied());
                }
            }
        }

        out.into_iter().collect()
    }
}

/// Walk every compilation unit's line program and collect the set of
/// source file paths it references.
///
/// We resolve each `FileEntry` by joining its directory and file name
/// just like a DWARF consumer would when emitting a source location
/// (DWARF v5 §6.2.4: file entries are dir-index + name pairs; index 0
/// of the file table refers to the comp_dir). We do **not** join with
/// `comp_dir` itself because the recorder wants the path exactly as the
/// compiler emitted it — preserving relative paths is critical for the
/// frontend to display "src/foo.c" rather than a build-host-absolute
/// path.
fn collect_source_files(dwarf: &gimli::Dwarf<Reader>) -> Result<BTreeSet<PathBuf>, DwarfError> {
    let mut files = BTreeSet::new();
    let mut units = dwarf.units();
    while let Some(header) = units.next().map_err(|e| DwarfError::Dwarf(format!("unit iter: {e}")))? {
        let unit = dwarf
            .unit(header)
            .map_err(|e| DwarfError::Dwarf(format!("unit parse: {e}")))?;
        let Some(line_program) = unit.line_program.clone() else {
            continue;
        };
        let header = line_program.header();
        for file_entry in header.file_names() {
            // The DWARF file table is 1-based in DWARF 2/3/4 (entry 0
            // is reserved) and 0-based in DWARF 5. `file_names()`
            // already gives us only the real entries, so we don't need
            // to special-case that. The directory index, however,
            // points into the line program's `include_directories`.
            let file_name = match dwarf.attr_string(&unit, file_entry.path_name()) {
                Ok(s) => s,
                Err(_) => continue,
            };
            let file_name_str = file_name.to_string_lossy().unwrap_or_default().into_owned();

            // The directory may itself be empty (file lives in
            // comp_dir) or absolute. Either way the recorder wants the
            // raw join so that downstream consumers see the same path
            // the compiler embedded.
            let dir_index = file_entry.directory_index();
            let dir_attr = header.directory(dir_index);
            let dir = match dir_attr {
                Some(attr) => match dwarf.attr_string(&unit, attr) {
                    Ok(s) => s.to_string_lossy().unwrap_or_default().into_owned(),
                    Err(_) => String::new(),
                },
                None => String::new(),
            };

            let path = if dir.is_empty() {
                PathBuf::from(file_name_str)
            } else {
                Path::new(&dir).join(file_name_str)
            };
            files.insert(path);
        }
    }
    Ok(files)
}

/// Walk every CU's line program and build the reverse `(file, line) ->
/// [PC]` index used by [`DwarfIndex::pcs_for_line`].
///
/// We deliberately use the line program's *execution* rather than just
/// the file table, because each row reports `(address, file_index,
/// line, column, is_stmt, ...)`. Only statement rows (`is_stmt`) are
/// kept — non-statement rows are intermediate steps inside a single
/// source statement and would muddy the breakpoint resolution if we
/// included them.
///
/// PC values are recorded verbatim from the line program rows — they
/// are the **static** addresses the compiler emitted, so callers that
/// have a runtime PC must rebase before comparing against this table.
/// `EmulatorReplaySession` does that rebase using `cp0.maps` data.
fn collect_pcs_by_line(dwarf: &gimli::Dwarf<Reader>) -> Result<HashMap<(PathBuf, u32), Vec<u64>>, DwarfError> {
    let mut out: HashMap<(PathBuf, u32), Vec<u64>> = HashMap::new();
    let mut units = dwarf.units();
    while let Some(header) = units.next().map_err(|e| DwarfError::Dwarf(format!("unit iter: {e}")))? {
        let unit = dwarf
            .unit(header)
            .map_err(|e| DwarfError::Dwarf(format!("unit parse: {e}")))?;
        let Some(line_program) = unit.line_program.clone() else {
            continue;
        };

        // Resolve each FileEntry to a full path string once, indexed by
        // the file_index the line program emits. Building this up-front
        // means we don't re-walk the file table per row.
        let header_ref = line_program.header();
        let mut path_for_index: Vec<PathBuf> = Vec::new();
        // DWARF 2/3/4 numbers files starting at 1; DWARF 5 starts at 0.
        // We push a sentinel at slot 0 for both flavours; the line
        // program's row file index is used verbatim as a Vec index, so
        // out-of-bounds rows are skipped (defensive against malformed
        // DWARF).
        path_for_index.push(PathBuf::new());
        for file_entry in header_ref.file_names() {
            let file_name = match dwarf.attr_string(&unit, file_entry.path_name()) {
                Ok(s) => s,
                Err(_) => {
                    path_for_index.push(PathBuf::new());
                    continue;
                }
            };
            let file_name_str = file_name.to_string_lossy().unwrap_or_default().into_owned();
            let dir_index = file_entry.directory_index();
            let dir_attr = header_ref.directory(dir_index);
            let dir = match dir_attr {
                Some(attr) => match dwarf.attr_string(&unit, attr) {
                    Ok(s) => s.to_string_lossy().unwrap_or_default().into_owned(),
                    Err(_) => String::new(),
                },
                None => String::new(),
            };
            let path = if dir.is_empty() {
                PathBuf::from(file_name_str)
            } else {
                Path::new(&dir).join(file_name_str)
            };
            path_for_index.push(path);
        }

        // Execute the line program. `rows()` consumes the program and
        // returns an iterator that yields one row per state-machine
        // step. We only care about *statement* rows (`is_stmt`) — those
        // are the rows debuggers should single-step to.
        let mut rows = line_program.rows();
        while let Some((_header, row)) = rows
            .next_row()
            .map_err(|e| DwarfError::Dwarf(format!("line row: {e}")))?
        {
            if row.end_sequence() {
                continue;
            }
            if !row.is_stmt() {
                continue;
            }
            let Some(line) = row.line() else {
                continue;
            };
            let line_u32 = line.get() as u32;
            let address = row.address();
            // DWARF 2/3/4: file index 0 means "no file"; DWARF 5: 0 is
            // the compilation file. Either way, looking it up in our
            // `path_for_index` is correct because we pushed an empty
            // sentinel at slot 0 for DWARF 2/3/4 (which skips it via
            // the empty-path check below) and DWARF 5's first entry is
            // also at index 0 in `file_names()`. To stay portable
            // across both, we tolerate either layout: lookup the
            // index, and skip empty paths.
            let file_index = row.file_index() as usize;
            let Some(path) = path_for_index.get(file_index) else {
                continue;
            };
            if path.as_os_str().is_empty() {
                continue;
            }
            out.entry((path.clone(), line_u32)).or_default().push(address);
        }
    }

    // Deduplicate per (file, line) — the same address can show up via
    // different file-index aliases for headers included from multiple
    // CUs, and consumers expect each PC at most once.
    for v in out.values_mut() {
        v.sort_unstable();
        v.dedup();
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pre-built ELF fixture; see `tests/fixtures/dwarf/hello.c` and
    /// `tests/fixtures/dwarf/rebuild.sh` for the source and build
    /// recipe. The fixture is intentionally tiny (~11 KB) and contains
    /// three functions (`add`, `compute`, `main`) compiled with `-O0
    /// -g` so the line numbers stay stable across rebuilds.
    const FIXTURE_ELF: &[u8] = include_bytes!("../tests/fixtures/dwarf/hello.elf");

    /// PC of the first instruction inside `add` — the function-entry
    /// `push %rbp` at hello.c line 23 (the `int add(...)` line).
    /// Confirmed via `objdump --dwarf=decodedline hello.elf`.
    const PC_ADD_ENTRY: u64 = 0x401000;

    /// PC inside `add`'s body — the `mov -0x14(%rbp),%edx` at hello.c
    /// line 24 (the `int sum = a + b;` line).
    const PC_ADD_BODY: u64 = 0x40100a;

    /// PC of the first instruction inside `main` — hello.c line 33.
    const PC_MAIN_ENTRY: u64 = 0x401048;

    /// PC well outside any code section — used to assert "no DWARF for
    /// this PC" returns `None` rather than crashing.
    const PC_NONSENSE: u64 = 0xdeadbeef_cafebabe;

    #[test]
    fn parses_valid_elf() {
        let index = DwarfIndex::from_elf_bytes(FIXTURE_ELF).expect("hello.elf fixture must parse");
        // Sanity: the fixture has at least one CU with at least one
        // source file (hello.c — plus possibly hello_start.S).
        assert!(index.source_file_count() >= 1, "expected ≥1 source file");
    }

    #[test]
    fn resolve_pc_inside_add_returns_expected_file_and_line() {
        let index = DwarfIndex::from_elf_bytes(FIXTURE_ELF).expect("parse");
        let info = index.resolve_pc(PC_ADD_BODY).expect("PC_ADD_BODY must resolve");

        // The DWARF file path is just "hello.c" for this fixture (gcc
        // emits it relative to comp_dir for files compiled from the
        // current directory). We assert containment, not equality,
        // because some toolchains prepend a "./" or similar.
        let file_str = info.file.to_string_lossy();
        assert!(file_str.ends_with("hello.c"), "unexpected file path: {file_str}");

        // Line 24 = the `int sum = a + b;` body line, per objdump
        // --dwarf=decodedline.
        assert_eq!(info.line, 24, "got info = {info:?}");

        // Function name should be the unmangled `add` (no demangling
        // pass is run by DwarfIndex; C names are already plain).
        assert_eq!(info.function.as_deref(), Some("add"), "got info = {info:?}");
    }

    #[test]
    fn resolve_pc_inside_main_returns_main() {
        let index = DwarfIndex::from_elf_bytes(FIXTURE_ELF).expect("parse");
        let info = index.resolve_pc(PC_MAIN_ENTRY).expect("PC_MAIN_ENTRY must resolve");

        assert!(info.file.to_string_lossy().ends_with("hello.c"));
        // Line 33 = `int main(void) {` per the .debug_line dump.
        assert_eq!(info.line, 33, "got info = {info:?}");
        assert_eq!(info.function.as_deref(), Some("main"));
    }

    #[test]
    fn resolve_pc_entry_of_add_returns_add() {
        // The function-entry PC may map to the *declaration* line (23)
        // rather than the body line — both are valid for a -O0 build,
        // depending on the line program's first row. We accept either
        // 23 or 24 to keep this test resilient to gcc version drift.
        let index = DwarfIndex::from_elf_bytes(FIXTURE_ELF).expect("parse");
        let info = index.resolve_pc(PC_ADD_ENTRY).expect("PC_ADD_ENTRY must resolve");
        assert_eq!(info.function.as_deref(), Some("add"));
        assert!(
            matches!(info.line, 23 | 24),
            "expected line 23 or 24 at function entry, got {info:?}"
        );
    }

    #[test]
    fn resolve_pc_outside_any_cu_returns_none() {
        let index = DwarfIndex::from_elf_bytes(FIXTURE_ELF).expect("parse");
        assert!(index.resolve_pc(PC_NONSENSE).is_none());
    }

    #[test]
    fn source_files_contains_hello_c() {
        let index = DwarfIndex::from_elf_bytes(FIXTURE_ELF).expect("parse");
        let files: Vec<PathBuf> = index.source_files().collect();
        assert!(
            files.iter().any(|p| p.to_string_lossy().ends_with("hello.c")),
            "expected hello.c in {files:?}"
        );
    }

    #[test]
    fn garbage_input_returns_err() {
        let garbage = b"this is not an ELF file at all, just some text bytes";
        let result = DwarfIndex::from_elf_bytes(garbage);
        assert!(result.is_err(), "garbage input must not parse");
    }

    #[test]
    fn empty_input_returns_err() {
        let result = DwarfIndex::from_elf_bytes(&[]);
        assert!(result.is_err());
    }

    #[test]
    fn from_elf_bytes_lossy_returns_empty_index_for_garbage() {
        let garbage = b"definitely not ELF";
        let index = DwarfIndex::from_elf_bytes_lossy(garbage);
        assert_eq!(index.source_file_count(), 0);
        assert!(index.resolve_pc(PC_ADD_BODY).is_none());
    }

    #[test]
    fn from_elf_bytes_lossy_succeeds_on_valid_elf() {
        // Round-trip: lossy variant should match the strict variant
        // when the input is valid.
        let index = DwarfIndex::from_elf_bytes_lossy(FIXTURE_ELF);
        assert!(index.source_file_count() >= 1);
        let info = index.resolve_pc(PC_ADD_BODY).expect("must resolve");
        assert_eq!(info.line, 24);
    }

    #[test]
    fn empty_index_resolves_nothing() {
        let index = DwarfIndex::empty();
        assert_eq!(index.source_file_count(), 0);
        assert!(index.resolve_pc(0x401000).is_none());
        assert!(index.source_files().next().is_none());
        assert!(index.pcs_for_line(Path::new("hello.c"), 24).is_empty());
    }

    /// M-Step-Stress: the reverse `(file, line) -> [PC]` lookup must
    /// return at least one PC for a known statement line in the hello.c
    /// fixture. We use line 24 (`int sum = a + b;`) — the same line the
    /// forward `resolve_pc(PC_ADD_BODY)` test already pins.
    #[test]
    fn pcs_for_line_finds_known_statement_pcs() {
        let index = DwarfIndex::from_elf_bytes(FIXTURE_ELF).expect("parse");
        let pcs = index.pcs_for_line(Path::new("hello.c"), 24);
        assert!(!pcs.is_empty(), "expected ≥1 PC for hello.c:24, got an empty vec");
        // Round-trip: every PC the reverse lookup yields must resolve
        // back to the same `(file, line)` via the forward index.
        for pc in &pcs {
            let info = index.resolve_pc(*pc).expect("reverse-lookup PC must resolve");
            assert_eq!(info.line, 24, "forward+reverse must agree on line at pc {pc:#x}");
            assert!(
                info.file.to_string_lossy().ends_with("hello.c"),
                "forward+reverse must agree on file at pc {pc:#x}, got {:?}",
                info.file,
            );
        }
    }

    /// Basename fallback: a caller passing `/some/absolute/path/hello.c`
    /// must still match the DWARF-emitted `hello.c` entry. The GUI may
    /// canonicalise breakpoint paths, so this fallback prevents
    /// silently-empty breakpoint sets.
    #[test]
    fn pcs_for_line_matches_by_basename() {
        let index = DwarfIndex::from_elf_bytes(FIXTURE_ELF).expect("parse");
        let pcs = index.pcs_for_line(Path::new("/canonicalised/abs/path/hello.c"), 24);
        assert!(
            !pcs.is_empty(),
            "basename fallback must match hello.c regardless of directory prefix"
        );
    }

    /// Out-of-range line numbers must return an empty Vec, not panic.
    #[test]
    fn pcs_for_line_returns_empty_for_unknown_line() {
        let index = DwarfIndex::from_elf_bytes(FIXTURE_ELF).expect("parse");
        let pcs = index.pcs_for_line(Path::new("hello.c"), 9999);
        assert!(pcs.is_empty(), "unknown line must return an empty Vec");
        let pcs = index.pcs_for_line(Path::new("not_a_file.c"), 24);
        assert!(pcs.is_empty(), "unknown file must return an empty Vec");
    }
}
