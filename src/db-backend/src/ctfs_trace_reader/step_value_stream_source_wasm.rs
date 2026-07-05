use std::path::Path;
use std::sync::Arc;

use codetracer_trace_types::{CallKey, FullValueRecord, Line, PathId, StepId};

use crate::db::DbStep;

use super::ctfs_container::CtfsReader;

#[derive(Debug)]
pub struct SeekableStepStream;

impl SeekableStepStream {
    pub fn open(_path: &Path) -> Result<Option<SeekableStepStream>, String> {
        Ok(None)
    }

    pub fn open_from_ctfs(_ctfs: &mut CtfsReader) -> Result<Option<SeekableStepStream>, String> {
        Ok(None)
    }

    pub fn step_count(&self) -> usize {
        0
    }

    pub fn chunk_size(&self) -> usize {
        1
    }

    pub fn chunk_decompressions(&self) -> u64 {
        0
    }

    pub fn open_sibling(&self) -> Option<SeekableStepStream> {
        None
    }

    pub fn step_line(&self, _step_id: StepId) -> Option<(PathId, Line)> {
        None
    }

    pub fn refresh_from_ctfs(&self, _ctfs: &mut CtfsReader) -> Result<(), String> {
        Ok(())
    }
}

#[derive(Debug)]
pub struct SeekableValueStream;

impl SeekableValueStream {
    pub fn open(_path: &Path) -> Result<Option<SeekableValueStream>, String> {
        Ok(None)
    }

    pub fn open_from_ctfs(_ctfs: &mut CtfsReader) -> Result<Option<SeekableValueStream>, String> {
        Ok(None)
    }

    pub fn value_count(&self) -> usize {
        0
    }

    pub fn chunk_size(&self) -> usize {
        1
    }

    pub fn chunk_decompressions(&self) -> u64 {
        0
    }

    pub fn variables_at(&self, _step_id: StepId) -> Option<Vec<FullValueRecord>> {
        None
    }

    pub fn refresh_from_ctfs(&self, _ctfs: &mut CtfsReader) -> Result<(), String> {
        Ok(())
    }
}

#[derive(Debug, Clone, Copy)]
pub enum StepBuildStrategy {
    Local { threads: usize },
    NetworkForward,
}

impl Default for StepBuildStrategy {
    fn default() -> Self {
        StepBuildStrategy::Local { threads: 1 }
    }
}

pub trait StepReplaySink {
    fn on_step(&mut self, _index: usize, _step: DbStep) {}
}

#[derive(Debug)]
pub struct LazyValueCache;

impl LazyValueCache {
    pub fn new(_stream: Arc<SeekableValueStream>, _step_count: usize) -> LazyValueCache {
        LazyValueCache
    }

    pub fn len(&self) -> usize {
        0
    }

    pub fn is_empty(&self) -> bool {
        true
    }

    pub fn populated_count(&self) -> usize {
        0
    }

    pub fn chunk_decompressions(&self) -> u64 {
        0
    }

    pub fn get(&self, _step_id: StepId) -> Option<&[FullValueRecord]> {
        None
    }
}

#[derive(Debug)]
pub struct LazyStepCache;

impl LazyStepCache {
    pub fn new(
        _stream: Arc<SeekableStepStream>,
        _call_keys: Vec<CallKey>,
        _global_call_keys: Vec<CallKey>,
    ) -> LazyStepCache {
        LazyStepCache
    }

    pub fn len(&self) -> usize {
        0
    }

    pub fn is_empty(&self) -> bool {
        true
    }

    pub fn populated_count(&self) -> usize {
        0
    }

    pub fn chunk_decompressions(&self) -> u64 {
        0
    }

    pub fn replay_range(&self, _range: std::ops::Range<usize>, _sinks: &mut [&mut dyn StepReplaySink]) {}

    pub fn build_whole_table(
        &self,
        path_count: usize,
        _strategy: StepBuildStrategy,
    ) -> (Vec<DbStep>, Vec<std::collections::HashMap<usize, Vec<DbStep>>>) {
        (Vec::new(), vec![std::collections::HashMap::new(); path_count])
    }

    pub fn find_next_line_hit(
        &self,
        _path_id: PathId,
        _line: Line,
        _from_step: usize,
        _strategy: StepBuildStrategy,
    ) -> Option<StepId> {
        None
    }

    pub fn get(&self, _step_id: StepId) -> Option<&DbStep> {
        None
    }
}
