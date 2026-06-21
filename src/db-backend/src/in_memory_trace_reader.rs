use std::collections::HashMap;
use std::path::Path;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, PathId, Place, StepId, TypeId, TypeRecord, ValueRecord,
    VariableId,
};

use crate::db::{CellChange, Db, DbCall, DbRecordEvent, DbStep, EndOfProgram};
use crate::trace_reader::TraceReader;

/// A [`TraceReader`] backed by a fully-loaded, in-memory [`Db`].
///
/// Every method simply delegates to the corresponding field on the
/// inner `Db`.  This is the "zero-cost" adapter: no extra allocation
/// or transformation is needed because the data already lives in
/// memory in the right shape.
///
/// # Scope (M17b): small-trace / test / placeholder ONLY — NOT the network path
///
/// This reader serves every lookup over a FULLY-MATERIALIZED in-memory `Db`
/// (HashMaps/Vecs of steps/values/cells for the whole trace). It does NOT seek.
/// Per `Trace-Files-Overview.md` §"Random-access seeking" the production reader
/// for a materialized `.ct` — especially one loaded over the network — must NOT
/// materialize the whole trace; that is the job of the SEEKABLE
/// [`crate::ctfs_trace_reader::CTFSTraceReader`], which `trace_processor.rs`
/// documents as the path traces "must be read through". M17b additionally routes
/// the call tree of a `has_call_stream` `.ct` off this full-load path onto the
/// on-demand `calls.dat` stream (see
/// [`crate::ctfs_trace_reader::call_stream_source`]).
///
/// `InMemoryTraceReader` is therefore intentionally retained ONLY as:
///   - a test adapter (`db.rs`, `tracepoint_interpreter`, `diff.rs` test/helper
///     paths construct a small `Db` directly), and
///   - an explicit, small/empty PLACEHOLDER for code paths that don't read a
///     materialized `Db` at all — e.g. the MCR/emulator replay session in
///     `dap_server.rs`, which owns its own state machine and only needs a
///     non-`None` `reader` field (an EMPTY `Db`).
///
/// It must NEVER be the reader for a large/network-loaded materialized `.ct`;
/// those flow through [`CTFSTraceReader::open`](crate::ctfs_trace_reader::CTFSTraceReader::open).
#[derive(Debug, Clone)]
pub struct InMemoryTraceReader {
    pub db: Db,
}

impl InMemoryTraceReader {
    pub fn new(db: Db) -> Self {
        Self { db }
    }
}

impl TraceReader for InMemoryTraceReader {
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
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// Helper: create an empty `InMemoryTraceReader` for testing.
    fn empty_reader() -> InMemoryTraceReader {
        let db = Db::new(&PathBuf::from("/tmp/test-workdir"));
        InMemoryTraceReader::new(db)
    }

    #[test]
    fn empty_reader_counts_are_zero() {
        let reader = empty_reader();
        assert_eq!(reader.step_count(), 0);
        assert_eq!(reader.call_count(), 0);
        assert_eq!(reader.path_count(), 0);
        assert_eq!(reader.function_count(), 0);
        assert_eq!(reader.type_count(), 0);
        assert_eq!(reader.event_count(), 0);
    }

    #[test]
    fn empty_reader_lookups_return_none() {
        let reader = empty_reader();
        assert!(reader.step(StepId(0)).is_none());
        assert!(reader.call(CallKey(0)).is_none());
        assert!(reader.path(PathId(0)).is_none());
        assert!(reader.function(FunctionId(0)).is_none());
        assert!(reader.type_record(TypeId(0)).is_none());
        assert!(reader.variable_name(VariableId(0)).is_none());
        assert!(reader.path_id_for("nonexistent.rs").is_none());
    }

    #[test]
    fn empty_reader_per_step_data_returns_none() {
        let reader = empty_reader();
        assert!(reader.variables_at(StepId(0)).is_none());
        assert!(reader.compound_at(StepId(0)).is_none());
        assert!(reader.cells_at(StepId(0)).is_none());
        assert!(reader.variable_cells_at(StepId(0)).is_none());
        assert!(reader.instructions_at(StepId(0)).is_none());
    }

    #[test]
    fn empty_reader_events_empty() {
        let reader = empty_reader();
        assert!(reader.events().is_empty());
    }

    #[test]
    fn empty_reader_steps_from_is_empty() {
        let reader = empty_reader();
        assert!(reader.steps_from(StepId(0)).is_empty());
    }

    #[test]
    fn workdir_matches_inner_db() {
        let reader = empty_reader();
        // Verify the reader exposes the same workdir that the inner Db
        // was constructed with.
        assert_eq!(reader.workdir(), Path::new("/tmp/test-workdir"));
    }

    #[test]
    fn workdir_matches_construction() {
        let reader = empty_reader();
        assert_eq!(reader.workdir(), Path::new("/tmp/test-workdir"));
    }
}
