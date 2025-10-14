use runtime_tracing::{StepId, ValueRecord};
use std::error::Error;

use crate::db::DbRecordEvent;
use crate::expr_loader::ExprLoader;
use crate::task::{Action, Location, ProgramEvent, CtLoadLocalsArguments, Variable};

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
    fn step(&mut self, action: Action, forward: bool) -> Result<bool, Box<dyn Error>>;
    fn load_locals(&mut self, arg: CtLoadLocalsArguments) -> Result<Vec<Variable>, Box<dyn Error>>;
    fn load_value(&mut self, expression: &str) -> Result<ValueRecord, Box<dyn Error>>;
    // assuming currently in the right call for both trace kinds; and if rr: possibly near the return value
    fn load_return_value(&mut self) -> Result<ValueRecord, Box<dyn Error>>;
    fn load_step_events(&mut self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent>;
    fn jump_to(&mut self, step_id: StepId) -> Result<bool, Box<dyn Error>>;
    fn current_step_id(&mut self) -> StepId;
}
