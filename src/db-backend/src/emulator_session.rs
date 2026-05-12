//! [`EmulatorReplaySession`] — `ReplaySession` impl backed by the Nim MCR
//! emulator (F5c-1 native, F5c-2 wasm32, F5c-3 trait-method bodies).
//!
//! ## Scope
//!
//! F5c-1 / F5c-2 stitched together the linking pipeline: the Nim emulator
//! is now part of the db-backend native and wasm32 builds. F5c-3
//! (this file) turns the placeholder trait impl into something the F5
//! browser-replay gateway can actually drive end-to-end — at minimum it
//! must surface ≥1 stack frame with a non-empty name and ≥1 variable
//! with a non-empty value so DAP `threads → stackTrace → scopes →
//! variables → setBreakpoints` succeeds.
//!
//! The implementation is **deliberately minimal** — it does not yet read
//! DWARF for true callstack unwinding nor evaluate complex expressions:
//! - The CTFS `meta.dat` block supplies program name, working directory,
//!   and source paths. We synthesise a single root frame from
//!   `meta.program` + `paths[0]` so the DAP client sees a meaningful
//!   stackTrace.
//! - Locals are projected from the register file. We surface every named
//!   x86_64 register as a `Variable` so the client always has at least
//!   one variable with a non-empty `rawValue`.
//! - Breakpoints are tracked in-process — `add_breakpoint` returns a
//!   `Breakpoint` whose handler shim sets `verified: true` in the DAP
//!   response (see `dap_handler::set_breakpoints` line 1294).
//!
//! Methods that F5's happy path may incidentally touch — `load_events`,
//! `load_step_events`, `load_return_value`, `run_to_entry`, `step` — are
//! implemented as graceful "empty / Default" returns so the DAP handler
//! never crashes on them when an emulator-backed session is in play.
//! Methods that F5 does NOT exercise at all (history pagination, the
//! various `jump_to`/`event_jump`/`callstack_jump`/`location_jump`/
//! `tracepoint_jump`/`toggle_breakpoint`/`evaluate_call_expression`)
//! deliberately stay as `todo!()` macros so they fail loudly if a future
//! milestone starts depending on them before the underlying machinery
//! (DWARF unwinding, snapshot-driven rewind, expression evaluator) is
//! wired up.
//!
//! ## Initialisation invariant
//!
//! Nim's exported procs require the runtime to be initialised exactly
//! once per process via `NimMain`. We guard that with [`std::sync::Once`]
//! so that constructing multiple sessions (e.g. during testing) is safe.
//! `mcrInit` itself is idempotent and is called on every `new()` so each
//! session starts from a clean emulator state.
//!
//! On wasm32 the runtime is single-threaded so the `Once` guard is
//! effectively trivial; we keep it for source-level symmetry with native.

use codetracer_trace_types::{StepId, TypeKind, TypeRecord, TypeSpecificInfo};
use std::collections::HashMap;
use std::error::Error;
use std::sync::Once;

use crate::ctfs_trace_reader::ctfs_container::CtfsReader;
use crate::ctfs_trace_reader::meta_dat::{parse_meta_dat, MetaDat};
use crate::db::DbRecordEvent;
use crate::dwarf_index::{DwarfIndex, PcInfo};
use crate::emulator_ffi;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::replay::ReplaySession;
use crate::task::{
    Action, Breakpoint, Call, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg,
    Location, ProgramEvent, RRTicks, VariableWithRecord, NO_ADDRESS, NO_EVENT, NO_POSITION,
};
use crate::value::ValueRecordWithType;

static NIM_RUNTIME_INIT: Once = Once::new();

/// Name of the CTFS internal file that carries the recorded binary plus its
/// DWARF sections (M-DWARF-3).
///
/// Conventions: lowercase, ≤12 chars, `.dat` extension to mirror the binary
/// `meta.dat` neighbour. We bundle the **full ELF** rather than only the
/// `.debug_*` sections so the replay backend can reuse the existing
/// `DwarfIndex::from_elf_bytes` parser without inventing a new
/// concat-of-sections format. The trade-off is ~1 MB of `.text`/`.data`
/// extra per trace; for the F5 inventory binary the full ELF is ~3 MB and
/// the DWARF subset is ~2 MB, so the overhead is acceptable. M-DWARF-4
/// will need the full binary anyway for `.eh_frame`-driven unwinding.
const BUNDLED_DEBUG_FILE: &str = "debug.dat";

/// Initialise the Nim runtime exactly once per process.
fn ensure_nim_runtime() {
    NIM_RUNTIME_INIT.call_once(|| {
        // SAFETY: NimMain is the standard Nim runtime entry point. It is
        // safe to call from a single thread once per process; the Once
        // guard guarantees that exclusivity.
        unsafe { emulator_ffi::NimMain() };
    });
}

/// Names of the 18 registers exposed via `mcrGetRegister(idx)`. The
/// order matches the `index` table documented in `emulator_ffi.rs`
/// (`mcrGetRegister`): 0..=15 are the GPRs, 16 is `rip`, 17 is `rflags`.
const REGISTER_NAMES: [&str; 18] = [
    "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    "rip", "rflags",
];

/// Returned by [`EmulatorReplaySession::new_from_ctfs_bytes`] when the
/// supplied byte slice can't be parsed as an MCR-bearing CTFS container.
///
/// We surface a single string-form error rather than a typed enum
/// because every call site treats CTFS failures the same way: log and
/// fall through to a non-MCR reader.
fn ctfs_error(msg: impl Into<String>) -> Box<dyn Error> {
    msg.into().into()
}

/// `ReplaySession` backed by the Nim MCR emulator.
///
/// Construct with [`new`](Self::new) for an empty emulator (used by the
/// F5c-1 bring-up smoke test) or with
/// [`new_from_ctfs_bytes`](Self::new_from_ctfs_bytes) to populate the
/// session from a `.ct` container with `FLAG_HAS_MCR_FIELDS` set.
pub struct EmulatorReplaySession {
    /// Parsed `meta.dat` for the active trace.
    ///
    /// Even an empty session keeps a default `MetaDat` so callbacks that
    /// reach for the program name or path list never have to special-case
    /// `Option::None`. The default has `version = 0` which would never
    /// match a real serialised header — useful as a sentinel in tests.
    meta: MetaDat,
    /// In-process breakpoint table: maps `(path, line)` to one or more
    /// allocated [`Breakpoint`] records. We track the structure rather
    /// than just IDs so that `delete_breakpoint` can locate the entry
    /// efficiently and `delete_breakpoints` can clear the lot.
    breakpoints: HashMap<(String, i64), Vec<Breakpoint>>,
    /// Monotonic next breakpoint id. Re-assigned on `delete_breakpoints`
    /// so a fresh session starts from 1, matching the
    /// `MaterializedReplaySession` convention.
    next_breakpoint_id: i64,
    /// Whether breakpoints currently fire. `disable_breakpoints` flips
    /// this to `false` without removing entries.
    breakpoints_enabled: bool,
    /// Cached step id returned by `current_step_id`. The emulator's own
    /// step counter is the source of truth (`mcrGetStepCounter`); we
    /// keep this field so unit tests can deterministically inspect the
    /// last reported value without having to dispatch to FFI.
    current_step_id: StepId,
    /// Parsed DWARF index for the recorded program, when the `.ct`
    /// container bundled a `debug.dat` blob (M-DWARF-3). `None` when:
    ///
    /// * The recorder did not include the binary (e.g. stripped target).
    /// * The bundled bytes failed to parse as an ELF (corrupt bundle).
    ///
    /// When `None`, the session falls back to the M-DWARF-2 behaviour
    /// where `build_location` synthesises `(meta.paths[0], 1)`.
    dwarf: Option<DwarfIndex>,
}

/// Manual `Debug` impl: [`DwarfIndex`] wraps an `addr2line::Context` that
/// does not implement `Debug`, and the parsed sections aren't useful in
/// log output anyway. Surfacing `Some/None` plus a coarse source-file
/// count is enough for diagnostics.
impl std::fmt::Debug for EmulatorReplaySession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EmulatorReplaySession")
            .field("meta", &self.meta)
            .field("breakpoints", &self.breakpoints)
            .field("next_breakpoint_id", &self.next_breakpoint_id)
            .field("breakpoints_enabled", &self.breakpoints_enabled)
            .field("current_step_id", &self.current_step_id)
            .field(
                "dwarf",
                &self
                    .dwarf
                    .as_ref()
                    .map(|d| format!("DwarfIndex({} source files)", d.source_file_count())),
            )
            .finish()
    }
}

/// Default empty type record for synthesised values.
///
/// Used wherever we surface raw scalars (e.g. registers) that don't have
/// a richer DWARF type available — the frontend only needs `kind` /
/// `lang_type` to be present for the value to render.
fn type_record(kind: TypeKind, lang_type: &str) -> TypeRecord {
    TypeRecord {
        kind,
        lang_type: lang_type.to_string(),
        specific_info: TypeSpecificInfo::None,
    }
}

impl EmulatorReplaySession {
    /// Create an empty session backed by a freshly-initialised Nim
    /// emulator. No memory or registers are loaded — primarily useful
    /// for unit tests that exercise the FFI bring-up surface.
    ///
    /// The first call also initialises the Nim runtime via `NimMain`.
    pub fn new() -> Self {
        ensure_nim_runtime();
        // SAFETY: mcrInit is safe to call after NimMain has run and is
        // idempotent — it merely resets the emulator's globals.
        unsafe { emulator_ffi::mcrInit() };
        Self {
            meta: MetaDat {
                version: 0,
                flags: 0,
                program: String::new(),
                args: Vec::new(),
                workdir: String::new(),
                recorder_id: String::new(),
                paths: Vec::new(),
                mcr: None,
            },
            breakpoints: HashMap::new(),
            next_breakpoint_id: 1,
            breakpoints_enabled: true,
            current_step_id: StepId(0),
            dwarf: None,
        }
    }

    /// Create a session from raw CTFS bytes (typically the in-memory
    /// VFS slot for the WASM build, or `std::fs::read("trace.ct")` on
    /// native).
    ///
    /// Currently the CTFS payload only seeds the source-map side of
    /// the session — register state and memory regions stay empty
    /// because no recorder yet emits a checkpoint stream the
    /// db-backend can consume directly. The path is wired up now so
    /// that future checkpoint-decode support drops into one place.
    ///
    /// Returns `Err` if the bytes are not a valid CTFS container, if
    /// `meta.dat` is missing or unparseable, or if the trace does not
    /// declare `FLAG_HAS_MCR_FIELDS` (callers should route those to
    /// `MaterializedReplaySession` instead).
    pub fn new_from_ctfs_bytes(bytes: Vec<u8>) -> Result<Self, Box<dyn Error>> {
        let mut ctfs = CtfsReader::from_bytes(bytes).map_err(|e| ctfs_error(format!("CTFS parse failed: {e}")))?;

        let meta_bytes = ctfs
            .read_file("meta.dat")
            .map_err(|e| ctfs_error(format!("meta.dat missing from CTFS container: {e}")))?;
        let meta = parse_meta_dat(&meta_bytes).map_err(|e| ctfs_error(format!("meta.dat parse failed: {e}")))?;

        if meta.mcr.is_none() {
            return Err(ctfs_error(
                "EmulatorReplaySession requires meta.dat with FLAG_HAS_MCR_FIELDS set",
            ));
        }

        // M-DWARF-3: look for the recorder-bundled binary (`debug.dat`).
        // Missing is fine — older traces predate the bundling step, and
        // stripped binaries skip the bundle on the recorder side. Parse
        // failures are tolerated identically so a corrupt bundle never
        // prevents the session from coming up at all; the session just
        // falls back to the M-DWARF-2 placeholder location.
        let dwarf = match ctfs.read_file(BUNDLED_DEBUG_FILE) {
            Ok(elf_bytes) if !elf_bytes.is_empty() => match DwarfIndex::from_elf_bytes(&elf_bytes) {
                Ok(index) => Some(index),
                Err(e) => {
                    eprintln!(
                        "warning: EmulatorReplaySession could not parse bundled `{BUNDLED_DEBUG_FILE}` \
                         ({e}); falling back to placeholder line numbers"
                    );
                    None
                }
            },
            // Either the file isn't present (older trace) or it's empty.
            // Both are silent fallbacks — they are the documented
            // graceful-degradation contract for M-DWARF-3.
            _ => None,
        };

        ensure_nim_runtime();
        // SAFETY: see `new()`.
        unsafe { emulator_ffi::mcrInit() };

        Ok(Self {
            meta,
            breakpoints: HashMap::new(),
            next_breakpoint_id: 1,
            breakpoints_enabled: true,
            current_step_id: StepId(0),
            dwarf,
        })
    }

    /// Allocate and store a new breakpoint record under `(path, line)`.
    fn allocate_breakpoint(&mut self, path: &str, line: i64) -> Breakpoint {
        let breakpoint = Breakpoint {
            id: self.next_breakpoint_id,
            enabled: self.breakpoints_enabled,
        };
        self.next_breakpoint_id += 1;
        self.breakpoints
            .entry((path.to_string(), line))
            .or_default()
            .push(breakpoint.clone());
        breakpoint
    }

    /// Resolve the active source path for synthesised locations.
    ///
    /// Prefers the first entry in `meta.paths` (the writer convention
    /// puts the program's primary source first); falls back to
    /// `meta.program` so we never emit an empty `Location.path`.
    fn primary_path(&self) -> String {
        if let Some(first) = self.meta.paths.first() {
            if !first.is_empty() {
                return first.clone();
            }
        }
        if !self.meta.program.is_empty() {
            return self.meta.program.clone();
        }
        "<unknown>".to_string()
    }

    /// Synthesise a function name for the root frame.
    ///
    /// We don't yet have DWARF, so the program basename is the best
    /// signal available. The F5 acceptance check only requires the name
    /// to be non-empty, so this is sufficient.
    fn root_function_name(&self) -> String {
        if !self.meta.program.is_empty() {
            // Strip any directory prefix; tolerate both Unix and Windows
            // separators so traces recorded on either host render the
            // same way.
            let mut name: &str = &self.meta.program;
            if let Some(idx) = name.rfind(['/', '\\']) {
                name = &name[idx + 1..];
            }
            if !name.is_empty() {
                return name.to_string();
            }
        }
        "<entry>".to_string()
    }

    /// Resolve the current emulator PC against the bundled DWARF, if any.
    ///
    /// Returns `None` when:
    ///
    /// * No DWARF was bundled (older trace or stripped binary).
    /// * The PC falls outside every CU range (libc, JIT page, padding).
    ///
    /// The returned `PcInfo.file` is the raw DWARF path; the caller is
    /// responsible for deciding whether to override `meta.paths[0]` with
    /// it. We deliberately don't canonicalise here — the recorder side
    /// embeds source paths exactly as the compiler emitted them, so the
    /// DWARF path matches the meta path for the same compilation unit.
    fn dwarf_pc_info(&self) -> Option<PcInfo> {
        let dwarf = self.dwarf.as_ref()?;
        // SAFETY: same rationale as `build_location` — the emulator FFI
        // getter reads from Nim-managed globals seeded by `mcrInit`.
        let pc = unsafe { emulator_ffi::mcrGetPC() };
        dwarf.resolve_pc(pc)
    }

    /// Build a [`Location`] from the current emulator state.
    ///
    /// When a bundled DWARF index is available and resolves the current
    /// PC, the returned location carries the real `(file, line)` from
    /// the binary's `.debug_line` table. Otherwise it falls back to the
    /// M-DWARF-2 placeholder of `(meta.paths[0], 1)` — F5 still passes
    /// against that fallback, just with a less informative breakpoint
    /// line.
    fn build_location(&self) -> Location {
        // SAFETY: getters never read uninitialised memory; they read
        // from the Nim-managed emulator globals which `mcrInit` reset.
        let pc = unsafe { emulator_ffi::mcrGetPC() };

        // Default to the M-DWARF-2 fallback so missing/incomplete DWARF
        // always produces a well-formed location.
        let mut path = self.primary_path();
        let mut line: i64 = 1;
        let function_name = self.root_function_name();

        if let Some(info) = self.dwarf_pc_info() {
            // Adopt the DWARF-reported source file when it disagrees
            // with `meta.paths[0]` — the DWARF line table is the
            // authoritative answer for "which source file does this PC
            // belong to". `meta.paths[0]` is a useful default but is
            // chosen by recorder-side heuristics, not by the PC.
            let dwarf_path = info.file.to_string_lossy().into_owned();
            if !dwarf_path.is_empty() {
                path = dwarf_path;
            }
            line = info.line as i64;
        }

        Location {
            path: path.clone(),
            line,
            function_name: function_name.clone(),
            high_level_path: path.clone(),
            high_level_line: line,
            high_level_function_name: function_name,
            low_level_path: path,
            low_level_line: line,
            rr_ticks: RRTicks(self.current_step_id.0),
            function_first: NO_POSITION,
            function_last: NO_POSITION,
            event: NO_EVENT,
            expression: String::new(),
            offset: pc as i64,
            error: false,
            callstack_depth: 0,
            originating_instruction_address: pc as i64,
            key: String::new(),
            global_call_key: String::new(),
            expansion_id: -1,
            expansion_first_line: -1,
            expansion_last_line: -1,
            missing_path: self.meta.paths.is_empty() && self.meta.program.is_empty(),
            ..Location::default()
        }
    }
}

impl Default for EmulatorReplaySession {
    fn default() -> Self {
        Self::new()
    }
}

impl ReplaySession for EmulatorReplaySession {
    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        Ok(self.build_location())
    }

    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        // The emulator's entry state is whatever `mcrSetRegisters` left
        // behind; we have no separate "rewind" because no recorder yet
        // emits checkpoint snapshots for the db-backend to restore.
        // Resetting the step counter view keeps `current_step_id` honest
        // for clients that call `run_to_entry` mid-session.
        self.current_step_id = StepId(0);
        Ok(())
    }

    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        // F5 paginates `Events` for the GUI events sidebar. Returning an
        // empty stream is correct for the emulator path until syscall
        // projection (`mcrAddSyscallEvent` -> `ProgramEvent`) is wired
        // up in a follow-up.
        Ok(Events {
            events: Vec::new(),
            first_events: Vec::new(),
            contents: String::new(),
        })
    }

    fn step(&mut self, _action: Action, _forward: bool) -> Result<bool, Box<dyn Error>> {
        // Drive one instruction. The emulator only steps forward; reverse
        // execution requires snapshots that this build does not yet have.
        // We swallow non-zero return codes because the F5 happy-path
        // never actually loads code to step over — the call exists so
        // that the DAP `next`/`stepIn` handlers don't blow up on an
        // unhandled `todo!()` when the user presses a step button on an
        // emulator-backed trace.
        //
        // SAFETY: `mcrStep` only reads/writes the Nim-managed emulator
        // globals seeded by `mcrInit` (and optionally `mcrSetRegisters`).
        let _ = unsafe { emulator_ffi::mcrStep() };
        // Mirror the emulator counter so subsequent `current_step_id`
        // calls return the updated value.
        // SAFETY: same as above.
        let counter = unsafe { emulator_ffi::mcrGetStepCounter() };
        self.current_step_id = StepId(counter as i64);
        Ok(true)
    }

    fn load_locals(&mut self, _arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        // Project every named x86_64 register as a local. This is enough
        // for F5's variables-view sanity assertion (≥1 variable with a
        // non-empty value) and is also a useful default debugging view
        // for emulator-backed traces — DWARF locals can stack on top
        // later.
        let mut out = Vec::with_capacity(REGISTER_NAMES.len());
        let int_type = type_record(TypeKind::Int, "u64");
        for (idx, name) in REGISTER_NAMES.iter().enumerate() {
            // SAFETY: `mcrGetRegister` is total and bounded by the index
            // table documented on the FFI. Indices 0..=17 always return
            // a defined `u64`.
            let value = unsafe { emulator_ffi::mcrGetRegister(idx as std::os::raw::c_int) };
            out.push(VariableWithRecord {
                expression: (*name).to_string(),
                value: ValueRecordWithType::Int {
                    i: value as i64,
                    typ: int_type.clone(),
                },
                address: NO_ADDRESS,
            });
        }
        Ok(out)
    }

    fn load_value(
        &mut self,
        expression: &str,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        // Look up the expression as a register name. Anything else
        // currently surfaces as a typed error so the frontend renders a
        // legible "not found" rather than crashing on a `todo!()`.
        let int_type = type_record(TypeKind::Int, "u64");
        if let Some(idx) = REGISTER_NAMES.iter().position(|name| *name == expression) {
            // SAFETY: indices 0..=17 are always valid for `mcrGetRegister`.
            let value = unsafe { emulator_ffi::mcrGetRegister(idx as std::os::raw::c_int) };
            return Ok(ValueRecordWithType::Int {
                i: value as i64,
                typ: int_type,
            });
        }
        Err(format!("EmulatorReplaySession: unknown variable `{expression}`").into())
    }

    fn load_return_value(
        &mut self,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        // Return-value introspection requires DWARF + ABI knowledge we
        // don't have yet. Returning a typed `None` keeps the DAP handler
        // happy if it ever reaches this branch on the emulator path.
        Ok(ValueRecordWithType::None {
            typ: type_record(TypeKind::None, "none"),
        })
    }

    fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
        // The emulator has no per-step event log yet. F5 only consults
        // this for the events sidebar, so returning an empty vector is
        // benign.
        Vec::new()
    }

    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        // Synthesise a single root frame. `load_callstack` is what feeds
        // DAP `stackTrace`, so producing one frame with a non-empty
        // function name (and a sensible source path) is the F5
        // acceptance bar.
        let location = self.build_location();
        let call = Call {
            key: "0".to_string(),
            children: Vec::new(),
            depth: 0,
            location,
            parent: None,
            raw_name: self.root_function_name(),
            args: Vec::new(),
            return_value: crate::value::Value::default(),
            with_args_and_return: false,
        };
        Ok(vec![CallLine::call(
            call, /* hidden_children */ false, /* count */ 0, 0,
        )])
    }

    fn load_history(&mut self, _arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        todo!("F5c-3: build per-line history from emulator trace")
    }

    fn add_breakpoint(&mut self, path: &str, line: i64) -> Result<Breakpoint, Box<dyn Error>> {
        // The dap_handler shim (`dap_handler::set_breakpoints`, around
        // line 1294) reports `verified: true` whenever `add_breakpoint`
        // returns `Ok`. So all we need to do here is mint a new id and
        // remember the entry so `delete_breakpoint` can find it.
        Ok(self.allocate_breakpoint(path, line))
    }

    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        for entries in self.breakpoints.values_mut() {
            if let Some(pos) = entries.iter().position(|b| b.id == breakpoint.id) {
                entries.remove(pos);
                return Ok(true);
            }
        }
        // Mirror MaterializedReplaySession: unknown id is an error so the
        // GUI can surface a diagnostic instead of silently no-ooping.
        Err(format!("breakpoint id {} not found", breakpoint.id).into())
    }

    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        self.breakpoints.clear();
        Ok(true)
    }

    fn toggle_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
        todo!("F5c-3: flip emulator breakpoint state")
    }

    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.breakpoints_enabled = true;
        for entries in self.breakpoints.values_mut() {
            for b in entries.iter_mut() {
                b.enabled = true;
            }
        }
        Ok(())
    }

    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.breakpoints_enabled = false;
        for entries in self.breakpoints.values_mut() {
            for b in entries.iter_mut() {
                b.enabled = false;
            }
        }
        Ok(())
    }

    fn jump_to(&mut self, _step_id: StepId) -> Result<bool, Box<dyn Error>> {
        todo!("F5c-3: rewind/fast-forward emulator to step_id")
    }

    fn jump_to_call(&mut self, _location: &Location) -> Result<Location, Box<dyn Error>> {
        todo!("F5c-3: jump to enclosing call entry")
    }

    fn event_jump(&mut self, _event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
        todo!("F5c-3: replay to the step that produced `event`")
    }

    fn callstack_jump(&mut self, _depth: usize) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: pop to caller at `depth`")
    }

    fn location_jump(&mut self, _location: &Location) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: jump to a specific source location")
    }

    fn tracepoint_jump(&mut self, _event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: jump to a tracepoint event")
    }

    fn evaluate_call_expression(
        &mut self,
        _call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        todo!("F5c-3: evaluate a `func(args)` expression via the emulator")
    }

    fn current_step_id(&mut self) -> StepId {
        self.current_step_id
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::ctfs_container::write_minimal_ctfs;
    use crate::ctfs_trace_reader::meta_dat::{serialize_meta_dat, McrFields, FLAG_HAS_MCR_FIELDS, META_DAT_VERSION};

    /// Build a synthetic CTFS payload with the `FlagHasMcrFields` bit set
    /// and a plausible meta block. We don't need real checkpoint streams
    /// to exercise the F5c-3 trait surface — the meta block alone is
    /// enough for `load_location` / `load_callstack` to synthesise a
    /// non-empty frame.
    fn synthetic_mcr_ctfs_bytes() -> Vec<u8> {
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
            program: "/usr/local/bin/example".to_owned(),
            args: vec!["arg0".to_owned()],
            workdir: "/tmp/run".to_owned(),
            recorder_id: "mcr".to_owned(),
            paths: vec!["src/main.c".to_owned(), "src/util.c".to_owned()],
            mcr: Some(McrFields {
                tick_source: 1,
                total_threads: 1,
                atomic_mode: 0,
                total_events: 0,
                total_checkpoints: 0,
                start_time_unix_us: 0,
                platform: "linux-x86_64".to_owned(),
                tick_granularity: "instruction".to_owned(),
                tick_source_str: "rdtsc".to_owned(),
                atomic_mode_str: "seq_cst".to_owned(),
                start_time_str: "1970-01-01T00:00:00Z".to_owned(),
                hook_profile: String::new(),
                hook_strategies: Vec::new(),
            }),
        };
        let dat = serialize_meta_dat(&meta);

        // Wrap meta.dat into a minimal CTFS container. The `t00000000000`
        // file is a placeholder thread stream — real MCR traces ship
        // per-thread streams, and including it here makes the fixture
        // resemble the production layout even though we don't yet read it.
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("synthetic.ct");
        write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("t00000000000", b"")]).unwrap();
        std::fs::read(&ct_path).unwrap()
    }

    /// F5c-1 bring-up: constructing the session must succeed (NimMain
    /// plus mcrInit linked and callable). Probing the emulator state
    /// via the FFI should report zeros, since we have not loaded a
    /// program.
    #[test]
    fn new_session_initialises_nim_runtime_and_resets_state() {
        let mut session = EmulatorReplaySession::new();

        // SAFETY: After `new()` the Nim runtime is initialised and
        // mcrInit has been called; these getters are safe to invoke
        // and return 0 because no register file has been loaded yet.
        unsafe {
            assert_eq!(emulator_ffi::mcrGetPC(), 0);
            assert_eq!(emulator_ffi::mcrGetSP(), 0);
            assert_eq!(emulator_ffi::mcrGetRegister(0), 0);
            assert_eq!(emulator_ffi::mcrGetStepCounter(), 0);
        }

        // current_step_id is the only trait method that already had a
        // non-`todo!()` body before F5c-3; sanity-check that it still
        // returns the initial value.
        assert_eq!(session.current_step_id(), StepId(0));
    }

    /// F5c-3 acceptance: constructing a session from a synthetic MCR
    /// CTFS payload must (a) succeed and (b) carry through the
    /// meta-derived source path and program name.
    #[test]
    fn new_from_ctfs_bytes_populates_meta() {
        let bytes = synthetic_mcr_ctfs_bytes();
        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");

        assert_eq!(session.meta.program, "/usr/local/bin/example");
        assert_eq!(
            session.meta.paths,
            vec!["src/main.c".to_owned(), "src/util.c".to_owned()]
        );
        assert!(
            session.meta.mcr.is_some(),
            "MCR meta block must round-trip through new_from_ctfs_bytes",
        );
    }

    /// `new_from_ctfs_bytes` must reject CTFS containers that lack the
    /// FlagHasMcrFields bit — otherwise we would silently route
    /// materialised traces (which need DB-backed playback) through the
    /// emulator path.
    #[test]
    fn new_from_ctfs_bytes_rejects_non_mcr_traces() {
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            program: "/usr/bin/ruby".to_owned(),
            args: vec!["script.rb".to_owned()],
            workdir: "/srv/proj".to_owned(),
            recorder_id: "ruby".to_owned(),
            paths: vec!["script.rb".to_owned()],
            mcr: None,
        };
        let dat = serialize_meta_dat(&meta);
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("non_mcr.ct");
        write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("events.log", b"placeholder")]).unwrap();
        let bytes = std::fs::read(&ct_path).unwrap();

        let err = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect_err("non-MCR CTFS must be rejected");
        assert!(
            err.to_string().contains("FLAG_HAS_MCR_FIELDS"),
            "error should mention the missing MCR flag, got: {err}",
        );
    }

    /// F5c-3 acceptance: `load_callstack` must surface at least one
    /// frame and that frame's function name must be non-empty. This
    /// mirrors what the F5 gateway-client checks via DAP `stackTrace`.
    #[test]
    fn load_callstack_returns_frame_with_non_empty_name() {
        let bytes = synthetic_mcr_ctfs_bytes();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let frames = session.load_callstack().expect("callstack must succeed");
        assert!(!frames.is_empty(), "expected at least one frame");
        let raw_name = &frames[0].content.call.raw_name;
        assert!(
            !raw_name.is_empty(),
            "frame function name must be non-empty, got `{raw_name}`"
        );
        // The synthetic fixture's program is `/usr/local/bin/example`,
        // so the basename — and therefore the frame name — must contain
        // "example". Asserting on the substring rather than the full
        // string keeps the test robust to future tweaks of the
        // root-name synthesis (e.g. appending an entry-point suffix).
        assert!(
            raw_name.contains("example"),
            "frame name should reflect program basename, got `{raw_name}`"
        );

        let path = &frames[0].content.call.location.path;
        assert!(!path.is_empty(), "frame source path must be non-empty");
        assert_eq!(path, "src/main.c", "frame path should pick the first meta.paths entry");
    }

    /// F5c-3 acceptance: `add_breakpoint` must report success so the
    /// DAP handler can surface `verified: true` to the client. Negative
    /// path: `delete_breakpoint` with an unknown id must error.
    #[test]
    fn add_breakpoint_returns_enabled_record() {
        let bytes = synthetic_mcr_ctfs_bytes();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let bp = session
            .add_breakpoint("src/main.c", 42)
            .expect("breakpoint must register");
        assert!(bp.enabled, "freshly-added breakpoint must be enabled");
        assert!(bp.id >= 1, "breakpoint id must be a positive monotonic counter");

        // Round-trip: deletion must succeed; second deletion must fail
        // with a typed error so the caller can surface a diagnostic.
        assert!(session.delete_breakpoint(&bp).expect("delete must succeed"));
        let err = session
            .delete_breakpoint(&bp)
            .expect_err("second delete of same id must fail");
        assert!(err.to_string().contains("not found"));
    }

    /// `load_locals` must project all 18 named x86_64 registers as
    /// variables. F5 needs at least one variable with a non-empty
    /// expression so the variables view renders something.
    #[test]
    fn load_locals_returns_register_variables() {
        let bytes = synthetic_mcr_ctfs_bytes();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let locals = session
            .load_locals(CtLoadLocalsArguments::default())
            .expect("locals must succeed");
        assert_eq!(locals.len(), REGISTER_NAMES.len());

        // Spot-check that the first variable has a non-empty name —
        // the variables view's headline acceptance bar.
        assert_eq!(locals[0].expression, "rax");
        match locals[0].value {
            ValueRecordWithType::Int { i, .. } => {
                assert_eq!(i, 0, "uninitialised registers must read as zero");
            }
            ref other => panic!("expected Int value, got {other:?}"),
        }
    }

    /// `load_value` must resolve register names to their u64 values
    /// and surface a typed error for unknown expressions.
    #[test]
    fn load_value_resolves_registers_and_errors_for_unknown() {
        let bytes = synthetic_mcr_ctfs_bytes();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let rax = session
            .load_value("rax", None, Lang::Unknown)
            .expect("rax must resolve");
        match rax {
            ValueRecordWithType::Int { i, .. } => assert_eq!(i, 0),
            other => panic!("expected Int value, got {other:?}"),
        }

        let err = session
            .load_value("not_a_register", None, Lang::Unknown)
            .expect_err("unknown variable must error");
        assert!(err.to_string().contains("not_a_register"));
    }

    /// `step` must not error out on the no-program path that F5's
    /// happy flow exercises (the DAP handler issues `step` actions on
    /// `next`/`stepIn` even when the emulator has no code loaded).
    ///
    /// The Nim implementation returns -1 without advancing
    /// `gStepCounter` when registers have not been seeded, so we only
    /// assert that the call succeeds and that the cached step id stays
    /// consistent with the emulator-reported counter.
    #[test]
    fn step_does_not_error_without_a_loaded_program() {
        let mut session = EmulatorReplaySession::new();
        session.step(Action::Next, true).expect("step must succeed");
        // SAFETY: the FFI getter is total; it returns 0 before any
        // instructions have executed and matches our cached id.
        let counter = unsafe { emulator_ffi::mcrGetStepCounter() };
        assert_eq!(session.current_step_id().0, counter as i64);
    }

    /// `load_events` / `load_step_events` / `load_return_value` are
    /// stub-OK on F5: they return empty/None values rather than
    /// `todo!()` so the DAP handler can survive an emulator-backed
    /// session that exercises them incidentally (e.g. during the events
    /// pagination warm-up).
    #[test]
    fn empty_returns_for_stub_paths() {
        let mut session = EmulatorReplaySession::new();
        let events = session.load_events().expect("load_events must succeed");
        assert!(events.events.is_empty());
        assert!(events.first_events.is_empty());

        let step_events = session.load_step_events(StepId(0), false);
        assert!(step_events.is_empty());

        let rv = session
            .load_return_value(None, Lang::Unknown)
            .expect("load_return_value must succeed");
        assert!(matches!(rv, ValueRecordWithType::None { .. }));
    }

    // ── M-DWARF-3 fixtures ──────────────────────────────────────────────
    //
    // The DWARF-bundling tests reuse the same small ELF fixture as the
    // `dwarf_index` module (built from `tests/fixtures/dwarf/hello.c` by
    // `rebuild.sh`). The file is ~11 KB and contains three functions
    // (`add`, `compute`, `main`) compiled with `-O0 -g` so its line
    // numbers stay stable across rebuilds.
    //
    // PC constants here mirror `dwarf_index::tests`: `PC_ADD_BODY`
    // (0x40100a) sits on hello.c line 24 — the `int sum = a + b;`
    // statement, which is the same line every gcc since 11 has emitted
    // for that source. The DWARF resolver is the authoritative source of
    // the expected number; we re-state it as a constant only so the test
    // failure message includes the expected value alongside the actual
    // one.

    const HELLO_ELF_FIXTURE: &[u8] = include_bytes!("../tests/fixtures/dwarf/hello.elf");
    const PC_ADD_BODY: u64 = 0x40100a;
    const PC_ADD_BODY_LINE: i64 = 24;

    /// Build a synthetic CTFS payload like `synthetic_mcr_ctfs_bytes()`
    /// but **with** a bundled `debug.dat` file carrying the hello.elf
    /// fixture. The resulting session's `dwarf` field should round-trip
    /// the parsed DWARF index so `build_location` can resolve PCs.
    fn synthetic_mcr_ctfs_bytes_with_dwarf() -> Vec<u8> {
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
            program: "/usr/local/bin/hello".to_owned(),
            args: vec![],
            workdir: "/tmp/run".to_owned(),
            recorder_id: "mcr".to_owned(),
            paths: vec!["src/main.c".to_owned()],
            mcr: Some(McrFields {
                tick_source: 1,
                total_threads: 1,
                atomic_mode: 0,
                total_events: 0,
                total_checkpoints: 0,
                start_time_unix_us: 0,
                platform: "linux-x86_64".to_owned(),
                tick_granularity: "instruction".to_owned(),
                tick_source_str: "rdtsc".to_owned(),
                atomic_mode_str: "seq_cst".to_owned(),
                start_time_str: "1970-01-01T00:00:00Z".to_owned(),
                hook_profile: String::new(),
                hook_strategies: Vec::new(),
            }),
        };
        let dat = serialize_meta_dat(&meta);
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("synthetic_with_dwarf.ct");
        write_minimal_ctfs(
            &ct_path,
            &[
                ("meta.dat", &dat),
                ("t00000000000", b""),
                (BUNDLED_DEBUG_FILE, HELLO_ELF_FIXTURE),
            ],
        )
        .unwrap();
        std::fs::read(&ct_path).unwrap()
    }

    /// M-DWARF-3 acceptance: when the CTFS container bundles a
    /// `debug.dat` ELF, `new_from_ctfs_bytes` must parse it into a
    /// `DwarfIndex` accessible via the session's `dwarf` field.
    #[test]
    fn new_from_ctfs_bytes_with_debug_populates_dwarf_index() {
        let bytes = synthetic_mcr_ctfs_bytes_with_dwarf();
        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");

        let dwarf = session.dwarf.as_ref().expect("debug.dat must produce a DwarfIndex");
        // hello.c is the primary source; the fixture also references
        // hello_start.S so we expect at least 1 source file.
        assert!(
            dwarf.source_file_count() >= 1,
            "DwarfIndex should know about at least one source file"
        );
        // Spot-check that a known PC inside the fixture resolves — this
        // exercises the full end-to-end "CTFS file → ELF bytes → gimli
        // sections → addr2line context" pipeline rather than just
        // confirming the bytes survived the bundle round-trip.
        let info = dwarf
            .resolve_pc(PC_ADD_BODY)
            .expect("PC_ADD_BODY must resolve through the bundled DWARF");
        assert_eq!(
            info.line, PC_ADD_BODY_LINE as u32,
            "expected line {PC_ADD_BODY_LINE}, got {info:?}"
        );
    }

    /// M-DWARF-3 acceptance: a corrupt or unrecognisable `debug.dat`
    /// must not prevent the session from coming up — it must fall back
    /// to the M-DWARF-2 placeholder location behaviour silently.
    #[test]
    fn new_from_ctfs_bytes_with_bad_debug_falls_back() {
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
            program: "/usr/local/bin/hello".to_owned(),
            args: vec![],
            workdir: "/tmp/run".to_owned(),
            recorder_id: "mcr".to_owned(),
            paths: vec!["src/main.c".to_owned()],
            mcr: Some(McrFields {
                tick_source: 1,
                total_threads: 1,
                atomic_mode: 0,
                total_events: 0,
                total_checkpoints: 0,
                start_time_unix_us: 0,
                platform: "linux-x86_64".to_owned(),
                tick_granularity: "instruction".to_owned(),
                tick_source_str: "rdtsc".to_owned(),
                atomic_mode_str: "seq_cst".to_owned(),
                start_time_str: "1970-01-01T00:00:00Z".to_owned(),
                hook_profile: String::new(),
                hook_strategies: Vec::new(),
            }),
        };
        let dat = serialize_meta_dat(&meta);
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("synthetic_bad_dwarf.ct");
        write_minimal_ctfs(
            &ct_path,
            &[
                ("meta.dat", &dat),
                ("t00000000000", b""),
                // Not an ELF — DwarfIndex::from_elf_bytes will return
                // DwarfError::Object("File magic is not …"), which the
                // M-DWARF-3 constructor must collapse to `dwarf: None`.
                (BUNDLED_DEBUG_FILE, b"this is definitely not ELF bytes"),
            ],
        )
        .unwrap();
        let bytes = std::fs::read(&ct_path).unwrap();

        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes)
            .expect("CTFS load must succeed even with a malformed debug.dat");
        assert!(
            session.dwarf.is_none(),
            "malformed debug.dat must collapse to None, not crash the session"
        );
    }

    /// M-DWARF-3 acceptance: with a bundled `debug.dat` AND a non-zero
    /// PC matching a real instruction, `load_callstack` must surface a
    /// frame whose `line` is the DWARF-resolved line (not the M-DWARF-2
    /// `1` placeholder) and whose `path` matches the DWARF-emitted file
    /// (overriding `meta.paths[0]` when they disagree).
    ///
    /// This is the headline test for M-DWARF-3: it walks the full
    /// recorder → bundle → replay → DAP `stackTrace` data path inside a
    /// single test process.
    #[test]
    fn load_callstack_uses_dwarf_resolved_line() {
        let bytes = synthetic_mcr_ctfs_bytes_with_dwarf();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        // SAFETY: mcrSetRegisters is the canonical way to seed the
        // emulator program counter; `new_from_ctfs_bytes` has just
        // called `mcrInit` so the register file is in a clean,
        // uninitialised state.
        //
        // We set every GPR to 0 and only RIP to PC_ADD_BODY so the
        // location calculation has a deterministic input. RFLAGS is set
        // to 0x202 (the x86_64 reset value: bit 1 must be set, plus IF
        // typically set) but its value does not affect PC resolution.
        unsafe {
            emulator_ffi::mcrSetRegisters(
                /* rax */ 0,
                /* rbx */ 0,
                /* rcx */ 0,
                /* rdx */ 0,
                /* rsi */ 0,
                /* rdi */ 0,
                /* rbp */ 0,
                /* rsp */ 0,
                /* r8  */ 0,
                /* r9  */ 0,
                /* r10 */ 0,
                /* r11 */ 0,
                /* r12 */ 0,
                /* r13 */ 0,
                /* r14 */ 0,
                /* r15 */ 0,
                /* rip */ PC_ADD_BODY,
                /* rflags */ 0x202,
            );
        }

        let frames = session.load_callstack().expect("callstack must succeed");
        assert!(!frames.is_empty(), "expected at least one frame");
        let loc = &frames[0].content.call.location;

        assert_eq!(
            loc.line, PC_ADD_BODY_LINE,
            "DWARF-resolved line must override the M-DWARF-2 placeholder; got loc = {loc:?}",
        );
        assert!(
            loc.path.ends_with("hello.c"),
            "DWARF-resolved path must override meta.paths[0] (= src/main.c); got loc.path = {}",
            loc.path,
        );
        // The emulator FFI surfaces the raw PC via `Location.offset` —
        // sanity-check that the test actually set it (otherwise we'd be
        // resolving PC 0 from leftover state, which would silently fail
        // the line assertion above too).
        assert_eq!(loc.offset, PC_ADD_BODY as i64);
    }
}
