use runtime_tracing::StepId;
use std::error::Error;

use crate::expr_loader::ExprLoader;
use crate::task::{Location, ProgramEvent};

#[derive(Debug, Clone)]
pub struct Events {
    pub events: Vec<ProgramEvent>,
    pub first_events: Vec<ProgramEvent>,
    pub contents: String,
}

pub trait Replay: std::fmt::Debug {
    fn load_location(&mut self, expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>>;
    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>>;
    fn load_events(&mut self) -> Result<Events, Box<dyn Error>>;
    fn step_in(&mut self, forward: bool) -> Result<(), Box<dyn Error>>;
    fn current_step_id(&self) -> StepId;
}
