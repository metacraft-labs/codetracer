use std::error::Error;

use crate::expr_loader::ExprLoader;
use crate::task::Location;

pub trait Replay: std::fmt::Debug {
    fn load_location(&mut self, expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>>;
    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>>;
}
