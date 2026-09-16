use std::path::Path;

use crate::ctfs_trace_reader::ctfs_container::CtfsError;

/// The wasm32 stand-in for the native [`FollowStep`](super::follow_stream_source::FollowStep):
/// the same shape, so a caller compiles either way, over a source that never
/// produces one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FollowStep {
    pub global_line_index: u64,
}

#[derive(Debug)]
pub struct FollowStepStreamSource;

impl FollowStepStreamSource {
    pub fn open(_path: &Path) -> Result<Self, CtfsError> {
        Err(CtfsError::Corrupt(
            "follow streams are not supported on wasm32".to_string(),
        ))
    }

    pub fn step_count(&self) -> usize {
        0
    }

    pub fn step(&self, _index: usize) -> Option<FollowStep> {
        None
    }

    pub fn steps(&self) -> &[FollowStep] {
        &[]
    }

    pub fn is_finalized(&self) -> bool {
        true
    }

    pub fn refresh(&mut self) -> Result<usize, CtfsError> {
        Ok(0)
    }
}

#[derive(Debug)]
pub struct FollowValueStreamSource;

impl FollowValueStreamSource {
    pub fn open(_path: &Path) -> Result<Self, CtfsError> {
        Err(CtfsError::Corrupt(
            "follow value streams are not supported on wasm32".to_string(),
        ))
    }
}

#[derive(Debug)]
pub struct FollowCallStreamSource;

impl FollowCallStreamSource {
    pub fn open(_path: &Path) -> Result<Self, CtfsError> {
        Err(CtfsError::Corrupt(
            "follow call streams are not supported on wasm32".to_string(),
        ))
    }
}

#[derive(Debug)]
pub struct FollowReader;

impl FollowReader {
    pub fn open(_path: &Path) -> Result<Self, CtfsError> {
        Err(CtfsError::Corrupt(
            "follow readers are not supported on wasm32".to_string(),
        ))
    }

    pub fn refresh(&mut self) -> Result<(usize, usize, usize), CtfsError> {
        Ok((0, 0, 0))
    }

    pub fn is_finalized(&self) -> bool {
        true
    }

    pub fn steps(&self) -> &FollowStepStreamSource {
        panic!("follow readers are not supported on wasm32")
    }

    pub fn values(&self) -> &FollowValueStreamSource {
        panic!("follow readers are not supported on wasm32")
    }

    pub fn calls(&self) -> &FollowCallStreamSource {
        panic!("follow readers are not supported on wasm32")
    }
}
