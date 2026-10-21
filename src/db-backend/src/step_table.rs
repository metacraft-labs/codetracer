//! Recorded source steps indexed by stable execution-record IDs.
//!
//! Reload annotations consume execution IDs without being source steps. The
//! backing rows therefore remain sorted by ID, while parallel value/call/event
//! tables keep their original execution coordinates. `len` is the ID-space
//! extent, not the number of source rows; `iter` and `items` contain only steps.
use std::ops::{Index, IndexMut};

use codetracer_trace_types::StepId;

use crate::db::DbStep;

#[derive(Debug, Clone, Default)]
pub struct StepTable {
    pub items: Vec<DbStep>,
    extent: usize,
}

impl StepTable {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, id: StepId) -> Option<&DbStep> {
        let index = self.items.binary_search_by_key(&id, |step| step.step_id).ok()?;
        self.items.get(index)
    }

    pub fn get_mut(&mut self, id: StepId) -> Option<&mut DbStep> {
        let index = self.items.binary_search_by_key(&id, |step| step.step_id).ok()?;
        self.items.get_mut(index)
    }

    /// Exclusive end of the execution-ID space, including annotation slots.
    pub fn len(&self) -> usize {
        self.extent.max(
            self.items
                .last()
                .and_then(|step| usize::try_from(step.step_id.0).ok())
                .map_or(0, |id| id.saturating_add(1)),
        )
    }

    /// Preserve trailing annotation slots when materializing a recorded table.
    pub fn set_extent(&mut self, extent: usize) {
        self.extent = extent;
    }
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
    pub fn push(&mut self, step: DbStep) {
        self.items.push(step);
    }
    pub fn pop(&mut self) -> Option<DbStep> {
        self.items.pop()
    }
    pub fn clear(&mut self) {
        self.items.clear();
        self.extent = 0;
    }
    pub fn iter(&self) -> impl Iterator<Item = &DbStep> {
        self.items.iter()
    }
    pub fn iter_mut(&mut self) -> impl Iterator<Item = &mut DbStep> {
        self.items.iter_mut()
    }
    pub fn first(&self) -> Option<&DbStep> {
        self.items.first()
    }
    pub fn last(&self) -> Option<&DbStep> {
        self.items.last()
    }
}

#[allow(clippy::panic)] // Index is the deliberately panicking counterpart of get.
impl Index<StepId> for StepTable {
    type Output = DbStep;
    fn index(&self, id: StepId) -> &Self::Output {
        self.get(id)
            .unwrap_or_else(|| panic!("execution record {} is not a source step", id.0))
    }
}
#[allow(clippy::panic)] // IndexMut follows the same contract as Index.
impl IndexMut<StepId> for StepTable {
    fn index_mut(&mut self, id: StepId) -> &mut Self::Output {
        self.get_mut(id)
            .unwrap_or_else(|| panic!("execution record {} is not a source step", id.0))
    }
}
