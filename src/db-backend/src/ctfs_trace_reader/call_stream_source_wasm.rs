use std::path::Path;

use codetracer_trace_types::CallKey;

use crate::db::DbCall;

use super::ctfs_container::CtfsReader;

#[derive(Debug)]
pub struct SeekableCallStream;

impl SeekableCallStream {
    pub fn open(_path: &Path) -> Result<Option<SeekableCallStream>, String> {
        Ok(None)
    }

    pub fn open_from_ctfs(_ctfs: &mut CtfsReader) -> Result<Option<SeekableCallStream>, String> {
        Ok(None)
    }

    pub fn call_count(&self) -> usize {
        0
    }

    pub fn chunk_size(&self) -> usize {
        1
    }

    pub fn chunk_decompressions(&self) -> u64 {
        0
    }

    pub fn call(&self, _key: CallKey) -> Option<DbCall> {
        None
    }

    pub fn calls_and_ranges(&self) -> Result<Vec<(DbCall, u64, u64)>, String> {
        Ok(Vec::new())
    }

    pub fn refresh_from_ctfs(&self, _ctfs: &mut CtfsReader) -> Result<(), String> {
        Ok(())
    }
}
